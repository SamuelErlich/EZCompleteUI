//
//  EZVoicePickerViewController.m
//  EZTTSLibrary
//

#import "EZVoicePickerViewController.h"
#import "EZTTSVoiceService.h"

static NSString * const kEZVoicePickerCellID = @"EZVoicePickerCell";

@interface EZVoicePickerViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *emptyStateLabel;

@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *allVoices;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *filteredVoices;

@end

@implementation EZVoicePickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Choose a Voice";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.allVoices = @[];
    self.filteredVoices = @[];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                              target:self
                              action:@selector(handleCancelTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search voices";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.emptyStateLabel = [[UILabel alloc] init];
    self.emptyStateLabel.text = @"No voices found.";
    self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyStateLabel.hidden = YES;
    [self.view addSubview:self.emptyStateLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    [self fetchVoices];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0);
    self.emptyStateLabel.frame = CGRectMake(20, self.view.safeAreaInsets.top + 40, self.view.bounds.size.width - 40, 40);
}

- (void)fetchVoices {
    [self.spinner startAnimating];
    self.tableView.hidden = YES;
    self.emptyStateLabel.hidden = YES;

    __weak typeof(self) weakSelf = self;
    [EZTTSVoiceService fetchVoicesWithCompletion:^(NSArray<NSDictionary<NSString *,id>*> * _Nullable voices, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.spinner stopAnimating];
        strongSelf.tableView.hidden = NO;

        if (error) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:error.userInfo[@"EZTTSVoiceServiceAlertTitle"] ?: @"Couldn't load voices"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:alert animated:YES completion:nil];
            return;
        }

        strongSelf.allVoices = voices ?: @[];
        strongSelf.filteredVoices = strongSelf.allVoices;
        strongSelf.emptyStateLabel.hidden = (strongSelf.allVoices.count > 0);
        [strongSelf.tableView reloadData];
    }];
}

- (void)handleCancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        self.filteredVoices = self.allVoices;
    } else {
        NSString *needle = query.lowercaseString;
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary *voice in self.allVoices) {
            NSString *name = [self displayNameForVoice:voice];
            if ([name.lowercaseString containsString:needle]) [matches addObject:voice];
        }
        self.filteredVoices = matches;
    }
    self.emptyStateLabel.hidden = (self.filteredVoices.count > 0);
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredVoices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kEZVoicePickerCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kEZVoicePickerCellID];
    }
    NSDictionary *voice = self.filteredVoices[indexPath.row];
    cell.textLabel.text = [self displayNameForVoice:voice];

    NSString *category = voice[@"category"];
    if ([category isKindOfClass:[NSString class]] && category.length > 0) {
        cell.detailTextLabel.text = [category capitalizedString];
    } else {
        cell.detailTextLabel.text = nil;
    }
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *voice = self.filteredVoices[indexPath.row];
    NSString *voiceID = [self voiceIDForVoice:voice];
    NSString *voiceName = [self displayNameForVoice:voice];

    void (^selected)(NSString *, NSString * _Nullable) = self.onVoiceSelected;
    [self dismissViewControllerAnimated:YES completion:^{
        if (selected && voiceID.length > 0) selected(voiceID, voiceName);
    }];
}

#pragma mark - Helpers

- (NSString *)voiceIDForVoice:(NSDictionary *)voice {
    id vid = voice[@"voice_id"] ?: voice[@"id"] ?: voice[@"voiceId"];
    return [vid isKindOfClass:[NSString class]] ? vid : @"";
}

- (NSString *)displayNameForVoice:(NSDictionary *)voice {
    id name = voice[@"name"] ?: voice[@"voice_name"];
    if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0) return name;
    return [self voiceIDForVoice:voice];
}

@end
