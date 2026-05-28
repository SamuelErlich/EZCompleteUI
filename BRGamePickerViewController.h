// BRGamePickerViewController.h
// BrainRotGame
// EZCompleteUI v1.0
//
// Full-screen game library picker. Displays saved games as a 2-column card grid
// with the background image filling each card and the title drawn over a gradient.
// A "New Game" card sits at index 0 always.
//
// Usage:
//   BRGamePickerViewController *picker = [BRGamePickerViewController new];
//   picker.onSelection = ^(BRGameRecord *record) {
//       // record == nil  →  user tapped New Game
//       // record != nil  →  user chose a saved game
//   };
//   [self presentViewController:picker animated:YES completion:nil];

#import <UIKit/UIKit.h>
#import "BRGameLibrary.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRGamePickerViewController : UIViewController

/// Called on the main thread when the user makes a selection.
/// nil record means New Game; non-nil means load that record.
/// The picker has already been dismissed before this block fires.
@property (nonatomic, copy) void (^onSelection)(BRGameRecord *_Nullable record);

@end

NS_ASSUME_NONNULL_END
