//
//  EZModelPickerViewController.m
//  EZCompleteUI v1.2
//

#import "EZModelPickerViewController.h"

static NSString *EZLocalized(NSString *key) {
    return NSLocalizedString(key, nil);
}

static NSDictionary<NSString *, NSString *> *EZModelLabels(void) {
    return @{
        @"gpt-6-astra":            EZLocalized(@"EZModelLabel.ChatVisionNewest"),
        @"gpt-5.6-sol":            EZLocalized(@"EZModelLabel.ChatVision"),
        @"gpt-5.6-terra":          EZLocalized(@"EZModelLabel.ChatVisionBalanced"),
        @"gpt-5.6-luna":           EZLocalized(@"EZModelLabel.ChatVisionFastCheap"),
        @"gpt-5-pro":              EZLocalized(@"EZModelLabel.ChatVision"),
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
        @[@"gpt-6-astra", @"gpt-5.6-sol", @"gpt-5.6-terra", @"gpt-5.6-luna", @"gpt-5-pro", @"gpt-5", @"gpt-5-mini"],
        @[@"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4", @"gpt-3.5-turbo"],
        @[@"gpt-image-2.5-flare", @"gpt-image-2.5-sunburst", @"gpt-image-2", @"gpt-image-1.5", @"gpt-image-1", @"gpt-image-1-mini", @"chatgpt-image-latest"],
        @[@"whisper-1"],
    ];
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
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(_dismiss)];
}

- (void)_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
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
    cell.textLabel.font            = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.detailTextLabel.text      = EZModelLabels()[model] ?: @"";
    cell.detailTextLabel.font      = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType             = [model isEqualToString:self.selectedModel]
                                     ? UITableViewCellAccessoryCheckmark
                                     : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *model = EZModelSections()[(NSUInteger)ip.section][(NSUInteger)ip.row];
    self.selectedModel = model;
    [tv reloadData];
    if (self.onModelSelected) self.onModelSelected(model);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
