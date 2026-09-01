// BRCommunityAdminViewController.m
// BrainRotGame
// EZCompleteUI v1.2 — Community Admin Panel
//
// Changes from v1.1:
//   - Removed all dequeueReusableCellWithReuseIdentifier: calls. The Theos
//     SDK generates an incomplete UITableView interface (forward-declared
//     only, no method bodies visible) so both the forIndexPath: and the
//     plain variants failed with "no visible @interface" regardless of
//     whether registerClass: was called. Since the admin panel has at most
//     a handful of rows and is a one-off tool, always alloc-initing cells
//     directly is the right call — no performance implication, no SDK gap.
//   - Added initWithNibName:bundle: override (asserts) to silence the
//     -Wobjc-designated-initializers warning that fires when a subclass
//     declares its own designated initializer without overriding the
//     superclass's.
//   - NS_DESIGNATED_INITIALIZER removed from the header (and from the
//     matching NS_UNAVAILABLE declarations) since the warning suppression
//     is now handled by the explicit override above.
//
// Purpose:
//   Implementation of BRCommunityAdminViewController. See the header for the
//   public contract and the two-layer security model (compile-flag + server-
//   side code check). Layout is a UITableView with two sections:
//     Section 0 — Code entry: secure text field + Authenticate button.
//                 Always visible; collapses to zero height once authenticated.
//     Section 1 — Game list: one row per shared game, shown only after the
//                 server accepts the admin code. Rows carry swipe-to-hide and
//                 swipe-to-delete actions.

#import "BRCommunityAdminViewController.h"

/// In-memory model for one row returned by admin_list_games.
@interface BRAdminGameRecord : NSObject
@property (nonatomic, copy) NSString *sharedGameId;
@property (nonatomic, copy) NSString *themeTitle;
@property (nonatomic, copy, nullable) NSString *premise;
@property (nonatomic, assign) BOOL isHidden;
@property (nonatomic, copy, nullable) NSString *hiddenReason;
@property (nonatomic, assign) NSInteger reportCount;
@property (nonatomic, assign) NSInteger downloadCount;
@end
@implementation BRAdminGameRecord @end

@interface BRCommunityAdminViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) NSURL *endpointURL;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *codeField;
@property (nonatomic, strong, nullable) NSString *authenticatedCode;   // nil until server accepts
@property (nonatomic, strong) NSArray<BRAdminGameRecord *> *games;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong, nullable) UILabel *emptyLabel;
@end

@implementation BRCommunityAdminViewController

#pragma mark - Lifecycle

- (instancetype)initWithBrCommunityEndpointURL:(NSURL *)endpointURL {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _endpointURL = endpointURL;
        _games = @[];
    }
    return self;
}

/// Satisfies the -Wobjc-designated-initializers requirement: UIViewController's
/// designated initializer must be overridden when a subclass declares its own.
/// Marked unavailable in the header — callers must use
/// initWithBrCommunityEndpointURL:.
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil
                         bundle:(nullable NSBundle *)nibBundleOrNil {
    NSAssert(NO, @"Use initWithBrCommunityEndpointURL: instead.");
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Community Admin";
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.03 blue:0.16 alpha:1.0];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                           action:@selector(handleCloseTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.dataSource = self;
    self.tableView.delegate   = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    self.loadingSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingSpinner.color = [UIColor systemYellowColor];
    self.loadingSpinner.hidesWhenStopped = YES;
    self.loadingSpinner.center = self.view.center;
    self.loadingSpinner.autoresizingMask =
        UIViewAutoresizingFlexibleTopMargin  | UIViewAutoresizingFlexibleBottomMargin |
        UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:self.loadingSpinner];
}

