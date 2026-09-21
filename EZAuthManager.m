// EZAuthManager.m
// EZCompleteUI beta
//
// Supabase Auth client for the beta backend.  This file deliberately contains
// no service-role key and no billing logic.  The anon/publishable key is read
// from EZSupabaseConfig; all authorization decisions belong to the backend.

#import "EZAuthManager.h"
#import "EZKeyVault.h"
#import "EZSupabaseConfig.h"

NSString *const EZPasswordResetReadyNotification = @"EZPasswordResetReadyNotification";
NSString *const EZAuthSessionChangedNotification  = @"EZAuthSessionChangedNotification";

// These declarations are implemented by the app's configuration layer.  They
// are kept as functions so tests and a future staging build can switch the
// project without changing this auth client.
extern BOOL EZBackendConfigured(void);
extern NSURL * _Nullable EZBackendURLForPath(NSString *path);

static NSString *const kEZTokenExpiryKey = @"supabase_access_token_expiry";
static NSString *const kEZPasswordResetRedirect = @"ezcompletebeta://password-reset";
static NSTimeInterval const kEZRefreshLeeway = 45.0;

static NSError *EZAuthError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"EZAuthManager"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Falha de autenticação."}];
}

static void EZCallMain(void (^block)(void)) {
    if (!block) return;
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static NSString *EZStringValue(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

static NSString *EZUserIDFromJSON(NSDictionary *json) {
    NSString *direct = EZStringValue(json[@"user_id"]);
    if (direct.length) return direct;
    direct = EZStringValue(json[@"id"]);
    if (direct.length) return direct;
    NSDictionary *user = [json[@"user"] isKindOfClass:[NSDictionary class]] ? json[@"user"] : nil;
    return EZStringValue(user[@"id"]);
}

static NSTimeInterval EZExpiryFromSession(NSDictionary *json) {
    NSNumber *expiresIn = [json[@"expires_in"] isKindOfClass:[NSNumber class]] ? json[@"expires_in"] : nil;
    if (expiresIn.doubleValue > 0) return NSDate.date.timeIntervalSince1970 + expiresIn.doubleValue;

    NSString *access = EZStringValue(json[@"access_token"]);
    NSArray *parts = [access componentsSeparatedByString:@"."];
    if (parts.count == 3) {
        NSString *payload = parts[1];
        NSMutableString *base64 = [payload mutableCopy];
        [base64 replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, base64.length)];
        [base64 replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, base64.length)];
        while (base64.length % 4) [base64 appendString:@"="];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
        NSDictionary *claims = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSNumber *exp = [claims[@"exp"] isKindOfClass:[NSNumber class]] ? claims[@"exp"] : nil;
        if (exp.doubleValue > 0) return exp.doubleValue;
    }
    return 0;
}

@interface EZAuthManager ()
@property (nonatomic, assign, readwrite) BOOL isInPasswordRecoveryMode;
@property (nonatomic, copy, readwrite, nullable) NSString *accessToken;
@property (nonatomic, copy, readwrite, nullable) NSString *userId;
@property (nonatomic, assign, readwrite) BOOL isLoggedIn;
@property (nonatomic, assign) BOOL refreshInFlight;
@property (nonatomic, assign) NSUInteger sessionGeneration;
@property (nonatomic, strong) NSMutableArray *refreshWaiters;
@property (nonatomic, copy, nullable) NSString *recoveryAccessToken;
@property (nonatomic, copy, nullable) NSString *recoveryRefreshToken;
@end

@implementation EZAuthManager

// Explicit synthesis is required because the accessors below add locking.
@synthesize accessToken = _accessToken;
@synthesize userId = _userId;

+ (instancetype)shared {
    static EZAuthManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [[self alloc] initPrivate]; });
    return manager;
}

- (instancetype)init {
    return [EZAuthManager shared];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _refreshWaiters = [NSMutableArray array];
        _sessionGeneration = 1;
    }
    return self;
}

- (void)dealloc {
    // Singleton is intentionally process-lifetime; no observers are retained.
}

- (BOOL)isLoggedIn {
    @synchronized (self) {
        return self.accessToken.length > 0 && self.userId.length > 0;
    }
}

