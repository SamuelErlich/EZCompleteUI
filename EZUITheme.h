// EZUITheme.h
// Shared visual tokens for the Portuguese dark blue/purple redesign.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZUITheme : NSObject
+ (UIColor *)backgroundColor;
+ (UIColor *)surfaceColor;
+ (UIColor *)surfaceElevatedColor;
+ (UIColor *)accentColor;
+ (UIColor *)accentSecondaryColor;
+ (UIColor *)accentSoftColor;
+ (UIColor *)primaryTextColor;
+ (UIColor *)secondaryTextColor;
+ (UIColor *)dividerColor;
+ (UIColor *)userBubbleColor;
+ (UIColor *)assistantBubbleColor;
+ (void)styleCard:(UIView *)view cornerRadius:(CGFloat)cornerRadius;
+ (void)stylePrimaryButton:(UIButton *)button;
+ (void)styleSecondaryButton:(UIButton *)button;
+ (void)styleTextInput:(UIView *)view;
@end

NS_ASSUME_NONNULL_END
