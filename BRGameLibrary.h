// BRGameLibrary.h
// BrainRotGame
// EZCompleteUI v1.0
//
// Persistent game library. Each saved game is stored as a folder under
// <Documents>/BRGames/<uuid>/ containing meta.json, background.png,
// player.png, and enemy.png. BRGameRecord is a lightweight in-memory
// representation of one saved game; images are loaded on demand.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - BRGameRecord

/// Lightweight in-memory descriptor for one saved game.
/// Images are loaded lazily from disk the first time they are requested.
@interface BRGameRecord : NSObject

@property (nonatomic, copy)   NSString *gameID;      ///< UUID — used as the folder name on disk
@property (nonatomic, copy)   NSString *themeTitle;  ///< e.g. "DUCK INSURGENCY"
@property (nonatomic, copy)   NSString *premise;     ///< 2-3 sentence story shown on loading screen
@property (nonatomic, copy)   NSString *hint;
@property (nonatomic, strong) NSArray<NSString *> *items;
@property (nonatomic, strong) NSArray<NSString *> *enemies;
@property (nonatomic, strong) NSNumber *seed;        ///< maze generation seed
@property (nonatomic, strong) NSDate   *createdDate;

/// Lazily decoded from disk. Returns nil if the file is missing.
@property (nonatomic, strong, readonly, nullable) UIImage *backgroundImage;
@property (nonatomic, strong, readonly, nullable) UIImage *playerImage;
@property (nonatomic, strong, readonly, nullable) UIImage *enemyImage;

/// Convenience dictionary matching the shape that BrainRotViewController
/// already consumes from buildGameAssetsWithCompletion:.
- (NSDictionary *)asAssetDict;

@end

#pragma mark - BRGameLibrary

/// Singleton that manages saving, loading, and deleting game records on disk.
@interface BRGameLibrary : NSObject

+ (instancetype)shared;

/// Saves a game asynchronously. The completion block is called on the main
/// thread with the resulting BRGameRecord once all files are written.
/// Passing nil images is safe — those files are simply not written.
- (void)saveGameWithThemeTitle:(NSString *)themeTitle
                        premise:(NSString *)premise
                           hint:(NSString *)hint
                          items:(NSArray<NSString *> *)items
                        enemies:(NSArray<NSString *> *)enemies
                           seed:(NSNumber *)seed
               backgroundImage:(nullable UIImage *)backgroundImage
                    playerImage:(nullable UIImage *)playerImage
                     enemyImage:(nullable UIImage *)enemyImage
                     completion:(nullable void (^)(BRGameRecord *record))completion;

/// Returns all saved records sorted newest-first. Synchronous; call off main
/// thread for large libraries, though in practice libraries stay small.
- (NSArray<BRGameRecord *> *)allRecords;

/// Permanently deletes a record's folder from disk.
- (void)deleteRecord:(BRGameRecord *)record;

@end

NS_ASSUME_NONNULL_END
