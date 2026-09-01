//
//  EZModelPickerViewController.m
//  EZCompleteUI v1.1
//
//  Purpose: modal grouped-table sheet for choosing the active OpenAI model.
//  Presented from ViewController's showModelPicker; reports the choice back
//  via onModelSelected. The model list, section grouping, and human-readable
//  labels are all defined locally here (EZModelSections/EZModelLabels) —
//  NOT derived from the `models` array passed into initWithModels:. See the
//  note on the models property below before assuming that array does
//  anything.
//
// Changes from v1.0:
//   - EZModelLabels/EZModelSections: added gpt-5.6-sol, gpt-5.6-terra,
//     gpt-5.6-luna (new flagship family, replaces gpt-5.5) and gpt-image-2
//     (replaces gpt-image-1.5 as newest image model), placed above their
//     respective generation's existing entries.
//   - Moved the ⭐ "recommended" marker from gpt-4o to gpt-5.6-sol — gpt-4o
//     is three model generations behind now and shouldn't be the default
//     recommendation anymore. gpt-4o keeps its own label, just without the
//     star.
//   - NOTE (not fixed, flagging for a deliberate decision): `self.models`
//     is set in initWithModels: and then never read. EZModelSections() is
//     a separate hardcoded array that actually drives every table view
//     data source method. Practically this means the `models` array
//     ViewController builds and passes in here is currently decorative —
//     adding/removing a model in ViewController.m's self.models has NO
//     effect on this picker; EZModelSections()/EZModelLabels() must be
//     updated here too, by hand, every time (as done above). Whether to
//     collapse these into one source of truth (have this file build its
//     sections from the passed-in models array, with a separate
//     grouping/label map keyed by prefix) is a real refactor — didn't want
//     to make that call silently while just adding two model families.
//

#import "EZModelPickerViewController.h"

static NSDictionary<NSString *, NSString *> *EZModelLabels(void) {
    return @{
        @"gpt-5.6-sol":          @"💬 Chat + 👁 Vision ⭐",
        @"gpt-5.6-terra":        @"💬 Chat + 👁 Vision (balanced)",
        @"gpt-5.6-luna":         @"💬 Chat + 👁 Vision (fast/cheap)",
        @"gpt-5-pro":            @"💬 Chat + 👁 Vision",
        @"gpt-5":                @"💬 Chat + 👁 Vision",
        @"gpt-5-mini":           @"💬 Chat + 👁 Vision",
        @"gpt-4o":               @"💬 Chat + 👁 Vision",
        @"gpt-4o-mini":          @"💬 Chat + 👁 Vision (fast)",
        @"gpt-4-turbo":          @"💬 Chat + 👁 Vision",
        @"gpt-4":                @"💬 Chat + 👁 Vision",
        @"gpt-3.5-turbo":        @"💬 Chat only",
        @"gpt-image-2":          @"🖼 Image gen (newest)",
        @"gpt-image-1.5":        @"🖼 Image gen",
        @"gpt-image-1":          @"🖼 Image gen + ✏️ Edit",
        @"gpt-image-1-mini":     @"🖼 Image gen (fast/cheap)",
        @"chatgpt-image-latest": @"🖼 ChatGPT image (latest)",
        @"dall-e-3":             @"🖼 Image gen only (legacy)",
        @"sora-2":               @"🎬 Video gen (4/8/12/16s)",
        @"sora-2-pro":           @"🎬 Video gen HQ (5/10/15/20s)",
        @"whisper-1":            @"🎙 Audio transcription only",
    };
}

static NSArray<NSString *> *EZModelSectionTitles(void) {
    return @[@"GPT-5 Reasoning", @"GPT-4 Chat", @"Image Generation", @"Video", @"Audio"];
}

static NSArray<NSArray<NSString *> *> *EZModelSections(void) {
    return @[
        @[@"gpt-5.6-sol", @"gpt-5.6-terra", @"gpt-5.6-luna", @"gpt-5-pro", @"gpt-5", @"gpt-5-mini"],
        @[@"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4", @"gpt-3.5-turbo"],
        @[@"gpt-image-2", @"gpt-image-1.5", @"gpt-image-1", @"gpt-image-1-mini", @"chatgpt-image-latest", @"dall-e-3"],
        @[@"sora-2", @"sora-2-pro"],
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
    self.title = @"Select Model";
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
