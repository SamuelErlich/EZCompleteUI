// BRCommunityAdminViewController.h
// BrainRotGame
// EZCompleteUI v1.0 — Community Admin Panel
//
// Purpose:
//   An in-app moderation panel for the community game library. Gated behind
//   two independent layers:
//     1. #if DEBUG compile flag in the caller (BRGamePickerViewController)
//        so the entry point never appears in App Store or ad-hoc builds.
//     2. A BR_ADMIN_CODE passphrase verified server-side on every request
//        so a jailbroken device with a patched release build still gets a
//        403 from the edge function without the correct code.
//
//   Shows all shared games (including auto-hidden ones), their report counts,
//   and their current hidden/visible status. Per-game actions:
//     • Swipe-leading:  Restore (if hidden) or Hide (if visible).
//     • Swipe-trailing: Delete (permanent, non-reversible, confirmed by alert).
//
//   The admin code entered by the user is held in memory only and is never
//   written to disk, NSUserDefaults, or any persistent store.
//
// Usage (wrap call site in #if DEBUG / #endif):
//   BRCommunityAdminViewController *admin =
//     [[BRCommunityAdminViewController alloc]
//       initWithBrCommunityEndpointURL:endpointURL];
//   UINavigationController *nav =
//     [[UINavigationController alloc] initWithRootViewController:admin];
//   nav.modalPresentationStyle = UIModalPresentationFullScreen;
//   [self presentViewController:nav animated:YES completion:nil];

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRCommunityAdminViewController : UIViewController

/// Designated initializer. `endpointURL` is the br-community edge function
/// URL resolved from kBRHighScoreURL — passed in so this VC never derives
/// project URLs itself.
- (instancetype)initWithBrCommunityEndpointURL:(NSURL *)endpointURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
