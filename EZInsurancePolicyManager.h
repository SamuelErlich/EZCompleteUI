// EZInsurancePolicyManager.h
// EZCompleteUI
//
// Purpose:
//   Backend access point for the "Insurance Policy" dead-man's-switch
//   feature. Wraps every insurance_policies / insurance_policy_files /
//   storage call behind one class so no other file talks to those tables
//   or that storage bucket directly — same "one owner per resource"
//   pattern as EZEntitlementManager owns ez_usage_log.
//
//   Deliberately independent of EZAttachmentSave() and the chat
//   attachment pipeline — insurance files live in their own storage
//   bucket and their own table, never mixed with chat attachments, per
//   the plan for this to eventually ship as its own app. The only thing
//   this class borrows from the rest of EZCompleteUI is the signed-in
//   session via [EZAuthManager shared] — nothing else.
//
//   Every mutating call below (check-in, send-now, cancel) requires the
//   POLICY password, not just an authenticated session. That's enforced
//   server-side (see insurance_policy_schema.sql) — this class just
//   passes the password through, it doesn't and can't bypass the check.
//
// Changes from v1:
//   - Removed the single-active-policy assumption: fetchActivePolicyWith
//     Completion: replaced with listPoliciesWithCompletion:, since users
//     can now run more than one policy at a time.
//   - createPolicyWithPassword:targetEmail:frequencyHours:completion: lost
//     its targetEmail parameter — recipients are now added separately
//     (possibly several, via "add extra recipient") through the new
//     addRecipientEmail:policyID:completion: / listRecipientsForPolicyID:
//     completion: / deleteRecipientWithID:completion: methods.
//   - sendNowPolicyID:password:completion: now also reports how many
//     recipients were actually sent to, since a policy can have more
//     than one and a partial send is a real possible outcome.
//   - createPolicyWithPassword:frequencyHours:completion: gained a
//     clientRequestID parameter — required now, not optional — so a
//     retried create request (e.g. after a client-side timeout on an
//     actually-successful call) can't create a duplicate policy.
//   - Every failure path now logs the raw HTTP status/body (or, for a
//     genuine network-level failure, the NSError domain/code) via
//     EZLogf under the "INSURANCE" tag, instead of only surfacing the
//     user-facing friendly string.
//   - Added downloadFileWithStoragePath:originalFilename:completion: —
//     downloads a file's real bytes to a local temp file (named after
//     the original filename so extension-based type detection works),
//     for the new tap-to-preview feature in the detail screen. No new
//     backend permission needed: storage RLS already lets the owner
//     read their own objects directly, this is just an authenticated GET.
//   - uploadFileAtURL:policyID:progress:completion: gained a thumbnail
//     parameter (now uploadFileAtURL:policyID:thumbnail:progress:
//     completion:) — when provided, a small JPEG is uploaded alongside
//     the main file and its path saved as thumbnail_storage_path, so a
//     policy opened later can show real thumbnails without downloading
//     full files. Added downloadThumbnailDataWithStoragePath:completion:
//     to fetch those back (raw NSData, no temp file needed — these are
//     small). Requires insurance_policy_files.thumbnail_storage_path,
//     added to insurance_policy_schema.sql.
//   - Added backfillThumbnailImage:forFileID:policyID:completion: — lets a
//     file that predates thumbnail_storage_path get one added after the
//     fact (uploaded, then PATCHed onto its row). Server restricts the
//     PATCH to that one column via a GRANT — see
//     insurance_policy_schema.sql.
//   - THE false-failure bug, actually fixed: every JSON parse in this file
//     was missing NSJSONReadingAllowFragments. PostgREST returns scalar
//     RPC results (booleans from checkin/cancel/claim, a bare uuid string
//     from create) as a raw top-level JSON value, not wrapped in {} or
//     []. NSJSONSerialization refuses to parse a bare fragment without
//     that option and silently returns nil — so every one of those calls
//     ALWAYS looked like it failed to parse, on every single request,
//     regardless of network conditions. This was never a timing/cold-start
//     issue; the timeout increase and idempotency-key fixes from earlier
//     were real improvements but not the cause of the "works but shows an
//     error" reports. This is.
//   - Added renameFileWithID:newFilename:completion: and
//     updateNotesForFileID:notes:completion: — simple PATCHes onto the
//     same "Owners can edit their files while active" grant thumbnail
//     backfill already uses, restricted server-side to exactly those
//     columns.
//   - downloadFileWithStoragePath:originalFilename:completion: gained a
//     mimeType parameter (now ...originalFilename:mimeType:completion:).
//     Fixes a real bug: originalFilename is user-editable now (rename)
//     and can end up with no extension at all, in which case
//     QLPreviewController has nothing to go on and shows a generic "Data"
//     placeholder instead of the actual file. mime_type is never
//     user-editable, so it's used to derive a real extension when the
//     (possibly renamed) filename doesn't have one.
//
// View controllers for setup/landing/countdown are still not part of this
// pass — this remains backend access only.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h> // UIImage, used by uploadFileAtURL:policyID:thumbnail:progress:completion:

