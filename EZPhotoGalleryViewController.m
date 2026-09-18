//
//  EZPhotoGalleryViewController.m
//  EZCompleteUI
//
//  Dark, polished photo gallery. Reads images from /Documents/EZAttachments.
//  Pinch gesture cycles the grid between 2 – 5 columns.
//  Tap → full-screen detail sheet with action buttons.

#import "EZPhotoGalleryViewController.h"
#import "BrainRotViewController.h"
#import "EZAuthManager.h"
#import "EZSupabaseConfig.h"
#import "helpers.h"
#import <SafariServices/SafariServices.h>
#import <QuartzCore/QuartzCore.h>
#import <PhotosUI/PhotosUI.h>
#import <ImageIO/ImageIO.h>

// ── Notification names ────────────────────────────────────────────────────────

NSNotificationName const EZAttachImageToChat = @"EZAttachImageToChat";
NSNotificationName const EZEditImageInChat   = @"EZEditImageInChat";

// ── Constants ─────────────────────────────────────────────────────────────────

static NSString *const kGalleryCellID   = @"EZGalleryCell";
static NSString *const kAttachmentsDir  = @"EZAttachments";
static CGFloat   const kCellSpacing     = 3.0;
static NSInteger const kMinColumns      = 2;
static NSInteger const kMaxColumns      = 5;
static NSInteger const kDefaultColumns  = 3;
static NSString *const kGalleryImagePromptsKey = @"EZGalleryImagePrompts";

// ── Thumbnail cell ─────────────────────────────────────────────────────────────

@interface EZGalleryCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView  *imageView;
@property (nonatomic, strong) UIView       *selectionOverlay;
@property (nonatomic, strong) UIView       *shimmerView;
- (void)setImage:(UIImage * _Nullable)image;
- (void)startShimmer;
@end

@implementation EZGalleryCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];

        self.imageView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.imageView.contentMode      = UIViewContentModeScaleAspectFill;
        self.imageView.clipsToBounds    = YES;
        [self.contentView addSubview:self.imageView];

        // Subtle shimmer placeholder
        self.shimmerView = [[UIView alloc] initWithFrame:self.contentView.bounds];
        self.shimmerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.shimmerView.backgroundColor  = [UIColor colorWithWhite:0.18 alpha:1];
        self.shimmerView.hidden = YES;
        [self.contentView addSubview:self.shimmerView];

        // Selection highlight
        self.selectionOverlay = [[UIView alloc] initWithFrame:self.contentView.bounds];
        self.selectionOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.selectionOverlay.backgroundColor  = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.22];
        self.selectionOverlay.alpha = 0;
        [self.contentView addSubview:self.selectionOverlay];
    }
    return self;
}

- (void)setImage:(UIImage *)image {
    [self.shimmerView.layer removeAllAnimations];
    self.shimmerView.hidden = YES;
    self.imageView.alpha = 0;
    self.imageView.image = image;
    [UIView animateWithDuration:0.25 animations:^{ self.imageView.alpha = 1; }];
}

- (void)startShimmer {
    self.imageView.image    = nil;
    self.shimmerView.hidden = NO;
    [UIView animateWithDuration:0.9
                          delay:0
                        options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat
                     animations:^{ self.shimmerView.alpha = 0.4; }
                     completion:nil];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageView.image    = nil;
    self.shimmerView.hidden = YES;
    [self.shimmerView.layer removeAllAnimations];
    self.shimmerView.alpha  = 1;
    self.selectionOverlay.alpha = 0;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12 animations:^{
        self.selectionOverlay.alpha = highlighted ? 1 : 0;
        self.transform = highlighted ? CGAffineTransformMakeScale(0.96, 0.96) : CGAffineTransformIdentity;
    }];
}

@end

// ── Detail / preview view controller ─────────────────────────────────────────
// Presented as a sheet from within the gallery.

@interface EZPhotoDetailViewController : UIViewController
@property (nonatomic, strong) UIImage  *image;
@property (nonatomic, copy)   NSString *filePath;
@property (nonatomic, copy, nullable) NSString *imagePrompt;
@property (nonatomic, copy)   void (^onDeleted)(void);
@end

@interface EZPhotoDetailViewController () <UITextFieldDelegate, PHPickerViewControllerDelegate,
                                            UIContextMenuInteractionDelegate>
- (void)setupImageEditingControls;
- (void)layoutImageEditingControls;
- (void)layoutProcessingOverlay;
- (void)layoutImagePresentation;
- (void)keyboardWillChange:(NSNotification *)notification;
- (void)addEditImageTapped;
- (void)addPickedEditImage:(UIImage *)image;
- (UIImage *)compositeEditSourceImage;
- (void)updateImageEditStatus;
- (BOOL)shouldRetryLastImageEditFailure;
- (void)sendImageEditTapped;
- (NSData *)PNGDataForImage:(UIImage *)image;
- (void)setImageEditing:(BOOL)editing;
- (void)startProcessingAnimation;
- (void)stopProcessingAnimationWithCompletion:(void (^ _Nullable)(void))completion;
- (void)finishImageEditWithImage:(UIImage * _Nullable)editedImage
                            error:(NSString * _Nullable)errorMessage;
- (void)showImageEditError:(NSString *)message;
- (UIImage *)shareImageWithBranding;
- (UIImage *)shareImageWithBrandingForImage:(UIImage *)image showOriginalCard:(BOOL)showOriginalCard;
- (NSURL *)animatedShareGIFURL;
- (void)downloadTapped;
@end

@implementation EZPhotoDetailViewController {
    UIScrollView      *_scrollView;
    UIView             *_imageCanvas;
    UIImageView       *_imageView;
    UIImage           *_originalImageForShare;
    NSMutableArray<UIImageView *> *_imageGridViews;
    NSMutableArray<UIImage *> *_editSourceImages;
    NSMutableArray<NSString *> *_editSourcePaths;
    UIVisualEffectView *_toolbar;
    UIButton          *_askButton;
    UIButton          *_editButton;
    UIButton          *_useInGameButton;
    UIButton          *_shareButton;
    UIButton          *_downloadButton;
    UIButton          *_deleteButton;
    UILabel           *_filenameLabel;

    // EZPhotoAIEditorPatchInstalled
    UITextField       *_editPromptField;
    UIButton          *_addImageButton;
    UILabel           *_sourceCountLabel;
    UIButton          *_sendEditButton;
    UIView            *_processingOverlay;
    UIVisualEffectView *_processingBlurView;
    CAGradientLayer   *_waveGradientLayer;
    UIActivityIndicatorView *_editSpinner;
    UIActivityIndicatorView *_processingSpinner;
    UILabel           *_processingStatusLabel;
    UILabel           *_editErrorLabel;
    NSTimer           *_editStatusTimer;
    NSURLSessionDataTask *_imageEditTask;
    BOOL               _isEditingImage;
    BOOL               _hasEditedImage;
    BOOL               _isRetryingImageEdit;
    BOOL               _lastImageEditFailureWasTransient;
    NSInteger          _imageEditRetryCount;
    NSInteger          _imageEditStatusPhase;
    CGFloat            _keyboardOverlap;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0];

    _editSourceImages = [NSMutableArray arrayWithObject:self.image];
    _originalImageForShare = self.image;
    _editSourcePaths = [NSMutableArray array];
    if (self.filePath.length) [_editSourcePaths addObject:self.filePath];

    [self setupScrollView];
    [self setupToolbar];
    [self setupNavBar];
    [self setupImageEditingControls];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(keyboardWillChange:)
                   name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(keyboardWillChange:)
                   name:UIKeyboardWillHideNotification object:nil];
}

