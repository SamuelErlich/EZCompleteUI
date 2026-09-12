// BRCustomGameCreatorViewController.m
// BrainRotGame
// EZCompleteUI v2.1 — Custom Workshop Component
//
// Purpose:
//   Lets the player configure and generate a brand-new custom game: a
//   title, an optional hand-written premise, and player/enemy/background
//   art that can each be left as the backend's default AI generation,
//   replaced with a photo from the library, or generated (and previewed,
//   and regenerated as many times as desired) via BRAssetGenerationSheetViewController.
//   Tapping CREATE GAME posts the configuration to the br-ai edge function
//   (which is the only place the real coin cost is calculated and charged),
//   then writes the resulting game — including any AI-generated art
//   returned in the response or accepted from a preview — to BRGameLibrary,
//   and hands off to BRGameResultViewController so the player can jump
//   straight into the new game.
//
// Changes from v2.0:
//   - FIXED: every br-ai call was reading a session token from the
//     NSUserDefaults key "BRUserSessionJWT", which nothing in the app ever
//     wrote — so requests went out as "Authorization: Bearer " (empty), and
//     generate_workshop_asset correctly rejected them with 401. Replaced
//     brAIEndpointURL / brAIRequestWithTimeout: with
//     performBrAIRequestWithPayload:timeout:completion:, which fetches a
//     real, refreshed-if-needed token via [EZAuthManager shared]
//     getValidAccessToken:. If the player isn't signed in, the network is
//     never touched and both call sites surface a "please sign in" message
//     (via a synthetic "BRWorkshopAuth"/401 error) instead of a generic
//     network failure.
//   - NOTE: create_custom's coin gate in br-ai (index.ts) had the exact same
//     "&& userJwt" pattern, but written to *fail open* — an empty/missing
//     JWT meant the entitlement check was skipped entirely and generation
//     proceeded uncharged. index.ts v1.5 closes this: a missing JWT now
//     returns 401 (handled above) whenever AI generation would actually be
//     billed, for both create_custom and the original new-game flow.
//
// Changes from v1.9:
//   - The "AI Prompt" asset source option now opens
//     BRAssetGenerationSheetViewController instead of a plain text-input
//     sheet. The player types a prompt, taps GENERATE, sees a live preview,
//     and can REGENERATE freely (each call is a separate paid request to
//     br-ai's new generate_workshop_asset action — see index.ts v1.4) before
//     tapping "Use This Image".
//   - Replaced the three separate "image vs prompt" booleans per slot with
//     a single BRAssetSourceKind (Default / UploadedPhoto / AIGenerated),
//     tracked per slot via playerSourceKind/enemySourceKind/backgroundSourceKind.
//     This is now the single source of truth for both the cell subtitle and
//     what gets pre-loaded when reopening the generation sheet for a slot.
//   - New setAIGeneratedImage:prompt:forAssetSlot: stores both the accepted
//     image and the prompt that produced it (so regenerating later starts
//     from the same prompt), mirroring setCustomImage:forAssetSlot: for
//     uploaded photos.
//   - Added coinCostForAssetSlot: as the single numeric source of truth for
//     per-slot pricing (player/enemy: 3, bg: 6), used by both the cell's
//     default-cost label and the generation sheet's cost description.
//   - Removed the "prompts" dict from create_custom's payload: by the time
//     handleCommitAction fires, any AI-generated image has already been
//     produced (and charged) via the generation sheet and is sitting in
//     self.playerImage/enemyImage/backgroundImage, which makes has_custom_X
//     true for that slot — so create_custom never reads a prompt for it.
//
// Changes from v1.8:
//   - The top-right nav bar action now reads "CREATE" / "GAME" on two lines
//     (a custom-view UIButton, since UIBarButtonItem can't wrap its title)
//     instead of "GENERATE", to better describe what tapping it does now
//     that per-asset generation happens earlier in the flow (see the AI
//     Prompt sheet redesign discussed separately).
//
// Changes from v1.7:
//   - On a successful generation, the premise/title/asset thumbnails are
//     now pushed onto a BRGameResultViewController immediately (premise
//     reveal), while the BRGameLibrary disk write happens in parallel.
//     Once the write completes, markReadyWithRecord: swaps the result
//     screen's "Finalizing..." spinner for a PLAY button.
//   - Added onPlayRequested (declared in the header): fires after this
//     view controller and the result screen have both been dismissed,
//     mirroring BRGamePickerViewController.onSelection's "already
//     dismissed before the block fires" contract. "Maybe Later" dismisses
//     the same way without firing onPlayRequested, matching the old exit.
//   - onGameCreated now fires as soon as the record is written (whether or
//     not the player ultimately taps PLAY or "Maybe Later"), so library
//     caches stay in sync regardless of which button the player chooses.
//
// Changes from v1.6:
//   - Replaced the UIAlertControllerStyleActionSheet used to choose how an
//     asset is sourced with BRAssetSourceSheetViewController, a themed
//     table-view bottom sheet that also shows the asset's current state.
//   - Replaced the UIAlertController text-field alerts for the title,
//     premise, and AI prompt fields with BRTextInputSheetViewController, a
//     themed bottom sheet with live character counters and proper keyboard
//     handling.
//   - Introduced the BRAssetSlot enum plus a single set of accessor methods
//     (customImageForAssetSlot:, setCustomPrompt:forAssetSlot:, etc.) that
//     replace the three near-identical player/enemy/background if-else
//     chains that used to be duplicated across this file.
//   - PHPicker image-load failures are now logged via EZLogf instead of
//     being silently dropped.

