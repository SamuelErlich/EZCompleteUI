//
//  EZTTSManifestEntry.h
//  EZTTSLibrary
//
//  Model object representing a single archived TTS clip inside Manifest.json.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A single entry in the TTS library manifest. One instance == one archived audio clip
/// on disk, plus the metadata needed to list, search, and replay it.
///
/// Conforms to NSSecureCoding so it can be safely archived/unarchived if ever cached
/// in memory (e.g. NSCache, drag-and-drop pasteboard payloads for the future timeline
/// editor). The canonical on-disk representation is JSON via Manifest.json, produced by
/// -dictionaryRepresentation / +entryWithDictionary:.
@interface EZTTSManifestEntry : NSObject <NSSecureCoding, NSCopying>

/// Stable unique identifier for this clip. Generated once at save time, never reused.
@property (nonatomic, copy) NSString *uuid;

/// Creation timestamp (UTC). This is what "sorted by creation date" sorts on.
@property (nonatomic, strong) NSDate *created;

/// Generation backend that produced this clip, e.g. "elevenlabs", "openai", "apple", "kokoro".
/// Free-form string rather than an enum so new providers never require a manifest migration.
@property (nonatomic, copy) NSString *provider;

/// Human-readable voice name at time of generation (voices can be renamed/deleted upstream,
/// so this is a snapshot, not a live lookup).
@property (nonatomic, copy, nullable) NSString *voiceName;

/// Provider-specific voice identifier used for the request.
@property (nonatomic, copy, nullable) NSString *voiceID;

/// Provider-specific model identifier used for the request (e.g. "eleven_multilingual_v2").
@property (nonatomic, copy, nullable) NSString *model;

/// Full text that was synthesized.
@property (nonatomic, copy) NSString *prompt;

/// Short preview/snippet of the prompt, precomputed for fast list-cell rendering
/// without truncating `prompt` on the main thread repeatedly.
@property (nonatomic, copy, nullable) NSString *preview;

/// Filename on disk, e.g. "tts_1751567890_ABCDEF12.wav". Lives under Audio/.
@property (nonatomic, copy) NSString *filename;

/// Path relative to the TTSLibrary/ root, e.g. "Audio/tts_1751567890_ABCDEF12.wav".
/// Stored (not just derived) so the manifest stays portable if the folder layout
/// gains subdirectories later (e.g. per-provider or per-month folders).
@property (nonatomic, copy) NSString *relativePath;

/// Duration in seconds, as measured via AVFoundation at save time.
@property (nonatomic, assign) double duration;

/// Sample rate in Hz, as measured via AVFoundation at save time.
@property (nonatomic, assign) double sampleRate;

/// File size in bytes on disk.
@property (nonatomic, assign) unsigned long long fileSize;

/// User-toggleable favorite flag.
@property (nonatomic, assign, getter=isFavorite) BOOL favorite;

/// Free-form tags for search/filtering. Always non-nil (empty array if none).
@property (nonatomic, copy) NSArray<NSString *> *tags;

/// Open-ended bag for anything that doesn't deserve a first-class property yet
/// (e.g. future waveform cache path, timeline clip trim points, playlist membership).
/// Values must be JSON-safe (NSString/NSNumber/NSArray/NSDictionary/NSNull) since this
/// dictionary round-trips through Manifest.json verbatim.
@property (nonatomic, copy) NSDictionary<NSString *, id> *metadata;

/// Designated initializer. `uuid` and `created` are generated automatically if you use
/// +entryWithProvider:... below instead of calling this directly.
- (instancetype)initWithUUID:(NSString *)uuid
                      created:(NSDate *)created
                     provider:(NSString *)provider
                    voiceName:(nullable NSString *)voiceName
                      voiceID:(nullable NSString *)voiceID
                        model:(nullable NSString *)model
                       prompt:(NSString *)prompt
                      preview:(nullable NSString *)preview
                     filename:(NSString *)filename
                 relativePath:(NSString *)relativePath
                     duration:(double)duration
                   sampleRate:(double)sampleRate
                     fileSize:(unsigned long long)fileSize
                     favorite:(BOOL)favorite
                         tags:(nullable NSArray<NSString *> *)tags
                     metadata:(nullable NSDictionary<NSString *, id> *)metadata NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Convenience initializer for freshly-generated clips. Generates a new UUID and stamps
/// `created` to now. `preview` is auto-derived from `prompt` if not supplied.
+ (instancetype)entryWithProvider:(NSString *)provider
                         voiceName:(nullable NSString *)voiceName
                           voiceID:(nullable NSString *)voiceID
                             model:(nullable NSString *)model
                            prompt:(NSString *)prompt
                          filename:(NSString *)filename
                      relativePath:(NSString *)relativePath
                          duration:(double)duration
                        sampleRate:(double)sampleRate
                          fileSize:(unsigned long long)fileSize;

#pragma mark - Dictionary serialization

/// JSON-safe dictionary representation. Keys match Manifest.json exactly.
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

/// Builds an entry from a dictionary previously produced by -dictionaryRepresentation
/// (or hand-authored JSON matching that shape). Returns nil and populates `error` if
/// required fields (uuid, created, provider, prompt, filename, relativePath) are missing
/// or malformed. Unknown keys are preserved into `metadata` under an "__unknown" bucket
/// so forward-compatible manifests never lose data on round-trip through an older app version.
+ (nullable instancetype)entryWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                                        error:(NSError * _Nullable * _Nullable)error;

#pragma mark - JSON serialization

/// UTF-8 JSON data for this single entry (rarely needed directly; the library manager
/// serializes the whole manifest at once, but this is useful for export/debugging/sharing
/// a single clip's metadata).
- (nullable NSData *)jsonDataWithError:(NSError * _Nullable * _Nullable)error;

/// Inverse of -jsonDataWithError:.
+ (nullable instancetype)entryWithJSONData:(NSData *)jsonData
                                      error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
