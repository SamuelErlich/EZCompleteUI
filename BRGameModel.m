// BRGameModel.m
// BrainRotGame
// EZCompleteUI v1.0
//
// Maze generation: depth-first recursive backtracker with a seeded LCG so
// the same NSNumber seed always produces the same maze. The algorithm works
// on a (cols/2) × (rows/2) logical grid then expands each logical cell to a
// 2×2 block of tiles, with the wall between two cells carved when the
// backtracker connects them. This guarantees a perfect maze (exactly one path
// between any two floor tiles) which the ViewController's BFS reachability
// check can then verify. Odd col/row counts are handled by treating the last
// column/row as a permanent wall border.

#import "BRGameModel.h"

static const NSInteger kBRDefaultMaxHP = 3;

#pragma mark - BRTile

@implementation BRTile
@end

#pragma mark - Seeded LCG random

/// Tiny linear-congruential generator seeded from the game seed.
/// Not cryptographically secure; used only for reproducible maze generation.
typedef struct {
    uint64_t state;
} BRLCG;

static void brLCGSeed(BRLCG *rng, uint64_t seed) {
    rng->state = seed ^ 0x123456789ABCDEFULL;
}

/// Returns a pseudo-random NSInteger in [0, upperBound).
static NSInteger brLCGNext(BRLCG *rng, NSInteger upperBound) {
    // Multiplier and increment from Knuth TAOCP vol.2
    rng->state = rng->state * 6364136223846793005ULL + 1442695040888963407ULL;
    uint64_t shifted = (rng->state >> 33) ^ rng->state;
    return (NSInteger)(shifted % (uint64_t)upperBound);
}

#pragma mark - BRGameModel

@interface BRGameModel ()
@property (nonatomic, strong) NSMutableArray<BRTile *> *tiles; ///< row-major flat array
@property (nonatomic, assign) NSInteger _cols;
@property (nonatomic, assign) NSInteger _rows;
@property (nonatomic, assign) NSInteger _exitCol;
@property (nonatomic, assign) NSInteger _exitRow;
@property (nonatomic, assign) NSInteger _maxHP;
@end

@implementation BRGameModel

- (NSInteger)cols    { return self._cols;    }
- (NSInteger)rows    { return self._rows;    }
- (NSInteger)exitCol { return self._exitCol; }
- (NSInteger)exitRow { return self._exitRow; }
- (NSInteger)maxHP   { return self._maxHP;   }

