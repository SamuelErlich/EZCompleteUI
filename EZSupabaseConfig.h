// EZSupabaseConfig.h
// EZCompleteUI
//
// Single source of truth for the new beta Supabase project. The checked-in
// values are safe placeholders until a project is created and configured.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Base URL of the Supabase project, no trailing slash.
extern NSString *const EZSupabaseURL;

/// Supabase anon/publishable key. Intentionally public — safe to ship in
/// the binary, analogous to a Firebase API key. Never add the
/// service_role key here or anywhere in client code; it belongs only in
/// Edge Function secrets (see supabase/README.md).
extern NSString *const EZSupabaseAnonKey;

/// Returns NO while the beta is using the safe placeholder configuration.
/// The app must fail closed instead of ever contacting the original project.
FOUNDATION_EXPORT BOOL EZBackendConfigured(void);

/// Builds a function URL from the configured project URL. Returns nil while
/// the backend is unconfigured, which keeps network calls fail-closed.
FOUNDATION_EXPORT NSURL * _Nullable EZSupabaseFunctionURL(NSString *functionName);

/// Builds an HTTPS URL for an Auth REST path such as /auth/v1/user.
FOUNDATION_EXPORT NSURL * _Nullable EZBackendURLForPath(NSString *path);

NS_ASSUME_NONNULL_END
