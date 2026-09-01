// BRAssetGenerationSheetViewController.h
// BrainRotGame
// EZCompleteUI v1.0 — AI Asset Generate / Regenerate / Preview Sheet
//
// Purpose:
//   Replaces the old "type a prompt and Save" sheet for the AI Prompt asset
//   source option. The player types a prompt, taps GENERATE, and sees a
//   live preview of the resulting image right in the sheet. They can
//   REGENERATE (optionally after editing the prompt) as many times as they
//   like — each generation is a paid call, enforced server-side by br-ai's
//   generate_workshop_asset action — and only "Use This Image" commits the
//   currently-shown preview back to the Workshop form.
//
//   This sheet never talks to the network directly. Each GENERATE /
//   REGENERATE tap invokes `generateHandler`, which the presenter (the
//   Custom Workshop view controller) implements using its existing
//   auth/host setup. This keeps the sheet reusable and testable without a
//   network connection.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Invoked once per GENERATE/REGENERATE tap. Call `completion` exactly once,
/// on the main thread, with either the generated image or an error message
/// (never both, never neither). A non-nil `errorMessage` is shown inline in
/// the sheet and re-enables the Generate button; the existing preview (if
/// any) is left untouched so a failed regenerate doesn't lose the last good
/// image.
typedef void (^BRAssetGenerationHandler)(NSString *prompt,
                                          void (^completion)(UIImage * _Nullable image,
                                                              NSString * _Nullable errorMessage));

@interface BRAssetGenerationSheetViewController : UIViewController

/// Builds a ready-to-present generation sheet. Present it with
/// `presentViewController:animated:completion:` from any view controller.
///
/// @param displayName     Human-readable name of the asset being generated,
///                          e.g. "Player Asset", used in the sheet's title.
/// @param costDescription  One-line cost note shown under the title, e.g.
///                          "Each generation costs 3 coins.".
/// @param initialPrompt    Pre-fills the prompt field. Pass nil for empty.
/// @param initialImage     If the slot already has an accepted AI-generated
///                          image (from a previous visit to this sheet),
///                          pass it here so the preview and "Use This Image"
///                          / "Regenerate" buttons are shown immediately.
///                          Pass nil if there's nothing to preview yet.
/// @param generateHandler  Called for every GENERATE/REGENERATE tap.
/// @param onAccept         Called once, when the player taps "Use This
///                          Image", with the currently-previewed image and
///                          the prompt that produced it. Not called if the
///                          player dismisses without accepting — any paid
///                          generations made along the way are not refunded,
///                          but also aren't applied to the Workshop form.
+ (instancetype)sheetForAssetDisplayName:(NSString *)displayName
                          costDescription:(NSString *)costDescription
                            initialPrompt:(nullable NSString *)initialPrompt
                             initialImage:(nullable UIImage *)initialImage
                          generateHandler:(BRAssetGenerationHandler)generateHandler
                                 onAccept:(void (^)(UIImage *image, NSString *prompt))onAccept;

@end

NS_ASSUME_NONNULL_END
