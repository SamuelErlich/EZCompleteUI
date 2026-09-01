// BRRemoteImageLoader.m
// BrainRotGame
// EZCompleteUI v1.0 — Shared Async Image Loader
//
// Purpose:
//   Implementation of BRRemoteImageLoader. See the header for the public
//   contract and why this file exists as a standalone class.

#import "BRRemoteImageLoader.h"

@implementation BRRemoteImageLoader {
    NSCache<NSString *, UIImage *> *_cache;
}

+ (instancetype)shared {
    static BRRemoteImageLoader *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [BRRemoteImageLoader new]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 200; // grid/preview thumbnails only; plenty for a browse session
    }
    return self;
}

- (nullable NSURLSessionDataTask *)loadImageFromURLString:(NSString *)urlString
                                                 completion:(void (^)(UIImage * _Nullable image))completion {
    if (urlString.length == 0) { completion(nil); return nil; }

    UIImage *cached = [_cache objectForKey:urlString];
    if (cached) { completion(cached); return nil; }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { completion(nil); return nil; }

    // Self is a long-lived singleton (never deallocates), so capturing it
    // strongly here is harmless and avoids an unnecessary weak/strong dance
    // for ivar access inside the completion block.
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                                completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        if (image) [self->_cache setObject:image forKey:urlString];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
    }];
    [task resume];
    return task;
}

@end
