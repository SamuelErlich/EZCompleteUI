// BRGamePickerViewController.m
// BrainRotGame
// EZCompleteUI v1.0
//
// Layout: full-screen dark background, scrollable 2-column UICollectionView.
// Row 0: "✚ NEW GAME" card (always present, spanning full width via a separate
//         section so it never gets displaced by saved games).
// Rows 1+: one card per saved game, newest first.
//
// Each saved-game card:
//   - Background image fills the cell with aspect-fill clipping.
//   - A vertical gradient (clear → 80% black) darkens the bottom two-thirds.
//   - Theme title in bold white overlaid at the bottom.
//   - Creation date in small gray text below the title.
//   - Long-press triggers a delete confirmation UIAlertController.
//
// The title is also drawn directly into a thumbnail image (renderCardThumbnail:)
// for use as a UIContextMenuConfiguration preview if desired in future.

#import "BRGamePickerViewController.h"
#import "BRGameLibrary.h"

static NSString *const kBRNewGameCellIdentifier    = @"BRNewGameCell";
static NSString *const kBRSavedGameCellIdentifier  = @"BRSavedGameCell";
static NSString *const kBRNewGameSectionIdentifier = @"newGame";

#pragma mark - BRSavedGameCell

/// Private cell: background image + gradient + title/date labels.
@interface BRSavedGameCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *backgroundImageView;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *dateLabel;
- (void)configureWithRecord:(BRGameRecord *)record;
@end

@implementation BRSavedGameCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.contentView.layer.cornerRadius  = 12;
    self.contentView.layer.masksToBounds = YES;
    self.contentView.backgroundColor     = [UIColor colorWithWhite:0.12 alpha:1.0];

    // Background image — fills entire cell
    self.backgroundImageView               = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
    self.backgroundImageView.contentMode   = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.clipsToBounds = YES;
    self.backgroundImageView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentView addSubview:self.backgroundImageView];

    // Gradient overlay: clear at top, dark at bottom
    self.gradientLayer              = [CAGradientLayer layer];
    self.gradientLayer.colors       = @[
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor colorWithRed:0.02 green:0.0 blue:0.08 alpha:0.85].CGColor,
    ];
    self.gradientLayer.locations    = @[@(0.35), @(1.0)];
    self.gradientLayer.frame        = self.contentView.bounds;
    [self.contentView.layer addSublayer:self.gradientLayer];

    // Theme title
    self.titleLabel               = [[UILabel alloc] init];
    self.titleLabel.font          = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightBold];
    self.titleLabel.textColor     = [UIColor whiteColor];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.titleLabel];

    // Date label
    self.dateLabel           = [[UILabel alloc] init];
    self.dateLabel.font      = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.dateLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.dateLabel];

    CGFloat sidePad = 8;
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:sidePad],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-sidePad],
        [self.titleLabel.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-24],
        [self.dateLabel.leadingAnchor   constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.dateLabel.trailingAnchor  constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.dateLabel.bottomAnchor    constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-8],
    ]];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.gradientLayer.frame = self.contentView.bounds;
}

- (void)configureWithRecord:(BRGameRecord *)record {
    self.titleLabel.text        = record.themeTitle;
    self.backgroundImageView.image = record.backgroundImage; // lazy load from disk

    // Relative date string
    NSTimeInterval age = -[record.createdDate timeIntervalSinceNow];
    NSString *dateString;
    if (age < 60)              dateString = @"Just now";
    else if (age < 3600)       dateString = [NSString stringWithFormat:@"%d min ago",  (int)(age / 60)];
    else if (age < 86400)      dateString = [NSString stringWithFormat:@"%d hr ago",   (int)(age / 3600)];
    else if (age < 86400 * 7)  dateString = [NSString stringWithFormat:@"%d days ago", (int)(age / 86400)];
    else {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterNoStyle;
        dateString = [formatter stringFromDate:record.createdDate];
    }
    self.dateLabel.text = dateString;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.backgroundImageView.image = nil;
    self.titleLabel.text           = nil;
    self.dateLabel.text            = nil;
}

