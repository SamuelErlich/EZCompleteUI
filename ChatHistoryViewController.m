// ChatHistoryViewController.m
// EZCompleteUI

#import "ChatHistoryViewController.h"
#import "helpers.h"
#import "EZUITheme.h"

// Keep translated presentation text separate from models, defaults, and saved data.
static NSString *EZWorkspaceLocalized(NSString *key) {
    NSString *value = NSLocalizedStringFromTable(key, @"EZWorkspace", nil);
    if (![value isEqualToString:key]) return value;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"en" ofType:@"lproj"];
    NSBundle *fallback = path.length ? [NSBundle bundleWithPath:path] : nil;
    return fallback ? [fallback localizedStringForKey:key value:key table:@"EZWorkspace"] : value;
}


static NSString * const kCellID = @"EZThreadCell";

@interface ChatHistoryViewController () <UISearchBarDelegate>
@property (nonatomic, strong) NSArray<EZChatThread *> *allThreads;
@property (nonatomic, strong) NSArray<EZChatThread *> *threads;
@property (nonatomic, strong) UISearchBar *searchBar;
@end

@implementation ChatHistoryViewController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = EZWorkspaceLocalized(@"History.Title");
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
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(focusSearch)];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(dismissSelf)];

    self.navigationItem.leftBarButtonItem.accessibilityLabel = EZWorkspaceLocalized(@"Common.Search");
    self.navigationItem.rightBarButtonItem.accessibilityLabel = EZWorkspaceLocalized(@"Common.Close");

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kCellID];
    self.tableView.rowHeight          = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70;

    [self setupSearchBar];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.allThreads = EZThreadList();
    [self applySearchFilter];

    // Disable close button when no threads exist? keep enabled to allow dismiss.
    self.navigationItem.rightBarButtonItem.enabled = (self.allThreads.count > 0);
}

// ─────────────────────────────────────────────────────────────────────────────
- (void)setupSearchBar {
    if (self.searchBar) return;
    self.searchBar                     = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.autoresizingMask    = UIViewAutoresizingFlexibleWidth;
    self.searchBar.placeholder         = EZWorkspaceLocalized(@"History.Search");
    self.searchBar.searchBarStyle      = UISearchBarStyleMinimal;
    self.searchBar.tintColor           = [EZUITheme accentSecondaryColor];
    self.searchBar.searchTextField.backgroundColor = [EZUITheme surfaceElevatedColor];
    self.searchBar.searchTextField.textColor = [EZUITheme primaryTextColor];
    self.searchBar.delegate            = self;
    self.searchBar.showsCancelButton   = NO;
    self.tableView.tableHeaderView     = self.searchBar;
}

