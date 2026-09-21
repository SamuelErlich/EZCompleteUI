// EZEntitlementManager.m
// EZCompleteUI beta
//
// The device never calculates or mutates its own wallet. Every debit, refund
// and balance value comes from the beta Supabase functions/RPCs.

#import "EZEntitlementManager.h"
#import "EZAuthManager.h"

@interface EZEntitlementManager ()
@property (nonatomic, strong, readwrite, nullable) NSNumber *coinBalance;
@property (nonatomic, copy, readwrite, nullable) NSString *currentTier;
@property (nonatomic, copy, readwrite, nullable) NSString *currentStatus;
@property (nonatomic, assign, readwrite) BOOL hasEverPurchased;
@property (nonatomic, copy, readwrite, nullable) NSString *lastLogID;
@end

static NSString *EZFeatureName(EZFeature feature) {
    switch (feature) {
        case EZFeatureChatMini: return @"chat_mini";
        case EZFeatureChatGPT4o: return @"chat_standard";
        case EZFeatureImageLow: return @"image_low";
        case EZFeatureImageMedium: return @"image_medium";
        case EZFeatureImageHigh: return @"image_high";
        case EZFeatureDalle3Standard: return @"image_dalle3";
        case EZFeatureDalle3HD: return @"image_dalle3_hd";
        case EZFeatureSora10s: return @"sora";
        case EZFeatureSoraPro10s: return @"sora_pro";
        case EZFeatureTTS500Chars: return @"tts";
        case EZFeatureVoiceClone: return @"voice_clone";
        case EZFeatureWhisperMinute: return @"whisper";
    }
    return @"unknown";
}

static NSString *EZString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSInteger EZInteger(id value) {
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

@implementation EZEntitlementManager

+ (instancetype)shared {
    static EZEntitlementManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [self new]; });
    return manager;
}

- (void)finishCheckWithData:(NSDictionary *)data
                      error:(NSError *)error
                 completion:(void (^)(BOOL, NSInteger, NSString * _Nullable))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            completion(NO, self.coinBalance.integerValue, error.localizedDescription ?: @"Servidor indisponível.");
            return;
        }
        NSInteger balance = EZInteger(data[@"balance"]);
        if (data[@"balance"] != nil) self.coinBalance = @(balance);
        NSString *logID = EZString(data[@"log_id"]);
        if (logID.length) self.lastLogID = logID;
        BOOL allowed = [data[@"allowed"] boolValue];
        NSString *reason = EZString(data[@"reason"]);
        completion(allowed, balance, reason);
    });
}

- (void)checkFeature:(EZFeature)feature
          estimated:(NSInteger)estimatedTokens
           quantity:(NSInteger)quantity
             prompt:(NSString *)prompt
              model:(NSString *)model
       featureTier:(NSString *)featureTier
            quality:(NSString *)quality
               size:(NSString *)size
             isEdit:(BOOL)isEdit
         completion:(void (^)(BOOL, NSInteger, NSString * _Nullable))completion {
    if (![EZAuthManager shared].isLoggedIn) {
        completion(NO, self.coinBalance.integerValue, @"Not logged in");
        return;
    }
    NSString *key = [NSUUID UUID].UUIDString;
    NSMutableDictionary *body = [@{
        @"feature": EZFeatureName(feature),
        @"estimated_tokens": @(MAX(0, estimatedTokens)),
        @"quantity": @(MAX(1, quantity)),
        @"idempotency_key": key,
        @"is_edit": @(isEdit)
    } mutableCopy];
    if (prompt.length) body[@"prompt_preview"] = [prompt substringToIndex:MIN(prompt.length, 500)];
    if (model.length) body[@"model"] = model;
    if (featureTier.length) body[@"feature_tier"] = featureTier;
    if (quality.length) body[@"img_quality"] = quality;
    if (size.length) body[@"img_size"] = size;

    [[EZAuthManager shared] postToPath:@"/functions/v1/check-entitlement"
                                  body:body
                            completion:^(NSDictionary *data, NSError *error) {
        [self finishCheckWithData:data error:error completion:completion];
    }];
}

- (void)checkEntitlementForFeature:(EZFeature)feature
                        completion:(void (^)(BOOL, NSInteger, NSString * _Nullable))completion {
    [self checkFeature:feature estimated:0 quantity:1 prompt:nil model:nil featureTier:nil
               quality:nil size:nil isEdit:NO completion:completion];
}

- (void)checkEntitlementForFeature:(EZFeature)feature
                          quantity:(NSInteger)quantity
                            prompt:(NSString *)prompt
                             model:(NSString *)model
                        completion:(void (^)(BOOL, NSInteger, NSString * _Nullable))completion {
    [self checkFeature:feature estimated:0 quantity:quantity prompt:prompt model:model featureTier:nil
               quality:nil size:nil isEdit:NO completion:completion];
}

