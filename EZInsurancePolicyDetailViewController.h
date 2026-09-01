// EZInsurancePolicyDetailViewController.h
// EZCompleteUI
//
// Purpose:
//   Handles both halves of the Insurance Policy feature in one screen:
//
//   NEW (initWithPolicy:nil) — password + confirm password, a check-in
//   frequency picker, and a "Create Policy" button. Once created, the
//   files/recipients sections below unlock for that new policy — same as
//   the EXISTING case, just arrived at differently.
//
//   EXISTING (initWithPolicy:<dict>) — live countdown, file list with
//   upload, recipient list with add, and the three password-gated actions
//   (Check In / Send Now / Cancel Policy).
//
//   Kept as one class rather than two so the files/recipients management
//   UI — identical in both cases — is written exactly once.
//
// Changes:
//   - Initial version.
//   - Added createRequestID, generated once per "new policy" screen
//     instance and passed through to createPolicyWithPassword:
//     frequencyHours:clientRequestID:completion: on every tap of Create
//     (including retries) — closes a duplicate-policy bug where a
//     client-side timeout on an actually-successful create made retrying
//     produce a second policy instead of recognizing the retry.
//   - "Add Files" now offers a source choice (action sheet): Photos or
//     Videos via PHPickerViewController (no photo-library permission
//     needed — it runs out-of-process and only hands back what the user
//     actually picked), or Files via the existing UIDocumentPickerViewController.
//     Both funnel into the same ez_beginUploadForFileURL:, so upload
//     progress/error handling is written once regardless of source.
//   - Each file row now shows a thumbnail and is tappable to open a
//     full-screen preview via QLPreviewController (native — handles
//     images, video, PDFs, docs, with its own built-in dismiss gesture).
//     Row thumbnails are real image/video frames for files uploaded THIS
//     session (generated from the local file before upload, cached in
//     memory); files loaded from an existing policy show a generic
//     type icon instead rather than downloading the whole file just to
//     render a list row. The tap-to-preview download works for every
//     file either way, real thumbnail or not — see
//     downloadFileWithStoragePath:originalFilename:completion: on
//     EZInsurancePolicyManager.
//   - Thumbnails now also load for files from an EXISTING policy, not just
//     ones uploaded this session: each upload now also saves a small
//     separate JPEG (thumbnail_storage_path) server-side, and opening a
//     policy fetches those — memory cache, then disk cache
//     (NSCachesDirectory, survives relaunch), then network, in that order
//     — instead of the generic icon this used to always show for
//     already-uploaded files. See ez_loadThumbnailsForCurrentFiles.
//   - Files that still don't have a thumbnail (uploaded before
//     thumbnail_storage_path existed) get one generated the first time
//     they're tapped to preview — reusing that download rather than a
//     separate fetch — cached locally immediately and best-effort saved
//     back to the server, so it only ever needs tapping once, not once
//     per device. See ez_backfillThumbnailFromDownloadedFile:forRecord:.
//   - File rows can now be renamed (inline text field, tap "Rename" from
//     a new "•••" menu) and given free-form notes (a dedicated
//     UITextView screen, "Edit Notes" from that same menu) — both real
//     editing UI, deliberately not UIAlertController text fields. Notes
//     show as a small italic preview line under the filename when set.
//   - Delete moved into the "•••" menu and now has a confirmation step
//     first — it used to delete on a single tap with no "are you sure,"
//     a real latent risk worth closing while restructuring this row
//     anyway.
//   - Tap-to-preview now opens EZInsuranceFilePreviewViewController (a
//     custom immersive viewer — title, zoomable image or video player,
//     notes card) for image/video files instead of QLPreviewController.
//     QuickLook remains the fallback for everything else (PDFs, docs).
//   - The "•••" menu is now a native UIMenu instead of a
//     UIAlertController action sheet — less code, more current pattern.
//     Delete's confirmation is still a real alert, appropriately.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZInsurancePolicyDetailViewController : UIViewController

/// Pass nil to start the "create a new policy" flow, or a policy
/// dictionary (as returned by EZInsurancePolicyManager) to manage an
/// existing one.
- (instancetype)initWithPolicy:(nullable NSDictionary *)policy;

@end

NS_ASSUME_NONNULL_END
