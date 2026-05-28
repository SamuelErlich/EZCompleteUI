// BRGameView.h
// BrainRotGame
// EZCompleteUI v1.5
//
// Changes from v1.4:
//   - backgroundImage property added. When set, drawRect crops the portion of
//     the image corresponding to the current viewport and draws it as the base
//     layer, automatically synchronized with cameraCol/cameraRow. The separate
//     backgroundImageView in the ViewController is no longer needed.
//   - floorsTransparent removed. Tile passability overlays are now always drawn
//     on top of the background image: wall tiles get a dark semi-transparent
//     overlay so the player can always see where they can't walk; floor tiles
//     draw nothing (the image shows through). This replaces the old approach
//     of relying on image brightness to communicate passability, which was
//     unreliable across different AI-generated art styles.
//   - hidePlayerDot behaviour unchanged; enemy indicators still always draw.

#import <UIKit/UIKit.h>
#import "BRGameModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRGameView : UIView

@property (nonatomic, strong, nullable) BRGameModel *model;

/// When set, drawRect crops the viewport region of this image and draws it
/// as the bottom layer, perfectly synchronized with the camera offset.
/// Set to nil to use solid-color tile fills (fallback mode).
@property (nonatomic, strong, nullable) UIImage *backgroundImage;

/// When YES, the player dot is not drawn. Use when the ViewController
/// renders the hero with an animated UIImageView overlay instead.
/// Does NOT affect enemy indicators — those always draw.
@property (nonatomic, assign) BOOL hidePlayerDot;

/// Number of tile columns visible at once. Default 9.
@property (nonatomic, assign) NSInteger viewportCols;

/// Number of tile rows visible at once. Default 9.
@property (nonatomic, assign) NSInteger viewportRows;

/// Left edge of the visible window in model tile coordinates.
@property (nonatomic, assign) NSInteger cameraCol;

/// Top edge of the visible window in model tile coordinates.
@property (nonatomic, assign) NSInteger cameraRow;

@end

NS_ASSUME_NONNULL_END
