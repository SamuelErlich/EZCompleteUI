// BRTextInputSheetViewController.h
// BrainRotGame
// EZCompleteUI v1.0 — Reusable Text Input Bottom Sheet
//
// Purpose:
//   A themed bottom-sheet replacement for UIAlertController's plain text
//   field alert. Use it any time the player needs to type or edit a short
//   line of text (a title) or a longer block of text (a story premise, an
//   AI image prompt, etc).
//
//   The sheet shows a title, optional subtitle/helper text, and a styled
//   text field. When a character limit is supplied it also shows a live
//   "x / limit" counter and stops the player from typing past the limit.
//   It reports back through `completion` whether the player saved or
//   cancelled, so the caller never has to guess.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Outcome of presenting a BRTextInputSheetViewController.
typedef NS_ENUM(NSInteger, BRTextInputSheetResult) {
    /// The player tapped Cancel, or dismissed the sheet by swiping it away.
    /// `resultText` will be nil — the caller should leave its state untouched.
    BRTextInputSheetResultCancelled,

    /// The player tapped Save. `resultText` holds the trimmed text, which
    /// may be an empty string if the player cleared the field entirely.
    /// Callers should treat an empty saved string as "reset to default".
    BRTextInputSheetResultSaved
};

/// Called once, after the sheet has finished dismissing itself.
typedef void (^BRTextInputSheetCompletion)(BRTextInputSheetResult result, NSString * _Nullable resultText);

@interface BRTextInputSheetViewController : UIViewController

/// Builds a ready-to-present text input sheet. Present it with
/// `presentViewController:animated:completion:` from any view controller.
///
/// @param title           Large header shown at the top of the sheet.
/// @param subtitle        Optional helper text shown under the title. Pass
///                         nil to hide it.
/// @param initialText     Existing value to pre-fill, or nil for an empty field.
/// @param placeholder     Placeholder text shown while the field is empty.
/// @param multiline       YES for a taller, scrollable text view suited to
///                         premises and AI prompts. NO for a compact
///                         single-line field suited to short titles — in
///                         single-line mode the Return key behaves like
///                         tapping Save.
/// @param characterLimit  Maximum character count to enforce, or 0 for no
///                         limit. When non-zero, a live "x / limit" counter
///                         is shown and further typing is blocked once the
///                         limit is reached (deleting always remains possible).
/// @param completion      Invoked exactly once after the sheet is dismissed.
+ (instancetype)sheetWithTitle:(NSString *)title
                       subtitle:(nullable NSString *)subtitle
                    initialText:(nullable NSString *)initialText
                    placeholder:(nullable NSString *)placeholder
                      multiline:(BOOL)multiline
                 characterLimit:(NSInteger)characterLimit
                     completion:(BRTextInputSheetCompletion)completion;

@end

NS_ASSUME_NONNULL_END
