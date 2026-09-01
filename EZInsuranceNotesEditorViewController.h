// EZInsuranceNotesEditorViewController.h
// EZCompleteUI
//
// Purpose:
//   Small dedicated screen for editing a file's notes — a real UITextView
//   with Cancel/Save bar buttons, not a UIAlertController text field.
//   Alerts are for confirmations and important warnings; multi-line notes
//   ("why this file matters, what to look for") deserve actual editing
//   room, which a single-line alert text field can't give.
//
// Changes:
//   - Initial version.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZInsuranceNotesEditorViewController : UIViewController

/// completion is called with the trimmed notes text (nil if left empty)
/// after Save is tapped, or not at all if Cancel is tapped. Present this
/// wrapped in a UINavigationController — it sets its own bar buttons and
/// relies on having a navigation bar to put them in.
- (instancetype)initWithFilename:(NSString *)filename
                    existingNotes:(nullable NSString *)existingNotes
                       completion:(void (^)(NSString * _Nullable updatedNotes))completion;

@end

NS_ASSUME_NONNULL_END
