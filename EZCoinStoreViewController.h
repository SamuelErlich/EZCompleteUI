// EZCoinStoreViewController.h
// EZCompleteUI
//
// Gamified coin store — subscription tiers and one-time coin top-ups.
// Launches from Settings "Subscribe / Manage" button and from the
// low-coins popup whenever a feature is blocked by insufficient balance.

#import <UIKit/UIKit.h>
#import <SafariServices/SafariServices.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZCoinStoreViewController : UIViewController

@property (nonatomic, assign) BOOL showLowCoinsWarning;
    /// If YES, shows a "Not enough coins" banner at the top of the store.

@property (nonatomic, strong, nullable) NSTimer *countdownTimer;
    // Fires every second to tick the "Next: Xh Ym Xs" label

@property (nonatomic, copy, nullable) NSString *triggeringFeatureName;
    /// Optional: the feature name that triggered the low-coins state (e.g. "GPT-5 chat")
@end

NS_ASSUME_NONNULL_END
