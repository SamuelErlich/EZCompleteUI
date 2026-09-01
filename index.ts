// ez-elevenlabs/index.ts
// EZCompleteUI v6.7
//
// Changes from v6.6:
//   - v6.6 introduced a BOOT_ERROR that took TTS down entirely (both the
//     main chat's speak button and the standalone TTS screen — same
//     function, same failure). Cause: `import { encodeBase64 } from
//     ".../std@0.168.0/encoding/base64.ts"` — that export was named
//     `encode` in std@0.168.0 (0.168.0 predates the encodeBase64 rename),
//     so the import failed to resolve at boot. Removed the external
//     dependency entirely and replaced it with a small self-contained
//     bytesToBase64 helper (chunks the char-code conversion, single btoa
//     call) — same fix as v6.6 intended, no pinned-version export-name risk
//     this time. See bytesToBase64's own comment for how the chunking
//     avoids the base64 padding-boundary problem naive chunking would hit.
//
// Changes from v6.5:
//   - FIXED CRASH: tts's base64 encoding used
//     btoa(String.fromCharCode(...new Uint8Array(audioData))) — spreading a
//     large byte array into String.fromCharCode blows the JS call-stack
//     argument limit. This crashed (uncaught, so no refund and no clean
//     error response — client just saw the connection die) for any TTS
//     response beyond roughly a few seconds of audio, which given normal
//     chat-response lengths was most of them. This was almost certainly
//     the "TTS network error" bug — it wasn't a network problem, the
//     function was throwing before it could respond.
//   - Added MAX_TTS_CHARS cap (10,000, matching eleven_multilingual_v2's
//     actual per-request limit — see DEFAULT_MODEL). Requests over the cap
//     are rejected with a clear 400 before any coin deduction or EL call,
//     instead of failing expensively at ElevenLabs after we've already
//     charged. If DEFAULT_MODEL ever changes, update this to match —
//     Flash v2.5 allows 40,000, Eleven v3 only 3,000.
//   - doELRequest now has a 90s AbortSignal.timeout per attempt (was
//     unbounded). An unbounded fetch here risked the whole function being
//     killed by Supabase's own platform-level execution timeout instead of
//     failing through our own error/refund path — same failure mode as the
//     crash above, just from the network side instead of the encoding
//     side. On timeout we now refund and return a clean 504 like any other
//     failure, instead of leaving the client to guess why the connection
//     dropped.
//
// Changes from v6.4:
//   - clone_voice now enforces per-tier slot limits before deducting coins.
//     Slots are counted from user_voices rows (no new DB column needed).
//     Tier limits: none=0, basic=1, standard=3, pro=5, ultra=10.
//     Non-subscribers cannot clone at all — it is a membership perk.
//     Response on slot exhaustion: 403 { error:"clone_slot_limit", used, limit, tier }
//   - clone_voice cost stays at 25 coins (charged on top of the slot system —
//     slots limit quantity, coins limit abuse of the remaining slots).
//   - pvc_clone action added (stub): returns 403 plan_required until a Creator
//     plan is confirmed. Code is present so the iOS client can call it without
//     a code change when the plan is upgraded — just remove the early return.
//   - getTierCloneLimit helper centralises tier→limit logic.
//   - getUserVoiceCount helper counts existing clones for the user.
//   - No changes to tts, fetch_voices, delete_voice actions.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const EL_API_KEY    = Deno.env.get("ELEVENLABS_API_KEY")!;
const DEFAULT_MODEL = "eleven_multilingual_v2";
const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const EL_COST_PER_1K_CHARS = 0.30;

// eleven_multilingual_v2's actual per-request character limit. Keep this in
// sync with DEFAULT_MODEL above — Flash v2.5 allows 40,000, Eleven v3 only
// 3,000. Rejecting oversized requests here (before deducting coins or
// calling ElevenLabs) avoids charging the user for a request we already
// know will fail.
const MAX_TTS_CHARS = 10000;

// Per-attempt timeout for the ElevenLabs call. Without this, a slow or
// hung EL response risks the whole edge function being killed by
// Supabase's own platform-level execution timeout instead of failing
// through our own error/refund path — same class of problem as an
// unbounded client request, just from the other side of the connection.
const EL_REQUEST_TIMEOUT_MS = 90_000;