#import "BRCustomGameCreatorViewController.h"
#import "BRGameLibrary.h"
#import "BRTextInputSheetViewController.h"
#import "BRAssetSourceSheetViewController.h"
#import "BRAssetGenerationSheetViewController.h"
#import "BRGameResultViewController.h"
#import "EZAuthManager.h"
#import <PhotosUI/PhotosUI.h>

// External project configuration references to prevent hardcoded placeholders
extern NSString *const kBRHighScoreURL;

void EZLog(NSInteger level, NSString *tag, NSString *message);
#define EZLogf(level, tag, fmt, ...) EZLog((level),(tag),[NSString stringWithFormat:(fmt),##__VA_ARGS__])

/// The three configurable visual assets for a custom game. Values match the
/// item index within section 1 of the collection view, so the enum can be
/// cast directly from `indexPath.item`.
typedef NS_ENUM(NSInteger, BRAssetSlot) {
    BRAssetSlotPlayer = 0,
    BRAssetSlotEnemy,
    BRAssetSlotBackground
};

/// How a slot's current image (if any) was produced. Drives both the cell
/// subtitle ("Local File Selected" vs "AI Generated" vs the default cost
/// label) and what gets pre-loaded when the player reopens the AI Prompt
/// sheet for this slot.
typedef NS_ENUM(NSInteger, BRAssetSourceKind) {
    BRAssetSourceKindDefault = 0,
    BRAssetSourceKindUploadedPhoto,
    BRAssetSourceKindAIGenerated
};

@interface BRCustomGameCreatorViewController () <UICollectionViewDelegate, UICollectionViewDataSource, PHPickerViewControllerDelegate>

@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

/// Custom-view right bar button (see initializeNavigationItems). Stored
/// directly because UIBarButtonItem.enabled does not reliably propagate to
/// a custom view's interaction state.
@property (nonatomic, strong) UIButton *createGameButton;

// Component Form State
@property (nonatomic, strong, nullable) NSString *gameTitle;
@property (nonatomic, strong, nullable) NSString *gamePremise;

@property (nonatomic, strong, nullable) UIImage *playerImage;
@property (nonatomic, strong, nullable) NSString *playerPrompt;
@property (nonatomic, assign) BRAssetSourceKind playerSourceKind;

@property (nonatomic, strong, nullable) UIImage *enemyImage;
@property (nonatomic, strong, nullable) NSString *enemyPrompt;
@property (nonatomic, assign) BRAssetSourceKind enemySourceKind;

@property (nonatomic, strong, nullable) UIImage *backgroundImage;
@property (nonatomic, strong, nullable) NSString *backgroundPrompt;
@property (nonatomic, assign) BRAssetSourceKind backgroundSourceKind;

/// Which asset slot the player most recently tapped, so the PHPicker and
/// AI generation sheet delegate callbacks know where to store their result.
/// Always set immediately before presenting a picker/sheet, so its default
/// value of BRAssetSlotPlayer is never actually relied upon.
@property (nonatomic, assign) BRAssetSlot activeAssetSlot;

/// Prevents the imported-photo role chooser from reappearing after another
/// sheet is dismissed or after the app returns from the background.
@property (nonatomic, assign) BOOL hasPromptedForInitialWorkshopImage;

@end

@implementation BRCustomGameCreatorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CUSTOM WORKSHOP";
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:1.0];

    [self buildCollectionViewLayout];
    [self initializeNavigationItems];
    [self initializeActivityIndicator];

    EZLogf(2, @"BR_WORKSHOP", @"Custom Game Generator view successfully initialised.");
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.initialWorkshopImage || self.hasPromptedForInitialWorkshopImage) return;

    self.hasPromptedForInitialWorkshopImage = YES;
    UIAlertController *chooser = [UIAlertController
        alertControllerWithTitle:@"Use This Image"
                         message:@"Should this attachment be the game background or the player character?"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [chooser addAction:[UIAlertAction actionWithTitle:@"Use as Background"
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
        [weakSelf setCustomImage:weakSelf.initialWorkshopImage
                  forAssetSlot:BRAssetSlotBackground];
        [weakSelf.collectionView reloadData];
    }]];
    [chooser addAction:[UIAlertAction actionWithTitle:@"Use as Character"
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
        [weakSelf setCustomImage:weakSelf.initialWorkshopImage
                  forAssetSlot:BRAssetSlotPlayer];
        [weakSelf.collectionView reloadData];
    }]];
    [chooser addAction:[UIAlertAction actionWithTitle:@"Choose Later"
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];
    chooser.popoverPresentationController.sourceView = self.view;
    chooser.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                     CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:chooser animated:YES completion:nil];
}

