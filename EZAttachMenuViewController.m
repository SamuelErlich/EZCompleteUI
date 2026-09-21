//
//  EZAttachMenuViewController.m
//  EZCompleteUI
//

#import "EZAttachMenuViewController.h"
#import "EZUITheme.h"

static NSString *EZInterfaceString(NSString *key) {
    return NSLocalizedStringFromTable(key, @"EZInterface", nil);
}

static NSArray<NSDictionary *> *EZAttachRows(void) {
    return @[
        @{ @"title": EZInterfaceString(@"Attach.Transcribe"),   @"subtitle": EZInterfaceString(@"Attach.TranscribeDetail"),         @"icon": @"waveform" },
        @{ @"title": EZInterfaceString(@"Attach.Analyze"),  @"subtitle": EZInterfaceString(@"Attach.AnalyzeDetail"),   @"icon": @"doc.text" },
        @{ @"title": EZInterfaceString(@"Attach.ImageFiles"),    @"subtitle": EZInterfaceString(@"Attach.ImageFilesDetail"),  @"icon": @"photo.on.rectangle" },
        @{ @"title": EZInterfaceString(@"Attach.PhotoLibrary"),  @"subtitle": EZInterfaceString(@"Attach.PhotoLibraryDetail"), @"icon": @"photo.stack" },
    ];
}

@implementation EZAttachMenuViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = EZInterfaceString(@"Attach.Title");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:EZInterfaceString(@"Common.Cancel")
                style:UIBarButtonItemStyleDone
               target:self action:@selector(_dismiss)];
    self.navigationController.navigationBar.tintColor = [EZUITheme accentSecondaryColor];
    self.view.backgroundColor = [EZUITheme backgroundColor];
    self.tableView.backgroundColor = [EZUITheme backgroundColor];
    self.tableView.separatorColor = [EZUITheme dividerColor];
}

- (void)_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)EZAttachRows().count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"AttachCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"AttachCell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.backgroundColor = [EZUITheme surfaceColor];
        cell.contentView.backgroundColor = [EZUITheme surfaceColor];
    }
    NSDictionary *row = EZAttachRows()[(NSUInteger)ip.row];
    cell.textLabel.text            = row[@"title"];
    cell.textLabel.font            = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.textLabel.textColor       = [EZUITheme primaryTextColor];
    cell.detailTextLabel.text      = row[@"subtitle"];
    cell.detailTextLabel.font      = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.textColor = [EZUITheme secondaryTextColor];
    cell.imageView.image           = [UIImage systemImageNamed:row[@"icon"]];
    cell.imageView.tintColor       = [EZUITheme accentSecondaryColor];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self dismissViewControllerAnimated:YES completion:^{
        switch (ip.row) {
            case 0: if (self.onWhisper)     self.onWhisper();     break;
            case 1: if (self.onAnalyze)     self.onAnalyze();     break;
            case 2: if (self.onImageFiles)  self.onImageFiles();  break;
            case 3: if (self.onPhotoLibrary) self.onPhotoLibrary(); break;
        }
    }];
}

@end
