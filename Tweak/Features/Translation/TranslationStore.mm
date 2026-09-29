#import "TranslationStore.h"

static NSString *LanguageCode(id value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *code = [[value lowercaseString] componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"-_."]].firstObject;
    if (code.length < 2 || code.length > 3 ||
        [code rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"].invertedSet].location != NSNotFound) return @"";
    return [code isEqualToString:@"rus"] ? @"ru" : code;
}
NSString *YTKACETranslationTrackLanguage(id trackID, id tags, id displayName) {
    NSString *code = LanguageCode(trackID);
    if (code.length && ![code isEqualToString:@"und"]) return code;
    if ([tags isKindOfClass:NSString.class]) {
        NSString *decoded = [tags stringByRemovingPercentEncoding] ?: tags;
        for (NSString *part in [decoded componentsSeparatedByString:@":"]) {
            if ([part hasPrefix:@"lang="]) {
                code = LanguageCode([part substringFromIndex:5]);
                if (code.length && ![code isEqualToString:@"und"]) return code;
            }
        }
    }
    if ([displayName isKindOfClass:NSString.class]) {
        NSString *name = [[displayName lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        for (NSString *russian in @[@"русский", @"russian"]) {
            if ([name isEqualToString:russian] || [name hasPrefix:[russian stringByAppendingString:@" ("]]) return @"ru";
        }
    }
    return @"";
}
NSString *YTKACETranslationLanguage(NSArray<NSDictionary *> *tracks, NSArray<NSDictionary *> *captions) {
    NSMutableSet *originals = [NSMutableSet set];
    for (NSDictionary *track in tracks) {
        NSString *tags = [track[@"tags"] isKindOfClass:NSString.class] ? track[@"tags"] : @"";
        tags = tags.stringByRemovingPercentEncoding ?: tags;
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        for (NSString *part in [tags componentsSeparatedByString:@":"]) {
            NSArray *pair = [part componentsSeparatedByString:@"="];
            if (pair.count == 2) fields[pair[0]] = pair[1];
        }
        if (![fields[@"acont"] isEqualToString:@"original"]) continue;
        NSString *code = LanguageCode(fields[@"lang"] ?: track[@"id"]);
        if (code.length) [originals addObject:code];
    }
    if (originals.count) return originals.count == 1 ? originals.anyObject : @"";
    for (NSDictionary *caption in captions) {
        if (![@"asr" isEqual:caption[@"kind"]]) continue;
        NSString *code = LanguageCode(caption[@"language"]);
        if (code.length) [originals addObject:code];
    }
    return originals.count == 1 ? originals.anyObject : @"";
}
BOOL YTKACETranslationShouldStart(NSString *language, NSNumber *remembered, BOOL automatic) {
    if ([language isEqualToString:@"ru"]) return NO;
    return remembered ? remembered.boolValue : (automatic && language.length > 0);
}
static BOOL ValidVideo(NSString *video) {
    return video.length == 11 && [video rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"].invertedSet].location == NSNotFound;
}
static NSString *const ChoicesKey = @"YTKACE.Translation.VideoChoices";
static const int64_t FileLimit = 256LL * 1024 * 1024;
@interface YTKACETranslationStore ()
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDownloadTask *task;
@property(nonatomic, copy) NSString *downloadingVideo;
@end
@implementation YTKACETranslationStore
- (instancetype)initWithDirectory:(NSURL *)directory defaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) { _directory = directory; _defaults = defaults; }
    return self;
}
- (NSDictionary *)choiceForVideo:(NSString *)videoID {
    id choice = [self.defaults dictionaryForKey:ChoicesKey][videoID ?: @""];
    return [choice isKindOfClass:NSDictionary.class] ? choice : @{};
}
- (void)rememberVideo:(NSString *)videoID values:(NSDictionary *)values {
    if (!ValidVideo(videoID)) return;
    NSMutableDictionary *choices = [[self.defaults dictionaryForKey:ChoicesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *choice = [[self choiceForVideo:videoID] mutableCopy];
    [choice addEntriesFromDictionary:values];
    choice[@"updated"] = @(NSDate.date.timeIntervalSince1970);
    choices[videoID] = choice;
    // ponytail: retain the last 200 videos; a database is unnecessary at this size.
    NSArray *ordered = [choices.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [choices[a][@"updated"] compare:choices[b][@"updated"]];
    }];
    for (NSUInteger i = 0; choices.count > 200; i++) [choices removeObjectForKey:ordered[i]];
    [self.defaults setObject:choices forKey:ChoicesKey];
}
- (NSURL *)pathForVideo:(NSString *)videoID {
    return ValidVideo(videoID) ? [self.directory URLByAppendingPathComponent:[videoID stringByAppendingString:@"-ru.mp3"]] : nil;
}
- (NSURL *)cachedAudioForVideo:(NSString *)videoID {
    NSURL *url = [self pathForVideo:videoID];
    if (!url) return nil;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if (!attrs) return nil;
    if ([attrs fileSize] == 0 || [attrs fileSize] > FileLimit ||
        -[attrs.fileModificationDate timeIntervalSinceNow] > 14 * 86400) {
        [self removeAudioForVideo:videoID]; return nil;
    }
    return url;
}
- (void)removeAudioForVideo:(NSString *)videoID {
    NSURL *url = [self pathForVideo:videoID];
    if (url) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}
- (void)cancelDownload {
    [self.session invalidateAndCancel]; self.session = nil; self.task = nil; self.downloadingVideo = nil;
}
- (void)cacheAudio:(NSURL *)url video:(NSString *)videoID {
    [self cancelDownload];
    NSString *host = url.host.lowercaseString;
    if (!ValidVideo(videoID) || [self cachedAudioForVideo:videoID] ||
        ![url.scheme isEqualToString:@"https"] || url.user || url.password || (url.port && url.port.integerValue != 443) ||
        !([host hasSuffix:@".yandex.net"] || [host hasSuffix:@".yandex.ru"] || [host hasSuffix:@".yandexcloud.net"])) return;
    self.downloadingVideo = videoID;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForResource = 180;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    self.task = [self.session downloadTaskWithURL:url];
    self.task.priority = NSURLSessionTaskPriorityLow;
    [self.task resume];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
    didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
    if (total > FileLimit || expected > FileLimit) [task cancel];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler { completionHandler(nil); }
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    if (task != self.task || ((NSHTTPURLResponse *)task.response).statusCode != 200) return;
    NSString *type = task.response.MIMEType.lowercaseString;
    if (type.length && ![type hasPrefix:@"audio/"] && ![type isEqualToString:@"application/octet-stream"]) return;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:location.path error:nil];
    if ([attrs fileSize] == 0 || [attrs fileSize] > FileLimit) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *destination = [self pathForVideo:self.downloadingVideo];
    [fm removeItemAtURL:destination error:nil];
    if (![fm moveItemAtURL:location toURL:destination error:nil]) return;
    NSArray *files = [fm contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLFileSizeKey] options:0 error:nil];
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *left, *right; [a getResourceValue:&left forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&right forKey:NSURLContentModificationDateKey error:nil]; return [left compare:right];
    }];
    unsigned long long total = 0;
    for (NSURL *file in files) total += [[fm attributesOfItemAtPath:file.path error:nil] fileSize];
    for (NSURL *file in files) {
        if (total <= 512ULL * 1024 * 1024) break;
        total -= [[fm attributesOfItemAtPath:file.path error:nil] fileSize]; [fm removeItemAtURL:file error:nil];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task != self.task) return;
    [session finishTasksAndInvalidate]; self.session = nil; self.task = nil; self.downloadingVideo = nil;
}
@end
