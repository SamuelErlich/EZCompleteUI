// BRGameView.m
// BrainRotGame
// EZCompleteUI v1.5
//
// Changes from v1.4:
//   - Background image rendered directly in drawRect by cropping the viewport
//     region from backgroundImage using CGImageCreateWithImageInRect. Since
//     this happens inside drawRect using the same cameraCol/cameraRow the rest
//     of the tile loop uses, the image is always perfectly in sync with the
//     maze overlay — no separate UIImageView that lags behind.
//   - Passability overlay replaces floorsTransparent logic:
//       Wall tiles: dark overlay (black 65% alpha) drawn on top of the image
//                   so the player always sees impassable areas even on busy art.
//       Floor tiles: no overlay — image shows through, giving them a visually
//                    distinct "open" appearance.
//       Exit tile: bright green overlay (unchanged).
//     In fallback mode (no backgroundImage) the original solid-color tile fills
//     are used so the game works without any AI assets.
//   - floorsTransparent removed entirely; image presence drives the behaviour.
//   - Enemy indicators, item dots, grid lines, and player dot unchanged from v1.4.

#import "BRGameView.h"
#import "BRGameModel.h"

@implementation BRGameView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _viewportCols = 5;
        _viewportRows = 5;
        _cameraCol    = 0;
        _cameraRow    = 0;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        _viewportCols = 5;
        _viewportRows = 5;
        _cameraCol    = 0;
        _cameraRow    = 0;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    if (!self.model) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    CGFloat viewWidth  = CGRectGetWidth(self.bounds);
    CGFloat viewHeight = CGRectGetHeight(self.bounds);
    CGFloat tileWidth  = viewWidth  / (CGFloat)self.viewportCols;
    CGFloat tileHeight = viewHeight / (CGFloat)self.viewportRows;

    NSInteger colStart = self.cameraCol;
    NSInteger rowStart = self.cameraRow;
    NSInteger colEnd   = MIN(self.model.cols, colStart + self.viewportCols);
    NSInteger rowEnd   = MIN(self.model.rows, rowStart + self.viewportRows);

    // ── Background image: crop viewport region and draw as base layer ─────────
    // CGImageCreateWithImageInRect works in pixel space, so multiply by scale.
    // The crop exactly matches colStart…colEnd / rowStart…rowEnd, so it is
    // always pixel-perfectly aligned with the tile overlay drawn below.
    if (self.backgroundImage) {
        CGFloat imageScale   = self.backgroundImage.scale;
        CGFloat imagePixelW  = self.backgroundImage.size.width  * imageScale;
        CGFloat imagePixelH  = self.backgroundImage.size.height * imageScale;
        CGFloat pixelsPerCol = imagePixelW / (CGFloat)self.model.cols;
        CGFloat pixelsPerRow = imagePixelH / (CGFloat)self.model.rows;

        CGRect sourcePixelRect = CGRectMake(
            colStart * pixelsPerCol,
            rowStart * pixelsPerRow,
            (colEnd - colStart) * pixelsPerCol,
            (rowEnd - rowStart) * pixelsPerRow);

        CGImageRef croppedImageRef = CGImageCreateWithImageInRect(
            self.backgroundImage.CGImage, sourcePixelRect);
        if (croppedImageRef) {
            // CGContextDrawImage draws upside-down relative to UIKit, so flip
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, 0, viewHeight);
            CGContextScaleCTM(ctx, 1.0, -1.0);
            CGContextDrawImage(ctx, CGRectMake(0, 0, viewWidth, viewHeight), croppedImageRef);
            CGContextRestoreGState(ctx);
            CGImageRelease(croppedImageRef);
        }
    }

    // ── Tile overlays ─────────────────────────────────────────────────────────
    for (NSInteger row = rowStart; row < rowEnd; row++) {
        for (NSInteger col = colStart; col < colEnd; col++) {
            BRTile    *tile       = [self.model tileAtCol:col row:row];
            NSInteger screenCol   = col - colStart;
            NSInteger screenRow   = row - rowStart;
            CGRect    tileRect    = CGRectMake(screenCol * tileWidth,
                                               screenRow * tileHeight,
                                               tileWidth, tileHeight);

            if (self.backgroundImage) {
                // ── Image mode: passability overlay ──────────────────────────
                // Wall tiles get a dark mask so the player knows they can't pass.
                // Floor tiles are left clear — the image shows through.
                // This is the only reliable way to communicate passability across
                // any AI art style without depending on image brightness.
                switch (tile.type) {
                    case BRTileTypeWall: {
                        // Light vignette so the AI's wall art shows through clearly.
                        // The template is now 1024×1024 and structurally 1:1 with the
                        // output, so the generated image's dark wall areas already
                        // signal impassability — we just add a subtle tint and a faint
                        // inner border to separate adjacent tiles without boxing them.
                        CGContextSetFillColorWithColor(ctx,
                            [UIColor colorWithWhite:0.0 alpha:0.22].CGColor);
                        CGContextFillRect(ctx, tileRect);
                        CGRect wallBorderRect = CGRectInset(tileRect, 1.0, 1.0);
                        CGContextSetStrokeColorWithColor(ctx,
                            [UIColor colorWithWhite:0.0 alpha:0.30].CGColor);
                        CGContextSetLineWidth(ctx, 0.75);
                        CGContextStrokeRect(ctx, wallBorderRect);
                        break;
                    }
                    case BRTileTypeExit:
                        CGContextSetFillColorWithColor(ctx,
                            [UIColor colorWithRed:0.05 green:0.85 blue:0.25 alpha:0.55].CGColor);
                        CGContextFillRect(ctx, tileRect);
                        // Bright ring so it stands out
                        CGContextSetStrokeColorWithColor(ctx,
                            [UIColor colorWithRed:0.1 green:1.0 blue:0.35 alpha:0.95].CGColor);
                        CGContextSetLineWidth(ctx, 2.5);
                        CGContextStrokeEllipseInRect(ctx,
                            CGRectInset(tileRect, tileWidth * 0.08, tileHeight * 0.08));
                        break;
                    case BRTileTypeFloor:
                    default:
                        break; // clear — image shows through
                }
            } else {
                // ── Fallback mode: solid-color tiles ─────────────────────────
                UIColor *fillColor;
                switch (tile.type) {
                    case BRTileTypeWall:
                        fillColor = [UIColor colorWithWhite:0.12 alpha:1.0]; break;
                    case BRTileTypeFloor:
                        fillColor = [UIColor colorWithWhite:0.92 alpha:1.0]; break;
                    case BRTileTypeExit:
                        fillColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.25 alpha:0.90]; break;
                    default:
                        fillColor = [UIColor blackColor]; break;
                }
                CGContextSetFillColorWithColor(ctx, fillColor.CGColor);
                CGContextFillRect(ctx, tileRect);

                // Grid lines in fallback mode only
                CGContextSetStrokeColorWithColor(ctx,
                    [UIColor colorWithWhite:0.75 alpha:0.5].CGColor);
                CGContextSetLineWidth(ctx, 0.5);
                CGContextStrokeRect(ctx, tileRect);
            }

            // ── Item dot — both modes ─────────────────────────────────────────
            if (tile.itemName) {
                CGRect dotRect = CGRectInset(tileRect, tileWidth * 0.18, tileHeight * 0.18);
                CGContextSetFillColorWithColor(ctx,
                    [UIColor colorWithRed:1.0 green:0.88 blue:0.0 alpha:1.0].CGColor);
                CGContextFillEllipseInRect(ctx, dotRect);
                CGContextSetStrokeColorWithColor(ctx,
                    [UIColor colorWithRed:0.55 green:0.40 blue:0.0 alpha:0.9].CGColor);
                CGContextSetLineWidth(ctx, 1.0);
                CGContextStrokeEllipseInRect(ctx, CGRectInset(dotRect, 0.5, 0.5));
            }

            // ── Enemy indicator — always drawn regardless of hidePlayerDot ────
            if (tile.enemyName) {
                CGRect enemyRect = CGRectInset(tileRect, tileWidth * 0.12, tileHeight * 0.12);
                if (self.backgroundImage) {
                    CGContextSetFillColorWithColor(ctx,
                        [UIColor colorWithRed:0.9 green:0.1 blue:0.1 alpha:0.45].CGColor);
                    CGContextFillEllipseInRect(ctx, enemyRect);
                    CGContextSetStrokeColorWithColor(ctx,
                        [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:0.95].CGColor);
                    CGContextSetLineWidth(ctx, 2.0);
                    CGContextStrokeEllipseInRect(ctx, CGRectInset(enemyRect, 1.0, 1.0));
                } else {
                    CGContextSetFillColorWithColor(ctx,
                        [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0].CGColor);
                    CGContextFillEllipseInRect(ctx, enemyRect);
                }
            }
        }
    }

    // ── Player dot (fallback mode only) ───────────────────────────────────────
    if (!self.hidePlayerDot) {
        NSInteger playerScreenCol = self.model.playerCol - colStart;
        NSInteger playerScreenRow = self.model.playerRow - rowStart;
        if (playerScreenCol >= 0 && playerScreenCol < self.viewportCols &&
            playerScreenRow >= 0 && playerScreenRow < self.viewportRows) {
            CGFloat playerW = tileWidth  * 0.75;
            CGFloat playerH = tileHeight * 0.75;
            CGRect playerRect = CGRectMake(
                playerScreenCol * tileWidth  + (tileWidth  - playerW) / 2.0,
                playerScreenRow * tileHeight + (tileHeight - playerH) / 2.0,
                playerW, playerH);
            CGContextSetFillColorWithColor(ctx,
                [UIColor colorWithRed:0.12 green:0.45 blue:0.9 alpha:1.0].CGColor);
            CGContextFillEllipseInRect(ctx, playerRect);
        }
    }
}

@end