- (void)setIsLoggedIn:(BOOL)value {
    // Kept only for KVC compatibility with older callers; the getter is
    // derived from the two credentials and never trusts this flag.
}

- (NSString *)accessToken {
    @synchronized (self) { return [_accessToken copy]; }
}

- (void)setAccessToken:(NSString *)token {
    @synchronized (self) { _accessToken = [token copy]; }
}

- (NSString *)userId {
    @synchronized (self) { return [_userId copy]; }
}

- (void)setUserId:(NSString *)userId {
    @synchronized (self) { _userId = [userId copy]; }
}

- (BOOL)isBackendReady:(NSError **)error {
    if (!EZBackendConfigured()) {
        if (error) *error = EZAuthError(1001, @"O servidor ainda não foi configurado. Informe a URL e a chave pública do Supabase.");
        return NO;
    }
    NSURL *url = EZBackendURLForPath(@"/auth/v1/user");
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length) {
        if (error) *error = EZAuthError(1002, @"Configuração de servidor inválida. O endereço deve usar HTTPS.");
        return NO;
    }
    return YES;
}

- (NSMutableURLRequest *)requestForPath:(NSString *)path
                                 method:(NSString *)method
                                  token:(NSString *)token
                                  error:(NSError **)error {
    if (![path isKindOfClass:[NSString class]] || !path.length || [path containsString:@"://"]) {
        if (error) *error = EZAuthError(1003, @"Endpoint de autenticação inválido.");
        return nil;
    }
    if (![self isBackendReady:error]) return nil;
    NSURL *url = EZBackendURLForPath(path);
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length) {
        if (error) *error = EZAuthError(1002, @"Endpoint do servidor inválido.");
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method.length ? method : @"GET";
    request.timeoutInterval = 25.0;
    [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
    [request setValue:@"EZCompleteUI/1" forHTTPHeaderField:@"x-client-info"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (token.length) [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    return request;
}

- (NSDictionary *)jsonDictionary:(NSData *)data {
    if (!data.length) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

- (void)saveSession:(NSDictionary *)data {
    @synchronized (self) {
    if (![data isKindOfClass:[NSDictionary class]]) return;
    NSString *access = EZStringValue(data[@"access_token"]);
    NSString *refresh = EZStringValue(data[@"refresh_token"]);
    NSString *user = EZUserIDFromJSON(data);
    if (!access.length || !refresh.length) return;

    // A session is committed as one logical unit.  If any Keychain write
    // fails, delete the partial credentials instead of leaving an unusable
    // half-session to be mistaken for a valid login at the next launch.
    BOOL ok = [EZKeyVault saveKey:access forIdentifier:EZVaultKeyAccessToken];
    ok = ok && [EZKeyVault saveKey:refresh forIdentifier:EZVaultKeyRefreshToken];
    if (user.length) ok = ok && [EZKeyVault saveKey:user forIdentifier:EZVaultKeyUserId];
    NSTimeInterval expiry = EZExpiryFromSession(data);
    if (expiry > 0) ok = ok && [EZKeyVault saveKey:[NSString stringWithFormat:@"%.0f", expiry]
                                    forIdentifier:kEZTokenExpiryKey];
    ok = ok && [EZKeyVault saveKey:[NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970]
                     forIdentifier:EZVaultKeyLastAuthDate];
    if (!ok) {
        [self clearPersistedSession];
        @synchronized (self) { self.accessToken = nil; self.userId = nil; }
        return;
    }
    @synchronized (self) {
        self.accessToken = access;
        self.userId = user.length ? user : self.userId;
    }
    }
}

- (void)clearPersistedSession {
    [EZKeyVault deleteKeyForIdentifier:EZVaultKeyAccessToken];
    [EZKeyVault deleteKeyForIdentifier:EZVaultKeyRefreshToken];
    [EZKeyVault deleteKeyForIdentifier:EZVaultKeyUserId];
    [EZKeyVault deleteKeyForIdentifier:kEZTokenExpiryKey];
    [EZKeyVault deleteKeyForIdentifier:EZVaultKeyLastAuthDate];
}

- (void)clearSessionAndNotify:(BOOL)notify {
    @synchronized (self) {
        self.sessionGeneration += 1;
        self.accessToken = nil;
        self.userId = nil;
        // Keep the generation fence and Keychain deletion atomic with respect
        // to a late refresh/sign-in response attempting to save credentials.
        [self clearPersistedSession];
    }
    if (notify) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:EZAuthSessionChangedNotification object:self];
        });
    }
}