- (void)setupNavBar {
    UIBarButtonItem *dismissItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.down.circle.fill"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(dismiss)];
    dismissItem.tintColor = [UIColor colorWithWhite:0.6 alpha:1];

    _downloadButton = [self makeIconButton:@"arrow.down.to.line"
                                     color:[UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0]];
    _downloadButton.frame = CGRectMake(0, 0, 36, 36);
    [_downloadButton addTarget:self action:@selector(downloadTapped)
              forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.leftBarButtonItems = @[
        dismissItem,
        [[UIBarButtonItem alloc] initWithCustomView:_downloadButton]
    ];

    _shareButton = [self makeIconButton:@"square.and.arrow.up" color:[UIColor colorWithWhite:0.75 alpha:1]];
    _shareButton.frame = CGRectMake(0, 0, 36, 36);
    [_shareButton addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [_shareButton addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
    _deleteButton = [self makeIconButton:@"trash" color:[UIColor systemRedColor]];
    _deleteButton.frame = CGRectMake(0, 0, 36, 36);
    [_deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithCustomView:_deleteButton],
        [[UIBarButtonItem alloc] initWithCustomView:_shareButton]
    ];

    // Attachment filenames are implementation details and are often UUIDs.
    self.title = @"";
}

- (void)setupScrollView {
    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.backgroundColor  = [UIColor clearColor];
    _scrollView.minimumZoomScale = 1.0;
    _scrollView.maximumZoomScale = 5.0;
    _scrollView.showsVerticalScrollIndicator   = NO;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.delegate = (id<UIScrollViewDelegate>)self;
    [self.view addSubview:_scrollView];

    _imageCanvas = [[UIView alloc] init];
    _imageCanvas.clipsToBounds = YES;
    [_scrollView addSubview:_imageCanvas];

    _imageView = [[UIImageView alloc] initWithImage:self.image];
    _imageView.contentMode   = UIViewContentModeScaleAspectFit;
    _imageView.clipsToBounds = NO;
    [_imageCanvas addSubview:_imageView];
    _imageGridViews = [NSMutableArray arrayWithObject:_imageView];

    // Double-tap to zoom
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [_scrollView addGestureRecognizer:doubleTap];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _imageCanvas;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    [self centerImageView];
}

- (void)centerImageView {
    CGSize  boundsSize  = _scrollView.bounds.size;
    CGRect  frameToCenter = _imageCanvas.frame;
    frameToCenter.origin.x = frameToCenter.size.width < boundsSize.width
        ? (boundsSize.width - frameToCenter.size.width) / 2 : 0;
    frameToCenter.origin.y = frameToCenter.size.height < boundsSize.height
        ? (boundsSize.height - frameToCenter.size.height) / 2 : 0;
    _imageCanvas.frame = frameToCenter;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    if (_scrollView.zoomScale > 1.0) {
        [_scrollView setZoomScale:1.0 animated:YES];
    } else {
    CGPoint  pt   = [tap locationInView:_imageCanvas];
        CGRect   rect = CGRectMake(pt.x - 60, pt.y - 60, 120, 120);
        [_scrollView zoomToRect:rect animated:YES];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat toolbarH = 184 + self.view.safeAreaInsets.bottom;
    CGFloat availableHeight = self.view.bounds.size.height - _keyboardOverlap;
    CGFloat imageAreaH = MAX(0.0, availableHeight - toolbarH);

    _scrollView.frame = CGRectMake(0, 0, self.view.bounds.size.width, imageAreaH);

    [self layoutImagePresentation];

    _toolbar.frame = CGRectMake(0, availableHeight - toolbarH,
                                self.view.bounds.size.width, toolbarH);
    [self layoutToolbarButtons];
    [self layoutImageEditingControls];
    [self layoutProcessingOverlay];
}

// A single reference keeps the familiar aspect-fit preview.  Two or three
// references become an equal-sized grid, giving each input the same visual
// weight before the edit is sent.
- (void)layoutImagePresentation {
    NSUInteger count = _editSourceImages.count;
    if (count == 0) return;

    CGFloat width = CGRectGetWidth(_scrollView.bounds);
    CGFloat height = CGRectGetHeight(_scrollView.bounds);
    if (count == 1) {
        CGSize imageSize = _editSourceImages.firstObject.size;
        if (imageSize.width <= 0 || imageSize.height <= 0) return;
        CGFloat scale = MIN(width / imageSize.width, height / imageSize.height);
        _imageCanvas.frame = CGRectMake(0, 0, imageSize.width * scale, imageSize.height * scale);
        _imageGridViews.firstObject.frame = _imageCanvas.bounds;
        _imageGridViews.firstObject.contentMode = UIViewContentModeScaleAspectFit;
    } else {
        _imageCanvas.frame = CGRectMake(0, 0, width, height);
        NSUInteger columns = 2;
        CGFloat gap = 4.0;
        CGFloat tileWidth = (width - gap) / columns;
        CGFloat tileHeight = (height - gap) / 2.0;
        for (NSUInteger index = 0; index < _imageGridViews.count; index++) {
            NSUInteger row = index / columns;
            NSUInteger column = index % columns;
            UIImageView *imageView = _imageGridViews[index];
            imageView.frame = CGRectMake(column * (tileWidth + gap), row * (tileHeight + gap),
                                         tileWidth, tileHeight);
            imageView.contentMode = UIViewContentModeScaleAspectFill;
            imageView.clipsToBounds = YES;
        }
    }
    _scrollView.contentSize = _imageCanvas.bounds.size;
    [self centerImageView];
}

// Keep the entire edit bar, including its text field, directly above the
// keyboard.  The intersection calculation also handles rotation and avoids
// moving the bar for a detached/floating keyboard that does not cover it.
- (void)keyboardWillChange:(NSNotification *)notification {
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardInView = [self.view convertRect:keyboardFrame fromView:nil];
    CGRect coveredArea = CGRectIntersection(self.view.bounds, keyboardInView);
    BOOL keyboardTouchesBottom = !CGRectIsNull(coveredArea) &&
        CGRectGetMaxY(coveredArea) >= CGRectGetMaxY(self.view.bounds) - 0.5;
    _keyboardOverlap = keyboardTouchesBottom ? CGRectGetHeight(coveredArea) : 0.0;

    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions curve =
        [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
    [UIView animateWithDuration:duration
                          delay:0
                        options:curve | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)setupToolbar {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _toolbar = [[UIVisualEffectView alloc] initWithEffect:blur];
    _toolbar.clipsToBounds = YES;

    // Top separator line
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 9999, 0.5)];
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_toolbar.contentView addSubview:line];

    // Ask button — gold, prominent
    _askButton = [self makeButtonTitle:NSLocalizedString(@"EZGallery.AskQuestion", nil)
                                  icon:@"bubble.left.and.bubble.right.fill"
                           accentColor:[UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]
                                  dark:YES];
    [_askButton addTarget:self action:@selector(askTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_askButton];

    // Edit button — blue
    _editButton = [self makeButtonTitle:NSLocalizedString(@"EZGallery.EditWithAI", nil)
                                   icon:@"wand.and.stars"
                            accentColor:[UIColor systemBlueColor]
                                   dark:NO];
    [_editButton addTarget:self action:@selector(editTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_editButton];

    _useInGameButton = [self makeButtonTitle:NSLocalizedString(@"EZGallery.UseInVideoGame", nil)
                                         icon:@"gamecontroller.fill"
                                  accentColor:[UIColor systemPurpleColor]
                                         dark:NO];
    [_useInGameButton addTarget:self action:@selector(useInVideoGameTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_useInGameButton];

    [self.view addSubview:_toolbar];

    [self layoutToolbarButtons];
}

- (void)layoutToolbarButtons {
    CGFloat pad  = 16;
    CGFloat btnH = 56;
    CGFloat y    = 88;
    CGFloat W    = self.view.bounds.size.width;
    if (W == 0) W = UIScreen.mainScreen.bounds.size.width;

    CGFloat buttonW = (W - pad * 2 - 16) / 3.0;
    _askButton.frame       = CGRectMake(pad, y, buttonW, btnH);
    _editButton.frame      = CGRectMake(pad + buttonW + 8, y, buttonW, btnH);
    _useInGameButton.frame = CGRectMake(pad + (buttonW + 8) * 2, y, buttonW, btnH);
}

#pragma mark - AI Image Editing

- (void)setupImageEditingControls {
    UIView *promptContainer = [[UIView alloc] init];
    promptContainer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    promptContainer.layer.cornerRadius = 18.0;
    promptContainer.layer.borderWidth = 1.0;
    promptContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.11].CGColor;
    promptContainer.clipsToBounds = YES;
    [_toolbar.contentView addSubview:promptContainer];

    _editPromptField = [[UITextField alloc] init];
    _editPromptField.placeholder = NSLocalizedString(@"EZGallery.EditPromptPlaceholder", nil);
    _editPromptField.textColor = [UIColor whiteColor];
    _editPromptField.tintColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _editPromptField.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _editPromptField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _editPromptField.returnKeyType = UIReturnKeySend;
    _editPromptField.enablesReturnKeyAutomatically = YES;
    _editPromptField.delegate = (id<UITextFieldDelegate>)self;
    _editPromptField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:NSLocalizedString(@"EZGallery.EditPromptPlaceholder", nil)
            attributes:@{
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.72 alpha:0.70]
            }];
    [promptContainer addSubview:_editPromptField];

    _addImageButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _addImageButton.tintColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _addImageButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _addImageButton.layer.cornerRadius = 18.0;
    UIImageSymbolConfiguration *addConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
    [_addImageButton setImage:[UIImage systemImageNamed:@"plus" withConfiguration:addConfig]
                       forState:UIControlStateNormal];
    [_addImageButton addTarget:self action:@selector(addEditImageTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [promptContainer addSubview:_addImageButton];

    _sourceCountLabel = [[UILabel alloc] init];
    _sourceCountLabel.backgroundColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _sourceCountLabel.textColor = [UIColor colorWithRed:0.03 green:0.05 blue:0.10 alpha:1.0];
    _sourceCountLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    _sourceCountLabel.textAlignment = NSTextAlignmentCenter;
    _sourceCountLabel.layer.cornerRadius = 8.0;
    _sourceCountLabel.clipsToBounds = YES;
    _sourceCountLabel.hidden = YES;
    [promptContainer addSubview:_sourceCountLabel];

    _sendEditButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _sendEditButton.backgroundColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _sendEditButton.tintColor = [UIColor colorWithRed:0.03 green:0.05 blue:0.10 alpha:1.0];
    _sendEditButton.layer.cornerRadius = 28.0;
    _sendEditButton.layer.shadowColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0].CGColor;
    _sendEditButton.layer.shadowOpacity = 0.30;
    _sendEditButton.layer.shadowRadius = 10.0;
    _sendEditButton.layer.shadowOffset = CGSizeMake(0, 4);
    UIImageSymbolConfiguration *symbolConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
    UIImage *sendImage = [UIImage systemImageNamed:@"arrow.up"
                                 withConfiguration:symbolConfig];
    [_sendEditButton setImage:sendImage forState:UIControlStateNormal];
    [_sendEditButton addTarget:self
                        action:@selector(sendImageEditTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_sendEditButton];

    _editSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _editSpinner.color = [UIColor colorWithRed:0.03 green:0.05 blue:0.10 alpha:1.0];
    _editSpinner.hidesWhenStopped = YES;
    [_sendEditButton addSubview:_editSpinner];

    _editErrorLabel = [[UILabel alloc] init];
    _editErrorLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _editErrorLabel.textColor = [UIColor systemOrangeColor];
    _editErrorLabel.textAlignment = NSTextAlignmentCenter;
    _editErrorLabel.numberOfLines = 1;
    _editErrorLabel.hidden = YES;
    [_toolbar.contentView addSubview:_editErrorLabel];
}

- (void)layoutImageEditingControls {
    if (!_editPromptField || !_sendEditButton) return;

    CGFloat pad = 16.0;
    CGFloat y = 14.0;
    CGFloat fieldHeight = 56.0;
    CGFloat sendSize = 56.0;
    CGFloat width = _toolbar.contentView.bounds.size.width;
    if (width <= 0) width = self.view.bounds.size.width;

    _sendEditButton.frame = CGRectMake(width - pad - sendSize, y, sendSize, sendSize);
    _editSpinner.center = CGPointMake(CGRectGetMidX(_sendEditButton.bounds),
                                      CGRectGetMidY(_sendEditButton.bounds));

    UIView *promptContainer = _editPromptField.superview;
    promptContainer.frame = CGRectMake(pad, y, width - (pad * 2.0) - sendSize - 10.0, fieldHeight);
    _addImageButton.frame = CGRectMake(8.0, 10.0, 36.0, 36.0);
    _sourceCountLabel.frame = CGRectMake(33.0, 5.0, 16.0, 16.0);
    _sourceCountLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)_editSourceImages.count];
    _sourceCountLabel.hidden = _editSourceImages.count < 2;
    _addImageButton.alpha = _editSourceImages.count >= 3 ? 0.40 : 1.0;
    _editPromptField.frame = CGRectMake(54.0, 0.0,
                                        MAX(0.0, CGRectGetWidth(promptContainer.bounds) - 70.0),
                                        CGRectGetHeight(promptContainer.bounds));
    _editErrorLabel.frame = CGRectMake(pad, 72.0, width - pad * 2.0, 14.0);
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self sendImageEditTapped];
    return NO;
}

- (void)addEditImageTapped {
    if (_isEditingImage || _editSourceImages.count >= 3) return;

    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = [PHPickerFilter imagesFilter];
    configuration.selectionLimit = 3 - _editSourceImages.count;
    PHPickerViewController *picker = [[PHPickerViewController alloc]
        initWithConfiguration:configuration];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    for (PHPickerResult *result in results) {
        if (![result.itemProvider canLoadObjectOfClass:[UIImage class]]) continue;
        [result.itemProvider loadObjectOfClass:[UIImage class]
                           completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
            UIImage *image = [object isKindOfClass:[UIImage class]] ? object : nil;
            if (!image || error) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self addPickedEditImage:image];
            });
        }];
    }
}

