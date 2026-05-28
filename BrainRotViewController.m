// BrainRotViewController.m
// BrainRotGame
// EZCompleteUI v2.5
//
// Purpose:
//   Main game view controller for BrainRot — a top-down AI-generated maze game.
//   Owns the full game lifecycle: new-run asset generation, saved-game loading,
//   player movement and combat, HUD, level-end card, high-score submission, and
//   the marquee banner. Also manages all audio: looping background music and
//   reactive sound effects for every meaningful player action.
//
// Changes from v2.4:
//   - AVFoundation audio system added.
//   - Background music loops automatically from game start through end card.
//     Three theme tracks in Resources/sounds/ (brainrot-theme1/2/3.mp3);
//     theme1 is the primary loop (70% weight), theme2 and theme3 play
//     occasionally for variety.
//   - Nine categorised SFX in Resources/sounds/ (.aiff), preloaded at launch:
//       player-movement / player-movement2   — random variant on each step
//       found-item      / found-item2        — random variant on item pickup
//       hurt-player     / hurt-player2       — random variant when player is hit
//       wall-blast-success                   — wall breached or bare-hands crumble
//       wall-blast-fail                      — wall breach failure (warden spawns)
//       enemy-died                           — enemy defeated via Use action
//   - setupAudioSession, preloadSoundEffects, startBackgroundMusic,
//     stopBackgroundMusic, fadeOutAndStopPlayer:, playSoundNamed:,
//     playRandomVariantOfSound:variantCount: added under #pragma mark - Audio.
//   - Music starts in startNewRun (loading screen), loadGameRecord:, and
//     playAgainRun. Fades out in viewDidDisappear:.
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
#import "BRGameLibrary.h"
#import "BRGamePickerViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import <AVFoundation/AVFoundation.h>
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

@interface BrainRotViewController () <UITextFieldDelegate> {
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
// backgroundImageView removed in v2.0 — background image is now rendered
// inside BRGameView.drawRect, cropped to the viewport, so it scrolls in
// perfect sync with the tile overlay. See BRGameView v1.5.
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

// ── Current game record (set after save, used by Play Again) ────────────────────
@property (nonatomic, strong, nullable) BRGameRecord *currentGameRecord;

// ── Saved run — for Play Again ────────────────────────────────────────────────
// Stored once all assets are ready so playAgainRun can skip API calls.
@property (nonatomic, strong) NSNumber     *savedRunSeed;    // same maze topology
@property (nonatomic, strong) NSDictionary *savedRunAssets;  // images + text from last build

// ── Audio ─────────────────────────────────────────────────────────────────────
// musicPlayer loops background music throughout gameplay. sfxPlayers holds one
// pre-loaded AVAudioPlayer per sound effect, keyed by the filename (sans extension).
// Both are set up once in viewDidLoad and reused for the lifetime of the controller.
@property (nonatomic, strong) AVAudioPlayer                          *musicPlayer;
@property (nonatomic, strong) NSMutableDictionary<NSString *,
                                                  AVAudioPlayer *>   *sfxPlayers;

// ── Maze template image ───────────────────────────────────────────────────────
// B&W rendering of the model's tile layout, passed as a reference image to the
// background image API call so the AI skins a known-good topology rather than
// inventing one that may have disconnected paths or no route to the exit.
@property (nonatomic, strong) NSData *savedMazeTemplateImageData;

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

    // Audio must be configured before any game starts so SFX are ready to fire
    // the instant the player taps a button for the first time.
    [self setupAudioSession];
    [self preloadSoundEffects];

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

    // Background image is rendered inside BRGameView (v1.5), so no separate
    // UIImageView is needed. gameView.backgroundImage drives everything.

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
    self.loadingOverlayView.hidden = YES;
    self.loadingOverlayView.alpha  = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Members get the full picker (saved library + new game option).
        // Non-members go straight to a new game — no library, no save.
        if ([self userHasMembership]) {
            [self showGamePicker];
        } else {
            [self startNewRun];
        }
    });

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

    self.gameView.frame = CGRectMake(gridLeft, gridTop, gridSize, gridSize);

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
        // Scoring breakdown:
        //   Base clear:          100 pts
        //   Per heart remaining: +20 pts each  (encourages survival)
        //   Per item in bag:     +15 pts each  (rewards item collection)
        NSInteger heartBonus = self.model.playerHP * 20;
        NSInteger itemBonus  = (NSInteger)self.inventory.count * 15;
        NSInteger clearBonus = 100 + heartBonus + itemBonus;
        self.score += clearBonus;
        [self updateHUD];
        NSString *bonusBreakdown = [NSString stringWithFormat:
            @"+100 clear  +%ld hearts  +%ld items", (long)heartBonus, (long)itemBonus];
        [self showLevelEndCardWithTitle:@"ESCAPED!"
                              subtitle:bonusBreakdown
                                 score:self.score
                                 isWin:YES];
    }
}

#pragma mark - Level End Card

