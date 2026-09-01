// EZCoinStoreViewController.m
// EZCompleteUI
//
// Gamified EZ Coin store with subscription tiers, one-time top-ups, and daily free coins.
// Uses SFSafariViewController for PayPal checkout flow.
// Coin image: EZCoin.png (bundled asset).
//
// Subscription architecture:
//   The app never holds PayPal plan IDs. Each subscription tier is identified
//   by a name ("basic", "standard", "pro", "ultra") and the edge function
//   (create-paypal-subscription) resolves the real plan_id from server-side
//   env vars. This keeps plan IDs out of the binary, which is especially
//   important given the jailbreak audience — plan IDs in the binary can be
//   read and potentially misused via method hooks.
//
// Recent changes:
//   - Removed hardcoded PayPal plan ID constants (kPlanBasic, kPlanStandard,
//     kPlanPro, kPlanUltra). Subscription items now store tier names instead.
//     The edge function resolves the real plan_id from environment variables.
//     Previously, sandbox plan IDs were baked into the binary causing "failed
//     to open store" errors when the backend switched to live mode.
//   - createPayPalSubscriptionForPlanID:token: renamed to
//     createPayPalSubscriptionForTier:token: and updated to send { tier, user_id }
//     instead of { plan_id, user_id } to match the updated edge function contract.
//   - startSubscriptionForPlanID:token: renamed to startSubscriptionForTier:token:
//   - pendingPlanID property renamed to pendingTierName to reflect the new
//     tier-name-based architecture (property remains reserved for future retry logic)
//   - Daily free coins: 5/day for free users, 10/day for active subscribers (any tier)
//   - Floating "Daily Coins" button added top-left, mirroring the Ledger button on the right
//   - Ledger button and its methods wrapped in #if DEBUG — absent in Release/production builds
//   - Daily coin eligibility is always verified server-side (claim-daily-coins edge function)
//   - Successful claim triggers the same coin celebration overlay used for purchases
//   - Button shows a live ticking countdown (e.g. "Next: 4h 22m", "Next: 3m 45s", "Next: 12s")
//     driven by an NSTimer that fires every second; timer starts when the server confirms
//     coins were already claimed and stops automatically when the countdown reaches zero,
//     when coins become available, or when the view disappears
//   - Short local variable names (pad, w, h, req, url, card, etc.) renamed for readability
//   - Replaced NSISO8601DateFormatter with NSDateFormatter (crash fix: SIGABRT on iOS 15 / jailbreak)
//   - All JSON value reads now use NSNull-safe helpers (crash fix: JSON null → [NSNull null] → ___forwarding___)

#import "EZCoinStoreViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZCoinPotView.h"
#import "helpers.h"
#import "EZCoinLedgerViewController.h"


#import "EZCoinUsageViewController.h"

// ── Safe JSON value helpers ───────────────────────────────────────────────────
// NSJSONSerialization maps JSON `null` to [NSNull null], a real Objective-C object
// that crashes on any message it doesn't implement (boolValue, integerValue, length, etc.)
// because those calls go through ___forwarding___ and abort.
// Confirmed crash on iPhone OS 15.8.7 / jailbroken: frames 5–6 in EZCompleteUI binary
// followed immediately by _CF_forwarding_prep_0 → ___forwarding___ → objc_exception_throw.
// Always use these helpers instead of messaging json[key] directly.

static BOOL jsonBool(NSDictionary *json, NSString *key) {
    id value = json[key];
    return (value && value != (id)[NSNull null]) ? [value boolValue] : NO;
}

static NSInteger jsonInteger(NSDictionary *json, NSString *key) {
    id value = json[key];
    return (value && value != (id)[NSNull null]) ? [value integerValue] : 0;
}