- (void)addPickedEditImage:(UIImage *)image {
    if (!image || _isEditingImage || _editSourceImages.count >= 3) return;
    [_editSourceImages addObject:image];
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    imageView.clipsToBounds = YES;
    [_imageCanvas addSubview:imageView];
    [_imageGridViews addObject:imageView];

    [_scrollView setZoomScale:1.0 animated:NO];
    [UIView transitionWithView:_imageCanvas duration:0.28
                       options:UIViewAnimationOptionTransitionCrossDissolve |
                               UIViewAnimationOptionCurveEaseInOut
                    animations:^{
        [self layoutImagePresentation];
        [self layoutImageEditingControls];
    }
                    completion:nil];
}

- (void)editTapped {
    [_editPromptField becomeFirstResponder];
    [UIView animateWithDuration:0.20 animations:^{
        _editPromptField.superview.transform = CGAffineTransformMakeScale(1.02, 1.02);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.18 animations:^{
            _editPromptField.superview.transform = CGAffineTransformIdentity;
        }];
    }];
}

- (void)sendImageEditTapped {
    if (_isEditingImage && !_isRetryingImageEdit) return;

    NSString *prompt = [_editPromptField.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (prompt.length == 0) {
        [self showImageEditError:@"Please describe the change you want to make."];
        [_editPromptField becomeFirstResponder];
        return;
    }

    _editErrorLabel.hidden = YES;
    if (!_isRetryingImageEdit) {
        _imageEditRetryCount = 0;
        _lastImageEditFailureWasTransient = NO;
    }
    _isRetryingImageEdit = NO;

    NSString *accessToken = [EZAuthManager shared].accessToken;
    if (accessToken.length == 0) {
        [self showImageEditError:@"Please sign in before editing an image."];
        return;
    }

    NSMutableArray<NSString *> *imagePayloads = [NSMutableArray array];
    for (UIImage *sourceImage in _editSourceImages) {
        NSData *imageData = [self PNGDataForImage:sourceImage];
        if (imageData.length > 0) {
            [imagePayloads addObject:[imageData base64EncodedStringWithOptions:0]];
        }
    }
    if (imagePayloads.count == 0) {
        [self showImageEditError:@"The selected photo could not be prepared for editing."];
        return;
    }

    [_editPromptField resignFirstResponder];
    [self setImageEditing:YES];
    [self startProcessingAnimation];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Gallery edits use the precision image-editing model regardless of the
    // chat screen's active model.
    NSString *model = @"gpt-image-2.5-sunburst";

    NSInteger variationCount = [defaults integerForKey:@"imgVariations"];
    if (variationCount < 1 || variationCount > 4) variationCount = 1;
    NSString *size = [defaults stringForKey:@"imgSize"] ?: @"1024x1024";
    NSString *quality = [defaults stringForKey:@"imgQuality"] ?: @"auto";
    NSString *format = [defaults stringForKey:@"imgFormat"] ?: @"png";
    NSString *background = [defaults stringForKey:@"imgBackground"] ?: @"auto";
    NSString *moderation = [defaults stringForKey:@"imgModeration"] ?: @"low";
    // Older deployments of ez-image accept a single `image_b64` value. Send a
    // labelled-free composite there so every selected reference is still seen,
    // while newer deployments can use the individual source array directly.
    UIImage *compatibilityImage = [self compositeEditSourceImage];
    NSData *compatibilityData = [self PNGDataForImage:compatibilityImage];
    NSString *compatibilityPayload = compatibilityData.length
        ? [compatibilityData base64EncodedStringWithOptions:0] : imagePayloads.firstObject;
    NSDictionary *body = @{
        @"action": @"edit", @"model": model, @"prompt": prompt,
        @"image_b64": compatibilityPayload, @"images_b64": imagePayloads,
        @"n": @(variationCount), @"size": size, @"quality": quality,
        @"output_format": format, @"background": background, @"moderation": moderation,
    };
    NSError *encodingError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodingError];
    if (!bodyData) {
        [self finishImageEditWithImage:nil error:encodingError.localizedDescription ?: @"Could not prepare the image edit."];
        return;
    }

    NSURL *endpoint = [NSURL URLWithString:[NSString stringWithFormat:
        @"%@/functions/v1/ez-image", EZSupabaseURL]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 330.0;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", accessToken]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = bodyData;

    __weak typeof(self) weakSelf = self;
    _imageEditTask = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *failureMessage = nil;
        UIImage *editedImage = nil;
        BOOL transientFailure = NO;
        if (error) {
            failureMessage = error.localizedDescription;
            transientFailure = error.code == NSURLErrorTimedOut ||
                error.code == NSURLErrorNetworkConnectionLost ||
                error.code == NSURLErrorNotConnectedToInternet ||
                error.code == NSURLErrorCannotConnectToHost;
        } else {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            transientFailure = statusCode == 408 || statusCode == 429 || statusCode >= 500;
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                                  options:0 error:&jsonError];
            id errorValue = json[@"error"];
            NSString *reason = [json[@"reason"] isKindOfClass:[NSString class]] ? json[@"reason"] : nil;
            if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
                failureMessage = @"The image-edit service returned an invalid response.";
            } else if (errorValue && errorValue != [NSNull null]) {
                NSString *errorText = [errorValue isKindOfClass:[NSString class]] ? errorValue : @"Image edit failed.";
                failureMessage = reason.length ? [NSString stringWithFormat:@"%@ %@", errorText, reason] : errorText;
            } else {
                NSDictionary *firstImage = [json[@"images"] firstObject];
                NSString *signedURL = [firstImage[@"url"] isKindOfClass:[NSString class]] ? firstImage[@"url"] : nil;
                NSData *editedData = signedURL.length ? [NSData dataWithContentsOfURL:[NSURL URLWithString:signedURL]] : nil;
                editedImage = [UIImage imageWithData:editedData];
                if (!editedImage) failureMessage = @"The image-edit service did not return a usable image.";
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self->_imageEditTask = nil;
            self->_lastImageEditFailureWasTransient = transientFailure;
            [self finishImageEditWithImage:editedImage error:failureMessage];
        });
    }];
    [_imageEditTask resume];
}