- (void)applyPasswordResetTokens:(NSString *)accessToken refreshToken:(NSString *)refreshToken {
    if (!accessToken.length || !refreshToken.length) return;
    @synchronized (self) {
        // Recovery credentials are memory-only and never overwrite the normal
        // session. This isolates a reset link from the signed-in account.
        self.recoveryAccessToken = accessToken;
        self.recoveryRefreshToken = refreshToken;
        self.isInPasswordRecoveryMode = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:EZPasswordResetReadyNotification object:self];
    });
}

- (void)cancelPasswordReset {
    @synchronized (self) {
        self.recoveryAccessToken = nil;
        self.recoveryRefreshToken = nil;
        self.isInPasswordRecoveryMode = NO;
    }
}

- (void)sendJSONRequest:(NSMutableURLRequest *)request
                   body:(NSDictionary *)body
             completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    if (body) {
        NSError *jsonError = nil;
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
        if (jsonError) {
            EZCallMain(^{ completion(nil, nil, jsonError); });
            return;
        }
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        completion(data, http, error);
    }] resume];
}

- (NSString *)friendlyErrorFromData:(NSDictionary *)data networkError:(NSError *)error {
    if (error) {
        if (error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorNetworkConnectionLost) {
            return @"Sem conexão com a internet. Tente novamente.";
        }
        return error.localizedDescription.length ? error.localizedDescription : @"Não foi possível conectar ao servidor.";
    }
    NSString *code = EZStringValue(data[@"error_code"]) ?: EZStringValue(data[@"code"]);
    NSString *message = EZStringValue(data[@"msg"]) ?: EZStringValue(data[@"message"]);
    if ([code isEqualToString:@"invalid_credentials"] || [code isEqualToString:@"invalid_grant"]) {
        return @"E-mail ou senha incorretos.";
    }
    if ([code isEqualToString:@"email_exists"]) return @"Este e-mail já está cadastrado.";
    if ([code isEqualToString:@"weak_password"]) return @"Use uma senha mais forte, com pelo menos 8 caracteres.";
    if ([code isEqualToString:@"user_not_found"]) return @"Usuário não encontrado.";
    if (message.length) return message;
    return @"O servidor recusou a solicitação. Tente novamente.";
}

- (void)signUpWithEmail:(NSString *)email
               password:(NSString *)password
             completion:(void (^)(BOOL, NSString * _Nullable))completion {
    NSError *configError = nil;
    NSMutableURLRequest *request = [self requestForPath:@"/auth/v1/signup" method:@"POST" token:nil error:&configError];
    if (!request) { EZCallMain(^{ completion(NO, configError.localizedDescription); }); return; }
    // Never let a previous account remain active while a new account is being
    // created. This also increments generation, fencing an old refresh race.
    [self clearSessionAndNotify:NO];
    NSUInteger generation;
    @synchronized (self) { generation = self.sessionGeneration; }
    NSDictionary *body = @{ @"email": email ?: @"", @"password": password ?: @"" };
    [self sendJSONRequest:request body:body completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSDictionary *json = [self jsonDictionary:data];
        BOOL stale = NO;
        @synchronized (self) { stale = generation != self.sessionGeneration; }
        BOOL ok = !stale && !error && response.statusCode >= 200 && response.statusCode < 300;
        if (ok && EZStringValue(json[@"access_token"]).length) {
            // Keep the generation check and Keychain commit under the same
            // lock. signOut cannot interleave and then be undone by this
            // late network response.
            @synchronized (self) {
                if (generation == self.sessionGeneration) [self saveSession:json];
                else ok = NO;
            }
        }
        if (ok && EZStringValue(json[@"access_token"]).length && !self.isLoggedIn) ok = NO;
        NSString *friendly = stale ? @"A solicitação de acesso foi cancelada." : (ok ? nil : [self friendlyErrorFromData:json networkError:error]);
        EZCallMain(^{ completion(ok, friendly); });
    }];
}

