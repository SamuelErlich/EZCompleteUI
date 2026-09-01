// EZInsuranceDateUtils.m
// EZCompleteUI

#import "EZInsuranceDateUtils.h"

@implementation EZInsuranceDateUtils

+ (nullable NSDate *)dateFromPostgRESTString:(nullable NSString *)string {
    if (!string.length) return nil;

    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                   NSISO8601DateFormatWithFractionalSeconds;
    });

    // Postgres sends 6 fractional digits (microseconds); NSISO8601DateFormatter
    // only accepts 0 or 3 (milliseconds). Truncate to 3 before parsing —
    // without this, every single timestamp from the database fails to
    // parse and silently returns nil.
    NSString *normalized = string;
    NSRange dotRange = [string rangeOfString:@"."];
    if (dotRange.location != NSNotFound) {
        NSUInteger fractionStart = dotRange.location + 1;
        NSUInteger fractionDigits = 0;
        while (fractionStart + fractionDigits < string.length &&
               isdigit([string characterAtIndex:fractionStart + fractionDigits])) {
            fractionDigits++;
        }
        if (fractionDigits > 3) {
            NSString *prefix = [string substringToIndex:fractionStart + 3];
            NSString *suffix = [string substringFromIndex:fractionStart + fractionDigits];
            normalized = [prefix stringByAppendingString:suffix];
        }
    }

    NSDate *parsed = [formatter dateFromString:normalized];
    if (parsed) return parsed;

    // Fall back to no-fractional-seconds in case a timestamp ever comes
    // back without them (shouldn't happen from Postgres, but cheap to
    // guard against rather than showing a blank countdown).
    static NSISO8601DateFormatter *plainFormatter;
    static dispatch_once_t plainOnceToken;
    dispatch_once(&plainOnceToken, ^{
        plainFormatter = [[NSISO8601DateFormatter alloc] init];
        plainFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [plainFormatter dateFromString:normalized];
}

+ (NSDate *)deadlineFromLastCheckinAt:(NSDate *)lastCheckinAt frequencyHours:(NSInteger)frequencyHours {
    return [lastCheckinAt dateByAddingTimeInterval:frequencyHours * 3600.0];
}

+ (NSString *)countdownStringFromNowUntilDeadline:(NSDate *)deadline {
    NSTimeInterval remaining = [deadline timeIntervalSinceNow];
    if (remaining <= 0) return @"Overdue — release pending";

    NSInteger totalSeconds = (NSInteger)remaining;
    NSInteger days    = totalSeconds / 86400;
    NSInteger hours    = (totalSeconds % 86400) / 3600;
    NSInteger minutes  = (totalSeconds % 3600) / 60;
    NSInteger seconds  = totalSeconds % 60;

    if (days > 0)  return [NSString stringWithFormat:@"%ldd %ldh %ldm", (long)days, (long)hours, (long)minutes];
    if (hours > 0) return [NSString stringWithFormat:@"%ldh %ldm %02lds", (long)hours, (long)minutes, (long)seconds];
    return [NSString stringWithFormat:@"%ldm %02lds", (long)minutes, (long)seconds];
}

@end
