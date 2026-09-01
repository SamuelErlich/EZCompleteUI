// BRRemoteImageLoader.h
// BrainRotGame
// EZCompleteUI v1.0 — Shared Async Image Loader
//
// Purpose:
//   Minimal NSCache-backed async image loader for remote (signed Storage
//   URL) images — the Community grid's background thumbnails and, as of
//   BRGameResultViewController v2.0, a community game's preview card before
//   it's been downloaded. Extracted out of BRGamePickerViewController.m
//   (where it first lived as a private class) once a second file needed the
//   same thing — see that file's changelog. If a project-wide image-loading
//   utility already exists elsewhere that this duplicates, consolidate into
//   that instead; nothing in the files reviewed so far suggested one does.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRRemoteImageLoader : NSObject

+ (instancetype)shared;

/// Returns the in-flight NSURLSessionDataTask, or nil if the image was
/// already cached (in which case `completion` is called synchronously,
/// before this method returns) or the URL was invalid. Callers should keep
/// a *weak* reference to the returned task so cell/view reuse can cancel it.
- (nullable NSURLSessionDataTask *)loadImageFromURLString:(NSString *)urlString
                                                 completion:(void (^)(UIImage * _Nullable image))completion;

@end

NS_ASSUME_NONNULL_END