/// Dismisses the end card and routes appropriately.
/// Members see the full picker; non-members start a new run directly.
- (void)showGamePickerFromEndCard {
    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView = nil;
    if ([self userHasMembership]) {
        [self showGamePicker];
    } else {
        [self startNewRun];
    }
}

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
    [newRunButton addTarget:self action:@selector(showGamePickerFromEndCard) forControlEvents:UIControlEventTouchUpInside];
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
///
/// Keyboard handling strategy:
///   - Card animates upward when keyboard appears so the name field is always visible.
///   - Return key dismisses the keyboard (textFieldShouldReturn:).
///   - Tapping anywhere outside the field on the card also dismisses the keyboard.
///   - Keyboard observers are removed when the card is removed from the hierarchy.
- (void)checkHighScoreQualificationForScore:(NSInteger)finalScore
                                     onCard:(UIView *)card
                                aboveButton:(UIButton *)newRunButton {
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:kBRHighScoreURL]];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSArray *topScores = nil;
        BOOL     qualifies = NO;
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
            // ── Name field ────────────────────────────────────────────────────
            UITextField *nameField       = [UITextField new];
            nameField.placeholder        = @"Your name (top 10!)";
            nameField.font               = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
            nameField.textColor          = [UIColor whiteColor];
            nameField.textAlignment      = NSTextAlignmentCenter;
            nameField.backgroundColor    = [UIColor colorWithWhite:0.18 alpha:1.0];
            nameField.layer.cornerRadius = 10;
            nameField.layer.borderColor  = [UIColor systemYellowColor].CGColor;
            nameField.layer.borderWidth  = 1.5;
            nameField.returnKeyType      = UIReturnKeyDone;
            nameField.autocorrectionType = UITextAutocorrectionTypeNo;
            nameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
            nameField.maxLength          = 20;
            nameField.delegate           = self;
            nameField.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:nameField];

            // ── Submit button ─────────────────────────────────────────────────
            UIButton *submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
            [submitButton setTitle:@"🏆  Submit Score" forState:UIControlStateNormal];
            submitButton.titleLabel.font    = [UIFont boldSystemFontOfSize:16];
            submitButton.tintColor          = [UIColor blackColor];
            submitButton.backgroundColor    = [UIColor systemYellowColor];
            submitButton.layer.cornerRadius = 10;
            submitButton.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:submitButton];

            // ── Layout: name field centered, submit above it ──────────────────
            // Both anchored to center-Y so they stay visible on all screen sizes.
            // When the keyboard appears we translate the card up — centering here
            // ensures the field lands above the keyboard after the shift.
            [NSLayoutConstraint activateConstraints:@[
                [nameField.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [nameField.centerYAnchor constraintEqualToAnchor:card.centerYAnchor constant:60],
                [nameField.widthAnchor constraintEqualToConstant:280],
                [nameField.heightAnchor constraintEqualToConstant:50],
                [submitButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [submitButton.bottomAnchor constraintEqualToAnchor:nameField.topAnchor constant:-14],
                [submitButton.widthAnchor constraintEqualToConstant:220],
                [submitButton.heightAnchor constraintEqualToConstant:48],
            ]];

            // ── Tap-to-dismiss keyboard on card background ────────────────────
            UITapGestureRecognizer *tapToDismiss =
                [[UITapGestureRecognizer alloc] initWithTarget:nameField
                                                        action:@selector(resignFirstResponder)];
            tapToDismiss.cancelsTouchesInView = NO; // let button taps still fire
            [card addGestureRecognizer:tapToDismiss];

            // ── Keyboard avoidance: slide card up when keyboard appears ───────
            // We capture the card in the blocks using a weak ref; if the card is
            // removed (user taps New Run) before the keyboard fires, we no-op.
            __weak UIView *weakCard = card;
            __block id keyboardShowObserver = nil;
            __block id keyboardHideObserver = nil;

            keyboardShowObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIKeyboardWillShowNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                UIView *strongCard = weakCard;
                if (!strongCard || !strongCard.window) return;
                NSDictionary *userInfo = note.userInfo;
                CGRect keyboardFrame = [userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
                double duration      = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
                UIViewAnimationCurve curve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];

                // How much of the card is hidden behind the keyboard?
                CGRect cardFrameInWindow = [strongCard convertRect:strongCard.bounds
                                                            toView:strongCard.window];
                CGFloat cardBottom    = CGRectGetMaxY(cardFrameInWindow);
                CGFloat keyboardTop   = CGRectGetMinY(keyboardFrame);
                CGFloat overlap       = cardBottom - keyboardTop;
                CGFloat shiftUp       = (overlap > 0) ? -(overlap + 16) : 0;

                [UIView animateWithDuration:duration
                                      delay:0
                                    options:(UIViewAnimationOptions)(curve << 16)
                                 animations:^{
                    strongCard.transform = CGAffineTransformMakeTranslation(0, shiftUp);
                } completion:nil];
            }];

            keyboardHideObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIKeyboardWillHideNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                UIView *strongCard = weakCard;
                if (!strongCard) return;
                NSDictionary *userInfo = note.userInfo;
                double duration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
                UIViewAnimationCurve curve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
                [UIView animateWithDuration:duration
                                      delay:0
                                    options:(UIViewAnimationOptions)(curve << 16)
                                 animations:^{
                    strongCard.transform = CGAffineTransformIdentity;
                } completion:nil];
            }];

            // Remove keyboard observers when the card leaves the window
            // (user tapped New Run or Play Again before submitting)
            // We use a display-link-free approach: observe the card's
            // didMoveToWindow via a one-time dealloc block pattern using
            // a trampoline associated object.
            dispatch_block_t cleanupBlock = ^{
                [[NSNotificationCenter defaultCenter] removeObserver:keyboardShowObserver];
                [[NSNotificationCenter defaultCenter] removeObserver:keyboardHideObserver];
            };
            // Store cleanup on the card so it fires when card is deallocated
            static const void *kBRKeyboardCleanupKey = &kBRKeyboardCleanupKey;
            objc_setAssociatedObject(card, kBRKeyboardCleanupKey,
                cleanupBlock, OBJC_ASSOCIATION_COPY_NONATOMIC);

            // ── Wire submit ───────────────────────────────────────────────────
            [submitButton addTarget:self action:@selector(submitScoreFromEndCard:)
                   forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(submitButton, kBREndCardNameFieldKey,
                nameField, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(submitButton, kBREndCardFinalScoreKey,
                @(finalScore), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            // Auto-focus — pop the keyboard immediately so the user
            // doesn't have to tap the field to start typing
            [nameField becomeFirstResponder];
        });
    }] resume];
}

// ── UITextFieldDelegate — Return key dismisses keyboard ───────────────────────
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

/// Called when the submit button on the end card is tapped.
/// Reads the name field and final score from associated objects on the sender.
/// Handles submit tap. Dismisses keyboard first (which also slides the card
/// back down via the keyboard-hide observer) then posts the score.
- (void)submitScoreFromEndCard:(UIButton *)submitButton {
    UITextField *nameField  = objc_getAssociatedObject(submitButton, kBREndCardNameFieldKey);
    NSNumber    *scoreValue = objc_getAssociatedObject(submitButton, kBREndCardFinalScoreKey);

    // Dismiss keyboard — the UIKeyboardWillHide observer will animate the
    // card back to its original position automatically.
    [nameField resignFirstResponder];

    NSString  *playerName = nameField.text.length > 0 ? nameField.text : @"Anonymous";
    NSInteger  finalScore = scoreValue.integerValue;

    [self submitScore:finalScore playerName:playerName];
    submitButton.hidden = YES;
    nameField.enabled   = NO;
    nameField.text      = [NSString stringWithFormat:@"✓ %@", playerName];
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

    // Two movement sound variants for natural variety — alternate sound keeps
    // rapid tapping from sounding like a stuck record.
    [self playRandomVariantOfSound:@"player-movement" variantCount:2];

    [self updateCameraForPlayerCol:self.model.playerCol playerRow:self.model.playerRow];
    [self repositionPlayerImageAnimated:YES];
    BRTile *landedTile = [self.model tileAtCol:self.model.playerCol row:self.model.playerRow];

    if (landedTile.itemName) {
        NSString *pickedItem = landedTile.itemName;
        landedTile.itemName  = nil;
        self.score += 10;
        static const NSInteger kBRMaxPickupHP = 3;
        if ([pickedItem isEqualToString:@"❤️ heart"]) {
            // Heart pickup restores HP up to max instead of going to inventory
            if (self.model.playerHP < kBRMaxPickupHP) {
                self.model.playerHP += 1;
            } else {
                self.score += 15; // already at full health — bonus points instead
            }
        } else {
            [self.inventory addObject:pickedItem];
        }
        // Two found-item variants — same rationale as movement
        [self playRandomVariantOfSound:@"found-item" variantCount:2];
    } else if (landedTile.enemyName) {
        // Bare-hands bump: costs 1 HP but always drops a reward so the
        // player is never left with nothing. Priority: restore a heart if
        // below max, otherwise drop a random item from the level's item list.
        landedTile.enemyName = nil;
        self.model.playerHP -= 1;
        self.score += 15;
        static const NSInteger kBRMaxHeartDisplay = 3;
        if (self.model.playerHP < kBRMaxHeartDisplay) {
            // Restore 1 HP — heart drop
            self.model.playerHP += 1;
            landedTile.itemName = @"❤️ heart";
        } else {
            // Inventory drop — pick from level items, fall back to "scrap"
            NSArray<NSString *> *dropPool = self.model.aiItems;
            NSString *droppedItem = (dropPool.count > 0)
                ? dropPool[arc4random_uniform((uint32_t)dropPool.count)]
                : @"scrap";
            landedTile.itemName = droppedItem;
        }
        // Two hurt-player variants — keeps repeated hits from sounding monotonous
        [self playRandomVariantOfSound:@"hurt-player" variantCount:2];
    }
    [self updateHUD];
}

