// br-community/index.ts
// EZCompleteUI — BrainRot Game Community Sharing Edge Function
// v1.6
//
// Purpose:
//   Lets players publish a finished game (title, premise, maze seed,
//   items/enemies, and all 3 art assets) to a public, paginated browse list,
//   lets other players download a published game into their own local
//   BRGameLibrary, and provides reporting + self-service unsharing.
//
//   Deliberately a SEPARATE edge function from br-ai: br-ai is "spend coins
//   to generate AI content"; this is "spend coins to download something that
//   already exists" plus free CRUD around sharing/reporting/unsharing. Each
//   stays focused and neither file balloons into doing both jobs.
//
//   Requires (Project Settings → Edge Functions → br-community → Secrets):
//     SUPABASE_URL               — same project URL br-ai already uses
//     SUPABASE_SERVICE_ROLE_KEY  — service-role key (bypasses RLS; never
//                                   ship in the app binary).
//     BR_ADMIN_CODE              — NEW in v1.6. A secret passphrase required
//                                   for all admin_* actions. Set it before
//                                   deploying. If absent, admin endpoints
//                                   return 503. Never put this value in the
//                                   app binary — the app sends whatever the
//                                   user types; the server checks it here.
//
// Changes from v1.5:
//   - admin_list_games: returns all games including is_hidden ones, plus a
//     per-game report_count derived from shared_game_reports, sorted newest-
//     first. Intended for the in-app admin panel (debug builds only).
//   - admin_set_hidden: manually hide or restore a game with an optional
//     reason string. Does not require the caller to be the game's creator.
//   - admin_delete_game: force-delete any game + its Storage assets regardless
//     of who created it. Permanent and not reversible.
//   All three require a valid BR_ADMIN_CODE in the request body. The iOS app
//   additionally gates the admin UI behind #if DEBUG, but the server enforces
//   the code check independently — a release build (or a jailbroken device
//   calling the endpoint directly) still gets a 403 without the right code.
//
// Actions (all POST, JSON body with an "action" field):
//   share_game          — publish a game. Requires JWT. Rate-limited.
//   list_shared_games   — paginated public browse. No JWT required.
//   download_shared_game — download assets as base64. Requires JWT.
//                          Free on re-download; costs coins on first download.
//   report_game         — flag a game. Requires JWT. Auto-hides after
//                          REPORT_AUTO_HIDE_THRESHOLD distinct reporters.
//   delete_shared_game  — creator-only unshare. Requires JWT.
//   admin_list_games    — all games + report counts. Requires BR_ADMIN_CODE.
//   admin_set_hidden    — manually hide/restore. Requires BR_ADMIN_CODE.
//   admin_delete_game   — force-delete any game. Requires BR_ADMIN_CODE.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const SUPABASE_URL              = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHECK_ENTITLEMENT_URL     = `${SUPABASE_URL}/functions/v1/check-entitlement`;

const STORAGE_BUCKET = "shared-game-assets";

// ── Tunables ─────────────────────────────────────────────────────────────────
const SHARED_GAME_DOWNLOAD_COINS = 2;     // flat fee; covers storage/bandwidth, well under any generation cost
const MAX_SHARES_PER_24H         = 5;     // per user, checked against real row timestamps server-side
const REPORT_AUTO_HIDE_THRESHOLD = 3;     // distinct reporters before auto-hide kicks in
const MAX_IMAGE_BYTES            = 4 * 1024 * 1024; // 4MB/image — generous for a 1024x1024 PNG, caps abuse
const MAX_TITLE_LENGTH           = 60;
const MAX_PREMISE_LENGTH         = 1000;
const MAX_ARRAY_ITEMS            = 10;    // items[] / enemies[] length cap
const MAX_ARRAY_ITEM_LENGTH      = 40;    // each items[]/enemies[] string cap
const SIGNED_URL_EXPIRY_SECONDS  = 3600;  // 1 hour — list results go stale; client re-fetches the list to refresh

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
  };
}

function jsonResp(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders() });
}

// ── Supabase REST helpers ───────────────────────────────────────────────────
// Raw fetch against PostgREST/Storage rather than the supabase-js SDK, to
// match br-ai's existing style (no new SDK dependency introduced for this).

