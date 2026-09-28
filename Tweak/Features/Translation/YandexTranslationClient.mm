#import "YandexTranslationClient.h"
#import <CommonCrypto/CommonHMAC.h>
#include <cmath>

// Protocol adapted from FOSWLY/vot.js a92a2794 (MIT); see THIRD_PARTY_NOTICES.md.
// This is a public protocol signing constant, not a user credential.
static NSString *const YTKACEVOTKey = @"bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf";
static NSString *const YTKACEVOTVersion = @"26.8.3.1002";

namespace {
void Varint(NSMutableData *data, uint64_t value) {
    do {
        uint8_t byte = (value & 127) | (value > 127 ? 128 : 0);
        [data appendBytes:&byte length:1];
        value >>= 7;
    } while (value);
}
void Integer(NSMutableData *data, unsigned field, uint64_t value) {
    Varint(data, field << 3); Varint(data, value);
}
void Bytes(NSMutableData *data, unsigned field, NSData *value) {
    Varint(data, (field << 3) | 2); Varint(data, value.length); [data appendData:value];
}
void String(NSMutableData *data, unsigned field, NSString *value) {
    Bytes(data, field, [value dataUsingEncoding:NSUTF8StringEncoding]);
}
bool ReadVarint(const uint8_t *bytes, NSUInteger size, NSUInteger &offset, uint64_t &value) {
    value = 0;
    for (unsigned shift = 0; shift < 64 && offset < size; shift += 7) {
        uint8_t byte = bytes[offset++];
        if (shift == 63 && byte > 1) return false;
        value |= uint64_t(byte & 127) << shift;
        if (!(byte & 128)) return true;
    }
    return false;
}
// Only the flat wire types needed by the VOT replies; reject malformed lengths/varints.
NSDictionary<NSNumber *, id> *Decode(NSData *data, NSUInteger limit = 1024 * 1024) {
    if (!data.length || data.length > limit) return nil;
    auto bytes = static_cast<const uint8_t *>(data.bytes);
    NSUInteger offset = 0;
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    while (offset < data.length) {
        uint64_t tag, value;
        if (!ReadVarint(bytes, data.length, offset, tag) || (tag >> 3) == 0 || (tag >> 3) > 0x1fffffff) return nil;
        NSNumber *field = @(tag >> 3);
        switch (tag & 7) {
            case 0:
                if (!ReadVarint(bytes, data.length, offset, value)) return nil;
                fields[field] = @(value);
                break;
            case 1: case 5: {
                NSUInteger count = (tag & 7) == 1 ? 8 : 4;
                if (count > data.length - offset) return nil;
                offset += count;
                break;
            }
            case 2:
                if (!ReadVarint(bytes, data.length, offset, value) || value > data.length - offset) return nil;
                fields[field] = [data subdataWithRange:NSMakeRange(offset, (NSUInteger)value)];
                offset += (NSUInteger)value;
                break;
            default: return nil;
        }
    }
    return fields;
}
NSString *Text(NSDictionary *fields, NSNumber *field) {
    id data = fields[field];
    return [data isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
NSInteger Number(NSDictionary *fields, NSNumber *field, NSInteger fallback) {
    id value = fields[field];
    return [value isKindOfClass:NSNumber.class] ? [value integerValue] : fallback;
}
NSString *Signature(NSData *data) {
    NSData *key = [YTKACEVOTKey dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (unsigned char byte : digest) [result appendFormat:@"%02x", byte];
    return result;
}
NSError *Failure(NSString *message) {
    return [NSError errorWithDomain:@"YTKACE.YandexTranslation" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}
BOOL ValidVideoID(NSString *value) {
    return value.length == 11 && [value rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet]].location == NSNotFound;
}
NSURL *AudioURL(NSString *value) {
    NSURL *url = value.length ? [NSURL URLWithString:value] : nil;
    NSString *host = url.host.lowercaseString;
    // Only Yandex media hosts; never forward session headers to the audio server.
    BOOL allowed = [host hasSuffix:@".yandex.net"] || [host hasSuffix:@".yandex.ru"] ||
                   [host hasSuffix:@".yandexcloud.net"];
    return [url.scheme.lowercaseString isEqualToString:@"https"] && allowed &&
        !url.user && !url.password && (!url.port || url.port.integerValue == 443) ? url : nil;
}
}

@interface YTKACEYandexTranslationClient () <NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSURLSessionConfiguration *configuration;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, copy) NSString *uuid;
@property(nonatomic, copy) NSString *secret;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *language;
@property(nonatomic) double duration;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic) NSTimeInterval sessionExpires;
@property(nonatomic) BOOL firstRequest;
@property(nonatomic) NSUInteger transientFailures;
@property(nonatomic) BOOL sentAudio;
@property(nonatomic) BOOL bypassCache;
@property(nonatomic, strong) NSData *sourceAudio;
@property(nonatomic, copy) NSString *audioFileID;
@property(nonatomic, copy) void (^progress)(NSInteger);
@property(nonatomic, copy) void (^completion)(NSURL *, NSError *);
@end

@implementation YTKACEYandexTranslationClient
- (instancetype)init {
    return [self initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
}
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {
    if ((self = [super init])) {
        _configuration = [configuration copy];
        _configuration.HTTPCookieStorage = nil;
        _configuration.URLCredentialStorage = nil;
        _configuration.URLCache = nil;
        _configuration.timeoutIntervalForRequest = 30;
        _configuration.timeoutIntervalForResource = 45;
    }
    return self;
}
- (void)cancel {
    NSAssert(NSThread.isMainThread, @"Translation client must run on the main thread");
    self.generation++;
    [self.task cancel]; self.task = nil;
    [self.session invalidateAndCancel]; self.session = nil;
    self.completion = nil; self.progress = nil; self.secret = nil;
    self.sourceAudio = nil; self.audioFileID = nil;
}
- (void)finish:(NSURL *)url error:(NSError *)error {
    void (^completion)(NSURL *, NSError *) = self.completion;
    [self cancel];
    if (completion) completion(url, error);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // The signed API has one fixed origin. Do not leak its headers on redirects.
    completionHandler(nil);
}
- (void)post:(NSString *)path body:(NSData *)body method:(NSString *)method
        json:(BOOL)json signedSession:(BOOL)signedSession
  completion:(void (^)(NSData *))completion {
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) {
        [self finish:nil error:Failure(@"Translation timed out. Try again later.")]; return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[@"https://api.browser.yandex.ru" stringByAppendingString:path]]];
    request.HTTPMethod = method; request.HTTPBody = body;
    [request setValue:json ? @"application/json" : @"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    [request setValue:json ? @"application/json" : @"application/x-protobuf" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 YaBrowser/26.8.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    if (!json) [request setValue:Signature(body) forHTTPHeaderField:@"Vtrans-Signature"];
    if (signedSession) {
        NSString *token = [NSString stringWithFormat:@"%@:%@:%@", self.uuid, path, YTKACEVOTVersion];
        [request setValue:self.secret forHTTPHeaderField:@"Sec-Vtrans-Sk"];
        [request setValue:[NSString stringWithFormat:@"%@:%@", Signature([token dataUsingEncoding:NSUTF8StringEncoding]), token]
            forHTTPHeaderField:@"Sec-Vtrans-Token"];
    }
    NSUInteger generation = self.generation;
    __weak __typeof(self) weakSelf = self;
    self.task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof(self) self = weakSelf;
            if (!self || generation != self.generation) return;
            self.task = nil;
            if (error) { [self finish:nil error:error]; return; }
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (status != 200) {
#ifdef YTKACE_VOT_DIAGNOSTICS
                NSLog(@"VOT HTTP %ld %@: %@", (long)status, path, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
#endif
                if ((status == 408 || status == 429 || status == 500 || status == 502 || status == 503 || status == 504) && self.transientFailures++ < 2) {
                    NSString *retryAfter = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Retry-After"];
                    NSTimeInterval delay = MAX(5.0, MIN(60.0, retryAfter.doubleValue));
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (generation == self.generation)
                            [self post:path body:body method:method json:json signedSession:signedSession completion:completion];
                    });
                    return;
                }
                [self finish:nil error:[NSError errorWithDomain:@"YTKACE.YandexTranslation" code:status userInfo:@{
                    NSLocalizedDescriptionKey: @"Yandex translation service is unavailable. Try again later.", @"path": path}]];
                return;
            }
            self.transientFailures = 0;
            if (!data.length || data.length > 1024 * 1024) {
                [self finish:nil error:Failure(@"Invalid response from Yandex.")]; return;
            }
            completion(data);
        });
    }];
    [self.task resume];
}
- (void)translateVideoID:(NSString *)videoID duration:(double)duration language:(NSString *)language
               progress:(void (^)(NSInteger))progress completion:(void (^)(NSURL *, NSError *))completion {
    [self cancel];
    if (!ValidVideoID(videoID) || !std::isfinite(duration) || duration <= 0 || duration > 14400) {
        completion(nil, Failure(@"Translation supports regular videos up to 4 hours.")); return;
    }
    self.videoID = videoID; self.duration = duration;
    self.language = language.length && language.length <= 12 ? language : @"en";
    self.progress = progress; self.completion = completion;
    self.firstRequest = YES; self.sentAudio = NO; self.transientFailures = 0;
    self.bypassCache = NO;
    self.deadline = NSProcessInfo.processInfo.systemUptime + 15 * 60;
    self.session = [NSURLSession sessionWithConfiguration:self.configuration delegate:self delegateQueue:nil];
    [self createSession];
}
- (void)createSession {
    self.uuid = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSMutableData *body = [NSMutableData data];
    String(body, 1, self.uuid); String(body, 2, @"video-translation");
    [self post:@"/session/create" body:body method:@"POST" json:NO signedSession:NO completion:^(NSData *data) {
        NSDictionary *fields = Decode(data);
        NSString *secret = Text(fields, @1);
        NSInteger expires = Number(fields, @2, 0);
        if (!secret.length || secret.length > 4096 || expires <= 0 ||
            [secret rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
            [self finish:nil error:Failure(@"Invalid response from Yandex.")]; return;
        }
        self.secret = secret;
        self.sessionExpires = NSProcessInfo.processInfo.systemUptime + expires;
        [self poll];
    }];
}
- (void)waitAndPoll:(NSInteger)remaining {
    if (self.progress) self.progress(remaining);
    NSUInteger generation = self.generation;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(5, MIN(60, remaining)) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof(self) self = weakSelf;
        if (self && generation == self.generation) [self poll];
    });
}
- (void)poll {
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) {
        [self finish:nil error:Failure(@"Translation timed out. Try again later.")]; return;
    }
    if (NSProcessInfo.processInfo.systemUptime >= self.sessionExpires) { [self createSession]; return; }
    NSMutableData *body = [NSMutableData data];
    String(body, 3, [@"https://youtu.be/" stringByAppendingString:self.videoID]);
    Integer(body, 5, self.firstRequest ? 1 : 0);
    self.firstRequest = NO;
    Varint(body, (6 << 3) | 1);
    double duration = self.duration;
    uint64_t bits; memcpy(&bits, &duration, sizeof(bits)); bits = CFSwapInt64HostToLittle(bits);
    [body appendBytes:&bits length:sizeof(bits)];
    Integer(body, 7, 1); String(body, 8, self.language);
    String(body, 14, @"ru"); Integer(body, 15, 1); Integer(body, 16, 2);
    if (self.bypassCache) Integer(body, 17, 1);
    [self post:@"/video-translation/translate" body:body method:@"POST" json:NO signedSession:YES completion:^(NSData *data) {
        NSDictionary *fields = Decode(data);
        NSInteger status = Number(fields, @4, -1);
#ifdef YTKACE_VOT_DIAGNOSTICS
        NSLog(@"VOT status %ld, message: %@", (long)status, Text(fields, @9));
#endif
        NSInteger remaining = Number(fields, @5, 10);
        if (status == 1) {
            NSURL *url = AudioURL(Text(fields, @1));
            [self finish:url error:url ? nil : Failure(@"Invalid audio URL from Yandex.")];
        } else if (status == 2 || status == 3 || status == 5) {
            // ponytail: wait for the complete track; partial-track replacement can be added later.
            [self waitAndPoll:remaining];
        } else if (status == 6 && !self.sentAudio && Text(fields, @7).length) {
            self.sentAudio = YES;
            [self requestAudio:Text(fields, @7)];
        } else if (status == 6) {
            [self waitAndPoll:remaining];
        } else if (status == 0 && self.audioProvider && !self.sentAudio && !self.bypassCache) {
            // A prior failed attempt may be cached; retry once with source upload available.
            self.bypassCache = YES; self.firstRequest = YES; [self waitAndPoll:5];
        } else {
            NSString *message = Text(fields, @9);
            if (status == 0 && message.length && message.length <= 300) {
                [self finish:nil error:Failure(message)]; return;
            }
            [self finish:nil error:Failure(status == 7 ? @"Yandex requires sign-in for this video."
                : (status == 0 ? @"Yandex could not translate this video." : @"Invalid response from Yandex."))];
        }
    }];
}
- (void)requestAudio:(NSString *)translationID {
    if (!self.audioProvider) {
        [self finish:nil error:Failure(@"Could not load source audio for translation.")]; return;
    }
    NSUInteger generation = self.generation;
    __block BOOL received = NO;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        __typeof(self) self = weakSelf;
        if (self && generation == self.generation && !received)
            [self finish:nil error:Failure(@"Source audio download timed out.")];
    });
    self.audioProvider(^(NSData *data, NSInteger itag, NSError *error) {
        __typeof(self) self = weakSelf;
        if (!self || generation != self.generation || received) return;
        received = YES;
        if (error || !data.length || data.length > 256 * 1024 * 1024 || itag <= 0) {
            [self finish:nil error:error ?: Failure(@"Could not load source audio for translation.")]; return;
        }
        self.sourceAudio = data;
        NSData *metadata = [NSJSONSerialization dataWithJSONObject:@{
            @"downloadType": @"web_api_get_all_generating_urls_data_from_iframe",
            @"itag": @(itag), @"minChunkSize": @5295308,
            @"fileSize": [NSString stringWithFormat:@"%lu", (unsigned long)data.length]
        } options:0 error:nil];
        self.audioFileID = [[NSString alloc] initWithData:metadata encoding:NSUTF8StringEncoding];
        [self uploadAudio:translationID chunk:0];
    });
}
- (void)uploadAudio:(NSString *)translationID chunk:(NSUInteger)index {
    const NSUInteger chunkSize = 5295308;
    NSUInteger count = (self.sourceAudio.length + chunkSize - 1) / chunkSize;
    NSUInteger offset = index * chunkSize;
    NSData *chunk = [self.sourceAudio subdataWithRange:NSMakeRange(offset, MIN(chunkSize, self.sourceAudio.length - offset))];
    NSMutableData *body = [NSMutableData data], *audio = [NSMutableData data];
    String(body, 1, translationID);
    String(body, 2, [@"https://youtu.be/" stringByAppendingString:self.videoID]);
    Bytes(audio, 2, chunk);
    if (count == 1) {
        String(audio, 1, self.audioFileID); Bytes(body, 6, audio);
    } else {
        Integer(audio, 1, index);
        NSMutableData *partial = [NSMutableData data];
        Bytes(partial, 1, audio); Integer(partial, 2, count);
        String(partial, 3, self.audioFileID); Integer(partial, 4, 1);
        Bytes(body, 4, partial);
    }
    [self post:@"/video-translation/audio" body:body method:@"PUT" json:NO signedSession:YES completion:^(NSData *reply) {
        NSInteger status = Number(Decode(reply), @1, -1);
        if ((index + 1 == count && status != 2) || (status != 1 && status != 2)) {
            [self finish:nil error:Failure(@"Yandex could not retrieve the video's audio.")]; return;
        }
        if (index + 1 < count) [self uploadAudio:translationID chunk:index + 1];
        else { self.sourceAudio = nil; [self waitAndPoll:5]; }
    }];
}
@end