- (void)initializeNavigationItems {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(handleCancelAction)];

    // UIBarButtonItem's title can't wrap, so "CREATE GAME" would either
    // truncate or be shown as one cramped word. A custom-view UIButton with
    // a 2-line title gives us "CREATE" / "GAME" stacked, matching the
    // compact width nav bars give trailing items.
    self.createGameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.createGameButton setTitle:@"CREATE\nGAME" forState:UIControlStateNormal];
    self.createGameButton.titleLabel.numberOfLines = 2;
    self.createGameButton.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.createGameButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    self.createGameButton.tintColor = [UIColor systemYellowColor];
    [self.createGameButton addTarget:self action:@selector(handleCommitAction) forControlEvents:UIControlEventTouchUpInside];
    [self.createGameButton sizeToFit];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.createGameButton];
}

- (void)initializeActivityIndicator {
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.center = self.view.center;
    self.spinner.color = [UIColor systemYellowColor];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
}

- (void)buildCollectionViewLayout {
    UICollectionLayoutListConfiguration *config = [[UICollectionLayoutListConfiguration alloc] initWithAppearance:UICollectionLayoutListAppearanceInsetGrouped];
    config.backgroundColor = [UIColor clearColor];
    UICollectionViewCompositionalLayout *layout = [UICollectionViewCompositionalLayout layoutWithListConfiguration:config];

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:[UICollectionViewListCell class] forCellWithReuseIdentifier:@"FormCell"];
    [self.view addSubview:self.collectionView];
}

#pragma mark - UICollectionViewDataSource & Delegate

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 2;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (section == 0) ? 2 : 3;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewListCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"FormCell" forIndexPath:indexPath];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];

    content.textProperties.color = [UIColor whiteColor];
    content.secondaryTextProperties.color = [UIColor systemGrayColor];
    cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];

    if (indexPath.section == 0) {
        if (indexPath.item == 0) {
            content.text = @"Game Title";
            content.secondaryText = self.gameTitle ? self.gameTitle : @"Required";
        } else {
            content.text = @"Custom Narrative / Premise";
            content.secondaryText = self.gamePremise ? self.gamePremise : @"AI Auto-Generated (-1 Coin)";
        }
    } else {
        BRAssetSlot slot = (BRAssetSlot)indexPath.item;
        content.text = [self displayNameForAssetSlot:slot];

        UIImage *customImage = [self customImageForAssetSlot:slot];

        switch ([self sourceKindForAssetSlot:slot]) {
            case BRAssetSourceKindUploadedPhoto:
                content.secondaryText = @"Local File Selected";
                content.image = customImage;
                break;
            case BRAssetSourceKindAIGenerated:
                content.secondaryText = @"AI Generated";
                content.image = customImage;
                break;
            case BRAssetSourceKindDefault:
            default:
                content.secondaryText = [self defaultGenerationCostLabelForAssetSlot:slot];
                break;
        }

        if (content.image) {
            content.imageProperties.maximumSize = CGSizeMake(32, 32);
            content.imageProperties.reservedLayoutSize = CGSizeMake(32, 32);
            content.imageProperties.cornerRadius = 4.0;
        }
    }

    cell.contentConfiguration = content;
    cell.accessories = @[[[UICellAccessoryDisclosureIndicator alloc] init]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self presentTextFieldSheetForFormItem:indexPath.item];
    } else {
        [self presentAssetSourceOptionsForSlot:(BRAssetSlot)indexPath.item];
    }
}

#pragma mark - Form Input Sheets

