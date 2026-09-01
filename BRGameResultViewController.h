// BRGameResultViewController.h
// BrainRotGame
// EZCompleteUI v2.0 — Custom Workshop / Saved-Game / Community-Preview Result Screen
//
// Purpose:
//   Reveal-card screen used by three flows:
//     1. Custom Workshop — shown immediately after generating a new game.
//        Starts in a "Finalizing your world..." busy state; the presenter
//        calls markReadyWithRecord: once BRGameLibrary finishes writing the
//        game, which replaces the busy state with a PLAY button.
//     2. An already-saved or just-downloaded game — the presenter calls
//        markReadyWithRecord: immediately, so PLAY appears right away with
//        no busy state at all.
//     3. A community game NOT YET downloaded (resultControllerForCommunityPreview...)
//        — title/premise/thumbnails are shown immediately using already-known
//        preview data (no network wait), but the primary button reads
//        DOWNLOAD instead of PLAY. Tapping it invokes the presenter-supplied
//        downloadHandler; while that's in flight the screen shows a busy
//        state ("Downloading your game..."), and on success it transitions
//        itself into the same PLAY state as flow #2 (internally calling
//        markReadyWithRecord: with the newly-created record) — no second
//        screen, no re-presentation, the same card just changes what its
//        button does. On failure, an inline message appears and the button
//        reverts to DOWNLOAD so the player can retry.
//
//   In all three flows, a secondary "Maybe Later" action lets the player
//   back out without committing — except mid-generation (flow #1, while
//   busy) and mid-download (flow #3, while busy), where there is nothing
//   sensible to back out of mid-flight.
//
//   This screen never talks to BRGameLibrary or the gameplay view
//   controller directly — it only reports what the player tapped via its
//   callback blocks (the same way BRGamePickerViewController reports
//   selections via `onSelection`), and for downloads, calls a presenter-
//   supplied handler block rather than doing any networking itself. The
//   presenter owns navigation and all networking/persistence.

#import <UIKit/UIKit.h>

@class BRGameRecord;

NS_ASSUME_NONNULL_BEGIN

/// Supplied by the presenter for community-preview screens (flow #3 above).
/// Called once, the moment the player taps DOWNLOAD. The implementation
/// should perform the actual network download and local save (e.g. via
/// BRGameLibrary), then call `completion` exactly once, on the main thread:
///   - completion(record, nil)               on success
///   - completion(nil, "readable message")   on failure — the screen shows
///                                             this message inline and
///                                             reverts to DOWNLOAD so the
///                                             player can retry
typedef void (^BRGameResultDownloadHandler)(void (^completion)(BRGameRecord * _Nullable record,
                                                                  NSString * _Nullable errorMessage));

@interface BRGameResultViewController : UIViewController

/// Builds a ready-to-push/present result screen for flows #1 and #2 (Custom
/// Workshop generation, or an already-known local/downloaded record).
/// `premise` and the asset images may all be nil — the layout degrades
/// gracefully (a placeholder message for a missing premise, hidden
/// thumbnails for missing assets, and the themed background color in place
/// of a background image). Starts in the busy ("Finalizing your world...")
/// state; call markReadyWithRecord: to reveal PLAY, or call it immediately
/// after construction (before presenting) if the record is already known.
+ (instancetype)resultControllerWithTitle:(NSString *)gameTitle
                                   premise:(nullable NSString *)premise
                               playerImage:(nullable UIImage *)playerImage
                                enemyImage:(nullable UIImage *)enemyImage
                           backgroundImage:(nullable UIImage *)backgroundImage;

/// Builds a result screen for flow #3 — a community game not yet
/// downloaded. Title and premise are shown immediately (no network wait,
/// since they're already known from list_shared_games); the three asset
/// images are loaded asynchronously from the given signed URLs via
/// BRRemoteImageLoader and pop in as they arrive, but loading them is not a
/// precondition for tapping DOWNLOAD. Any of the three URL strings may be
/// nil — that thumbnail/background slot is simply left empty, same
/// graceful-degradation behavior as the UIImage-based factory above.
+ (instancetype)resultControllerForCommunityPreviewWithTitle:(NSString *)gameTitle
                                                       premise:(nullable NSString *)premise
                                          playerImageURLString:(nullable NSString *)playerImageURLString
                                           enemyImageURLString:(nullable NSString *)enemyImageURLString
                                      backgroundImageURLString:(nullable NSString *)backgroundImageURLString
                                               downloadHandler:(BRGameResultDownloadHandler)downloadHandler;

/// Call once BRGameLibrary has finished writing the game to disk — either
/// right after construction (flow #2, no busy state ever shown) or later,
/// once generation completes (flow #1). Replaces whatever the screen was
/// showing with the PLAY button and stores `record` so `onPlayTapped` can
/// hand it back. Safe to call before the view has appeared (or even been
/// loaded) — the ready state will simply be reflected immediately once it
/// is. Also used internally by the community-preview flow (#3) once its
/// downloadHandler succeeds — callers of that factory don't need to call
/// this themselves.
- (void)markReadyWithRecord:(BRGameRecord *)record;

/// Fired when the player taps PLAY — never fires for DOWNLOAD taps (those
/// invoke the downloadHandler supplied at construction instead). Only
/// enabled after markReadyWithRecord: has supplied a record (whether
/// supplied directly by the presenter or internally after a successful
/// download), so `record` here is always that same instance. The presenter
/// is responsible for dismissing this screen (and whatever's beneath it)
/// and transitioning into gameplay.
@property (nonatomic, copy, nullable) void (^onPlayTapped)(BRGameRecord *record);

/// Fired when the player taps "Maybe Later". The presenter is responsible
/// for dismissing this screen and whatever's beneath it, the same way it
/// would after a normal Cancel. Not available while a busy state (generating
/// or downloading) is showing — there's nothing sensible to back out of
/// mid-flight in either case.
@property (nonatomic, copy, nullable) void (^onMaybeLaterTapped)(void);

@end

NS_ASSUME_NONNULL_END