function restHeaders(extra?: Record<string, string>) {
  return {
    "apikey":        SUPABASE_SERVICE_ROLE_KEY,
    "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    "Content-Type":  "application/json",
    ...extra,
  };
}

/// Parses a PostgREST "Content-Range: 0-4/7" response header into the total
/// count (7 in that example). Returns 0 if the header is missing/malformed.
function parseContentRangeTotal(res: Response): number {
  const header = res.headers.get("content-range");
  if (!header) return 0;
  const parts = header.split("/");
  const total = parts.length === 2 ? parseInt(parts[1], 10) : NaN;
  return Number.isFinite(total) ? total : 0;
}

/// Resolves a user JWT to a verified user id via Supabase's own auth
/// endpoint. Deliberately NOT a local base64 decode of the JWT payload —
/// that would read the claims without verifying the signature, which means
/// a forged token could claim to be any user. Given this app's audience can
/// and will tamper with anything not verified server-side, every identity
/// check in this file goes through Supabase's verifier.
async function resolveUserIdFromJwt(userJwt: string): Promise<string | null> {
  try {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: {
        "apikey":        SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": `Bearer ${userJwt}`,
      },
    });
    if (!res.ok) return null;
    const data = await res.json();
    return typeof data?.id === "string" ? data.id : null;
  } catch (err) {
    console.error("[br-community] resolveUserIdFromJwt network error:", err);
    return null;
  }
}

async function decodeBase64ToBytes(base64String: string): Promise<Uint8Array> {
  const binary = atob(base64String);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/// Inverse of decodeBase64ToBytes. Chunked to avoid call-stack blowups from
/// String.fromCharCode(...hugeArray) on larger buffers.
function bytesToBase64(bytes: Uint8Array): string {
  const CHUNK_SIZE = 8192;
  let binary = "";
  for (let i = 0; i < bytes.length; i += CHUNK_SIZE) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK_SIZE));
  }
  return btoa(binary);
}

async function storageUpload(path: string, bytes: Uint8Array, contentType: string): Promise<boolean> {
  try {
    const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${STORAGE_BUCKET}/${path}`, {
      method:  "POST",
      headers: {
        "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        "apikey":        SUPABASE_SERVICE_ROLE_KEY,
        "Content-Type":  contentType,
        "x-upsert":      "true",
      },
      body: bytes as BodyInit,
    });
    return res.ok;
  } catch (err) {
    console.error(`[br-community] storageUpload failed for ${path}:`, err);
    return false;
  }
}

async function storageDownloadAsBase64(path: string): Promise<string | null> {
  try {
    const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${STORAGE_BUCKET}/${path}`, {
      headers: { "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`, "apikey": SUPABASE_SERVICE_ROLE_KEY },
    });
    if (!res.ok) return null;
    const buffer = new Uint8Array(await res.arrayBuffer());
    return bytesToBase64(buffer);
  } catch (err) {
    console.error(`[br-community] storageDownloadAsBase64 failed for ${path}:`, err);
    return null;
  }
}