/// Presents the themed text-input sheet for either the Game Title (item 0,
/// single line, short limit) or the Custom Premise (item 1, multi-line,
/// longer limit). Saving with an empty string clears the field back to its
/// "AI Auto-Generated" default, matching the previous alert's behaviour.
- (void)presentTextFieldSheetForFormItem:(NSInteger)itemIndex {
    __weak typeof(self) weakSelf = self;

    if (itemIndex == 0) {
        BRTextInputSheetViewController *sheet = [BRTextInputSheetViewController sheetWithTitle:@"Game Title"
                                                                                        subtitle:@"Enter the conceptual title for this instance."
                                                                                     initialText:self.gameTitle
                                                                                     placeholder:@"e.g., NEON DUNGEON"
                                                                                       multiline:NO
                                                                                  characterLimit:40
                                                                                      completion:^(BRTextInputSheetResult result, NSString * _Nullable text) {
            if (result != BRTextInputSheetResultSaved) return;
            weakSelf.gameTitle = (text.length > 0) ? text : nil;
            [weakSelf.collectionView reloadData];
        }];
        [self presentViewController:sheet animated:YES completion:nil];
    } else {
        BRTextInputSheetViewController *sheet = [BRTextInputSheetViewController sheetWithTitle:@"Custom Premise"
                                                                                        subtitle:@"Manually dictate the story elements, or leave blank to rely on backend synthesis."
                                                                                     initialText:self.gamePremise
                                                                                     placeholder:@"Enter narrative specifications..."
                                                                                       multiline:YES
                                                                                  characterLimit:600
                                                                                      completion:^(BRTextInputSheetResult result, NSString * _Nullable text) {
            if (result != BRTextInputSheetResultSaved) return;
            weakSelf.gamePremise = (text.length > 0) ? text : nil;
            [weakSelf.collectionView reloadData];
        }];
        [self presentViewController:sheet animated:YES completion:nil];
    }
}

/// Presents the themed asset-source sheet for the tapped slot, then routes
/// the player's choice to the photo picker, the AI generation sheet, or a reset.
- (void)presentAssetSourceOptionsForSlot:(BRAssetSlot)slot {
    self.activeAssetSlot = slot;

    NSString *displayName = [self displayNameForAssetSlot:slot];
    NSString *currentStateLabel = [self currentStateLabelForAssetSlot:slot];
    BOOL hasCustomAsset = ([self sourceKindForAssetSlot:slot] != BRAssetSourceKindDefault);

    __weak typeof(self) weakSelf = self;
    BRAssetSourceSheetViewController *sheet = [BRAssetSourceSheetViewController sheetForAssetDisplayName:displayName
                                                                                        currentStateLabel:currentStateLabel
                                                                                           hasCustomAsset:hasCustomAsset
                                                                                               completion:^(BRAssetSourceOption selectedOption) {
        [weakSelf handleAssetSourceOption:selectedOption forSlot:slot];
    }];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)handleAssetSourceOption:(BRAssetSourceOption)option forSlot:(BRAssetSlot)slot {
    switch (option) {
        case BRAssetSourceOptionUploadPhoto:
            [self presentPhotoPickerForSlot:slot];
            break;
        case BRAssetSourceOptionAIPrompt:
            [self presentAssetGenerationSheetForSlot:slot];
            break;
        case BRAssetSourceOptionResetToDefault:
            [self resetAssetSlot:slot];
            [self.collectionView reloadData];
            break;
    }
}

- (void)presentPhotoPickerForSlot:(BRAssetSlot)slot {
    self.activeAssetSlot = slot;

    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter imagesFilter];
    config.selectionLimit = 1;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

