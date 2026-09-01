//
//  EZTTSClipEditViewController.h
//  EZTTSLibrary
//
//  Expanded editing view for a single archived clip:
//   - Speed: playback-rate only, persisted per-clip, no regeneration.
//   - Change voice: hands off to the compose screen, prefilled, for an actual
//     regeneration (voice changes require new audio — nothing in this view fakes that).
//   - Insert silence: scrub to a point on the waveform, pick a duration, and splice in
//     a true silent gap via AVMutableComposition, saved as a brand-new archived clip.
//     The original clip is never modified.
//

#import <UIKit/UIKit.h>
#import "EZTTSManifestEntry.h"

NS_ASSUME_NONNULL_BEGIN

@interface EZTTSClipEditViewController : UIViewController

- (instancetype)initWithEntry:(EZTTSManifestEntry *)entry;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
