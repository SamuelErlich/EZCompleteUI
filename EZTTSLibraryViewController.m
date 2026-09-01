//
//  EZTTSLibraryViewController.m
//  EZTTSLibrary
//

#import "EZTTSLibraryViewController.h"
#import "EZTTSLibraryManager.h"
#import "EZTTSLibraryClipCell.h"
#import "EZTTSClipEditViewController.h"
#import "TextToSpeechViewController.h"
#import "helpers.h"
#import <AVFoundation/AVFoundation.h>

static NSString * const kEZClipCellReuseID = @"EZTTSLibraryClipCell";

@interface EZTTSLibraryViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, AVAudioPlayerDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UILabel *emptyStateLabel;

@property (nonatomic, copy) NSArray<EZTTSManifestEntry *> *clips;

@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, copy, nullable) NSString *playingUUID;

@end

@implementation EZTTSLibraryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"History";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.clips = @[];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.rowHeight = 84;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[EZTTSLibraryClipCell class] forCellReuseIdentifier:kEZClipCellReuseID];
    [self.view addSubview:self.tableView];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search prompt, voice, or tag";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.emptyStateLabel = [[UILabel alloc] init];
    self.emptyStateLabel.text = @"No archived clips yet — generate something to see it here.";
    self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyStateLabel.font = [UIFont systemFontOfSize:15];
    self.emptyStateLabel.numberOfLines = 0;
    self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyStateLabel.hidden = YES;
    [self.view addSubview:self.emptyStateLabel];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat margin = 32;
    self.emptyStateLabel.frame = CGRectMake(margin, self.view.safeAreaInsets.top + 40,
                                             self.view.bounds.size.width - margin * 2, 80);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Clips may have changed since last time this screen was shown (new generations,
    // deletes elsewhere) — always refresh from the source of truth on appear.
    [self reloadClips];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopPlayback];
}

#pragma mark - Data

- (void)reloadClips {
    NSString *query = self.searchController.searchBar.text;
    NSArray<EZTTSManifestEntry *> *sorted = [[EZTTSLibraryManager sharedManager] searchClipsWithQuery:query];
    self.clips = [self partitionedPinnedFirst:sorted];
    self.emptyStateLabel.hidden = (self.clips.count > 0);
    [self.tableView reloadData];
}

/// Pins favorites to the top, ordered by when each was pinned (most recent pin first) —
/// not by creation date. That's what makes pin order fully user-controllable: pinning
/// (or re-pinning) something always sends it above every other pinned clip.
- (NSArray<EZTTSManifestEntry *> *)partitionedPinnedFirst:(NSArray<EZTTSManifestEntry *> *)sorted {
    NSMutableArray<EZTTSManifestEntry *> *pinned = [NSMutableArray array];
    NSMutableArray<EZTTSManifestEntry *> *unpinned = [NSMutableArray array];
    for (EZTTSManifestEntry *entry in sorted) {
        if (entry.isFavorite) {
            [pinned addObject:entry];
        } else {
            [unpinned addObject:entry];
        }
    }

    NSArray<EZTTSManifestEntry *> *pinnedByPinRecency = [pinned sortedArrayUsingComparator:^NSComparisonResult(EZTTSManifestEntry *a, EZTTSManifestEntry *b) {
        double aTime = [self pinnedAtTimestampForEntry:a];
        double bTime = [self pinnedAtTimestampForEntry:b];
        if (aTime == bTime) return NSOrderedSame;
        return aTime > bTime ? NSOrderedAscending : NSOrderedDescending; // most recent pin first
    }];

    return [pinnedByPinRecency arrayByAddingObjectsFromArray:unpinned];
}

/// Falls back to creation date for clips favorited before this feature existed (no
/// `pinnedAt` in their metadata yet), so old favorites still sort sensibly instead of
/// all colliding at the same default value.
- (double)pinnedAtTimestampForEntry:(EZTTSManifestEntry *)entry {
    id pinnedAt = entry.metadata[@"pinnedAt"];
    if ([pinnedAt isKindOfClass:[NSNumber class]]) return [pinnedAt doubleValue];
    return entry.created.timeIntervalSince1970;
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self reloadClips];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.clips.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZTTSLibraryClipCell *cell = [tableView dequeueReusableCellWithIdentifier:kEZClipCellReuseID forIndexPath:indexPath];
    EZTTSManifestEntry *entry = self.clips[indexPath.row];
    NSURL *audioURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:entry];

    [cell configureWithEntry:entry audioURL:audioURL];
    [cell setPlaying:[entry.uuid isEqualToString:self.playingUUID]];

    __weak typeof(self) weakSelf = self;
    cell.onPlayTapped = ^{ [weakSelf togglePlaybackForEntry:entry]; };
    cell.onFavoriteTapped = ^{ [weakSelf toggleFavoriteForEntry:entry]; };
    cell.onRegenerateTapped = ^{ [weakSelf regenerateEntry:entry]; };
    cell.onEditTapped = ^{ [weakSelf editEntry:entry]; };

    return cell;
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
                leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    EZTTSManifestEntry *entry = self.clips[indexPath.row];
    __weak typeof(self) weakSelf = self;

    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                           title:@"Share"
                                                                         handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf presentShareSheetForEntry:entry sourceView:sourceView];
        completionHandler(YES);
    }];
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    share.backgroundColor = [UIColor systemBlueColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[share]];
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
                trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    EZTTSManifestEntry *entry = self.clips[indexPath.row];
    __weak typeof(self) weakSelf = self;

    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                            title:@"Delete"
                                                                          handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf deleteEntry:entry completion:^(BOOL success) {
            completionHandler(success);
        }];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    EZTTSManifestEntry *entry = self.clips[indexPath.row];
    [self togglePlaybackForEntry:entry];
}

