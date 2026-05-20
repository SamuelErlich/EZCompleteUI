// BRGameView.h
// BrainRotGame
// EZCompleteUI v1.2
//
// Changes from v1.1:
//   - floorsTransparent now suppresses grid lines and wall fills entirely —
//     in image mode the background UIImageView IS the map, so only item/exit/
//     enemy dots are drawn on top. Grid lines and wall squares survive only in
//     the solid-color fallback mode (no background image loaded).

#import <UIKit/UIKit.h>
#import "BRGameModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRGameView : UIView

@property (nonatomic, strong, nullable) BRGameModel *model;

/// When YES, all tile fills and grid lines are suppressed so the background
/// UIImageView placed behind this view shows through completely. Only item dots,
/// the exit tile highlight, and (when hidePlayerDot=NO) enemy/player dots are
/// drawn. Set to NO for the solid-color fallback when no background image loaded.
@property (nonatomic, assign) BOOL floorsTransparent;

/// When YES, the player circle is not drawn. Use when the ViewController
/// is rendering the hero with an animated UIImageView overlay instead.
/// Also gates the inline enemy dots (image mode uses UIImageView overlays for enemies).
@property (nonatomic, assign) BOOL hidePlayerDot;

@end

NS_ASSUME_NONNULL_END
