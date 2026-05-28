// SystemLogViewController.m
// EZCompleteUI

#import "SystemLogViewController.h"
#import "helpers.h"

@interface SystemLogViewController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation SystemLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"System Log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setupTextView];
    [self setupBarButtons];
    [self loadLog];
}

- (void)setupTextView {
    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.textView.alwaysBounceVertical = YES;
    [self.view addSubview:self.textView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
}

- (void)setupBarButtons {
    UIBarButtonItem *shareItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:self
                             action:@selector(shareLog)];
    UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(loadLog)];
    self.navigationItem.rightBarButtonItems = @[shareItem, refreshItem];
}

- (void)loadLog {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = EZLogGetPath();
        NSString *raw  = [NSString stringWithContentsOfFile:path
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
        if (!raw) raw = @"(System log unavailable)";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.textView.text = raw;
            [self scrollTextViewToBottom];
        });
    });
}

- (void)shareLog {
    NSString *path = EZLogGetPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showAlertWithTitle:@"Log Missing" message:@"System log file not found."];
        return;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    UIActivityViewController *ac = [[UIActivityViewController alloc]
        initWithActivityItems:@[fileURL] applicationActivities:nil];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)scrollTextViewToBottom {
    UITextView *tv = self.textView;
    if (!tv.text.length) return;
    NSRange bottom = NSMakeRange(tv.text.length - 1, 1);
    [tv scrollRangeToVisible:bottom];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