- (instancetype)initWithCols:(NSInteger)cols rows:(NSInteger)rows seed:(NSNumber *)seed {
    self = [super init];
    if (!self) return nil;

    // Enforce odd dimensions so the backtracker expansion always produces a clean border
    self._cols  = (cols  % 2 == 0) ? cols  + 1 : cols;
    self._rows  = (rows  % 2 == 0) ? rows  + 1 : rows;
    self._maxHP = kBRDefaultMaxHP;
    self.playerHP = kBRDefaultMaxHP;

    // Allocate all tiles as walls
    NSInteger totalTiles = self._cols * self._rows;
    NSMutableArray<BRTile *> *tiles = [NSMutableArray arrayWithCapacity:totalTiles];
    for (NSInteger tileIndex = 0; tileIndex < totalTiles; tileIndex++) {
        BRTile *tile = [[BRTile alloc] init];
        tile.type = BRTileTypeWall;
        [tiles addObject:tile];
    }
    self.tiles = tiles;

    BRLCG rng;
    brLCGSeed(&rng, (uint64_t)seed.integerValue);

    // ── Depth-first backtracker on the logical (odd-indexed) grid ────────────
    // Logical grid dimensions (each logical cell maps to an odd tile index)
    NSInteger logicalCols = (self._cols - 1) / 2;
    NSInteger logicalRows = (self._rows - 1) / 2;
    NSInteger logicalCount = logicalCols * logicalRows;

    // Visited flags for logical cells
    NSMutableData *visitedStorage = [NSMutableData dataWithLength:logicalCount];
    uint8_t       *visited        = visitedStorage.mutableBytes;

    // Stack for backtracking (stores logical cell index)
    NSMutableArray<NSNumber *> *backtrackStack = [NSMutableArray array];

    // Start at logical cell (0,0) → tile (1,1)
    NSInteger startLogicalIndex = 0;
    visited[startLogicalIndex]  = 1;
    [backtrackStack addObject:@(startLogicalIndex)];

    // Cardinal direction offsets in logical space
    const NSInteger logicalDC[] = { 0,  0, -1, 1 };
    const NSInteger logicalDR[] = {-1,  1,  0, 0 };

    while (backtrackStack.count > 0) {
        NSInteger currentLogical   = backtrackStack.lastObject.integerValue;
        NSInteger currentLogicalCol = currentLogical % logicalCols;
        NSInteger currentLogicalRow = currentLogical / logicalCols;

        // Collect unvisited logical neighbors
        NSMutableArray<NSNumber *> *unvisitedDirections = [NSMutableArray array];
        for (NSInteger direction = 0; direction < 4; direction++) {
            NSInteger neighborLogicalCol = currentLogicalCol + logicalDC[direction];
            NSInteger neighborLogicalRow = currentLogicalRow + logicalDR[direction];
            if (neighborLogicalCol < 0 || neighborLogicalCol >= logicalCols ||
                neighborLogicalRow < 0 || neighborLogicalRow >= logicalRows) continue;
            NSInteger neighborLogicalIndex = neighborLogicalRow * logicalCols + neighborLogicalCol;
            if (!visited[neighborLogicalIndex]) {
                [unvisitedDirections addObject:@(direction)];
            }
        }

        if (unvisitedDirections.count == 0) {
            [backtrackStack removeLastObject];
            continue;
        }

        // Pick a random unvisited neighbor
        NSInteger chosenDirection    = unvisitedDirections[brLCGNext(&rng, unvisitedDirections.count)].integerValue;
        NSInteger neighborLogicalCol = currentLogicalCol + logicalDC[chosenDirection];
        NSInteger neighborLogicalRow = currentLogicalRow + logicalDR[chosenDirection];
        NSInteger neighborLogicalIdx = neighborLogicalRow * logicalCols + neighborLogicalCol;

        // Tile coordinates of the current and neighbor logical cells
        NSInteger currentTileCol  = currentLogicalCol  * 2 + 1;
        NSInteger currentTileRow  = currentLogicalRow  * 2 + 1;
        NSInteger neighborTileCol = neighborLogicalCol * 2 + 1;
        NSInteger neighborTileRow = neighborLogicalRow * 2 + 1;

        // Carve the logical cells
        [self tileAtCol:currentTileCol  row:currentTileRow ].type = BRTileTypeFloor;
        [self tileAtCol:neighborTileCol row:neighborTileRow].type = BRTileTypeFloor;

        // Carve the wall between them (the tile at the midpoint)
        NSInteger wallCol = (currentTileCol  + neighborTileCol) / 2;
        NSInteger wallRow = (currentTileRow  + neighborTileRow) / 2;
        [self tileAtCol:wallCol row:wallRow].type = BRTileTypeFloor;

        visited[neighborLogicalIdx] = 1;
        [backtrackStack addObject:@(neighborLogicalIdx)];
    }

    // ── Player start: top-left interior cell (1,1) ────────────────────────────
    self.playerCol = 1;
    self.playerRow = 1;
    [self tileAtCol:1 row:1].type = BRTileTypeFloor; // ensure always walkable

    // ── Exit: bottom-right interior cell ─────────────────────────────────────
    NSInteger exitTileCol = self._cols - 2;
    NSInteger exitTileRow = self._rows - 2;
    self._exitCol = exitTileCol;
    self._exitRow = exitTileRow;
    [self tileAtCol:exitTileCol row:exitTileRow].type = BRTileTypeExit;

    return self;
}

#pragma mark - Tile access

- (nullable BRTile *)tileAtCol:(NSInteger)col row:(NSInteger)row {
    if (col < 0 || col >= self._cols || row < 0 || row >= self._rows) return nil;
    return self.tiles[row * self._cols + col];
}

#pragma mark - Player movement

- (BOOL)movePlayerByDC:(NSInteger)deltaCol DR:(NSInteger)deltaRow {
    NSInteger targetCol = self.playerCol + deltaCol;
    NSInteger targetRow = self.playerRow + deltaRow;
    BRTile   *targetTile = [self tileAtCol:targetCol row:targetRow];
    if (!targetTile || targetTile.type == BRTileTypeWall) return NO;
    self.playerCol = targetCol;
    self.playerRow = targetRow;
    return YES;
}

