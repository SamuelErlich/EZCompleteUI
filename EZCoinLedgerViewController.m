// EZCoinLedgerViewController.m
// EZCompleteUI
//
// Admin ledger — shows coin usage transactions across all users.
// Fetches from /functions/v1/get-admin-ledger?mode=user (service-role view).
//
// Auth: requires a valid JWT AND the ADMIN_SECRET env var value sent as
//       x-admin-secret header. The secret is never hardcoded — it is entered
//       once via an in-app prompt and stored in NSUserDefaults. On a 403 the
//       stored value is cleared and the prompt is shown again.
//
// Each row shows: user email, feature, model, prompt snippet, coins charged,
//   running balance, token counts, images, API cost, cost/100 coins, timestamp.
// Summary header: total calls, coins, cost, efficiency, margin (all users).
//
// DEBUG-only: this entire file is excluded from Release builds. The admin
// secret prompt is real protection on its own, but per-call prompts, costs,
// and margins across every user have no business being reachable from a
// shipped binary at all — so the class doesn't exist outside DEBUG, full
// stop. The call site in EZCoinStoreViewController is gated to match; if
// anything else ever tries to reference EZCoinLedgerViewController from
// non-DEBUG code, it will fail to compile rather than silently shipping.
//
// Changes from personal-ledger version:
//   - Endpoint changed from get-usage-log to get-admin-ledger (mode=user)
//   - Admin secret prompt + NSUserDefaults storage (never hardcoded in binary)
//   - Added user_email and ip_address display per row
//   - Summary header now shows all-users aggregate, not personal balance
//   - Aggregate key names updated to match get-admin-ledger response schema
//   - implied_margin_pct read from server; client-side margin calc removed
//   - currentBalance property removed (not meaningful in all-users context)
//   - Whole file wrapped in #if DEBUG — previously only intended, never done
//   - Summary header now also shows platform-wide coins in circulation
//     (global_total_circulating from get-admin-ledger) plus a drift warning
//     if the ledger total disagrees with the actual sum of live balances
//   - Added search/filter bar: "@" in query → email filter, else → feature
//     filter (e.g. "tts", "chat", "image"). Debounced 0.4s. Summary subtitle
//     and empty-state label both update to reflect the active filter.

#import "EZCoinLedgerViewController.h"
#import "EZAuthManager.h"

#if DEBUG

static NSString *const kAdminLedgerBase    = @"https://spuoimtqofhbdzosrbng.supabase.co";
static NSString *const kAdminLedgerPath    = @"/functions/v1/get-admin-ledger";
static NSString *const kAdminSecretUDKey   = @"EZAdminSecret";   // NSUserDefaults key
static NSString *const kLedgerCellID       = @"EZAdminLedgerCell";

// Cost breakeven thresholds ($ per 100 coins) — matches edge function constants
static double const kBreakevenBest  = 0.80;  // Ultra tier
static double const kBreakevenWorst = 1.25;  // Basic tier

// ── Colors ────────────────────────────────────────────────────────────────────

static UIColor *EZGold(void)  { return [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]; }
static UIColor *EZBg(void)    { return [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0]; }
static UIColor *EZCard(void)  { return [UIColor colorWithRed:0.09 green:0.09 blue:0.14 alpha:1.0]; }
static UIColor *EZMuted(void) { return [UIColor colorWithWhite:0.45 alpha:1]; }

// ── Efficiency color ──────────────────────────────────────────────────────────

static UIColor *efficiencyColor(double costPer100) {
    if (costPer100 <= kBreakevenBest)  return [UIColor systemGreenColor];
    if (costPer100 <= kBreakevenWorst) return [UIColor systemOrangeColor];
    return [UIColor systemRedColor];
}

// ── Date formatter ────────────────────────────────────────────────────────────

static NSDateFormatter *sharedDisplayFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale     = [NSLocale currentLocale];
        formatter.dateFormat = @"MMM d, h:mm a";
    });
    return formatter;
}

// ── Coin count formatter ──────────────────────────────────────────────────────
// Circulation totals run into 5+ digits quickly — grouping separators make
// them readable at a glance instead of a wall of digits.

static NSString *formattedCoinCount(NSInteger count) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSNumberFormatter new];
        formatter.numberStyle          = NSNumberFormatterDecimalStyle;
        formatter.usesGroupingSeparator = YES;
        formatter.groupingSeparator      = @",";
    });
    return [formatter stringFromNumber:@(count)] ?: [NSString stringWithFormat:@"%ld", (long)count];
}