- (void)signInWithEmail:(NSString *)email
               password:(NSString *)password
             completion:(void (^)(BOOL, NSString * _Nullable))completion {
    NSError *configError = nil;
    NSMutableURLRequest *request = [self requestForPath:@"/auth/v1/token?grant_type=password" method:@"POST" token:nil error:&configError];
    if (!request) { EZCallMain(^{ completion(NO, configError.localizedDescription); }); return; }
    [self clearSessionAndNotify:NO];
    NSUInteger generation;
    @synchronized (self) { generation = self.sessionGeneration; }
    NSDictionary *body = @{ @"email": email ?: @"", @"password": password ?: @"" };
    [self sendJSONRequest:request body:body completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSDictionary *json = [self jsonDictionary:data];
        BOOL stale = NO;
        @synchronized (self) { stale = generation != self.sessionGeneration; }
        BOOL ok = !stale && !error && response.statusCode >= 200 && response.statusCode < 300 &&
                  EZStringValue(json[@"access_token"]).length && EZStringValue(json[@"refresh_token"]).length;
        if (ok) {
            @synchronized (self) {
                if (generation == self.sessionGeneration) [self saveSession:json];
                else ok = NO;
            }
        }
        if (ok && !self.isLoggedIn) ok = NO;
        NSString *friendly = stale ? @"A solicitação de acesso foi cancelada." : (ok ? nil : [self friendlyErrorFromData:json networkError:error]);
        EZCallMain(^{ completion(ok, friendly); });
    }];
}

- (void)sendPasswordResetEmail:(NSString *)email completion:(void (^)(BOOL, NSString * _Nullable))completion {
    NSError *configError = nil;
    NSMutableURLRequest *request = [self requestForPath:@"/auth/v1/recover" method:@"POST" token:nil error:&configError];
    if (!request) { EZCallMain(^{ completion(NO, configError.localizedDescription); }); return; }
    NSDictionary *body = @{ @"email": email ?: @"", @"redirect_to": kEZPasswordResetRedirect };
    [self sendJSONRequest:request body:body completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSDictionary *json = [self jsonDictionary:data];
        BOOL ok = !error && response.statusCode >= 200 && response.statusCode < 300;
        EZCallMain(^{ completion(ok, ok ? nil : [self friendlyErrorFromData:json networkError:error]); });
    }];
}

- (void)setNewPassword:(NSString *)newPassword completion:(void (^)(BOOL, NSString * _Nullable))completion {
    NSString *token = nil;
    @synchronized (self) { token = [self.recoveryAccessToken copy]; }
    if (!self.isInPasswordRecoveryMode || !token.length) {
        EZCallMain(^{ completion(NO, @"O link de recuperação expirou. Solicite um novo link."); });
        return;
    }
    NSError *requestError = nil;
    NSMutableURLRequest *request = [self requestForPath:@"/auth/v1/user" method:@"PUT" token:token error:&requestError];
    if (!request) { EZCallMain(^{ completion(NO, requestError.localizedDescription); }); return; }
    [self sendJSONRequest:request body:@{ @"password": newPassword ?: @"" } completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSDictionary *json = [self jsonDictionary:data];
        BOOL ok = !error && response.statusCode >= 200 && response.statusCode < 300;
        if (ok) [self cancelPasswordReset];
        EZCallMain(^{ completion(ok, ok ? nil : [self friendlyErrorFromData:json networkError:error]); });
    }];
}

- (void)signOut {
    NSString *token = self.accessToken;
    // Fence all in-flight requests before starting the best-effort server
    // revoke. The local account is gone even if the network is offline.
    [self clearSessionAndNotify:YES];
    if (!token.length) return;
    NSError *requestError = nil;
    NSMutableURLRequest *request = [self requestForPath:@"/auth/v1/logout" method:@"POST" token:token error:&requestError];
    if (request) [self sendJSONRequest:request body:nil completion:^(__unused NSData *data, __unused NSHTTPURLResponse *response, __unused NSError *error) {}];
}

