// BrainRotViewController.m
// BrainRotGame
// EZCompleteUI v1.7
//
// Changes from v1.5:
//   - flavorLabel removed entirely. The 76pt story-text strip is gone;
//     that vertical space is reclaimed by the game grid (~80-100pt taller).
//   - Story now told during loading only. The loading overlay is a 3-phase
//     story theater:
//       Phase 1 — spinner + small status text while premise API call runs.
//       Phase 2 — big story title + body fades in once premise JSON arrives;
//                 images continue generating in background while player reads.
//       Phase 3 — "▶ TAP TO BEGIN" appears once all assets are ready.
//                 Player taps when they want; overlay fades and game starts.
//   - All in-game callBrainRotAI narration removed from useAction and
//     attemptMoveByDeltaCol:deltaRow:. Game logic (score, inventory, HP,
//     tile mutation) is identical; the blocking chatbot commentary is gone.
//     callBrainRotAI is still used for asset building (premise + image prompts).
//   - Win/loss replaced UIAlertController with showLevelEndCardWithTitle:
//     subtitle:score:isWin: — a full-screen cinematic card with large text
//     and embedded high-score name entry.
//   - HUD compacted to one line: HP hearts + Score + item count.
//   - Layout recalculated: banner(28) → hud(22) → grid(max) → dpad+buttons.
//   - Renamed movePlayerImageToCol:row:animated: → repositionPlayerImageAnimated:
//     (it reads playerCol/Row from model directly; no redundant params).
//   - extractJSONDictFromString: helper pulled out of buildGameAssetsWithCompletion:
//     for clarity and reuse.
//   - Play Again added to level-end card (replays same seed + saved assets, zero
//     API calls). New Run still generates a fresh world.
//   - restartBtn relocated from next to the d-pad to the HUD row (top of screen)
//     so accidental taps during frantic movement are not possible.
//     Bottom action row is now Use-only (full width).
//   - savedRunSeed + savedRunAssets stored on completion so Play Again works.
//   - Enemy indicators now always drawn in BRGameView (v1.3) so players can
//     see what they are walking into regardless of sprite-sheet load success.

#import "BrainRotViewController.h"
#import "BRGameModel.h"
#import "BRGameView.h"
#import "EZAuthManager.h"
#import <objc/runtime.h>

#pragma mark - UITextField (MaxLength) category

@interface UITextField (MaxLength)
@property (nonatomic, assign) IBInspectable NSUInteger maxLength;
@end

@implementation UITextField (MaxLength)

static const void *kBRMaxLengthKey     = &kBRMaxLengthKey;
static const void *kBRObserverAddedKey = &kBRObserverAddedKey;

- (void)setMaxLength:(NSUInteger)maxLength {
    objc_setAssociatedObject(self, kBRMaxLengthKey, @(maxLength), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *added = objc_getAssociatedObject(self, kBRObserverAddedKey);
    if (!added.boolValue) {
        [self addTarget:self action:@selector(br_enforceMaxLength:)
               forControlEvents:UIControlEventEditingChanged];
        objc_setAssociatedObject(self, kBRObserverAddedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (NSUInteger)maxLength {
    NSNumber *stored = objc_getAssociatedObject(self, kBRMaxLengthKey);
    return stored ? stored.unsignedIntegerValue : 0;
}

- (void)br_enforceMaxLength:(UITextField *)textField {
    NSUInteger maxAllowed = self.maxLength;
    if (maxAllowed == 0) return;
    NSString *currentText = textField.text ?: @"";
    if (currentText.length <= maxAllowed) return;
    UITextRange *selection    = self.selectedTextRange;
    NSInteger    cursorOffset = selection
        ? [self offsetFromPosition:self.beginningOfDocument toPosition:selection.start] : 0;
    textField.text = [currentText substringToIndex:maxAllowed];
    NSInteger      clampedOffset = MIN((NSInteger)maxAllowed, cursorOffset);
    UITextPosition *newPosition  = [self positionFromPosition:self.beginningOfDocument
                                                       offset:clampedOffset];
    if (newPosition) {
        self.selectedTextRange = [self textRangeFromPosition:newPosition toPosition:newPosition];
    }
}

@end

#pragma mark - BrainRotViewController interface

@interface BrainRotViewController () {
    BOOL _endCardFired; // guards against double-triggering win/loss end card
}

// ── Marquee banner ────────────────────────────────────────────────────────────
@property (nonatomic, strong) UIView        *bannerContainerView;
@property (nonatomic, strong) UILabel       *bannerLabel;
@property (nonatomic, strong) CADisplayLink *bannerDisplayLink;
@property (nonatomic, assign) CGFloat        bannerScrollOffset;

// ── Compact single-line HUD ───────────────────────────────────────────────────
@property (nonatomic, strong) UILabel *hudLabel;

// ── Game views ────────────────────────────────────────────────────────────────
@property (nonatomic, strong) UIImageView *backgroundImageView;
@property (nonatomic, strong) BRGameView  *gameView;
@property (nonatomic, strong) UIImageView *playerImageView;
@property (nonatomic, strong) UIImage     *enemyImage;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImageView *> *enemyImageViews;

// ── Story/loading overlay (3-phase) ──────────────────────────────────────────
@property (nonatomic, strong) UIView                  *loadingOverlayView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UILabel                 *loadingPhaseLabel;  // small status (phase 1)
@property (nonatomic, strong) UILabel                 *storyTitleLabel;    // big theme name (phase 2+)
@property (nonatomic, strong) UILabel                 *storyBodyLabel;     // premise text (phase 2+)
@property (nonatomic, strong) UIButton                *beginButton;        // tap-to-begin (phase 3)
@property (nonatomic, copy)   dispatch_block_t         beginButtonAction;  // set when assets ready

// ── Level-end card ────────────────────────────────────────────────────────────
@property (nonatomic, strong) UIView *levelEndCardView;

// ── Controls ──────────────────────────────────────────────────────────────────
@property (nonatomic, strong) UIButton *upBtn;
@property (nonatomic, strong) UIButton *downBtn;
@property (nonatomic, strong) UIButton *leftBtn;
@property (nonatomic, strong) UIButton *rightBtn;
@property (nonatomic, strong) UIButton *actionBtn;
@property (nonatomic, strong) UIButton *restartBtn;

// ── Model / state ─────────────────────────────────────────────────────────────
@property (nonatomic, strong) BRGameModel                *model;
@property (nonatomic, strong) NSMutableArray<NSString *> *inventory;
@property (nonatomic, assign) NSInteger                   score;
@property (nonatomic, strong) NSTimer                    *tickTimer;

// ── Saved run — for Play Again ────────────────────────────────────────────────
// Stored once all assets are ready so playAgainRun can skip API calls.
@property (nonatomic, strong) NSNumber     *savedRunSeed;    // same maze topology
@property (nonatomic, strong) NSDictionary *savedRunAssets;  // images + text from last build

@end

#pragma mark - BrainRotViewController implementation

@implementation BrainRotViewController

static NSString *const kBRBrainRotAIURL = @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/br-ai";
static NSString *const kBRHighScoreURL  = @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/br-highscores";

// File-scope keys for associated objects attached to the end-card submit button.
// Must be file-scope so checkHighScoreQualificationForScore: (setter) and
// submitScoreFromEndCard: (getter) resolve to the same pointer address.
static const void *kBREndCardNameFieldKey  = &kBREndCardNameFieldKey;
static const void *kBREndCardFinalScoreKey = &kBREndCardFinalScoreKey;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _endCardFired = NO;

    // ── Marquee banner ────────────────────────────────────────────────────────
    self.bannerContainerView = [[UIView alloc] init];
    self.bannerContainerView.backgroundColor   = [UIColor colorWithRed:0.05 green:0.0 blue:0.15 alpha:1.0];
    self.bannerContainerView.layer.borderColor = [UIColor systemPurpleColor].CGColor;
    self.bannerContainerView.layer.borderWidth = 1.0;
    self.bannerContainerView.clipsToBounds     = YES;
    [self.view addSubview:self.bannerContainerView];

    self.bannerLabel = [[UILabel alloc] init];
    self.bannerLabel.font            = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold];
    self.bannerLabel.textColor       = [UIColor systemYellowColor];
    self.bannerLabel.backgroundColor = [UIColor clearColor];
    self.bannerLabel.text            = @"🕹 BRAINROT";
    [self.bannerLabel sizeToFit];
    [self.bannerContainerView addSubview:self.bannerLabel];
    [self fetchHighScoresForBanner];

    // ── Compact HUD (one line: hearts + score + item count) ───────────────────
    self.hudLabel = [[UILabel alloc] init];
    self.hudLabel.font          = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
    self.hudLabel.textColor     = [UIColor whiteColor];
    self.hudLabel.textAlignment = NSTextAlignmentCenter;
    self.hudLabel.text          = @"♥♥♥   Score: 0   Items: 0";
    [self.view addSubview:self.hudLabel];

    // ── Background image (behind game grid, provides visual map) ─────────────
    self.backgroundImageView               = [[UIImageView alloc] init];
    self.backgroundImageView.contentMode   = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.clipsToBounds = YES;
    self.backgroundImageView.layer.cornerRadius = 8;
    [self.view addSubview:self.backgroundImageView];

    // ── Game view (transparent tile overlay in image mode) ────────────────────
    self.gameView                     = [[BRGameView alloc] init];
    self.gameView.backgroundColor     = [UIColor colorWithWhite:0.1 alpha:1.0];
    self.gameView.layer.cornerRadius  = 8;
    self.gameView.layer.masksToBounds = YES;
    [self.view addSubview:self.gameView];

    // ── Player image view ─────────────────────────────────────────────────────
    self.playerImageView               = [[UIImageView alloc] init];
    self.playerImageView.contentMode   = UIViewContentModeScaleAspectFill;
    self.playerImageView.clipsToBounds = YES;
    self.playerImageView.layer.borderColor = [UIColor whiteColor].CGColor;
    self.playerImageView.layer.borderWidth = 1.5;
    self.playerImageView.hidden        = YES;
    [self.view addSubview:self.playerImageView];

    self.enemyImageViews = [NSMutableDictionary dictionary];

    // ── Loading / story overlay ───────────────────────────────────────────────
    [self buildLoadingOverlay];
    [self.view addSubview:self.loadingOverlayView];

    // ── D-pad ─────────────────────────────────────────────────────────────────
    self.upBtn    = [self makeArrowButtonWithTitle:@"▲"  selector:@selector(moveUp)];
    self.downBtn  = [self makeArrowButtonWithTitle:@"▼"  selector:@selector(moveDown)];
    self.leftBtn  = [self makeArrowButtonWithTitle:@"◀︎" selector:@selector(moveLeft)];
    self.rightBtn = [self makeArrowButtonWithTitle:@"▶︎" selector:@selector(moveRight)];
    [self.view addSubview:self.upBtn];
    [self.view addSubview:self.downBtn];
    [self.view addSubview:self.leftBtn];
    [self.view addSubview:self.rightBtn];

    // ── Action + restart buttons ──────────────────────────────────────────────
    self.actionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.actionBtn setTitle:@"⚡ Use" forState:UIControlStateNormal];
    self.actionBtn.titleLabel.font    = [UIFont boldSystemFontOfSize:15];
    self.actionBtn.tintColor          = [UIColor systemYellowColor];
    self.actionBtn.layer.cornerRadius = 8;
    self.actionBtn.layer.borderWidth  = 1;
    self.actionBtn.layer.borderColor  = [UIColor systemYellowColor].CGColor;
    [self.actionBtn addTarget:self action:@selector(useAction)
             forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.actionBtn];

    // restartBtn lives in the HUD row at the top — far from the d-pad.
    // This prevents accidental "New Run" taps while tapping movement arrows.
    self.restartBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.restartBtn setTitle:@"↺" forState:UIControlStateNormal];
    self.restartBtn.titleLabel.font    = [UIFont boldSystemFontOfSize:18];
    self.restartBtn.tintColor          = [UIColor colorWithWhite:0.5 alpha:1.0];
    self.restartBtn.layer.cornerRadius = 6;
    self.restartBtn.layer.borderWidth  = 1;
    self.restartBtn.layer.borderColor  = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    [self.restartBtn addTarget:self action:@selector(startNewRun)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.restartBtn];

    [self layoutViews];

    self.inventory = [NSMutableArray array];
    [self startNewRun];

    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                      target:self
                                                    selector:@selector(tick)
                                                    userInfo:nil
                                                     repeats:YES];
}