async function storageSignedUrl(path: string): Promise<string | null> {
  try {
    const res = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/${STORAGE_BUCKET}/${path}`, {
      method:  "POST",
      headers: restHeaders(),
      body:    JSON.stringify({ expiresIn: SIGNED_URL_EXPIRY_SECONDS }),
    });
    if (!res.ok) return null;
    const data = await res.json();
    return typeof data?.signedURL === "string" ? `${SUPABASE_URL}/storage/v1${data.signedURL}` : null;
  } catch (err) {
    console.error(`[br-community] storageSignedUrl failed for ${path}:`, err);
    return null;
  }
}

/// Best-effort cleanup used when a share_game request fails partway through
/// (e.g. images uploaded but the DB insert then fails). Failure to clean up
/// here is logged but never changes the response sent to the client — it
/// would only leave a few orphaned objects in storage, not a security or
/// correctness issue.
async function storageDeleteMany(paths: string[]): Promise<void> {
  if (paths.length === 0) return;
  try {
    await fetch(`${SUPABASE_URL}/storage/v1/object/${STORAGE_BUCKET}`, {
      method:  "DELETE",
      headers: restHeaders(),
      body:    JSON.stringify({ prefixes: paths }),
    });
  } catch (err) {
    console.error("[br-community] storageDeleteMany cleanup failed:", err);
  }
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders() });

  let body: any;
  try {
    body = await req.json();
  } catch {
    return jsonResp({ error: "Invalid JSON body" }, 400);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const userJwt = authHeader.replace(/^Bearer\s+/i, "").trim();

  // ── share_game ─────────────────────────────────────────────────────────────
  if (body.action === "share_game") {
    if (!userJwt) return jsonResp({ error: "Authentication required" }, 401);
    const userId = await resolveUserIdFromJwt(userJwt);
    if (!userId) return jsonResp({ error: "Invalid session" }, 401);

    // Validate everything BEFORE the rate-limit check or any storage/DB
    // writes, so a malformed request never burns part of the user's daily
    // share quota.
    const themeTitle = typeof body.theme_title === "string" ? body.theme_title.trim() : "";
    const premise     = typeof body.premise === "string" ? body.premise.trim() : "";
    const hint         = typeof body.hint === "string" ? body.hint.trim() : "";
    const items        = Array.isArray(body.items) ? body.items : [];
    const enemies      = Array.isArray(body.enemies) ? body.enemies : [];
    const seed          = typeof body.seed === "number" ? body.seed : null;
    const playerB64     = typeof body.player_image_b64 === "string" ? body.player_image_b64 : null;
    const enemyB64       = typeof body.enemy_image_b64 === "string" ? body.enemy_image_b64 : null;
    const backgroundB64 = typeof body.background_image_b64 === "string" ? body.background_image_b64 : null;

    if (!themeTitle) return jsonResp({ error: "theme_title required" }, 400);
    if (themeTitle.length > MAX_TITLE_LENGTH) return jsonResp({ error: `theme_title must be ${MAX_TITLE_LENGTH} characters or fewer` }, 400);
    if (!premise) return jsonResp({ error: "premise required" }, 400);
    if (premise.length > MAX_PREMISE_LENGTH) return jsonResp({ error: `premise must be ${MAX_PREMISE_LENGTH} characters or fewer` }, 400);
    if (seed === null || !Number.isFinite(seed)) return jsonResp({ error: "seed must be a number" }, 400);
    if (!playerB64 || !enemyB64 || !backgroundB64) return jsonResp({ error: "player_image_b64, enemy_image_b64, and background_image_b64 are all required" }, 400);

    for (const [label, arr] of [["items", items], ["enemies", enemies]] as const) {
      if (arr.length > MAX_ARRAY_ITEMS) return jsonResp({ error: `${label} may contain at most ${MAX_ARRAY_ITEMS} entries` }, 400);
      for (const entry of arr) {
        if (typeof entry !== "string" || entry.length > MAX_ARRAY_ITEM_LENGTH) {
          return jsonResp({ error: `${label} entries must be strings of ${MAX_ARRAY_ITEM_LENGTH} characters or fewer` }, 400);
        }
      }
    }

    let playerBytes: Uint8Array, enemyBytes: Uint8Array, backgroundBytes: Uint8Array;
    try {
      [playerBytes, enemyBytes, backgroundBytes] = await Promise.all([
        decodeBase64ToBytes(playerB64),
        decodeBase64ToBytes(enemyB64),
        decodeBase64ToBytes(backgroundB64),
      ]);
    } catch {
      return jsonResp({ error: "One or more images are not valid base64" }, 400);
    }
    for (const [label, bytes] of [["player", playerBytes], ["enemy", enemyBytes], ["background", backgroundBytes]] as const) {
      if (bytes.length > MAX_IMAGE_BYTES) {
        return jsonResp({ error: `${label}_image exceeds the ${MAX_IMAGE_BYTES} byte limit` }, 400);
      }
      if (bytes.length === 0) {
        return jsonResp({ error: `${label}_image is empty` }, 400);
      }
    }

    // Rate limit: count this user's shares in the last 24h via PostgREST's
    // exact-count header rather than trusting anything the client claims
    // about its own request history.
    const sinceIso = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    let recentShareCount = 0;
    try {
      const countRes = await fetch(
        `${SUPABASE_URL}/rest/v1/shared_games?select=id&creator_user_id=eq.${userId}&created_at=gte.${sinceIso}`,
        { headers: restHeaders({ "Prefer": "count=exact" }) },
      );
      recentShareCount = parseContentRangeTotal(countRes);
    } catch (err) {
      console.error("[br-community] rate limit count query failed:", err);
      // Fail open on infra errors (consistent with br-ai's check-entitlement
      // pattern) — an outage in our own count query shouldn't block sharing.
    }
    if (recentShareCount >= MAX_SHARES_PER_24H) {
      return jsonResp({
        error:   "rate_limited",
        message: `You can share up to ${MAX_SHARES_PER_24H} games per day. Try again later.`,
      }, 429);
    }

    const gameId = crypto.randomUUID();
    const playerPath     = `${gameId}/player.png`;
    const enemyPath       = `${gameId}/enemy.png`;
    const backgroundPath = `${gameId}/background.png`;

    const uploadResults = await Promise.all([
      storageUpload(playerPath, playerBytes, "image/png"),
      storageUpload(enemyPath, enemyBytes, "image/png"),
      storageUpload(backgroundPath, backgroundBytes, "image/png"),
    ]);
    if (uploadResults.some((ok) => !ok)) {
      // Clean up whichever uploads DID succeed so we don't leak partial
      // asset sets under a gameId that never gets a DB row.
      await storageDeleteMany([playerPath, enemyPath, backgroundPath]);
      return jsonResp({ error: "Failed to upload one or more images" }, 502);
    }

    try {
      const insertRes = await fetch(`${SUPABASE_URL}/rest/v1/shared_games`, {
        method:  "POST",
        headers: restHeaders({ "Prefer": "return=minimal" }),
        body: JSON.stringify({
          id: gameId,
          creator_user_id: userId,
          theme_title: themeTitle,
          premise,
          hint: hint || null,
          items,
          enemies,
          seed,
          player_image_path: playerPath,
          enemy_image_path: enemyPath,
          background_image_path: backgroundPath,
        }),
      });
      if (!insertRes.ok) {
        const errText = await insertRes.text();
        console.error(`[br-community] shared_games insert failed ${insertRes.status}:`, errText);
        await storageDeleteMany([playerPath, enemyPath, backgroundPath]);
        return jsonResp({ error: "Failed to publish game" }, 502);
      }
    } catch (err) {
      console.error("[br-community] shared_games insert network error:", err);
      await storageDeleteMany([playerPath, enemyPath, backgroundPath]);
      return jsonResp({ error: "Network error" }, 502);
    }

    console.log(`[br-community] share_game ok — id=${gameId} user=${userId}`);
    return jsonResp({ success: true, shared_game_id: gameId });
  }

  // ── list_shared_games ────────────────────────────────────────────────────
  if (body.action === "list_shared_games") {
    const limit = Math.min(50, Math.max(1, typeof body.limit === "number" ? body.limit : 20));
    const before = typeof body.before === "string" ? body.before : null;

    let query = `${SUPABASE_URL}/rest/v1/shared_games?select=id,theme_title,premise,hint,items,enemies,seed,player_image_path,enemy_image_path,background_image_path,created_at&is_hidden=eq.false&order=created_at.desc&limit=${limit}`;
    if (before) query += `&created_at=lt.${encodeURIComponent(before)}`;

    let rows: any[];
    try {
      const res = await fetch(query, { headers: restHeaders() });
      if (!res.ok) {
        const errText = await res.text();
        console.error(`[br-community] list_shared_games query failed ${res.status}:`, errText);
        return jsonResp({ error: "Failed to load shared games" }, 502);
      }
      rows = await res.json();
    } catch (err) {
      console.error("[br-community] list_shared_games network error:", err);
      return jsonResp({ error: "Network error" }, 502);
    }

    // Signed URLs are generated in parallel per row, 3 per row. For a
    // 50-row page that's 150 signing calls — acceptable for v1; worth
    // revisiting (e.g. a single batch-sign endpoint, or smaller default
    // page sizes) if list_shared_games becomes a hot path at scale.
    const items = await Promise.all(rows.map(async (row) => {
      const [playerUrl, enemyUrl, backgroundUrl] = await Promise.all([
        storageSignedUrl(row.player_image_path),
        storageSignedUrl(row.enemy_image_path),
        storageSignedUrl(row.background_image_path),
      ]);
      return {
        shared_game_id: row.id,
        theme_title: row.theme_title,
        premise: row.premise,
        created_at: row.created_at,
        player_image_url: playerUrl,
        enemy_image_url: enemyUrl,
        background_image_url: backgroundUrl,
      };
    }));

    const nextCursor = rows.length === limit ? rows[rows.length - 1].created_at : null;
    return jsonResp({ success: true, items, next_cursor: nextCursor });
  }

  // ── download_shared_game ─────────────────────────────────────────────────
  if (body.action === "download_shared_game") {
    if (!userJwt) return jsonResp({ error: "Authentication required" }, 401);
    const userId = await resolveUserIdFromJwt(userJwt);
    if (!userId) return jsonResp({ error: "Invalid session" }, 401);

    const sharedGameId = typeof body.shared_game_id === "string" ? body.shared_game_id : null;
    if (!sharedGameId) return jsonResp({ error: "shared_game_id required" }, 400);

    let game: any;
    try {
      const res = await fetch(`${SUPABASE_URL}/rest/v1/shared_games?id=eq.${sharedGameId}&select=*`, { headers: restHeaders() });
      const rows = res.ok ? await res.json() : [];
      game = rows[0] ?? null;
    } catch (err) {
      console.error("[br-community] download_shared_game lookup network error:", err);
      return jsonResp({ error: "Network error" }, 502);
    }
    if (!game || game.is_hidden) return jsonResp({ error: "Game not found" }, 404);

    const isCreator = game.creator_user_id === userId;
    let chargedCoins = false;
    let insertedDownloadRow = false;

    if (!isCreator) {
      // Atomic "claim": the unique (user_id, shared_game_id) constraint
      // makes this insert itself the source of truth for "is this a first
      // download". Succeeds → genuinely first time → charge. Conflicts →
      // already downloaded before → free re-serve, no charge.
      let isFirstDownload = false;
      try {
        const claimRes = await fetch(`${SUPABASE_URL}/rest/v1/shared_game_downloads`, {
          method:  "POST",
          headers: restHeaders({ "Prefer": "return=minimal" }),
          body:    JSON.stringify({ user_id: userId, shared_game_id: sharedGameId }),
        });
        if (claimRes.ok) {
          isFirstDownload = true;
          insertedDownloadRow = true;
        } else if (claimRes.status === 409) {
          isFirstDownload = false; // already downloaded previously — free
        } else {
          // Genuine infra error on the claim itself. Fail open: charge
          // anyway rather than block the download — worst case is a future
          // re-download getting charged again instead of recognized as
          // free, which is a minor UX nit, not a security or cost issue.
          console.error(`[br-community] download claim insert failed ${claimRes.status}, failing open`);
          isFirstDownload = true;
          insertedDownloadRow = false;
        }
      } catch (err) {
        console.error("[br-community] download claim network error, failing open:", err);
        isFirstDownload = true;
        insertedDownloadRow = false;
      }

      if (isFirstDownload) {
        try {
          const entitlementRes = await fetch(CHECK_ENTITLEMENT_URL, {
            method:  "POST",
            headers: { "Content-Type": "application/json", "Authorization": `Bearer ${userJwt}` },
            body: JSON.stringify({
              action:  "deduct",
              feature: "brainrot_shared_game_download",
              coins:   SHARED_GAME_DOWNLOAD_COINS,
              prompt:  `Download shared game: ${game.theme_title}`,
              model:   "n/a",
            }),
          });
          const entitlementData = await entitlementRes.json();
          if (!entitlementData.allowed) {
            // Compensate: undo the claim so a future retry (once the
            // player has enough coins) is still treated as first-time.
            if (insertedDownloadRow) {
              await fetch(`${SUPABASE_URL}/rest/v1/shared_game_downloads?user_id=eq.${userId}&shared_game_id=eq.${sharedGameId}`, {
                method: "DELETE", headers: restHeaders(),
              }).catch((err) => console.error("[br-community] compensating delete failed:", err));
            }
            const balance = entitlementData.balance ?? 0;
            const needed  = Math.max(0, SHARED_GAME_DOWNLOAD_COINS - balance);
            return jsonResp({ error: "insufficient_coins", balance, cost: SHARED_GAME_DOWNLOAD_COINS, needed }, 402);
          }
          chargedCoins = true;
        } catch (err) {
          console.error("[br-community] check-entitlement unreachable, failing open:", err);
          // Consistent with br-ai: an unreachable entitlement service fails
          // open rather than blocking the user over our own infra issue.
        }
      }
    }

    const [playerB64, enemyB64, backgroundB64] = await Promise.all([
      storageDownloadAsBase64(game.player_image_path),
      storageDownloadAsBase64(game.enemy_image_path),
      storageDownloadAsBase64(game.background_image_path),
    ]);
    if (!playerB64 || !enemyB64 || !backgroundB64) {
      return jsonResp({ error: "One or more game assets could not be retrieved" }, 502);
    }

    // Best-effort, non-critical — never fails the request.
    fetch(`${SUPABASE_URL}/rest/v1/shared_games?id=eq.${sharedGameId}`, {
      method: "PATCH", headers: restHeaders(),
      body: JSON.stringify({ download_count: (game.download_count ?? 0) + 1 }),
    }).catch((err) => console.error("[br-community] download_count increment failed:", err));

    console.log(`[br-community] download_shared_game ok — id=${sharedGameId} user=${userId} charged=${chargedCoins}`);
    return jsonResp({
      success: true,
      theme_title: game.theme_title,
      premise: game.premise,
      hint: game.hint ?? "",
      items: game.items ?? [],
      enemies: game.enemies ?? [],
      seed: game.seed,
      charged_coins: chargedCoins ? SHARED_GAME_DOWNLOAD_COINS : 0,
      assets: { player: playerB64, enemy: enemyB64, bg: backgroundB64 },
    });
  }

  // ── report_game ───────────────────────────────────────────────────────────
  if (body.action === "report_game") {
    if (!userJwt) return jsonResp({ error: "Authentication required" }, 401);
    const userId = await resolveUserIdFromJwt(userJwt);
    if (!userId) return jsonResp({ error: "Invalid session" }, 401);

    const sharedGameId = typeof body.shared_game_id === "string" ? body.shared_game_id : null;
    if (!sharedGameId) return jsonResp({ error: "shared_game_id required" }, 400);
    const reason = typeof body.reason === "string" ? body.reason.trim().slice(0, 500) : null;

    try {
      const insertRes = await fetch(`${SUPABASE_URL}/rest/v1/shared_game_reports`, {
        method:  "POST",
        headers: restHeaders({ "Prefer": "return=minimal" }),
        body:    JSON.stringify({ shared_game_id: sharedGameId, reporter_user_id: userId, reason }),
      });
      // 409 = this user already reported this game. Treat as success — "I
      // already flagged this" shouldn't surface as an error to the player.
      if (!insertRes.ok && insertRes.status !== 409) {
        const errText = await insertRes.text();
        console.error(`[br-community] report insert failed ${insertRes.status}:`, errText);
        return jsonResp({ error: "Failed to submit report" }, 502);
      }
    } catch (err) {
      console.error("[br-community] report insert network error:", err);
      return jsonResp({ error: "Network error" }, 502);
    }

    // Check the report count and auto-hide if the threshold is crossed.
    // This is a circuit-breaker on top of "publish then review", not a
    // replacement for it — clearly bad content shouldn't sit fully public
    // for days waiting on manual review just because nobody's checked yet.
    try {
      const countRes = await fetch(
        `${SUPABASE_URL}/rest/v1/shared_game_reports?select=id&shared_game_id=eq.${sharedGameId}`,
        { headers: restHeaders({ "Prefer": "count=exact" }) },
      );
      const reportCount = parseContentRangeTotal(countRes);
      if (reportCount >= REPORT_AUTO_HIDE_THRESHOLD) {
        await fetch(`${SUPABASE_URL}/rest/v1/shared_games?id=eq.${sharedGameId}`, {
          method: "PATCH", headers: restHeaders(),
          body: JSON.stringify({ is_hidden: true, hidden_reason: `auto: ${reportCount} reports` }),
        });
        console.log(`[br-community] auto-hid shared_game ${sharedGameId} after ${reportCount} reports`);
      }
    } catch (err) {
      console.error("[br-community] report count/auto-hide check failed:", err);
      // Non-critical — the report itself was already recorded successfully.
    }

    return jsonResp({ success: true });
  }

  // ── delete_shared_game (creator-only unshare) ────────────────────────────
  if (body.action === "delete_shared_game") {
    if (!userJwt) return jsonResp({ error: "Authentication required" }, 401);
    const userId = await resolveUserIdFromJwt(userJwt);
    if (!userId) return jsonResp({ error: "Invalid session" }, 401);

    const sharedGameId = typeof body.shared_game_id === "string" ? body.shared_game_id : null;
    if (!sharedGameId) return jsonResp({ error: "shared_game_id required" }, 400);

    let game: any;
    try {
      const res = await fetch(`${SUPABASE_URL}/rest/v1/shared_games?id=eq.${sharedGameId}&select=id,creator_user_id,player_image_path,enemy_image_path,background_image_path`, { headers: restHeaders() });
      const rows = res.ok ? await res.json() : [];
      game = rows[0] ?? null;
    } catch (err) {
      console.error("[br-community] delete_shared_game lookup network error:", err);
      return jsonResp({ error: "Network error" }, 502);
    }
    if (!game) return jsonResp({ error: "Game not found" }, 404);
    if (game.creator_user_id !== userId) return jsonResp({ error: "Only the creator can unshare this game" }, 403);

    try {
      const deleteRes = await fetch(`${SUPABASE_URL}/rest/v1/shared_games?id=eq.${sharedGameId}`, {
        method: "DELETE", headers: restHeaders(),
      });
      if (!deleteRes.ok) {
        const errText = await deleteRes.text();
        console.error(`[br-community] shared_games delete failed ${deleteRes.status}:`, errText);
        return jsonResp({ error: "Failed to unshare game" }, 502);
      }
    } catch (err) {
      console.error("[br-community] shared_games delete network error:", err);
      return jsonResp({ error: "Network error" }, 502);
    }

    // Storage cleanup after the DB row is gone (not before) — if this fails,
    // the game is already unlisted either way; a few orphaned objects in
    // storage is a minor cleanup item, not a correctness issue.
    await storageDeleteMany([game.player_image_path, game.enemy_image_path, game.background_image_path]);

    console.log(`[br-community] delete_shared_game ok — id=${sharedGameId} user=${userId}`);
    return jsonResp({ success: true });
  }

  // ── admin_list_games ────────────────────────────────────────────────────────
  // Returns every shared game (including hidden ones) plus the per-game report
  // count derived from shared_game_reports. Intended for the in-app admin
  // panel visible only in #if DEBUG builds; server validates BR_ADMIN_CODE
  // regardless of build type so a direct API call without the right code
  // still gets a 403.
  if (body.action === "admin_list_games") {
    const expectedCode = Deno.env.get("BR_ADMIN_CODE");
    if (!expectedCode) return jsonResp({ error: "Admin endpoint not configured on server" }, 503);
    const providedCode = typeof body.admin_code === "string" ? body.admin_code.trim() : "";
    if (!providedCode || providedCode !== expectedCode) return jsonResp({ error: "Invalid admin code" }, 403);

    let games: any[], reports: any[];
    try {
      const [gamesRes, reportsRes] = await Promise.all([
        fetch(`${SUPABASE_URL}/rest/v1/shared_games?select=id,theme_title,premise,is_hidden,hidden_reason,download_count,created_at&order=created_at.desc`, { headers: restHeaders() }),
        fetch(`${SUPABASE_URL}/rest/v1/shared_game_reports?select=shared_game_id`, { headers: restHeaders() }),
      ]);
      games   = gamesRes.ok   ? await gamesRes.json()   : [];
      reports = reportsRes.ok ? await reportsRes.json() : [];
    } catch (err) {
      console.error("[br-community] admin_list_games fetch error:", err);
      return jsonResp({ error: "Failed to load games" }, 502);
    }

    // Count reports per game in JS — avoids PostgREST aggregate syntax
    // differences across Supabase versions and keeps the query simple.
    const reportCounts: Record<string, number> = {};
    for (const row of reports) {
      if (typeof row.shared_game_id === "string") {
        reportCounts[row.shared_game_id] = (reportCounts[row.shared_game_id] ?? 0) + 1;
      }
    }

    const enriched = games.map((g) => ({ ...g, report_count: reportCounts[g.id] ?? 0 }));
    console.log(`[br-community] admin_list_games ok — ${enriched.length} games`);
    return jsonResp({ success: true, games: enriched });
  }

  // ── admin_set_hidden ─────────────────────────────────────────────────────────
  // Manually hide or restore any game. Used by the admin panel to act on
  // reported games without waiting for the auto-hide threshold, or to restore
  // a game that was incorrectly hidden.
  if (body.action === "admin_set_hidden") {
    const expectedCode = Deno.env.get("BR_ADMIN_CODE");
    if (!expectedCode) return jsonResp({ error: "Admin endpoint not configured on server" }, 503);
    const providedCode = typeof body.admin_code === "string" ? body.admin_code.trim() : "";
    if (!providedCode || providedCode !== expectedCode) return jsonResp({ error: "Invalid admin code" }, 403);

    const sharedGameId = typeof body.shared_game_id === "string" ? body.shared_game_id : null;
    if (!sharedGameId) return jsonResp({ error: "shared_game_id required" }, 400);
    const shouldHide = body.hidden === true;
    const reason     = typeof body.reason === "string" ? body.reason.trim().slice(0, 200) : null;

    try {
      const patchRes = await fetch(`${SUPABASE_URL}/rest/v1/shared_games?id=eq.${sharedGameId}`, {
        method: "PATCH",
        headers: restHeaders(),
        body: JSON.stringify({
          is_hidden:     shouldHide,
          hidden_reason: shouldHide ? (reason ?? "admin: manually hidden") : null,
        }),
      });
      if (!patchRes.ok) {
        console.error(`[br-community] admin_set_hidden patch failed ${patchRes.status}`);
        return jsonResp({ error: "Failed to update game" }, 502);
      }
    } catch (err) {
      console.error("[br-community] admin_set_hidden network error:", err);
      return jsonResp({ error: "Network error" }, 502);
    }

    console.log(`[br-community] admin_set_hidden ok — id=${sharedGameId} hidden=${shouldHide}`);
    return jsonResp({ success: true, hidden: shouldHide });
  }

  // ── admin_delete_game ────────────────────────────────────────────────────────
  // Force-delete any shared game and its Storage assets regardless of who
  // created it. Permanent. No soft-delete — if the admin is removing something,
  // it should not be recoverable by anyone without direct DB access.
  if (body.action === "admin_delete_game") {
    const expectedCode = Deno.env.get("BR_ADMIN_CODE");
    if (!expectedCode) return jsonResp({ error: "Admin endpoint not configured on server" }, 503);
    const providedCode = typeof body.admin_code === "string" ? body.admin_code.trim() : "";
    if (!providedCode || providedCode !== expectedCode) return jsonResp({ error: "Invalid admin code" }, 403);

    const sharedGameId = typeof body.shared_game_id === "string" ? body.shared_game_id : null;
    if (!sharedGameId) return jsonResp({ error: "shared_game_id required" }, 400);

    // Fetch the storage paths before deleting the row, so we can clean up
    // Storage even if the row delete succeeds but Storage cleanup fails.
    let game: any;
    try {
      const res  = await fetch(`${SUPABASE_URL}/rest/v1/shared_games?id=eq.${sharedGameId}&select=id,player_image_path,enemy_image_path,background_image_path`, { headers: restHeaders() });
      const rows = res.ok ? await res.json() : [];
      game = rows[0] ?? null;
    } catch (err) {
      console.error("[br-community] admin_delete_game lookup error:", err);
      return jsonResp({ error: "Network error" }, 502);
    }
    if (!game) return jsonResp({ error: "Game not found" }, 404);

    try {
      const delRes = await fetch(`${SUPABASE_URL}/rest/v1/shared_games?id=eq.${sharedGameId}`, {
        method: "DELETE",
        headers: restHeaders(),
      });
      if (!delRes.ok) {
        console.error(`[br-community] admin_delete_game row delete failed ${delRes.status}`);
        return jsonResp({ error: "Failed to delete game" }, 502);
      }
    } catch (err) {
      console.error("[br-community] admin_delete_game row delete network error:", err);
      return jsonResp({ error: "Network error" }, 502);
    }

    // Best-effort Storage cleanup. Row is already gone; orphaned assets are a
    // minor cleanup item, not a correctness issue.
    await storageDeleteMany([game.player_image_path, game.enemy_image_path, game.background_image_path]);

    console.log(`[br-community] admin_delete_game ok — id=${sharedGameId}`);
    return jsonResp({ success: true });
  }

  return jsonResp({ error: `Unknown action: ${body.action}` }, 400);
});