// ── Admin ledger row cell ─────────────────────────────────────────────────────
// Shows all fields returned by get-admin-ledger mode=user, including user
// identity fields (email, IP) that are only available via the admin endpoint.

@interface EZAdminLedgerCell : UITableViewCell
- (void)configureWithRow:(NSDictionary *)row;
+ (CGFloat)rowHeight;
@end

@implementation EZAdminLedgerCell {
    UIView  *_card;
    UILabel *_featureLabel;
    UILabel *_modelLabel;
    UILabel *_userEmailLabel;   // user_email — admin-only field
    UILabel *_ipLabel;          // ip_address — admin-only field
    UILabel *_promptLabel;
    UILabel *_coinsLabel;
    UILabel *_balanceLabel;
    UILabel *_tokensLabel;
    UILabel *_imagesLabel;
    UILabel *_costLabel;
    UILabel *_effLabel;
    UILabel *_timeLabel;
    UIView  *_statusDot;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle  = UITableViewCellSelectionStyleNone;

    _card = [UIView new];
    _card.backgroundColor    = EZCard();
    _card.layer.cornerRadius = 12;
    _card.layer.borderWidth  = 0.5;
    _card.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    [self.contentView addSubview:_card];

    // Helper block — creates a label, adds it to the card, returns it
    UILabel* (^makeLabel)(CGFloat, UIFontWeight, UIColor *, NSInteger) =
    ^UILabel *(CGFloat size, UIFontWeight weight, UIColor *color, NSInteger lines) {
        UILabel *label       = [UILabel new];
        label.font           = [UIFont systemFontOfSize:size weight:weight];
        label.textColor      = color;
        label.numberOfLines  = (int)lines;
        [self->_card addSubview:label];
        return label;
    };

    _featureLabel   = makeLabel(13, UIFontWeightBold,    EZGold(),                              1);
    _modelLabel     = makeLabel(11, UIFontWeightRegular, EZMuted(),                             1);
    _userEmailLabel = makeLabel(10, UIFontWeightRegular, [UIColor colorWithWhite:0.55 alpha:1], 1);
    _ipLabel        = makeLabel(10, UIFontWeightRegular, EZMuted(),                             1);
    _promptLabel    = makeLabel(12, UIFontWeightRegular, [UIColor colorWithWhite:0.80 alpha:1], 2);
    _coinsLabel     = makeLabel(14, UIFontWeightBold,    [UIColor systemOrangeColor],           1);
    _balanceLabel   = makeLabel(11, UIFontWeightRegular, EZMuted(),                             1);
    _tokensLabel    = makeLabel(11, UIFontWeightRegular, [UIColor colorWithWhite:0.60 alpha:1], 1);
    _imagesLabel    = makeLabel(11, UIFontWeightRegular, [UIColor colorWithWhite:0.60 alpha:1], 1);
    _costLabel      = makeLabel(11, UIFontWeightRegular, EZMuted(),                             1);
    _effLabel       = makeLabel(12, UIFontWeightBold,    [UIColor systemGreenColor],            1);
    _timeLabel      = makeLabel(10, UIFontWeightRegular, EZMuted(),                             1);

    _statusDot = [UIView new];
    _statusDot.layer.cornerRadius = 4;
    [_card addSubview:_statusDot];

    return self;
}