#pragma mark - Loading Overlay Construction

/// Builds the 3-phase story theater overlay.
/// Phase 1: spinner + small status text while premise call runs.
/// Phase 2: big title + body text fades in when premise arrives; images still generating.
/// Phase 3: spinner hides, "TAP TO BEGIN" button appears when all assets are ready.
- (void)buildLoadingOverlay {
    self.loadingOverlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.loadingOverlayView.backgroundColor  = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:0.97];
    self.loadingOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // Phase 1 — spinner
    self.loadingSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingSpinner.color = [UIColor systemYellowColor];
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingSpinner startAnimating];
    [self.loadingOverlayView addSubview:self.loadingSpinner];

    // Phase 1 — small status text
    self.loadingPhaseLabel = [UILabel new];
    self.loadingPhaseLabel.text          = @"Creating your game…";
    self.loadingPhaseLabel.font          = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.loadingPhaseLabel.textColor     = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.loadingPhaseLabel.textAlignment = NSTextAlignmentCenter;
    self.loadingPhaseLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingOverlayView addSubview:self.loadingPhaseLabel];

    // Phase 2 — big theme title
    self.storyTitleLabel = [UILabel new];
    self.storyTitleLabel.font          = [UIFont monospacedSystemFontOfSize:30 weight:UIFontWeightBold];
    self.storyTitleLabel.textColor     = [UIColor systemYellowColor];
    self.storyTitleLabel.textAlignment = NSTextAlignmentCenter;
    self.storyTitleLabel.numberOfLines = 2;
    self.storyTitleLabel.alpha         = 0;
    self.storyTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingOverlayView addSubview:self.storyTitleLabel];

    // Phase 2 — premise body text
    self.storyBodyLabel = [UILabel new];
    self.storyBodyLabel.font          = [UIFont systemFontOfSize:19 weight:UIFontWeightMedium];
    self.storyBodyLabel.textColor     = [UIColor colorWithWhite:0.90 alpha:1.0];
    self.storyBodyLabel.textAlignment = NSTextAlignmentCenter;
    self.storyBodyLabel.numberOfLines = 0;
    self.storyBodyLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.storyBodyLabel.alpha         = 0;
    self.storyBodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingOverlayView addSubview:self.storyBodyLabel];

    // Phase 3 — begin button
    self.beginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.beginButton setTitle:@"▶  TAP TO BEGIN" forState:UIControlStateNormal];
    self.beginButton.titleLabel.font  = [UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightBold];
    self.beginButton.tintColor        = [UIColor blackColor];
    self.beginButton.backgroundColor  = [UIColor systemYellowColor];
    self.beginButton.layer.cornerRadius = 12;
    self.beginButton.alpha            = 0;
    self.beginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.beginButton addTarget:self action:@selector(beginButtonTapped)
               forControlEvents:UIControlEventTouchUpInside];
    [self.loadingOverlayView addSubview:self.beginButton];

    [NSLayoutConstraint activateConstraints:@[
        // Spinner — vertically centered, slightly above midpoint
        [self.loadingSpinner.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.loadingSpinner.centerYAnchor constraintEqualToAnchor:self.loadingOverlayView.centerYAnchor constant:-40],
        // Phase status text — below spinner
        [self.loadingPhaseLabel.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.loadingPhaseLabel.topAnchor constraintEqualToAnchor:self.loadingSpinner.bottomAnchor constant:14],
        [self.loadingPhaseLabel.leadingAnchor constraintEqualToAnchor:self.loadingOverlayView.leadingAnchor constant:32],
        [self.loadingPhaseLabel.trailingAnchor constraintEqualToAnchor:self.loadingOverlayView.trailingAnchor constant:-32],
        // Story title — upper portion (leaves room for body and button below)
        [self.storyTitleLabel.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.storyTitleLabel.topAnchor constraintEqualToAnchor:self.loadingOverlayView.topAnchor constant:100],
        [self.storyTitleLabel.leadingAnchor constraintEqualToAnchor:self.loadingOverlayView.leadingAnchor constant:28],
        [self.storyTitleLabel.trailingAnchor constraintEqualToAnchor:self.loadingOverlayView.trailingAnchor constant:-28],
        // Story body — below title
        [self.storyBodyLabel.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.storyBodyLabel.topAnchor constraintEqualToAnchor:self.storyTitleLabel.bottomAnchor constant:24],
        [self.storyBodyLabel.leadingAnchor constraintEqualToAnchor:self.loadingOverlayView.leadingAnchor constant:32],
        [self.storyBodyLabel.trailingAnchor constraintEqualToAnchor:self.loadingOverlayView.trailingAnchor constant:-32],
        // Begin button — near bottom
        [self.beginButton.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.beginButton.bottomAnchor constraintEqualToAnchor:self.loadingOverlayView.bottomAnchor constant:-80],
        [self.beginButton.widthAnchor constraintEqualToConstant:240],
        [self.beginButton.heightAnchor constraintEqualToConstant:52],
    ]];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutViews];
}