- (void)applySearchFilter {
    NSString *text = [self.searchBar.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        self.threads = self.allThreads;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(EZChatThread *thread, NSDictionary *bindings) {
            NSString *title = thread.title ?: @"";
            return [title rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.threads = [self.allThreads filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)focusSearch {
    [self.searchBar becomeFirstResponder];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applySearchFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Table view data source
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.threads.count == 0 ? 1 : (NSInteger)self.threads.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID
                                                            forIndexPath:indexPath];
    // Reset reused state
    cell.accessoryType          = UITableViewCellAccessoryNone;
    cell.userInteractionEnabled = YES;
    cell.selectionStyle         = UITableViewCellSelectionStyleDefault;
    cell.backgroundColor = [UIColor clearColor];
    cell.tintColor = [EZUITheme accentSecondaryColor];
    UIBackgroundConfiguration *background = [UIBackgroundConfiguration listPlainCellConfiguration];
    background.backgroundColor = [EZUITheme surfaceColor];
    background.cornerRadius = 16;
    background.backgroundInsets = NSDirectionalEdgeInsetsMake(5, 16, 5, 16);
    cell.backgroundConfiguration = background;

    if (self.threads.count == 0) {
        // Empty state row
        if (@available(iOS 14.0, *)) {
            UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
            cfg.text                  = EZWorkspaceLocalized(@"History.Empty");
            cfg.textProperties.numberOfLines = 0;
            cfg.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(22, 32, 22, 32);
            cfg.image = [UIImage systemImageNamed:@"bubble.left.and.bubble.right"];
            cfg.imageProperties.tintColor = [EZUITheme secondaryTextColor];
            cfg.textProperties.color  = [EZUITheme secondaryTextColor];
            cell.contentConfiguration = cfg;
        } else {
            cell.textLabel.text      = EZWorkspaceLocalized(@"History.Empty");
            cell.textLabel.textColor = [EZUITheme secondaryTextColor];
        }
        cell.userInteractionEnabled = NO;
        cell.selectionStyle         = UITableViewCellSelectionStyleNone;
        return cell;
    }

    EZChatThread *thread = self.threads[(NSUInteger)indexPath.row];

    // Format relative date
    NSDateFormatter *fmt    = [[NSDateFormatter alloc] init];
    fmt.dateStyle           = NSDateFormatterShortStyle;
    fmt.timeStyle           = NSDateFormatterShortStyle;
    fmt.doesRelativeDateFormatting = YES;

    // Parse the ISO-8601 updatedAt string back to NSDate for formatting
    NSDateFormatter *isoFmt = [[NSDateFormatter alloc] init];
    isoFmt.dateFormat       = @"yyyy-MM-dd'T'HH:mm:ss";
    isoFmt.locale           = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDate *updated         = [isoFmt dateFromString:thread.updatedAt];
    NSString *dateStr       = updated ? [fmt stringFromDate:updated] : thread.updatedAt;
    NSString *subtitle      = [NSString stringWithFormat:@"%@  •  %@",
                               thread.modelName ?: @"?", dateStr ?: @""];

    if (@available(iOS 14.0, *)) {
        UIListContentConfiguration *cfg  = cell.defaultContentConfiguration;
        cfg.text                         = thread.title ?: EZWorkspaceLocalized(@"History.Untitled");
        cfg.textProperties.numberOfLines = 2;
        cfg.textProperties.color = [EZUITheme primaryTextColor];
        cfg.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cfg.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(20, 32, 20, 32);
        cfg.image = [UIImage systemImageNamed:@"bubble.left.and.bubble.right"];
        cfg.imageProperties.tintColor = [EZUITheme accentSecondaryColor];
        cfg.secondaryText                = subtitle;
        cfg.secondaryTextProperties.color = [EZUITheme secondaryTextColor];
        cfg.secondaryTextProperties.numberOfLines = 2;
        cfg.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        cell.contentConfiguration        = cfg;
    } else {
        cell.textLabel.text              = thread.title ?: EZWorkspaceLocalized(@"History.Untitled");
        cell.textLabel.numberOfLines     = 2;
        cell.textLabel.textColor = [EZUITheme primaryTextColor];
        cell.detailTextLabel.text        = subtitle;
        cell.detailTextLabel.textColor   = [EZUITheme secondaryTextColor];
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Table view delegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.threads.count == 0) return;

    EZChatThread *stub = self.threads[(NSUInteger)indexPath.row];

    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:EZWorkspaceLocalized(@"History.RestoreTitle")
                         message:EZWorkspaceLocalized(@"History.RestoreMessage")
                  preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:EZWorkspaceLocalized(@"History.Restore")
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
        // Load full thread with messages
        EZChatThread *full = EZThreadLoad(stub.threadID);
        if (!full) {
            UIAlertController *err = [UIAlertController
                alertControllerWithTitle:EZWorkspaceLocalized(@"Common.Error")
                                 message:EZWorkspaceLocalized(@"History.LoadError")
                          preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:EZWorkspaceLocalized(@"Common.OK")
                                                   style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:err animated:YES completion:nil];
            return;
        }
        EZLogf(EZLogLevelInfo, @"HISTORY", @"Restoring thread: %@", full.threadID);
        [self dismissViewControllerAnimated:YES completion:^{
            [self.delegate chatHistoryDidSelectThread:full];
        }];
    }]];

    [confirm addAction:[UIAlertAction actionWithTitle:EZWorkspaceLocalized(@"Common.Cancel")
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return EZWorkspaceLocalized(@"Common.Delete");
}

// Swipe-to-delete individual thread
- (BOOL)tableView:(UITableView *)tableView
canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.threads.count > 0;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && self.threads.count > 0) {
        EZChatThread *thread = self.threads[(NSUInteger)indexPath.row];
        EZLogf(EZLogLevelInfo, @"HISTORY", @"Deleting thread: %@", thread.threadID);
        EZThreadDelete(thread.threadID);
        [self reload];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Delete All
// ─────────────────────────────────────────────────────────────────────────────

- (void)confirmDeleteAll {
    if (self.threads.count == 0) return;
    NSString *msg = [NSString stringWithFormat:
        EZWorkspaceLocalized(@"History.DeleteAllMessage"),
        (unsigned long)self.threads.count];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:EZWorkspaceLocalized(@"History.DeleteAllTitle")
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:EZWorkspaceLocalized(@"History.DeleteAll")
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
        for (EZChatThread *t in self.threads) EZThreadDelete(t.threadID);
        EZLog(EZLogLevelInfo, @"HISTORY", @"All threads deleted by user");
        [self reload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:EZWorkspaceLocalized(@"Common.Cancel")
                                             style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