// Returns the string value for key, or nil if the value is absent, null, or not a string.
static NSString *jsonString(NSDictionary *json, NSString *key) {
    id value = json[key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// ── ISO 8601 date parsing ─────────────────────────────────────────────────────
// NSISO8601DateFormatter triggers a SIGABRT inside ___forwarding___ on iOS 15
// jailbroken devices (confirmed crash: com.i0stweak3r.ezcompleteui / iPhone OS 15.8.7).
// NSDateFormatter with explicit format strings is available since iOS 2 and is stable.
// Accepts `id` so callers never need to cast — NSNull and nil both return nil safely.
// Formatters are created once per process via dispatch_once.

static NSDate *dateFromISO8601String(id isoStringOrNull) {
    // Reject nil, [NSNull null], and any non-string type that JSON might produce
    if (![isoStringOrNull isKindOfClass:[NSString class]]) return nil;
    NSString *isoString = (NSString *)isoStringOrNull;
    if (isoString.length == 0) return nil;

    // Two formats to cover what Supabase / the edge function may return:
    //   Format A (JavaScript toISOString): "2026-06-09T20:28:18.000Z"
    //   Format B (PostgreSQL timestamptz): "2026-06-09T20:28:18+00:00"
    static NSDateFormatter *formatterWithMilliseconds    = nil;
    static NSDateFormatter *formatterWithoutMilliseconds = nil;
    static dispatch_once_t  onceToken;
    dispatch_once(&onceToken, ^{
        NSLocale *posixLocale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

        formatterWithMilliseconds            = [[NSDateFormatter alloc] init];
        formatterWithMilliseconds.locale     = posixLocale;
        formatterWithMilliseconds.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";

        formatterWithoutMilliseconds            = [[NSDateFormatter alloc] init];
        formatterWithoutMilliseconds.locale     = posixLocale;
        formatterWithoutMilliseconds.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    });

    NSDate *parsedDate = [formatterWithMilliseconds dateFromString:isoString];
    return parsedDate ?: [formatterWithoutMilliseconds dateFromString:isoString];
}

// ── Supabase / PayPal constants ───────────────────────────────────────────────

static NSString *const kStoreSupabaseURL   = @"https://spuoimtqofhbdzosrbng.supabase.co";

// Daily coins endpoint — see supabase/functions/claim-daily-coins/index.ts
static NSString *const kDailyCoinsEndpoint = @"/functions/v1/claim-daily-coins";

// Subscription tier names sent to the create-paypal-subscription edge function.
// The edge function resolves the real PayPal plan_id from server-side env vars
// (PAYPAL_PLAN_BASIC, PAYPAL_PLAN_STANDARD, etc.) so plan IDs never live in
// the binary. To add a tier: add a constant here, add it to buildItems, and
// set the matching PAYPAL_PLAN_* env var in Supabase.
static NSString *const kTierBasic    = @"basic";
static NSString *const kTierStandard = @"standard";
static NSString *const kTierPro      = @"pro";
static NSString *const kTierUltra    = @"ultra";

// ── Store item model ──────────────────────────────────────────────────────────

typedef NS_ENUM(NSUInteger, EZStoreItemType) {
    EZStoreItemTypeSubscription,
    EZStoreItemTypeTopUp,
};

@interface EZStoreItem : NSObject
@property (nonatomic, copy)   NSString        *title;
@property (nonatomic, copy)   NSString        *subtitle;       // e.g. "400 coins / month"
@property (nonatomic, copy)   NSString        *priceString;    // e.g. "$5.00 / mo"
@property (nonatomic, copy)   NSString        *planOrPackageID;
@property (nonatomic, assign) EZStoreItemType  type;
@property (nonatomic, assign) NSInteger        coins;
@property (nonatomic, assign) BOOL             isCurrentPlan;
@property (nonatomic, strong) UIColor         *accentColor;
@property (nonatomic, copy)   NSString        *badgeText;      // e.g. "BEST VALUE" — nil for none
@end

@implementation EZStoreItem
@end

// ── Cell ──────────────────────────────────────────────────────────────────────

@interface EZStoreCell : UITableViewCell
@property (nonatomic, strong) UIView      *cardView;
@property (nonatomic, strong) UIImageView *coinImageView;
@property (nonatomic, strong) UILabel     *titleLabel;
@property (nonatomic, strong) UILabel     *subtitleLabel;
@property (nonatomic, strong) UILabel     *priceLabel;
@property (nonatomic, strong) UILabel     *badgeLabel;
@property (nonatomic, strong) UIButton    *actionButton;
@property (nonatomic, copy)   void (^onAction)(void);
- (void)configureWithItem:(EZStoreItem *)item coinImage:(UIImage * _Nullable)coinImage;
@end

@implementation EZStoreCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;

        self.cardView = [[UIView alloc] init];
        self.cardView.layer.cornerRadius  = 16;
        self.cardView.layer.borderWidth   = 1;
        self.cardView.layer.borderColor   = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
        self.cardView.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.cardView.layer.shadowOpacity = 0.25;
        self.cardView.layer.shadowOffset  = CGSizeMake(0, 4);
        self.cardView.layer.shadowRadius  = 10;
        [self.contentView addSubview:self.cardView];

        self.coinImageView = [[UIImageView alloc] init];
        self.coinImageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.cardView addSubview:self.coinImageView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font      = [UIFont boldSystemFontOfSize:17];
        self.titleLabel.textColor = [UIColor labelColor];
        [self.cardView addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.font          = [UIFont systemFontOfSize:13];
        self.subtitleLabel.textColor     = [UIColor secondaryLabelColor];
        self.subtitleLabel.numberOfLines = 2;
        [self.cardView addSubview:self.subtitleLabel];

        self.priceLabel = [[UILabel alloc] init];
        self.priceLabel.font          = [UIFont boldSystemFontOfSize:15];
        self.priceLabel.textAlignment = NSTextAlignmentRight;
        [self.cardView addSubview:self.priceLabel];

        self.badgeLabel = [[UILabel alloc] init];
        self.badgeLabel.font                        = [UIFont boldSystemFontOfSize:10];
        self.badgeLabel.textColor                   = [UIColor whiteColor];
        self.badgeLabel.textAlignment               = NSTextAlignmentCenter;
        self.badgeLabel.layer.cornerRadius          = 8;
        self.badgeLabel.layer.masksToBounds         = YES;
        self.badgeLabel.hidden                      = YES;
        [self.cardView addSubview:self.badgeLabel];

        self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.actionButton.layer.cornerRadius  = 10;
        self.actionButton.titleLabel.font     = [UIFont boldSystemFontOfSize:14];
        [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.actionButton addTarget:self
                              action:@selector(actionTapped)
                    forControlEvents:UIControlEventTouchUpInside];
        [self.cardView addSubview:self.actionButton];
    }
    return self;
}

- (void)configureWithItem:(EZStoreItem *)item coinImage:(UIImage *)coinImage {
    UIColor *accentColor = item.accentColor ?: [UIColor systemBlueColor];
    self.cardView.backgroundColor   = [accentColor colorWithAlphaComponent:0.12];
    self.cardView.layer.borderColor = [accentColor colorWithAlphaComponent:0.3].CGColor;

    self.coinImageView.image  = coinImage;
    self.titleLabel.text      = item.title;
    self.subtitleLabel.text   = item.subtitle;
    self.priceLabel.text      = item.priceString;
    self.priceLabel.textColor = accentColor;

    if (item.badgeText) {
        self.badgeLabel.hidden          = NO;
        self.badgeLabel.text            = [NSString stringWithFormat:@" %@ ", item.badgeText];
        self.badgeLabel.backgroundColor = accentColor;
    } else {
        self.badgeLabel.hidden = YES;
    }

    if (item.isCurrentPlan) {
        [self.actionButton setTitle:@"Cancel Plan" forState:UIControlStateNormal];
        self.actionButton.backgroundColor = [UIColor systemRedColor];
        self.actionButton.enabled         = YES;
    } else if (item.type == EZStoreItemTypeSubscription) {
        [self.actionButton setTitle:@"Subscribe" forState:UIControlStateNormal];
        self.actionButton.backgroundColor = accentColor;
        self.actionButton.enabled         = YES;
    } else {
        [self.actionButton setTitle:@"Buy Now" forState:UIControlStateNormal];
        self.actionButton.backgroundColor = accentColor;
        self.actionButton.enabled         = YES;
    }
}

- (void)actionTapped {
    if (self.onAction) self.onAction();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat cellPadding  = 12;
    CGFloat cardWidth    = self.contentView.bounds.size.width - 32;
    CGFloat cardHeight   = self.contentView.bounds.size.height - 16;
    self.cardView.frame  = CGRectMake(16, 8, cardWidth, cardHeight);

    CGFloat coinSize = 52;
    self.coinImageView.frame = CGRectMake(cellPadding, (cardHeight - coinSize) / 2, coinSize, coinSize);

    CGFloat textX = coinSize + cellPadding * 2;
    CGFloat textW = cardWidth - textX - 90 - cellPadding;
    self.titleLabel.frame    = CGRectMake(textX, cellPadding, textW, 22);
    self.subtitleLabel.frame = CGRectMake(textX, cellPadding + 24, textW, 34);

    self.priceLabel.frame = CGRectMake(cardWidth - 90 - cellPadding, cellPadding, 90, 22);
    self.badgeLabel.frame = CGRectMake(cardWidth - 90 - cellPadding, cellPadding + 26, 90, 18);

    CGFloat buttonWidth  = cardWidth - textX - cellPadding;
    CGFloat buttonHeight = 34;
    self.actionButton.frame = CGRectMake(textX, cardHeight - buttonHeight - cellPadding, buttonWidth, buttonHeight);
}

@end

// ── Main VC ───────────────────────────────────────────────────────────────────

@interface EZCoinStoreViewController () <UITableViewDelegate, UITableViewDataSource, SFSafariViewControllerDelegate>
@property (nonatomic, strong) UITableView             *tableView;
@property (nonatomic, strong) UIView                  *headerView;
@property (nonatomic, strong) UILabel                 *balanceLabel;
@property (nonatomic, strong) UILabel                 *warningLabel;
@property (nonatomic, strong) NSArray<EZStoreItem *>  *items;
@property (nonatomic, strong) UIImage                 *coinImage;
@property (nonatomic, strong) NSString                *pendingPurchaseType;  // @"subscription" or @"topup"
@property (nonatomic, strong) NSString                *pendingTierName;      // Reserved for subscription retry logic (currently unused)
@property (nonatomic, strong) NSString                *pendingOrderID;
@property (nonatomic, strong) EZCoinPotView           *storePotView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

// Daily coins UI and state
@property (nonatomic, strong) UIButton  *dailyCoinsButton;       // Floating button top-left
@property (nonatomic, assign) BOOL       isDailyCoinsAvailable;  // Whether the server says coins can be claimed now
@property (nonatomic, strong) NSDate    *nextDailyClaimDate;     // ISO date from server; drives the countdown label
@property (nonatomic, assign) NSInteger  dailyCoinsPendingAmount; // 5 or 10 depending on membership; from server
//@property (nonatomic, strong) NSTimer   *countdownTimer;         // Fires every second to tick the "Next: Xh Ym Xs" label
@end

@implementation EZCoinStoreViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"🪙 EZ Coin Store";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];

    // "History" — user-facing coin usage log (right nav bar button)
    UIBarButtonItem *historyBarButton = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"clock.arrow.circlepath"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(historyTapped)];
    historyBarButton.tintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
    self.navigationItem.rightBarButtonItem = historyBarButton;

    self.coinImage = [UIImage imageNamed:@"EZCoin"];

    [self buildItems];
    [self setupUI];
    [self refreshBalance];
    [self addDailyCoinsButton];
    [self refreshDailyCoinsStatus];

    [self addLedgerButton];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Lightweight countdown refresh using already-cached timing data.
    // No network call here — refreshDailyCoinsStatus handles that on load
    // and again after each refreshBalance.
    if (self.nextDailyClaimDate) {
        [self updateDailyCoinsButtonState];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopCountdownTimer];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// ── Build store items ─────────────────────────────────────────────────────────