#pragma mark - Regenerate / Edit

/// "Regenerate" doesn't call any network code itself — it sends the user to the compose
/// screen with the same prompt and voice already filled in, one tap from a new clip.
/// This deliberately avoids duplicating -performTTSWithText:...'s network/auth logic
/// onto this screen; that method reads its voice/speed from live UI fields on the
/// compose screen, so reusing it safely means reusing that screen.
- (void)regenerateEntry:(EZTTSManifestEntry *)entry {
    TextToSpeechViewController *composeVC = [[TextToSpeechViewController alloc] init];
    [composeVC prefillWithText:entry.prompt voiceID:entry.voiceID voiceName:entry.voiceName];
    [self.navigationController pushViewController:composeVC animated:YES];
}

- (void)editEntry:(EZTTSManifestEntry *)entry {
    EZTTSClipEditViewController *editVC = [[EZTTSClipEditViewController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:editVC animated:YES];
}

#pragma mark - Mutations

- (void)toggleFavoriteForEntry:(EZTTSManifestEntry *)entry {
    NSIndexPath *oldIndexPath = [self indexPathForClipUUID:entry.uuid];
    EZTTSLibraryManager *manager = [EZTTSLibraryManager sharedManager];
    __weak typeof(self) weakSelf = self;
    void (^completion)(EZTTSManifestEntry *, NSError *) = ^(EZTTSManifestEntry *updated, NSError *error) {
        if (error) {
            [weakSelf presentErrorAlert:error title:@"Couldn't update favorite"];
            return;
        }
        [weakSelf applyFavoriteChange:updated fromIndexPath:oldIndexPath];
    };
    if (entry.isFavorite) {
        [manager unfavoriteClipWithUUID:entry.uuid completion:completion];
    } else {
        [manager favoriteClipWithUUID:entry.uuid completion:completion];
    }
}

/// Recomputes the pinned-first ordering against the latest data, then animates just the
/// one row that changed from `oldIndexPath` to its new position — everything else on
/// screen stays exactly where it is, so this doesn't retrigger waveform loads or reset
/// scroll position for unrelated rows.
- (void)applyFavoriteChange:(EZTTSManifestEntry *)updatedEntry fromIndexPath:(nullable NSIndexPath *)oldIndexPath {
    NSString *query = self.searchController.searchBar.text;
    NSArray<EZTTSManifestEntry *> *sorted = [[EZTTSLibraryManager sharedManager] searchClipsWithQuery:query];
    NSArray<EZTTSManifestEntry *> *newClips = [self partitionedPinnedFirst:sorted];

    NSIndexPath *newIndexPath = nil;
    NSUInteger idx = [newClips indexOfObjectPassingTest:^BOOL(EZTTSManifestEntry *e, NSUInteger i, BOOL *stop) {
        return [e.uuid isEqualToString:updatedEntry.uuid];
    }];
    if (idx != NSNotFound) newIndexPath = [NSIndexPath indexPathForRow:idx inSection:0];

    self.clips = newClips;
    self.emptyStateLabel.hidden = (self.clips.count > 0);

    if (oldIndexPath && newIndexPath && ![oldIndexPath isEqual:newIndexPath]) {
        __weak typeof(self) weakSelf = self;
        [self.tableView performBatchUpdates:^{
            [self.tableView moveRowAtIndexPath:oldIndexPath toIndexPath:newIndexPath];
        } completion:^(BOOL finished) {
            // The move animation relocates the existing cell instance as-is — its star
            // glyph still reflects the pre-toggle state, so patch just that in place.
            EZTTSLibraryClipCell *cell = (EZTTSLibraryClipCell *)[weakSelf.tableView cellForRowAtIndexPath:newIndexPath];
            [cell setFavorite:updatedEntry.isFavorite];
        }];
    } else {
        // Nothing to animate (uuid not found, or position genuinely didn't change) —
        // fall back to a plain reload rather than risk an inconsistent table state.
        [self.tableView reloadData];
    }
}

- (void)deleteEntry:(EZTTSManifestEntry *)entry completion:(void (^)(BOOL success))completion {
    if ([entry.uuid isEqualToString:self.playingUUID]) {
        [self stopPlayback];
    }
    [[EZTTSLibraryManager sharedManager] deleteClipWithUUID:entry.uuid completion:^(BOOL success, NSError * _Nullable error) {
        if (!success) {
            [self presentErrorAlert:error title:@"Couldn't delete clip"];
            completion(NO);
            return;
        }
        [self reloadClips];
        completion(YES);
    }];
}

#pragma mark - Playback

- (void)togglePlaybackForEntry:(EZTTSManifestEntry *)entry {
    if ([entry.uuid isEqualToString:self.playingUUID]) {
        [self stopPlayback];
        return;
    }

    [self stopPlayback]; // stop whatever else was playing first

    NSURL *audioURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:entry];
    NSError *playerError;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:audioURL error:&playerError];
    if (!player) {
        [self presentErrorAlert:playerError title:@"Couldn't play clip"];
        return;
    }

    player.delegate = self;
    player.enableRate = YES;
    id storedRate = entry.metadata[@"playbackRate"];
    player.rate = [storedRate isKindOfClass:[NSNumber class]] ? [storedRate floatValue] : 1.0f;
    [player prepareToPlay];
    [player play];

    self.player = player;
    self.playingUUID = entry.uuid;
    [self updateCellPlayingStateForUUID:entry.uuid playing:YES];

    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                            target:self
                                                          selector:@selector(handleProgressTick)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)handleProgressTick {
    if (!self.player || self.playingUUID == nil) return;
    CGFloat progress = self.player.duration > 0 ? (CGFloat)(self.player.currentTime / self.player.duration) : 0;
    [self updateCellPlaybackProgressForUUID:self.playingUUID progress:progress];
}

