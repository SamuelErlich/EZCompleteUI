// BRGameView.m
// BrainRotGame
// EZCompleteUI v1.3
//
// Changes from v1.2:
//   - Item dots made larger (inset reduced from 25% to 12%) and given a dark
//     contrasting stroke so they're visible against any background image color.
//   - Enemy indicators now always drawn regardless of hidePlayerDot flag.
//     In solid-color fallback mode: filled red circle (unchanged).
//     In image mode (floorsTransparent=YES): red ring outline + semi-transparent
//     fill, drawn even when the ViewController's UIImageView sprite failed to load.
//     Previously enemies were invisible in image mode if the sprite sheet API call
//     failed, leaving the player stumbling into things they couldn't see.
//   - hidePlayerDot now only gates the player dot, as the name implies.
//   - Exit tile pulse: in image mode the exit gets a brighter, wider green border
//     ring drawn around its center so it reads clearly over the background image.

#import "BRGameView.h"
#import "BRGameModel.h"

@implementation BRGameView

- (void)drawRect:(CGRect)rect {
    if (!self.model) return;
    CGContextRef ctx      = UIGraphicsGetCurrentContext();
    NSInteger    gridCols = self.model.cols;
    NSInteger    gridRows = self.model.rows;
    CGFloat tileWidth     = CGRectGetWidth(self.bounds)  / (CGFloat)gridCols;
    CGFloat tileHeight    = CGRectGetHeight(self.bounds) / (CGFloat)gridRows;

    for (NSInteger row = 0; row < gridRows; row++) {
        for (NSInteger col = 0; col < gridCols; col++) {
            BRTile *tile     = [self.model tileAtCol:col row:row];
            CGRect  tileRect = CGRectMake(col * tileWidth, row * tileHeight,
                                          tileWidth, tileHeight);

            // ── Tile background fill ──────────────────────────────────────────
            UIColor *fillColor;
            if (self.floorsTransparent) {
                fillColor = (tile.type == BRTileTypeExit)
                    ? [UIColor colorWithRed:0.15 green:0.80 blue:0.25 alpha:0.55]
                    : [UIColor clearColor];
            } else {
                switch (tile.type) {
                    case BRTileTypeWall:
                        fillColor = [UIColor colorWithWhite:0.12 alpha:1.0];  break;
                    case BRTileTypeFloor:
                        fillColor = [UIColor colorWithWhite:0.95 alpha:1.0];  break;
                    case BRTileTypeExit:
                        fillColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.25 alpha:0.90]; break;
                    default:
                        fillColor = [UIColor blackColor]; break;
                }
            }
            CGContextSetFillColorWithColor(ctx, fillColor.CGColor);
            CGContextFillRect(ctx, tileRect);

            // ── Exit ring (image mode) — bright border so it reads over any bg ──
            // In solid mode the filled tile is sufficient; in image mode a ring
            // is more visible than a translucent fill alone.
            if (self.floorsTransparent && tile.type == BRTileTypeExit) {
                CGFloat strokeInset = tileWidth * 0.08;
                CGRect  exitRingRect = CGRectInset(tileRect, strokeInset, strokeInset);
                CGContextSetStrokeColorWithColor(ctx,
                    [UIColor colorWithRed:0.1 green:1.0 blue:0.35 alpha:0.95].CGColor);
                CGContextSetLineWidth(ctx, 2.5);
                CGContextStrokeEllipseInRect(ctx, exitRingRect);
            }

            // ── Item dot ──────────────────────────────────────────────────────
            // Larger inset (12% vs old 25%) so the dot is big enough to notice.
            // Dark stroke gives contrast against both light and dark backgrounds.
            if (tile.itemName) {
                CGRect dotRect = CGRectInset(tileRect, tileWidth * 0.12, tileHeight * 0.12);
                CGContextSetFillColorWithColor(ctx,
                    [UIColor colorWithRed:1.0 green:0.88 blue:0.0 alpha:1.0].CGColor);
                CGContextFillEllipseInRect(ctx, dotRect);
                // Contrasting stroke so gold dot is visible on light backgrounds too
                CGContextSetStrokeColorWithColor(ctx,
                    [UIColor colorWithRed:0.55 green:0.40 blue:0.0 alpha:0.85].CGColor);
                CGContextSetLineWidth(ctx, 1.0);
                CGContextStrokeEllipseInRect(ctx, CGRectInset(dotRect, 0.5, 0.5));
            }

            // ── Enemy indicator — always drawn ────────────────────────────────
            // hidePlayerDot only gates the PLAYER dot below; enemies are always
            // indicated so the player can see what they're walking into.
            //
            // Image mode: semi-transparent red fill + bright red ring outline.
            //   Ensures enemies are visible even if the UIImageView sprite sheet
            //   API call failed and no overlay image was assigned.
            // Solid mode: fully opaque filled red circle (unchanged from before).
            if (tile.enemyName) {
                CGRect enemyRect = CGRectInset(tileRect, tileWidth * 0.12, tileHeight * 0.12);
                if (self.floorsTransparent) {
                    // Semi-transparent fill so background image still shows through
                    CGContextSetFillColorWithColor(ctx,
                        [UIColor colorWithRed:0.9 green:0.1 blue:0.1 alpha:0.40].CGColor);
                    CGContextFillEllipseInRect(ctx, enemyRect);
                    // Bright ring so the indicator is unmissable
                    CGContextSetStrokeColorWithColor(ctx,
                        [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:0.92].CGColor);
                    CGContextSetLineWidth(ctx, 2.0);
                    CGContextStrokeEllipseInRect(ctx, CGRectInset(enemyRect, 1.0, 1.0));
                } else {
                    CGContextSetFillColorWithColor(ctx,
                        [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0].CGColor);
                    CGContextFillEllipseInRect(ctx, enemyRect);
                }
            }

            // ── Grid lines — solid-color fallback only ────────────────────────
            if (!self.floorsTransparent) {
                CGContextSetStrokeColorWithColor(ctx,
                    [UIColor colorWithWhite:0.8 alpha:0.6].CGColor);
                CGContextSetLineWidth(ctx, 0.5);
                CGContextStrokeRect(ctx, tileRect);
            }
        }
    }

    // ── Player dot — gated by hidePlayerDot, unrelated to enemy rendering ─────
    if (!self.hidePlayerDot) {
        CGFloat playerWidth  = tileWidth  * 0.8;
        CGFloat playerHeight = tileHeight * 0.8;
        CGRect playerRect = CGRectMake(
            self.model.playerCol * tileWidth  + (tileWidth  - playerWidth)  / 2.0,
            self.model.playerRow * tileHeight + (tileHeight - playerHeight) / 2.0,
            playerWidth, playerHeight);
        CGContextSetFillColorWithColor(ctx,
            [UIColor colorWithRed:0.12 green:0.45 blue:0.9 alpha:1.0].CGColor);
        CGContextFillEllipseInRect(ctx, playerRect);
    }
}

@end
