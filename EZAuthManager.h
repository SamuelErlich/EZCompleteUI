// EZAuthManager.h
// EZCompleteUI

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZAuthManager : NSObject

@property (nonatomic, copy, readonly, nullable) NSString *accessToken;
@property (nonatomic, copy, readonly, nullable) NSString *userId;
@property (nonatomic, readonly) BOOL isLoggedIn;

+ (instancetype)shared;

- (void)signUpWithEmail:(NSString *)email
               password:(NSString *)password
             completion:(void(^)(BOOL success, NSString * _Nullable error))completion;

- (void)signInWithEmail:(NSString *)email
               password:(NSString *)password
             completion:(void(^)(BOOL success, NSString * _Nullable error))completion;

- (void)signOut;

- (void)restoreSessionWithCompletion:(void(^)(BOOL loggedIn))completion;

- (void)refreshSessionIfNeeded:(void(^)(NSString * _Nullable freshToken,
                                        NSError  * _Nullable error))completion;

/// Returns YES if the user hasn't authenticated in over 7 days.
/// Check this before restoreSessionWithCompletion: and present LoginViewController if YES.
- (BOOL)requiresReAuthentication;

@end

NS_ASSUME_NONNULL_END