- (void)buildItems {
    NSString *currentTier   = [EZEntitlementManager shared].currentTier;
    NSString *currentStatus = [EZEntitlementManager shared].currentStatus;

    // A plan only counts as "current" if the subscription is actually active.
    // Cancelled/suspended/expired accounts should see the Subscribe button again.
    BOOL isActive = [currentStatus isEqualToString:@"active"];

    NSMutableArray *items = [NSMutableArray array];

    // ── Subscription tiers ────────────────────────────────────────────────────

    EZStoreItem *basic    = [EZStoreItem new];
    basic.title           = @"Basic";
    basic.subtitle        = @"400 coins / month\nIdeal for casual use";
    basic.priceString     = @"$5 / mo";
    basic.planOrPackageID = kTierBasic;
    basic.type            = EZStoreItemTypeSubscription;
    basic.coins           = 400;
    basic.accentColor     = [UIColor systemBlueColor];
    basic.isCurrentPlan   = isActive && [currentTier isEqualToString:@"basic"];
    if ([currentTier isEqualToString:@"basic"] && !isActive && currentStatus)
        basic.badgeText   = currentStatus.uppercaseString;
    [items addObject:basic];

    EZStoreItem *standard    = [EZStoreItem new];
    standard.title           = @"Standard";
    standard.subtitle        = @"900 coins / month\nGreat for daily users";
    standard.priceString     = @"$10 / mo";
    standard.planOrPackageID = kTierStandard;
    standard.type            = EZStoreItemTypeSubscription;
    standard.coins           = 900;
    standard.accentColor     = [UIColor systemPurpleColor];
    standard.isCurrentPlan   = isActive && [currentTier isEqualToString:@"standard"];
    if ([currentTier isEqualToString:@"standard"] && !isActive && currentStatus)
        standard.badgeText   = currentStatus.uppercaseString;
    else if (![currentTier isEqualToString:@"standard"] || !isActive)
        standard.badgeText   = @"POPULAR";
    [items addObject:standard];

    EZStoreItem *pro    = [EZStoreItem new];
    pro.title           = @"Pro";
    pro.subtitle        = @"1,600 coins / month\nFor power users & GPT-5";
    pro.priceString     = @"$15 / mo";
    pro.planOrPackageID = kTierPro;
    pro.type            = EZStoreItemTypeSubscription;
    pro.coins           = 1600;
    pro.accentColor     = [UIColor systemOrangeColor];
    pro.isCurrentPlan   = isActive && [currentTier isEqualToString:@"pro"];
    if ([currentTier isEqualToString:@"pro"] && !isActive && currentStatus)
        pro.badgeText    = currentStatus.uppercaseString;
    else if (![currentTier isEqualToString:@"pro"] || !isActive)
        pro.badgeText    = @"BEST VALUE";
    [items addObject:pro];

    EZStoreItem *ultra    = [EZStoreItem new];
    ultra.title           = @"Ultra";
    ultra.subtitle        = @"2,500 coins / month\nUnlimited power";
    ultra.priceString     = @"$20 / mo";
    ultra.planOrPackageID = kTierUltra;
    ultra.type            = EZStoreItemTypeSubscription;
    ultra.coins           = 2500;
    ultra.accentColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]; // gold
    ultra.isCurrentPlan   = isActive && [currentTier isEqualToString:@"ultra"];
    if ([currentTier isEqualToString:@"ultra"] && !isActive && currentStatus)
        ultra.badgeText   = currentStatus.uppercaseString;
    else
        ultra.badgeText   = @"ULTRA";
    [items addObject:ultra];

    // ── One-time top-ups ──────────────────────────────────────────────────────

    EZStoreItem *topup1    = [EZStoreItem new];
    topup1.title           = @"Coin Starter Pack";
    topup1.subtitle        = @"400 coins, one-time\nNever expires";
    topup1.priceString     = @"$5.00";
    topup1.planOrPackageID = @"TOPUP_400";
    topup1.type            = EZStoreItemTypeTopUp;
    topup1.coins           = 400;
    topup1.accentColor     = [UIColor systemTealColor];
    [items addObject:topup1];

    EZStoreItem *topup2    = [EZStoreItem new];
    topup2.title           = @"Coin Value Pack";
    topup2.subtitle        = @"900 coins, one-time\nNever expires";
    topup2.priceString     = @"$10.00";
    topup2.planOrPackageID = @"TOPUP_900";
    topup2.type            = EZStoreItemTypeTopUp;
    topup2.coins           = 900;
    topup2.accentColor     = [UIColor systemGreenColor];
    topup2.badgeText       = @"SAVE 10%";
    [items addObject:topup2];

    self.items = [items copy];
}

