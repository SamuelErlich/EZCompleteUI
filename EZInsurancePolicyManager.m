// EZInsurancePolicyManager.m
// EZCompleteUI

#import "EZInsurancePolicyManager.h"
#import "EZAuthManager.h"
#import "EZSupabaseConfig.h"
#import "helpers.h" // EZLog/EZLogf — same logging macros used throughout the rest of the app
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <UIKit/UIKit.h> // UIImage/UIImageJPEGRepresentation, for thumbnail encoding

static NSString *const kInsuranceBucket = @"insurance-policy-files";
static const long long kMaxFileSizeBytes = 36700160; // 35MB — must match insurance_policy_schema.sql

@interface EZInsurancePolicyManager () <NSURLSessionTaskDelegate>

// Dedicated session for uploads so progress delegate callbacks only ever
// concern this class — never shares a session with unrelated networking
// elsewhere in the app.
@property (nonatomic, strong) NSURLSession *uploadSession;

// Maps NSURLSessionTask.taskIdentifier -> copied progress block, so the
// delegate callback (which only gets the task) can find the right block.
// Guarded by ez_taskLock since delegate callbacks land on a background
// queue, not necessarily the main queue.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, EZInsuranceUploadProgress> *progressHandlers;
@property (nonatomic, strong) NSLock *taskLock;

@end

@implementation EZInsurancePolicyManager

+ (instancetype)shared {
    static EZInsurancePolicyManager *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sharedInstance = [[self alloc] init]; });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _progressHandlers = [NSMutableDictionary dictionary];
        _taskLock = [[NSLock alloc] init];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest  = 180; // generous — files run up to 35MB
        config.timeoutIntervalForResource = 300;
        _uploadSession = [NSURLSession sessionWithConfiguration:config
                                                        delegate:self
                                                   delegateQueue:nil];
    }
    return self;
}

// ── Auth helper ───────────────────────────────────────────────────────────
// Every call in this file goes through here rather than reading
// [EZAuthManager shared].accessToken directly, so token refresh is always
// handled and no caller has to think about it. (This is the pattern
// EZAuthManager.h itself documents as correct — some existing code in the
// app reads the raw property instead, which is a latent bug worth fixing
// separately; not touched here since it's outside this feature's files.)

- (void)ez_requireAccessToken:(void (^)(NSString * _Nullable token,
                                         NSString * _Nullable errorMessage))handler {
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *error) {
        if (!token.length) {
            handler(nil, @"Your session expired. Please sign in again.");
            return;
        }
        handler(token, nil);
    }];
}

// ── Generic REST/RPC request ─────────────────────────────────────────────
// path is relative, e.g. "/rest/v1/insurance_policies" or
// "/rest/v1/rpc/checkin_insurance_policy". Handles auth, JSON encoding/
// decoding, and turns non-2xx responses into a friendly error message
// pulled from whatever PostgREST/Edge Function sent back.

