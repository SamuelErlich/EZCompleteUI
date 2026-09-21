// EZKeyVault.h
// EZCompleteUI
//
// Secure storage for credentials and small secrets.
//
// The vault uses the iOS Keychain directly with a device-only accessibility
// class.  A client-side encryption layer would not add protection here (the
// app would need to carry the decryption key), so there is no custom AES key
// or proprietary crypto to preserve.  The Keychain is the security boundary.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Identifier constants — use these everywhere so the strings stay in sync.
extern NSString * const EZVaultKeyOpenAI;
extern NSString * const EZVaultKeyElevenLabs;
/// Support contact address — value seeded only from EZKeyVault.m (never in open-source files).
extern NSString * const EZVaultKeySupportEmail;
extern NSString * const EZVaultKeyAccessToken;
extern NSString * const EZVaultKeyRefreshToken;
extern NSString * const EZVaultKeyUserId;
extern NSString * const EZVaultKeyLastAuthDate;


@interface EZKeyVault : NSObject

/// Save (or overwrite) a credential in a device-only Keychain item.
/// @param key        The plaintext key string to protect.
/// @param identifier One of the EZVaultKey* constants.
/// @return YES on success.
+ (BOOL)saveKey:(NSString *)key forIdentifier:(NSString *)identifier;

/// Load a previously saved credential from the Keychain.
/// @param identifier One of the EZVaultKey* constants.
/// @return The plaintext key, or nil if not found or decryption failed.
+ (nullable NSString *)loadKeyForIdentifier:(NSString *)identifier;

/// Delete a stored key entirely.
+ (BOOL)deleteKeyForIdentifier:(NSString *)identifier;

/// Returns YES if a key has been stored for the given identifier.
+ (BOOL)hasKeyForIdentifier:(NSString *)identifier;

/// Seeds a configured support contact, when one is supplied by the app build.
/// The open-source beta intentionally leaves this unset rather than inventing
/// or shipping a third-party address. Safe to call every launch.
+ (void)seedSupportEmailIfNeeded;

@end

NS_ASSUME_NONNULL_END