@end

#pragma mark - BRNewGameCell

/// Simple "New Game" card with a ✚ and text.
@interface BRNewGameCell : UICollectionViewCell
@end

@implementation BRNewGameCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.contentView.layer.cornerRadius  = 12;
    self.contentView.layer.masksToBounds = YES;
    self.contentView.backgroundColor     = [UIColor colorWithRed:0.05 green:0.0 blue:0.18 alpha:1.0];
    self.contentView.layer.borderColor   = [UIColor systemYellowColor].CGColor;
    self.contentView.layer.borderWidth   = 1.5;

    UILabel *plusLabel      = [[UILabel alloc] init];
    plusLabel.text          = @"✚";
    plusLabel.font          = [UIFont systemFontOfSize:40 weight:UIFontWeightLight];
    plusLabel.textColor     = [UIColor systemYellowColor];
    plusLabel.textAlignment = NSTextAlignmentCenter;
    plusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:plusLabel];

    UILabel *textLabel      = [[UILabel alloc] init];
    textLabel.text          = @"NEW GAME";
    textLabel.font          = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
    textLabel.textColor     = [UIColor systemYellowColor];
    textLabel.textAlignment = NSTextAlignmentCenter;
    textLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:textLabel];

    UILabel *subLabel      = [[UILabel alloc] init];
    subLabel.text          = @"AI-generated";
    subLabel.font          = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    subLabel.textColor     = [UIColor colorWithWhite:0.55 alpha:1.0];
    subLabel.textAlignment = NSTextAlignmentCenter;
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:subLabel];

    [NSLayoutConstraint activateConstraints:@[
        [plusLabel.centerXAnchor  constraintEqualToAnchor:self.contentView.centerXAnchor],
        [plusLabel.centerYAnchor  constraintEqualToAnchor:self.contentView.centerYAnchor constant:-18],
        [textLabel.centerXAnchor  constraintEqualToAnchor:self.contentView.centerXAnchor],
        [textLabel.topAnchor      constraintEqualToAnchor:plusLabel.bottomAnchor constant:6],
        [subLabel.centerXAnchor   constraintEqualToAnchor:self.contentView.centerXAnchor],
        [subLabel.topAnchor       constraintEqualToAnchor:textLabel.bottomAnchor constant:4],
    ]];
    return self;
}

@end

#pragma mark - BRGamePickerViewController

@interface BRGamePickerViewController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray<BRGameRecord *> *savedGames;
@end

@implementation BRGamePickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:1.0];

    // ── Header ────────────────────────────────────────────────────────────────
    UILabel *headerLabel      = [[UILabel alloc] init];
    headerLabel.text          = @"🕹  BRAINROT";
    headerLabel.font          = [UIFont monospacedSystemFontOfSize:26 weight:UIFontWeightBold];
    headerLabel.textColor     = [UIColor systemYellowColor];
    headerLabel.textAlignment = NSTextAlignmentCenter;
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:headerLabel];

    UILabel *subHeader      = [[UILabel alloc] init];
    subHeader.text          = @"Choose a world or generate a new one";
    subHeader.font          = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    subHeader.textColor     = [UIColor colorWithWhite:0.55 alpha:1.0];
    subHeader.textAlignment = NSTextAlignmentCenter;
    subHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subHeader];

    // ── Collection view ───────────────────────────────────────────────────────
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing      = 12;
    layout.sectionInset            = UIEdgeInsetsMake(12, 16, 24, 16);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero
                                             collectionViewLayout:layout];
    self.collectionView.backgroundColor     = [UIColor clearColor];
    self.collectionView.dataSource          = self;
    self.collectionView.delegate            = self;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.collectionView registerClass:[BRNewGameCell class]
            forCellWithReuseIdentifier:kBRNewGameCellIdentifier];
    [self.collectionView registerClass:[BRSavedGameCell class]
            forCellWithReuseIdentifier:kBRSavedGameCellIdentifier];
    [self.view addSubview:self.collectionView];

    [NSLayoutConstraint activateConstraints:@[
        [headerLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [headerLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subHeader.topAnchor constraintEqualToAnchor:headerLabel.bottomAnchor constant:4],
        [subHeader.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.collectionView.topAnchor constraintEqualToAnchor:subHeader.bottomAnchor constant:12],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self reloadSavedGames];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSavedGames];
}