- (void)ez_requestWithMethod:(NSString *)method
                          path:(NSString *)path
                   queryItems:(nullable NSArray<NSURLQueryItem *> *)queryItems
                     jsonBody:(nullable id)jsonBody
                 extraHeaders:(nullable NSDictionary<NSString *, NSString *> *)extraHeaders
                   completion:(void (^)(id _Nullable json,
                                        NSInteger statusCode,
                                        NSString * _Nullable errorMessage))completion {
    [self ez_requireAccessToken:^(NSString *token, NSString *authError) {
        if (authError) { completion(nil, 0, authError); return; }

        NSURLComponents *components = [NSURLComponents componentsWithString:
            [EZSupabaseURL stringByAppendingString:path]];
        if (queryItems.count) components.queryItems = queryItems;

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
        request.HTTPMethod      = method;
        // 30s, not 20 — a Supabase free-tier project that's been idle can
        // take 10-30+s to wake back up on its first request. A client-side
        // timeout that's too short causes exactly the confusing "it failed
        // but actually worked" symptom: Postgres/PostgREST keeps processing
        // the request and commits it even though this NSURLSession task has
        // already given up waiting for the response.
        request.timeoutInterval = 30;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
        for (NSString *key in extraHeaders) {
            [request setValue:extraHeaders[key] forHTTPHeaderField:key];
        }

        if (jsonBody) {
            request.HTTPBody = [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:nil];
        }

        [[self.uploadSession dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (networkError) {
                    EZLogf(EZLogLevelError, @"INSURANCE",
                           @"%@ %@ network error: %@ (domain=%@ code=%ld)",
                           method, path, networkError.localizedDescription,
                           networkError.domain, (long)networkError.code);
                    completion(nil, 0, @"Network error. Check your connection and try again.");
                    return;
                }

                NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                id json = nil;
                if (data.length) {
                    // NSJSONReadingAllowFragments is NOT optional here — PostgREST
                    // returns scalar RPC results (booleans from checkin/cancel/
                    // claim, a bare quoted uuid string from create) as a raw
                    // top-level JSON value, not wrapped in {} or []. Without this
                    // option, NSJSONSerialization refuses to parse a bare
                    // fragment at all and silently returns nil — which means
                    // every one of those calls would ALWAYS look like it failed
                    // to the app, even on a genuine 200 OK with the server-side
                    // action having actually succeeded. This was a real,
                    // deterministic bug, not a network-timing issue.
                    NSError *jsonParseError = nil;
                    json = [NSJSONSerialization JSONObjectWithData:data
                                                            options:NSJSONReadingAllowFragments
                                                              error:&jsonParseError];
                    if (!json && jsonParseError) {
                        EZLogf(EZLogLevelError, @"INSURANCE",
                               @"%@ %@ JSON parse failed: %@ (raw: %@)",
                               method, path, jsonParseError.localizedDescription,
                               [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                    }
                }

                if (statusCode >= 200 && statusCode < 300) {
                    completion(json, statusCode, nil);
                    return;
                }

                NSString *rawBody = data.length
                    ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                    : @"(empty body)";
                EZLogf(EZLogLevelError, @"INSURANCE",
                       @"%@ %@ -> %ld: %@", method, path, (long)statusCode, rawBody);

                completion(json, statusCode, [self ez_friendlyErrorFromJSON:json statusCode:statusCode]);
            });
        }] resume];
    }];
}

- (NSString *)ez_friendlyErrorFromJSON:(id)json statusCode:(NSInteger)statusCode {
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = json;
        NSString *code    = dict[@"code"];
        NSString *message = dict[@"message"] ?: dict[@"error"];

        // Unique-violation. The only unique constraint left in this
        // feature's schema is (policy_id, email) on
        // insurance_policy_recipients — if that ever changes, this message
        // needs to change with it.
        if ([code isEqualToString:@"23505"]) {
            return @"That recipient is already on this policy.";
        }
        if (message.length) return message;
    }
    if (statusCode == 401) return @"Your session expired. Please sign in again.";
    return @"Something went wrong. Please try again.";
}

// ── Policy lifecycle ──────────────────────────────────────────────────────

- (void)createPolicyWithPassword:(NSString *)password
                   frequencyHours:(NSInteger)frequencyHours
                   clientRequestID:(NSString *)clientRequestID
                       completion:(void (^)(NSString * _Nullable, NSString * _Nullable))completion {
    NSDictionary *body = @{
        @"p_password":          password ?: @"",
        @"p_frequency_hours":   @(frequencyHours),
        @"p_client_request_id": clientRequestID ?: [NSNull null],
    };

    [self ez_requestWithMethod:@"POST"
                           path:@"/rest/v1/rpc/create_insurance_policy"
                     queryItems:nil
                       jsonBody:body
                   extraHeaders:nil
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        if (errorMessage) { completion(nil, errorMessage); return; }
        // PostgREST RPC returning a scalar (uuid) sends the raw JSON value,
        // e.g. "3fa8...c21" — not wrapped in an object.
        NSString *policyID = [json isKindOfClass:[NSString class]] ? json : nil;
        if (!policyID.length) { completion(nil, @"Policy was not created. Please try again."); return; }
        completion(policyID, nil);
    }];
}