NS_ASSUME_NONNULL_BEGIN

/// Upload progress, 0.0–1.0. Always called on the main queue.
typedef void (^EZInsuranceUploadProgress)(double fractionComplete);

@interface EZInsurancePolicyManager : NSObject

+ (instancetype)shared;

// ── Policy lifecycle ──────────────────────────────────────────────────────

/// Creates a new active policy for the signed-in user. No recipients yet —
/// call addRecipientEmail:policyID:completion: at least once afterward, or
/// sendNowPolicyID:password:completion: and the scheduled release will both
/// refuse to send with an empty recipient list. Fails with a clear message
/// if the password is under 8 characters.
///
/// clientRequestID must be the SAME value across every retry of one
/// logical "create" attempt (generate one NSUUID when the create screen
/// appears, not a fresh one per tap) — the server uses it to recognize a
/// retry after a client-side timeout and return the already-created policy
/// instead of creating a duplicate. A fresh NSUUID per call defeats this
/// entirely, so don't regenerate it inside a retry handler.
- (void)createPolicyWithPassword:(NSString *)password
                   frequencyHours:(NSInteger)frequencyHours
                   clientRequestID:(NSString *)clientRequestID
                       completion:(void (^)(NSString * _Nullable policyID,
                                            NSString * _Nullable errorMessage))completion;

/// Lists every policy belonging to the signed-in user, most recently
/// created first, in any status. Use this to drive "Update Existing
/// Policy" (there's no cap on how many a user can have) and to compute
/// each countdown display from last_checkin_at / frequency_hours.
- (void)listPoliciesWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable policies,
                                              NSString * _Nullable errorMessage))completion;

/// Resets the countdown. Requires the policy password — an authenticated
/// session alone is not sufficient, by design.
- (void)checkInPolicyID:(NSString *)policyID
                password:(NSString *)password
              completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;

/// Immediately emails all uploaded files to every recipient on the policy
/// and marks it released. Irreversible. Requires the policy password.
///
/// If some recipients succeed and others don't, success is NO but the
/// ones that succeeded will not be re-emailed on a later retry — only
/// recipientsSent is a reliable count of what happened this call;
/// checking listRecipientsForPolicyID: is the source of truth for who's
/// been sent to overall.
- (void)sendNowPolicyID:(NSString *)policyID
                password:(NSString *)password
              completion:(void (^)(BOOL success,
                                    NSInteger filesSent,
                                    NSInteger recipientsSent,
                                    NSString * _Nullable errorMessage))completion;

/// Cancels the policy without sending anything. Requires the policy
/// password.
- (void)cancelPolicyID:(NSString *)policyID
                password:(NSString *)password
              completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;

// ── Recipients ─────────────────────────────────────────────────────────────
// No password required to add/list/remove — same reasoning as files: this
// only affects who's on the list before anything has actually been sent,
// gated by plain account ownership + the policy still being active.

/// Adds one recipient ("add extra recipient" button — call this again for
/// each additional one). Rejects an already-added email on this policy.
- (void)addRecipientEmail:(NSString *)email
                  policyID:(NSString *)policyID
                completion:(void (^)(NSDictionary * _Nullable recipientRecord,
                                      NSString * _Nullable errorMessage))completion;

/// Lists every recipient on a policy. Each dictionary's "sent_at" is null
/// until that recipient has actually received the release email — useful
/// for showing partial-send state after a retry.
- (void)listRecipientsForPolicyID:(NSString *)policyID
                        completion:(void (^)(NSArray<NSDictionary *> * _Nullable recipients,
                                              NSString * _Nullable errorMessage))completion;