- (void)useAction {
    if (!self.model) return;

    // ── No inventory: bare-hands wall push ───────────────────────────────
    // Gives the player something to do when cornered with no items.
    // 25% chance to crumble an adjacent wall revealing a hidden reward.
    // No penalty on failure so this is always safe to attempt.
    if (self.inventory.count == 0) {
        NSArray<NSValue *> *neighbors = [self.model neighborsOfCol:self.model.playerCol
                                                               row:self.model.playerRow];
        BRTile  *wallTarget    = nil;
        CGPoint  wallTargetPos = CGPointZero;
        for (NSValue *posValue in neighbors) {
            CGPoint pt   = posValue.CGPointValue;
            BRTile *tile = [self.model tileAtCol:pt.x row:pt.y];
            if (tile.type == BRTileTypeWall) {
                wallTarget    = tile;
                wallTargetPos = pt;
                break;
            }
        }
        if (wallTarget && arc4random_uniform(100) < 25) {
            // Snapshot the wall tile BEFORE clearing it so the explosion
            // fragments show the wall graphic, not the open floor behind it.
            UIImage *wallSnapshot = [self snapshotOfGameViewTileAtCol:(NSInteger)wallTargetPos.x
                                                                  row:(NSInteger)wallTargetPos.y];
            wallTarget.type = BRTileTypeFloor;
            // Reward: heart if injured, item otherwise
            static const NSInteger kBRMaxHPWallPush = 3;
            if (self.model.playerHP < kBRMaxHPWallPush) {
                wallTarget.itemName = @"❤️ heart";
            } else {
                NSArray<NSString *> *dropPool = self.model.aiItems;
                wallTarget.itemName = (dropPool.count > 0)
                    ? dropPool[arc4random_uniform((uint32_t)dropPool.count)]
                    : @"scrap";
            }
            self.score += 10;
            [self playSoundNamed:@"wall-blast-success"];
            [self playExplosionAtTileCol:(NSInteger)wallTargetPos.x
                                     row:(NSInteger)wallTargetPos.y
                             sourceImage:wallSnapshot];
            [self updateHUD];
            [self.gameView setNeedsDisplay];
        }
        return;
    }

    NSString *chosenItem = self.inventory.firstObject;
    NSArray<NSValue *> *neighborPositions = [self.model neighborsOfCol:self.model.playerCol
                                                                   row:self.model.playerRow];

    // ── Adjacent enemy — use item as weapon ──────────────────────────────────
    // Always drops a reward on the cleared tile: heart if injured, else item.
    for (NSValue *posValue in neighborPositions) {
        CGPoint adjacentPoint = posValue.CGPointValue;
        BRTile *adjacentTile  = [self.model tileAtCol:adjacentPoint.x row:adjacentPoint.y];
        if (!adjacentTile.enemyName) continue;
        adjacentTile.enemyName = nil;
        [self.inventory removeObjectAtIndex:0];
        self.score += 40;
        static const NSInteger kBRMaxHPForDrop = 3;
        if (self.model.playerHP < kBRMaxHPForDrop) {
            adjacentTile.itemName = @"❤️ heart";
        } else {
            NSArray<NSString *> *dropPool = self.model.aiItems;
            adjacentTile.itemName = (dropPool.count > 0)
                ? dropPool[arc4random_uniform((uint32_t)dropPool.count)]
                : @"scrap";
        }
        [self playSoundNamed:@"enemy-died"];
        // Remove the enemy sprite immediately so it doesn't linger while
        // the explosion fragments are flying (tick would remove it on its
        // next 0.25s fire, which is too late — it would ghost under pieces).
        NSString *enemyKey = [NSString stringWithFormat:@"%ld,%ld",
                              (long)(NSInteger)adjacentPoint.x,
                              (long)(NSInteger)adjacentPoint.y];
        UIImageView *defeatedEnemyView = self.enemyImageViews[enemyKey];
        [defeatedEnemyView removeFromSuperview];
        [self.enemyImageViews removeObjectForKey:enemyKey];
        // Use the enemy sprite image for fragments so pieces look like the
        // defeated enemy rather than a generic burst.
        [self playExplosionAtTileCol:(NSInteger)adjacentPoint.x
                                 row:(NSInteger)adjacentPoint.y
                         sourceImage:self.enemyImage];
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
        // Snapshot BEFORE clearing the tile — fragments must show the wall graphic.
        UIImage *wallSnapshot = [self snapshotOfGameViewTileAtCol:(NSInteger)wallTilePosition.x
                                                              row:(NSInteger)wallTilePosition.y];
        BRTile *breachedTile = [self.model tileAtCol:wallTilePosition.x row:wallTilePosition.y];
        breachedTile.type    = BRTileTypeFloor;
        breachedTile.itemName = @"scrap";
        [self.inventory removeObjectAtIndex:0];
        self.score += 25;
        [self playSoundNamed:@"wall-blast-success"];
        [self playExplosionAtTileCol:(NSInteger)wallTilePosition.x
                                 row:(NSInteger)wallTilePosition.y
                         sourceImage:wallSnapshot];
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
        [self playSoundNamed:@"wall-blast-fail"];
        [self playRandomVariantOfSound:@"hurt-player" variantCount:2];
    }
    [self updateHUD];
    [self.gameView setNeedsDisplay];
}

#pragma mark - Membership

/// Returns YES if the current user has any active EZComplete subscription.
/// Used to gate save-game and library features. Membership is required to:
///   - access the game picker / saved library
///   - auto-save newly generated games
///   - play the free default game
/// Non-members can still generate new games (coins deducted) and play them,
/// but games are not persisted and the picker is not shown.
- (BOOL)userHasMembership {
    // EZAuthManager.shared.subscriptionTier returns nil/empty for non-subscribers.
    // Any non-empty tier string means the user has an active plan.
    NSString *tier = [EZEntitlementManager shared].currentTier;
    return (tier.length > 0);
}

#pragma mark - Game Picker