// ── UI Setup ──────────────────────────────────────────────────────────────────

- (void)setupUI {
    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 120)];
    self.headerView.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];

    UILabel *storeTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 20, self.view.bounds.size.width, 36)];
    storeTitleLabel.text          = @"⚡ EZ Coin Store";
    storeTitleLabel.font          = [UIFont boldSystemFontOfSize:24];
    storeTitleLabel.textColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
    storeTitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.headerView addSubview:storeTitleLabel];

    self.balanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 62, self.view.bounds.size.width, 22)];
    self.balanceLabel.font          = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.balanceLabel.textColor     = [UIColor secondaryLabelColor];
    self.balanceLabel.textAlignment = NSTextAlignmentCenter;
    self.balanceLabel.text          = @"Loading balance...";
    [self.headerView addSubview:self.balanceLabel];

    // Low-coin warning banner — shown when the store is opened because
    // the user ran out mid-session (triggeringFeatureName is set by the caller)
    self.warningLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 88, self.view.bounds.size.width, 28)];
    self.warningLabel.backgroundColor = [UIColor systemRedColor];
    self.warningLabel.font            = [UIFont boldSystemFontOfSize:13];
    self.warningLabel.textColor       = [UIColor whiteColor];
    self.warningLabel.textAlignment   = NSTextAlignmentCenter;
    self.warningLabel.hidden          = !self.showLowCoinsWarning;

    if (self.showLowCoinsWarning) {
        NSString *featureName = self.triggeringFeatureName ?: @"this feature";
        self.warningLabel.text = [NSString stringWithFormat:
            @"⚠️  Not enough coins for %@. Top up below.", featureName];
        CGRect expandedHeaderFrame    = self.headerView.frame;
        expandedHeaderFrame.size.height = 124;
        self.headerView.frame           = expandedHeaderFrame;
    }
    [self.headerView addSubview:self.warningLabel];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate         = self;
    self.tableView.dataSource       = self;
    self.tableView.backgroundColor  = [UIColor systemBackgroundColor];
    self.tableView.separatorStyle   = UITableViewCellSeparatorStyleNone;
    self.tableView.tableHeaderView  = self.headerView;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.tableView registerClass:[EZStoreCell class] forCellReuseIdentifier:@"EZStoreCell"];
    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center           = self.view.center;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
}

- (void)refreshBalance {
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        NSString *tier   = [EZEntitlementManager shared].currentTier;
        NSString *status = [EZEntitlementManager shared].currentStatus;

        NSString *planDisplay;
        if (tier.length && status.length && ![status isEqualToString:@"active"]) {
            planDisplay = [NSString stringWithFormat:@"%@ (%@)",
                           tier.capitalizedString, status.capitalizedString];
        } else if (tier.length) {
            planDisplay = tier.capitalizedString;
        } else {
            planDisplay = @"No plan";
        }

        self.balanceLabel.text = [NSString stringWithFormat:
            @"🪙 %ld coins   •   %@", (long)balance, planDisplay];
        [self buildItems];
        [self.tableView reloadData];

        // Re-check daily coin availability after every balance refresh.
        // Handles the edge case where the user's membership tier changed since
        // the last check (e.g. they just subscribed or their plan was cancelled).
        [self refreshDailyCoinsStatus];
    }];
}

// ── UITableView ───────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4; // subscription tiers
    return 2;                   // top-up packages
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"  SUBSCRIPTIONS" : @"  ONE-TIME TOP-UPS";
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *sectionHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 36)];
    sectionHeaderView.backgroundColor = [UIColor clearColor];

    UILabel *sectionTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 8, 300, 20)];
    sectionTitleLabel.text                    = section == 0 ? @"SUBSCRIPTIONS" : @"ONE-TIME TOP-UPS";
    sectionTitleLabel.font                    = [UIFont boldSystemFontOfSize:11];
    sectionTitleLabel.textColor               = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.8];
    sectionTitleLabel.adjustsFontSizeToFitWidth = YES;
    [sectionHeaderView addSubview:sectionTitleLabel];

    UIView *goldDividerLine = [[UIView alloc] initWithFrame:CGRectMake(20, 30, tableView.bounds.size.width - 40, 0.5)];
    goldDividerLine.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.3];
    [sectionHeaderView addSubview:goldDividerLine];

    return sectionHeaderView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 36;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 120;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZStoreCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZStoreCell"
                                                        forIndexPath:indexPath];
    NSInteger itemIndex = indexPath.section == 0 ? indexPath.row : 4 + indexPath.row;
    if (itemIndex < (NSInteger)self.items.count) {
        EZStoreItem *item = self.items[itemIndex];
        [cell configureWithItem:item coinImage:self.coinImage];

        __weak typeof(self) weakSelf = self;
        cell.onAction = ^{
            [weakSelf handlePurchaseForItem:item];
        };
    }
    return cell;
}