- (void)layoutViews {
    CGFloat screenWidth  = CGRectGetWidth(self.view.bounds);
    CGFloat screenHeight = CGRectGetHeight(self.view.bounds);
    CGFloat safeTop      = self.view.safeAreaInsets.top;
    CGFloat safeBottom   = self.view.safeAreaInsets.bottom;
    CGFloat sideMargin   = 10;

    // ── Banner ────────────────────────────────────────────────────────────────
    CGFloat bannerHeight = 28;
    self.bannerContainerView.frame = CGRectMake(0, safeTop, screenWidth, bannerHeight);
    CGFloat bannerLabelCenterY = bannerHeight / 2.0;
    CGFloat bannerLabelH       = CGRectGetHeight(self.bannerLabel.frame);
    self.bannerLabel.frame = CGRectMake(self.bannerScrollOffset,
                                        bannerLabelCenterY - bannerLabelH / 2.0,
                                        CGRectGetWidth(self.bannerLabel.frame),
                                        bannerLabelH);

    // ── HUD row: stats label left, restart button right ─────────────────────
    // Restart sits here (far from d-pad) to prevent accidental New Run taps.
    CGFloat hudHeight  = 28;
    CGFloat restartW   = 36;
    CGFloat hudTop     = safeTop + bannerHeight + 4;
    self.restartBtn.frame = CGRectMake(screenWidth - sideMargin - restartW,
                                       hudTop, restartW, hudHeight);
    self.hudLabel.frame   = CGRectMake(sideMargin, hudTop,
                                       screenWidth - sideMargin * 3 - restartW, hudHeight);

    // ── Game grid — use all remaining space above button area ─────────────────
    // Button area: up-row(40) + gap(6) + left/down/right-row(40) + gap(8) + action-row(40) + safeBottom + pad(8)
    CGFloat buttonAreaHeight = 40 + 6 + 40 + 8 + 40 + safeBottom + 8;
    CGFloat gridTop          = CGRectGetMaxY(self.hudLabel.frame) + 6;
    CGFloat gridAvailable    = screenHeight - gridTop - buttonAreaHeight;
    CGFloat gridSize         = MIN(screenWidth - sideMargin * 2, MAX(200, gridAvailable));
    CGFloat gridLeft         = (screenWidth - gridSize) / 2.0;

    self.gameView.frame            = CGRectMake(gridLeft, gridTop, gridSize, gridSize);
    self.backgroundImageView.frame = self.gameView.frame;

    if (!self.playerImageView.hidden && self.model) {
        [self repositionPlayerImageAnimated:NO];
    }

    // ── D-pad ─────────────────────────────────────────────────────────────────
    CGFloat buttonW  = 54;
    CGFloat buttonH  = 40;
    CGFloat dpadTopY = CGRectGetMaxY(self.gameView.frame) + 8;
    CGFloat dpadCX   = screenWidth / 2.0;

    self.upBtn.frame    = CGRectMake(dpadCX - buttonW / 2.0, dpadTopY, buttonW, buttonH);
    self.downBtn.frame  = CGRectMake(dpadCX - buttonW / 2.0, dpadTopY + buttonH + 6, buttonW, buttonH);
    self.leftBtn.frame  = CGRectMake(dpadCX - buttonW * 1.5 - 6, dpadTopY + buttonH + 6, buttonW, buttonH);
    self.rightBtn.frame = CGRectMake(dpadCX + buttonW / 2.0  + 6, dpadTopY + buttonH + 6, buttonW, buttonH);

    // ── Action button — full width row; restart is in the HUD, not here ──────
    CGFloat actionRowY = CGRectGetMaxY(self.downBtn.frame) + 8;
    self.actionBtn.frame = CGRectMake(sideMargin, actionRowY,
                                      screenWidth - sideMargin * 2, 40);
}

- (UIButton *)makeArrowButtonWithTitle:(NSString *)title selector:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font    = [UIFont boldSystemFontOfSize:22];
    button.tintColor          = [UIColor whiteColor];
    button.layer.cornerRadius = 8;
    button.layer.borderWidth  = 1;
    button.layer.borderColor  = [UIColor colorWithWhite:0.35 alpha:1.0].CGColor;
    button.backgroundColor    = [UIColor colorWithWhite:0.12 alpha:1.0];
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Game Loop

- (void)tick {
    [self.gameView setNeedsDisplay];
    [self updateHUD];
    [self refreshEnemyImageViews];
    [self checkForWinOrLoss];
}

- (void)updateHUD {
    if (!self.model) return;
    NSMutableString *hearts = [NSMutableString string];
    // kBRMaxHeartDisplay matches the starting playerHP in BRGameModel.
    // Replace with self.model.maxHP if that property is added to the model later.
    static const NSInteger kBRMaxHeartDisplay = 3;
    for (NSInteger heartIndex = 0; heartIndex < kBRMaxHeartDisplay; heartIndex++) {
        [hearts appendString:(heartIndex < self.model.playerHP) ? @"♥" : @"♡"];
    }
    self.hudLabel.text = [NSString stringWithFormat:@"%@   Score: %ld   Items: %lu",
                          hearts, (long)self.score, (unsigned long)self.inventory.count];
}

- (void)checkForWinOrLoss {
    if (!self.model || _endCardFired) return;
    if (self.model.playerHP <= 0) {
        _endCardFired = YES;
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        [self showLevelEndCardWithTitle:@"BUSTED"
                              subtitle:@"You collapsed. Better luck next time."
                                 score:self.score
                                 isWin:NO];
    } else if (self.model.playerCol == self.model.exitCol &&
               self.model.playerRow == self.model.exitRow) {
        _endCardFired = YES;
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        NSInteger clearBonus = 100 + self.model.playerHP * 5;
        self.score += clearBonus;
        [self updateHUD];
        [self showLevelEndCardWithTitle:@"ESCAPED!"
                              subtitle:[NSString stringWithFormat:
                                        @"Level clear bonus  +%ld pts", (long)clearBonus]
                                 score:self.score
                                 isWin:YES];
    }
}

#pragma mark - Level End Card

