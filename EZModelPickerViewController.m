//
//  EZModelPickerViewController.m
//  EZCompleteUI v1.2
//

#import "EZModelPickerViewController.h"
#import "EZCoinStoreViewController.h"
#import "EZEntitlementManager.h"
#import "EZUITheme.h"

// Keep translated presentation text separate from models, defaults, and saved data.
static NSString *EZWorkspaceLocalized(NSString *key) {
    NSString *value = NSLocalizedStringFromTable(key, @"EZWorkspace", nil);
    if (![value isEqualToString:key]) return value;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"en" ofType:@"lproj"];
    NSBundle *fallback = path.length ? [NSBundle bundleWithPath:path] : nil;
    return fallback ? [fallback localizedStringForKey:key value:key table:@"EZWorkspace"] : value;
}


static NSString *EZLocalized(NSString *key) {
    NSString *localized = NSLocalizedString(key, nil);
    if (![localized isEqualToString:key]) return localized;

    // Some English regional locales do not resolve en.lproj through the
    // normal bundle fallback. Use the bundled English table only when the
    // standard lookup did not find a value.
    NSString *englishPath = [[NSBundle mainBundle] pathForResource:@"en"
                                                            ofType:@"lproj"];
    NSBundle *englishBundle = englishPath.length ? [NSBundle bundleWithPath:englishPath] : nil;
    return englishBundle
        ? [englishBundle localizedStringForKey:key value:key table:@"Localizable"]
        : localized;
}

static NSDictionary<NSString *, NSString *> *EZModelLabels(void) {
    return @{
        @"gpt-6-astra":            EZLocalized(@"EZModelLabel.ChatVisionNewest"),
        @"gpt-5.6-sol":            EZLocalized(@"EZModelLabel.ChatVision"),
        @"gpt-5.6-terra":          EZLocalized(@"EZModelLabel.ChatVisionBalanced"),
        @"gpt-5.6-luna":           EZLocalized(@"EZModelLabel.ChatVisionFastCheap"),
     //   @"gpt-5-pro":              EZLocalized(@"EZModelLabel.ChatVision"),
        @"gpt-5":                  EZLocalized(@"EZModelLabel.ChatVision"),
        @"gpt-5-mini":             EZLocalized(@"EZModelLabel.ChatVision"),
        @"gpt-4o":                 EZLocalized(@"EZModelLabel.ChatVision"),
        @"gpt-4o-mini":            EZLocalized(@"EZModelLabel.ChatVisionFastCheap"),
        @"gpt-4-turbo":            EZLocalized(@"EZModelLabel.ChatVision"),
        @"gpt-4":                  EZLocalized(@"EZModelLabel.ChatVision"),
        @"gpt-3.5-turbo":          EZLocalized(@"EZModelLabel.ChatOnly"),
        @"gpt-image-2.5-flare":    EZLocalized(@"EZModelLabel.ImageGenNewestFast"),
        @"gpt-image-2.5-sunburst": EZLocalized(@"EZModelLabel.ImageGenEditPrecision"),
        @"gpt-image-2":            EZLocalized(@"EZModelLabel.ImageGenEdit"),
        @"gpt-image-1.5":          EZLocalized(@"EZModelLabel.ImageGen"),
        @"gpt-image-1":            EZLocalized(@"EZModelLabel.ImageGenEdit"),
        @"gpt-image-1-mini":       EZLocalized(@"EZModelLabel.ImageGenFastCheap"),
       @"chatgpt-image-latest":   EZLocalized(@"EZModelLabel.ChatGPTImageLatest"),
        @"whisper-1":              EZLocalized(@"EZModelLabel.AudioTranscriptionOnly"),
    };
}

static NSArray<NSString *> *EZModelSectionTitles(void) {
    return @[
        EZLocalized(@"EZModelSection.FrontierReasoning"),
        EZLocalized(@"EZModelSection.GPT4Chat"),
        EZLocalized(@"EZModelSection.ImageGeneration"),
        EZLocalized(@"EZModelSection.AudioTranscription"),
    ];
}

static NSArray<NSArray<NSString *> *> *EZModelSections(void) {
    return @[
        @[@"gpt-6-astra", @"gpt-5.6-sol", @"gpt-5.6-terra", @"gpt-5.6-luna", //@"gpt-5-pro",
          @"gpt-5-mini"],
        @[@"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4", @"gpt-3.5-turbo"],
        @[@"gpt-image-2.5-flare", @"gpt-image-2.5-sunburst", @"gpt-image-2", @"gpt-image-1.5", @"gpt-image-1", @"gpt-image-1-mini", @"chatgpt-image-latest"],
        @[@"whisper-1"]
    ];
}

static BOOL EZModelRequiresSubscription(NSString *model) {
    if ([model isEqualToString:@"gpt-6-astra"]) return YES;
    return [model hasPrefix:@"gpt-5.6-"] &&
           ![model isEqualToString:@"gpt-5.6-luna"];
}