- (NSData *)PNGDataForImage:(UIImage *)image {
    if (!image) return nil;

    CGFloat maximumDimension = 2048.0;
    CGSize sourceSize = image.size;
    CGFloat largestSide = MAX(sourceSize.width, sourceSize.height);
    UIImage *prepared = image;

    if (largestSide > maximumDimension) {
        CGFloat scale = maximumDimension / largestSide;
        CGSize targetSize = CGSizeMake(floor(sourceSize.width * scale),
                                       floor(sourceSize.height * scale));
        UIGraphicsBeginImageContextWithOptions(targetSize, NO, 1.0);
        [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
        prepared = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }

    return UIImagePNGRepresentation(prepared);
}

// A single-image edit endpoint can still receive all references as a 2×2
// contact sheet.  Each source is aspect-fit (never cropped), so the model can
// use every attachment even when it does not yet understand `images_b64`.
- (UIImage *)compositeEditSourceImage {
    if (_editSourceImages.count <= 1) return _editSourceImages.firstObject;

    CGFloat side = 2048.0;
    CGFloat gap = 12.0;
    CGFloat tileSide = (side - gap * 3.0) / 2.0;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), YES, 1.0);
    [[UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1] setFill];
    UIRectFill(CGRectMake(0, 0, side, side));
    for (NSUInteger index = 0; index < _editSourceImages.count; index++) {
        UIImage *image = _editSourceImages[index];
        if (image.size.width <= 0 || image.size.height <= 0) continue;
        NSUInteger row = index / 2;
        NSUInteger column = index % 2;
        CGRect tile = CGRectMake(gap + column * (tileSide + gap),
                                 gap + row * (tileSide + gap), tileSide, tileSide);
        CGFloat scale = MIN(tile.size.width / image.size.width, tile.size.height / image.size.height);
        CGSize fittedSize = CGSizeMake(image.size.width * scale, image.size.height * scale);
        CGRect drawRect = CGRectMake(CGRectGetMidX(tile) - fittedSize.width / 2.0,
                                     CGRectGetMidY(tile) - fittedSize.height / 2.0,
                                     fittedSize.width, fittedSize.height);
        [image drawInRect:drawRect];
    }
    UIImage *composite = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return composite;
}

- (void)setImageEditing:(BOOL)editing {
    _isEditingImage = editing;
    _editPromptField.enabled = !editing;
    _addImageButton.enabled = !editing && _editSourceImages.count < 3;
    _sendEditButton.enabled = !editing;
    _askButton.enabled = !editing;
    _editButton.enabled = !editing;
    _useInGameButton.enabled = !editing;
    _shareButton.enabled = !editing;
    _downloadButton.enabled = !editing;
    _deleteButton.enabled = !editing;
    _sendEditButton.alpha = editing ? 0.92 : 1.0;

    if (editing) {
        [_sendEditButton setImage:nil forState:UIControlStateNormal];
        [_editSpinner startAnimating];
    } else {
        [_editSpinner stopAnimating];
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
        [_sendEditButton setImage:[UIImage systemImageNamed:@"arrow.up"
                                          withConfiguration:config]
                          forState:UIControlStateNormal];
    }
}