- (void)listPoliciesWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSString * _Nullable))completion {
    NSString *userId = [EZAuthManager shared].userId;
    if (!userId.length) { completion(nil, @"You're not signed in."); return; }

    NSArray<NSURLQueryItem *> *query = @[
        [NSURLQueryItem queryItemWithName:@"user_id" value:[@"eq." stringByAppendingString:userId]],
        [NSURLQueryItem queryItemWithName:@"select"  value:@"*"],
        [NSURLQueryItem queryItemWithName:@"order"   value:@"created_at.desc"],
    ];

    [self ez_requestWithMethod:@"GET"
                           path:@"/rest/v1/insurance_policies"
                     queryItems:query
                       jsonBody:nil
                   extraHeaders:nil
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        if (errorMessage) { completion(nil, errorMessage); return; }
        completion([json isKindOfClass:[NSArray class]] ? json : @[], nil);
    }];
}

- (void)checkInPolicyID:(NSString *)policyID
                password:(NSString *)password
              completion:(void (^)(BOOL, NSString * _Nullable))completion {
    NSDictionary *body = @{ @"p_policy_id": policyID ?: @"", @"p_password": password ?: @"" };

    [self ez_requestWithMethod:@"POST"
                           path:@"/rest/v1/rpc/checkin_insurance_policy"
                     queryItems:nil
                       jsonBody:body
                   extraHeaders:nil
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        if (errorMessage) { completion(NO, errorMessage); return; }
        BOOL success = [json isKindOfClass:[NSNumber class]] && [(NSNumber *)json boolValue];
        completion(success, success ? nil : @"Incorrect password, or this policy is no longer active.");
    }];
}

- (void)cancelPolicyID:(NSString *)policyID
                password:(NSString *)password
              completion:(void (^)(BOOL, NSString * _Nullable))completion {
    NSDictionary *body = @{ @"p_policy_id": policyID ?: @"", @"p_password": password ?: @"" };

    [self ez_requestWithMethod:@"POST"
                           path:@"/rest/v1/rpc/cancel_insurance_policy"
                     queryItems:nil
                       jsonBody:body
                   extraHeaders:nil
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        if (errorMessage) { completion(NO, errorMessage); return; }
        BOOL success = [json isKindOfClass:[NSNumber class]] && [(NSNumber *)json boolValue];
        completion(success, success ? nil : @"Incorrect password, or this policy is no longer active.");
    }];
}

- (void)sendNowPolicyID:(NSString *)policyID
                password:(NSString *)password
              completion:(void (^)(BOOL, NSInteger, NSInteger, NSString * _Nullable))completion {
    [self ez_requireAccessToken:^(NSString *token, NSString *authError) {
        if (authError) { completion(NO, 0, 0, authError); return; }

        NSURL *url = [NSURL URLWithString:
            [EZSupabaseURL stringByAppendingString:@"/functions/v1/insurance-send-now"]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod      = @"POST";
        request.timeoutInterval = 60; // this call sends an email server-side, give it room
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
            @"policy_id": policyID ?: @"",
            @"password":  password ?: @"",
        } options:0 error:nil];

        [[self.uploadSession dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (networkError) {
                    completion(NO, 0, 0, @"Network error. Check your connection and try again.");
                    return;
                }
                NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                NSDictionary *json = data.length
                    ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil]
                    : @{};
                NSInteger filesSent      = [json[@"filesSent"] integerValue];
                NSInteger recipientsSent = [json[@"recipientsSent"] integerValue];

                if (statusCode >= 200 && statusCode < 300) {
                    completion(YES, filesSent, recipientsSent, nil);
                } else {
                    // A 502 here means a partial send — some recipients did
                    // get the files even though this call overall reports
                    // failure. recipientsSent still reflects that; the error
                    // message from the edge function explains the split.
                    completion(NO, filesSent, recipientsSent,
                               json[@"error"] ?: @"Something went wrong. Please try again.");
                }
            });
        }] resume];
    }];
}

// ── Recipients ─────────────────────────────────────────────────────────────

