// EZPoliciesViewController.h
// EZCompleteUI

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EZPolicyTab) {
    EZPolicyTabTerms   = 0,
    EZPolicyTabPrivacy = 1,
    EZPolicyTabRefund  = 2,
};

@interface EZPoliciesViewController : UIViewController

/// Which tab to show on first appearance. Defaults to EZPolicyTabTerms (0).
@property (nonatomic, assign) EZPolicyTab initialTab;

@end

NS_ASSUME_NONNULL_END