- (void)startProcessingAnimation {
    if (_processingOverlay) return;

    _processingOverlay = [[UIView alloc] initWithFrame:_imageCanvas.bounds];
    _processingOverlay.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _processingOverlay.userInteractionEnabled = NO;
    _processingOverlay.clipsToBounds = YES;
    _processingOverlay.backgroundColor = [UIColor colorWithRed:0.03 green:0.10 blue:0.18 alpha:0.12];
    [_imageCanvas addSubview:_processingOverlay];

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _processingBlurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    _processingBlurView.frame = _processingOverlay.bounds;
    _processingBlurView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _processingBlurView.alpha = 0.0;
    [_processingOverlay addSubview:_processingBlurView];

    _processingSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _processingSpinner.color = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _processingSpinner.transform = CGAffineTransformMakeScale(1.7, 1.7);
    [_processingOverlay addSubview:_processingSpinner];

    _processingStatusLabel = [[UILabel alloc] init];
    _processingStatusLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _processingStatusLabel.textColor = [UIColor whiteColor];
    _processingStatusLabel.textAlignment = NSTextAlignmentCenter;
    _processingStatusLabel.numberOfLines = 2;
    [_processingOverlay addSubview:_processingStatusLabel];
    [self layoutProcessingOverlay];
    _imageEditStatusPhase = 0;
    [_processingSpinner startAnimating];
    [self updateImageEditStatus];
    _editStatusTimer = [NSTimer scheduledTimerWithTimeInterval:4.0
                                                          target:self
                                                        selector:@selector(updateImageEditStatus)
                                                        userInfo:nil
                                                         repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_editStatusTimer forMode:NSRunLoopCommonModes];

    _waveGradientLayer = [CAGradientLayer layer];
    _waveGradientLayer.frame = CGRectInset(_processingOverlay.bounds,
                                           -_processingOverlay.bounds.size.width, 0);
    _waveGradientLayer.startPoint = CGPointMake(0.0, 0.5);
    _waveGradientLayer.endPoint = CGPointMake(1.0, 0.5);
    _waveGradientLayer.colors = @[
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor colorWithRed:0.00 green:0.95 blue:0.74 alpha:0.06].CGColor,
        (id)[UIColor colorWithRed:0.20 green:0.45 blue:1.00 alpha:0.34].CGColor,
        (id)[UIColor colorWithRed:0.00 green:0.95 blue:0.74 alpha:0.06].CGColor,
        (id)[UIColor clearColor].CGColor
    ];
    _waveGradientLayer.locations = @[@0.0, @0.30, @0.50, @0.70, @1.0];
    _waveGradientLayer.compositingFilter = @"screenBlendMode";
    [_processingOverlay.layer addSublayer:_waveGradientLayer];

    CABasicAnimation *wave = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    wave.fromValue = @(-_processingOverlay.bounds.size.width);
    wave.toValue = @(_processingOverlay.bounds.size.width);
    wave.duration = 1.65;
    wave.repeatCount = HUGE_VALF;
    wave.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_waveGradientLayer addAnimation:wave forKey:@"ez.ai.wave"];

    [UIView animateWithDuration:0.45 animations:^{
        self->_processingBlurView.alpha = 0.90;
        self->_imageCanvas.transform = CGAffineTransformMakeScale(1.025, 1.025);
    }];

    [UIView animateWithDuration:1.05
                          delay:0.45
                        options:UIViewAnimationOptionAutoreverse |
                                UIViewAnimationOptionRepeat |
                                UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self->_imageCanvas.transform = CGAffineTransformMakeScale(1.055, 1.055);
        self->_processingOverlay.alpha = 0.78;
    } completion:nil];
}

- (void)layoutProcessingOverlay {
    if (!_processingOverlay) return;
    _processingOverlay.frame = _imageCanvas.bounds;
    _processingBlurView.frame = _processingOverlay.bounds;
    _waveGradientLayer.frame = CGRectInset(_processingOverlay.bounds,
                                           -_processingOverlay.bounds.size.width, 0);
    _processingSpinner.center = CGPointMake(CGRectGetMidX(_processingOverlay.bounds),
                                            CGRectGetMidY(_processingOverlay.bounds) - 18.0);
    _processingStatusLabel.frame = CGRectMake(24.0, CGRectGetMidY(_processingOverlay.bounds) + 24.0,
                                              MAX(0.0, CGRectGetWidth(_processingOverlay.bounds) - 48.0), 48.0);
}

- (void)updateImageEditStatus {
    NSArray<NSString *> *messages = @[
        @"Preparing your image edit…",
        @"Applying your requested changes…",
        @"Still working. Almost done.",
        @"Finishing the image…"
    ];
    _processingStatusLabel.text = messages[_imageEditStatusPhase % messages.count];
    _imageEditStatusPhase++;
}

- (BOOL)shouldRetryLastImageEditFailure {
    return _lastImageEditFailureWasTransient && _imageEditRetryCount < 2;
}

- (void)stopProcessingAnimationWithCompletion:(void (^)(void))completion {
    [_editStatusTimer invalidate];
    _editStatusTimer = nil;
    [_processingSpinner stopAnimating];
    [_processingOverlay.layer removeAllAnimations];
    [_waveGradientLayer removeAllAnimations];

    [UIView animateWithDuration:0.34 animations:^{
        self->_processingOverlay.alpha = 0.0;
        self->_imageCanvas.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [self->_processingOverlay removeFromSuperview];
        self->_processingOverlay = nil;
        self->_processingBlurView = nil;
        self->_waveGradientLayer = nil;
        self->_processingSpinner = nil;
        self->_processingStatusLabel = nil;
        if (completion) completion();
    }];
}