- (void)addRecipientEmail:(NSString *)email
                  policyID:(NSString *)policyID
                completion:(void (^)(NSDictionary * _Nullable, NSString * _Nullable))completion {
    NSDictionary *body = @{ @"p_policy_id": policyID ?: @"", @"p_email": email ?: @"" };

    [self ez_requestWithMethod:@"POST"
                           path:@"/rest/v1/rpc/add_insurance_policy_recipient"
                     queryItems:nil
                       jsonBody:body
                   extraHeaders:nil
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        if (errorMessage) { completion(nil, errorMessage); return; }
        NSString *recipientID = [json isKindOfClass:[NSString class]] ? json : nil;
        if (!recipientID.length) { completion(nil, @"Recipient was not added. Please try again."); return; }
        completion((@{ @"id": recipientID, @"email": email ?: @"", @"sent_at": [NSNull null] }), nil);
    }];
}

- (void)listRecipientsForPolicyID:(NSString *)policyID
                        completion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSString * _Nullable))completion {
    NSArray<NSURLQueryItem *> *query = @[
        [NSURLQueryItem queryItemWithName:@"policy_id" value:[@"eq." stringByAppendingString:policyID]],
        [NSURLQueryItem queryItemWithName:@"select"    value:@"*"],
        [NSURLQueryItem queryItemWithName:@"order"     value:@"created_at.asc"],
    ];

    [self ez_requestWithMethod:@"GET"
                           path:@"/rest/v1/insurance_policy_recipients"
                     queryItems:query
                       jsonBody:nil
                   extraHeaders:nil
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        if (errorMessage) { completion(nil, errorMessage); return; }
        completion([json isKindOfClass:[NSArray class]] ? json : @[], nil);
    }];
}

- (void)deleteRecipientWithID:(NSString *)recipientID
                     policyID:(NSString *)policyID
                   completion:(void (^)(BOOL, NSString * _Nullable))completion {
    NSArray<NSURLQueryItem *> *query = @[
        [NSURLQueryItem queryItemWithName:@"id" value:[@"eq." stringByAppendingString:recipientID]],
    ];

    [self ez_requestWithMethod:@"DELETE"
                           path:@"/rest/v1/insurance_policy_recipients"
                     queryItems:query
                       jsonBody:nil
                   extraHeaders:nil
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        completion(errorMessage == nil, errorMessage);
    }];
}

// ── Files ──────────────────────────────────────────────────────────────────

- (void)uploadFileAtURL:(NSURL *)fileURL
               policyID:(NSString *)policyID
              thumbnail:(nullable UIImage *)thumbnail
               progress:(EZInsuranceUploadProgress)progress
             completion:(void (^)(NSDictionary * _Nullable, NSString * _Nullable))completion {
    NSString *userId = [EZAuthManager shared].userId;
    if (!userId.length) { completion(nil, @"You're not signed in."); return; }

    NSNumber *fileSizeNumber = nil;
    NSError *sizeError = nil;
    [fileURL getResourceValue:&fileSizeNumber forKey:NSURLFileSizeKey error:&sizeError];
    if (sizeError || !fileSizeNumber) {
        completion(nil, @"Could not read that file.");
        return;
    }
    long long fileSize = fileSizeNumber.longLongValue;
    if (fileSize > kMaxFileSizeBytes) {
        completion(nil, @"That file is over the 35MB limit.");
        return;
    }
    if (fileSize <= 0) {
        completion(nil, @"That file appears to be empty.");
        return;
    }

    NSString *originalFilename = fileURL.lastPathComponent;
    NSString *extension        = fileURL.pathExtension;
    NSString *storageFilename  = extension.length
        ? [[NSUUID UUID].UUIDString stringByAppendingPathExtension:extension]
        : [NSUUID UUID].UUIDString;
    // {user_id}/{policy_id}/{generated-name} — must match the folder shape
    // the storage RLS policies check in insurance_policy_schema.sql.
    NSString *storagePath = [NSString stringWithFormat:@"%@/%@/%@", userId, policyID, storageFilename];
    NSString *mimeType    = [self ez_mimeTypeForExtension:extension];

    // Thumbnail upload (if any) happens first, but its failure is never
    // fatal to the actual file upload — a missing thumbnail just means
    // this row falls back to a generic icon later, which is a much better
    // outcome than losing an otherwise-successful upload over it.
    [self ez_uploadThumbnailIfNeeded:thumbnail userId:userId policyID:policyID
                          completion:^(NSString *thumbnailStoragePath) {
        [self ez_uploadMainFileAtURL:fileURL storagePath:storagePath mimeType:mimeType
                             fileSize:fileSize policyID:policyID
                    originalFilename:originalFilename
                  thumbnailStoragePath:thumbnailStoragePath
                             progress:progress completion:completion];
    }];
}