// ── Image pricing reference (gpt-image-1-mini, May 2026) ─────────────────
// Kept here so ez-elevenlabs stays consistent if image features are added.
// Canonical table lives in br-ai/index.ts IMAGE_API_COST_USD.
//   1024x1024: low=$0.005(2c) medium=$0.020(6c) high=$0.036(11c)
//   1024x1536: low=$0.008(2c) medium=$0.030(9c) high=$0.054(16c)

// ── check-entitlement COIN_COSTS_PER_1K_TOKENS sync note ─────────────────
// Must match ez-chat MODEL_COINS_PER_1K. Update check-entitlement to:
//   chat_mini: 1, chat_standard: 2, chat_premium: 5
// (was standard:3, premium:10 — those overcounted and caused false 402s)

// TTS: 1 coin per 20 chars (~46% margin). Old 1/50 rate was losing 35%.
function ttsCoinCost(charCount: number): number {
  return Math.ceil(charCount / 20);
}

function truncatePrompt(text: unknown): string | null {
  if (!text || typeof text !== "string") return null;
  const cap    = 120;
  const search = text.slice(0, cap);
  const match  = search.match(/[.?!\n]/);
  if (match && match.index !== undefined && match.index > 10) {
    return text.slice(0, match.index + 1);
  }
  return text.length <= cap ? text : text.slice(0, cap) + "…";
}

function computeCostPer100Coins(apiCostUsd: number, coinsCharged: number): number | null {
  if (coinsCharged <= 0) return null;
  return Math.round((apiCostUsd / coinsCharged) * 100 * 10000) / 10000;
}

/// TEMPORARY: caps every subscriber tier to a single clone slot while voice cloning
/// is new — the tier-scaled limits in getTierCloneLimit below (basic=1, standard=3,
/// pro=5, ultra=10) are fully implemented and already correctly enforced by
/// getUserVoiceCount/clone_voice; this just dials them all down to 1 for launch.
/// To restore the real per-tier limits, set this to null.
const CLONE_LIMIT_OVERRIDE: number | null = 1;

/// Returns the maximum number of cloned voices allowed for a given tier.
/// Returns 0 for no subscription — cloning is a members-only perk.
function getTierCloneLimit(tier: string | null | undefined): number {
  const scaledLimit = (() => {
    switch ((tier ?? "").toLowerCase()) {
      case "basic":    return 1;
      case "standard": return 3;
      case "pro":      return 5;
      case "ultra":    return 10;
      default:         return 0; // no subscription or unrecognised tier
    }
  })();
  if (scaledLimit === 0) return 0; // still gate cloning behind a subscription regardless of override
  return CLONE_LIMIT_OVERRIDE ?? scaledLimit;
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Content-Type":                 "application/json",
  };
}

function jsonResponse(body: object, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders() });
}

/// Converts a byte array to base64 without spreading the whole buffer into
/// String.fromCharCode at once — that crashes past roughly 65,536 bytes
/// (exceeds the JS engine's max call-stack argument count). Converts in
/// bounded chunks instead, then base64-encodes the fully assembled string
/// in a single btoa() call — chunking the encode step itself would need
/// each chunk aligned to a multiple of 3 bytes to avoid mid-stream padding,
/// this sidesteps that entirely by only chunking the char-code conversion.
/// Self-contained on purpose — no external std/encoding import, after one
/// caused a boot failure by pinning a version whose export name had
/// changed. See v6.7 changelog.
function bytesToBase64(bytes: Uint8Array): string {
  const CHUNK_SIZE = 8192; // comfortably under the ~65,536 argument ceiling
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += CHUNK_SIZE) {
    const chunk = bytes.subarray(offset, offset + CHUNK_SIZE);
    binary += String.fromCharCode.apply(null, chunk as unknown as number[]);
  }
  return btoa(binary);
}

// ── Coin helpers ──────────────────────────────────────────────────────────────

async function getBalance(
  supabase: ReturnType<typeof createClient>,
  userId: string
): Promise<{ balance: number; tier: string } | null> {
  const { data, error } = await supabase
    .from("subscriptions")
    .select("coins_balance, tier")
    .eq("user_id", userId)
    .single();
  if (error || !data) return null;
  return { balance: data.coins_balance ?? 0, tier: data.tier ?? "" };
}

