// BRCustomGameCreatorViewController.h
// BrainRotGame
// EZCompleteUI v1.5 — Custom Workshop Component
//
// Changes from v1.4:
//   - Added onPlayRequested, fired when the player taps PLAY on the
//     post-generation result screen. Mirrors the
//     BRGamePickerViewController.onSelection contract: this view controller
//     dismisses itself first, then the block fires with the freshly-created
//     record so the presenter can transition straight into gameplay.

#import <UIKit/UIKit.h>
#import "BRGameLibrary.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRCustomGameCreatorViewController : UIViewController

/// Optional photo supplied by another part of the app (for example, EZ
/// Attachments). When present, the workshop asks whether to use it as the
/// player character or the game's background before any generation begins.
@property (nonatomic, strong, nullable) UIImage *initialWorkshopImage;

/// Fired on the main thread when the backend approves the transaction,
/// generations complete, and the asset pack is fully written to local storage.
/// Fires once, at the moment the record becomes available — before the
/// player has necessarily chosen PLAY or "Maybe Later" on the result
/// screen. Use this to add the new record to any in-memory library caches
/// (e.g. so it appears in BRGamePickerViewController next time it's shown).
@property (nonatomic, copy, nullable) void (^onGameCreated)(BRGameRecord *record);

/// Fired on the main thread when the player taps PLAY on the result screen.
/// This view controller (and the result screen pushed on top of it) have
/// already been dismissed before this block fires — the same contract as
/// BRGamePickerViewController.onSelection. The presenter should respond by
/// transitioning straight into gameplay with `record`.
@property (nonatomic, copy, nullable) void (^onPlayRequested)(BRGameRecord *record);

@end

NS_ASSUME_NONNULL_END
