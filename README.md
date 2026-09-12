# EZCompleteUI

EZCompleteUI is a native iOS AI workspace built with Objective-C and Theos. It combines coin-metered AI chat, image generation and editing, transcription, voice tools, local thread history, searchable memories, a photo gallery, and a custom game-creation area in one app.

The current release is **7.0.7** and targets iOS 15.0 and later.

## What it includes

- Authenticated, coin-based access with a coin store, balance display, user usage ledger, and admin cost ledger.
- Persistent chats with local thread restore, inline image attachments, generated-image grids, code blocks, and Quick Look previews.
- AI memory: conversations are summarized, searchable, editable, and can retain attachment references.
- Image gallery: view generated images, ask about an image, edit it with AI, share or delete it, or pass it into the custom game workflow.
- Image generation and editing with configurable size, quality, output format, background, and moderation settings where supported.
- File and vision workflows for images, PDFs, ePub, text, HTML, RTF, CSV, and JSON files.
- Apple speech dictation, Whisper transcription, Apple text-to-speech, ElevenLabs text-to-speech, and ElevenLabs voice-clone management.
- Web search toggle with an optional location hint.
- BrainRot custom-game creation, saved games, game library/picker, and community/admin game tools.
- In-app Terms, Privacy, Refund, and Support/Feedback screens.

## Model picker

The picker is the source of truth for models exposed by the app.

| Group | Models |
| --- | --- |
| Frontier reasoning | `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5-pro`, `gpt-5`, `gpt-5-mini` |
| GPT-4 chat | `gpt-4o`, `gpt-4o-mini`, `gpt-4-turbo`, `gpt-4`, `gpt-3.5-turbo` |
| Image generation | `gpt-image-2`, `gpt-image-1.5`, `gpt-image-1`, `gpt-image-1-mini`, `chatgpt-image-latest`, `dall-e-3` |
| Audio transcription | `whisper-1` |

`gpt-6-astra` is shown as the newest frontier model. The GPT-5.6 variants are presented as full, balanced, and fast/cheap choices. Image models can generate new images; the `gpt-image-*` family also supports the app’s attachment-driven editing flow. `whisper-1` is transcription-only and is not used as a chat model.

## Using the app

1. Sign in and accept the in-app terms.
2. Add coins or manage your subscription from Settings or the coin balance control.
3. Choose a model from the model button.
4. Send a prompt, or attach an image/file with the attachment control.
5. Use the history drawer to restore chats and the Memories view to search or edit retained summaries.

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

Authenticated requests, entitlement checks, billing, and usage logging are handled through the project’s Supabase edge functions. API costs and coin deductions are recorded in the appropriate usage ledgers.

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

**Images or attachments are blank after restoring a chat**

Open the thread again after updating. Current builds resolve attachment filenames against the local attachment store and restore generated-image events from the ordered thread timeline. Files that no longer exist on the device cannot be recreated locally.

**A feature says there are not enough coins**

Open the coin store, add coins or manage the subscription, then retry. The user usage ledger shows credits and deductions; administrators can use the admin ledger for API cost and cost-basis detail.

**Dictation is unavailable**

Enable Microphone and Speech Recognition access for EZCompleteUI in iOS Settings.

**A file cannot be previewed**

Confirm it was fully saved under `EZAttachments/`, then reopen the associated chat or memory entry. Quick Look is used for supported previews.

## License

MIT License — see [LICENSE](LICENSE).
