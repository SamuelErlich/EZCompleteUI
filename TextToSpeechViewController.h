// TextToSpeechViewController.h

#import <UIKit/UIKit.h>

@interface TextToSpeechViewController : UIViewController
- (void)prefillWithText:(nullable NSString *)text voiceID:(nullable NSString *)voiceID voiceName:(nullable NSString*)voiceName;
@end
