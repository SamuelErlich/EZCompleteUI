// BRGameView.m
// BrainRotGame
// EZCompleteUI v1.7
//
// Purpose:
//   Custom UIView responsible for rendering the visible portion of the maze
//   in a single drawRect: pass. Draws the background image cropped to the
//   current viewport, passability overlays for wall and exit tiles, coin and
//   heart item indicators, enemy position indicators, and (in no-image fallback
//   mode) the player dot. All layout is driven by cameraCol/cameraRow and the
//   viewport dimensions set by BrainRotViewController; this view is passive and
//   calls setNeedsDisplay only in response to property changes set externally.
//
// Changes from v1.6:
//   - Heart pickup icon enlarged to ~88% of the tile cell. Previously it was
//     sized against the inset baseRect (≈64% of the tile) and then scaled to
//     80% of that, resulting in an icon that covered roughly half the tile and
//     was hard to read at a glance during gameplay. Now uses tileRect directly
//     as the size reference so the heart nearly fills the cell, matching the
//     visual weight of the enemy and coin indicators.
//
// Changes from v1.5:
//   - Heart pickup icon replaced. The previous BRGameViewHeartPath() bezier
//     function produced a shape that read as a circle at typical tile sizes.
//     The pickup now draws heart.png from the main bundle instead, rendered
//     via UIGraphicsPushContext so UIKit handles the coordinate-system flip.
//   - BRGameViewHeartPath() removed entirely.

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

            // ── Item indicator — coins vs heart pickups ─────────────────────────
            if (tile.itemName) {
                CGRect baseRect = CGRectInset(tileRect, tileWidth * 0.18, tileHeight * 0.18);
                BOOL isHeartPickup = ([tile.itemName rangeOfString:@"heart"
                                                      options:NSCaseInsensitiveSearch].location != NSNotFound);
                if (isHeartPickup) {
                    // Load heart.png from the bundle (cached by UIImage after first call).
                    UIImage *heartImage = [UIImage imageNamed:@"heart"];
                    if (heartImage) {
                        // Use tileRect as the size reference rather than the inset
                        // baseRect, so the heart nearly fills the full tile cell.
                        // 0.88 leaves a small visible margin so adjacent tiles remain
                        // distinguishable even when two hearts are side by side.
                        CGFloat pulseScale  = 1.0 + 0.12 * sinf(self.heartPulsePhase);
                        CGFloat baseSize    = MIN(tileRect.size.width, tileRect.size.height) * 0.88;
                        CGFloat scaledSize  = baseSize * pulseScale;
                        CGRect heartDrawRect = CGRectMake(CGRectGetMidX(tileRect) - scaledSize / 2.0,
                                                          CGRectGetMidY(tileRect) - scaledSize / 2.0,
                                                          scaledSize, scaledSize);
                        UIGraphicsPushContext(ctx);
                        [heartImage drawInRect:heartDrawRect];
                        UIGraphicsPopContext();
                    }
                } else {
                    CGContextSetFillColorWithColor(ctx,
                        [UIColor colorWithRed:1.0 green:0.88 blue:0.0 alpha:1.0].CGColor);
                    CGContextFillEllipseInRect(ctx, baseRect);
                    CGContextSetStrokeColorWithColor(ctx,
                        [UIColor colorWithRed:0.55 green:0.40 blue:0.0 alpha:0.9].CGColor);
                    CGContextSetLineWidth(ctx, 1.0);
                    CGContextStrokeEllipseInRect(ctx, CGRectInset(baseRect, 0.5, 0.5));
                }
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