- (BOOL)tokenIsFresh {
    NSString *token = self.accessToken;
    if (!token.length) return NO;
    NSTimeInterval expiry = [EZKeyVault loadKeyForIdentifier:kEZTokenExpiryKey].doubleValue;
    if (expiry > 0) return expiry - NSDate.date.timeIntervalSince1970 > kEZRefreshLeeway;
    // A JWT without an exp claim is treated as usable for the current request;
    // the backend remains authoritative and a 401 triggers refresh.
    return YES;
}

- (void)getValidAccessToken:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    if ([self tokenIsFresh]) {
        EZCallMain(^{ completion(self.accessToken, nil); });
        return;
    }
    [self refreshSessionIfNeeded:completion];
}

- (void)refreshSessionIfNeeded:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    if (completion) {
        @synchronized (self) { [self.refreshWaiters addObject:[completion copy]]; }
    }

    NSString *refresh = [EZKeyVault loadKeyForIdentifier:EZVaultKeyRefreshToken];
    if (!refresh.length) {
        NSArray *waiters;
        @synchronized (self) {
            waiters = [self.refreshWaiters copy];
            [self.refreshWaiters removeAllObjects];
            self.refreshInFlight = NO;
        }
        NSError *error = EZAuthError(401, @"Sua sessão terminou. Entre novamente.");
        for (void (^waiter)(NSString *, NSError *) in waiters) EZCallMain(^{ waiter(nil, error); });
        return;
    }

    @synchronized (self) {
        if (self.refreshInFlight) return; // single-flight: this caller is queued above
        self.refreshInFlight = YES;
    }
    NSUInteger generation;
    @synchronized (self) { generation = self.sessionGeneration; }

    NSError *requestError = nil;
    NSMutableURLRequest *request = [self requestForPath:@"/auth/v1/token?grant_type=refresh_token" method:@"POST" token:nil error:&requestError];
    if (!request) {
        @synchronized (self) { self.refreshInFlight = NO; }
        NSArray *waiters;
        @synchronized (self) { waiters = [self.refreshWaiters copy]; [self.refreshWaiters removeAllObjects]; }
        for (void (^waiter)(NSString *, NSError *) in waiters) EZCallMain(^{ waiter(nil, requestError); });
        return;
    }
    [self sendJSONRequest:request body:@{ @"refresh_token": refresh } completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSDictionary *json = [self jsonDictionary:data];
        BOOL ok = !error && response.statusCode >= 200 && response.statusCode < 300 && EZStringValue(json[@"access_token"]).length;
        NSError *resultError = nil;
        NSString *fresh = nil;
        BOOL staleGeneration = NO;
        @synchronized (self) { staleGeneration = generation != self.sessionGeneration; }
        if (ok && !staleGeneration) {
            @synchronized (self) {
                if (generation == self.sessionGeneration) {
                    [self saveSession:json];
                    fresh = self.accessToken;
                } else {
                    staleGeneration = YES;
                }
            }
        } else if (!ok && !error && (response.statusCode == 400 || response.statusCode == 401)) {
            [self clearSessionAndNotify:YES];
        }
        if (staleGeneration) resultError = EZAuthError(409, @"A sessão foi encerrada antes da renovação terminar.");
        else if (!ok) resultError = EZAuthError(response.statusCode ?: 503, [self friendlyErrorFromData:json networkError:error]);

        NSArray *waiters;
        @synchronized (self) {
            self.refreshInFlight = NO;
            waiters = [self.refreshWaiters copy];
            [self.refreshWaiters removeAllObjects];
        }
        for (void (^waiter)(NSString *, NSError *) in waiters) {
            EZCallMain(^{ waiter(fresh, resultError); });
        }
    }];
}

