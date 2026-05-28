// BRGameModel.h
// BrainRotGame
// EZCompleteUI v1.0
//
// Grid-based maze model. Tile topology is generated from a seed using a
// depth-first recursive backtracker so the same seed always produces the
// same maze. The ViewController can override tile types after generation
// (e.g. brightness-based reclassification from a background image).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - BRTile

typedef NS_ENUM(NSInteger, BRTileType) {
    BRTileTypeWall  = 0,
    BRTileTypeFloor = 1,
    BRTileTypeExit  = 2,
};

/// A single grid cell. Mutable so the ViewController can carve corridors,
/// place items/enemies, and reclassify tiles after image-based generation.
@interface BRTile : NSObject
@property (nonatomic, assign) BRTileType  type;
@property (nonatomic, copy,   nullable) NSString *itemName;   ///< non-nil when a collectible is here
@property (nonatomic, copy,   nullable) NSString *enemyName;  ///< non-nil when an enemy is here
@end

#pragma mark - BRGameModel

@interface BRGameModel : NSObject

// ── Grid dimensions ───────────────────────────────────────────────────────────
@property (nonatomic, readonly) NSInteger cols;
@property (nonatomic, readonly) NSInteger rows;

// ── Player state ──────────────────────────────────────────────────────────────
@property (nonatomic, assign) NSInteger playerCol;
@property (nonatomic, assign) NSInteger playerRow;
@property (nonatomic, assign) NSInteger playerHP;

/// Maximum HP — used by the HUD to draw the correct number of heart outlines.
@property (nonatomic, readonly) NSInteger maxHP;

// ── Exit position ─────────────────────────────────────────────────────────────
@property (nonatomic, readonly) NSInteger exitCol;
@property (nonatomic, readonly) NSInteger exitRow;

// ── AI-generated metadata (set by ViewController after asset build) ───────────
@property (nonatomic, copy,   nullable) NSString             *levelFlavor;
@property (nonatomic, copy,   nullable) NSString             *vulnerableHint;
@property (nonatomic, strong, nullable) NSArray<NSString *>  *aiItems;
@property (nonatomic, strong, nullable) NSArray<NSString *>  *aiEnemies;

/// Designated initialiser. Generates the maze immediately using a seeded
/// depth-first backtracker; the same seed always produces the same layout.
- (instancetype)initWithCols:(NSInteger)cols rows:(NSInteger)rows seed:(NSNumber *)seed
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Returns the tile at (col, row), or nil if out of bounds.
- (nullable BRTile *)tileAtCol:(NSInteger)col row:(NSInteger)row;

/// Attempts to move the player by (deltaCol, deltaRow).
/// Returns YES and updates playerCol/playerRow if the destination is floor or exit.
/// Returns NO if the destination is a wall or out of bounds.
- (BOOL)movePlayerByDC:(NSInteger)deltaCol DR:(NSInteger)deltaRow;

/// Returns NSValue-wrapped CGPoints for the four cardinal neighbors of (col, row)
/// that are within the grid bounds. Does not filter by tile type.
- (NSArray<NSValue *> *)neighborsOfCol:(NSInteger)col row:(NSInteger)row;

/// Randomly places up to count items from the itemNames array on floor tiles
/// that don't already have an item or enemy, excluding the player start and exit.
- (void)placeItems:(NSArray<NSString *> *)itemNames count:(NSInteger)count;

/// Randomly places up to count enemies from the enemyNames array on floor tiles
/// that are not adjacent to the player start, don't already have an enemy or item,
/// and are not the exit tile.
- (void)placeEnemies:(NSArray<NSString *> *)enemyNames count:(NSInteger)count;

@end

NS_ASSUME_NONNULL_END