- (void)handleCloseTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; // 0 = code entry, 1 = game list
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Admin Authentication";
    return self.authenticatedCode ? [NSString stringWithFormat:@"%lu Games", (unsigned long)self.games.count] : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0 && !self.authenticatedCode) return @"The admin code is verified server-side. It is never stored on this device.";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return self.authenticatedCode ? 0 : 1; // collapses after auth
    return self.authenticatedCode ? (NSInteger)self.games.count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        // Always alloc/init — avoids UITableView dequeue selector visibility
        // issues under the Theos SDK. The admin panel is a one-off tool with
        // at most 1 row in this section, so no reuse is ever needed anyway.
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                       reuseIdentifier:nil];
        cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
        cell.selectionStyle  = UITableViewCellSelectionStyleNone;

        // Build the code entry row lazily the first time.
        if (!self.codeField) {
            self.codeField = [[UITextField alloc] init];
            self.codeField.placeholder       = @"Enter admin code";
            self.codeField.secureTextEntry   = YES;
            self.codeField.returnKeyType     = UIReturnKeyDone;
            self.codeField.keyboardAppearance = UIKeyboardAppearanceDark;
            self.codeField.textColor         = [UIColor whiteColor];
            self.codeField.font              = [UIFont systemFontOfSize:16];
            self.codeField.delegate          = self;
            self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;

            UIButton *authButton = [UIButton buttonWithType:UIButtonTypeSystem];
            [authButton setTitle:@"Authenticate" forState:UIControlStateNormal];
            authButton.tintColor = [UIColor systemYellowColor];
            authButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
            [authButton addTarget:self action:@selector(handleAuthenticateTapped)
                 forControlEvents:UIControlEventTouchUpInside];

            UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.codeField, authButton]];
            stack.axis      = UILayoutConstraintAxisHorizontal;
            stack.spacing   = 12;
            stack.alignment = UIStackViewAlignmentCenter;
            stack.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:stack];

            [NSLayoutConstraint activateConstraints:@[
                [stack.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor  constant:16],
                [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [stack.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor      constant:8],
                [stack.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor   constant:-8],
                [authButton.widthAnchor constraintEqualToConstant:110],
            ]];
        }
        return cell;
    }

    // Section 1 — game row. Direct alloc/init for the same reason as above.
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    BRAdminGameRecord *record = self.games[indexPath.row];

    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = record.themeTitle;
    content.textProperties.color = record.isHidden
        ? [UIColor systemGrayColor]
        : [UIColor whiteColor];

    NSMutableString *subtitle = [NSMutableString string];
    [subtitle appendFormat:@"%ld report%@ · %ld download%@",
        (long)record.reportCount, (record.reportCount == 1 ? @"" : @"s"),
        (long)record.downloadCount, (record.downloadCount == 1 ? @"" : @"s")];
    if (record.isHidden) {
        NSString *reason = record.hiddenReason.length > 0 ? record.hiddenReason : @"hidden";
        [subtitle appendFormat:@" · ⚠ %@", reason];
    }
    content.secondaryText = subtitle;
    content.secondaryTextProperties.color = record.reportCount >= 3
        ? [UIColor systemOrangeColor]
        : [UIColor systemGrayColor];

    cell.contentConfiguration = content;
    cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return nil;
    BRAdminGameRecord *record = self.games[indexPath.row];

    NSString *title = record.isHidden ? @"Restore" : @"Hide";
    UIColor  *color = record.isHidden ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];

    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:title
                          handler:^(UIContextualAction *act, UIView *src, void (^done)(BOOL)) {
        BOOL nowHidden = !record.isHidden;
        NSString *reason = nowHidden ? @"admin: manually hidden" : nil;
        [weakSelf setHidden:nowHidden reason:reason forRecord:record completion:^(BOOL success) {
            done(success);
        }];
    }];
    action.backgroundColor = color;
    return [UISwipeActionsConfiguration configurationWithActions:@[action]];
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return nil;
    BRAdminGameRecord *record = self.games[indexPath.row];

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"Delete"
                          handler:^(UIContextualAction *act, UIView *src, void (^done)(BOOL)) {
        [weakSelf confirmDeleteRecord:record completion:^(BOOL deleted) {
            done(deleted);
        }];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self handleAuthenticateTapped];
    return NO;
}

#pragma mark - Actions