/// Removes a recipient. recipientID comes from a dictionary returned by
/// listRecipientsForPolicyID:.
- (void)deleteRecipientWithID:(NSString *)recipientID
                     policyID:(NSString *)policyID
                   completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;

// ── Files ──────────────────────────────────────────────────────────────────

/// Uploads a single file (already on disk — pass the URL from a document
/// picker) to the policy's storage folder and registers it in
/// insurance_policy_files. Streams from disk rather than loading the whole
/// file into memory, since these can be up to 35MB.
///
/// Rejects anything over 35MB before starting the network request.
///
/// thumbnail, if provided, is uploaded as a small separate JPEG alongside
/// the main file — this is what lets a policy opened later show real
/// thumbnails without downloading full files just to render a row. Pass
/// nil for file types that don't have one (see
/// ez_generateThumbnailForLocalURL:completion: in the detail view
/// controller). A failed thumbnail upload never fails the main upload —
/// worst case that row falls back to a generic icon.
- (void)uploadFileAtURL:(NSURL *)fileURL
               policyID:(NSString *)policyID
              thumbnail:(nullable UIImage *)thumbnail
               progress:(nullable EZInsuranceUploadProgress)progress
             completion:(void (^)(NSDictionary * _Nullable fileRecord,
                                   NSString * _Nullable errorMessage))completion;

/// Lists all files currently attached to a policy.
- (void)listFilesForPolicyID:(NSString *)policyID
                   completion:(void (^)(NSArray<NSDictionary *> * _Nullable files,
                                         NSString * _Nullable errorMessage))completion;

/// Removes a single file. fileID and storagePath both come from a
/// dictionary returned by listFilesForPolicyID: — pass them straight
/// through, don't reconstruct storagePath yourself.
- (void)deleteFileWithID:(NSString *)fileID
              storagePath:(NSString *)storagePath
               completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;

/// Renames a file (its display name, not the underlying storage object).
- (void)renameFileWithID:(NSString *)fileID
              newFilename:(NSString *)newFilename
               completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;

/// Sets or clears a file's notes. Pass nil to clear.
- (void)updateNotesForFileID:(NSString *)fileID
                        notes:(nullable NSString *)notes
                   completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;

/// Downloads a file's actual bytes to a local temp file, named after
/// originalFilename so callers that care about the file extension (e.g.
/// QLPreviewController's type detection) get a usable name. The caller
/// owns the returned file afterward — delete it when done with it.
///
/// originalFilename is user-editable (rename) and can end up with no
/// extension at all — pass mimeType (from the same file record,
/// never user-editable) so a real extension can be derived from it in
/// that case instead of QuickLook falling back to a generic, useless
/// preview. Pass nil if you don't have it; the fallback is just skipped.
- (void)downloadFileWithStoragePath:(NSString *)storagePath
                     originalFilename:(NSString *)originalFilename
                             mimeType:(nullable NSString *)mimeType
                          completion:(void (^)(NSURL * _Nullable localFileURL,
                                                NSString * _Nullable errorMessage))completion;

/// Downloads a thumbnail's raw JPEG bytes directly (no temp file — these
/// are small, ~10-20KB). storagePath comes from a file record's
/// thumbnail_storage_path; nil/empty for files that don't have one.
- (void)downloadThumbnailDataWithStoragePath:(NSString *)storagePath
                                   completion:(void (^)(NSData * _Nullable jpegData,
                                                         NSString * _Nullable errorMessage))completion;

/// For a file that doesn't have a thumbnail yet (uploaded before
/// thumbnail_storage_path existed) — uploads the given image as its
/// thumbnail and saves the path on that file's row. Restricted server-side
/// to only ever touch thumbnail_storage_path on that one row, via a
/// column-level GRANT — see insurance_policy_schema.sql.
- (void)backfillThumbnailImage:(UIImage *)thumbnail
                       forFileID:(NSString *)fileID
                        policyID:(NSString *)policyID
                      completion:(void (^)(NSString * _Nullable thumbnailStoragePath,
                                            NSString * _Nullable errorMessage))completion;

@end

NS_ASSUME_NONNULL_END