- (void)checkEntitlementForFeature:(EZFeature)feature
                   estimatedTokens:(NSInteger)estimatedTokens
                        featureTier:(NSString *)featureTier
                             prompt:(NSString *)prompt
                              model:(NSString *)model
                         completion:(void (^)(BOOL, NSInteger, NSString * _Nullable))completion {
    [self checkFeature:feature estimated:estimatedTokens quantity:1 prompt:prompt model:model
           featureTier:featureTier quality:nil size:nil isEdit:NO completion:completion];
}

- (void)checkEntitlementForFeature:(EZFeature)feature
                   estimatedTokens:(NSInteger)estimatedTokens
                        featureTier:(NSString *)featureTier
                         completion:(void (^)(BOOL, NSInteger, NSString * _Nullable))completion {
    [self checkEntitlementForFeature:feature estimatedTokens:estimatedTokens featureTier:featureTier
                              prompt:nil model:nil completion:completion];
}

- (void)checkEntitlementForFeature:(EZFeature)feature
                          quantity:(NSInteger)quantity
                            prompt:(NSString *)prompt
                             model:(NSString *)model
                           quality:(NSString *)quality
                              size:(NSString *)size
                            isEdit:(BOOL)isEdit
                        completion:(void (^)(BOOL, NSInteger, NSString * _Nullable))completion {
    [self checkFeature:feature estimated:0 quantity:quantity prompt:prompt model:model featureTier:nil
               quality:quality size:size isEdit:isEdit completion:completion];
}

- (void)completeUsageLogWithImagesReturned:(NSInteger)imagesReturned errorText:(NSString *)errorText {
    NSString *logID = self.lastLogID;
    if (!logID.length) return;
    NSDictionary *body = @{@"log_id":logID, @"success":@(errorText.length == 0),
                           @"images_returned":@(MAX(0, imagesReturned)),
                           @"error":errorText ?: @""};
    [[EZAuthManager shared] postToPath:@"/functions/v1/usage-complete" body:body completion:^(__unused NSDictionary *data, __unused NSError *error) {}];
}

- (void)refundTokensForTier:(NSString *)tier estimatedTokens:(NSInteger)estimatedTokens
                actualTokens:(NSInteger)actualTokens inputTokens:(NSInteger)inputTokens
               outputTokens:(NSInteger)outputTokens {
    NSString *logID = self.lastLogID;
    if (!logID.length) return;
    NSDictionary *body = @{@"log_id":logID, @"reason":@"provider_usage_adjustment",
                           @"tier":tier ?: @"", @"estimated_tokens":@(estimatedTokens),
                           @"actual_tokens":@(actualTokens), @"input_tokens":@(inputTokens),
                           @"output_tokens":@(outputTokens)};
    [[EZAuthManager shared] postToPath:@"/functions/v1/usage-refund" body:body completion:^(__unused NSDictionary *data, __unused NSError *error) {}];
}

- (void)refundTokensForTier:(NSString *)tier estimatedTokens:(NSInteger)estimatedTokens actualTokens:(NSInteger)actualTokens {
    [self refundTokensForTier:tier estimatedTokens:estimatedTokens actualTokens:actualTokens
                  inputTokens:(NSInteger)round(actualTokens * 0.7)
                 outputTokens:(NSInteger)round(actualTokens * 0.3)];
}

- (void)applyKnownBalance:(NSInteger)balance {
    self.coinBalance = @(MAX(0, balance));
}

- (void)refreshBalanceWithCompletion:(void (^)(NSInteger))completion {
    if (![EZAuthManager shared].isLoggedIn) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(self.coinBalance.integerValue); });
        return;
    }
    [[EZAuthManager shared] postToPath:@"/functions/v1/wallet" body:@{} completion:^(NSDictionary *data, NSError *error) {
        if (!error && data) {
            if (data[@"balance"]) self.coinBalance = @(EZInteger(data[@"balance"]));
            self.currentTier = EZString(data[@"tier"]) ?: self.currentTier;
            self.currentStatus = EZString(data[@"status"]) ?: self.currentStatus;
            self.hasEverPurchased = [data[@"has_ever_purchased"] boolValue];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(self.coinBalance.integerValue); });
    }];
}

- (void)refreshSubscriptionStatusWithCompletion:(void (^)(BOOL, NSInteger))completion {
    if (![EZAuthManager shared].isLoggedIn) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, self.coinBalance.integerValue); });
        return;
    }
    [[EZAuthManager shared] postToPath:@"/functions/v1/wallet" body:@{} completion:^(NSDictionary *data, NSError *error) {
        BOOL refreshed = !error && data != nil;
        if (refreshed) {
            self.coinBalance = @(EZInteger(data[@"balance"]));
            self.currentTier = EZString(data[@"tier"]);
            self.currentStatus = EZString(data[@"status"]);
            self.hasEverPurchased = [data[@"has_ever_purchased"] boolValue];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(refreshed, self.coinBalance.integerValue); });
    }];
}

@end