- (void)configureWithRow:(NSDictionary *)row {
    // Safe value extractor — handles NSNull and non-string types from JSON
    NSString *(^safeString)(id) = ^NSString *(id value) {
        if (!value || value == (id)[NSNull null]) return @"";
        if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
        if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
        return @"";
    };

    // Feature + model
    NSString *featureKey = safeString(row[@"feature"]);
    _featureLabel.text   = [self friendlyFeature:featureKey.length ? featureKey : @"unknown"];
    _modelLabel.text     = safeString(row[@"model"]);

    // User identity (admin-only fields)
    NSString *email = safeString(row[@"user_email"]);
    NSString *ip    = safeString(row[@"ip_address"]);
    _userEmailLabel.text = email.length ? email : safeString(row[@"user_id"]);
    _ipLabel.text        = ip.length   ? [NSString stringWithFormat:@"IP: %@", ip] : @"";

    // Prompt
    NSString *prompt  = safeString(row[@"prompt"]);
    _promptLabel.text = prompt.length ? prompt : @"(no prompt recorded)";
    _promptLabel.textColor = prompt.length
        ? [UIColor colorWithWhite:0.78 alpha:1] : EZMuted();

    // Coins + running balance
    NSInteger coinsCharged  = [row[@"coins_charged"]  integerValue];
    NSInteger runningBalance = [row[@"running_balance"] integerValue];
    NSInteger quantity       = [row[@"quantity"]        integerValue];
    _coinsLabel.text  = quantity > 1
        ? [NSString stringWithFormat:@"−%ld coins ×%ld", (long)coinsCharged, (long)quantity]
        : [NSString stringWithFormat:@"−%ld coins", (long)coinsCharged];
    _balanceLabel.text = [NSString stringWithFormat:@"Balance after: %ld", (long)runningBalance];

    // Token counts
    id inputTokens  = row[@"input_tokens"];
    id outputTokens = row[@"output_tokens"];
    if (inputTokens && ![inputTokens isKindOfClass:[NSNull class]]) {
        _tokensLabel.text = [NSString stringWithFormat:@"In: %@ / Out: %@ tokens",
                             inputTokens, outputTokens ?: @"0"];
    } else {
        _tokensLabel.text = @"";
    }

    // Image counts
    id imagesReturned   = row[@"images_returned"];
    id imagesRequested  = row[@"images_requested"];
    if (imagesReturned && ![imagesReturned isKindOfClass:[NSNull class]]) {
        _imagesLabel.text = [NSString stringWithFormat:@"Images: %@ returned / %@ requested",
                             imagesReturned, imagesRequested ?: @"?"];
    } else {
        _imagesLabel.text = @"";
    }

    // API cost
    id apiCostValue = row[@"api_cost_usd"];
    if (apiCostValue && ![apiCostValue isKindOfClass:[NSNull class]]) {
        _costLabel.text = [NSString stringWithFormat:@"API cost: $%.4f", [apiCostValue doubleValue]];
    } else {
        _costLabel.text = @"";
    }

    // Cost per 100 coins efficiency
    id effValue = row[@"cost_per_100_coins"];
    if (effValue && ![effValue isKindOfClass:[NSNull class]]) {
        double eff          = [effValue doubleValue];
        _effLabel.text      = [NSString stringWithFormat:@"$%.4f / 100 coins", eff];
        _effLabel.textColor = efficiencyColor(eff);
    } else {
        _effLabel.text      = @"—";
        _effLabel.textColor = EZMuted();
    }

    // Timestamp
    NSString *isoDate = safeString(row[@"created_at"]);
    if (isoDate.length >= 19) {
        NSDateFormatter *isoParser = [NSDateFormatter new];
        isoParser.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        isoParser.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
        NSDate *parsedDate   = [isoParser dateFromString:[isoDate substringToIndex:19]];
        _timeLabel.text = parsedDate ? [sharedDisplayFormatter() stringFromDate:parsedDate] : isoDate;
    } else {
        _timeLabel.text = isoDate;
    }

    // Status dot
    NSString *status = safeString(row[@"status"]);
    if (!status.length) status = @"complete";
    if ([status isEqualToString:@"pending"]) {
        _statusDot.backgroundColor = [UIColor systemYellowColor];
    } else if ([status isEqualToString:@"error"]) {
        _statusDot.backgroundColor = [UIColor systemRedColor];
    } else {
        _statusDot.backgroundColor = [UIColor systemGreenColor];
    }

    [self setNeedsLayout];
}

- (NSString *)friendlyFeature:(NSString *)featureKey {
    NSDictionary *featureNames = @{
        @"chat_mini":       @"💬 Chat Mini",
        @"chat_standard":   @"💬 Chat Standard",
        @"chat_premium":    @"💬 Chat Premium",
        @"image_low":       @"🖼 Image — Low",
        @"image_medium":    @"🖼 Image — Medium",
        @"image_high":      @"🖼 Image — High",
        @"dalle3_standard": @"🖼 DALL-E 3",
        @"dalle3_hd":       @"🖼 DALL-E 3 HD",
        @"sora_10s":        @"🎬 Sora 10s",
        @"sora_pro_10s":    @"🎬 Sora Pro 10s",
        @"tts":             @"🔊 TTS",
        @"voice_clone":     @"🎤 Voice Clone",
        @"whisper_minute":  @"🎙 Whisper",
        @"web_search":      @"🔍 Web Search",
    };
    return featureNames[featureKey] ?: featureKey;
}

