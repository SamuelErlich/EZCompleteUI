// EZInsuranceLandingViewController.h
// EZCompleteUI
//
// Purpose:
//   Entry point for the Insurance Policy feature. Shows every policy still
//   "in play" (active, releasing, or release_failed) and a button to start
//   a new one. Released and cancelled policies are deliberately not shown
//   here — they're permanent rows in the database, just not this screen's
//   concern; a history view can be added later if it's ever wanted.
//
//   Tapping an existing row, or the "Open New Policy" button, both push
//   EZInsurancePolicyDetailViewController — it handles both "brand new"
//   and "existing" states itself, so there's only one place files/
//   recipients/countdown UI is ever written.
//
// Changes:
//   - Initial version.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZInsuranceLandingViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
