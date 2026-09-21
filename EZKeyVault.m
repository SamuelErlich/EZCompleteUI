// EZKeyVault.m
// EZCompleteUI beta
//
// All values are stored as Keychain generic-password items.  This file must
// never contain an API secret, a service-role key, or a password.  Supabase
// access and refresh tokens are credentials, not encryption keys; Keychain's
// device-only accessibility class is the appropriate storage boundary.

#import "EZKeyVault.h"
#import <Security/Security.h>

NSString * const EZVaultKeyOpenAI       = @"openai_api_key";
NSString * const EZVaultKeyElevenLabs   = @"elevenlabs_api_key";
NSString * const EZVaultKeySupportEmail = @"support_email";
NSString * const EZVaultKeyAccessToken  = @"supabase_access_token";
NSString * const EZVaultKeyRefreshToken = @"supabase_refresh_token";
NSString * const EZVaultKeyUserId      = @"supabase_user_id";
NSString * const EZVaultKeyLastAuthDate = @"supabase_last_auth_date";

static NSString *EZKeychainService(void) {
    // The beta bundle identifier is deliberate.  Do not silently fall back to
    // the original author's service, which could expose an unrelated account.
    static NSString *const kEZBetaKeychainService = @"com.gabriel.ezcomplete.beta";
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (bundleID.length && [bundleID hasPrefix:kEZBetaKeychainService]) {
        return bundleID;
    }
    return kEZBetaKeychainService;
}

static BOOL EZValidIdentifier(NSString *identifier) {
    return [identifier isKindOfClass:[NSString class]] && identifier.length > 0 &&
           identifier.length < 256 && [identifier rangeOfCharacterFromSet:
            [NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

static NSMutableDictionary *EZBaseQuery(NSString *identifier) {
    return [@{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: EZKeychainService(),
        (__bridge id)kSecAttrAccount: identifier,
    } mutableCopy];
}

@implementation EZKeyVault

+ (BOOL)saveKey:(NSString *)key forIdentifier:(NSString *)identifier {
    if (!EZValidIdentifier(identifier) || ![key isKindOfClass:[NSString class]]) return NO;
    NSData *value = [key dataUsingEncoding:NSUTF8StringEncoding];
    if (!value) return NO;

    NSMutableDictionary *query = EZBaseQuery(identifier);
    NSDictionary *attributes = @{
        (__bridge id)kSecValueData: value,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                    (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        [query addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    return status == errSecSuccess;
}

+ (NSString *)loadKeyForIdentifier:(NSString *)identifier {
    if (!EZValidIdentifier(identifier)) return nil;
    NSMutableDictionary *query = EZBaseQuery(identifier);
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    if (![data isKindOfClass:[NSData class]]) return nil;
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return value.length ? value : nil;
}

+ (BOOL)deleteKeyForIdentifier:(NSString *)identifier {
    if (!EZValidIdentifier(identifier)) return NO;
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)EZBaseQuery(identifier));
    return status == errSecSuccess || status == errSecItemNotFound;
}

+ (BOOL)hasKeyForIdentifier:(NSString *)identifier {
    if (!EZValidIdentifier(identifier)) return NO;
    NSMutableDictionary *query = EZBaseQuery(identifier);
    query[(__bridge id)kSecReturnData] = @NO;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    return SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL) == errSecSuccess;
}

+ (void)seedSupportEmailIfNeeded {
    // The beta has no support mailbox configured yet.  Leaving this empty is
    // intentional: an unset recipient fails closed in the support screen.
}

@end