- (void)finishImageEditWithImage:(UIImage *)editedImage error:(NSString *)errorMessage {
    if (errorMessage.length > 0 && [self shouldRetryLastImageEditFailure]) {
        _imageEditRetryCount++;
        _processingStatusLabel.text = [NSString stringWithFormat:
            @"Connection interrupted — retrying (%ld of 2)…", (long)_imageEditRetryCount];
        EZLogf(EZLogLevelWarning, @"IMGEDIT", @"Transient gallery edit failure; retry %ld: %@",
               (long)_imageEditRetryCount, errorMessage);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.viewIfLoaded.window || !self->_isEditingImage) return;
            self->_isRetryingImageEdit = YES;
            [self sendImageEditTapped];
        });
        return;
    }

    [self setImageEditing:NO];

    if (errorMessage.length > 0 || !editedImage) {
        [self stopProcessingAnimationWithCompletion:nil];
        [self showImageEditError:errorMessage ?: @"The image edit did not return an image."];
        return;
    }

    [self stopProcessingAnimationWithCompletion:^{
        // Never replace the selected attachment.  A gallery edit is a new
        // asset, so the source remains recoverable even if the user deletes
        // the result later.
        NSData *savedData = [self PNGDataForImage:editedImage];
        NSString *newFilePath = savedData.length
            ? EZAttachmentSave(savedData, @"gallery_edit.png") : nil;
        if (!newFilePath.length) {
            [self showImageEditError:@"The edit completed, but could not be saved as a new gallery image."];
            return;
        }

        self.image = editedImage;
        self->_hasEditedImage = YES;
        self.filePath = newFilePath;
        [_editSourcePaths removeAllObjects];
        [_editSourcePaths addObject:newFilePath];
        [_editSourceImages removeAllObjects];
        [_editSourceImages addObject:editedImage];
        while (_imageGridViews.count > 1) {
            UIImageView *extraView = _imageGridViews.lastObject;
            [extraView removeFromSuperview];
            [_imageGridViews removeLastObject];
        }
        [UIView transitionWithView:self->_imageCanvas
                          duration:0.42
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionCurveEaseInOut
                        animations:^{
            self->_imageView.image = editedImage;
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
        } completion:nil];

        NSMutableDictionary *prompts = [[[NSUserDefaults standardUserDefaults]
            dictionaryForKey:kGalleryImagePromptsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
        prompts[newFilePath] = self->_editPromptField.text ?: @"";
        [[NSUserDefaults standardUserDefaults] setObject:prompts forKey:kGalleryImagePromptsKey];
        self.imagePrompt = self->_editPromptField.text;

        // Gallery edits bypass the chat controller, so save their one memory
        // entry here after the edited asset has been written successfully.
        NSString *prompt = [self->_editPromptField.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *token = [EZAuthManager shared].accessToken;
        if (prompt.length > 0 && token.length > 0) {
            NSString *answer = [NSString stringWithFormat:@"Edited a gallery image per: %@", prompt];
            NSArray<NSString *> *attachments = self.filePath.length ? @[self.filePath] : @[];
            createMemoryFromCompletion(prompt, answer, token, nil, attachments,
            ^(NSString *entry) {
                if (entry) EZLog(EZLogLevelInfo, @"MEMORY", @"Saved gallery image-edit memory");
            });
        }
    }];
}

- (void)showImageEditError:(NSString *)message {
    _editErrorLabel.text = message.length ? message : @"Image edit could not be completed.";
    _editErrorLabel.hidden = NO;
    EZLogf(EZLogLevelWarning, @"IMGEDIT", @"Gallery edit failed: %@", _editErrorLabel.text);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [_imageEditTask cancel];
        _imageEditTask = nil;
        [_editStatusTimer invalidate];
        _editStatusTimer = nil;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIButton *)makeButtonTitle:(NSString *)title icon:(NSString *)iconName
                   accentColor:(UIColor *)color dark:(BOOL)dark {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.backgroundColor    = dark ? color : [color colorWithAlphaComponent:0.18];
    btn.layer.cornerRadius = 14;
    btn.layer.masksToBounds = YES;
    btn.tintColor          = dark ? [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1] : color;

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14
                                                                                         weight:UIImageSymbolWeightSemibold];
    UIImage *icon = [UIImage systemImageNamed:iconName withConfiguration:config];

    if (@available(iOS 15, *)) {
        UIButtonConfiguration *bc = [UIButtonConfiguration filledButtonConfiguration];
        bc.title             = title;
        bc.image             = icon;
        bc.imagePadding      = 6;
        bc.imagePlacement    = NSDirectionalRectEdgeLeading;
        bc.contentInsets     = NSDirectionalEdgeInsetsMake(0, 14, 0, 14);
        bc.titleTextAttributesTransformer =
            ^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attrs) {
                NSMutableDictionary *m = [attrs mutableCopy];
                m[NSFontAttributeName] = [UIFont boldSystemFontOfSize:13];
                return m;
            };
        bc.background.backgroundColor = btn.backgroundColor;
        btn.configuration = bc;
        btn.tintColor = dark ? [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1] : color;
    } else {
        [btn setTitle:[@"  " stringByAppendingString:title] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [btn setTitleColor:dark ? [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1] : color
                  forState:UIControlStateNormal];
    }
    return btn;
}

- (UIButton *)makeIconButton:(NSString *)iconName color:(UIColor *)color {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.backgroundColor    = [UIColor colorWithWhite:1 alpha:0.07];
    btn.layer.cornerRadius = 14;
    btn.tintColor          = color;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18
                                                                                       weight:UIImageSymbolWeightMedium];
    [btn setImage:[UIImage systemImageNamed:iconName withConfiguration:cfg] forState:UIControlStateNormal];
    return btn;
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)askTapped {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EZAttachImageToChat
                      object:nil
                    userInfo:@{ @"image": self.image }];
    [self dismissAllTheWay];
}

- (void)useInVideoGameTapped {
    UIViewController *presenter = self.navigationController.presentingViewController;
    if (!presenter) return;

    UIImage *selectedImage = self.image;
    [presenter dismissViewControllerAnimated:YES completion:^{
        BrainRotViewController *brainRot = [[BrainRotViewController alloc] init];
        brainRot.initialWorkshopImage = selectedImage;
        UINavigationController *gameNavigation =
            [[UINavigationController alloc] initWithRootViewController:brainRot];
        gameNavigation.modalPresentationStyle = UIModalPresentationPageSheet;
        [presenter presentViewController:gameNavigation animated:YES completion:nil];
    }];
}

- (void)shareTapped {
    NSURL *animatedGIFURL = [self animatedShareGIFURL];
    id exportItem = animatedGIFURL ?: ([self shareImageWithBranding] ?: self.image);
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[exportItem] applicationActivities:nil];
    share.popoverPresentationController.sourceView = _shareButton;
    [self presentViewController:share animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                         configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                    previewProvider:nil
                                                     actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *save = [UIAction actionWithTitle:@"Save to Photos"
                                              image:[UIImage systemImageNamed:@"arrow.down.to.line"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *action) {
            [self downloadTapped];
        }];
        return [UIMenu menuWithTitle:@"" children:@[save]];
    }];
}

// Builds a lightweight, looping before/after GIF for edited images.  It uses
// a capped canvas so opening the share sheet remains responsive on large photos.
- (NSURL *)animatedShareGIFURL {
    if (!_hasEditedImage || !_originalImageForShare || !self.image) return nil;
    UIImage *before = [self shareImageWithBrandingForImage:_originalImageForShare showOriginalCard:NO];
    UIImage *after = [self shareImageWithBranding];
    if (!before.CGImage || !after.CGImage) return nil;

    CGFloat maxSide = 900.0;
    CGFloat scale = MIN(1.0, maxSide / MAX(after.size.width, after.size.height));
    CGSize frameSize = CGSizeMake(floor(after.size.width * scale), floor(after.size.height * scale));
    if (frameSize.width < 1 || frameSize.height < 1) return nil;

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, CFSTR("com.compuserve.gif"), 14, NULL);
    if (!destination) return nil;
    NSDictionary *gifProperties = @{(NSString *)kCGImagePropertyGIFDictionary: @{(NSString *)kCGImagePropertyGIFLoopCount: @0}};
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)gifProperties);

    void (^addFrame)(UIImage *, CGFloat) = ^(UIImage *image, CGFloat delay) {
        UIGraphicsBeginImageContextWithOptions(frameSize, YES, 1.0);
        [[UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1] setFill];
        UIRectFill((CGRect){CGPointZero, frameSize});
        CGFloat imageScale = MIN(frameSize.width / image.size.width, frameSize.height / image.size.height);
        CGSize size = CGSizeMake(image.size.width * imageScale, image.size.height * imageScale);
        [image drawInRect:CGRectMake((frameSize.width - size.width) / 2.0,
                                     (frameSize.height - size.height) / 2.0,
                                     size.width, size.height)];
        UIImage *frame = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSDictionary *frameProperties = @{
            (NSString *)kCGImagePropertyGIFDictionary: @{(NSString *)kCGImagePropertyGIFDelayTime: @(delay)}
        };
        CGImageDestinationAddImage(destination, frame.CGImage, (__bridge CFDictionaryRef)frameProperties);
    };

    addFrame(before, 0.9);
    for (NSInteger step = 1; step <= 6; step++) {
        CGFloat progress = step / 6.0;
        UIGraphicsBeginImageContextWithOptions(frameSize, YES, 1.0);
        [before drawInRect:(CGRect){CGPointZero, frameSize}];
        [after drawInRect:(CGRect){CGPointZero, frameSize} blendMode:kCGBlendModeNormal alpha:progress];
        UIImage *transition = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        addFrame(transition, 0.11);
    }
    addFrame(after, 1.2);
    for (NSInteger step = 5; step >= 0; step--) {
        CGFloat progress = step / 6.0;
        UIGraphicsBeginImageContextWithOptions(frameSize, YES, 1.0);
        [before drawInRect:(CGRect){CGPointZero, frameSize}];
        [after drawInRect:(CGRect){CGPointZero, frameSize} blendMode:kCGBlendModeNormal alpha:progress];
        UIImage *transition = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        addFrame(transition, 0.11);
    }

    if (!CGImageDestinationFinalize(destination)) {
        CFRelease(destination);
        return nil;
    }
    CFRelease(destination);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"EZCompleteUI-edit-%@.gif", NSUUID.UUID.UUIDString]];
    return [data writeToFile:path atomically:YES] ? [NSURL fileURLWithPath:path] : nil;
}

