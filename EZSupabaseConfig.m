// EZSupabaseConfig.m
// EZCompleteUI

#import "EZSupabaseConfig.h"

// Independent beta backend owned by Gabriel. The anon/publishable key is
// intended for client use; never place the service_role key in the app.
NSString *const EZSupabaseURL     = @"https://ygssswkgmcofkdowizeo.supabase.co";
NSString *const EZSupabaseAnonKey = @"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inlnc3Nzd2tnbWNvZmtkb3dpemVvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk5OTEwNTAsImV4cCI6MjEwNTU2NzA1MH0.KLdjhmdl6MfwOD0uwH2wSGZD-I7k9hNhX1qU2vCDXlg";

BOOL EZBackendConfigured(void) {
    return EZSupabaseURL.length > 0 &&
           [EZSupabaseURL rangeOfString:@"YOUR_PROJECT_REF"].location == NSNotFound &&
           EZSupabaseAnonKey.length > 20;
}

NSURL *EZSupabaseFunctionURL(NSString *functionName) {
    if (!EZBackendConfigured() || functionName.length == 0) return nil;
    NSString *encoded = [functionName stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLPathAllowedCharacterSet]];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/functions/v1/%@",
                                 EZSupabaseURL, encoded ?: functionName]];
}

NSURL *EZBackendURLForPath(NSString *path) {
    if (!EZBackendConfigured() || path.length == 0 || [path containsString:@"://"]) return nil;
    NSString *normalized = [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path];
    return [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:normalized]];
}
