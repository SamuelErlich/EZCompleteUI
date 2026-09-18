
#!/usr/bin/env python3
"""
Patches EZPhotoGalleryViewController.m with an in-place AI photo editor.

Usage:
    python3 patch_ez_photo_gallery.py /path/to/EZPhotoGalleryViewController.m

The script always creates a timestamped .bak backup in the same folder before
writing the patched source file.
"""

from __future__ import annotations

import shutil
import sys
from datetime import datetime
from pathlib import Path


def require_replace(source: str, old: str, new: str, label: str) -> str:
    if old not in source:
        raise RuntimeError(
            f'Could not find the expected "{label}" section. '
            "The source file may differ from the version supplied."
        )
    return source.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: python3 patch_ez_photo_gallery.py /path/to/EZPhotoGalleryViewController.m")
        raise SystemExit(2)

    path = Path(sys.argv[1]).expanduser().resolve()
    if not path.is_file():
        print(f"File not found: {path}")
        raise SystemExit(2)

    source = path.read_text(encoding="utf-8")

    if "EZPhotoAIEditorPatchInstalled" in source:
        print("This file already appears to have the AI editor patch installed. No changes made.")
        return

    backup = path.with_name(
        f"{path.stem}.{datetime.now().strftime('%Y%m%d-%H%M%S')}.bak{path.suffix}"
    )
    shutil.copy2(path, backup)

    source = require_replace(
        source,
        '#import <SafariServices/SafariServices.h>',
        '#import <SafariServices/SafariServices.h>\n#import <QuartzCore/QuartzCore.h>',
        "import section",
    )

    source = require_replace(
        source,
        '''    UIButton          *_deleteButton;
    UILabel           *_filenameLabel;
}''',
        '''    UIButton          *_deleteButton;
    UILabel           *_filenameLabel;

    // EZPhotoAIEditorPatchInstalled
    UITextField       *_editPromptField;
    UIButton          *_sendEditButton;
    UIView            *_processingOverlay;
    UIVisualEffectView *_processingBlurView;
    CAGradientLayer   *_waveGradientLayer;
    UIActivityIndicatorView *_editSpinner;
    NSURLSessionDataTask *_imageEditTask;
    BOOL               _isEditingImage;
}''',
        "detail controller ivars",
    )

    source = require_replace(
        source,
        '''    [self setupScrollView];
    [self setupToolbar];
    [self setupNavBar];''',
        '''    [self setupScrollView];
    [self setupToolbar];
    [self setupNavBar];
    [self setupImageEditingControls];''',
        "viewDidLoad setup",
    )

    source = require_replace(
        source,
        '''    CGFloat toolbarH = 110 + self.view.safeAreaInsets.bottom;''',
        '''    CGFloat toolbarH = 184 + self.view.safeAreaInsets.bottom;''',
        "toolbar height",
    )

    source = require_replace(
        source,
        '''    _toolbar.frame = CGRectMake(0, self.view.bounds.size.height - toolbarH,
                                self.view.bounds.size.width, toolbarH);
    [self layoutToolbarButtons];''',
        '''    _toolbar.frame = CGRectMake(0, self.view.bounds.size.height - toolbarH,
                                self.view.bounds.size.width, toolbarH);
    [self layoutToolbarButtons];
    [self layoutImageEditingControls];
    [self layoutProcessingOverlay];''',
        "layout toolbar section",
    )

    source = require_replace(
        source,
        '''    CGFloat pad  = 16;
    CGFloat btnH = 48;
    CGFloat y    = 14;''',
        '''    CGFloat pad  = 16;
    CGFloat btnH = 56;
    CGFloat y    = 88;''',
        "toolbar buttons positioning",
    )

    source = require_replace(
        source,
        '''- (UIButton *)makeButtonTitle:(NSString *)title icon:(NSString *)iconName''',
        r'''#pragma mark - AI Image Editing

- (void)setupImageEditingControls {
    UIView *promptContainer = [[UIView alloc] init];
    promptContainer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    promptContainer.layer.cornerRadius = 18.0;
    promptContainer.layer.borderWidth = 1.0;
    promptContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.11].CGColor;
    promptContainer.clipsToBounds = YES;
    [_toolbar.contentView addSubview:promptContainer];

    _editPromptField = [[UITextField alloc] init];
    _editPromptField.placeholder = @"Describe your edits…";
    _editPromptField.textColor = [UIColor whiteColor];
    _editPromptField.tintColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _editPromptField.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _editPromptField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _editPromptField.returnKeyType = UIReturnKeySend;
    _editPromptField.enablesReturnKeyAutomatically = YES;
    _editPromptField.delegate = (id<UITextFieldDelegate>)self;
    _editPromptField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Describe your edits…"
            attributes:@{
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.72 alpha:0.70]
            }];
    [promptContainer addSubview:_editPromptField];

    _sendEditButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _sendEditButton.backgroundColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _sendEditButton.tintColor = [UIColor colorWithRed:0.03 green:0.05 blue:0.10 alpha:1.0];
    _sendEditButton.layer.cornerRadius = 28.0;
    _sendEditButton.layer.shadowColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0].CGColor;
    _sendEditButton.layer.shadowOpacity = 0.30;
    _sendEditButton.layer.shadowRadius = 10.0;
    _sendEditButton.layer.shadowOffset = CGSizeMake(0, 4);
    UIImageSymbolConfiguration *symbolConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
    UIImage *sendImage = [UIImage systemImageNamed:@"arrow.up"
                                 withConfiguration:symbolConfig];
    [_sendEditButton setImage:sendImage forState:UIControlStateNormal];
    [_sendEditButton addTarget:self
                        action:@selector(sendImageEditTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_sendEditButton];

    _editSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _editSpinner.color = [UIColor colorWithRed:0.03 green:0.05 blue:0.10 alpha:1.0];
    _editSpinner.hidesWhenStopped = YES;
    [_sendEditButton addSubview:_editSpinner];
}

- (void)layoutImageEditingControls {
    if (!_editPromptField || !_sendEditButton) return;

    CGFloat pad = 16.0;
    CGFloat y = 14.0;
    CGFloat fieldHeight = 56.0;
    CGFloat sendSize = 56.0;
    CGFloat width = _toolbar.contentView.bounds.size.width;
    if (width <= 0) width = self.view.bounds.size.width;

    _sendEditButton.frame = CGRectMake(width - pad - sendSize, y, sendSize, sendSize);
    _editSpinner.center = CGPointMake(CGRectGetMidX(_sendEditButton.bounds),
                                      CGRectGetMidY(_sendEditButton.bounds));

    UIView *promptContainer = _editPromptField.superview;
    promptContainer.frame = CGRectMake(pad, y, width - (pad * 2.0) - sendSize - 10.0, fieldHeight);
    _editPromptField.frame = CGRectInset(promptContainer.bounds, 16.0, 0.0);
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self sendImageEditTapped];
    return NO;
}

- (void)editTapped {
    [_editPromptField becomeFirstResponder];
    [UIView animateWithDuration:0.20 animations:^{
        _editPromptField.superview.transform = CGAffineTransformMakeScale(1.02, 1.02);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.18 animations:^{
            _editPromptField.superview.transform = CGAffineTransformIdentity;
        }];
    }];
}

- (void)sendImageEditTapped {
    if (_isEditingImage) return;

    NSString *prompt = [_editPromptField.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (prompt.length == 0) {
        [self showImageEditError:@"Please describe the change you want to make."];
        [_editPromptField becomeFirstResponder];
        return;
    }

    NSString *apiKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"OpenAIAPIKey"];
    if (![apiKey isKindOfClass:[NSString class]] || apiKey.length == 0) {
        [self showImageEditError:@"OpenAIAPIKey is missing from Info.plist."];
        return;
    }

    NSData *imageData = [self PNGDataForImage:self.image];
    if (imageData.length == 0) {
        [self showImageEditError:@"The selected photo could not be prepared for editing."];
        return;
    }

    [_editPromptField resignFirstResponder];
    [self setImageEditing:YES];
    [self startProcessingAnimation];

    NSString *boundary = [NSString stringWithFormat:@"EZCompleteUI-%@", NSUUID.UUID.UUIDString];
    NSMutableData *body = [NSMutableData data];

    [self appendMultipartField:@"model" value:@"gpt-image-1" boundary:boundary toBody:body];
    [self appendMultipartField:@"prompt" value:prompt boundary:boundary toBody:body];
    [self appendMultipartField:@"size" value:@"1024x1024" boundary:boundary toBody:body];
    [self appendMultipartField:@"quality" value:@"medium" boundary:boundary toBody:body];
    [self appendMultipartFileNamed:@"image"
                          fileName:@"attachment.png"
                       contentType:@"image/png"
                              data:imageData
                          boundary:boundary
                            toBody:body];
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary]
                      dataUsingEncoding:NSUTF8StringEncoding]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/images/edits"]];
    request.HTTPMethod = @"POST";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
   forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.HTTPBody = body;
    request.timeoutInterval = 180.0;

    __weak typeof(self) weakSelf = self;
    _imageEditTask = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self->_imageEditTask = nil;

            if (error) {
                [self finishImageEditWithImage:nil error:error.localizedDescription];
                return;
            }

            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                  options:0
                                                                    error:&jsonError];
            if (http.statusCode < 200 || http.statusCode >= 300) {
                NSString *message = [json[@"error"][@"message"] isKindOfClass:[NSString class]]
                    ? json[@"error"][@"message"]
                    : @"OpenAI could not complete this image edit.";
                [self finishImageEditWithImage:nil error:message];
                return;
            }

            NSString *base64 = [json[@"data"] firstObject][@"b64_json"];
            NSData *editedData = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
            UIImage *editedImage = [UIImage imageWithData:editedData];
            if (!editedImage || jsonError) {
                [self finishImageEditWithImage:nil
                                           error:@"The image-edit response did not contain a usable image."];
                return;
            }

            [self finishImageEditWithImage:editedImage error:nil];
        });
    }];
    [_imageEditTask resume];
}

- (NSData *)PNGDataForImage:(UIImage *)image {
    if (!image) return nil;

    CGFloat maximumDimension = 2048.0;
    CGSize sourceSize = image.size;
    CGFloat largestSide = MAX(sourceSize.width, sourceSize.height);
    UIImage *prepared = image;

    if (largestSide > maximumDimension) {
        CGFloat scale = maximumDimension / largestSide;
        CGSize targetSize = CGSizeMake(floor(sourceSize.width * scale),
                                       floor(sourceSize.height * scale));
        UIGraphicsBeginImageContextWithOptions(targetSize, NO, 1.0);
        [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
        prepared = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }

    return UIImagePNGRepresentation(prepared);
}

- (void)appendMultipartField:(NSString *)name
                       value:(NSString *)value
                    boundary:(NSString *)boundary
                      toBody:(NSMutableData *)body {
    NSString *part = [NSString stringWithFormat:
        @"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n",
        boundary, name, value];
    [body appendData:[part dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)appendMultipartFileNamed:(NSString *)name
                        fileName:(NSString *)fileName
                     contentType:(NSString *)contentType
                            data:(NSData *)data
                        boundary:(NSString *)boundary
                          toBody:(NSMutableData *)body {
    NSString *header = [NSString stringWithFormat:
        @"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n"
         "Content-Type: %@\r\n\r\n",
        boundary, name, fileName, contentType];
    [body appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:data];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)setImageEditing:(BOOL)editing {
    _isEditingImage = editing;
    _editPromptField.enabled = !editing;
    _sendEditButton.enabled = !editing;
    _askButton.enabled = !editing;
    _editButton.enabled = !editing;
    _useInGameButton.enabled = !editing;
    _shareButton.enabled = !editing;
    _deleteButton.enabled = !editing;
    _sendEditButton.alpha = editing ? 0.92 : 1.0;

    if (editing) {
        [_sendEditButton setImage:nil forState:UIControlStateNormal];
        [_editSpinner startAnimating];
    } else {
        [_editSpinner stopAnimating];
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
        [_sendEditButton setImage:[UIImage systemImageNamed:@"arrow.up"
                                          withConfiguration:config]
                          forState:UIControlStateNormal];
    }
}

- (void)startProcessingAnimation {
    if (_processingOverlay) return;

    _processingOverlay = [[UIView alloc] initWithFrame:_imageView.bounds];
    _processingOverlay.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _processingOverlay.userInteractionEnabled = NO;
    _processingOverlay.clipsToBounds = YES;
    _processingOverlay.backgroundColor = [UIColor colorWithRed:0.03 green:0.10 blue:0.18 alpha:0.12];
    [_imageView addSubview:_processingOverlay];

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _processingBlurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    _processingBlurView.frame = _processingOverlay.bounds;
    _processingBlurView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _processingBlurView.alpha = 0.0;
    [_processingOverlay addSubview:_processingBlurView];

    _waveGradientLayer = [CAGradientLayer layer];
    _waveGradientLayer.frame = CGRectInset(_processingOverlay.bounds,
                                           -_processingOverlay.bounds.size.width, 0);
    _waveGradientLayer.startPoint = CGPointMake(0.0, 0.5);
    _waveGradientLayer.endPoint = CGPointMake(1.0, 0.5);
    _waveGradientLayer.colors = @[
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor colorWithRed:0.00 green:0.95 blue:0.74 alpha:0.06].CGColor,
        (id)[UIColor colorWithRed:0.20 green:0.45 blue:1.00 alpha:0.34].CGColor,
        (id)[UIColor colorWithRed:0.00 green:0.95 blue:0.74 alpha:0.06].CGColor,
        (id)[UIColor clearColor].CGColor
    ];
    _waveGradientLayer.locations = @[@0.0, @0.30, @0.50, @0.70, @1.0];
    _waveGradientLayer.compositingFilter = @"screenBlendMode";
    [_processingOverlay.layer addSublayer:_waveGradientLayer];

    CABasicAnimation *wave = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    wave.fromValue = @(-_processingOverlay.bounds.size.width);
    wave.toValue = @(_processingOverlay.bounds.size.width);
    wave.duration = 1.65;
    wave.repeatCount = HUGE_VALF;
    wave.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_waveGradientLayer addAnimation:wave forKey:@"ez.ai.wave"];

    [UIView animateWithDuration:0.45 animations:^{
        self->_processingBlurView.alpha = 0.90;
        self->_imageView.transform = CGAffineTransformMakeScale(1.025, 1.025);
    }];

    [UIView animateWithDuration:1.05
                          delay:0.45
                        options:UIViewAnimationOptionAutoreverse |
                                UIViewAnimationOptionRepeat |
                                UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self->_imageView.transform = CGAffineTransformMakeScale(1.055, 1.055);
        self->_processingOverlay.alpha = 0.78;
    } completion:nil];
}

- (void)layoutProcessingOverlay {
    if (!_processingOverlay) return;
    _processingOverlay.frame = _imageView.bounds;
    _processingBlurView.frame = _processingOverlay.bounds;
    _waveGradientLayer.frame = CGRectInset(_processingOverlay.bounds,
                                           -_processingOverlay.bounds.size.width, 0);
}

- (void)stopProcessingAnimationWithCompletion:(void (^)(void))completion {
    [_processingOverlay.layer removeAllAnimations];
    [_waveGradientLayer removeAllAnimations];

    [UIView animateWithDuration:0.34 animations:^{
        self->_processingOverlay.alpha = 0.0;
        self->_imageView.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [self->_processingOverlay removeFromSuperview];
        self->_processingOverlay = nil;
        self->_processingBlurView = nil;
        self->_waveGradientLayer = nil;
        if (completion) completion();
    }];
}

- (void)finishImageEditWithImage:(UIImage *)editedImage error:(NSString *)errorMessage {
    [self setImageEditing:NO];

    if (errorMessage.length > 0 || !editedImage) {
        [self stopProcessingAnimationWithCompletion:nil];
        [self showImageEditError:errorMessage ?: @"The image edit did not return an image."];
        return;
    }

    [self stopProcessingAnimationWithCompletion:^{
        self.image = editedImage;
        [UIView transitionWithView:self->_imageView
                          duration:0.42
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionCurveEaseInOut
                        animations:^{
            self->_imageView.image = editedImage;
        } completion:nil];

        NSData *savedData = [self PNGDataForImage:editedImage];
        if (savedData.length > 0 && self.filePath.length > 0) {
            [savedData writeToFile:self.filePath atomically:YES];
        }

        [self.view setNeedsLayout];
    }];
}

- (void)showImageEditError:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Image Edit"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [_imageEditTask cancel];
        _imageEditTask = nil;
    }
}

- (UIButton *)makeButtonTitle:(NSString *)title icon:(NSString *)iconName''',
        "AI editor methods insertion point",
    )

    source = require_replace(
        source,
        '''- (void)editTapped {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EZEditImageInChat
                      object:nil
                    userInfo:@{ @"image": self.image, @"editMode": @YES }];
    [self dismissAllTheWay];
}

''',
        "",
        "old editTapped action",
    )

    path.write_text(source, encoding="utf-8")
    print(f"Patched: {path}")
    print(f"Backup:  {backup}")
    print("")
    print("Next: add an OpenAIAPIKey String entry to Info.plist, then clean/build the app.")


if __name__ == "__main__":
    main()