- (void)downloadTapped {
    if (!self.image) return;
    _downloadButton.enabled = NO;
    UIImageWriteToSavedPhotosAlbum(self.image, self,
        @selector(image:didFinishSavingWithError:contextInfo:), NULL);
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error
 contextInfo:(void *)contextInfo {
    _downloadButton.enabled = YES;
    NSString *symbolName = error ? @"exclamationmark.triangle" : @"checkmark";
    [_downloadButton setImage:[UIImage systemImageNamed:symbolName] forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self->_downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.to.line"]
                                forState:UIControlStateNormal];
    });
}

// Exports a self-contained presentation image without altering the original
// gallery asset.  Attachments that have no recorded generation prompt simply
// omit the bottom prompt card.
- (UIImage *)shareImageWithBranding {
    return [self shareImageWithBrandingForImage:self.image showOriginalCard:_hasEditedImage];
}

- (UIImage *)shareImageWithBrandingForImage:(UIImage *)source showOriginalCard:(BOOL)showOriginalCard {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;

    NSString *prompt = [self.imagePrompt
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    CGFloat width = source.size.width;
    CGFloat border = MAX(12.0, width * 0.022);
    CGFloat headerHeight = MAX(58.0, width * 0.095);
    CGFloat promptHeight = prompt.length ? MAX(82.0, width * 0.14) : 0.0;
    CGSize outputSize = CGSizeMake(width, source.size.height + headerHeight + promptHeight + border * 2.0);

    UIGraphicsBeginImageContextWithOptions(outputSize, YES, source.scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect outputRect = (CGRect){ .origin = CGPointZero, .size = outputSize };
    NSArray *colors = @[
        (id)[UIColor colorWithRed:0.08 green:0.86 blue:0.77 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.31 green:0.38 blue:1.00 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.88 green:0.24 blue:0.92 alpha:1].CGColor
    ];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, 0),
                                CGPointMake(outputSize.width, outputSize.height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);

    CGRect innerRect = CGRectInset(outputRect, border, border);
    [[UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1] setFill];
    UIRectFill(innerRect);

    NSDictionary *brandAttributes = @{
        NSFontAttributeName: [UIFont fontWithName:@"AvenirNext-DemiBoldItalic"
                                              size:MAX(19.0, width * 0.040)] ?: [UIFont boldSystemFontOfSize:22],
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSKernAttributeName: @(0.8)
    };
    [@"EZCompleteUI" drawAtPoint:CGPointMake(border * 2.0, border + (headerHeight - 28.0) / 2.0)
                    withAttributes:brandAttributes];

    CGRect imageArea = CGRectMake(border, border + headerHeight, width - border * 2.0, source.size.height);
    [source drawInRect:imageArea];

    if (prompt.length) {
        CGRect promptRect = CGRectMake(border, CGRectGetMaxY(imageArea), width - border * 2.0, promptHeight);
        [[UIColor colorWithWhite:1 alpha:0.075] setFill];
        UIRectFill(promptRect);
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.alignment = NSTextAlignmentCenter;
        style.lineBreakMode = NSLineBreakByTruncatingTail;
        NSString *caption = [NSString stringWithFormat:@"%@", prompt];
        [caption drawInRect:CGRectInset(promptRect, 18.0, 14.0)
                  withAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:MAX(14.0, width * 0.024) weight:UIFontWeightMedium],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.93 alpha:1],
            NSParagraphStyleAttributeName: style
        }];
    }

    // For an AI-edited result, keep a small, clearly labelled reference to
    // the image the edit began with.  It is part of the exported image only;
    // the gallery's original asset remains untouched.
    if (showOriginalCard && _originalImageForShare) {
        CGFloat cardWidth = MIN(width * 0.31, 300.0);
        CGFloat cardHeight = MAX(cardWidth * 0.72, 100.0);
        CGFloat cardInset = border * 1.25;
        CGRect cardRect = CGRectMake(CGRectGetMaxX(imageArea) - cardWidth - cardInset,
                                     CGRectGetMaxY(imageArea) - cardHeight - cardInset,
                                     cardWidth, cardHeight);
        UIBezierPath *outerPath = [UIBezierPath bezierPathWithRoundedRect:cardRect cornerRadius:12.0];
        CGContextSaveGState(context);
        [outerPath addClip];
        NSArray *cardColors = @[
            (id)[UIColor colorWithRed:0.08 green:0.86 blue:0.77 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.31 green:0.38 blue:1.00 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.88 green:0.24 blue:0.92 alpha:1].CGColor
        ];
        CGColorSpaceRef cardColorSpace = CGColorSpaceCreateDeviceRGB();
        CGGradientRef cardGradient = CGGradientCreateWithColors(cardColorSpace,
                                                                  (__bridge CFArrayRef)cardColors, NULL);
        CGContextDrawLinearGradient(context, cardGradient, cardRect.origin,
                                    CGPointMake(CGRectGetMaxX(cardRect), CGRectGetMaxY(cardRect)), 0);
        CGGradientRelease(cardGradient);
        CGColorSpaceRelease(cardColorSpace);
        CGContextRestoreGState(context);

        CGRect innerCard = CGRectInset(cardRect, 4.0, 4.0);
        UIBezierPath *innerPath = [UIBezierPath bezierPathWithRoundedRect:innerCard cornerRadius:9.0];
        CGContextSaveGState(context);
        [innerPath addClip];
        [[UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1] setFill];
        UIRectFill(innerCard);
        CGFloat imageScale = MAX(CGRectGetWidth(innerCard) / _originalImageForShare.size.width,
                                 CGRectGetHeight(innerCard) / _originalImageForShare.size.height);
        CGSize fittedSize = CGSizeMake(_originalImageForShare.size.width * imageScale,
                                       _originalImageForShare.size.height * imageScale);
        CGRect originalRect = CGRectMake(CGRectGetMidX(innerCard) - fittedSize.width / 2.0,
                                         CGRectGetMidY(innerCard) - fittedSize.height / 2.0,
                                         fittedSize.width, fittedSize.height);
        [_originalImageForShare drawInRect:originalRect];
        CGContextRestoreGState(context);

        NSDictionary *originalLabelAttributes = @{
            NSFontAttributeName: [UIFont systemFontOfSize:MAX(9.0, width * 0.014) weight:UIFontWeightBold],
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSKernAttributeName: @(0.6)
        };
        [@"ORIGINAL" drawAtPoint:CGPointMake(CGRectGetMinX(cardRect) + 9.0,
                                               CGRectGetMinY(cardRect) + 8.0)
                    withAttributes:originalLabelAttributes];
    }

    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