// ── Daily Coins button ────────────────────────────────────────────────────────
// Floats top-left over the table content, mirroring the DEBUG Ledger button on the right.
// Coin amounts and eligibility are always enforced server-side. The button state here
// is purely informational — a jailbreak user can enable a disabled button, but the
// edge function will still reject the claim if the 24-hour window hasn't elapsed.

- (void)addDailyCoinsButton {
    self.dailyCoinsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.dailyCoinsButton setTitle:@"🎁 Daily Coins" forState:UIControlStateNormal];
    self.dailyCoinsButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.dailyCoinsButton.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
    self.dailyCoinsButton.titleLabel.font   = [UIFont systemFontOfSize:16.0];
    // Muted until the server confirms eligibility
    self.dailyCoinsButton.tintColor = [UIColor secondaryLabelColor];
    self.dailyCoinsButton.enabled   = NO;
    [self.dailyCoinsButton addTarget:self
                              action:@selector(dailyCoinsTapped:)
                    forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.dailyCoinsButton];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.dailyCoinsButton.topAnchor     constraintEqualToAnchor:safeArea.topAnchor     constant:8.0],
        [self.dailyCoinsButton.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12.0],
    ]];
}

// Refreshes the button label and enabled state from the current cached values.
// Does NOT make a network call — call refreshDailyCoinsStatus for that.
- (void)updateDailyCoinsButtonState {
    if (self.isDailyCoinsAvailable) {
        [self stopCountdownTimer];
        NSString *buttonTitle = self.dailyCoinsPendingAmount > 0
            ? [NSString stringWithFormat:@"🎁 +%ld Free!", (long)self.dailyCoinsPendingAmount]
            : @"🎁 Free Coins!";
        [self.dailyCoinsButton setTitle:buttonTitle forState:UIControlStateNormal];
        self.dailyCoinsButton.tintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
        self.dailyCoinsButton.enabled   = YES;

    } else if (self.nextDailyClaimDate) {
        NSTimeInterval secondsRemaining = [self.nextDailyClaimDate timeIntervalSinceNow];
        if (secondsRemaining > 0) {
            [self updateCountdownLabel:secondsRemaining];
            self.dailyCoinsButton.tintColor = [UIColor tertiaryLabelColor];
            self.dailyCoinsButton.enabled   = NO;
            [self startCountdownTimer];
        } else {
            // Countdown hit zero — optimistically enable; server still verifies on tap
            [self stopCountdownTimer];
            [self.dailyCoinsButton setTitle:@"🎁 Free Coins!" forState:UIControlStateNormal];
            self.dailyCoinsButton.tintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
            self.dailyCoinsButton.enabled   = YES;
            self.isDailyCoinsAvailable      = YES;
        }
    } else {
        // No cached data yet — stays muted until first server response arrives
        [self stopCountdownTimer];
        [self.dailyCoinsButton setTitle:@"🎁 Daily Coins" forState:UIControlStateNormal];
        self.dailyCoinsButton.tintColor = [UIColor secondaryLabelColor];
        self.dailyCoinsButton.enabled   = NO;
    }
}

// Sets the button title to a human-readable countdown for the given number of seconds.
// Called both from updateDailyCoinsButtonState (initial render) and the repeating timer.
- (void)updateCountdownLabel:(NSTimeInterval)secondsRemaining {
    NSInteger totalSeconds = (NSInteger)secondsRemaining;
    NSInteger hours        = totalSeconds / 3600;
    NSInteger minutes      = (totalSeconds % 3600) / 60;
    NSInteger seconds      = totalSeconds % 60;

    NSString *countdownText;
    if (hours > 0) {
        countdownText = [NSString stringWithFormat:@"🎁 Next: %ldh %ldm", (long)hours, (long)minutes];
    } else if (minutes > 0) {
        countdownText = [NSString stringWithFormat:@"🎁 Next: %ldm %lds", (long)minutes, (long)seconds];
    } else {
        countdownText = [NSString stringWithFormat:@"🎁 Next: %lds", (long)seconds];
    }
    [self.dailyCoinsButton setTitle:countdownText forState:UIControlStateNormal];
}

// Starts the per-second timer if it isn't already running.
- (void)startCountdownTimer {
    if (self.countdownTimer) return; // Already ticking
    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                           target:self
                                                         selector:@selector(countdownTimerFired:)
                                                         userInfo:nil
                                                          repeats:YES];
}

// Stops and releases the timer.
- (void)stopCountdownTimer {
    [self.countdownTimer invalidate];
    self.countdownTimer = nil;
}

// Fires every second while the countdown is active.
- (void)countdownTimerFired:(NSTimer *)timer {
    if (!self.nextDailyClaimDate) {
        [self stopCountdownTimer];
        return;
    }
    NSTimeInterval secondsRemaining = [self.nextDailyClaimDate timeIntervalSinceNow];
    if (secondsRemaining <= 0) {
        // Time's up — flip to available and let updateDailyCoinsButtonState handle the rest
        [self stopCountdownTimer];
        self.isDailyCoinsAvailable = YES;
        [self updateDailyCoinsButtonState];
    } else {
        [self updateCountdownLabel:secondsRemaining];
    }
}

// Asks the server whether coins can be claimed right now and how many would be awarded.
// Uses a GET request with ?check=1 so no coins are credited during a status poll.
- (void)refreshDailyCoinsStatus {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) return; // Not signed in — button stays disabled

    NSURL *statusURL = [NSURL URLWithString:[[kStoreSupabaseURL
        stringByAppendingString:kDailyCoinsEndpoint]
        stringByAppendingString:@"?check=1"]];
    NSMutableURLRequest *statusRequest = [NSMutableURLRequest requestWithURL:statusURL];
    statusRequest.HTTPMethod      = @"GET";
    statusRequest.timeoutInterval = 10;
    [statusRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]
         forHTTPHeaderField:@"Authorization"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:statusRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) return; // Silent failure; button stays in its current state

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (!json) return;

            self.isDailyCoinsAvailable   = jsonBool(json, @"available");
            self.dailyCoinsPendingAmount = jsonInteger(json, @"coins_to_award");
            self.nextDailyClaimDate      = dateFromISO8601String(jsonString(json, @"next_claim_at"));
            [self updateDailyCoinsButtonState];
        });
    }] resume];
}