// Updates the subtitle to show which filter is currently active.
// Pass nil to restore the default "N transactions loaded" text.
- (void)setFilterDescription:(NSString *)filterDescription {
    if (filterDescription.length > 0) {
        _subtitleLabel.text = [NSString stringWithFormat:@"Filter: %@", filterDescription];
    } else {
        _subtitleLabel.text = [NSString stringWithFormat:@"%ld transactions loaded", (long)_lastTotalCalls];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat cellWidth  = self.contentView.bounds.size.width;
    CGFloat cellHeight = self.contentView.bounds.size.height;
    CGFloat padding    = 12;
    _card.frame = CGRectMake(12, 6, cellWidth - 24, cellHeight - 12);

    CGFloat cardWidth = _card.bounds.size.width;
    CGFloat x = padding, y = padding;

    // Status dot — top-right corner
    _statusDot.frame = CGRectMake(cardWidth - padding - 8, padding, 8, 8);

    // Row 1: feature (left) + timestamp (right)
    _featureLabel.frame = CGRectMake(x, y, cardWidth - 120, 18);
    _timeLabel.frame    = CGRectMake(cardWidth - 118, y, 106, 14);
    y += 20;

    // Row 2: model (left) + user email (right)
    _modelLabel.frame     = CGRectMake(x, y, cardWidth * 0.45, 14);
    _userEmailLabel.frame = CGRectMake(cardWidth - 190, y, 178, 14);
    y += 16;

    // Row 3: IP address (right-aligned, small)
    _ipLabel.frame = CGRectMake(cardWidth - 190, y, 178, 13);
    y += 16;

    // Prompt (2 lines)
    _promptLabel.frame = CGRectMake(x, y, cardWidth - x * 2, 36);
    y += 40;

    // Coins + balance (left), efficiency (right)
    _coinsLabel.frame   = CGRectMake(x, y, 180, 20);
    _effLabel.frame     = CGRectMake(cardWidth - 188, y, 176, 20);
    y += 22;
    _balanceLabel.frame = CGRectMake(x, y, 220, 14);
    y += 18;

    // Detail rows
    _tokensLabel.frame  = CGRectMake(x, y, cardWidth - x * 2, 14);
    y += 17;
    _imagesLabel.frame  = CGRectMake(x, y, cardWidth - x * 2, 14);
    y += 17;
    _costLabel.frame    = CGRectMake(x, y, cardWidth - x * 2, 14);
}

+ (CGFloat)rowHeight { return 210; }

@end

// ── Admin summary header view ─────────────────────────────────────────────────
// Shows aggregate stats across all users for the current filter/page set.
// Data comes from the aggregate block in get-admin-ledger mode=user response.

@interface EZAdminSummaryView : UIView
- (void)configureWithAggregate:(NSDictionary *)aggregate;
// Updates the subtitle line to show an active filter description.
// Pass nil to restore the default "N transactions loaded" text.
- (void)setFilterDescription:(nullable NSString *)filterDescription;
@end

@implementation EZAdminSummaryView {
    UILabel *_headlineLabel;      // "🌐 All Users"
    UILabel *_subtitleLabel;      // row count, or active filter description
    UILabel *_globalEffLabel;     // cost/100 coins
    UILabel *_marginLabel;        // implied margin %
    UILabel *_circulationLabel;   // platform-wide coins in circulation (global, unfiltered)
    UILabel *_driftLabel;         // ledger-vs-balances drift warning; hidden when zero
    UILabel *_totalCoinsLabel;
    UILabel *_totalCostLabel;
    UILabel *_totalCallsLabel;
    UILabel *_totalImagesLabel;
    UILabel *_totalTokensLabel;
    NSInteger _lastTotalCalls;    // preserved so setFilterDescription:nil can restore the default subtitle
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.backgroundColor = EZBg();

    UILabel* (^makeLabel)(CGFloat, UIFontWeight, UIColor *, NSTextAlignment) =
    ^UILabel *(CGFloat size, UIFontWeight weight, UIColor *color, NSTextAlignment alignment) {
        UILabel *label       = [UILabel new];
        label.font           = [UIFont systemFontOfSize:size weight:weight];
        label.textColor      = color;
        label.textAlignment  = alignment;
        label.numberOfLines  = 2;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor        = 0.7;
        [self addSubview:label];
        return label;
    };

    _headlineLabel   = makeLabel(26, UIFontWeightBold,    EZGold(),                              NSTextAlignmentCenter);
    _subtitleLabel   = makeLabel(12, UIFontWeightRegular, EZMuted(),                             NSTextAlignmentCenter);
    _globalEffLabel  = makeLabel(20, UIFontWeightBold,    [UIColor systemGreenColor],            NSTextAlignmentCenter);
    _marginLabel     = makeLabel(12, UIFontWeightRegular, [UIColor colorWithWhite:0.6 alpha:1],  NSTextAlignmentCenter);
    _circulationLabel= makeLabel(17, UIFontWeightSemibold,[UIColor whiteColor],                  NSTextAlignmentCenter);
    _driftLabel      = makeLabel(11, UIFontWeightRegular, [UIColor systemRedColor],              NSTextAlignmentCenter);
    _totalCoinsLabel = makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalCostLabel  = makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalCallsLabel = makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalImagesLabel= makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalTokensLabel= makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);

    _driftLabel.hidden = YES;   // shown only when ledger and live balances disagree

    // Gold divider line (above the per-call stats)
    UIView *divider = [UIView new];
    divider.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.25];
    divider.tag = 99;
    [self addSubview:divider];

    // Second divider, between margin and the circulation total
    UIView *circulationDivider = [UIView new];
    circulationDivider.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.15];
    circulationDivider.tag = 100;
    [self addSubview:circulationDivider];

    return self;
}