- (void)deleteTapped {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Delete Photo"
                         message:@"This will permanently remove the photo from EZ Attachments."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_) {
        NSError *err;
        [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:&err];
        if (self.onDeleted) self.onDeleted();
        [self dismiss];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = _deleteButton;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dismiss {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)dismissAllTheWay {
    // Dismiss the whole gallery sheet so the chat window is visible
    UIViewController *root = self.navigationController.presentingViewController;
    [root dismissViewControllerAnimated:YES completion:nil];
}

@end

// ── Gallery VC ────────────────────────────────────────────────────────────────

@interface EZPhotoGalleryViewController () <UICollectionViewDelegate,
                                             UICollectionViewDataSource,
                                             UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UICollectionView      *collectionView;
@property (nonatomic, strong) UICollectionViewFlowLayout *layout;
@property (nonatomic, strong) NSMutableArray<NSString *> *filePaths;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbnailCache;
@property (nonatomic, strong) NSOperationQueue      *loadQueue;
@property (nonatomic, assign) NSInteger              columnCount;
@property (nonatomic, strong) UILabel               *emptyLabel;
@property (nonatomic, strong) UILabel               *countLabel;
@end

@implementation EZPhotoGalleryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.columnCount = kDefaultColumns;
    self.filePaths   = [NSMutableArray array];
    self.thumbnailCache = [[NSCache alloc] init];
    self.thumbnailCache.countLimit = 200;
    self.loadQueue = [[NSOperationQueue alloc] init];
    self.loadQueue.maxConcurrentOperationCount = 4;
    self.loadQueue.qualityOfService = NSQualityOfServiceUserInitiated;

    [self styleNavBar];
    [self setupCollectionView];
    [self setupEmptyState];
    [self setupPinchGesture];
    [self loadFilePaths];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Includes edits saved by a pushed detail controller without requiring it
    // to mutate the gallery's data source directly.
    [self loadFilePaths];
}

- (void)styleNavBar {
    self.title = @"EZ Attachments";

    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0];
    appearance.titleTextAttributes = @{
        NSFontAttributeName:            [UIFont boldSystemFontOfSize:17],
        NSForegroundColorAttributeName: [UIColor whiteColor],
    };
    self.navigationController.navigationBar.standardAppearance   = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.tintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

    // Close button
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor colorWithWhite:0.65 alpha:1];

    // Count label as right item (updated after load)
    self.countLabel = [[UILabel alloc] init];
    self.countLabel.font      = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.countLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.countLabel];
}

- (void)setupCollectionView {
    self.layout = [[UICollectionViewFlowLayout alloc] init];
    self.layout.minimumInteritemSpacing = kCellSpacing;
    self.layout.minimumLineSpacing      = kCellSpacing;
    self.layout.sectionInset            = UIEdgeInsetsZero;

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds
                                             collectionViewLayout:self.layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor  = [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0];
    self.collectionView.delegate         = self;
    self.collectionView.dataSource       = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[EZGalleryCell class] forCellWithReuseIdentifier:kGalleryCellID];
    [self.view addSubview:self.collectionView];
}

- (void)setupEmptyState {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text          = @"No attachments yet.\nImages saved from chats appear here.";
    self.emptyLabel.numberOfLines = 2;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font          = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    self.emptyLabel.textColor     = [UIColor colorWithWhite:0.4 alpha:1];
    self.emptyLabel.hidden        = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor
                                                              constant:-60],
    ]];
}

- (void)setupPinchGesture {
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePinch:)];
    [self.collectionView addGestureRecognizer:pinch];
}

// ── File loading ──────────────────────────────────────────────────────────────

- (NSString *)attachmentsPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:kAttachmentsDir];
}

- (void)loadFilePaths {
    NSString *dir = [self attachmentsPath];
    NSArray<NSString *> *all = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:dir error:nil] ?: @[];

    NSArray<NSString *> *imageExts = @[@"jpg", @"jpeg", @"png", @"heic", @"gif", @"webp", @"tiff", @"bmp"];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *name in all) {
        if ([imageExts containsObject:name.pathExtension.lowercaseString]) {
            [paths addObject:[dir stringByAppendingPathComponent:name]];
        }
    }

    // Sort newest first (by modification date)
    NSFileManager *fm = [NSFileManager defaultManager];
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [fm attributesOfItemAtPath:a error:nil][NSFileModificationDate] ?: [NSDate distantPast];
        NSDate *db = [fm attributesOfItemAtPath:b error:nil][NSFileModificationDate] ?: [NSDate distantPast];
        return [db compare:da];
    }];

    self.filePaths = paths;
    [self.collectionView reloadData];

    NSInteger count = paths.count;
    self.countLabel.text = count == 0 ? @"" :
        [NSString stringWithFormat:@"%ld %@", (long)count, count == 1 ? @"photo" : @"photos"];
    self.emptyLabel.hidden = count > 0;
}

// ── Pinch to resize grid ──────────────────────────────────────────────────────

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch {
    static NSInteger startColumns;

    if (pinch.state == UIGestureRecognizerStateBegan) {
        startColumns = self.columnCount;
    }

    if (pinch.state == UIGestureRecognizerStateChanged ||
        pinch.state == UIGestureRecognizerStateEnded) {

        // Pinch out (scale > 1) → fewer columns (bigger cells)
        // Pinch in  (scale < 1) → more columns (smaller cells)
        NSInteger newCols = (NSInteger)round(startColumns / pinch.scale);
        newCols = MAX(kMinColumns, MIN(kMaxColumns, newCols));

        if (newCols != self.columnCount) {
            self.columnCount = newCols;
            [UIView animateWithDuration:0.2 animations:^{
                [self.collectionView performBatchUpdates:^{
                    [self.layout invalidateLayout];
                } completion:nil];
            }];

            // Haptic tick
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
        }
    }
}

// ── UICollectionView ──────────────────────────────────────────────────────────

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return self.filePaths.count;
}

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat total = cv.bounds.size.width - kCellSpacing * (self.columnCount - 1);
    CGFloat side  = floor(total / self.columnCount);
    return CGSizeMake(side, side);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    EZGalleryCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kGalleryCellID
                                                        forIndexPath:indexPath];
    NSString *path = self.filePaths[indexPath.item];
    UIImage  *cached = [self.thumbnailCache objectForKey:path];

    if (cached) {
        [cell setImage:cached];
    } else {
        [cell startShimmer];
        CGFloat side = [self collectionView:cv layout:cv.collectionViewLayout
                     sizeForItemAtIndexPath:indexPath].width * UIScreen.mainScreen.scale;

        NSIndexPath *ip = indexPath;
        [self.loadQueue addOperationWithBlock:^{
            UIImage *thumb = [self thumbnailForPath:path side:side];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (thumb) [self.thumbnailCache setObject:thumb forKey:path];
                EZGalleryCell *visible = (EZGalleryCell *)[cv cellForItemAtIndexPath:ip];
                if (visible) [visible setImage:thumb];
            });
        }];
    }
    return cell;
}

- (UIImage *)thumbnailForPath:(NSString *)path side:(CGFloat)side {
    UIImage *full = [UIImage imageWithContentsOfFile:path];
    if (!full) return nil;
    CGSize  sz     = CGSizeMake(side, side);
    UIGraphicsBeginImageContextWithOptions(sz, YES, 0);
    CGFloat scale  = MAX(sz.width / full.size.width, sz.height / full.size.height);
    CGFloat w      = full.size.width  * scale;
    CGFloat h      = full.size.height * scale;
    [full drawInRect:CGRectMake((sz.width - w) / 2, (sz.height - h) / 2, w, h)];
    UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return thumb;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSString *path  = self.filePaths[indexPath.item];
    UIImage  *image = [UIImage imageWithContentsOfFile:path];
    if (!image) return;

    EZPhotoDetailViewController *detail = [EZPhotoDetailViewController new];
    detail.image    = image;
    detail.filePath = path;
    NSDictionary *prompts = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:kGalleryImagePromptsKey];
    NSString *prompt = [prompts[path] isKindOfClass:[NSString class]] ? prompts[path] : nil;
    // Compatibility with generations made before prompt-to-file metadata.
    if (!prompt.length && [path isEqualToString:[[NSUserDefaults standardUserDefaults]
                                           stringForKey:@"lastImageLocalPath"]]) {
        prompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastImagePrompt"];
    }
    detail.imagePrompt = prompt;

    __weak typeof(self) weakSelf = self;
    detail.onDeleted = ^{
        [weakSelf loadFilePaths];
    };

    [self.navigationController pushViewController:detail animated:YES];
}

// ── Close ─────────────────────────────────────────────────────────────────────

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