// Called when the user taps the Daily Coins button.
- (void)dailyCoinsTapped:(UIButton *)sender {
    // Disable immediately to block double-taps while the request is in-flight
    self.dailyCoinsButton.enabled = NO;
    [self.dailyCoinsButton setTitle:@"⏳ Claiming..." forState:UIControlStateNormal];
    [self claimDailyCoins];
}

// POSTs to the claim-daily-coins edge function, which enforces the 24-hour cooldown
// server-side, determines the award amount by checking subscription status in the DB,
// credits coins, and returns the new balance.
- (void)claimDailyCoins {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) {
        [self showAlert:@"Not Signed In" message:@"Please sign in to claim your daily coins."];
        self.isDailyCoinsAvailable = YES;
        [self updateDailyCoinsButtonState];
        return;
    }

    NSURL *claimURL = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:kDailyCoinsEndpoint]];
    NSMutableURLRequest *claimRequest = [NSMutableURLRequest requestWithURL:claimURL];
    claimRequest.HTTPMethod      = @"POST";
    claimRequest.timeoutInterval = 15;
    [claimRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [claimRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]
        forHTTPHeaderField:@"Authorization"];
    claimRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{} options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:claimRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{

            if (error) {
                // Network error — let them retry
                [self showAlert:@"Network Error"
                        message:@"Couldn't reach the server. Please try again."];
                self.isDailyCoinsAvailable = YES;
                [self updateDailyCoinsButtonState];
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:nil];
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

            if (httpResponse.statusCode == 200 && [json[@"success"] boolValue]) {
                NSInteger coinsAdded = jsonInteger(json, @"coins_added");
                NSInteger newBalance = jsonInteger(json, @"balance");

                // Record next-claim time from server so the countdown is accurate
                self.nextDailyClaimDate    = dateFromISO8601String(jsonString(json, @"next_claim_at"));
                self.isDailyCoinsAvailable = NO;

                // Reflect new balance immediately before the delayed full refresh
                [[EZEntitlementManager shared] applyKnownBalance:newBalance];
                [self updateDailyCoinsButtonState];
                [self showCoinCelebration:coinsAdded newBalance:newBalance];

                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"EZSubscriptionUpdated" object:nil];

                // Delayed sync to pick up any secondary server-side processing
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self refreshBalance];
                });

            } else if (httpResponse.statusCode == 429
                       || [json[@"error"] isEqualToString:@"too_soon"]) {
                // Server rejected the claim — update countdown from authoritative server time
                self.nextDailyClaimDate    = dateFromISO8601String(jsonString(json, @"next_claim_at"));
                self.isDailyCoinsAvailable = NO;
                [self updateDailyCoinsButtonState];
                [self showAlert:@"Already Claimed"
                        message:@"You've already claimed your daily coins. Check back tomorrow!"];

            } else {
                // Unexpected server error — allow retry
                NSString *serverError = jsonString(json, @"error") ?: @"Something went wrong. Please try again.";
                [self showAlert:@"Error" message:serverError];
                self.isDailyCoinsAvailable = YES;
                [self updateDailyCoinsButtonState];
            }
        });
    }] resume];
}

// ── Coin Ledger ───────────────────────────────────────────────────────────────
// Raw transaction inspector showing cost info and balance history.
// TODO: wrap in #if DEBUG before release build.

#if DEBUG

- (void)addLedgerButton {
    UIButton *ledgerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [ledgerButton setTitle:@"Ledger" forState:UIControlStateNormal];
    ledgerButton.translatesAutoresizingMaskIntoConstraints = NO;
    ledgerButton.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
    ledgerButton.titleLabel.font   = [UIFont systemFontOfSize:16.0];
    [ledgerButton addTarget:self
                     action:@selector(ledgerButtonTapped:)
           forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:ledgerButton];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [ledgerButton.topAnchor      constraintEqualToAnchor:safeArea.topAnchor      constant:8.0],
        [ledgerButton.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],
    ]];
}

- (void)ledgerButtonTapped:(UIButton *)sender {
    EZCoinLedgerViewController *ledgerVC = [[EZCoinLedgerViewController alloc] init];
    if (self.navigationController) {
        [self.navigationController pushViewController:ledgerVC animated:YES];
    } else {
        UINavigationController *ledgerNav = [[UINavigationController alloc]
            initWithRootViewController:ledgerVC];
        ledgerNav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:ledgerNav animated:YES completion:nil];
    }
}
#endif
/// User-facing coin usage history — triggered via the clock icon in the nav bar
- (void)historyTapped {
    EZCoinUsageViewController *usageVC = [[EZCoinUsageViewController alloc] init];
    UINavigationController *usageNav = [[UINavigationController alloc]
        initWithRootViewController:usageVC];
    usageNav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15, *)) {
        UISheetPresentationController *sheet = usageNav.sheetPresentationController;
        sheet.detents               = @[UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:usageNav animated:YES completion:nil];
}

// ── Purchase flow ─────────────────────────────────────────────────────────────