async function deductCoins(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  currentBalance: number,
  cost: number,
  feature: string
): Promise<number> {
  const newBalance = currentBalance - cost;
  await supabase
    .from("subscriptions")
    .update({ coins_balance: newBalance, updated_at: new Date().toISOString() })
    .eq("user_id", userId);
  if (cost > 0) {
    await supabase.from("coin_transactions").insert({
      user_id:       userId,
      amount:        cost,
      direction:     "debit",
      feature:       feature,
      description:   `Used ${feature}`,
      balance_after: newBalance,
    });
  }
  return newBalance;
}

async function refundCoins(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  originalBalance: number,
  cost: number,
  feature: string,
  reason: string
): Promise<void> {
  await supabase
    .from("subscriptions")
    .update({ coins_balance: originalBalance, updated_at: new Date().toISOString() })
    .eq("user_id", userId);
  await supabase.from("coin_transactions").insert({
    user_id:       userId,
    amount:        cost,
    direction:     "credit",
    feature:       feature,
    description:   `Refund: ${reason}`,
    balance_after: originalBalance,
  });
}

/// Counts how many voices the user has currently cloned.
/// Uses user_voices rows — no separate counter column needed.
async function getUserVoiceCount(
  supabase: ReturnType<typeof createClient>,
  userId: string
): Promise<number> {
  const { count, error } = await supabase
    .from("user_voices")
    .select("*", { count: "exact", head: true })
    .eq("user_id", userId);
  if (error || count === null) return 0;
  return count;
}

