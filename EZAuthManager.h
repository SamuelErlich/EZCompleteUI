// EZAuthManager.h
// EZCompleteUI

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const EZPasswordResetReadyNotification;

@interface EZAuthManager : NSObject

@property (nonatomic, assign, readonly) BOOL isInPasswordRecoveryMode;
@property (nonatomic, copy, readonly, nullable) NSString *accessToken;
@property (nonatomic, copy, readonly, nullable) NSString *userId;
@property (nonatomic, readonly) BOOL isLoggedIn;

+ (instancetype)shared;


- (void)applyPasswordResetTokens:(NSString *)accessToken refreshToken:(NSString *)refreshToken;
- (void)setNewPassword:(NSString *)newPassword completion:(void(^)(BOOL success, NSString * _Nullable errorMessage))completion;

- (void)cancelPasswordReset;

- (void)getValidAccessToken:(void(^)(NSString * _Nullable token, NSError * _Nullable error))completion;

- (void)sendPasswordResetEmail:(NSString *)email completion:(void(^)(BOOL success, NSString * _Nullable error))completion;

- (void)signUpWithEmail:(NSString *)email
               password:(NSString *)password
             completion:(void(^)(BOOL success, NSString * _Nullable error))completion;

- (void)signInWithEmail:(NSString *)email
               password:(NSString *)password
             completion:(void(^)(BOOL success, NSString * _Nullable error))completion;

- (void)signOut;

- (void)saveSession:(NSDictionary *)data;

- (void)postToPath:(NSString *)path
              body:(NSDictionary *)body
        completion:(void(^)(NSDictionary *data, NSError *error))completion;

- (void)restoreSessionWithCompletion:(void(^)(BOOL loggedIn))completion;

- (void)refreshSessionIfNeeded:(void(^)(NSString * _Nullable freshToken,
                                        NSError  * _Nullable error))completion;

- (NSString *)friendlyErrorFromData:(NSDictionary *)data networkError:(NSError *)error;

/// Returns YES if the user hasn't authenticated in over 7 days.
/// Check this before restoreSessionWithCompletion: and present LoginViewController if YES.
- (BOOL)requiresReAuthentication;

@end

NS_ASSUME_NONNULL_END
