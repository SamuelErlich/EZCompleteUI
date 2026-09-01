// EZInsuranceDateUtils.h
// EZCompleteUI
//
// Purpose:
//   Small shared helpers for the Insurance Policy feature — parsing the
//   timestamptz strings PostgREST returns and formatting a "time
//   remaining" countdown from them. Pulled out into its own file because
//   both EZInsuranceLandingViewController (a mini countdown per row) and
//   EZInsurancePolicyDetailViewController (the main countdown) need
//   exactly the same logic; better one small file than two slightly-
//   different copies that drift apart over time.
//
// Changes:
//   - Initial version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZInsuranceDateUtils : NSObject

/// Parses a PostgREST timestamptz string, e.g.
/// "2026-08-08T12:34:56.123456+00:00". Handles the fact that Postgres's
/// default fractional-second precision (6 digits, microseconds) is more
/// than NSISO8601DateFormatter accepts out of the box (it wants 0 or 3) —
/// this truncates to milliseconds before parsing rather than silently
/// failing on every single timestamp that comes back from the database.
+ (nullable NSDate *)dateFromPostgRESTString:(nullable NSString *)string;

/// Human-readable countdown, e.g. "2d 4h 12m" or "38m 05s". Returns
/// "Overdue — release pending" once the deadline has passed (this can
/// briefly be true and correct: the cron release-check runs on an
/// interval, not instantly, so there's a normal few-minute window where a
/// policy is past its deadline but not yet claimed).
+ (NSString *)countdownStringFromNowUntilDeadline:(NSDate *)deadline;

/// Convenience: last_checkin_at + frequency_hours, as an NSDate.
+ (NSDate *)deadlineFromLastCheckinAt:(NSDate *)lastCheckinAt frequencyHours:(NSInteger)frequencyHours;

@end

NS_ASSUME_NONNULL_END
