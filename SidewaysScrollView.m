//
//  SidewaysScrollView.m
//  EZCompleteUI
//
//  Compact, accessible tool rail used by the main chat screen. The public
//  configure method stays compatible with the original project while the
//  duplicated cover-flow cards are replaced by one calm blue/purple row.
//

#import "SidewaysScrollView.h"
#import "EZUITheme.h"

@interface SidewaysScrollView ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSArray<UIButton *> *protoButtons;
@property (nonatomic, assign) BOOL doubleSize;
@property (nonatomic, assign) CGSize lastLayoutSize;
@end

@implementation SidewaysScrollView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        _interItemSpacing = 8.0;
        _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.alwaysBounceHorizontal = YES;
        _scrollView.directionalLockEnabled = YES;
        _scrollView.clipsToBounds = NO;
        [self addSubview:_scrollView];
        [NSLayoutConstraint activateConstraints:@[
            [_scrollView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
            [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10.0],
        ]];
    }
    return self;
}

- (void)configureWithButtons:(NSArray<UIButton *> *)buttons doubleSize:(BOOL)doubleSize {
    self.protoButtons = buttons ?: @[];
    self.doubleSize = doubleSize;
    [self rebuildContent];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.scrollView.subviews.count != self.protoButtons.count ||
        !CGSizeEqualToSize(self.lastLayoutSize, self.bounds.size)) {
        [self rebuildContent];
    }
}

- (void)rebuildContent {
    if (self.bounds.size.height <= 0) return;
    for (UIView *view in [self.scrollView.subviews copy]) [view removeFromSuperview];
    if (self.protoButtons.count == 0) {
        self.scrollView.contentSize = CGSizeZero;
        self.lastLayoutSize = self.bounds.size;
        return;
    }

    CGFloat itemWidth = self.doubleSize ? 96.0 : 86.0;
    CGFloat itemHeight = MAX(68.0, MIN(86.0, CGRectGetHeight(self.bounds) - 8.0));
    CGFloat x = 0.0;
    for (NSInteger i = 0; i < self.protoButtons.count; i++) {
        UIButton *button = [self modernButtonFromPrototype:self.protoButtons[i]];
        button.frame = CGRectMake(x, (CGRectGetHeight(self.bounds) - itemHeight) / 2.0,
                                  itemWidth, itemHeight);
        [self.scrollView addSubview:button];
        x += itemWidth + self.interItemSpacing;
    }
    self.scrollView.contentSize = CGSizeMake(MAX(0, x - self.interItemSpacing),
                                              CGRectGetHeight(self.bounds));
    self.lastLayoutSize = self.bounds.size;
}

- (UIButton *)modernButtonFromPrototype:(UIButton *)prototype {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *image = [prototype imageForState:UIControlStateNormal];
    if (image) [button setImage:image forState:UIControlStateNormal];
    NSString *title = [prototype titleForState:UIControlStateNormal];
    if (title.length) [button setTitle:title forState:UIControlStateNormal];
    button.accessibilityLabel = prototype.accessibilityLabel ?: title;
    button.accessibilityTraits = UIAccessibilityTraitButton;
    button.tintColor = [EZUITheme accentSecondaryColor];
    button.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.72;
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    button.backgroundColor = [EZUITheme surfaceElevatedColor];
    button.layer.cornerRadius = 16.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [EZUITheme dividerColor].CGColor;
    button.layer.masksToBounds = YES;

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
        configuration.image = image;
        configuration.title = title;
        configuration.imagePlacement = NSDirectionalRectEdgeTop;
        configuration.imagePadding = 5.0;
        configuration.titlePadding = 2.0;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(8, 5, 7, 5);
        configuration.baseForegroundColor = [EZUITheme primaryTextColor];
        configuration.imageColorTransformer = ^UIColor *(UIColor *color) {
            return [EZUITheme accentSecondaryColor];
        };
        button.configuration = configuration;
    }

    for (id target in prototype.allTargets) {
        NSArray<NSString *> *actions = [prototype actionsForTarget:target
                                                   forControlEvent:UIControlEventTouchUpInside] ?: @[];
        for (NSString *actionName in actions) {
            [button addTarget:target action:NSSelectorFromString(actionName)
             forControlEvents:UIControlEventTouchUpInside];
        }
    }
    [button addTarget:self action:@selector(ez_pressed:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(ez_released:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchCancel];
    return button;
}

- (void)ez_pressed:(UIButton *)button {
    [UIView animateWithDuration:0.12 animations:^{ button.transform = CGAffineTransformMakeScale(0.94, 0.94); }];
}

- (void)ez_released:(UIButton *)button {
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:2.0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        button.transform = CGAffineTransformIdentity;
    } completion:nil];
}

@end