/// Presents the library picker modally. The completion callback either loads
/// a saved record (no API calls) or kicks off startNewRun.
- (void)showGamePicker {
    BRGamePickerViewController *picker = [[BRGamePickerViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    picker.onSelection = ^(BRGameRecord *selectedRecord) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (selectedRecord) {
            [strongSelf loadGameRecord:selectedRecord];
        } else {
            [strongSelf startNewRun];
        }
    };
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - Load Saved Game

/// Restores a previously saved game record with zero API calls.
/// Mirrors playAgainRun but sources everything from a BRGameRecord instead
/// of savedRunAssets/savedRunSeed, and skips the loading overlay entirely.
- (void)loadGameRecord:(BRGameRecord *)record {
    // Immediately hide the loading overlay — a saved game does zero API calls
    // and needs no loading screen. startNewRun may have left it visible if
    // it was called first (e.g. from viewDidLoad before the picker appeared).
    self.loadingOverlayView.hidden = YES;
    self.loadingOverlayView.alpha  = 0;
    [self.loadingSpinner stopAnimating];

    _endCardFired = NO;
    self.score    = 0;
    [self.inventory removeAllObjects];
    [self setGameInputEnabled:NO];

    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView       = nil;
    self.currentGameRecord      = record;
    self.savedRunSeed           = record.seed;

    // Reset visuals
    self.playerImageView.hidden = YES;
    self.playerImageView.image  = nil;
    self.enemyImage             = nil;
    [self clearEnemyImageViews];
    self.gameView.backgroundImage   = nil;
    self.gameView.hidePlayerDot     = NO;
    self.gameView.backgroundColor   = [UIColor colorWithWhite:0.1 alpha:1.0];

    // Rebuild model from saved seed
    self.model = [[BRGameModel alloc] initWithCols:17 rows:13 seed:record.seed];
    self.gameView.model = self.model;

    // Build asset dict from record (images loaded lazily from disk)
    NSDictionary *assetDict = [record asAssetDict];
    UIImage *bgImage   = assetDict[@"bgImage"];
    UIImage *playerImg = assetDict[@"playerImage"];
    UIImage *enemyImg  = assetDict[@"enemyImage"];

    if (bgImage) {
        self.gameView.backgroundImage = bgImage;
        self.gameView.backgroundColor = [UIColor clearColor];
    }

    self.model.levelFlavor    = record.premise;
    self.model.aiItems        = record.items;
    self.model.aiEnemies      = record.enemies;
    self.model.vulnerableHint = record.hint;
    [self.model placeItems:record.items
                     count:MIN(6, (NSInteger)record.items.count  * 2)];
    [self.model placeEnemies:record.enemies
                       count:MIN(6, (NSInteger)record.enemies.count * 2)];

    [self updateCameraForPlayerCol:self.model.playerCol playerRow:self.model.playerRow];

    if (playerImg) {
        self.playerImageView.image  = playerImg;
        self.gameView.hidePlayerDot = YES;
        self.playerImageView.hidden = NO;
        [self repositionPlayerImageAnimated:NO];
    }
    self.enemyImage = enemyImg;

    // Save assets so Play Again works from a loaded game too
    self.savedRunAssets = assetDict;

    [self clearEnemyImageViews];
    [self refreshEnemyImageViews];
    [self updateHUD];
    [self.gameView setNeedsDisplay];
    [self setGameInputEnabled:YES];

    // Saved game has no loading screen, so start music here as the player
    // gains control. Stops and replaces any track already playing.
    [self startBackgroundMusic];

    if (!self.tickTimer || !self.tickTimer.isValid) {
        self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                          target:self
                                                        selector:@selector(tick)
                                                        userInfo:nil
                                                         repeats:YES];
    }
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
    self.gameView.backgroundImage = nil;
    self.gameView.hidePlayerDot   = NO;
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

    // Start music immediately so the player hears it during the story loading screen.
    // Music carries through into gameplay — startBackgroundMusic handles stopping
    // any previous track before beginning the new one.
    [self startBackgroundMusic];

    [self buildGameAssetsWithCompletion:^(NSDictionary *assetDict) {
        NSString *themeTitle = assetDict[@"themeTitle"]  ?: @"BRAINROT";
        NSString *levelDesc  = assetDict[@"levelDesc"]   ?: @"Something stirs.";
        NSString *hint       = assetDict[@"hint"]        ?: @"";
        NSArray  *items      = assetDict[@"items"]       ?: @[@"widget", @"cable"];
        NSArray  *enemies    = assetDict[@"enemies"]     ?: @[@"warden", @"patrol"];
        UIImage  *bgImage    = assetDict[@"bgImage"];
        UIImage  *playerImg  = assetDict[@"playerImage"];
        UIImage  *enemyImg   = assetDict[@"enemyImage"];

        // Background image is set directly on gameView — it handles cropping
        // to the current viewport in drawRect. No separate UIImageView needed.
        // The DFS maze model is ground truth for movement; we no longer
        // reclassify tiles from image brightness (that was unreliable).
        if (bgImage) {
            self.gameView.backgroundImage = bgImage;
            self.gameView.backgroundColor = [UIColor clearColor];
        }

        // Place items/enemies on finalized tile layout
        self.model.levelFlavor    = levelDesc;
        self.model.aiItems        = items;
        self.model.aiEnemies      = enemies;
        self.model.vulnerableHint = hint;
        [self.model placeItems:items    count:MIN(6, (NSInteger)items.count   * 2)];
        [self.model placeEnemies:enemies count:MIN(6, (NSInteger)enemies.count * 2)];

        [self updateCameraForPlayerCol:self.model.playerCol playerRow:self.model.playerRow];
        if (playerImg) {
            self.playerImageView.image  = playerImg;
            self.gameView.hidePlayerDot = YES;
            self.playerImageView.hidden = NO;
            [self repositionPlayerImageAnimated:NO];
        }
        self.enemyImage = enemyImg;

        // Snapshot everything needed for Play Again (same world, zero API cost)
        self.savedRunAssets = assetDict;

        // Only persist to the library for subscribers — saving is a membership perk.
        // Non-members can play the game they just generated but it won't appear
        // in the picker on their next session.
        if (![self userHasMembership]) return; // skip save for non-members

        __weak typeof(self) weakSelfForSave = self;
        [[BRGameLibrary shared]
            saveGameWithThemeTitle:themeTitle
                           premise:levelDesc
                              hint:hint
                             items:items
                           enemies:enemies
                              seed:self.savedRunSeed
                  backgroundImage:bgImage
                       playerImage:playerImg
                        enemyImage:enemyImg
                        completion:^(BRGameRecord *savedRecord) {
            __strong typeof(weakSelfForSave) strongSelfForSave = weakSelfForSave;
            strongSelfForSave.currentGameRecord = savedRecord;
        }];

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

    self.gameView.backgroundImage = bgImage;
    self.gameView.backgroundColor = bgImage ? [UIColor clearColor]
                                            : [UIColor colorWithWhite:0.1 alpha:1.0];

    self.model.levelFlavor    = levelDesc;
    self.model.aiItems        = items;
    self.model.aiEnemies      = enemies;
    self.model.vulnerableHint = hint;
    [self.model placeItems:items    count:MIN(6, (NSInteger)items.count   * 2)];
    [self.model placeEnemies:enemies count:MIN(6, (NSInteger)enemies.count * 2)];

    [self updateCameraForPlayerCol:self.model.playerCol playerRow:self.model.playerRow];
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

    // Restart music for the new attempt — same world, fresh track selection.
    [self startBackgroundMusic];

    if (!self.tickTimer || !self.tickTimer.isValid) {
        self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                          target:self
                                                        selector:@selector(tick)
                                                        userInfo:nil
                                                         repeats:YES];
    }
}

#pragma mark - Maze Template Image

/// Renders the current model's tile topology to a PNG UIImage using plain
/// Core Graphics. White = floor/exit, near-black = wall. This image is sent
/// alongside the background image prompt so the AI skins an already-correct
/// maze rather than guessing one — the generated image will have bright/dark
/// areas that match this reference, which our brightness-sampling grid rebuild
/// can then read back reliably.
///
/// Rendered at 2× the tile grid size (34×26 at 17×13 with 2px/tile) for a
/// compact but readable reference image.
- (NSData *)renderMazeTemplateImageData {
    if (!self.model) return nil;

    NSInteger gridCols     = self.model.cols;
    NSInteger gridRows     = self.model.rows;
    // 32px per tile = 544×416px for a 17×13 grid.
    // The old 4px/tile (68×52px) was too small for the AI to read the maze topology —
    // it produced landscape paintings that ignored the path layout in complex sections.
    // 32px gives enough resolution for the edit model to see individual corridors.
    // Base64 size: ~544×416 PNG ≈ 35-60KB uncompressed, well within the API limit.
    NSInteger pixelsPerTile = 32;
    NSInteger canvasWidth   = gridCols * pixelsPerTile;
    NSInteger canvasHeight  = gridRows * pixelsPerTile;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(canvasWidth, canvasHeight), YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    for (NSInteger row = 0; row < gridRows; row++) {
        for (NSInteger col = 0; col < gridCols; col++) {
            BRTile  *tile     = [self.model tileAtCol:col row:row];
            CGRect   tileRect = CGRectMake(col * pixelsPerTile, row * pixelsPerTile,
                                           pixelsPerTile, pixelsPerTile);
            UIColor *fillColor;
            switch (tile.type) {
                case BRTileTypeFloor: fillColor = [UIColor whiteColor];                                  break;
                case BRTileTypeExit:  fillColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.4 alpha:1]; break;
                case BRTileTypeWall:  fillColor = [UIColor colorWithWhite:0.08 alpha:1.0];               break;
                default:              fillColor = [UIColor blackColor];                                   break;
            }
            CGContextSetFillColorWithColor(ctx, fillColor.CGColor);
            CGContextFillRect(ctx, tileRect);
        }
    }

    // Mark player start (blue) and exit (bright green) so the AI knows which
    // end of the path is which
    CGRect startRect = CGRectMake(self.model.playerCol * pixelsPerTile,
                                  self.model.playerRow * pixelsPerTile,
                                  pixelsPerTile, pixelsPerTile);
    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithRed:0.1 green:0.4 blue:1.0 alpha:1.0].CGColor);
    CGContextFillRect(ctx, startRect);

    UIImage *templateImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return UIImagePNGRepresentation(templateImage);
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
        "  backgroundPrompt: DALL-E image prompt for the reference maze image provided. "
        "The reference shows the EXACT maze layout: white/light = walkable floor path, "
        "black/dark = impassable wall, blue dot = player start, bright green = exit goal. "
        "You MUST match this exact corridor structure — every white path in the reference "
        "must appear as a VISUALLY BRIGHT, clearly traversable area in your image. "
        "Every dark wall area must appear as a DARKER, visually dense obstacle area. "
        "The contrast between paths (bright/open) and walls (dark/dense) is critical. "
        "Style the paths as thematic terrain (dirt trails, marble corridors, neon streets). "
        "Style walls as dense thematic obstacles (hedges, stone walls, buildings, jungle). "
        "Top-down view, game-art style. NO characters or text. "
        "CRITICAL: preserve the maze layout exactly — players navigate by visual contrast.\n"
        "  spriteSheetPrompt: DALL-E prompt for a single 1024x1024 image. "
        "TOP HALF: hero character only, centered, full body, white background, bold cartoon outlines. "
        "Thin white dividing line across center. "
        "BOTTOM HALF: villain/enemy only, centered, full body, white background, "
        "bold cartoon outlines, menacing look.";

    [self callBrainRotAI:systemPrompt
             userMessage:@"Generate a new unexpected game premise."
               maxTokens:500
           deductNewGame:YES
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

        // Render a B&W maze template from the current model topology.
        // This is passed to the background image call as a reference image so the
        // AI produces an image whose bright/dark regions match our known-good maze,
        // instead of inventing a layout that may be unnavigable.
        NSData *mazeTemplateData = [self renderMazeTemplateImageData];
        self.savedMazeTemplateImageData = mazeTemplateData;

        // Generate background + sprite sheet in parallel
        dispatch_group_t imageGroup      = dispatch_group_create();
        __block UIImage *backgroundImg   = nil;
        __block UIImage *spriteSheetImg  = nil;

        dispatch_group_enter(imageGroup);
        [self generateImageWithPrompt:bgPrompt
                          transparent:NO
                    referenceImageData:mazeTemplateData
                            completion:^(UIImage *img) {
            backgroundImg = img;
            dispatch_group_leave(imageGroup);
        }];

        dispatch_group_enter(imageGroup);
        [self generateImageWithPrompt:spritePrompt
                          transparent:YES
                    referenceImageData:nil
                            completion:^(UIImage *img) {
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

// Image-based grid generation and BFS exit-reachability methods removed in
// v2.0. The DFS backtracker in BRGameModel produces a guaranteed-solvable
// perfect maze from the seed. Using image brightness to reclassify tiles
// was unreliable across different AI art styles and was causing the
// passability problems. The background image is now purely visual.


#pragma mark - Image Generation

/// Generates an image via the br-ai edge function.
/// Pass a non-nil referenceImageData (PNG) to send a reference/template image
/// alongside the prompt for image-to-image generation. Pass nil for text-only.
- (void)generateImageWithPrompt:(NSString *)prompt
                    transparent:(BOOL)transparent
              referenceImageData:(nullable NSData *)referenceImageData
                      completion:(void (^)(UIImage *_Nullable image))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kBRBrainRotAIURL]];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 90;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    // Build payload — include reference image as base64 if provided
    NSMutableDictionary *payload = [@{
        @"action":      @"generate_image",
        @"prompt":      prompt,
        @"size":        @"1024x1024",
        @"transparent": @(transparent),
    } mutableCopy];
    if (referenceImageData) {
        payload[@"reference_image_b64"] = [referenceImageData base64EncodedStringWithOptions:0];
    }
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

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

/// Recentres the camera on the given model coordinates, clamped so the viewport
/// never extends past the model edges.
- (void)updateCameraForPlayerCol:(NSInteger)playerCol playerRow:(NSInteger)playerRow {
    NSInteger halfViewCols = self.gameView.viewportCols / 2;
    NSInteger halfViewRows = self.gameView.viewportRows / 2;
    NSInteger maxCameraCol = MAX(0, self.model.cols - self.gameView.viewportCols);
    NSInteger maxCameraRow = MAX(0, self.model.rows - self.gameView.viewportRows);
    self.gameView.cameraCol = MAX(0, MIN(maxCameraCol, playerCol - halfViewCols));
    self.gameView.cameraRow = MAX(0, MIN(maxCameraRow, playerRow - halfViewRows));
}

/// Returns the on-screen CGRect for a model tile at (col, row), accounting for
/// the current camera offset. Returns CGRectZero if the tile is outside the viewport.
- (CGRect)tileFrameForCol:(NSInteger)col row:(NSInteger)row {
    if (!self.model || CGRectIsEmpty(self.gameView.frame)) return CGRectZero;
    NSInteger screenCol = col - self.gameView.cameraCol;
    NSInteger screenRow = row - self.gameView.cameraRow;
    // Return zero rect for tiles outside the visible viewport
    if (screenCol < 0 || screenCol >= self.gameView.viewportCols ||
        screenRow < 0 || screenRow >= self.gameView.viewportRows) {
        return CGRectZero;
    }
    CGFloat tileW = self.gameView.frame.size.width  / (CGFloat)self.gameView.viewportCols;
    CGFloat tileH = self.gameView.frame.size.height / (CGFloat)self.gameView.viewportRows;
    return CGRectMake(self.gameView.frame.origin.x + screenCol * tileW,
                      self.gameView.frame.origin.y + screenRow * tileH,
                      tileW, tileH);
}

/// Moves playerImageView to the current model.playerCol/playerRow position.
/// Hides the view if the player tile is outside the current viewport (camera offset).
- (void)repositionPlayerImageAnimated:(BOOL)animated {
    if (!self.model) return;
    CGRect tileFrame = [self tileFrameForCol:self.model.playerCol row:self.model.playerRow];
    if (CGRectIsEmpty(tileFrame)) {
        self.playerImageView.hidden = YES; // scrolled out of viewport
        return;
    }
    self.playerImageView.hidden = (self.playerImageView.image == nil);
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

#pragma mark - Explosion Animation

/// Renders the gameView's current visual state at a single tile position into a
/// UIImage. The snapshot is taken BEFORE any model changes so the returned image
/// shows what the tile looked like at the moment of impact (wall or enemy sprite),
/// not the floor/empty state that replaces it.
///
/// Returns nil if the tile is outside the viewport, the context couldn't be
/// created, or the gameView has no frame yet. All callers guard on nil.
- (nullable UIImage *)snapshotOfGameViewTileAtCol:(NSInteger)col row:(NSInteger)row {
    CGRect tileInViewCoords = [self tileFrameForCol:col row:row];
    if (CGRectIsEmpty(tileInViewCoords)) return nil;

    // tileFrameForCol:row: returns coords in self.view space.
    // We need the same rect in gameView's local coordinate system to crop
    // the layer render correctly, regardless of where gameView sits on screen
    // or how far the camera has scrolled.
    CGRect tileInGameViewCoords = [self.gameView convertRect:tileInViewCoords
                                                    fromView:self.view];
    CGSize tileSize = tileInGameViewCoords.size;
    if (tileSize.width <= 0 || tileSize.height <= 0) return nil;

    UIGraphicsBeginImageContextWithOptions(tileSize, NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }
    // Shift the render origin so this tile's top-left maps to (0, 0) in the image.
    CGContextTranslateCTM(ctx, -tileInGameViewCoords.origin.x,
                               -tileInGameViewCoords.origin.y);
    [self.gameView.layer renderInContext:ctx];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

/// Plays a cinematic tile-destruction burst at the given model coordinates.
///
/// Visual sequence:
///   1. Impact flash — a bright disc scales up from the tile centre and fades
///      in ~0.2 s, giving an immediate "hit" cue before pieces fly.
///   2. Six fragments (2-column × 3-row grid) — each is a cropped slice of
///      sourceImage if one is provided, or an orange fallback otherwise.
///      Fragments launch outward from the tile centre with a perpendicular
///      wobble, tumble via random rotation (±150°), shrink, and fade over
///      ~0.45 s using spring physics.
///   3. All subviews clean up in their own completion blocks — nothing leaks.
///
/// Pass the snapshot image BEFORE mutating the model so fragments look like
/// the destroyed tile, not the floor that replaces it.
- (void)playExplosionAtTileCol:(NSInteger)col
                           row:(NSInteger)row
                   sourceImage:(nullable UIImage *)sourceImage {

    CGRect tileFrame = [self tileFrameForCol:col row:row];
    if (CGRectIsEmpty(tileFrame)) return;

    CGPoint explosionCenter = CGPointMake(CGRectGetMidX(tileFrame),
                                          CGRectGetMidY(tileFrame));
    CGFloat tileSize = MIN(tileFrame.size.width, tileFrame.size.height);

    // ── 1. Impact flash ───────────────────────────────────────────────────────
    // A bright yellow-orange disc that expands from 20% to 220% of the tile
    // and fades out quickly. It fires before the fragments so the player sees
    // an immediate response even on slower devices.
    CGFloat flashDiameter = tileSize * 0.85;
    UIView *flashView = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, flashDiameter, flashDiameter)];
    flashView.center          = explosionCenter;
    flashView.backgroundColor = [UIColor colorWithRed:1.0 green:0.88 blue:0.15 alpha:0.92];
    flashView.layer.cornerRadius = flashDiameter / 2.0;
    flashView.transform       = CGAffineTransformMakeScale(0.2, 0.2);
    // Insert below the player sprite but above the game grid
    [self.view insertSubview:flashView aboveSubview:self.gameView];

    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        flashView.transform = CGAffineTransformMakeScale(2.2, 2.2);
        flashView.alpha     = 0;
    } completion:^(BOOL finished) {
        [flashView removeFromSuperview];
    }];

    // ── 2. Fragment burst ─────────────────────────────────────────────────────
    // Six pieces arranged as a 2-column × 3-row grid over the tile rect.
    // Each is a cropped slice of the source image (or an orange fallback),
    // launched outward from the explosion centre with spring physics.
    static const NSInteger kFragmentCols = 2;
    static const NSInteger kFragmentRows = 3;
    CGFloat fragmentW = tileFrame.size.width  / kFragmentCols;
    CGFloat fragmentH = tileFrame.size.height / kFragmentRows;

    for (NSInteger fragmentRow = 0; fragmentRow < kFragmentRows; fragmentRow++) {
        for (NSInteger fragmentCol = 0; fragmentCol < kFragmentCols; fragmentCol++) {

            CGRect fragmentStartFrame = CGRectMake(
                tileFrame.origin.x + fragmentCol * fragmentW,
                tileFrame.origin.y + fragmentRow * fragmentH,
                fragmentW, fragmentH);

            // ── Build fragment visual ─────────────────────────────────────────
            UIView *fragment;
            if (sourceImage) {
                // Crop the proportional slice of sourceImage that matches this
                // fragment's position within the tile.
                //
                // sourceImage is in UIKit point space (size) with a scale factor.
                // CGImageCreateWithImageInRect expects pixel coordinates, so
                // multiply by scale before cropping.
                CGFloat tileW = tileFrame.size.width;
                CGFloat tileH = tileFrame.size.height;
                CGFloat imgW  = sourceImage.size.width;
                CGFloat imgH  = sourceImage.size.height;
                CGFloat sc    = sourceImage.scale;

                CGFloat cropX = (fragmentCol * fragmentW / tileW) * imgW * sc;
                CGFloat cropY = (fragmentRow * fragmentH / tileH) * imgH * sc;
                CGFloat cropW = (fragmentW / tileW) * imgW * sc;
                CGFloat cropH = (fragmentH / tileH) * imgH * sc;

                UIImageView *imgFragment =
                    [[UIImageView alloc] initWithFrame:fragmentStartFrame];
                imgFragment.contentMode = UIViewContentModeScaleAspectFill;
                imgFragment.clipsToBounds = YES;

                CGImageRef cropRef = CGImageCreateWithImageInRect(
                    sourceImage.CGImage,
                    CGRectMake(cropX, cropY, cropW, cropH));
                if (cropRef) {
                    imgFragment.image = [UIImage imageWithCGImage:cropRef
                                                            scale:sc
                                                      orientation:UIImageOrientationUp];
                    CGImageRelease(cropRef);
                }
                fragment = imgFragment;
            } else {
                // Fallback when no source image is available (e.g. game loaded
                // before the background image finished generating).
                fragment = [[UIView alloc] initWithFrame:fragmentStartFrame];
                fragment.backgroundColor =
                    [UIColor colorWithRed:1.0 green:0.45 blue:0.1 alpha:1.0];
            }

            fragment.layer.cornerRadius = 2.5;
            fragment.clipsToBounds      = YES;
            [self.view insertSubview:fragment aboveSubview:self.gameView];

            // ── Launch vector ─────────────────────────────────────────────────
            // Direction: unit vector from tile centre toward this fragment's
            // centre, so pieces always fly away from the impact point.
            CGPoint fragmentCenter = CGPointMake(CGRectGetMidX(fragmentStartFrame),
                                                 CGRectGetMidY(fragmentStartFrame));
            CGFloat dx = fragmentCenter.x - explosionCenter.x;
            CGFloat dy = fragmentCenter.y - explosionCenter.y;
            CGFloat magnitude = hypotf(dx, dy);
            if (magnitude > 0.001f) {
                dx /= magnitude;
                dy /= magnitude;
            } else {
                // Fragment is exactly at centre (unlikely but safe): send it
                // in a random direction so it doesn't stay frozen in place.
                CGFloat angle = arc4random_uniform(360) * M_PI / 180.0;
                dx = cosf(angle);
                dy = sinf(angle);
            }

            // Travel distance varies per fragment for a natural, uneven burst.
            // Perpendicular wobble adds lateral scatter so fragments don't all
            // fly in perfectly straight lines away from centre.
            CGFloat travelDistance  = 55.0f + arc4random_uniform(75);
            NSInteger wobbleAmount  = (NSInteger)arc4random_uniform(44) - 22;
            CGFloat finalX = fragmentCenter.x + dx * travelDistance + (-dy) * wobbleAmount;
            CGFloat finalY = fragmentCenter.y + dy * travelDistance +   dx  * wobbleAmount;

            // Random tumble ±150° — gives a "hit by a powerful force" feel
            CGFloat rotationAngle = ((NSInteger)arc4random_uniform(300) - 150) * (CGFloat)M_PI / 180.0f;

            // Tiny stagger (0–80 ms) so all six fragments don't leave at
            // the exact same frame; makes the burst look less mechanical.
            NSTimeInterval launchDelay = arc4random_uniform(80) / 1000.0;

            [UIView animateWithDuration:0.45
                                  delay:launchDelay
                 usingSpringWithDamping:0.62
                  initialSpringVelocity:2.2
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{
                fragment.center    = CGPointMake(finalX, finalY);
                fragment.transform = CGAffineTransformConcat(
                    CGAffineTransformMakeRotation(rotationAngle),
                    CGAffineTransformMakeScale(0.10, 0.10));
                fragment.alpha = 0;
            } completion:^(BOOL finished) {
                [fragment removeFromSuperview];
            }];
        }
    }
}