/// Full-screen cinematic end card. Replaces UIAlertController for win/loss so we
/// can style it and embed the high-score name field without nested alerts.
- (void)showLevelEndCardWithTitle:(NSString *)cardTitle
                         subtitle:(NSString *)cardSubtitle
                            score:(NSInteger)finalScore
                            isWin:(BOOL)isWin {
    [self.levelEndCardView removeFromSuperview];

    UIView *card = [[UIView alloc] initWithFrame:self.view.bounds];
    card.backgroundColor  = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:0.96];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    card.alpha            = 0;
    self.levelEndCardView = card;
    [self.view addSubview:card];

    UILabel *titleLabel        = [UILabel new];
    titleLabel.text            = cardTitle;
    titleLabel.font            = [UIFont monospacedSystemFontOfSize:52 weight:UIFontWeightBold];
    titleLabel.textColor       = isWin ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    titleLabel.textAlignment   = NSTextAlignmentCenter;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subtitleLabel     = [UILabel new];
    subtitleLabel.text         = cardSubtitle;
    subtitleLabel.font         = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    subtitleLabel.textColor    = [UIColor colorWithWhite:0.85 alpha:1.0];
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    subtitleLabel.numberOfLines = 2;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subtitleLabel];

    UILabel *scoreDisplayLabel  = [UILabel new];
    scoreDisplayLabel.text      = [NSString stringWithFormat:@"SCORE  %ld", (long)finalScore];
    scoreDisplayLabel.font      = [UIFont monospacedSystemFontOfSize:34 weight:UIFontWeightBold];
    scoreDisplayLabel.textColor = [UIColor systemYellowColor];
    scoreDisplayLabel.textAlignment = NSTextAlignmentCenter;
    scoreDisplayLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:scoreDisplayLabel];

    // Play Again — same seed + saved assets, no API calls
    UIButton *playAgainButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [playAgainButton setTitle:@"↩  PLAY AGAIN" forState:UIControlStateNormal];
    playAgainButton.titleLabel.font    = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightBold];
    playAgainButton.tintColor          = [UIColor blackColor];
    playAgainButton.backgroundColor    = [UIColor systemYellowColor];
    playAgainButton.layer.cornerRadius = 12;
    playAgainButton.translatesAutoresizingMaskIntoConstraints = NO;
    [playAgainButton addTarget:self action:@selector(playAgainRun)
             forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:playAgainButton];

    // New Run — fresh world, new API calls
    UIButton *newRunButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [newRunButton setTitle:@"▶  NEW RUN" forState:UIControlStateNormal];
    newRunButton.titleLabel.font    = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];
    newRunButton.tintColor          = [UIColor colorWithWhite:0.6 alpha:1.0];
    newRunButton.translatesAutoresizingMaskIntoConstraints = NO;
    [newRunButton addTarget:self action:@selector(startNewRun) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:newRunButton];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:card.centerYAnchor constant:-100],
        [subtitleLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28],
        [scoreDisplayLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [scoreDisplayLabel.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:28],
        // Play Again is the primary CTA — large, yellow, prominent
        [playAgainButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [playAgainButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-90],
        [playAgainButton.widthAnchor constraintEqualToConstant:220],
        [playAgainButton.heightAnchor constraintEqualToConstant:52],
        // New Run is secondary — smaller, dimmer, below Play Again
        [newRunButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [newRunButton.topAnchor constraintEqualToAnchor:playAgainButton.bottomAnchor constant:10],
    ]];

    [UIView animateWithDuration:0.5 animations:^{ card.alpha = 1.0; }];

    // Asynchronously check if score qualifies for top 10 and add name field if so
    [self checkHighScoreQualificationForScore:finalScore onCard:card aboveButton:newRunButton];
}