// ── Main handler ──────────────────────────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return jsonResponse({ error: "No auth" }, 401);

    const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
    const jwt = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabase.auth.getUser(jwt);
    if (userError || !user) return jsonResponse({ error: "Invalid token" }, 401);

    const ipAddress = req.headers.get("cf-connecting-ip")
                   ?? req.headers.get("x-forwarded-for")?.split(",")[0].trim()
                   ?? req.headers.get("x-real-ip")
                   ?? null;
    const userEmail = user.email ?? null;

    const body   = await req.json();
    const action = body.action as string;

    // ── fetch_voices — free ───────────────────────────────────────────────────
    if (action === "fetch_voices") {
      const res  = await fetch("https://api.elevenlabs.io/v1/voices", {
        headers: { "xi-api-key": EL_API_KEY },
      });
      const data = await res.json();

      // EL_API_KEY is one shared ElevenLabs account behind every app user, so
      // /v1/voices returns EVERY cloned voice on that account — not just this
      // caller's. Cross-reference against user_voices (the same table clone_voice
      // and delete_voice already scope by user_id) and only let a "cloned"-category
      // voice through if this user is the one who created it. Premade/professional/
      // etc. voices are untouched — those are meant to be shared.
      const { data: owned, error: ownedError } = await supabase
        .from("user_voices")
        .select("voice_id")
        .eq("user_id", user.id);

      if (ownedError) {
        console.error("[ez-elevenlabs] fetch_voices: could not load user_voices:", ownedError);
        // Fail closed — better to return an error than to accidentally leak every
        // user's cloned voices if the ownership lookup itself is broken.
        return jsonResponse({ error: "Could not verify voice ownership" }, 500);
      }

      const ownedVoiceIds = new Set((owned ?? []).map((row: { voice_id: string }) => row.voice_id));
      const allVoices = Array.isArray(data?.voices) ? data.voices : [];
      const visibleVoices = allVoices.filter((voice: { voice_id?: string; category?: string }) => {
        if (voice.category !== "cloned") return true;
        return voice.voice_id ? ownedVoiceIds.has(voice.voice_id) : false;
      });

      return jsonResponse({ ...data, voices: visibleVoices });
    }

    // ── tts ───────────────────────────────────────────────────────────────────
    if (action === "tts") {
      const { text, voice_id, output_format, speed, char_count } = body;
      if (!text || !voice_id) return jsonResponse({ error: "Missing text or voice_id" }, 400);

      const charCount = typeof char_count === "number" ? char_count : (text as string).length;

      if (charCount > MAX_TTS_CHARS) {
        return jsonResponse({
          error:  "text_too_long",
          reason: `ElevenLabs' ${DEFAULT_MODEL} model accepts at most ${MAX_TTS_CHARS} characters ` +
                  `per request. This text is ${charCount} characters — shorten it or split it up.`,
          max_chars: MAX_TTS_CHARS,
          char_count: charCount,
        }, 400);
      }

      const coinCost  = ttsCoinCost(charCount);
      const acct      = await getBalance(supabase, user.id);

      if (!acct) return jsonResponse({ error: "No account found" }, 403);
      if (acct.balance < coinCost) {
        return jsonResponse({ error: "Insufficient coins", balance: acct.balance, cost: coinCost }, 402);
      }

      const newBalance = await deductCoins(supabase, user.id, acct.balance, coinCost, "tts");
      const fmt        = (output_format as string) || "mp3_44100_128";
      const speedValue = typeof speed === "number" ? Math.min(1.2, Math.max(0.7, speed)) : 1.0;
      const elBody     = {
        text,
        model_id:       DEFAULT_MODEL,
        voice_settings: { stability: 0.5, similarity_boost: 0.75 },
        speed:          speedValue,
      };

      const doELRequest = async (requestFmt: string) =>
        fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voice_id}?output_format=${requestFmt}`, {
          method:  "POST",
          headers: { "xi-api-key": EL_API_KEY, "Content-Type": "application/json" },
          body:    JSON.stringify(elBody),
          signal:  AbortSignal.timeout(EL_REQUEST_TIMEOUT_MS),
        });

      let elResponse: Response;
      let usedFmt = fmt;
      try {
        elResponse = await doELRequest(fmt);
      } catch (fetchErr) {
        // AbortSignal.timeout() throws a DOMException named "TimeoutError"
        // rather than resolving with a non-ok Response, so it needs its own
        // catch — the !elResponse.ok branches below never see this case.
        const isTimeout = fetchErr instanceof DOMException && fetchErr.name === "TimeoutError";
        await refundCoins(supabase, user.id, acct.balance, coinCost, "tts",
          isTimeout ? "ElevenLabs request timed out" : "ElevenLabs fetch failed");
        await supabase.from("ez_usage_log").insert({
          user_id: user.id, user_email: userEmail, ip_address: ipAddress,
          feature: "tts", model: voice_id, prompt: truncatePrompt(text),
          coins_charged: coinCost, quantity: charCount,
          running_balance: acct.balance, api_cost_usd: (0).toFixed(6), status: "error",
          error_text: isTimeout ? "EL request timeout" : String(fetchErr).slice(0, 200),
        });
        return jsonResponse({
          error: isTimeout ? "tts_timeout" : "tts_fetch_failed",
          reason: isTimeout
            ? "ElevenLabs didn't respond in time. Coins have been refunded — try again, or use Apple TTS."
            : "Couldn't reach ElevenLabs. Coins have been refunded — try again, or use Apple TTS.",
        }, isTimeout ? 504 : 502);
      }

      if (!elResponse.ok && (elResponse.status === 402 || elResponse.status === 403)) {
        console.log(`[ez-elevenlabs] Format ${fmt} rejected (${elResponse.status}), falling back`);
        usedFmt = "mp3_44100_128";
        try {
          elResponse = await doELRequest(usedFmt);
        } catch (fetchErr) {
          const isTimeout = fetchErr instanceof DOMException && fetchErr.name === "TimeoutError";
          await refundCoins(supabase, user.id, acct.balance, coinCost, "tts",
            isTimeout ? "ElevenLabs fallback request timed out" : "ElevenLabs fallback fetch failed");
          await supabase.from("ez_usage_log").insert({
            user_id: user.id, user_email: userEmail, ip_address: ipAddress,
            feature: "tts", model: voice_id, prompt: truncatePrompt(text),
            coins_charged: coinCost, quantity: charCount,
            running_balance: acct.balance, api_cost_usd: (0).toFixed(6), status: "error",
            error_text: isTimeout ? "EL fallback timeout" : String(fetchErr).slice(0, 200),
          });
          return jsonResponse({
            error: isTimeout ? "tts_timeout" : "tts_fetch_failed",
            reason: "ElevenLabs didn't respond on the fallback attempt either. Coins have been refunded.",
          }, isTimeout ? 504 : 502);
        }
        if (!elResponse.ok) {
          await refundCoins(supabase, user.id, acct.balance, coinCost, "tts", "TTS failed after fallback");
          await supabase.from("ez_usage_log").insert({
            user_id: user.id, user_email: userEmail, ip_address: ipAddress,
            feature: "tts", model: voice_id, prompt: truncatePrompt(text),
            coins_charged: coinCost, quantity: charCount,
            running_balance: acct.balance, api_cost_usd: (0).toFixed(6), status: "error",
            error_text: "TTS failed after format fallback",
          });
          return jsonResponse({ error: "TTS failed" }, 500);
        }
      } else if (!elResponse.ok) {
        const errText = await elResponse.text();
        await refundCoins(supabase, user.id, acct.balance, coinCost, "tts", `EL error ${elResponse.status}`);
        await supabase.from("ez_usage_log").insert({
          user_id: user.id, user_email: userEmail, ip_address: ipAddress,
          feature: "tts", model: voice_id, prompt: truncatePrompt(text),
          coins_charged: coinCost, quantity: charCount,
          running_balance: acct.balance, api_cost_usd: (0).toFixed(6), status: "error",
          error_text: errText.slice(0, 200),
        });
        return jsonResponse({ error: errText }, elResponse.status);
      }

      const apiCostUsd = (charCount / 1000) * EL_COST_PER_1K_CHARS;
      await supabase.from("ez_usage_log").insert({
        user_id: user.id, user_email: userEmail, ip_address: ipAddress,
        feature: "tts", model: voice_id, prompt: truncatePrompt(text),
        coins_charged: coinCost, quantity: charCount,
        running_balance: newBalance, api_cost_usd: apiCostUsd.toFixed(6),
        cost_per_100_coins: computeCostPer100Coins(apiCostUsd, coinCost), status: "complete",
      });

      const audioData = await elResponse.arrayBuffer();
      const b64  = bytesToBase64(new Uint8Array(audioData));
      const mime      = usedFmt.includes("mp3") ? "audio/mpeg"
                      : usedFmt.includes("wav") ? "audio/wav" : "audio/mpeg";

      return jsonResponse({ audio_b64: b64, mime_type: mime, format: usedFmt,
                            coins_spent: coinCost, balance: newBalance });
    }

    // ── clone_voice ───────────────────────────────────────────────────────────
    if (action === "clone_voice") {
      const { name, audio_b64, filename, remove_background_noise } = body;
      if (!name || !audio_b64) return jsonResponse({ error: "Missing name or audio" }, 400);

      const acct = await getBalance(supabase, user.id);
      if (!acct) return jsonResponse({ error: "No account found" }, 403);

      // ── Membership gate: cloning is members-only ──────────────────────────
      const cloneLimit = getTierCloneLimit(acct.tier);
      if (cloneLimit === 0) {
        return jsonResponse({
          error:  "membership_required",
          reason: "Voice cloning is available to subscribers only. Subscribe to get started.",
        }, 403);
      }

      // ── Slot gate: check how many they've used ────────────────────────────
      const voicesUsed = await getUserVoiceCount(supabase, user.id);
      if (voicesUsed >= cloneLimit) {
        return jsonResponse({
          error: "clone_slot_limit",
          used:  voicesUsed,
          limit: cloneLimit,
          tier:  acct.tier,
          reason: `Your ${acct.tier} plan allows ${cloneLimit} cloned voice${cloneLimit === 1 ? "" : "s"}. ` +
                  `Upgrade your plan or delete an existing voice to free a slot.`,
        }, 403);
      }

      // ── Coin gate ─────────────────────────────────────────────────────────
      const CLONE_COST = 25;
      if (acct.balance < CLONE_COST) {
        return jsonResponse({ error: "Insufficient coins", balance: acct.balance, cost: CLONE_COST }, 402);
      }

      const newBalance = await deductCoins(supabase, user.id, acct.balance, CLONE_COST, "voice_clone");

      // ── Call ElevenLabs ───────────────────────────────────────────────────
      const audioBytes = Uint8Array.from(atob(audio_b64), (c) => c.charCodeAt(0));
      const formData   = new FormData();
      formData.append("name", name);
      formData.append("description", "Created via EZCompleteUI");
      formData.append("remove_background_noise", remove_background_noise === true ? "true" : "false");
      formData.append(
        "files",
        new Blob([audioBytes], { type: "audio/wav" }),
        filename || "sample.wav"
      );

      const elResponse   = await fetch("https://api.elevenlabs.io/v1/voices/add", {
        method:  "POST",
        headers: { "xi-api-key": EL_API_KEY },
        body:    formData,
      });
      const responseData = await elResponse.json();

      if (responseData.voice_id) {
        await supabase.from("user_voices").insert({
          user_id:    user.id,
          voice_id:   responseData.voice_id,
          voice_name: name,
        });
        const apiCostUsd = 0.10;
        await supabase.from("ez_usage_log").insert({
          user_id: user.id, user_email: userEmail, ip_address: ipAddress,
          feature: "voice_clone", model: responseData.voice_id, prompt: name,
          coins_charged: CLONE_COST, quantity: 1,
          running_balance: newBalance, api_cost_usd: apiCostUsd.toFixed(6),
          cost_per_100_coins: computeCostPer100Coins(apiCostUsd, CLONE_COST), status: "complete",
        });
        console.log(`[ez-elevenlabs] Clone ok: ${responseData.voice_id}, ${voicesUsed + 1}/${cloneLimit} slots used`);
        return jsonResponse({ ...responseData, balance: newBalance,
                              slots_used: voicesUsed + 1, slots_limit: cloneLimit });
      } else {
        await refundCoins(supabase, user.id, acct.balance, CLONE_COST, "voice_clone",
          "clone did not return voice_id");
        await supabase.from("ez_usage_log").insert({
          user_id: user.id, user_email: userEmail, ip_address: ipAddress,
          feature: "voice_clone", prompt: name,
          coins_charged: CLONE_COST, quantity: 1,
          running_balance: acct.balance, api_cost_usd: (0).toFixed(6),
          status: "error", error_text: "Clone did not return voice_id",
        });
        return jsonResponse({ ...responseData, balance: acct.balance });
      }
    }

    // ── pvc_clone — stub until Creator plan is active ────────────────────────
    // The iOS client can already send this action. When a Creator plan is
    // confirmed, remove this early return and implement the /v1/voices/pvc flow.
    if (action === "pvc_clone") {
      return jsonResponse({
        error:  "plan_required",
        reason: "Professional Voice Cloning requires a Creator plan. Coming soon.",
      }, 403);
    }

    // ── delete_voice — free ───────────────────────────────────────────────────
    if (action === "delete_voice") {
      const { voice_id } = body;
      if (!voice_id) return jsonResponse({ error: "Missing voice_id" }, 400);

      // Verify ownership BEFORE calling ElevenLabs' delete endpoint. Without this,
      // any authenticated user who knew (or, until the fetch_voices fix, could see)
      // a voice_id could permanently delete another user's actual cloned voice —
      // the user_voices row-scoping below only cleaned up this account's own
      // bookkeeping, it never stopped the real ElevenLabs deletion from happening.
      const { data: ownedRow, error: ownedError } = await supabase
        .from("user_voices")
        .select("voice_id")
        .eq("user_id", user.id)
        .eq("voice_id", voice_id)
        .maybeSingle();

      if (ownedError) {
        console.error("[ez-elevenlabs] delete_voice: ownership check failed:", ownedError);
        return jsonResponse({ error: "Could not verify voice ownership" }, 500);
      }
      if (!ownedRow) {
        return jsonResponse({ error: "not_found", reason: "You don't own a voice with that id." }, 404);
      }

      await fetch(`https://api.elevenlabs.io/v1/voices/${voice_id}`, {
        method:  "DELETE",
        headers: { "xi-api-key": EL_API_KEY },
      });
      await supabase.from("user_voices").delete()
        .eq("user_id", user.id).eq("voice_id", voice_id);

      return jsonResponse({ success: true });
    }

    return jsonResponse({ error: "Unknown action" }, 400);

  } catch (unexpectedError) {
    console.error("[ez-elevenlabs] Uncaught error:", unexpectedError);
    return jsonResponse({ error: "Server error" }, 500);
  }
});