#pragma mark - AI Text Helper

/// Called when the server returns 402 (insufficient coins).
/// Hides the loading overlay, shows an alert with the shortfall, and offers
/// to open the EZ Coin Store. Does NOT start a new run.
- (void)handleInsufficientCoinsWithBalance:(NSInteger)balance needed:(NSInteger)needed {
    // Hide loading overlay if it's showing
    [UIView animateWithDuration:0.3 animations:^{
        self.loadingOverlayView.alpha = 0;
    } completion:^(BOOL finished) {
        self.loadingOverlayView.hidden = YES;
    }];
    [self setGameInputEnabled:YES];

    NSString *message = (needed > 0)
        ? [NSString stringWithFormat:
            @"You have %ld coin%@ but a new game costs %ld coins.\n\n"
             "Replay a saved game for free, or get more coins.",
            (long)balance, balance == 1 ? @"" : @"s",
            (long)(balance + needed)]
        : @"Not enough coins for a new game. Replay a saved game for free, or get more coins.";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Need More Coins"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];

    // "Get Coins" — open EZ Coin Store via deep link if available
    [alert addAction:[UIAlertAction
        actionWithTitle:@"Get Coins"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
            NSURL *storeURL = [NSURL URLWithString:@"ezcomplete://coin-store"];
            if ([[UIApplication sharedApplication] canOpenURL:storeURL]) {
                [[UIApplication sharedApplication] openURL:storeURL
                                                   options:@{}
                                         completionHandler:nil];
            }
    }]];

    // Only offer the saved game picker to members who have a library to browse
    if ([self userHasMembership]) {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"Pick Saved Game"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
                [self showGamePicker];
        }]];
    }

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Cancel"
                  style:UIAlertActionStyleCancel
                handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