/// Fetches top 10 scores. If this run qualifies, injects a name-entry field
/// and submit button into the already-visible end card. Non-qualifying runs: no-op.
- (void)checkHighScoreQualificationForScore:(NSInteger)finalScore
                                     onCard:(UIView *)card
                                aboveButton:(UIButton *)newRunButton {
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:kBRHighScoreURL]];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSArray *topScores   = nil;
        BOOL     qualifies   = NO;
        if (data) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSArray class]]) topScores = parsed;
        }
        if (topScores.count < 10) {
            qualifies = YES;
        } else {
            qualifies = finalScore > [topScores.lastObject[@"score"] integerValue];
        }
        if (!qualifies) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            UITextField *nameField    = [UITextField new];
            nameField.placeholder     = @"Your name  (top 10!)";
            nameField.font            = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];
            nameField.textColor       = [UIColor whiteColor];
            nameField.textAlignment   = NSTextAlignmentCenter;
            nameField.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
            nameField.layer.cornerRadius = 8;
            nameField.layer.borderColor  = [UIColor systemYellowColor].CGColor;
            nameField.layer.borderWidth  = 1.0;
            nameField.returnKeyType      = UIReturnKeyDone;
            nameField.autocorrectionType = UITextAutocorrectionTypeNo;
            nameField.maxLength          = 20;
            nameField.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:nameField];

            UIButton *submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
            [submitButton setTitle:@"🏆  Submit Score" forState:UIControlStateNormal];
            submitButton.titleLabel.font    = [UIFont boldSystemFontOfSize:15];
            submitButton.tintColor          = [UIColor systemYellowColor];
            submitButton.layer.cornerRadius = 8;
            submitButton.layer.borderColor  = [UIColor systemYellowColor].CGColor;
            submitButton.layer.borderWidth  = 1.0;
            submitButton.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:submitButton];

            [NSLayoutConstraint activateConstraints:@[
                [nameField.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [nameField.bottomAnchor constraintEqualToAnchor:newRunButton.topAnchor constant:-16],
                [nameField.widthAnchor constraintEqualToConstant:260],
                [nameField.heightAnchor constraintEqualToConstant:44],
                [submitButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [submitButton.bottomAnchor constraintEqualToAnchor:nameField.topAnchor constant:-10],
                [submitButton.widthAnchor constraintEqualToConstant:200],
                [submitButton.heightAnchor constraintEqualToConstant:40],
            ]];

            // Wire submit button. Keys are file-scope statics (defined near the top of
            // the @implementation) so this setter and submitScoreFromEndCard: (getter)
            // resolve to the same pointer addresses.
            [submitButton addTarget:self action:@selector(submitScoreFromEndCard:)
                   forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(submitButton, kBREndCardNameFieldKey,
                nameField, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(submitButton, kBREndCardFinalScoreKey,
                @(finalScore), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
    }] resume];
}

/// Called when the submit button on the end card is tapped.
/// Reads the name field and final score from associated objects on the sender.
- (void)submitScoreFromEndCard:(UIButton *)submitButton {

    UITextField *nameField  = objc_getAssociatedObject(submitButton, kBREndCardNameFieldKey);
    NSNumber    *scoreValue = objc_getAssociatedObject(submitButton, kBREndCardFinalScoreKey);
    [nameField resignFirstResponder];

    NSString  *playerName  = nameField.text.length > 0 ? nameField.text : @"Anonymous";
    NSInteger  finalScore  = scoreValue.integerValue;

    [self submitScore:finalScore playerName:playerName];
    submitButton.hidden = YES;
    nameField.enabled   = NO;
    nameField.text      = [NSString stringWithFormat:@"✓ Submitted as %@", playerName];
}

#pragma mark - Controls

- (void)moveUp    { [self attemptMoveByDeltaCol:0  deltaRow:-1]; }
- (void)moveDown  { [self attemptMoveByDeltaCol:0  deltaRow:1];  }
- (void)moveLeft  { [self attemptMoveByDeltaCol:-1 deltaRow:0];  }
- (void)moveRight { [self attemptMoveByDeltaCol:1  deltaRow:0];  }

- (void)attemptMoveByDeltaCol:(NSInteger)deltaCol deltaRow:(NSInteger)deltaRow {
    if (!self.model) return;
    BOOL moved = [self.model movePlayerByDC:deltaCol DR:deltaRow];
    if (!moved) return; // wall or boundary — silent, no narration

    [self repositionPlayerImageAnimated:YES];
    BRTile *landedTile = [self.model tileAtCol:self.model.playerCol row:self.model.playerRow];

    if (landedTile.itemName) {
        self.score += 10;
        [self.inventory addObject:landedTile.itemName];
        landedTile.itemName = nil;
    } else if (landedTile.enemyName) {
        // Walking into an enemy without a weapon costs HP; clears the tile
        self.model.playerHP -= 1;
        landedTile.enemyName = nil;
        self.score += 5;
    }
    [self updateHUD];
}

- (void)useAction {
    if (!self.model || self.inventory.count == 0) return;

    NSString *chosenItem = self.inventory.firstObject;
    NSArray<NSValue *> *neighborPositions = [self.model neighborsOfCol:self.model.playerCol
                                                                   row:self.model.playerRow];

    // ── Adjacent enemy — use item as weapon (instant, no narration) ───────────
    for (NSValue *posValue in neighborPositions) {
        CGPoint adjacentPoint = posValue.CGPointValue;
        BRTile *adjacentTile  = [self.model tileAtCol:adjacentPoint.x row:adjacentPoint.y];
        if (!adjacentTile.enemyName) continue;
        adjacentTile.enemyName = nil;
        [self.inventory removeObjectAtIndex:0];
        self.score += 40;
        [self updateHUD];
        [self.gameView setNeedsDisplay];
        return;
    }

    // ── Adjacent wall — try to breach it ──────────────────────────────────────
    BRTile  *wallTileToBreach = nil;
    CGPoint  wallTilePosition = CGPointZero;
    for (NSValue *posValue in neighborPositions) {
        CGPoint adjacentPoint = posValue.CGPointValue;
        BRTile *adjacentTile  = [self.model tileAtCol:adjacentPoint.x row:adjacentPoint.y];
        if (adjacentTile.type == BRTileTypeWall) {
            wallTileToBreach = adjacentTile;
            wallTilePosition = adjacentPoint;
            break;
        }
    }
    if (!wallTileToBreach) return;

    // Success chance: base 30% + up to 40% for longer item names + 25% bonus
    // if the item name appears in the vulnerable hint
    NSInteger breachChance = 30 + (NSInteger)MIN(40, (NSInteger)chosenItem.length * 3);
    NSString *vulnerableHint = self.model.vulnerableHint;
    if (vulnerableHint &&
        [vulnerableHint.lowercaseString containsString:chosenItem.lowercaseString]) {
        breachChance += 25;
    }
    BOOL breachSucceeded = (NSInteger)(arc4random() % 100) < breachChance;

    if (breachSucceeded) {
        BRTile *breachedTile = [self.model tileAtCol:wallTilePosition.x row:wallTilePosition.y];
        breachedTile.type    = BRTileTypeFloor;
        breachedTile.itemName = @"scrap";
        [self.inventory removeObjectAtIndex:0];
        self.score += 25;
    } else {
        // Failure: spawn a warden on a nearby open floor tile, player loses 1 HP
        for (NSValue *posValue in neighborPositions) {
            CGPoint adjacentPoint = posValue.CGPointValue;
            BRTile *adjacentTile  = [self.model tileAtCol:adjacentPoint.x row:adjacentPoint.y];
            BOOL    isPlayerTile  = (adjacentPoint.x == self.model.playerCol &&
                                     adjacentPoint.y == self.model.playerRow);
            if (adjacentTile.type == BRTileTypeFloor && !adjacentTile.enemyName && !isPlayerTile) {
                adjacentTile.enemyName = @"Warden";
                break;
            }
        }
        self.model.playerHP -= 1;
    }
    [self updateHUD];
    [self.gameView setNeedsDisplay];
}

#pragma mark - New Run

- (void)startNewRun {
    _endCardFired = NO;
    self.score    = 0;
    [self.inventory removeAllObjects];
    [self setGameInputEnabled:NO];

    // Tear down previous run
    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView       = nil;
    self.playerImageView.hidden = YES;
    self.playerImageView.image  = nil;
    self.enemyImage             = nil;
    [self clearEnemyImageViews];
    self.backgroundImageView.image  = nil;
    self.gameView.floorsTransparent = NO;
    self.gameView.hidePlayerDot     = NO;
    self.gameView.backgroundColor   = [UIColor colorWithWhite:0.1 alpha:1.0];

    // Seed model so grid exists while assets generate.
    // Store the seed so Play Again can reinitialise with the same topology.
    NSNumber *newSeed   = @((NSInteger)arc4random());
    self.savedRunSeed   = newSeed;
    self.savedRunAssets = nil; // cleared until buildGameAssets completes
    self.model = [[BRGameModel alloc] initWithCols:17 rows:13 seed:newSeed];
    self.gameView.model = self.model;
    [self updateHUD];

    // Reset overlay to phase 1
    self.loadingSpinner.alpha    = 1.0;
    self.loadingPhaseLabel.alpha = 1.0;
    self.loadingPhaseLabel.text  = @"Writing your story…";
    self.storyTitleLabel.alpha   = 0;
    self.storyBodyLabel.alpha    = 0;
    self.beginButton.alpha       = 0;
    self.beginButtonAction       = nil;
    self.loadingOverlayView.hidden = NO;
    self.loadingOverlayView.alpha  = 1.0;
    [self.view bringSubviewToFront:self.loadingOverlayView];

    [self buildGameAssetsWithCompletion:^(NSDictionary *assetDict) {
        NSString *levelDesc  = assetDict[@"levelDesc"]   ?: @"Something stirs.";
        // Note: themeTitle was already applied to storyTitleLabel during phase 2
        // inside buildGameAssetsWithCompletion; no need to re-read it here.
        NSString *hint       = assetDict[@"hint"]        ?: @"";
        NSArray  *items      = assetDict[@"items"]       ?: @[@"widget", @"cable"];
        NSArray  *enemies    = assetDict[@"enemies"]     ?: @[@"warden", @"patrol"];
        UIImage  *bgImage    = assetDict[@"bgImage"];
        UIImage  *playerImg  = assetDict[@"playerImage"];
        UIImage  *enemyImg   = assetDict[@"enemyImage"];

        // Apply background image and rebuild grid from brightness
        if (bgImage) {
            self.backgroundImageView.image  = bgImage;
            self.gameView.backgroundColor   = [UIColor clearColor];
            self.gameView.floorsTransparent = YES;
            [self rebuildGridTilesFromBackgroundImage:bgImage model:self.model];
        }

        // Place items/enemies on finalized tile layout
        self.model.levelFlavor    = levelDesc;
        self.model.aiItems        = items;
        self.model.aiEnemies      = enemies;
        self.model.vulnerableHint = hint;
        [self.model placeItems:items    count:MIN(6, (NSInteger)items.count   * 2)];
        [self.model placeEnemies:enemies count:MIN(6, (NSInteger)enemies.count * 2)];

        if (playerImg) {
            self.playerImageView.image  = playerImg;
            self.gameView.hidePlayerDot = YES;
            self.playerImageView.hidden = NO;
            [self repositionPlayerImageAnimated:NO];
        }
        self.enemyImage = enemyImg;

        // Snapshot everything needed for Play Again (same world, zero API cost)
        self.savedRunAssets = assetDict;

        // Phase 3: reveal begin button, let player tap when ready.
        // weakSelf breaks the retain cycle: self → beginButtonAction (property)
        // → block → self would be a cycle without it.
        self.loadingPhaseLabel.text = @"";
        __weak typeof(self) weakSelf = self;
        self.beginButtonAction = ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [UIView animateWithDuration:0.5 animations:^{
                strongSelf.loadingOverlayView.alpha = 0;
            } completion:^(BOOL finished) {
                strongSelf.loadingOverlayView.hidden = YES;
                [strongSelf setGameInputEnabled:YES];
                [strongSelf refreshEnemyImageViews];
                if (!strongSelf.tickTimer || !strongSelf.tickTimer.isValid) {
                    strongSelf.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                                            target:strongSelf
                                                                          selector:@selector(tick)
                                                                          userInfo:nil
                                                                           repeats:YES];
                }
                [strongSelf.gameView setNeedsDisplay];
            }];
        };
        [UIView animateWithDuration:0.4 animations:^{
            self.loadingSpinner.alpha    = 0;
            self.loadingPhaseLabel.alpha = 0;
            self.beginButton.alpha       = 1.0;
        }];
    }];
}

- (void)beginButtonTapped {
    if (self.beginButtonAction) self.beginButtonAction();
}

#pragma mark - Play Again (same world, no API calls)

