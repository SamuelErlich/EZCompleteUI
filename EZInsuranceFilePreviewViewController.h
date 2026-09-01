// EZInsuranceFilePreviewViewController.h
// EZCompleteUI
//
// Purpose:
//   Custom full-screen preview for an image or video attachment — title
//   centered at top, content in the middle (zoomable for images, standard
//   playback controls for video via AVPlayerViewController), notes in a
//   card at the bottom when present. Replaces QLPreviewController for
//   these two types specifically; QuickLook is still used as a fallback
//   for anything else (PDFs, documents) where a custom layout doesn't
//   make sense.
//
//   Deliberately no swipe-to-dismiss gesture — it would conflict with the
//   image scroll view's own pan/zoom handling if not done carefully.
//   Close button only, for now.
//
// Changes:
//   - Initial version.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZInsuranceFilePreviewViewController : UIViewController

/// fileURL must be a local file (this doesn't download anything itself —
/// the caller already did that for tap-to-preview). mimeType decides
/// image vs. video rendering; pass the real mime_type from the file
/// record. notes is shown in a bottom card only when non-empty.
- (instancetype)initWithFileURL:(NSURL *)fileURL
                        mimeType:(nullable NSString *)mimeType
                            title:(NSString *)title
                            notes:(nullable NSString *)notes;

@end

NS_ASSUME_NONNULL_END