/// Calls the br-ai chat endpoint.
/// When deductForNewGame is YES, passes deduct_for_new_game: true and the
/// user's JWT so the edge function deducts coins before making any OpenAI
/// calls. A 402 response means insufficient coins — completion is called
/// with nil and handleInsufficientCoins is called on the main thread.
- (void)callBrainRotAI:(NSString *)systemPrompt
           userMessage:(NSString *)userMessage
             maxTokens:(NSInteger)maxTokens
       deductNewGame:(BOOL)deductForNewGame
            completion:(void (^)(NSString *_Nullable result))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kBRBrainRotAIURL]];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    // Attach JWT so the edge function can identify the user for coin deduction.
    // EZAuthManager.shared.accessToken returns nil when not signed in.
    NSString *jwt = [EZAuthManager shared].accessToken;
    if (jwt.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", jwt]
   forHTTPHeaderField:@"Authorization"];
    }

    NSMutableDictionary *payload = [@{
        @"system_prompt": systemPrompt,
        @"user_message":  userMessage,
        @"max_tokens":    @(maxTokens),
    } mutableCopy];
    if (deductForNewGame && jwt.length > 0) {
        payload[@"deduct_for_new_game"] = @YES;
    }
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) { completion(nil); return; }
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (httpResp.statusCode == 402) {
                // Insufficient coins — parse balance info and show prompt
                NSDictionary *json    = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSInteger     balance = [json[@"balance"] integerValue];
                NSInteger     needed  = [json[@"needed"]  integerValue];
                [self handleInsufficientCoinsWithBalance:balance needed:needed];
                completion(nil);
                return;
            }
            NSDictionary *json   = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString     *result = json[@"result"];
            completion(result.length > 0 ? result : nil);
        });
    }] resume];
}