- (void)configureWithAggregate:(NSDictionary *)aggregate {
    _headlineLabel.text = @"🌐 All Users";

    // get-admin-ledger mode=user uses different aggregate keys than get-usage-log:
    //   total_coins  (not total_coins_charged)
    //   total_input_tokens + total_output_tokens  (not total_tokens)
    //   implied_margin_pct  (computed server-side, not client-side)
    NSInteger totalCalls    = [aggregate[@"total_calls"]          integerValue];
    NSInteger totalCoins    = [aggregate[@"total_coins"]          integerValue];
    double    totalCostUsd  = [aggregate[@"total_api_cost_usd"]   doubleValue];
    NSInteger totalImages   = [aggregate[@"total_images"]         integerValue];
    NSInteger inputTokens   = [aggregate[@"total_input_tokens"]   integerValue];
    NSInteger outputTokens  = [aggregate[@"total_output_tokens"]  integerValue];
    NSInteger totalTokens   = inputTokens + outputTokens;

    _subtitleLabel.text = [NSString stringWithFormat:@"%ld transactions loaded", (long)totalCalls];
    _lastTotalCalls     = totalCalls;

    // Efficiency and margin — prefer server-computed values from the response
    id costPer100Value  = aggregate[@"cost_per_100_coins"];
    id marginPctValue   = aggregate[@"implied_margin_pct"];

    if (costPer100Value && ![costPer100Value isKindOfClass:[NSNull class]]) {
        double costPer100          = [costPer100Value doubleValue];
        _globalEffLabel.text       = [NSString stringWithFormat:@"$%.4f / 100 coins", costPer100];
        _globalEffLabel.textColor  = efficiencyColor(costPer100);

        double marginPct = (marginPctValue && ![marginPctValue isKindOfClass:[NSNull class]])
            ? [marginPctValue doubleValue]
            : (totalCoins > 0 ? (totalCoins * 0.0100 - totalCostUsd) / (totalCoins * 0.0100) * 100 : 0);

        _marginLabel.text      = [NSString stringWithFormat:
            @"Implied margin: %.1f%%   |   Breakeven: $%.2f–$%.2f",
            marginPct, kBreakevenBest, kBreakevenWorst];
        _marginLabel.textColor = marginPct >= 0
            ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    } else {
        _globalEffLabel.text = @"No cost data yet";
        _marginLabel.text    = @"";
    }

    _totalCoinsLabel.text  = [NSString stringWithFormat:@"Coins used\n%ld",  (long)totalCoins];
    _totalCostLabel.text   = [NSString stringWithFormat:@"API cost\n$%.4f",  totalCostUsd];
    _totalCallsLabel.text  = [NSString stringWithFormat:@"Calls\n%ld",       (long)totalCalls];
    _totalImagesLabel.text = [NSString stringWithFormat:@"Images\n%ld",      (long)totalImages];
    _totalTokensLabel.text = [NSString stringWithFormat:@"Tokens\n%ld",      (long)totalTokens];

    // Platform-wide circulation — global and unfiltered, unlike everything
    // above. See get-admin-ledger's comment on the global_* aggregate keys.
    NSInteger globalCirculating = [aggregate[@"global_total_circulating"] integerValue];
    NSInteger globalBalances    = [aggregate[@"global_total_balances"]    integerValue];
    NSInteger drift              = [aggregate[@"global_circulation_drift"] integerValue];

    _circulationLabel.text = [NSString stringWithFormat:@"🪙 %@ coins in circulation",
                               formattedCoinCount(globalCirculating)];

    if (drift != 0) {
        // Ledger total (credits − debits) disagrees with the actual sum of
        // every live balance. Either a coin-mutating path changed a balance
        // without logging a matching coin_transactions row, or something
        // outside the edge functions touched a balance directly — exactly
        // the kind of thing this metric exists to catch.
        _driftLabel.hidden = NO;
        _driftLabel.text   = [NSString stringWithFormat:
            @"⚠️ Drift: %@%@ coins — live balances total %@",
            drift > 0 ? @"+" : @"−", formattedCoinCount(ABS(drift)), formattedCoinCount(globalBalances)];
    } else {
        _driftLabel.hidden = YES;
        _driftLabel.text   = @"";
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat viewWidth = self.bounds.size.width;
    CGFloat padding   = 16;

    _headlineLabel.frame  = CGRectMake(0, 14, viewWidth, 34);
    _subtitleLabel.frame  = CGRectMake(0, 50, viewWidth, 18);

    UIView *divider = [self viewWithTag:99];
    divider.frame = CGRectMake(padding * 2, 74, viewWidth - padding * 4, 0.5);

    _globalEffLabel.frame = CGRectMake(0, 82, viewWidth, 28);
    _marginLabel.frame    = CGRectMake(padding, 112, viewWidth - padding * 2, 30);

    UIView *circulationDivider = [self viewWithTag:100];
    circulationDivider.frame = CGRectMake(padding * 2, 144, viewWidth - padding * 4, 0.5);

    _circulationLabel.frame = CGRectMake(0, 150, viewWidth, 22);
    _driftLabel.frame       = CGRectMake(padding, 172, viewWidth - padding * 2, 14);

    CGFloat columnWidth = viewWidth / 5;
    NSArray *statLabels = @[_totalCoinsLabel, _totalCostLabel, _totalCallsLabel,
                            _totalImagesLabel, _totalTokensLabel];
    for (NSInteger i = 0; i < (NSInteger)statLabels.count; i++) {
        ((UILabel *)statLabels[(NSUInteger)i]).frame =
            CGRectMake(columnWidth * i, 190, columnWidth, 36);
    }
}

+ (CGFloat)height { return 234; }

@end

// ── Main VC ───────────────────────────────────────────────────────────────────

@interface EZCoinLedgerViewController () <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UITableView            *tableView;
@property (nonatomic, strong) UISearchBar            *searchBar;
@property (nonatomic, strong) EZAdminSummaryView     *summaryView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSDictionary           *aggregate;
@property (nonatomic, assign) BOOL                    loading;
@property (nonatomic, assign) BOOL                    hasMore;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel                *emptyLabel;
@property (nonatomic, strong) NSString               *adminSecret;   // from NSUserDefaults
@property (nonatomic, strong) NSString               *activeSearchQuery;  // nil = no filter
@property (nonatomic, strong) NSTimer                *searchDebounceTimer;
@end

@implementation EZCoinLedgerViewController

static NSInteger const kPageSize = 50;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"🌐 Admin Ledger";
    self.view.backgroundColor = EZBg();
    self.rows    = [NSMutableArray array];
    self.hasMore = YES;
    self.loading = NO;

    // Load stored admin secret — never prompts on its own; fetchPage triggers the prompt
    self.adminSecret = [[NSUserDefaults standardUserDefaults] stringForKey:kAdminSecretUDKey];

    [self styleNav];
    [self setupTable];
    [self fetchPage:0];
}

