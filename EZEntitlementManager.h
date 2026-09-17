// EZEntitlementManager.h
// EZCompleteUI

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EZFeature) {
    EZFeatureChatMini,
    EZFeatureChatGPT4o,
    EZFeatureImageLow,
    EZFeatureImageMedium,
    EZFeatureImageHigh,
    EZFeatureDalle3Standard,
    EZFeatureDalle3HD,
    EZFeatureSora10s,
    EZFeatureSoraPro10s,
    EZFeatureTTS500Chars,
    EZFeatureVoiceClone,
    EZFeatureWhisperMinute,
};

@interface EZEntitlementManager : NSObject

/// nil until the first successful server response.
/// Use integerValue to read the balance, and always check for nil before displaying.
@property (nonatomic, readonly, nullable) NSNumber *coinBalance;

/// nil until the first successful server response.
/// Always check for nil or compare with a known tier string before displaying.
@property (nonatomic, readonly, nullable) NSString *currentTier;

/// nil until the first successful server response.
/// Known values: "active", "cancelled", "suspended", "expired", "coins_only".
/// Always check for nil before comparing.
@property (nonatomic, readonly, nullable) NSString *currentStatus;

/// Whether the account has completed any paid purchase. This remains YES after
/// a subscription expires or is cancelled.
@property (nonatomic, readonly) BOOL hasEverPurchased;

/// The ez_usage_log row ID returned by the last successful check call.
/// Automatically used by completeUsageLog: and refundTokensForTier:
/// so actual API results get written back to the log row.
@property (nonatomic, readonly, nullable) NSString *lastLogID;

+ (instancetype)shared;

// ── Flat-rate checks ──────────────────────────────────────────────────────────

/// Basic flat-rate check — no metadata.
- (void)checkEntitlementForFeature:(EZFeature)feature
                        completion:(void(^)(BOOL allowed,
                                           NSInteger balance,
                                           NSString * _Nullable reason))completion;

/// Quantity-aware flat-rate check with usage metadata.
/// prompt (first 500 chars) and model stored in ez_usage_log.
- (void)checkEntitlementForFeature:(EZFeature)feature
                          quantity:(NSInteger)quantity
                            prompt:(nullable NSString *)prompt
                             model:(nullable NSString *)model
                        completion:(void(^)(BOOL allowed,
                                           NSInteger balance,
                                           NSString * _Nullable reason))completion;

// ── Token-based checks ────────────────────────────────────────────────────────

/// Full token-based check with usage metadata — preferred for chat.
- (void)checkEntitlementForFeature:(EZFeature)feature
                   estimatedTokens:(NSInteger)estimatedTokens
                        featureTier:(NSString *)featureTier
                             prompt:(nullable NSString *)prompt
                              model:(nullable NSString *)model
                         completion:(void(^)(BOOL allowed,
                                            NSInteger balance,
                                            NSString * _Nullable reason))completion;

/// Legacy token-based check — no metadata.
- (void)checkEntitlementForFeature:(EZFeature)feature
                   estimatedTokens:(NSInteger)estimatedTokens
                        featureTier:(NSString *)featureTier
                         completion:(void(^)(BOOL allowed,
                                            NSInteger balance,
                                            NSString * _Nullable reason))completion;

/// Quantity-aware flat-rate check with quality/size/edit metadata — used
/// for images, where quality and size materially change the real cost.
/// quality/size are sent to check-entitlement as img_quality/img_size
/// (see that action's own code) — pass nil for non-image features, which
/// still works correctly via the estimator's own fallback. isEdit affects
/// the cost estimate for image edits specifically (adds reference-image
/// input token cost on top of the base per-image fee).
- (void)checkEntitlementForFeature:(EZFeature)feature
                          quantity:(NSInteger)quantity
                            prompt:(nullable NSString *)prompt
                             model:(nullable NSString *)model
                           quality:(nullable NSString *)quality
                              size:(nullable NSString *)size
                            isEdit:(BOOL)isEdit
                        completion:(void(^)(BOOL allowed,
                                           NSInteger balance,
                                           NSString * _Nullable reason))completion;
// ── Post-completion updates ───────────────────────────────────────────────────

/// Call after image/sora API returns. Uses lastLogID automatically.
/// imagesReturned = 0 for non-image. errorText = nil on success.
- (void)completeUsageLogWithImagesReturned:(NSInteger)imagesReturned
                                 errorText:(nullable NSString *)errorText;

/// Full refund with actual token split — computes precise api_cost_usd.
- (void)refundTokensForTier:(nullable NSString *)tier
            estimatedTokens:(NSInteger)estimatedTokens
               actualTokens:(NSInteger)actualTokens
               inputTokens:(NSInteger)inputTokens
              outputTokens:(NSInteger)outputTokens;

/// Legacy refund — estimates 70/30 input/output split.
- (void)refundTokensForTier:(nullable NSString *)tier
            estimatedTokens:(NSInteger)estimatedTokens
               actualTokens:(NSInteger)actualTokens;

/// Directly apply a known-good balance from a server response.
/// Use only when you have a trusted balance value (e.g. capture-paypal-order response)
/// and want to avoid a racing refreshBalance call overwriting it.
- (void)applyKnownBalance:(NSInteger)balance;

/// Read-only balance refresh — no coin deduction.
- (void)refreshBalanceWithCompletion:(void(^)(NSInteger balance))completion;

/// Refreshes subscription state without deducting coins. `refreshed` is NO
/// when the server could not confirm the user's current tier and status.
- (void)refreshSubscriptionStatusWithCompletion:(void(^)(BOOL refreshed,
                                                         NSInteger balance))completion;

@end

NS_ASSUME_NONNULL_END