/// Restores the same world the player just finished — same seed for tile topology,
/// same images, same items and enemies. Does NOT make any API calls.
/// Falls back to startNewRun if saved assets are missing for any reason.
- (void)playAgainRun {
    if (!self.savedRunSeed || !self.savedRunAssets) {
        [self startNewRun]; // safety fallback
        return;
    }

    _endCardFired = NO;
    self.score    = 0;
    [self.inventory removeAllObjects];
    [self setGameInputEnabled:NO];

    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView = nil;

    // Reinitialise model with the same seed so tile layout matches the saved bgImage
    self.model = [[BRGameModel alloc] initWithCols:17 rows:13 seed:self.savedRunSeed];
    self.gameView.model = self.model;

    // Reapply saved assets (no image re-download, no text call)
    NSDictionary *assets  = self.savedRunAssets;
    NSString *levelDesc   = assets[@"levelDesc"]  ?: @"";
    NSString *hint        = assets[@"hint"]       ?: @"";
    NSArray  *items       = assets[@"items"]      ?: @[];
    NSArray  *enemies     = assets[@"enemies"]    ?: @[];
    UIImage  *bgImage     = assets[@"bgImage"];
    UIImage  *playerImg   = assets[@"playerImage"];
    UIImage  *enemyImg    = assets[@"enemyImage"];

    self.backgroundImageView.image  = bgImage;
    self.gameView.floorsTransparent = (bgImage != nil);
    self.gameView.backgroundColor   = bgImage ? [UIColor clearColor]
                                              : [UIColor colorWithWhite:0.1 alpha:1.0];
    if (bgImage) {
        [self rebuildGridTilesFromBackgroundImage:bgImage model:self.model];
    }

    self.model.levelFlavor    = levelDesc;
    self.model.aiItems        = items;
    self.model.aiEnemies      = enemies;
    self.model.vulnerableHint = hint;
    [self.model placeItems:items    count:MIN(6, (NSInteger)items.count   * 2)];
    [self.model placeEnemies:enemies count:MIN(6, (NSInteger)enemies.count * 2)];

    self.gameView.hidePlayerDot     = (playerImg != nil);
    self.playerImageView.image      = playerImg;
    self.playerImageView.hidden     = (playerImg == nil);
    self.enemyImage                 = enemyImg;
    if (playerImg) {
        [self repositionPlayerImageAnimated:NO];
    }

    [self clearEnemyImageViews];
    [self refreshEnemyImageViews];
    [self updateHUD];
    [self.gameView setNeedsDisplay];
    [self setGameInputEnabled:YES];

    if (!self.tickTimer || !self.tickTimer.isValid) {
        self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                          target:self
                                                        selector:@selector(tick)
                                                        userInfo:nil
                                                         repeats:YES];
    }
}

#pragma mark - Asset Building

- (void)buildGameAssetsWithCompletion:(void (^)(NSDictionary *assetDict))completion {
    NSString *systemPrompt =
        @"You are creating a completely unique, absurd game scenario for a top-down maze game. "
        "Pick something wildly different every time — a rubber duck, a confused grandma, "
        "a sentient hot dog, a wizard cat, a spy potato, anything goofy and unexpected. "
        "Return ONLY a valid JSON object with NO markdown, NO code fences, just raw JSON. "
        "Required keys:\n"
        "  themeTitle: 1-4 word punchy ALL-CAPS theme name (e.g. 'DUCK INSURGENCY')\n"
        "  premise: 2-3 SHORT punchy sentences. Movie-trailer energy. No fancy words.\n"
        "  items: array of 4 short thematic item names (under 20 chars each)\n"
        "  enemies: array of 2 short enemy names\n"
        "  vulnerableHint: 1 short sentence hinting which item is best for breaking walls\n"
        "  backgroundPrompt: DALL-E prompt for a top-down aerial game board matching the "
        "theme. Rich textures. BRIGHT winding paths through DARK blocked areas. "
        "Game-art style. NO characters, NO text in image.\n"
        "  spriteSheetPrompt: DALL-E prompt for a single 1024x1024 image. "
        "TOP HALF: hero character only, centered, full body, white background, bold cartoon outlines. "
        "Thin white dividing line across center. "
        "BOTTOM HALF: villain/enemy only, centered, full body, white background, "
        "bold cartoon outlines, menacing look.";

    [self callBrainRotAI:systemPrompt
             userMessage:@"Generate a new unexpected game premise."
               maxTokens:500
              completion:^(NSString *aiResponse) {

        NSDictionary *premiseDict  = [self extractJSONDictFromString:aiResponse];
        NSString *themeTitle  = premiseDict[@"themeTitle"]     ?: @"BRAINROT";
        NSString *premise     = premiseDict[@"premise"]        ?: @"";
        NSString *hint        = premiseDict[@"vulnerableHint"] ?: @"";
        NSArray  *items       = [premiseDict[@"items"]   isKindOfClass:[NSArray class]]
                                     ? premiseDict[@"items"]   : @[@"widget",@"cable",@"chip",@"lens"];
        NSArray  *enemies     = [premiseDict[@"enemies"] isKindOfClass:[NSArray class]]
                                     ? premiseDict[@"enemies"] : @[@"warden",@"patrol"];
        NSString *bgPrompt    = premiseDict[@"backgroundPrompt"]
            ?: @"top-down game board, bright winding paths through dark zones, no characters";
        NSString *spritePrompt = premiseDict[@"spriteSheetPrompt"]
            ?: @"sprite sheet: top half hero on white, bottom half villain on white, dividing line";

        // Phase 2 — show story text while images generate
        if (premise.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.storyTitleLabel.text = themeTitle;
                self.storyBodyLabel.text  = premise;
                self.loadingPhaseLabel.text = @"Painting the world…";
                [UIView animateWithDuration:0.6 animations:^{
                    self.loadingSpinner.alpha  = 0.3;
                    self.storyTitleLabel.alpha = 1.0;
                    self.storyBodyLabel.alpha  = 1.0;
                }];
            });
        }

        // Generate background + sprite sheet in parallel
        dispatch_group_t imageGroup      = dispatch_group_create();
        __block UIImage *backgroundImg   = nil;
        __block UIImage *spriteSheetImg  = nil;

        dispatch_group_enter(imageGroup);
        [self generateImageWithPrompt:bgPrompt transparent:NO completion:^(UIImage *img) {
            backgroundImg = img;
            dispatch_group_leave(imageGroup);
        }];

        dispatch_group_enter(imageGroup);
        [self generateImageWithPrompt:spritePrompt transparent:YES completion:^(UIImage *img) {
            spriteSheetImg = img;
            dispatch_group_leave(imageGroup);
        }];

        dispatch_group_notify(imageGroup, dispatch_get_main_queue(), ^{
            // Crop sprite sheet: top half = player, bottom half = enemy
            UIImage *playerImg = nil;
            UIImage *enemyImg  = nil;
            if (spriteSheetImg) {
                NSInteger fullPixelW  = (NSInteger)(spriteSheetImg.size.width  * spriteSheetImg.scale);
                NSInteger fullPixelH  = (NSInteger)(spriteSheetImg.size.height * spriteSheetImg.scale);
                NSInteger halfPixelH  = fullPixelH / 2;

                CGImageRef topRef = CGImageCreateWithImageInRect(
                    spriteSheetImg.CGImage, CGRectMake(0, 0, fullPixelW, halfPixelH));
                CGImageRef botRef = CGImageCreateWithImageInRect(
                    spriteSheetImg.CGImage, CGRectMake(0, halfPixelH, fullPixelW, halfPixelH));

                if (topRef) {
                    playerImg = [UIImage imageWithCGImage:topRef
                                                    scale:spriteSheetImg.scale
                                              orientation:UIImageOrientationUp];
                    CGImageRelease(topRef);
                }
                if (botRef) {
                    enemyImg = [UIImage imageWithCGImage:botRef
                                                   scale:spriteSheetImg.scale
                                             orientation:UIImageOrientationUp];
                    CGImageRelease(botRef);
                }
            }

            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            result[@"themeTitle"] = themeTitle;
            result[@"levelDesc"]  = premise;
            result[@"hint"]       = hint;
            result[@"items"]      = items;
            result[@"enemies"]    = enemies;
            if (backgroundImg) result[@"bgImage"]     = backgroundImg;
            if (playerImg)     result[@"playerImage"] = playerImg;
            if (enemyImg)      result[@"enemyImage"]  = enemyImg;
            completion(result);
        });
    }];
}