- (void)ez_uploadThumbnailIfNeeded:(nullable UIImage *)thumbnail
                              userId:(NSString *)userId
                            policyID:(NSString *)policyID
                          completion:(void (^)(NSString * _Nullable thumbnailStoragePath))completion {
    if (!thumbnail) { completion(nil); return; }

    NSData *jpegData = UIImageJPEGRepresentation(thumbnail, 0.7);
    if (!jpegData.length) { completion(nil); return; }

    NSString *thumbnailPath = [NSString stringWithFormat:@"%@/%@/thumbs/%@.jpg",
        userId, policyID, [NSUUID UUID].UUIDString];

    [self ez_requireAccessToken:^(NSString *token, NSString *authError) {
        if (authError) { completion(nil); return; }

        NSString *encodedPath = [thumbnailPath stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/storage/v1/object/%@/%@",
            EZSupabaseURL, kInsuranceBucket, encodedPath]];

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [request setValue:@"image/jpeg" forHTTPHeaderField:@"Content-Type"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        request.HTTPBody = jpegData; // small (~96x96 JPEG) — a plain in-memory body is fine, no need to stream from disk like the main file upload

        [[self.uploadSession dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
            BOOL ok = !networkError && statusCode >= 200 && statusCode < 300;
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok ? thumbnailPath : nil);
            });
        }] resume];
    }];
}

- (void)ez_uploadMainFileAtURL:(NSURL *)fileURL
                     storagePath:(NSString *)storagePath
                        mimeType:(NSString *)mimeType
                        fileSize:(long long)fileSize
                        policyID:(NSString *)policyID
                originalFilename:(NSString *)originalFilename
            thumbnailStoragePath:(nullable NSString *)thumbnailStoragePath
                        progress:(EZInsuranceUploadProgress)progress
                      completion:(void (^)(NSDictionary * _Nullable, NSString * _Nullable))completion {
    [self ez_requireAccessToken:^(NSString *token, NSString *authError) {
        if (authError) { completion(nil, authError); return; }

        NSString *encodedPath = [storagePath stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/storage/v1/object/%@/%@",
            EZSupabaseURL, kInsuranceBucket, encodedPath]];

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [request setValue:mimeType forHTTPHeaderField:@"Content-Type"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];

        // __block so the completion handler below — which only runs after
        // this whole statement has finished executing — can read the real
        // taskIdentifier to clean up its own progress-handler entry. Without
        // __block, the closure would capture the pointer's value at the
        // point the block literal is built, before `task` is assigned.
        __block NSURLSessionUploadTask *task = nil;
        task = [self.uploadSession uploadTaskWithRequest:request
                                                 fromFile:fileURL
                                        completionHandler:
            ^(NSData *data, NSURLResponse *response, NSError *networkError) {
            [self ez_clearProgressHandlerForTaskIdentifier:task.taskIdentifier];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (networkError) {
                    completion(nil, @"Upload failed. Check your connection and try again.");
                    return;
                }
                NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                if (statusCode < 200 || statusCode >= 300) {
                    completion(nil, @"Upload was rejected by the server. Please try again.");
                    return;
                }

                // Storage upload succeeded — now register the metadata row.
                // If this second step fails, the blob is orphaned in storage
                // but harmless (private bucket, never listed without a
                // matching row) — surfaced to the user as a normal error so
                // they can retry rather than silently losing the file from
                // the list they see.
                [self ez_registerFileRecordWithPolicyID:policyID
                                             storagePath:storagePath
                                       originalFilename:originalFilename
                                                mimeType:mimeType
                                               sizeBytes:fileSize
                                   thumbnailStoragePath:thumbnailStoragePath
                                              completion:completion];
            });
        }];

        if (progress) {
            [self.taskLock lock];
            self.progressHandlers[@(task.taskIdentifier)] = progress;
            [self.taskLock unlock];
        }
        [task resume];
    }];
}

