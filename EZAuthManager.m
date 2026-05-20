    // EZAuthManager.m
    #import "EZAuthManager.h"
    #import "EZKeyVault.h"

    static NSString *const kSupabaseURL = @"https://spuoimtqofhbdzosrbng.supabase.co";
    static NSString *const kSupabaseAnonKey = @"sb_publishable_AzEVhLuIj1nSMwZvIgKw7A__Y3Ghdtl";
#define kAccessTokenKey  EZVaultKeyAccessToken
#define kRefreshTokenKey EZVaultKeyRefreshToken
#define kUserIdKey       EZVaultKeyUserId


    @interface EZAuthManager ()
    @property (nonatomic, copy, readwrite, nullable) NSString *accessToken;
    @property (nonatomic, copy, readwrite, nullable) NSString *userId;
    @end

    @implementation EZAuthManager

    + (instancetype)shared {
        static EZAuthManager *instance;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
        return instance;
    }

    - (BOOL)isLoggedIn {
        return self.accessToken != nil;
    }


- (void)refreshSessionIfNeeded:(void(^)(NSString *token, NSError *error))completion {
    NSString *current = self.accessToken;

    // If we have a token, check if it's still valid by decoding the exp claim.
    // JWT format: header.payload.signature — payload is base64url encoded JSON.
    if (current.length > 0) {
        NSArray *parts = [current componentsSeparatedByString:@"."];
        if (parts.count == 3) {
            NSString *payload = parts[1];
            // Base64url → base64
            NSMutableString *base64 = [payload mutableCopy];
            [base64 replaceOccurrencesOfString:@"-" withString:@"+"
                                       options:0 range:NSMakeRange(0, base64.length)];
            [base64 replaceOccurrencesOfString:@"_" withString:@"/"
                                       options:0 range:NSMakeRange(0, base64.length)];
            // Pad to multiple of 4
            while (base64.length % 4 != 0) [base64 appendString:@"="];

            NSData *decoded = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
            if (decoded) {
                NSDictionary *claims = [NSJSONSerialization
                    JSONObjectWithData:decoded options:0 error:nil];
                NSTimeInterval exp = [claims[@"exp"] doubleValue];
                // Give 60 second buffer before expiry
                if (exp > 0 && [[NSDate date] timeIntervalSince1970] < exp - 60) {
                    // Token still valid — use it directly
                    completion(current, nil);
                    return;
                }
            }
        }
    }

    // Token missing, invalid, or expired — refresh it
    NSString *refresh = [EZKeyVault loadKeyForIdentifier:kRefreshTokenKey];
    if (!refresh) {
        completion(nil, [NSError errorWithDomain:@"EZAuth" code:401
            userInfo:@{NSLocalizedDescriptionKey: @"No refresh token"}]);
        return;
    }
    NSDictionary *body = @{ @"refresh_token": refresh };
    [self postToPath:@"/auth/v1/token?grant_type=refresh_token"
                body:body
          completion:^(NSDictionary *data, NSError *error) {
        if (data[@"access_token"]) {
            self.accessToken = data[@"access_token"];
            self.userId = data[@"user"][@"id"] ?: self.userId;
            [EZKeyVault saveKey:self.accessToken forIdentifier:kAccessTokenKey];
            [EZKeyVault saveKey:data[@"refresh_token"] forIdentifier:kRefreshTokenKey];
            completion(self.accessToken, nil);
        } else {
            [self signOut];
            completion(nil, error ?: [NSError errorWithDomain:@"EZAuth" code:401
                userInfo:@{NSLocalizedDescriptionKey: @"Session expired, please sign in again"}]);
        }
    }];
}

    - (void)restoreSessionWithCompletion:(void(^)(BOOL loggedIn))completion {
        NSString *token = [EZKeyVault loadKeyForIdentifier:kAccessTokenKey];
        NSString *uid = [EZKeyVault loadKeyForIdentifier:kUserIdKey];
        NSString *refresh = [EZKeyVault loadKeyForIdentifier:kRefreshTokenKey];
        if (!token || !refresh) {
            completion(NO);
            return;
        }

        // Try to refresh the session
        NSDictionary *body = @{ @"refresh_token": refresh };
        [self postToPath:@"/auth/v1/token?grant_type=refresh_token"
                    body:body
              completion:^(NSDictionary *data, NSError *error) {
            if (data[@"access_token"]) {
                self.accessToken = data[@"access_token"];
                self.userId = data[@"user"][@"id"] ?: uid;
                [EZKeyVault saveKey:self.accessToken forIdentifier:kAccessTokenKey];
                [EZKeyVault saveKey:data[@"refresh_token"] forIdentifier:kRefreshTokenKey];
                [EZKeyVault saveKey:self.userId forIdentifier:kUserIdKey];
                completion(YES);
            } else {
                [self signOut];
                completion(NO);
            }
        }];
    }

    - (void)signUpWithEmail:(NSString *)email
                   password:(NSString *)password
                 completion:(void(^)(BOOL success, NSString * _Nullable error))completion {
        NSDictionary *body = @{ @"email": email, @"password": password };
        [self postToPath:@"/auth/v1/signup" body:body completion:^(NSDictionary *data, NSError *error) {
            if (error || data[@"error"]) {
                completion(NO, data[@"error_description"] ?: error.localizedDescription);
            } else if (data[@"access_token"]) {
                [self saveSession:data];
                completion(YES, nil);
            } else {
                // Email confirmation required
                completion(YES, nil);
            }
        }];
    }

    - (void)signInWithEmail:(NSString *)email
                   password:(NSString *)password
                 completion:(void(^)(BOOL success, NSString * _Nullable error))completion {
        NSDictionary *body = @{ @"email": email, @"password": password };
        [self postToPath:@"/auth/v1/token?grant_type=password"
                    body:body
              completion:^(NSDictionary *data, NSError *error) {
            if (error || data[@"error"]) {
                completion(NO, data[@"error_description"] ?: error.localizedDescription);
            } else if (data[@"access_token"]) {
                [self saveSession:data];
                completion(YES, nil);
            } else {
                completion(NO, @"Unknown error");
            }
        }];
    }

    - (void)signOut {
        self.accessToken = nil;
        self.userId = nil;
        [EZKeyVault deleteKeyForIdentifier:kAccessTokenKey];
        [EZKeyVault deleteKeyForIdentifier:kRefreshTokenKey];
        [EZKeyVault deleteKeyForIdentifier:kUserIdKey];    }

- (void)saveSession:(NSDictionary *)data {
    self.accessToken = data[@"access_token"];
    self.userId = data[@"user"][@"id"];
    [EZKeyVault saveKey:self.accessToken forIdentifier:kAccessTokenKey];
    [EZKeyVault saveKey:data[@"refresh_token"] forIdentifier:kRefreshTokenKey];
    [EZKeyVault saveKey:self.userId forIdentifier:kUserIdKey];
}

    - (void)postToPath:(NSString *)path
                  body:(NSDictionary *)body
            completion:(void(^)(NSDictionary *data, NSError *error))completion {
        NSURL *url = [NSURL URLWithString:[kSupabaseURL stringByAppendingString:path]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:kSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) { completion(@{}, error); return; }
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                     options:0
                                                                       error:nil];
                completion(json ?: @{}, nil);
            });
        }] resume];
    }

    @end