- (void)styleNav {
    UINavigationBarAppearance *navAppearance = [UINavigationBarAppearance new];
    [navAppearance configureWithOpaqueBackground];
    navAppearance.backgroundColor       = EZBg();
    navAppearance.titleTextAttributes   = @{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName:            [UIFont boldSystemFontOfSize:17],
    };
    self.navigationController.navigationBar.standardAppearance   = navAppearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = navAppearance;
    self.navigationController.navigationBar.tintColor            = EZGold();

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor colorWithWhite:0.6 alpha:1];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(refreshTapped)];
}

- (void)setupTable {
    // ── Search bar ────────────────────────────────────────────────────────────
    // Floats at the top of the view, above the table. Does not scroll away.
    // Typing an @-sign triggers an email filter; anything else filters by
    // feature name (case-insensitive substring, e.g. "tts", "chat", "image").
    // Fetches are debounced 0.4s after the last keystroke to avoid hammering
    // the server on every character. Clearing the field instantly resets.
    self.searchBar                    = [UISearchBar new];
    self.searchBar.placeholder        = @"email or feature (tts, chat, image…)";
    self.searchBar.searchBarStyle     = UISearchBarStyleMinimal;
    self.searchBar.barStyle           = UIBarStyleBlack;
    self.searchBar.tintColor          = EZGold();
    self.searchBar.returnKeyType      = UIReturnKeySearch;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate           = self;
    [self.view addSubview:self.searchBar];

    // ── Summary view (scrolls as tableHeaderView) ─────────────────────────────
    self.summaryView = [EZAdminSummaryView new];
    self.summaryView.frame = CGRectMake(0, 0,
        self.view.bounds.size.width, [EZAdminSummaryView height]);

    // ── Table view ────────────────────────────────────────────────────────────
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                                  style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor     = EZBg();
    self.tableView.separatorStyle      = UITableViewCellSeparatorStyleNone;
    self.tableView.tableHeaderView     = self.summaryView;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.delegate            = self;
    self.tableView.dataSource          = self;
    self.tableView.rowHeight           = [EZAdminLedgerCell rowHeight];
    [self.tableView registerClass:[EZAdminLedgerCell class]
           forCellReuseIdentifier:kLedgerCellID];
    [self.view addSubview:self.tableView];

    // ── Layout — search bar pinned to safe area top, table fills the rest ─────
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor      constraintEqualToAnchor:safeArea.topAnchor],
        [self.searchBar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.tableView.topAnchor      constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.tableView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // ── Spinner ───────────────────────────────────────────────────────────────
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color            = EZGold();
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center           = self.view.center;
    [self.view addSubview:self.spinner];

    // ── Empty state label ─────────────────────────────────────────────────────
    self.emptyLabel               = [UILabel new];
    self.emptyLabel.text          = @"No transactions found.";
    self.emptyLabel.textColor     = EZMuted();
    self.emptyLabel.font          = [UIFont systemFontOfSize:15];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden        = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

// ── Admin secret prompt ───────────────────────────────────────────────────────
// The ADMIN_SECRET is never hardcoded. It is entered once here, stored in
// NSUserDefaults, and reused on every subsequent fetch. A 403 from the server
// clears the stored value and re-triggers this prompt.

- (void)promptForAdminSecretThenFetchPage:(NSInteger)offset {
    UIAlertController *secretAlert = [UIAlertController
        alertControllerWithTitle:@"Admin Secret Required"
                         message:@"Enter the ADMIN_SECRET value from your Supabase edge function environment."
                  preferredStyle:UIAlertControllerStyleAlert];

    [secretAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder    = @"ADMIN_SECRET";
        textField.secureTextEntry = YES;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    [secretAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                    style:UIAlertActionStyleCancel
                                                  handler:nil]];

    [secretAlert addAction:[UIAlertAction actionWithTitle:@"Continue"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
        NSString *enteredSecret = secretAlert.textFields.firstObject.text;
        if (!enteredSecret.length) return;

        self.adminSecret = enteredSecret;
        [[NSUserDefaults standardUserDefaults] setObject:enteredSecret
                                                  forKey:kAdminSecretUDKey];
        [self fetchPage:offset];
    }]];

    [self presentViewController:secretAlert animated:YES completion:nil];
}