- (void)validateSessionWithGeneration:(NSUInteger)generation
                           allowRefresh:(BOOL)allowRefresh
                            completion:(void (^)(BOOL, NSError * _Nullable))completion {
    NSString *token = self.accessToken;
    NSError *requestError = nil;
    NSMutableURLRequest *request = [self requestForPath:@"/auth/v1/user" method:@"GET" token:token error:&requestError];
    if (!request) { completion(NO, requestError); return; }
    [self sendJSONRequest:request body:nil completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSDictionary *json = [self jsonDictionary:data];
        BOOL ok = !error && response.statusCode >= 200 && response.statusCode < 300;
        NSUInteger nowGeneration;
        @synchronized (self) { nowGeneration = self.sessionGeneration; }
        if (generation != nowGeneration) {
            completion(NO, EZAuthError(409, @"A sessão foi encerrada durante a validação."));
            return;
        }
        if (ok) {
            NSString *uid = EZUserIDFromJSON(json);
            if (uid.length) {
                [EZKeyVault saveKey:uid forIdentifier:EZVaultKeyUserId];
                self.userId = uid;
            }
            [EZKeyVault saveKey:[NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970]
                  forIdentifier:EZVaultKeyLastAuthDate];
            completion(YES, nil);
            return;
        }
        if (allowRefresh && !error && (response.statusCode == 401 || response.statusCode == 403)) {
            [self refreshSessionIfNeeded:^(NSString *fresh, NSError *refreshError) {
                if (!fresh.length || refreshError) { completion(NO, refreshError); return; }
                [self validateSessionWithGeneration:generation allowRefresh:NO completion:completion];
            }];
            return;
        }
        if (!error && (response.statusCode == 401 || response.statusCode == 403)) [self clearSessionAndNotify:YES];
        completion(NO, EZAuthError(response.statusCode ?: 503, [self friendlyErrorFromData:json networkError:error]));
    }];
}

- (void)restoreSessionWithCompletion:(void (^)(BOOL))completion {
    NSUInteger startGeneration;
    @synchronized (self) { startGeneration = self.sessionGeneration; }
    NSString *access = [EZKeyVault loadKeyForIdentifier:EZVaultKeyAccessToken];
    NSString *refresh = [EZKeyVault loadKeyForIdentifier:EZVaultKeyRefreshToken];
    NSString *uid = [EZKeyVault loadKeyForIdentifier:EZVaultKeyUserId];
    if (!access.length || !refresh.length) {
        @synchronized (self) { self.accessToken = nil; self.userId = nil; }
        EZCallMain(^{ completion(NO); });
        return;
    }
    @synchronized (self) {
        if (startGeneration != self.sessionGeneration) {
            EZCallMain(^{ completion(NO); });
            return;
        }
        self.accessToken = access;
        self.userId = uid;
    }
    NSUInteger generation;
    @synchronized (self) { generation = self.sessionGeneration; }
    [self validateSessionWithGeneration:generation allowRefresh:YES completion:^(BOOL loggedIn, NSError *error) {
        EZCallMain(^{ completion(loggedIn && self.isLoggedIn); });
    }];
}

- (void)postToPath:(NSString *)path
              body:(NSDictionary *)body
        completion:(void (^)(NSDictionary *, NSError *))completion {
    [self getValidAccessToken:^(NSString *token, NSError *tokenError) {
        if (!token.length || tokenError) { EZCallMain(^{ completion(nil, tokenError ?: EZAuthError(401, @"Faça login para continuar.")); }); return; }
        NSError *requestError = nil;
        NSMutableURLRequest *request = [self requestForPath:path method:@"POST" token:token error:&requestError];
        if (!request) { EZCallMain(^{ completion(nil, requestError); }); return; }
        [self sendJSONRequest:request body:body completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            NSDictionary *json = [self jsonDictionary:data];
            BOOL ok = !error && response.statusCode >= 200 && response.statusCode < 300;
            NSError *result = ok ? nil : EZAuthError(response.statusCode ?: 503, [self friendlyErrorFromData:json networkError:error]);
            EZCallMain(^{ completion(ok ? json : nil, result); });
        }];
    }];
}

- (BOOL)requiresReAuthentication {
    NSString *dateString = [EZKeyVault loadKeyForIdentifier:EZVaultKeyLastAuthDate];
    NSTimeInterval timestamp = dateString.doubleValue;
    if (timestamp <= 0) return YES;
    return NSDate.date.timeIntervalSince1970 - timestamp > (7.0 * 24.0 * 60.0 * 60.0);
}

@end