/// Extracts a JSON dictionary from an AI response that may be pure JSON,
/// JSON inside markdown fences, or JSON embedded in prose.
- (NSDictionary *)extractJSONDictFromString:(NSString *)responseString {
    if (responseString.length == 0) return @{};

    // Try direct parse first
    NSData *directData   = [responseString dataUsingEncoding:NSUTF8StringEncoding];
    id      directParsed = [NSJSONSerialization JSONObjectWithData:directData options:0 error:nil];
    if ([directParsed isKindOfClass:[NSDictionary class]]) return directParsed;

    // Find first { … } block
    NSRange openBrace  = [responseString rangeOfString:@"{"];
    NSRange closeBrace = [responseString rangeOfString:@"}" options:NSBackwardsSearch];
    if (openBrace.location != NSNotFound && closeBrace.location > openBrace.location) {
        NSRange jsonRange = NSMakeRange(openBrace.location,
                                        closeBrace.location - openBrace.location + 1);
        NSString *jsonSubstring = [responseString substringWithRange:jsonRange];
        id subParsed = [NSJSONSerialization JSONObjectWithData:
            [jsonSubstring dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([subParsed isKindOfClass:[NSDictionary class]]) return subParsed;
    }
    return @{};
}

#pragma mark - Image-Based Grid Generation

/// Samples brightness at each tile center, applies an adaptive median threshold,
/// reclassifies tiles as floor (bright) or wall (dark).
/// MUST run before placeItems/placeEnemies.
- (void)rebuildGridTilesFromBackgroundImage:(UIImage *)backgroundImage
                                      model:(BRGameModel *)gameModel {
    NSInteger gridCols    = gameModel.cols;
    NSInteger gridRows    = gameModel.rows;
    NSInteger pixelWidth  = (NSInteger)(backgroundImage.size.width  * backgroundImage.scale);
    NSInteger pixelHeight = (NSInteger)(backgroundImage.size.height * backgroundImage.scale);

    CGColorSpaceRef colorSpace    = CGColorSpaceCreateDeviceRGB();
    NSInteger       bytesPerPixel = 4;
    NSInteger       bytesPerRow   = pixelWidth * bytesPerPixel;
    unsigned char  *pixelBuffer   = calloc((size_t)(pixelHeight * bytesPerRow), 1);

    CGContextRef bitmapCtx = CGBitmapContextCreate(
        pixelBuffer, pixelWidth, pixelHeight, 8, bytesPerRow, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);

    if (!bitmapCtx) { free(pixelBuffer); return; }
    CGContextDrawImage(bitmapCtx, CGRectMake(0, 0, pixelWidth, pixelHeight), backgroundImage.CGImage);
    CGContextRelease(bitmapCtx);

    CGFloat tilePixelW = pixelWidth  / (CGFloat)gridCols;
    CGFloat tilePixelH = pixelHeight / (CGFloat)gridRows;
    NSInteger tileCount = gridRows * gridCols;

    NSMutableArray<NSNumber *> *brightnessValues = [NSMutableArray arrayWithCapacity:tileCount];
    for (NSInteger row = 0; row < gridRows; row++) {
        for (NSInteger col = 0; col < gridCols; col++) {
            NSInteger sampleX = (NSInteger)(col * tilePixelW + tilePixelW / 2.0);
            NSInteger sampleY = (NSInteger)(row * tilePixelH + tilePixelH / 2.0);
            sampleX = MAX(0, MIN(pixelWidth  - 1, sampleX));
            sampleY = MAX(0, MIN(pixelHeight - 1, sampleY));

            NSInteger byteOffset = (sampleY * pixelWidth + sampleX) * bytesPerPixel;
            CGFloat red   = pixelBuffer[byteOffset]     / 255.0;
            CGFloat green = pixelBuffer[byteOffset + 1] / 255.0;
            CGFloat blue  = pixelBuffer[byteOffset + 2] / 255.0;
            // ITU-R BT.601 luminance weights
            [brightnessValues addObject:@(0.299 * red + 0.587 * green + 0.114 * blue)];
        }
    }
    free(pixelBuffer);

    // Adaptive threshold: median brightness clamped to [0.30, 0.65]
    NSArray<NSNumber *> *sorted    = [brightnessValues sortedArrayUsingSelector:@selector(compare:)];
    CGFloat medianBrightness       = sorted[sorted.count / 2].floatValue;
    CGFloat brightnessThreshold    = MAX(0.30, MIN(0.65, medianBrightness));

    for (NSInteger row = 0; row < gridRows; row++) {
        for (NSInteger col = 0; col < gridCols; col++) {
            BRTile *tile = [gameModel tileAtCol:col row:row];
            if (tile.type == BRTileTypeExit) continue; // never reclassify the exit
            CGFloat brightness = brightnessValues[row * gridCols + col].floatValue;
            tile.type = (brightness >= brightnessThreshold) ? BRTileTypeFloor : BRTileTypeWall;
        }
    }

    [gameModel tileAtCol:gameModel.playerCol row:gameModel.playerRow].type = BRTileTypeFloor;
    [self ensureExitReachableInModel:gameModel];
}

/// BFS from player start to verify exit is reachable.
/// If not, carves an L-shaped corridor (horizontal then vertical).
- (void)ensureExitReachableInModel:(BRGameModel *)gameModel {
    NSInteger gridCols  = gameModel.cols;
    NSInteger gridRows  = gameModel.rows;
    NSInteger startCol  = gameModel.playerCol;
    NSInteger startRow  = gameModel.playerRow;
    NSInteger targetCol = gameModel.exitCol;
    NSInteger targetRow = gameModel.exitRow;

    NSMutableData *visitedStorage = [NSMutableData dataWithLength:gridCols * gridRows];
    uint8_t       *visited        = visitedStorage.mutableBytes;

    NSMutableArray<NSValue *> *bfsQueue = [NSMutableArray array];
    [bfsQueue addObject:[NSValue valueWithCGPoint:CGPointMake(startCol, startRow)]];
    visited[startRow * gridCols + startCol] = 1;

    const NSInteger deltaCol[] = { 0,  0, -1, 1 };
    const NSInteger deltaRow[] = {-1,  1,  0, 0 };

    NSInteger queueHead   = 0;
    BOOL      exitReached = NO;

    while (queueHead < (NSInteger)bfsQueue.count) {
        CGPoint   current    = bfsQueue[queueHead++].CGPointValue;
        NSInteger currentCol = (NSInteger)current.x;
        NSInteger currentRow = (NSInteger)current.y;

        if (currentCol == targetCol && currentRow == targetRow) {
            exitReached = YES;
            break;
        }
        for (NSInteger direction = 0; direction < 4; direction++) {
            NSInteger neighborCol = currentCol + deltaCol[direction];
            NSInteger neighborRow = currentRow + deltaRow[direction];
            if (neighborCol < 0 || neighborCol >= gridCols ||
                neighborRow < 0 || neighborRow >= gridRows) continue;
            if (visited[neighborRow * gridCols + neighborCol]) continue;
            BRTile *neighborTile = [gameModel tileAtCol:neighborCol row:neighborRow];
            if (neighborTile.type == BRTileTypeFloor || neighborTile.type == BRTileTypeExit) {
                visited[neighborRow * gridCols + neighborCol] = 1;
                [bfsQueue addObject:[NSValue valueWithCGPoint:CGPointMake(neighborCol, neighborRow)]];
            }
        }
    }

    if (!exitReached) {
        // L-shaped corridor: walk horizontally to exit column, then vertically
        NSInteger carveCol = startCol;
        NSInteger carveRow = startRow;
        NSInteger colStep  = (targetCol > startCol) ? 1 : -1;
        NSInteger rowStep  = (targetRow > startRow) ? 1 : -1;

        while (carveCol != targetCol) {
            BRTile *carveTile = [gameModel tileAtCol:carveCol row:carveRow];
            if (carveTile.type == BRTileTypeWall) carveTile.type = BRTileTypeFloor;
            carveCol += colStep;
        }
        while (carveRow != targetRow) {
            BRTile *carveTile = [gameModel tileAtCol:carveCol row:carveRow];
            if (carveTile.type == BRTileTypeWall) carveTile.type = BRTileTypeFloor;
            carveRow += rowStep;
        }
        NSLog(@"[BrainRot] Exit isolated — carved L-shaped corridor to guarantee reachability.");
    }
}

#pragma mark - Image Generation

- (void)generateImageWithPrompt:(NSString *)prompt
                    transparent:(BOOL)transparent
                     completion:(void (^)(UIImage *_Nullable image))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kBRBrainRotAIURL]];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 90;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"action":      @"generate_image",
        @"prompt":      prompt,
        @"size":        @"1024x1024",
        @"transparent": @(transparent),
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *decodedImage = nil;
        if (!error && data) {
            NSDictionary *json      = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString     *base64Str = json[@"b64_json"];
            if (base64Str.length > 0) {
                NSData *imgData = [[NSData alloc] initWithBase64EncodedString:base64Str
                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
                if (imgData) {
                    decodedImage = [UIImage imageWithData:imgData scale:[UIScreen mainScreen].scale];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(decodedImage); });
    }] resume];
}

