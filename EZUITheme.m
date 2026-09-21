// EZUITheme.m

#import "EZUITheme.h"

@implementation EZUITheme
+ (UIColor *)backgroundColor { return [UIColor colorWithRed:0.025 green:0.030 blue:0.070 alpha:1.0]; }
+ (UIColor *)surfaceColor { return [UIColor colorWithRed:0.060 green:0.070 blue:0.135 alpha:1.0]; }
+ (UIColor *)surfaceElevatedColor { return [UIColor colorWithRed:0.095 green:0.105 blue:0.190 alpha:1.0]; }
+ (UIColor *)accentColor { return [UIColor colorWithRed:0.450 green:0.330 blue:1.000 alpha:1.0]; }
+ (UIColor *)accentSecondaryColor { return [UIColor colorWithRed:0.180 green:0.650 blue:1.000 alpha:1.0]; }
+ (UIColor *)accentSoftColor { return [UIColor colorWithRed:0.450 green:0.330 blue:1.000 alpha:0.20]; }
+ (UIColor *)primaryTextColor { return [UIColor colorWithWhite:0.97 alpha:1.0]; }
+ (UIColor *)secondaryTextColor { return [UIColor colorWithWhite:0.70 alpha:1.0]; }
+ (UIColor *)dividerColor { return [UIColor colorWithRed:0.35 green:0.37 blue:0.55 alpha:0.35]; }
+ (UIColor *)userBubbleColor { return [UIColor colorWithRed:0.245 green:0.200 blue:0.620 alpha:1.0]; }
+ (UIColor *)assistantBubbleColor { return [UIColor colorWithRed:0.095 green:0.105 blue:0.190 alpha:1.0]; }
+ (void)styleCard:(UIView *)view cornerRadius:(CGFloat)cornerRadius {
    view.backgroundColor = [self surfaceColor];
    view.layer.cornerRadius = cornerRadius;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = [self dividerColor].CGColor;
    view.layer.masksToBounds = YES;
}
+ (void)stylePrimaryButton:(UIButton *)button {
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [self accentColor];
    button.layer.cornerRadius = 14.0;
    button.layer.masksToBounds = YES;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
}
+ (void)styleSecondaryButton:(UIButton *)button {
    button.tintColor = [self accentSecondaryColor];
    button.backgroundColor = [self accentSoftColor];
    button.layer.cornerRadius = 12.0;
    button.layer.masksToBounds = YES;
}
+ (void)styleTextInput:(UIView *)view {
    view.backgroundColor = [self surfaceElevatedColor];
    view.layer.cornerRadius = 16.0;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = [self dividerColor].CGColor;
    view.layer.masksToBounds = YES;
}
@end