- (void)ez_registerFileRecordWithPolicyID:(NSString *)policyID
                                storagePath:(NSString *)storagePath
                          originalFilename:(NSString *)originalFilename
                                   mimeType:(NSString *)mimeType
                                  sizeBytes:(long long)sizeBytes
                       thumbnailStoragePath:(nullable NSString *)thumbnailStoragePath
                                 completion:(void (^)(NSDictionary * _Nullable, NSString * _Nullable))completion {
    NSMutableDictionary *row = [@{
        @"policy_id":         policyID,
        @"storage_path":      storagePath,
        @"original_filename": originalFilename,
        @"mime_type":         mimeType,
        @"size_bytes":        @(sizeBytes),
    } mutableCopy];
    row[@"thumbnail_storage_path"] = thumbnailStoragePath ?: [NSNull null];

    [self ez_requestWithMethod:@"POST"
                           path:@"/rest/v1/insurance_policy_files"
                     queryItems:nil
                       jsonBody:row
                   extraHeaders:@{@"Prefer": @"return=representation"}
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        if (errorMessage) { completion(nil, errorMessage); return; }
        NSArray *rows = [json isKindOfClass:[NSArray class]] ? json : @[];
        completion(rows.firstObject, rows.firstObject ? nil : @"Upload succeeded but could not be saved. Please try again.");
    }];
}

- (void)listFilesForPolicyID:(NSString *)policyID
                   completion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSString * _Nullable))completion {
    NSArray<NSURLQueryItem *> *query = @[
        [NSURLQueryItem queryItemWithName:@"policy_id" value:[@"eq." stringByAppendingString:policyID]],
        [NSURLQueryItem queryItemWithName:@"select"    value:@"*"],
        [NSURLQueryItem queryItemWithName:@"order"     value:@"uploaded_at.asc"],
    ];

    [self ez_requestWithMethod:@"GET"
                           path:@"/rest/v1/insurance_policy_files"
                     queryItems:query
                       jsonBody:nil
                   extraHeaders:nil
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        if (errorMessage) { completion(nil, errorMessage); return; }
        completion([json isKindOfClass:[NSArray class]] ? json : @[], nil);
    }];
}

- (void)deleteFileWithID:(NSString *)fileID
              storagePath:(NSString *)storagePath
               completion:(void (^)(BOOL, NSString * _Nullable))completion {
    // Remove the storage object first. If the row delete below fails after
    // this succeeds, the row will point at a now-missing object — the next
    // send-now/release-check would just skip it via the "signing failed,
    // skip this one file" fallback already in both edge functions, so this
    // ordering fails safe rather than leaving a phantom download link.
    [self ez_requireAccessToken:^(NSString *token, NSString *authError) {
        if (authError) { completion(NO, authError); return; }

        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/storage/v1/object/remove/%@",
            EZSupabaseURL, kInsuranceBucket]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"prefixes": @[storagePath] }
                                                             options:0 error:nil];

        [[self.uploadSession dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
            if (networkError || statusCode < 200 || statusCode >= 300) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, @"Could not delete that file. Please try again.");
                });
                return;
            }

            NSArray<NSURLQueryItem *> *query = @[
                [NSURLQueryItem queryItemWithName:@"id" value:[@"eq." stringByAppendingString:fileID]],
            ];
            [self ez_requestWithMethod:@"DELETE"
                                   path:@"/rest/v1/insurance_policy_files"
                             queryItems:query
                               jsonBody:nil
                           extraHeaders:nil
                             completion:^(id json, NSInteger rowStatus, NSString *rowError) {
                completion(rowError == nil, rowError);
            }];
        }] resume];
    }];
}