// ── Fetch ─────────────────────────────────────────────────────────────────────

- (void)fetchPage:(NSInteger)offset {
    if (self.loading) return;

    // Prompt for admin secret if not yet stored
    if (!self.adminSecret.length) {
        [self promptForAdminSecretThenFetchPage:offset];
        return;
    }

    self.loading = YES;
    if (offset == 0) [self.spinner startAnimating];

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) {
        [self.spinner stopAnimating];
        self.loading = NO;
        return;
    }

    NSString *urlString = [NSString stringWithFormat:
        @"%@%@?mode=user&limit=%ld&offset=%ld",
        kAdminLedgerBase, kAdminLedgerPath, (long)kPageSize, (long)offset];

    // Append the active filter — auto-detected from the search bar input.
    // "@" in the query → email substring filter; anything else → feature name.
    if (self.activeSearchQuery.length > 0) {
        NSString *encoded = [self.activeSearchQuery
            stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]];
        if ([self.activeSearchQuery containsString:@"@"]) {
            urlString = [urlString stringByAppendingFormat:@"&email=%@", encoded];
        } else {
            urlString = [urlString stringByAppendingFormat:@"&feature=%@", encoded];
        }
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:urlString]];
    request.timeoutInterval = 20;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:self.adminSecret
   forHTTPHeaderField:@"x-admin-secret"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.loading = NO;

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

            // Wrong secret — clear stored value and prompt again
            if (httpResponse.statusCode == 403) {
                self.adminSecret = nil;
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAdminSecretUDKey];
                [self promptForAdminSecretThenFetchPage:offset];
                return;
            }

            if (error || !data) return;

            NSDictionary *json     = [NSJSONSerialization JSONObjectWithData:data
                                                                     options:0
                                                                       error:nil];
            NSArray      *newRows  = json[@"rows"];
            NSDictionary *agg      = json[@"aggregate"];

            if (offset == 0) [self.rows removeAllObjects];

            if ([newRows isKindOfClass:[NSArray class]]) {
                [self.rows addObjectsFromArray:newRows];
                self.hasMore = ((NSInteger)newRows.count == kPageSize);
            }

            if ([agg isKindOfClass:[NSDictionary class]]) {
                self.aggregate = agg;
                [self.summaryView configureWithAggregate:agg];
                // Update the subtitle to show the active filter, or clear it
                [self.summaryView setFilterDescription:self.activeSearchQuery];
            }

            [self.tableView reloadData];
            self.emptyLabel.hidden = self.rows.count > 0;
            if (self.rows.count == 0 && self.activeSearchQuery.length > 0) {
                self.emptyLabel.text = [NSString stringWithFormat:
                    @"No results for \"%@\"", self.activeSearchQuery];
            } else {
                self.emptyLabel.text = @"No transactions found.";
            }
        });
    }] resume];
}