- (void)handlePurchaseForItem:(EZStoreItem *)item {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) {
        [self showAlert:@"Not logged in" message:@"Please sign in first."];
        return;
    }

    // If the user taps their current active plan, offer to cancel it
    if (item.isCurrentPlan && item.type == EZStoreItemTypeSubscription) {
        UIAlertController *cancelAlert = [UIAlertController
            alertControllerWithTitle:@"Cancel Subscription?"
                             message:@"Your remaining coins will stay in your account. This cannot be undone."
                      preferredStyle:UIAlertControllerStyleAlert];
        [cancelAlert addAction:[UIAlertAction actionWithTitle:@"Keep Plan"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
        [cancelAlert addAction:[UIAlertAction actionWithTitle:@"Cancel Plan"
                                                        style:UIAlertActionStyleDestructive
                                                      handler:^(UIAlertAction *action) {
            [self.spinner startAnimating];
            self.tableView.userInteractionEnabled = NO;
            [self cancelCurrentSubscriptionWithToken:token completion:^(BOOL success) {
                [self.spinner stopAnimating];
                self.tableView.userInteractionEnabled = YES;
                if (success) {
                    [self showAlert:@"Cancelled"
                            message:@"Your subscription has been cancelled. Your coins remain available."];
                    [self refreshBalance];
                } else {
                    [self showAlert:@"Error"
                            message:@"Could not cancel subscription. Please try again."];
                }
            }];
        }]];
        [self presentViewController:cancelAlert animated:YES completion:nil];
        return;
    }

    [self.spinner startAnimating];
    self.tableView.userInteractionEnabled = NO;

    if (item.type == EZStoreItemTypeSubscription) {
        [self startSubscriptionForTier:item.planOrPackageID token:token];
    } else {
        [self startTopUpForPackageID:item.planOrPackageID coins:item.coins token:token];
    }
}

// ── Subscription checkout ─────────────────────────────────────────────────────

- (void)startSubscriptionForTier:(NSString *)tierName token:(NSString *)token {
    NSString *currentTier   = [EZEntitlementManager shared].currentTier;
    NSString *currentStatus = [EZEntitlementManager shared].currentStatus;

    // Only cancel an existing subscription if it's genuinely active.
    // Cancelled/suspended/expired accounts go straight to checkout.
    BOOL hasActiveSub = currentTier.length > 0 && [currentStatus isEqualToString:@"active"];

    if (hasActiveSub) {
        [self cancelCurrentSubscriptionWithToken:token completion:^(BOOL success) {
            // Proceed to new plan regardless — PayPal handles the new charge
            [self createPayPalSubscriptionForTier:tierName token:token];
        }];
    } else {
        [self createPayPalSubscriptionForTier:tierName token:token];
    }
}

- (void)cancelCurrentSubscriptionWithToken:(NSString *)token
                                completion:(void(^)(BOOL success))completion {
    NSURL *cancelURL = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:@"/functions/v1/cancel-paypal-subscription"]];
    NSMutableURLRequest *cancelRequest = [NSMutableURLRequest requestWithURL:cancelURL];
    cancelRequest.HTTPMethod      = @"POST";
    cancelRequest.timeoutInterval = 15;
    [cancelRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [cancelRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]
         forHTTPHeaderField:@"Authorization"];
    cancelRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{} options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:cancelRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(!error);
        });
    }] resume];
}

- (void)createPayPalSubscriptionForTier:(NSString *)tierName token:(NSString *)token {
    // Sends the tier name, not a plan ID. The edge function resolves the real
    // PayPal plan_id from server-side env vars so it never lives in the binary.
    NSURL *createSubURL = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:@"/functions/v1/create-paypal-subscription"]];
    NSMutableURLRequest *createSubRequest = [NSMutableURLRequest requestWithURL:createSubURL];
    createSubRequest.HTTPMethod      = @"POST";
    createSubRequest.timeoutInterval = 15;
    [createSubRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [createSubRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]
            forHTTPHeaderField:@"Authorization"];
    createSubRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"tier":    tierName,
        @"user_id": [EZAuthManager shared].userId ?: @""
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:createSubRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.tableView.userInteractionEnabled = YES;

            if (error) { [self showAlert:@"Error" message:error.localizedDescription]; return; }
            NSDictionary *json       = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString     *approveURL = json[@"approve_url"];
            if (!approveURL) {
                [self showAlert:@"Error" message:@"Could not start checkout. Try again."];
                return;
            }
            self.pendingPurchaseType = @"subscription";
            SFSafariViewController *safari = [[SFSafariViewController alloc]
                initWithURL:[NSURL URLWithString:approveURL]];
            safari.delegate                = self;
            safari.preferredBarTintColor     = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];
            safari.preferredControlTintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
            [self presentViewController:safari animated:YES completion:nil];
        });
    }] resume];
}

// ── One-time top-up checkout ──────────────────────────────────────────────────

- (void)startTopUpForPackageID:(NSString *)packageID coins:(NSInteger)coins token:(NSString *)token {
    NSDictionary *packagePrices = @{
        @"TOPUP_400": @"5.00",
        @"TOPUP_900": @"10.00",
    };
    NSString *amount = packagePrices[packageID] ?: @"5.00";

    NSURL *orderURL = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:@"/functions/v1/create-paypal-order"]];
    NSMutableURLRequest *orderRequest = [NSMutableURLRequest requestWithURL:orderURL];
    orderRequest.HTTPMethod      = @"POST";
    orderRequest.timeoutInterval = 15;
    [orderRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [orderRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]
        forHTTPHeaderField:@"Authorization"];
    orderRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"user_id":    [EZAuthManager shared].userId ?: @"",
        @"package_id": packageID,
        @"amount":     amount,
        @"coins":      @(coins),
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:orderRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.tableView.userInteractionEnabled = YES;

            if (error) { [self showAlert:@"Error" message:error.localizedDescription]; return; }
            NSDictionary *json       = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString     *approveURL = json[@"approve_url"];
            if (!approveURL) {
                [self showAlert:@"Error" message:@"Could not start checkout. Try again."];
                return;
            }
            self.pendingPurchaseType = @"topup";
            self.pendingOrderID      = json[@"order_id"];
            SFSafariViewController *safari = [[SFSafariViewController alloc]
                initWithURL:[NSURL URLWithString:approveURL]];
            safari.delegate                = self;
            safari.preferredBarTintColor     = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];
            safari.preferredControlTintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
            [self presentViewController:safari animated:YES completion:nil];
        });
    }] resume];
}

// ── SFSafariViewControllerDelegate ───────────────────────────────────────────

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    if ([self.pendingPurchaseType isEqualToString:@"topup"] && self.pendingOrderID.length > 0) {
        // Capture the order directly — more reliable than a webhook for one-time payments
        [self captureOrderWithID:self.pendingOrderID];
        self.pendingOrderID = nil;
    } else {
        // Subscription — wait for webhook then refresh
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self refreshBalance];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"EZSubscriptionUpdated" object:nil];
        });
    }
    self.pendingPurchaseType = nil;
}