#pragma mark - Player Image Positioning

- (CGRect)tileFrameForCol:(NSInteger)col row:(NSInteger)row {
    if (!self.model || CGRectIsEmpty(self.gameView.frame)) return CGRectZero;
    CGFloat tileW = self.gameView.frame.size.width  / (CGFloat)self.model.cols;
    CGFloat tileH = self.gameView.frame.size.height / (CGFloat)self.model.rows;
    return CGRectMake(self.gameView.frame.origin.x + col * tileW,
                      self.gameView.frame.origin.y + row * tileH,
                      tileW, tileH);
}

/// Moves playerImageView to the current model.playerCol/playerRow position.
- (void)repositionPlayerImageAnimated:(BOOL)animated {
    if (!self.model) return;
    CGRect tileFrame = [self tileFrameForCol:self.model.playerCol row:self.model.playerRow];
    if (CGRectIsEmpty(tileFrame)) return;
    CGFloat inset    = tileFrame.size.width * 0.08;
    CGRect  newFrame = CGRectInset(tileFrame, inset, inset);
    self.playerImageView.layer.cornerRadius = newFrame.size.width / 2.0;
    if (animated) {
        [UIView animateWithDuration:0.12 delay:0
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{ self.playerImageView.frame = newFrame; }
                         completion:nil];
    } else {
        self.playerImageView.frame = newFrame;
    }
}

#pragma mark - Enemy Image Views

- (void)refreshEnemyImageViews {
    if (!self.enemyImage || !self.model) return;

    // Build set of tile keys that currently have enemies
    NSMutableSet<NSString *> *liveEnemyKeys = [NSMutableSet set];
    for (NSInteger row = 0; row < self.model.rows; row++) {
        for (NSInteger col = 0; col < self.model.cols; col++) {
            if ([self.model tileAtCol:col row:row].enemyName) {
                [liveEnemyKeys addObject:[NSString stringWithFormat:@"%ld,%ld", (long)col, (long)row]];
            }
        }
    }

    // Remove views for defeated or vacated enemies
    for (NSString *key in self.enemyImageViews.allKeys.copy) {
        if (![liveEnemyKeys containsObject:key]) {
            [self.enemyImageViews[key] removeFromSuperview];
            [self.enemyImageViews removeObjectForKey:key];
        }
    }

    // Add views for newly spawned enemies
    for (NSString *key in liveEnemyKeys) {
        if (self.enemyImageViews[key]) continue;
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@","];
        NSInteger col = [parts[0] integerValue];
        NSInteger row = [parts[1] integerValue];
        CGRect tileFrame = [self tileFrameForCol:col row:row];
        CGFloat inset    = tileFrame.size.width * 0.12;
        CGRect  frame    = CGRectInset(tileFrame, inset, inset);

        UIImageView *enemyView       = [[UIImageView alloc] initWithImage:self.enemyImage];
        enemyView.frame              = frame;
        enemyView.contentMode        = UIViewContentModeScaleAspectFill;
        enemyView.clipsToBounds      = YES;
        enemyView.layer.cornerRadius = frame.size.width / 2.0;
        enemyView.layer.borderColor  = [UIColor systemRedColor].CGColor;
        enemyView.layer.borderWidth  = 1.5;
        [self.view insertSubview:enemyView aboveSubview:self.gameView];
        self.enemyImageViews[key] = enemyView;
    }
}

- (void)clearEnemyImageViews {
    for (UIImageView *enemyView in self.enemyImageViews.allValues) {
        [enemyView removeFromSuperview];
    }
    [self.enemyImageViews removeAllObjects];
}

#pragma mark - Input Enable/Disable

- (void)setGameInputEnabled:(BOOL)enabled {
    self.upBtn.enabled      = enabled;
    self.downBtn.enabled    = enabled;
    self.leftBtn.enabled    = enabled;
    self.rightBtn.enabled   = enabled;
    self.actionBtn.enabled  = enabled;
    self.restartBtn.enabled = enabled;
}

#pragma mark - AI Text Helper

- (void)callBrainRotAI:(NSString *)systemPrompt
           userMessage:(NSString *)userMessage
             maxTokens:(NSInteger)maxTokens
            completion:(void (^)(NSString *_Nullable result))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kBRBrainRotAIURL]];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"system_prompt": systemPrompt,
        @"user_message":  userMessage,
        @"max_tokens":    @(maxTokens),
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) { completion(nil); return; }
            NSDictionary *json   = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString     *result = json[@"result"];
            completion(result.length > 0 ? result : nil);
        });
    }] resume];
}

#pragma mark - Marquee Banner

- (void)fetchHighScoresForBanner {
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:kBRHighScoreURL]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSArray *scores = nil;
        if (data) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSArray class]]) scores = parsed;
        }
        NSMutableString *marqueeText = [NSMutableString stringWithString:@"🕹 BRAINROT ✦ "];
        if (scores.count == 0) {
            [marqueeText appendString:@"No scores yet — be the first!"];
        } else {
            NSArray<NSString *> *medals = @[@"🥇",@"🥈",@"🥉",
                                            @"4th",@"5th",@"6th",
                                            @"7th",@"8th",@"9th",@"10th"];
            for (NSUInteger rankIndex = 0; rankIndex < scores.count; rankIndex++) {
                NSDictionary *entry = scores[rankIndex];
                NSString     *medal = rankIndex < medals.count ? medals[rankIndex] : @"—";
                [marqueeText appendFormat:@"%@ %@  %ld  ✦  ",
                    medal, entry[@"player_name"] ?: @"???",
                    (long)[entry[@"score"] integerValue]];
            }
        }
        NSString *fullScrollText = [NSString stringWithFormat:@"%@     %@", marqueeText, marqueeText];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.bannerLabel.text = fullScrollText;
            [self.bannerLabel sizeToFit];
            self.bannerScrollOffset = CGRectGetWidth(self.view.bounds);
            [self startScrollingBanner];
        });
    }] resume];
}

- (void)startScrollingBanner {
    [self stopScrollingBanner];
    self.bannerDisplayLink = [CADisplayLink displayLinkWithTarget:self
                                                         selector:@selector(scrollBannerTick)];
    [self.bannerDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopScrollingBanner {
    [self.bannerDisplayLink invalidate];
    self.bannerDisplayLink = nil;
}

- (void)scrollBannerTick {
    CGFloat pointsPerFrame  = 50.0 / 60.0; // ~50 pts/sec at 60 fps
    self.bannerScrollOffset -= pointsPerFrame;
    CGFloat labelW           = CGRectGetWidth(self.bannerLabel.frame);
    CGFloat singleCopyWidth  = labelW / 2.0; // text is duplicated; one copy = half total width
    if (self.bannerScrollOffset < -singleCopyWidth) {
        self.bannerScrollOffset += singleCopyWidth;
    }
    CGFloat containerH = CGRectGetHeight(self.bannerContainerView.frame);
    CGFloat labelH     = CGRectGetHeight(self.bannerLabel.frame);
    self.bannerLabel.frame = CGRectMake(self.bannerScrollOffset,
                                        (containerH - labelH) / 2.0,
                                        labelW, labelH);
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopScrollingBanner];
}

#pragma mark - High Score Submission

- (void)submitScore:(NSInteger)finalScore playerName:(NSString *)playerName {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kBRHighScoreURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"player_name": playerName,
        @"score":       @(finalScore),
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[BrainRot] Score submit error: %@", error.localizedDescription);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ [self fetchHighScoresForBanner]; });
        }
    }] resume];
}

@end