#pragma mark - Audio

/// Configures AVAudioSession for ambient playback.
/// AVAudioSessionCategoryAmbient respects the device silent/mute switch, which
/// is the expected behaviour for game audio — players who want silence get it.
/// It also mixes with any audio already playing (podcast, music app) rather than
/// interrupting it. Called once in viewDidLoad before any audio objects are created.
- (void)setupAudioSession {
    NSError *categoryError = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient
                                           error:&categoryError];
    if (categoryError) {
        NSLog(@"[BrainRot] AVAudioSession category error: %@",
              categoryError.localizedDescription);
    }
    NSError *activateError = nil;
    [[AVAudioSession sharedInstance] setActive:YES error:&activateError];
    if (activateError) {
        NSLog(@"[BrainRot] AVAudioSession activate error: %@",
              activateError.localizedDescription);
    }
}

/// Preloads every SFX file into its own AVAudioPlayer so playback is
/// instantaneous at runtime — no disk reads during gameplay.
/// Files are expected in Resources/sounds/ with a .aiff extension.
/// Missing files are logged and skipped; a missing SFX will never crash the game.
- (void)preloadSoundEffects {
    self.sfxPlayers = [NSMutableDictionary dictionary];

    NSArray<NSString *> *sfxFileNames = @[
        @"player-movement",    // step taken — primary variant
        @"player-movement2",   // step taken — alternate variant
        @"found-item",         // item picked up — primary variant
        @"found-item2",        // item picked up — alternate variant
        @"hurt-player",        // player takes damage — primary variant
        @"hurt-player2",       // player takes damage — alternate variant
        @"wall-blast-fail",    // wall breach attempt failed; warden spawns
        @"wall-blast-success", // wall breached successfully
        @"enemy-died",         // enemy defeated via Use action
    ];

    for (NSString *fileName in sfxFileNames) {
        // Try the sounds subdirectory first (folder reference in Xcode);
        // fall back to the bundle root (group-based import) if not found there.
        NSURL *fileURL = [[NSBundle mainBundle] URLForResource:fileName
                                                withExtension:@"aiff"
                                                 subdirectory:@"sounds"];
        if (!fileURL) {
            fileURL = [[NSBundle mainBundle] URLForResource:fileName
                                             withExtension:@"aiff"];
        }
        if (!fileURL) {
            NSLog(@"[BrainRot] SFX not found: %@.aiff", fileName);
            continue;
        }

        NSError *loadError = nil;
        AVAudioPlayer *sfxPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL
                                                                          error:&loadError];
        if (loadError || !sfxPlayer) {
            NSLog(@"[BrainRot] SFX load error for %@: %@",
                  fileName, loadError.localizedDescription);
            continue;
        }
        sfxPlayer.volume = 0.70; // SFX sit clearly above music (music is at 0.35)
        [sfxPlayer prepareToPlay];
        self.sfxPlayers[fileName] = sfxPlayer;
    }
}

/// Plays a preloaded sound effect by its filename (no extension).
/// If the effect is already mid-playback — e.g. the player taps movement
/// rapidly — it resets to the beginning and replays rather than stacking
/// duplicate audio on top of itself.
/// Safe to call with an unrecognised name; a cache miss is a silent no-op.
- (void)playSoundNamed:(NSString *)soundName {
    AVAudioPlayer *sfxPlayer = self.sfxPlayers[soundName];
    if (!sfxPlayer) return;
    if (sfxPlayer.isPlaying) {
        [sfxPlayer stop];
        sfxPlayer.currentTime = 0;
    }
    [sfxPlayer play];
}

/// Randomly picks one variant from a named sound family and plays it.
/// Variant 1 is the base name itself (e.g. "player-movement").
/// Variant 2+ are suffixed with the variant number ("player-movement2", etc.).
/// This keeps repeated actions — movement, getting hit — from sounding robotic.
///
/// Example: playRandomVariantOfSound:@"player-movement" variantCount:2
///   → plays either "player-movement" or "player-movement2" at random.
- (void)playRandomVariantOfSound:(NSString *)baseName variantCount:(NSUInteger)variantCount {
    if (variantCount <= 1) {
        [self playSoundNamed:baseName];
        return;
    }
    NSUInteger pickedVariant = arc4random_uniform((uint32_t)variantCount);
    // Variant index 0 maps to the base name; 1+ append the number (2, 3, …)
    NSString *variantName = (pickedVariant == 0)
        ? baseName
        : [NSString stringWithFormat:@"%@%lu", baseName, (unsigned long)(pickedVariant + 1)];
    [self playSoundNamed:variantName];
}