// ── UITableView ───────────────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZAdminLedgerCell *cell = [tableView dequeueReusableCellWithIdentifier:kLedgerCellID
                                                              forIndexPath:indexPath];
    [cell configureWithRow:self.rows[(NSUInteger)indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    // Paginate — load the next page when the user is 5 rows from the bottom
    if (self.hasMore && !self.loading &&
        indexPath.row == (NSInteger)self.rows.count - 5) {
        [self fetchPage:(NSInteger)self.rows.count];
    }
}

// ── UISearchBarDelegate ───────────────────────────────────────────────────────

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;

    NSString *trimmed = [searchText stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (trimmed.length == 0) {
        // Clear filter immediately — no debounce needed for an empty field
        self.activeSearchQuery = nil;
        self.hasMore = YES;
        [self fetchPage:0];
        return;
    }

    // Store the pending query and wait 0.4s after the last keystroke before
    // hitting the server — avoids a request for every character typed.
    self.activeSearchQuery = trimmed;
    self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                                target:self
                                                              selector:@selector(searchDebounceTimerFired)
                                                              userInfo:nil
                                                               repeats:NO];
}

- (void)searchDebounceTimerFired {
    self.searchDebounceTimer = nil;
    self.hasMore = YES;
    [self fetchPage:0];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    // Keyboard Search button — fire immediately without waiting for the timer
    [searchBar resignFirstResponder];
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    self.hasMore = YES;
    [self fetchPage:0];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)refreshTapped {
    // Preserve the active filter — refresh re-runs the current query from page 0
    self.hasMore = YES;
    [self fetchPage:0];
}

- (void)closeTapped {
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#endif // DEBUG