/// If this slot already has an accepted AI-generated image, the sheet opens
/// with that image and prompt pre-loaded so the player can immediately
/// regenerate or just re-confirm it. Switching to AI Prompt from an
/// uploaded photo (or from the untouched default) starts the sheet fresh —
/// there's no prompt associated with a photo, and no prior generation to
/// show for the default.
- (void)presentAssetGenerationSheetForSlot:(BRAssetSlot)slot {
    self.activeAssetSlot = slot;

    NSString *displayName = [self displayNameForAssetSlot:slot];
    NSString *costDescription = [NSString stringWithFormat:@"Each generation (including regenerates) costs %ld coins.", (long)[self coinCostForAssetSlot:slot]];

    BOOL isAIGenerated = ([self sourceKindForAssetSlot:slot] == BRAssetSourceKindAIGenerated);
    NSString *initialPrompt = isAIGenerated ? [self customPromptForAssetSlot:slot] : nil;
    UIImage *initialImage = isAIGenerated ? [self customImageForAssetSlot:slot] : nil;

    __weak typeof(self) weakSelf = self;
    BRAssetGenerationSheetViewController *sheet = [BRAssetGenerationSheetViewController sheetForAssetDisplayName:displayName
                                                                                                    costDescription:costDescription
                                                                                                      initialPrompt:initialPrompt
                                                                                                       initialImage:initialImage
                                                                                                    generateHandler:^(NSString * _Nonnull prompt, void (^ _Nonnull completion)(UIImage * _Nullable, NSString * _Nullable)) {
        [weakSelf requestWorkshopAssetPreviewForSlot:slot prompt:prompt completion:completion];
    }
                                                                                                           onAccept:^(UIImage * _Nonnull image, NSString * _Nonnull prompt) {
        [weakSelf setAIGeneratedImage:image prompt:prompt forAssetSlot:slot];
        [weakSelf.collectionView reloadData];
    }];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Asset Slot Accessors (single source of truth for player/enemy/background state)

- (NSString *)displayNameForAssetSlot:(BRAssetSlot)slot {
    switch (slot) {
        case BRAssetSlotPlayer:     return @"Player Asset";
        case BRAssetSlotEnemy:      return @"Enemy Asset";
        case BRAssetSlotBackground: return @"Background Environment";
    }
}

/// Numeric single source of truth for per-slot generation cost — mirrors
/// br-ai's WORKSHOP_ASSET_COINS constant (player/enemy: 3, bg: 6). Both
/// defaultGenerationCostLabelForAssetSlot: and the AI generation sheet's
/// cost description derive from this, so the two never drift apart. The
/// actual coin deduction is still enforced server-side; this is for display
/// only.
- (NSInteger)coinCostForAssetSlot:(BRAssetSlot)slot {
    switch (slot) {
        case BRAssetSlotPlayer:     return 3;
        case BRAssetSlotEnemy:      return 3;
        case BRAssetSlotBackground: return 6;
    }
}

- (NSString *)defaultGenerationCostLabelForAssetSlot:(BRAssetSlot)slot {
    return [NSString stringWithFormat:@"Default AI Asset (-%ld Coins)", (long)[self coinCostForAssetSlot:slot]];
}

/// One-line summary of how this asset is currently configured, shown at the
/// top of the asset source sheet.
- (NSString *)currentStateLabelForAssetSlot:(BRAssetSlot)slot {
    switch ([self sourceKindForAssetSlot:slot]) {
        case BRAssetSourceKindUploadedPhoto:
            return @"Currently using a photo from your library.";
        case BRAssetSourceKindAIGenerated: {
            NSString *prompt = [self customPromptForAssetSlot:slot];
            return [NSString stringWithFormat:@"Currently using an AI-generated image from the prompt: \u201C%@\u201D", prompt];
        }
        case BRAssetSourceKindDefault:
        default:
            return [NSString stringWithFormat:@"Currently set to %@.", [self defaultGenerationCostLabelForAssetSlot:slot]];
    }
}

- (BRAssetSourceKind)sourceKindForAssetSlot:(BRAssetSlot)slot {
    switch (slot) {
        case BRAssetSlotPlayer:     return self.playerSourceKind;
        case BRAssetSlotEnemy:      return self.enemySourceKind;
        case BRAssetSlotBackground: return self.backgroundSourceKind;
    }
}

- (nullable UIImage *)customImageForAssetSlot:(BRAssetSlot)slot {
    switch (slot) {
        case BRAssetSlotPlayer:     return self.playerImage;
        case BRAssetSlotEnemy:      return self.enemyImage;
        case BRAssetSlotBackground: return self.backgroundImage;
    }
}

/// Used by the PHPicker delegate when the player uploads a photo for this
/// slot. Clears any previously-accepted AI prompt/image — the two sources
/// are mutually exclusive.
- (void)setCustomImage:(nullable UIImage *)image forAssetSlot:(BRAssetSlot)slot {
    switch (slot) {
        case BRAssetSlotPlayer:
            self.playerImage = image;
            self.playerPrompt = nil;
            self.playerSourceKind = BRAssetSourceKindUploadedPhoto;
            break;
        case BRAssetSlotEnemy:
            self.enemyImage = image;
            self.enemyPrompt = nil;
            self.enemySourceKind = BRAssetSourceKindUploadedPhoto;
            break;
        case BRAssetSlotBackground:
            self.backgroundImage = image;
            self.backgroundPrompt = nil;
            self.backgroundSourceKind = BRAssetSourceKindUploadedPhoto;
            break;
    }
}

- (nullable NSString *)customPromptForAssetSlot:(BRAssetSlot)slot {
    switch (slot) {
        case BRAssetSlotPlayer:     return self.playerPrompt;
        case BRAssetSlotEnemy:      return self.enemyPrompt;
        case BRAssetSlotBackground: return self.backgroundPrompt;
    }
}

/// Called when the player taps "Use This Image" in the AI generation sheet.
/// Stores both the accepted image and the prompt that produced it (so
/// reopening the sheet later can pre-fill both), and clears any
/// previously-uploaded photo — the two sources are mutually exclusive.
- (void)setAIGeneratedImage:(UIImage *)image prompt:(NSString *)prompt forAssetSlot:(BRAssetSlot)slot {
    switch (slot) {
        case BRAssetSlotPlayer:
            self.playerImage = image;
            self.playerPrompt = prompt;
            self.playerSourceKind = BRAssetSourceKindAIGenerated;
            break;
        case BRAssetSlotEnemy:
            self.enemyImage = image;
            self.enemyPrompt = prompt;
            self.enemySourceKind = BRAssetSourceKindAIGenerated;
            break;
        case BRAssetSlotBackground:
            self.backgroundImage = image;
            self.backgroundPrompt = prompt;
            self.backgroundSourceKind = BRAssetSourceKindAIGenerated;
            break;
    }
}

- (void)resetAssetSlot:(BRAssetSlot)slot {
    switch (slot) {
        case BRAssetSlotPlayer:
            self.playerImage = nil;
            self.playerPrompt = nil;
            self.playerSourceKind = BRAssetSourceKindDefault;
            break;
        case BRAssetSlotEnemy:
            self.enemyImage = nil;
            self.enemyPrompt = nil;
            self.enemySourceKind = BRAssetSourceKindDefault;
            break;
        case BRAssetSlotBackground:
            self.backgroundImage = nil;
            self.backgroundPrompt = nil;
            self.backgroundSourceKind = BRAssetSourceKindDefault;
            break;
    }
}

#pragma mark - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    PHPickerResult *result = results.firstObject;
    if (![result.itemProvider canLoadObjectOfClass:[UIImage class]]) {
        EZLogf(2, @"BR_WORKSHOP", @"Picked item cannot be loaded as UIImage; ignoring selection.");
        return;
    }

    BRAssetSlot slot = self.activeAssetSlot;
    __weak typeof(self) weakSelf = self;
    [result.itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(id _Nullable object, NSError * _Nullable error) {
        if (error || ![object isKindOfClass:[UIImage class]]) {
            EZLogf(3, @"BR_WORKSHOP", @"Failed to load picked image: %@", error.localizedDescription);
            return;
        }

        UIImage *picked = (UIImage *)object;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setCustomImage:picked forAssetSlot:slot];
            [weakSelf.collectionView reloadData];
        });
    }];
}