- (void)stopPlayback {
    [self.player stop];
    self.player = nil;
    [self.progressTimer invalidate];
    self.progressTimer = nil;

    NSString *previousUUID = self.playingUUID;
    self.playingUUID = nil;
    if (previousUUID) [self updateCellPlayingStateForUUID:previousUUID playing:NO];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self stopPlayback];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError * _Nullable)error {
    [self stopPlayback];
    if (error) [self presentErrorAlert:error title:@"Playback error"];
}

#pragma mark - Cell lookup helpers

- (void)updateCellPlayingStateForUUID:(NSString *)uuid playing:(BOOL)playing {
    NSIndexPath *indexPath = [self indexPathForClipUUID:uuid];
    if (!indexPath) return;
    EZTTSLibraryClipCell *cell = (EZTTSLibraryClipCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    if (cell) [cell setPlaying:playing];
}

- (void)updateCellPlaybackProgressForUUID:(NSString *)uuid progress:(CGFloat)progress {
    NSIndexPath *indexPath = [self indexPathForClipUUID:uuid];
    if (!indexPath) return;
    EZTTSLibraryClipCell *cell = (EZTTSLibraryClipCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    if (cell) [cell setPlaybackProgress:progress animated:NO];
}

- (nullable NSIndexPath *)indexPathForClipUUID:(NSString *)uuid {
    NSUInteger idx = [self.clips indexOfObjectPassingTest:^BOOL(EZTTSManifestEntry *entry, NSUInteger i, BOOL *stop) {
        return [entry.uuid isEqualToString:uuid];
    }];
    if (idx == NSNotFound) return nil;
    return [NSIndexPath indexPathForRow:idx inSection:0];
}

#pragma mark - Sharing

- (void)presentShareSheetForEntry:(EZTTSManifestEntry *)entry sourceView:(UIView *)sourceView {
    NSURL *exportURL = [[EZTTSLibraryManager sharedManager] exportURLForClipWithUUID:entry.uuid];
    if (!exportURL) {
        NSError *missing = [NSError errorWithDomain:@"EZTTSLibraryViewController"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"That clip's audio file could not be found on disk."}];
        [self presentErrorAlert:missing title:@"Couldn't share clip"];
        return;
    }

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[exportURL]
                                                                                applicationActivities:nil];
    // Required on iPad — UIActivityViewController is presented as a popover there, and
    // without an anchor it throws at presentation time.
    if (activityVC.popoverPresentationController) {
        activityVC.popoverPresentationController.sourceView = sourceView;
        activityVC.popoverPresentationController.sourceRect = sourceView.bounds;
    }
    [self presentViewController:activityVC animated:YES completion:nil];
}

#pragma mark - Errors

- (void)presentErrorAlert:(NSError *)error title:(NSString *)title {
    EZLogf(EZLogLevelError, @"TTSLibrary", @"%@: %@", title, error.localizedDescription);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:error.localizedDescription
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
