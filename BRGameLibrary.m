// BRGameLibrary.m
// BrainRotGame
// EZCompleteUI v1.0
//
// Disk layout:
//   <Documents>/BRGames/
//       <uuid>/
//           meta.json          { themeTitle, premise, hint, items, enemies, seed, createdDate }
//           background.png
//           player.png         (omitted if generation failed)
//           enemy.png          (omitted if generation failed)

#import "BRGameLibrary.h"

#pragma mark - BRGameRecord implementation

@interface BRGameRecord ()
@property (nonatomic, copy)   NSString *gameFolderPath; ///< full path to <uuid>/ folder
@property (nonatomic, strong) UIImage  *cachedBackground;
@property (nonatomic, strong) UIImage  *cachedPlayer;
@property (nonatomic, strong) UIImage  *cachedEnemy;
@property (nonatomic, assign) BOOL      backgroundLoaded;
@property (nonatomic, assign) BOOL      playerLoaded;
@property (nonatomic, assign) BOOL      enemyLoaded;
@end

@implementation BRGameRecord

- (UIImage *)backgroundImage {
    if (!self.backgroundLoaded) {
        NSString *path = [self.gameFolderPath stringByAppendingPathComponent:@"background.png"];
        self.cachedBackground = [UIImage imageWithContentsOfFile:path];
        self.backgroundLoaded = YES;
    }
    return self.cachedBackground;
}

- (UIImage *)playerImage {
    if (!self.playerLoaded) {
        NSString *path = [self.gameFolderPath stringByAppendingPathComponent:@"player.png"];
        self.cachedPlayer = [UIImage imageWithContentsOfFile:path];
        self.playerLoaded = YES;
    }
    return self.cachedPlayer;
}

- (UIImage *)enemyImage {
    if (!self.enemyLoaded) {
        NSString *path = [self.gameFolderPath stringByAppendingPathComponent:@"enemy.png"];
        self.cachedEnemy = [UIImage imageWithContentsOfFile:path];
        self.enemyLoaded = YES;
    }
    return self.cachedEnemy;
}

- (NSDictionary *)asAssetDict {
    // Matches the shape BrainRotViewController expects from buildGameAssetsWithCompletion:
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"themeTitle"] = self.themeTitle ?: @"BRAINROT";
    dict[@"levelDesc"]  = self.premise    ?: @"";
    dict[@"hint"]       = self.hint       ?: @"";
    dict[@"items"]      = self.items      ?: @[];
    dict[@"enemies"]    = self.enemies    ?: @[];
    UIImage *bg  = self.backgroundImage;
    UIImage *plr = self.playerImage;
    UIImage *enm = self.enemyImage;
    if (bg)  dict[@"bgImage"]     = bg;
    if (plr) dict[@"playerImage"] = plr;
    if (enm) dict[@"enemyImage"]  = enm;
    return [dict copy];
}

@end

#pragma mark - BRGameLibrary implementation

@interface BRGameLibrary ()
@property (nonatomic, copy) NSString *libraryRootPath; ///< <Documents>/BRGames/
@end

@implementation BRGameLibrary

+ (instancetype)shared {
    static BRGameLibrary *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[BRGameLibrary alloc] init];
        [sharedInstance ensureLibraryDirectoryExists];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _libraryRootPath = [documents stringByAppendingPathComponent:@"BRGames"];
    }
    return self;
}

- (void)ensureLibraryDirectoryExists {
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.libraryRootPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    if (error) NSLog(@"[BRGameLibrary] Failed to create root dir: %@", error);
}

// ── Save ──────────────────────────────────────────────────────────────────────