#pragma mark - Network Engine Communication

/// Resolves the br-ai edge function URL from the same project host used
/// elsewhere in the app (kBRHighScoreURL), so this view controller never
/// hardcodes a project ID. Shared by performBrAIRequestWithPayload: — the
/// single source of truth for "where is br-ai".
- (NSURL *)brAIEndpointURL {
    NSURL *referenceURL = [NSURL URLWithString:kBRHighScoreURL];
    NSString *resolvedHost = referenceURL.host ? referenceURL.host : @"localhost:54321";
    NSString *endpointPath = [NSString stringWithFormat:@"https://%@/functions/v1/br-ai", resolvedHost];
    return [NSURL URLWithString:endpointPath];
}

/// Fetches a current, refreshed-if-needed access token from EZAuthManager
/// and, if one is available, POSTs `payload` to br-ai as JSON with it
/// attached as a Bearer token. This is the single source of truth for "how
/// do we talk to br-ai" — shared by handleCommitAction and
/// requestWorkshopAssetPreviewForSlot:prompt:completion:.
///
/// If the player isn't signed in (or the session can't be refreshed), the
/// network is never touched: `completion` is called with a nil data/response
/// and an error in the "BRWorkshopAuth" domain (code 401), which both
/// callers recognise and surface as a "please sign in" message rather than
/// a generic network failure.
- (void)performBrAIRequestWithPayload:(NSDictionary *)payload
                               timeout:(NSTimeInterval)timeout
                            completion:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completion {
    [[EZAuthManager shared] getValidAccessToken:^(NSString * _Nullable token, NSError * _Nullable authError) {
        if (token.length == 0) {
            NSError *signInError = [NSError errorWithDomain:@"BRWorkshopAuth"
                                                         code:401
                                                     userInfo:@{NSLocalizedDescriptionKey: @"Please sign in to use the Custom Workshop."}];
            completion(nil, nil, authError ?: signInError);
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self brAIEndpointURL]];
        request.timeoutInterval = timeout;
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

        NSError *serializationError = nil;
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&serializationError];
        if (serializationError) {
            completion(nil, nil, serializationError);
            return;
        }

        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:completion] resume];
    }];
}

- (void)handleCommitAction {
    if (self.gameTitle.length == 0) {
        UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:@"Validation Error" message:@"A valid non-empty Game Title is required to build a layout." preferredStyle:UIAlertControllerStyleAlert];
        [errorAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:errorAlert animated:YES completion:nil];
        return;
    }

    [self.spinner startAnimating];
    self.navigationItem.leftBarButtonItem.enabled = NO;
    self.createGameButton.enabled = NO;

    // Note: no "prompts" dict here. Any AI-generated asset has already been
    // produced (and charged) by requestWorkshopAssetPreviewForSlot:, and is
    // sitting in self.playerImage/enemyImage/backgroundImage by this point
    // — which makes has_custom_X true for that slot, so create_custom never
    // looks at a prompt for it. Only slots left at BRAssetSourceKindDefault
    // (no image at all) get generated here, using the backend's built-in
    // default prompts.
    NSDictionary *payload = @{
        @"action": @"create_custom",
        @"title": self.gameTitle,
        @"has_custom_premise": @(self.gamePremise != nil),
        @"custom_premise": self.gamePremise ? self.gamePremise : @"",
        @"has_custom_player": @(self.playerImage != nil),
        @"has_custom_enemy": @(self.enemyImage != nil),
        @"has_custom_bg": @(self.backgroundImage != nil),
    };

    __weak typeof(self) weakSelf = self;
    [self performBrAIRequestWithPayload:payload timeout:90.0 completion:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf processNetworkResponseData:data response:response error:error];
        });
    }];
}