// Shared by renameFileWithID: and updateNotesForFileID: below — both are
// just "PATCH one column on one file row I own," restricted server-side
// to exactly the columns in the "Owners can edit their files while
// active" GRANT (original_filename, notes, display_order,
// thumbnail_storage_path) — see insurance_policy_schema.sql.
- (void)ez_patchFileID:(NSString *)fileID
                  field:(NSString *)field
                  value:(nullable id)value
             completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion {
    NSArray<NSURLQueryItem *> *query = @[
        [NSURLQueryItem queryItemWithName:@"id" value:[@"eq." stringByAppendingString:fileID]],
    ];
    [self ez_requestWithMethod:@"PATCH"
                           path:@"/rest/v1/insurance_policy_files"
                     queryItems:query
                       jsonBody:@{ field: value ?: [NSNull null] }
                   extraHeaders:nil
                     completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
        completion(errorMessage == nil, errorMessage);
    }];
}

- (void)renameFileWithID:(NSString *)fileID
              newFilename:(NSString *)newFilename
               completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!newFilename.length) { completion(NO, @"Filename can't be empty."); return; }
    [self ez_patchFileID:fileID field:@"original_filename" value:newFilename completion:completion];
}

- (void)updateNotesForFileID:(NSString *)fileID
                        notes:(nullable NSString *)notes
                   completion:(void (^)(BOOL, NSString * _Nullable))completion {
    [self ez_patchFileID:fileID field:@"notes" value:notes completion:completion];
}

- (void)downloadFileWithStoragePath:(NSString *)storagePath
                     originalFilename:(NSString *)originalFilename
                             mimeType:(nullable NSString *)mimeType
                          completion:(void (^)(NSURL * _Nullable, NSString * _Nullable))completion {
    // Storage RLS already lets the owner read their own objects directly
    // (see "Owners can read their own files" in insurance_policy_schema.sql)
    // — no signed URL needed here, just an authenticated GET with the
    // caller's own token, same as every other request in this class.
    [self ez_requireAccessToken:^(NSString *token, NSString *authError) {
        if (authError) { completion(nil, authError); return; }

        NSString *encodedPath = [storagePath stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/storage/v1/object/%@/%@",
            EZSupabaseURL, kInsuranceBucket, encodedPath]];

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"GET";
        request.timeoutInterval = 60; // files can be up to 35MB
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];

        [[self.uploadSession dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (networkError) {
                    completion(nil, @"Network error. Check your connection and try again.");
                    return;
                }
                NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                if (statusCode < 200 || statusCode >= 300 || data.length == 0) {
                    completion(nil, @"Could not download that file. Please try again.");
                    return;
                }

                // Named after the ORIGINAL filename, in its own unique
                // subdirectory (not just dropped in the temp root) — two
                // files with the same name shouldn't collide, and
                // QLPreviewController relies on the extension to know how
                // to render the content, so a bare temp name isn't enough.
                //
                // originalFilename is user-editable now (rename) and can
                // legitimately end up with no extension at all — QuickLook
                // then has nothing to go on and falls back to showing a
                // generic "Data" placeholder instead of the actual content.
                // If that's happened, derive a real extension from
                // mime_type (which the user can't edit and always reflects
                // what the file actually is) rather than trusting the
                // display name to also be a valid filename.
                NSString *localFilename = originalFilename;
                if (localFilename.pathExtension.length == 0 && mimeType.length) {
                    UTType *type = [UTType typeWithMIMEType:mimeType];
                    NSString *properExtension = type.preferredFilenameExtension;
                    if (properExtension.length) {
                        localFilename = [localFilename stringByAppendingPathExtension:properExtension];
                    }
                }

                NSURL *uniqueSubdir = [NSURL fileURLWithPath:
                    [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString]
                                                    isDirectory:YES];
                [[NSFileManager defaultManager] createDirectoryAtURL:uniqueSubdir
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:nil];
                NSURL *localURL = [uniqueSubdir URLByAppendingPathComponent:localFilename];

                NSError *writeError = nil;
                BOOL wrote = [data writeToURL:localURL options:NSDataWritingAtomic error:&writeError];
                if (!wrote) {
                    completion(nil, @"Could not save that file for preview.");
                    return;
                }
                completion(localURL, nil);
            });
        }] resume];
    }];
}

