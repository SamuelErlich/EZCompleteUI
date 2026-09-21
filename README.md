# EZCompleteUI

EZCompleteUI is a native iOS AI workspace built with Objective-C and Theos. It combines coin-metered AI chat, image generation and editing, transcription, voice tools, local thread history, searchable memories, a photo gallery, and a custom game-creation area in one app.

The current checkout is the independent **0.1.0 beta** and targets iOS 15.0 and later. Its bundle identifier is \`com.gabriel.ezcomplete.beta\`.

## What it includes

- Authenticated, server-authoritative beta credits with a balance display and append-only usage ledger.
- Persistent chats with local thread restore, inline image attachments, generated-image grids, code blocks, and Quick Look previews, as well as shareable file creations including pdf, csv, rtf, with inline previews.
- AI memory: conversations are summarized, searchable, editable, and can retain attachment references.
- Image gallery: view generated images, ask about an image, edit it with AI, share or delete it, or pass it into the custom game workflow.
- Image generation and editing with configurable size, quality, output format, background, and moderation settings where supported.
- File and vision workflows for images, PDFs, ePub, text, HTML, RTF, CSV, and JSON files.
- Apple speech dictation, Whisper transcription, Apple text-to-speech, ElevenLabs text-to-speech, and ElevenLabs voice-clone management.
- Text to Speech library where all your TTS generations live.  You can replay or export them, re-order them, and even edit the audio files, maximizing volume, adding effects like reverb and echo, and you can combine multiple files into one.
- Web search toggle with an optional location hint.
- BrainRot custom-game creation, saved games, game library/picker, and community/admin game tools.
- In-app Terms, Privacy, Refund, and Support/Feedback screens.

## Model picker

The picker is the source of truth for models exposed by the app.

| Group | Models |
| --- | --- |
| Frontier reasoning | `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5-pro`, `gpt-5`, `gpt-5-mini` |
| GPT-4 chat | `gpt-4o`, `gpt-4o-mini`, `gpt-4-turbo`, `gpt-4`, `gpt-3.5-turbo` |
| Image generation | `gpt-image-2`, `gpt-image-1.5`, `gpt-image-1`, `gpt-image-1-mini` |
| Audio transcription | `whisper-1` |

`gpt-6-astra` is shown as the newest frontier model. The GPT-5.6 variants are presented as full, balanced, and fast/cheap choices. Image models can generate new images; the `gpt-image-*` family also supports the app’s attachment-driven editing flow. `whisper-1` is transcription-only and is not used as a chat model.

## Using the app

1. Sign in and accept the in-app terms.
2. Claim the one-time server test grant from the beta coin screen. Real payments are disabled.
3. Choose a model from the model button. 
4. When generaring or editing an image, check the image settings (little button that appears next to the model picker when an image model is active).  You can set the number of variations to generate, image quality, moderation level, background and file type.
5. Send a prompt, or attach an image/file with the attachment control.
6. Use the history drawer to restore chats and the Memories view to search or edit retained summaries.

Image attachments are stored locally and reconstructed in their original thread position when the thread is restored. Generated and edited images are also kept in the photo gallery.

## Local data

The app keeps its local working data in the app Documents directory:

| Path | Purpose |
| --- | --- |
| `EZThreads/` | Saved conversation JSON files |
| `EZAttachments/` | Attached, generated, edited, and restored files |
| `ezui_memory.json` | Memory summaries and attachment references |
| `ezui_system.log` | System diagnostic log |
| `ezui_helper.log` | Helper/routing diagnostic log |

Authenticated requests, entitlement checks, beta grants, and usage logging are handled through the new project’s Supabase edge functions. Real PayPal, Pix and card payments are intentionally disabled until provider webhooks and idempotency tests are complete.

## Building from source

Requirements:

- macOS with Xcode and Command Line Tools
- [Theos](https://theos.dev/docs/installation)
- iPhoneOS SDK compatible with the configured Theos target

For a development build:

```sh
make
```

For the packaged IPA and rootless `.deb` workflow:

```sh
./build.sh
```

The build script stages the app, applies the required microphone, speech-recognition, and document-access usage descriptions to the staged plist, creates `EZCompleteUI.ipa`, and packages the rootless Debian archive.

### Build without a Mac

The repository includes `.github/workflows/build-rootless.yml`. After pushing the
source to GitHub, open **Actions → Build rootless beta package → Run workflow**.
The workflow uses a hosted macOS runner, installs Theos and the iPhoneOS SDKs,
and publishes the generated `.deb` and `.ipa` as downloadable artifacts. Upload
the generated `.deb` to YouRepo only after testing that package on the device.

## Project layout

```text
EZCompleteUI/
├── ViewController.m                         # Main chat UI, model routing, attachments
├── helpers.m                                # Threads, memory, attachments, logging, context routing
├── EZModelPickerViewController.m            # Current model picker sections and labels
├── EZImageGridCell.m                        # Inline generated-image presentation
├── EZPhotoGalleryViewController.m           # Generated-image gallery and actions
├── MemoriesViewController.m                 # Searchable/editable memory browser
├── EZCoin*.m / EZEntitlementManager.*       # Coin store, ledgers, and entitlement client
├── TextToSpeechViewController.m             # Text-to-speech UI
├── ElevenLabsCloneViewController.m          # Voice clone management
├── BrainRotViewController.m                 # Custom game workflow entry point
├── BR*.m                                    # Game editor, model, library, and related views
├── Resources/Info.plist                     # Bundle metadata
├── Makefile                                 # Theos target and source list
└── build.sh                                 # IPA and rootless .deb packaging workflow
```

## Troubleshooting

**A feature says there are not enough coins**

This beta only accepts the one-time server grant. If the button says that the account is waiting for approval, add the user UUID to `beta_testers` in the new Supabase project; real purchases and subscriptions are disabled.

**API Error: The token is invalid**
Close the app and reopen it, or sign out and sign back in from settings.

**The network request timed out. **
Check your network connection, cellular signal, etc.  Check for auto-retry attempts, then try again if needed, 


**Dictation is unavailable**

Enable Microphone and Speech Recognition access for EZCompleteUI in iOS Settings.

**A file cannot be previewed**

Confirm it was fully saved under `EZAttachments/`, then reopen the associated chat or memory entry. Quick Look is used for supported previews.

## License

MIT License — see [LICENSE](LICENSE).