/// Calls br-ai's generate_workshop_asset action: a single paid image
/// generation for one asset slot, used by BRAssetGenerationSheetViewController
/// for both the initial GENERATE and every subsequent REGENERATE. Every call
/// — including regenerates — is charged server-side; there is no local cap
/// or free-attempt logic to bypass.
- (void)requestWorkshopAssetPreviewForSlot:(BRAssetSlot)slot
                                     prompt:(NSString *)prompt
                                 completion:(void (^)(UIImage * _Nullable image, NSString * _Nullable errorMessage))completion {
    NSString *slotKey;
    switch (slot) {
        case BRAssetSlotPlayer:     slotKey = @"player"; break;
        case BRAssetSlotEnemy:      slotKey = @"enemy";  break;
        case BRAssetSlotBackground: slotKey = @"bg";     break;
    }

    NSDictionary *payload = @{
        @"action": @"generate_workshop_asset",
        @"slot":   slotKey,
        @"prompt": prompt,
    };

    [self performBrAIRequestWithPayload:payload timeout:60.0 completion:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            if ([error.domain isEqualToString:@"BRWorkshopAuth"]) {
                EZLogf(2, @"BR_WORKSHOP", @"Asset preview blocked — no valid session (slot=%@)", slotKey);
                completion(nil, @"Please sign in to generate AI assets.");
                return;
            }
            EZLogf(3, @"BR_WORKSHOP", @"Asset preview network error (slot=%@): %@", slotKey, error.localizedDescription);
            completion(nil, @"Network error — check your connection and try again.");
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSError *jsonError = nil;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;

        if (httpResponse.statusCode == 402) {
            NSNumber *cost = json[@"cost"];
            completion(nil, [NSString stringWithFormat:@"Insufficient coins. This generation costs %@ coins.", cost ?: @"some"]);
            return;
        }

        if (httpResponse.statusCode != 200 || !json || ![json[@"success"] boolValue]) {
            EZLogf(3, @"BR_WORKSHOP", @"Asset preview rejected (slot=%@) status=%ld", slotKey, (long)httpResponse.statusCode);
            completion(nil, @"Generation failed. Please try again.");
            return;
        }

        NSString *b64 = json[@"b64_json"];
        NSData *decodedData = b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
        UIImage *image = decodedData ? [UIImage imageWithData:decodedData] : nil;

        if (!image) {
            EZLogf(3, @"BR_WORKSHOP", @"Asset preview returned no usable image (slot=%@)", slotKey);
            completion(nil, @"The server didn't return a usable image. Please try again.");
            return;
        }

        completion(image, nil);
    }];
}

- (void)processNetworkResponseData:(nullable NSData *)data response:(nullable NSURLResponse *)response error:(nullable NSError *)error {
    if (error) {
        if ([error.domain isEqualToString:@"BRWorkshopAuth"]) {
            [self terminateWithErrorMessage:@"Please sign in to create custom games."];
            return;
        }
        [self terminateWithErrorMessage:[NSString stringWithFormat:@"Network execution loss: %@", error.localizedDescription]];
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    NSError *jsonError = nil;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;

    if (httpResponse.statusCode != 200) {
        NSString *errCode = json[@"error"] ? json[@"error"] : @"unknown_server_failure";
        if ([errCode isEqualToString:@"insufficient_coins"]) {
            [self terminateWithErrorMessage:[NSString stringWithFormat:@"Insufficient balance. Cost: %@ coins.", json[@"cost"]]];
        } else if (httpResponse.statusCode == 401) {
            [self terminateWithErrorMessage:@"Your session has expired. Please sign in again."];
        } else {
            [self terminateWithErrorMessage:[NSString stringWithFormat:@"Server rejected transaction request: Code %ld", (long)httpResponse.statusCode]];
        }
        return;
    }

    if (!json || ![json[@"success"] boolValue]) {
        [self terminateWithErrorMessage:@"Malformed operational payload signature received from endpoint engine."];
        return;
    }

    EZLogf(1, @"BR_WORKSHOP", @"Transaction clear. Dynamic Cost deducted: %@ coins.", json[@"cost"]);

    NSString *finalPremise = json[@"premise"];
    NSDictionary *assets = json[@"assets"];

    __block UIImage *finalPlayer = self.playerImage;
    __block UIImage *finalEnemy = self.enemyImage;
    __block UIImage *finalBG = self.backgroundImage;

    if (!finalPlayer && assets[@"player"]) {
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:assets[@"player"] options:0];
        if (decodedData) finalPlayer = [UIImage imageWithData:decodedData];
    }

    if (!finalEnemy && assets[@"enemy"]) {
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:assets[@"enemy"] options:0];
        if (decodedData) finalEnemy = [UIImage imageWithData:decodedData];
    }

    if (!finalBG && assets[@"bg"]) {
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:assets[@"bg"] options:0];
        if (decodedData) finalBG = [UIImage imageWithData:decodedData];
    }

    [self.spinner stopAnimating];

    // Reveal the premise/title/thumbnails immediately. The disk write below
    // happens in parallel; markReadyWithRecord: swaps the result screen's
    // "Finalizing..." spinner for the PLAY button once it completes.
    BRGameResultViewController *resultViewController = [self transitionToResultScreenWithTitle:self.gameTitle
                                                                                          premise:finalPremise
                                                                                           player:finalPlayer
                                                                                            enemy:finalEnemy
                                                                                       background:finalBG];

    [self finalizeLocalDiskCommitWithTitle:self.gameTitle
                                    premise:finalPremise
                                     player:finalPlayer
                                      enemy:finalEnemy
                                 background:finalBG
                       resultViewController:resultViewController];
}