/// Starts background music, stopping any currently playing track first.
/// Theme selection is weighted so theme1 (the full-length main loop) plays most
/// of the time, while theme2 and theme3 add occasional variety:
///   0–69  → brainrot-theme1  (70%)
///  70–84  → brainrot-theme2  (15%)
///  85–99  → brainrot-theme3  (15%)
/// All three loop indefinitely. If the randomly chosen file is missing,
/// theme1 is tried as a fallback before giving up silently.
- (void)startBackgroundMusic {
    // Stop and release any currently playing track before starting a new one.
    [self.musicPlayer stop];
    self.musicPlayer = nil;

    NSUInteger themeRoll = arc4random_uniform(100);
    NSString *themeName;
    if      (themeRoll < 70) { themeName = @"brainrot-theme1"; }
    else if (themeRoll < 85) { themeName = @"brainrot-theme2"; }
    else                     { themeName = @"brainrot-theme3"; }

    // Try sounds subdirectory first, then bundle root
    NSURL *musicURL = [[NSBundle mainBundle] URLForResource:themeName
                                              withExtension:@"mp3"
                                               subdirectory:@"sounds"];
    if (!musicURL) {
        musicURL = [[NSBundle mainBundle] URLForResource:themeName withExtension:@"mp3"];
    }

    // Fall back to theme1 if the selected track is missing
    if (!musicURL && ![themeName isEqualToString:@"brainrot-theme1"]) {
        musicURL = [[NSBundle mainBundle] URLForResource:@"brainrot-theme1"
                                          withExtension:@"mp3"
                                           subdirectory:@"sounds"];
        if (!musicURL) {
            musicURL = [[NSBundle mainBundle] URLForResource:@"brainrot-theme1"
                                              withExtension:@"mp3"];
        }
    }

    if (!musicURL) {
        NSLog(@"[BrainRot] Background music not found — checked Resources/sounds/ and bundle root");
        return;
    }

    NSError *musicError = nil;
    self.musicPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:musicURL
                                                              error:&musicError];
    if (musicError || !self.musicPlayer) {
        NSLog(@"[BrainRot] Music load error (%@): %@",
              themeName, musicError.localizedDescription);
        return;
    }
    self.musicPlayer.numberOfLoops = -1;  // loop forever until explicitly stopped
    self.musicPlayer.volume        = 0.35; // lower than SFX so effects cut through cleanly
    [self.musicPlayer prepareToPlay];
    [self.musicPlayer play];
}

/// Fades out and stops background music.
/// Uses a recursive dispatch_after approach to decrement volume in small steps —
/// AVAudioPlayer has no built-in fade, and CADisplayLink would be overkill here.
/// Safe to call when no music is playing; the nil check on musicPlayer is the guard.
- (void)stopBackgroundMusic {
    AVAudioPlayer *playerToFade = self.musicPlayer;
    self.musicPlayer = nil; // nil out immediately so no other caller restarts it
    if (!playerToFade || !playerToFade.isPlaying) return;
    [self fadeOutAndStopPlayer:playerToFade];
}

/// Recursively lowers a player's volume by a small step on each call until it
/// reaches near-zero, then stops it. The 0.05 s interval over ~9 steps gives a
/// ~0.45 s fade — perceptible but not slow enough to feel like a hang.
/// The player reference is kept alive by the dispatch block until stop is called.
- (void)fadeOutAndStopPlayer:(AVAudioPlayer *)player {
    if (!player || player.volume <= 0.04) {
        [player stop];
        return;
    }
    player.volume -= 0.04;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self fadeOutAndStopPlayer:player];
    });
}

#pragma mark - Marquee Banner

/// Fetches high scores and updates the marquee banner.
/// Silently no-ops on network error — the existing banner text (cached from the
/// last successful fetch, or the offline placeholder) is kept rather than
/// resetting to a zero-width label which breaks scrollBannerTick.
/// Schedules a retry after 30 s so the banner self-heals when connectivity returns.
- (void)fetchHighScoresForBanner {
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:kBRHighScoreURL]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {

        // On any failure (offline, timeout, server error) keep existing banner
        // text and schedule a retry so the banner recovers automatically.
        if (networkError || !data) {
            NSLog(@"[BrainRot] Banner fetch failed (%@), retrying in 30s",
                  networkError.localizedDescription ?: @"no data");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf fetchHighScoresForBanner];
            });
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            NSLog(@"[BrainRot] Banner fetch HTTP %ld, retrying in 30s",
                  (long)httpResponse.statusCode);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf fetchHighScoresForBanner];
            });
            return;
        }

        NSArray *scores = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSArray class]]) scores = parsed;

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
        // Duplicate the text so the scroll loop can wrap seamlessly
        NSString *fullScrollText = [NSString stringWithFormat:@"%@     %@",
                                    marqueeText, marqueeText];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            // Guard against zero-width label breaking scrollBannerTick
            if (fullScrollText.length == 0) return;
            BOOL wasScrolling = (strongSelf.bannerDisplayLink != nil);
            strongSelf.bannerLabel.text = fullScrollText;
            [strongSelf.bannerLabel sizeToFit];
            // Only reset scroll position if we weren't already scrolling valid text.
            // If the banner was scrolling an offline placeholder, preserve position
            // so the update is seamless rather than jumping back to the right edge.
            if (!wasScrolling || CGRectGetWidth(strongSelf.bannerLabel.frame) == 0) {
                strongSelf.bannerScrollOffset = CGRectGetWidth(strongSelf.view.bounds);
            }
            [strongSelf startScrollingBanner];
        });
    }] resume];
}

- (void)startScrollingBanner {
    [self stopScrollingBanner];
    // Guard: don't start the display link if the label has no width yet —
    // singleCopyWidth would be 0 and scrollBannerTick would oscillate forever.
    if (CGRectGetWidth(self.bannerLabel.frame) == 0) return;
    self.bannerDisplayLink = [CADisplayLink displayLinkWithTarget:self
                                                         selector:@selector(scrollBannerTick)];
    [self.bannerDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopScrollingBanner {
    [self.bannerDisplayLink invalidate];
    self.bannerDisplayLink = nil;
}

- (void)scrollBannerTick {
    CGFloat labelW          = CGRectGetWidth(self.bannerLabel.frame);
    CGFloat singleCopyWidth = labelW / 2.0;
    // Safety: if label has no width (e.g. text not yet set) stop the display
    // link rather than oscillating. fetchHighScoresForBanner will restart it.
    if (singleCopyWidth <= 0) {
        [self stopScrollingBanner];
        return;
    }
    CGFloat pointsPerFrame   = 50.0 / 60.0;
    self.bannerScrollOffset -= pointsPerFrame;
    if (self.bannerScrollOffset < -singleCopyWidth) {
        self.bannerScrollOffset += singleCopyWidth;
    }
    CGFloat containerH = CGRectGetHeight(self.bannerContainerView.frame);
    CGFloat labelH     = CGRectGetHeight(self.bannerLabel.frame);
    self.bannerLabel.frame = CGRectMake(self.bannerScrollOffset,
                                        (containerH - labelH) / 2.0,
                                        labelW, labelH);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Re-fetch when coming back into view — covers the case where the user
    // played offline, then backgrounded the app, then came back with WiFi.
    [self fetchHighScoresForBanner];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopScrollingBanner];
    [self stopBackgroundMusic];
}

#pragma mark - High Score Submission

/// Submits a score. If the request fails (offline), queues one retry after
/// 10 s rather than silently losing the score.
- (void)submitScore:(NSInteger)finalScore playerName:(NSString *)playerName {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kBRHighScoreURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"player_name": playerName,
        @"score":       @(finalScore),
    } options:0 error:nil];

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        if (networkError) {
            NSLog(@"[BrainRot] Score submit failed (%@), retrying in 10s",
                  networkError.localizedDescription);
            // Single retry — avoids hammering the server if truly offline
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf submitScore:finalScore playerName:playerName];
            });
            return;
        }
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode == 200 || httpResponse.statusCode == 201) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf fetchHighScoresForBanner];
            });
        } else {
            NSLog(@"[BrainRot] Score submit HTTP %ld", (long)httpResponse.statusCode);
        }
    }] resume];
}

@end