@implementation EZModelPickerViewController

- (instancetype)initWithModels:(NSArray<NSString *> *)models selectedModel:(NSString *)selected {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    self.models        = models;
    self.selectedModel = selected;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = EZLocalized(@"EZModelPicker.Title");
    self.view.backgroundColor = [EZUITheme backgroundColor];
    self.view.tintColor = [EZUITheme accentSecondaryColor];
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [EZUITheme backgroundColor];
    appearance.titleTextAttributes = @{ NSForegroundColorAttributeName: [EZUITheme primaryTextColor] };
    appearance.shadowColor = [EZUITheme dividerColor];
    self.navigationItem.standardAppearance = appearance;
    self.navigationItem.scrollEdgeAppearance = appearance;
    self.navigationItem.compactAppearance = appearance;
    self.tableView.backgroundColor = [EZUITheme backgroundColor];
    self.tableView.separatorColor = [EZUITheme dividerColor];
    self.tableView.tintColor = [EZUITheme accentSecondaryColor];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:EZWorkspaceLocalized(@"Common.Done")
                                             style:UIBarButtonItemStyleDone
                                            target:self action:@selector(_dismiss)];
}

- (void)_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)selectModel:(NSString *)model {
    self.selectedModel = model;
    [self.tableView reloadData];
    if (self.onModelSelected) self.onModelSelected(model);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)hasPurchasedAccess {
    EZEntitlementManager *entitlements = [EZEntitlementManager shared];
    static NSSet<NSString *> *supportedTiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supportedTiers = [NSSet setWithObjects:@"basic", @"basic_weekly", @"standard", @"standard_annual",
                          @"pro", @"pro_annual", @"ultra", @"ultra_annual", @"power", @"power_annual",
                          @"enterprise", @"enterprise_annual", nil];
    });
    return entitlements.hasEverPurchased || [supportedTiers containsObject:entitlements.currentTier];
}

- (void)showSubscriptionRequiredAlertForModel:(NSString *)model {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:EZLocalized(@"EZSubscription.RequiredTitle")
                         message:[NSString stringWithFormat:
                                  EZLocalized(@"EZSubscription.ModelRequiredFormat"),
                                  model]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:EZLocalized(@"EZSubscription.NotNow")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:EZLocalized(@"EZSubscription.ViewPlans")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.navigationController pushViewController:[[EZCoinStoreViewController alloc] init]
                                             animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return (NSInteger)EZModelSections().count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return EZModelSectionTitles()[(NSUInteger)section];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)EZModelSections()[(NSUInteger)section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"ModelCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ModelCell"];
    }
    NSString *model = EZModelSections()[(NSUInteger)ip.section][(NSUInteger)ip.row];
    cell.textLabel.text            = model;
    cell.textLabel.font            = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    cell.textLabel.textColor       = [EZUITheme primaryTextColor];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.text      = EZModelLabels()[model] ?: @"";
    cell.detailTextLabel.font      = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.textColor = [EZUITheme secondaryTextColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.backgroundColor = [EZUITheme surfaceColor];
    cell.tintColor = [EZUITheme accentSecondaryColor];
    UIView *selectedBackground = [[UIView alloc] init];
    selectedBackground.backgroundColor = [EZUITheme accentSoftColor];
    cell.selectedBackgroundView = selectedBackground;
    NSArray<NSString *> *sectionSymbols = @[@"sparkles", @"bubble.left.and.bubble.right", @"photo", @"waveform"];
    cell.imageView.image = [UIImage systemImageNamed:sectionSymbols[(NSUInteger)ip.section]];
    cell.imageView.tintColor = [EZUITheme accentSecondaryColor];
    cell.accessibilityValue = [model isEqualToString:self.selectedModel]
        ? EZWorkspaceLocalized(@"ModelPicker.Selected") : nil;
    cell.accessoryType             = [model isEqualToString:self.selectedModel]
                                     ? UITableViewCellAccessoryCheckmark
                                     : UITableViewCellAccessoryNone;
    return cell;
}


- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.textColor = [EZUITheme secondaryTextColor];
    header.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *model = EZModelSections()[(NSUInteger)ip.section][(NSUInteger)ip.row];
    if (!EZModelRequiresSubscription(model)) {
        [self selectModel:model];
        return;
    }

    // A top-up may have completed since the last balance refresh. Refresh the
    // purchase flag before showing a gate so a stale local cache never blocks
    // a customer who has already paid.
    tv.userInteractionEnabled = NO;
    __weak typeof(self) weakSelf = self;
    [[EZEntitlementManager shared] refreshSubscriptionStatusWithCompletion:
        ^(__unused BOOL refreshed, __unused NSInteger balance) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                self.tableView.userInteractionEnabled = YES;
                if (![self hasPurchasedAccess]) {
                    [self showSubscriptionRequiredAlertForModel:model];
                    return;
                }
                [self selectModel:model];
            });
        }];
}

@end