- (void)captureOrderWithID:(NSString *)orderID {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token || !orderID) return;

    [self.spinner startAnimating];
    self.tableView.userInteractionEnabled = NO;

    NSURL *captureURL = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:@"/functions/v1/capture-paypal-order"]];
    NSMutableURLRequest *captureRequest = [NSMutableURLRequest requestWithURL:captureURL];
    captureRequest.HTTPMethod      = @"POST";
    captureRequest.timeoutInterval = 20;
    [captureRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [captureRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]
          forHTTPHeaderField:@"Authorization"];
    captureRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"order_id": orderID
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:captureRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.tableView.userInteractionEnabled = YES;

            if (error) {
                [self showAlert:@"Error"
                        message:@"Could not confirm purchase. Check your balance — coins may still have been added."];
                [self refreshBalance];
                return;
            }

            NSDictionary      *json         = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

            if (httpResponse.statusCode == 200 && jsonBool(json, @"success")) {
                NSInteger coinsAdded = jsonInteger(json, @"coins_added");
                NSInteger newBalance = jsonInteger(json, @"balance");

                // Trust the capture response — apply balance directly so
                // a racing refreshBalance can't overwrite it with a stale value.
                [[EZEntitlementManager shared] applyKnownBalance:newBalance];

                [self showCoinCelebration:coinsAdded newBalance:newBalance];
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"EZSubscriptionUpdated" object:nil];

                // Delayed refresh to sync any server-side changes after upsert settles
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self refreshBalance];
                });
            } else {
                NSString *errorMessage = jsonString(json, @"error") ?: @"Purchase could not be confirmed.";
                [self showAlert:@"Purchase Issue" message:errorMessage];
                [self refreshBalance];
            }
        });
    }] resume];
}

// ── Coin celebration overlay ──────────────────────────────────────────────────
// Shown after any successful coin credit: purchases, top-ups, and daily rewards.

- (void)showCoinCelebration:(NSInteger)coinsAdded newBalance:(NSInteger)newBalance {
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.75];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.alpha            = 0;
    overlay.tag              = 9901;
    [self.view addSubview:overlay];

    UIView *celebrationCard = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 320)];
    celebrationCard.center             = CGPointMake(self.view.bounds.size.width / 2,
                                                     self.view.bounds.size.height / 2);
    celebrationCard.backgroundColor    = [UIColor colorWithRed:0.08 green:0.08 blue:0.14 alpha:1.0];
    celebrationCard.layer.cornerRadius = 24;
    celebrationCard.layer.borderWidth  = 1.5;
    celebrationCard.layer.borderColor  = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.6].CGColor;
    celebrationCard.transform          = CGAffineTransformMakeScale(0.7, 0.7);
    [overlay addSubview:celebrationCard];

    EZCoinPotView *coinPot = [[EZCoinPotView alloc] initWithFrame:CGRectMake(90, 20, 100, 110)];
    coinPot.coinImage = self.coinImage;
    [celebrationCard addSubview:coinPot];
    self.storePotView = coinPot;

    UILabel *headlineLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 138, 240, 30)];
    headlineLabel.text          = @"🪙 Coins Added!";
    headlineLabel.font          = [UIFont boldSystemFontOfSize:20];
    headlineLabel.textColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
    headlineLabel.textAlignment = NSTextAlignmentCenter;
    [celebrationCard addSubview:headlineLabel];

    UILabel *amountLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 172, 240, 28)];
    amountLabel.text          = [NSString stringWithFormat:@"+%ld coins", (long)coinsAdded];
    amountLabel.font          = [UIFont boldSystemFontOfSize:26];
    amountLabel.textColor     = [UIColor whiteColor];
    amountLabel.textAlignment = NSTextAlignmentCenter;
    [celebrationCard addSubview:amountLabel];

    UILabel *newBalanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 204, 240, 22)];
    newBalanceLabel.text          = [NSString stringWithFormat:@"New balance: %ld coins", (long)newBalance];
    newBalanceLabel.font          = [UIFont systemFontOfSize:14];
    newBalanceLabel.textColor     = [UIColor secondaryLabelColor];
    newBalanceLabel.textAlignment = NSTextAlignmentCenter;
    [celebrationCard addSubview:newBalanceLabel];

    UIButton *dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];
    dismissButton.frame                  = CGRectMake(40, 248, 200, 44);
    dismissButton.backgroundColor        = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
    dismissButton.layer.cornerRadius     = 12;
    dismissButton.titleLabel.font        = [UIFont boldSystemFontOfSize:16];
    dismissButton.tag                    = 9900;
    [dismissButton setTitle:@"Sweet!" forState:UIControlStateNormal];
    [dismissButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [dismissButton addTarget:self
                      action:@selector(dismissCelebration:)
            forControlEvents:UIControlEventTouchUpInside];
    [celebrationCard addSubview:dismissButton];

    [UIView animateWithDuration:0.4
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:0
                     animations:^{
        overlay.alpha             = 1;
        celebrationCard.transform = CGAffineTransformIdentity;
    } completion:^(BOOL done) {
        // Set pot to the pre-credit fill level, then animate coins flying in
        NSString     *tier        = [EZEntitlementManager shared].currentTier ?: @"basic";
        NSDictionary *tierCoinMap = @{
            @"basic":    @400,
            @"standard": @900,
            @"pro":      @1600,
            @"ultra":    @2500,
        };
        NSInteger includedCoins = [tierCoinMap[tier.lowercaseString] integerValue] ?: 400;
        [coinPot updateBalance:newBalance - coinsAdded includedCoins:includedCoins animated:NO];

        [coinPot animateCoinToss:coinsAdded completion:^{
            [coinPot updateBalance:newBalance includedCoins:includedCoins animated:YES];
        }];
    }];
}

- (void)dismissCelebration:(UIButton *)sender {
    UIView *overlay = [self.view viewWithTag:9901];
    [UIView animateWithDuration:0.25 animations:^{
        overlay.alpha = 0;
    } completion:^(BOOL done) {
        [overlay removeFromSuperview];
        self.storePotView = nil;
    }];
}

// ── Utility ───────────────────────────────────────────────────────────────────

- (void)showAlert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:title
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end
