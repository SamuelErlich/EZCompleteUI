// EZSupabaseConfig.h
// EZCompleteUI
//
// Purpose:
//   Single source of truth for the Supabase project URL and anon
//   (publishable) key. EZAuthManager.m and SupportRequestViewController.m
//   currently each hardcode this URL as their own private constant — if
//   the project is ever migrated, both have to be found and updated by
//   hand, and it's easy to miss one. New code (starting with
//   EZInsurancePolicyManager) should import this header instead of adding
//   a third copy of the literal. Not touching the two existing files in
//   this pass since they're outside the current feature's scope, but
//   worth folding them onto this header next time either is touched.
//
// Changes:
//   - Initial version, extracted for EZInsurancePolicyManager.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Base URL of the Supabase project, no trailing slash.
extern NSString *const EZSupabaseURL;

/// Supabase anon/publishable key. Intentionally public — safe to ship in
/// the binary, analogous to a Firebase API key. Never add the
/// service_role key here or anywhere in client code; it belongs only in
/// Edge Function secrets (see insurance-release-check).
extern NSString *const EZSupabaseAnonKey;

NS_ASSUME_NONNULL_END