#pragma mark - Neighbors

- (NSArray<NSValue *> *)neighborsOfCol:(NSInteger)col row:(NSInteger)row {
    NSMutableArray<NSValue *> *neighbors = [NSMutableArray arrayWithCapacity:4];
    const NSInteger dc[] = { 0,  0, -1, 1 };
    const NSInteger dr[] = {-1,  1,  0, 0 };
    for (NSInteger direction = 0; direction < 4; direction++) {
        NSInteger neighborCol = col + dc[direction];
        NSInteger neighborRow = row + dr[direction];
        if ([self tileAtCol:neighborCol row:neighborRow]) {
            [neighbors addObject:[NSValue valueWithCGPoint:CGPointMake(neighborCol, neighborRow)]];
        }
    }
    return [neighbors copy];
}

#pragma mark - Item + enemy placement

- (void)placeItems:(NSArray<NSString *> *)itemNames count:(NSInteger)count {
    if (itemNames.count == 0 || count <= 0) return;
    NSMutableArray<BRTile *> *candidateTiles = [self floorTilesExcludingPlayerAndExit];
    NSInteger placed = 0;
    NSInteger nameCount = (NSInteger)itemNames.count;
    while (placed < count && candidateTiles.count > 0) {
        NSInteger randomIndex = arc4random_uniform((uint32_t)candidateTiles.count);
        BRTile   *tile        = candidateTiles[randomIndex];
        if (!tile.itemName && !tile.enemyName) {
            tile.itemName = itemNames[placed % nameCount];
            placed++;
        }
        [candidateTiles removeObjectAtIndex:randomIndex];
    }
}

- (void)placeEnemies:(NSArray<NSString *> *)enemyNames count:(NSInteger)count {
    if (enemyNames.count == 0 || count <= 0) return;

    // Enemies must not spawn adjacent to player start — give the player breathing room
    NSArray<NSValue *> *startNeighbors = [self neighborsOfCol:self.playerCol row:self.playerRow];
    NSMutableSet<NSString *> *forbiddenKeys = [NSMutableSet set];
    for (NSValue *posValue in startNeighbors) {
        CGPoint pos = posValue.CGPointValue;
        [forbiddenKeys addObject:[NSString stringWithFormat:@"%ld,%ld",
                                  (long)pos.x, (long)pos.y]];
    }
    [forbiddenKeys addObject:[NSString stringWithFormat:@"%ld,%ld",
                               (long)self.playerCol, (long)self.playerRow]];

    NSMutableArray<BRTile *> *candidateTiles = [NSMutableArray array];
    for (NSInteger row = 0; row < self._rows; row++) {
        for (NSInteger col = 0; col < self._cols; col++) {
            BRTile *tile = [self tileAtCol:col row:row];
            if (tile.type != BRTileTypeFloor) continue;
            if (tile.itemName || tile.enemyName) continue;
            NSString *key = [NSString stringWithFormat:@"%ld,%ld", (long)col, (long)row];
            if ([forbiddenKeys containsObject:key]) continue;
            [candidateTiles addObject:tile];
        }
    }

    NSInteger placed    = 0;
    NSInteger nameCount = (NSInteger)enemyNames.count;
    while (placed < count && candidateTiles.count > 0) {
        NSInteger randomIndex = arc4random_uniform((uint32_t)candidateTiles.count);
        BRTile   *tile        = candidateTiles[randomIndex];
        tile.enemyName = enemyNames[placed % nameCount];
        placed++;
        [candidateTiles removeObjectAtIndex:randomIndex];
    }
}

#pragma mark - Private helpers

/// Returns all floor tiles that are not the player start or exit tile.
- (NSMutableArray<BRTile *> *)floorTilesExcludingPlayerAndExit {
    NSMutableArray<BRTile *> *result = [NSMutableArray array];
    for (NSInteger row = 0; row < self._rows; row++) {
        for (NSInteger col = 0; col < self._cols; col++) {
            if (col == self.playerCol && row == self.playerRow) continue;
            if (col == self._exitCol  && row == self._exitRow)  continue;
            BRTile *tile = [self tileAtCol:col row:row];
            if (tile.type == BRTileTypeFloor) {
                [result addObject:tile];
            }
        }
    }
    return result;
}

@end