- (void)saveGameWithThemeTitle:(NSString *)themeTitle
                        premise:(NSString *)premise
                           hint:(NSString *)hint
                          items:(NSArray<NSString *> *)items
                        enemies:(NSArray<NSString *> *)enemies
                           seed:(NSNumber *)seed
               backgroundImage:(nullable UIImage *)backgroundImage
                    playerImage:(nullable UIImage *)playerImage
                     enemyImage:(nullable UIImage *)enemyImage
                     completion:(nullable void (^)(BRGameRecord *record))completion {

    NSString *gameID         = [[NSUUID UUID] UUIDString];
    NSString *gameFolderPath = [self.libraryRootPath stringByAppendingPathComponent:gameID];
    NSDate   *createdDate    = [NSDate date];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSError *error = nil;

        [fileManager createDirectoryAtPath:gameFolderPath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&error];
        if (error) {
            NSLog(@"[BRGameLibrary] Failed to create game folder: %@", error);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }

        // Write meta.json
        NSDictionary *metaDict = @{
            @"themeTitle":   themeTitle  ?: @"",
            @"premise":      premise     ?: @"",
            @"hint":         hint        ?: @"",
            @"items":        items       ?: @[],
            @"enemies":      enemies     ?: @[],
            @"seed":         seed        ?: @(0),
            @"createdDate":  @(createdDate.timeIntervalSince1970),
        };
        NSData *metaData = [NSJSONSerialization dataWithJSONObject:metaDict options:0 error:&error];
        if (metaData) {
            [metaData writeToFile:[gameFolderPath stringByAppendingPathComponent:@"meta.json"]
                       atomically:YES];
        }

        // Write images (PNG). Missing images are silently skipped.
        void (^writePNG)(UIImage *, NSString *) = ^(UIImage *image, NSString *filename) {
            if (!image) return;
            NSData *pngData = UIImagePNGRepresentation(image);
            if (!pngData) return;
            [pngData writeToFile:[gameFolderPath stringByAppendingPathComponent:filename]
                      atomically:YES];
        };
        writePNG(backgroundImage, @"background.png");
        writePNG(playerImage,     @"player.png");
        writePNG(enemyImage,      @"enemy.png");

        // Build the in-memory record
        BRGameRecord *record = [[BRGameRecord alloc] init];
        record.gameID         = gameID;
        record.themeTitle     = themeTitle  ?: @"";
        record.premise        = premise     ?: @"";
        record.hint           = hint        ?: @"";
        record.items          = items       ?: @[];
        record.enemies        = enemies     ?: @[];
        record.seed           = seed        ?: @(0);
        record.createdDate    = createdDate;
        record.gameFolderPath = gameFolderPath;

        NSLog(@"[BRGameLibrary] Saved game '%@' → %@", themeTitle, gameID);

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(record); });
        }
    });
}

// ── Load ──────────────────────────────────────────────────────────────────────

- (NSArray<BRGameRecord *> *)allRecords {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *subpaths = [fileManager contentsOfDirectoryAtPath:self.libraryRootPath
                                                                      error:&error];
    if (error || !subpaths) return @[];

    NSMutableArray<BRGameRecord *> *records = [NSMutableArray array];

    for (NSString *folderName in subpaths) {
        // Skip anything that's not a UUID-named directory
        NSString *folderPath = [self.libraryRootPath stringByAppendingPathComponent:folderName];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:folderPath isDirectory:&isDirectory] || !isDirectory) continue;

        NSString *metaPath = [folderPath stringByAppendingPathComponent:@"meta.json"];
        NSData   *metaData = [NSData dataWithContentsOfFile:metaPath];
        if (!metaData) continue;

        NSDictionary *metaDict = [NSJSONSerialization JSONObjectWithData:metaData
                                                                 options:0 error:nil];
        if (![metaDict isKindOfClass:[NSDictionary class]]) continue;

        BRGameRecord *record = [[BRGameRecord alloc] init];
        record.gameID         = folderName;
        record.gameFolderPath = folderPath;
        record.themeTitle     = metaDict[@"themeTitle"] ?: @"";
        record.premise        = metaDict[@"premise"]    ?: @"";
        record.hint           = metaDict[@"hint"]       ?: @"";
        record.items          = [metaDict[@"items"]   isKindOfClass:[NSArray class]]
                                     ? metaDict[@"items"]   : @[];
        record.enemies        = [metaDict[@"enemies"] isKindOfClass:[NSArray class]]
                                     ? metaDict[@"enemies"] : @[];
        record.seed           = [metaDict[@"seed"]    isKindOfClass:[NSNumber class]]
                                     ? metaDict[@"seed"]    : @(0);
        NSNumber *timestampNum = metaDict[@"createdDate"];
        record.createdDate    = timestampNum
                                     ? [NSDate dateWithTimeIntervalSince1970:timestampNum.doubleValue]
                                     : [NSDate distantPast];
        [records addObject:record];
    }

    // Sort newest first
    [records sortUsingComparator:^NSComparisonResult(BRGameRecord *a, BRGameRecord *b) {
        return [b.createdDate compare:a.createdDate];
    }];

    return [records copy];
}

// ── Delete ────────────────────────────────────────────────────────────────────

- (void)deleteRecord:(BRGameRecord *)record {
    if (!record.gameID.length) return;
    NSString *folderPath = [self.libraryRootPath stringByAppendingPathComponent:record.gameID];
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:folderPath error:&error];
    if (error) NSLog(@"[BRGameLibrary] Delete failed: %@", error);
}

@end