- (void)handleAuthenticateTapped {
    [self.codeField resignFirstResponder];
    NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length == 0) return;

    [self.loadingSpinner startAnimating];
    self.tableView.userInteractionEnabled = NO;

    NSDictionary *payload = @{@"action": @"admin_list_games", @"admin_code": code};
    __weak typeof(self) weakSelf = self;
    [self performAdminRequest:payload completion:^(NSDictionary * _Nullable json, NSString * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf.loadingSpinner stopAnimating];
        strongSelf.tableView.userInteractionEnabled = YES;

        if (error) {
            [strongSelf showErrorAlert:error];
            return;
        }

        NSArray<NSDictionary *> *rawGames = [json[@"games"] isKindOfClass:[NSArray class]]
            ? json[@"games"] : @[];
        NSMutableArray<BRAdminGameRecord *> *parsed = [NSMutableArray arrayWithCapacity:rawGames.count];
        for (NSDictionary *raw in rawGames) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            BRAdminGameRecord *rec = [BRAdminGameRecord new];
            rec.sharedGameId   = raw[@"id"]            ?: @"";
            rec.themeTitle     = raw[@"theme_title"]   ?: @"Untitled";
            rec.premise        = raw[@"premise"];
            rec.isHidden       = [raw[@"is_hidden"] boolValue];
            rec.hiddenReason   = raw[@"hidden_reason"];
            rec.reportCount    = [raw[@"report_count"]    integerValue];
            rec.downloadCount  = [raw[@"download_count"]  integerValue];
            [parsed addObject:rec];
        }
        strongSelf.authenticatedCode = code;
        strongSelf.games = [parsed copy];
        [strongSelf.tableView reloadData];
    }];
}

- (void)setHidden:(BOOL)hidden
           reason:(nullable NSString *)reason
        forRecord:(BRAdminGameRecord *)record
       completion:(void (^)(BOOL success))completion {
    NSMutableDictionary *payload = [@{
        @"action":         @"admin_set_hidden",
        @"admin_code":     self.authenticatedCode ?: @"",
        @"shared_game_id": record.sharedGameId,
        @"hidden":         @(hidden),
    } mutableCopy];
    if (reason) payload[@"reason"] = reason;

    __weak typeof(self) weakSelf = self;
    [self performAdminRequest:payload completion:^(NSDictionary * _Nullable json, NSString * _Nullable error) {
        if (error) {
            [weakSelf showErrorAlert:error];
            completion(NO);
            return;
        }
        record.isHidden     = hidden;
        record.hiddenReason = hidden ? (reason ?: @"admin: manually hidden") : nil;
        [weakSelf.tableView reloadData];
        completion(YES);
    }];
}

- (void)confirmDeleteRecord:(BRAdminGameRecord *)record completion:(void (^)(BOOL deleted))completion {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Delete \"%@\"?", record.themeTitle]
                         message:@"This permanently removes the game and all its assets from the community library. It cannot be undone."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete Forever"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [self deleteRecord:record completion:completion];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) { completion(NO); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteRecord:(BRAdminGameRecord *)record completion:(void (^)(BOOL deleted))completion {
    NSDictionary *payload = @{
        @"action":         @"admin_delete_game",
        @"admin_code":     self.authenticatedCode ?: @"",
        @"shared_game_id": record.sharedGameId,
    };
    __weak typeof(self) weakSelf = self;
    [self performAdminRequest:payload completion:^(NSDictionary * _Nullable json, NSString * _Nullable error) {
        if (error) {
            [weakSelf showErrorAlert:error];
            completion(NO);
            return;
        }
        NSMutableArray<BRAdminGameRecord *> *updated = [weakSelf.games mutableCopy];
        [updated removeObject:record];
        weakSelf.games = [updated copy];
        [weakSelf.tableView reloadData];
        completion(YES);
    }];
}

#pragma mark - Networking

/// All admin actions use the same unauthenticated request pattern — the
/// admin code in the payload IS the credential, so no JWT is needed here.
/// The server verifies BR_ADMIN_CODE independently.
- (void)performAdminRequest:(NSDictionary *)payload
                 completion:(void (^)(NSDictionary * _Nullable json, NSString * _Nullable errorMessage))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.endpointURL];
    request.timeoutInterval = 30.0;
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSError *serializationError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&serializationError];
    if (serializationError) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"Internal serialization error."); });
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(nil, [NSString stringWithFormat:@"Network error: %@", error.localizedDescription]);
                return;
            }
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

            if (httpResp.statusCode == 403) {
                completion(nil, @"Incorrect admin code.");
                return;
            }
            if (httpResp.statusCode == 503) {
                completion(nil, @"Admin endpoint not configured on the server.");
                return;
            }
            if (httpResp.statusCode != 200 || ![json[@"success"] boolValue]) {
                NSString *msg = [json[@"error"] isKindOfClass:[NSString class]]
                    ? json[@"error"] : @"Request failed. Please try again.";
                completion(nil, msg);
                return;
            }
            completion(json, nil);
        });
    }] resume];
}

#pragma mark - Helpers

- (void)showErrorAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Admin Error"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
