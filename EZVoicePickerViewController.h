//
//  EZVoicePickerViewController.h
//  EZTTSLibrary
//
//  Modal picker listing the caller's available ElevenLabs voices (clones + shared/premade
//  voices) via EZTTSVoiceService, with search. Present wrapped in its own UINavigationController.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZVoicePickerViewController : UIViewController

/// Called with the selected voice's id and display name (name may be nil if the voice
/// dictionary didn't include one). The picker dismisses itself right before calling this.
@property (nonatomic, copy, nullable) void (^onVoiceSelected)(NSString *voiceID, NSString * _Nullable voiceName);

@end

NS_ASSUME_NONNULL_END