- (void)reloadSavedGames {
    // Load from disk on a background queue, then reload on main
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<BRGameRecord *> *records = [BRGameLibrary.shared allRecords];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.savedGames = records;
            [self.collectionView reloadData];
        });
    });
}

#pragma mark - UICollectionView sizing

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
    CGFloat totalWidth  = CGRectGetWidth(self.collectionView.bounds);
    CGFloat sideInsets  = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat spacing     = layout.minimumInteritemSpacing;
    CGFloat cellWidth   = floor((totalWidth - sideInsets - spacing) / 2.0);
    CGFloat cellHeight  = cellWidth * 1.25; // portrait card aspect ratio
    if (!CGSizeEqualToSize(layout.itemSize, CGSizeMake(cellWidth, cellHeight))) {
        layout.itemSize = CGSizeMake(cellWidth, cellHeight);
        [layout invalidateLayout];
    }
}

#pragma mark - UICollectionViewDataSource

// Section 0 = New Game (always 1 item)
// Section 1 = Saved games
- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 2;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    return (section == 0) ? 1 : (NSInteger)self.savedGames.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return [collectionView dequeueReusableCellWithReuseIdentifier:kBRNewGameCellIdentifier
                                                         forIndexPath:indexPath];
    }
    BRSavedGameCell *cell =
        [collectionView dequeueReusableCellWithReuseIdentifier:kBRSavedGameCellIdentifier
                                                  forIndexPath:indexPath];
    BRGameRecord *record = self.savedGames[indexPath.item];
    [cell configureWithRecord:record];
    return cell;
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        [self dismissWithRecord:nil]; // New Game
    } else {
        BRGameRecord *selectedRecord = self.savedGames[indexPath.item];
        [self dismissWithRecord:selectedRecord];
    }
}

/// Long-press on a saved game cell offers deletion.
- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath
                                         point:(CGPoint)point
    API_AVAILABLE(ios(13.0)) {
    if (indexPath.section == 0) return nil; // no context menu on New Game

    BRGameRecord *record = self.savedGames[indexPath.item];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray *suggestedActions) {
        UIAction *deleteAction = [UIAction actionWithTitle:@"Delete"
                                                     image:[UIImage systemImageNamed:@"trash"]
                                                identifier:nil
                                                   handler:^(__kindof UIAction *action) {
            [self confirmDeleteRecord:record atIndexPath:indexPath];
        }];
        deleteAction.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:record.themeTitle children:@[deleteAction]];
    }];
}

- (void)confirmDeleteRecord:(BRGameRecord *)record atIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Delete \"%@\"?", record.themeTitle]
                         message:@"This permanently removes the game and its images."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [BRGameLibrary.shared deleteRecord:record];
        NSMutableArray *mutable = [self.savedGames mutableCopy];
        [mutable removeObjectAtIndex:indexPath.item];
        self.savedGames = [mutable copy];
        [self.collectionView deleteItemsAtIndexPaths:@[indexPath]];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Dismiss

- (void)dismissWithRecord:(nullable BRGameRecord *)record {
    void (^selectionBlock)(BRGameRecord *) = self.onSelection;
    [self dismissViewControllerAnimated:YES completion:^{
        if (selectionBlock) selectionBlock(record);
    }];
}

@end