- (void)downloadThumbnailDataWithStoragePath:(NSString *)storagePath
                                   completion:(void (^)(NSData * _Nullable jpegData,
                                                         NSString * _Nullable errorMessage))completion {
    // Same authenticated-GET pattern as downloadFileWithStoragePath, but
    // returns raw NSData directly rather than writing to a temp file —
    // thumbnails are small (~10-20KB), no need for the disk-streaming
    // treatment the potentially-35MB main files get.
    [self ez_requireAccessToken:^(NSString *token, NSString *authError) {
        if (authError) { completion(nil, authError); return; }

        NSString *encodedPath = [storagePath stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/storage/v1/object/%@/%@",
            EZSupabaseURL, kInsuranceBucket, encodedPath]];

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"GET";
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];

        [[self.uploadSession dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                if (networkError || statusCode < 200 || statusCode >= 300 || data.length == 0) {
                    completion(nil, @"Could not load thumbnail.");
                    return;
                }
                completion(data, nil);
            });
        }] resume];
    }];
}

- (void)backfillThumbnailImage:(UIImage *)thumbnail
                       forFileID:(NSString *)fileID
                        policyID:(NSString *)policyID
                      completion:(void (^)(NSString * _Nullable thumbnailStoragePath,
                                            NSString * _Nullable errorMessage))completion {
    NSString *userId = [EZAuthManager shared].userId;
    if (!userId.length) { completion(nil, @"You're not signed in."); return; }

    // Reuses the exact same upload path uploadFileAtURL:...thumbnail:...
    // uses internally — a backfill is just this same operation happening
    // later, after the fact, instead of at original upload time.
    [self ez_uploadThumbnailIfNeeded:thumbnail userId:userId policyID:policyID
                          completion:^(NSString *thumbnailStoragePath) {
        if (!thumbnailStoragePath.length) {
            completion(nil, @"Could not save thumbnail.");
            return;
        }

        NSArray<NSURLQueryItem *> *query = @[
            [NSURLQueryItem queryItemWithName:@"id" value:[@"eq." stringByAppendingString:fileID]],
        ];
        // Column-level GRANT on the server restricts this PATCH to only
        // ever touch thumbnail_storage_path, regardless of what else this
        // request tried to send — see insurance_policy_schema.sql.
        [self ez_requestWithMethod:@"PATCH"
                               path:@"/rest/v1/insurance_policy_files"
                         queryItems:query
                           jsonBody:@{@"thumbnail_storage_path": thumbnailStoragePath}
                       extraHeaders:nil
                         completion:^(id json, NSInteger statusCode, NSString *errorMessage) {
            if (errorMessage) { completion(nil, errorMessage); return; }
            completion(thumbnailStoragePath, nil);
        }];
    }];
}

// ── Upload progress plumbing ──────────────────────────────────────────────

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    if (totalBytesExpectedToSend <= 0) return;

    [self.taskLock lock];
    EZInsuranceUploadProgress handler = self.progressHandlers[@(task.taskIdentifier)];
    [self.taskLock unlock];
    if (!handler) return;

    double fraction = (double)totalBytesSent / (double)totalBytesExpectedToSend;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(fraction); });
}

- (void)ez_clearProgressHandlerForTaskIdentifier:(NSUInteger)taskIdentifier {
    [self.taskLock lock];
    [self.progressHandlers removeObjectForKey:@(taskIdentifier)];
    [self.taskLock unlock];
}

// ── MIME helper ────────────────────────────────────────────────────────────

- (NSString *)ez_mimeTypeForExtension:(NSString *)extension {
    if (extension.length) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if (type.preferredMIMEType) return type.preferredMIMEType;
    }
    return @"application/octet-stream";
}

@end