/// Pushes (or, if this view controller has no navigation controller,
/// presents) the result screen and wires its two callbacks. Both PLAY and
/// "Maybe Later" dismiss the entire Workshop presentation first — matching
/// BRGamePickerViewController.onSelection's "already dismissed before the
/// block fires" contract — with PLAY additionally firing onPlayRequested.
- (BRGameResultViewController *)transitionToResultScreenWithTitle:(NSString *)title
                                                            premise:(nullable NSString *)premise
                                                             player:(nullable UIImage *)player
                                                              enemy:(nullable UIImage *)enemy
                                                         background:(nullable UIImage *)background {
    BRGameResultViewController *resultViewController = [BRGameResultViewController resultControllerWithTitle:title
                                                                                                        premise:premise
                                                                                                    playerImage:player
                                                                                                     enemyImage:enemy
                                                                                                backgroundImage:background];

    __weak typeof(self) weakSelf = self;
    resultViewController.onPlayTapped = ^(BRGameRecord * _Nonnull record) {
        [weakSelf dismissEntirePresentationAnimated:YES completion:^{
            if (weakSelf.onPlayRequested) {
                weakSelf.onPlayRequested(record);
            }
        }];
    };
    resultViewController.onMaybeLaterTapped = ^{
        [weakSelf dismissEntirePresentationAnimated:YES completion:nil];
    };

    if (self.navigationController) {
        resultViewController.navigationItem.hidesBackButton = YES;
        [self.navigationController pushViewController:resultViewController animated:YES];
    } else {
        resultViewController.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:resultViewController animated:YES completion:nil];
    }

    return resultViewController;
}

/// Dismisses the entire Workshop presentation (this view controller, its
/// navigation controller if any, and the pushed result screen) in one step.
- (void)dismissEntirePresentationAnimated:(BOOL)animated completion:(void (^ _Nullable)(void))completion {
    UIViewController *presentedRoot = self.navigationController ?: self;
    UIViewController *presenter = presentedRoot.presentingViewController;
    if (presenter) {
        [presenter dismissViewControllerAnimated:animated completion:completion];
    } else if (completion) {
        completion();
    }
}

- (void)finalizeLocalDiskCommitWithTitle:(NSString *)title
                                  premise:(nullable NSString *)premise
                                   player:(nullable UIImage *)player
                                    enemy:(nullable UIImage *)enemy
                               background:(nullable UIImage *)bg
                     resultViewController:(BRGameResultViewController *)resultViewController {
    NSNumber *generatedSeed = @(arc4random_uniform(999999) + 1);
    EZLogf(1, @"BR_WORKSHOP", @"Committing structural asset definitions down to persistent storage tier.");

    __weak typeof(self) weakSelf = self;
    __weak typeof(resultViewController) weakResultViewController = resultViewController;
    [[BRGameLibrary shared] saveGameWithThemeTitle:title
                                           premise:(premise ?: @"")
                                              hint:@"Workshop Instance"
                                             items:@[@"Fragment", @"Core Element"]
                                           enemies:@[@"Entity Override"]
                                              seed:generatedSeed
                                   backgroundImage:bg
                                       playerImage:player
                                        enemyImage:enemy
                                        completion:^(BRGameRecord * _Nonnull record) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.onGameCreated) {
                weakSelf.onGameCreated(record);
            }
            [weakResultViewController markReadyWithRecord:record];
        });
    }];
}

- (void)terminateWithErrorMessage:(NSString *)message {
    [self.spinner stopAnimating];
    self.navigationItem.leftBarButtonItem.enabled = YES;
    self.createGameButton.enabled = YES;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Creation Failed" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Acknowledge" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleCancelAction {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
