// Run: bash Scripts/test-translation.sh (macOS with Xcode command line tools).
#import "../Tweak/Features/Translation/YandexTranslationClient.mm"
#import "../Tweak/Features/Translation/TranslationSync.h"
#import "../Tweak/Features/Translation/TranslationStore.mm"
#include <cassert>
#include <initializer_list>

static NSMutableArray<NSURLRequest *> *requests;
static NSData *(^responseForRequest)(NSURLRequest *);
static NSInteger httpStatus = 200;
static double responseDelay = 0;

@interface TranslationCacheTask : NSObject
@property(nonatomic, strong) NSURLResponse *testResponse;
@property(nonatomic) BOOL wasCancelled;
- (NSURLResponse *)response;
- (void)cancel;
@end
@implementation TranslationCacheTask
- (NSURLResponse *)response { return self.testResponse; }
- (void)cancel { self.wasCancelled = YES; }
@end

@interface VOTMockProtocol : NSURLProtocol
@end
@implementation VOTMockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    dispatch_async(dispatch_get_main_queue(), ^{
        [requests addObject:self.request];
        NSData *data = responseForRequest(self.request);
        NSInteger status = httpStatus;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(responseDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{}];
            [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [self.client URLProtocol:self didLoadData:data];
            [self.client URLProtocolDidFinishLoading:self];
        });
    });
}
- (void)stopLoading {} // Deliberately permit a late response to exercise cancellation.
@end

static void Pump(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static void Until(BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!done() && end.timeIntervalSinceNow > 0) Pump(0.01);
    assert(done());
}
static NSData *SessionReply(void) {
    NSMutableData *data = [NSMutableData data]; String(data, 1, @"test-session"); Integer(data, 2, 3600); return data;
}
static NSData *Reply(int status, NSString *url = nil) {
    NSMutableData *data = [NSMutableData data];
    if (url) String(data, 1, url);
    Integer(data, 4, status); Integer(data, 5, 5); String(data, 7, @"translation-id");
    return data;
}
static NSData *Body(NSURLRequest *request) {
    if (request.HTTPBody) return request.HTTPBody;
    NSInputStream *stream = request.HTTPBodyStream;
    [stream open]; NSMutableData *data = [NSMutableData data]; uint8_t buffer[1024]; NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [data appendBytes:buffer length:count];
    [stream close]; return data;
}
int main(void) { @autoreleasepool {
    requests = [NSMutableArray array];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[VOTMockProtocol.class];
    YTKACEYandexTranslationClient *client = [[YTKACEYandexTranslationClient alloc] initWithConfiguration:configuration];
    NSString *audio = @"https://vtrans.s3-private.mds.yandex.net/test.mp3";

    // Malformed protobuf, field types, overlong varints, and untrusted media URLs.
    assert(!Decode([NSData dataWithBytes:"\x0a\x7fX" length:3]));
    assert(!Decode([NSData dataWithBytes:"\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02" length:11]));
    assert(!Decode([NSData dataWithBytes:"\x00" length:1]));
    assert(!Text(Decode(Reply(1)), @4));
    assert(!AudioURL(@"https://example.com/test.mp3"));
    assert(!AudioURL(@"http://vtrans.yandex.net/test.mp3"));
    assert(!AudioURL(@"https://user:pass@vtrans.yandex.net/test.mp3"));
    assert(!AudioURL(@"https://vtrans.yandex.net.evil.test/test.mp3"));
    assert(AudioURL(audio));
    assert(ValidVideoID(@"jNQXAC9IVRw")); assert(!ValidVideoID(@"../bad/link"));

    // Known HMAC test vector, computed independently with Python hmac.sha256.
    assert([Signature([@"test" dataUsingEncoding:NSUTF8StringEncoding]) isEqualToString:@"ef02ef65d4b0c97334b2e2840177ba354f5b7e530200636dfe5b969eda9442e4"]);

    __block BOOL done = NO;
    responseForRequest = ^NSData *(NSURLRequest *request) {
        NSData *body = Body(request);
        assert([request valueForHTTPHeaderField:@"Vtrans-Signature"].length == 64);
        assert([[request valueForHTTPHeaderField:@"Vtrans-Signature"] isEqual:Signature(body)]);
        if ([request.URL.path isEqual:@"/session/create"]) return SessionReply();
        assert([[request valueForHTTPHeaderField:@"Sec-Vtrans-Sk"] isEqual:@"test-session"]);
        NSDictionary *fields = Decode(body);
        assert([Text(fields,@3) isEqual:@"https://youtu.be/jNQXAC9IVRw"]);
        assert([Text(fields,@14) isEqual:@"ru"]);
        assert(Number(fields,@5,0) == 1);
        assert(Number(fields,@16,0) == 2);
        return Reply(1,audio);
    };
    [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) {} completion:^(__unused NSURL *url,__unused NSError *error) {
        assert(url && !error); done = YES;
    }];
    Until(^BOOL { return done; }); assert(requests.count == 2);

    // Polling must include an explicit false firstRequest field (the API rejects omission).
    done = NO; __block BOOL waiting = NO; __block NSUInteger polls = 0;
    responseForRequest = ^NSData *(NSURLRequest *request) {
        if ([request.URL.path isEqual:@"/session/create"]) return SessionReply();
        NSDictionary *fields = Decode(Body(request));
        assert(Number(fields,@5,-1) == (polls == 0 ? 1 : 0));
        return polls++ == 0 ? Reply(2) : Reply(1,audio);
    };
    [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) { waiting = YES; } completion:^(NSURL *url, NSError *error) { assert(url && !error); done = YES; }];
    Until(^BOOL { return waiting; }); [client poll]; Until(^BOOL { return done; }); assert(polls == 2);

    // Waiting and partial content must not accidentally start an incomplete track.
    for (int status : {2,3,5}) {
        __block BOOL progress = NO; done = NO;
        responseForRequest = ^NSData *(NSURLRequest *request) { return [request.URL.path isEqual:@"/session/create"] ? SessionReply() : Reply(status,audio); };
        [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) { progress = YES; } completion:^(__unused NSURL *url,__unused NSError *error) { done = YES; }];
        Until(^BOOL { return progress; }); assert(!done); [client cancel];
    }
    // Auth required, explicit failure, malformed responses and unsafe audio URL.
    for (int status : {0,7,99,1}) {
        done = NO;
        responseForRequest = ^NSData *(NSURLRequest *request) { return [request.URL.path isEqual:@"/session/create"] ? SessionReply() : Reply(status,@"https://example.com/audio.mp3"); };
        [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) {} completion:^(__unused NSURL *url,__unused NSError *error) { assert(!url && error); done = YES; }];
        Until(^BOOL { return done; });
    }
    // Real source bytes, single and multipart uploads, signed PUT and chunk ordering.
    __block BOOL progress = NO;
    for (NSUInteger size : {NSUInteger(17), NSUInteger(5295308 + 17)}) {
        NSData *source = [NSMutableData dataWithLength:size];
        __block NSUInteger uploaded = 0, chunkIndex = 0;
        progress = NO;
        client.audioProvider = ^(void (^completion)(NSData *, NSInteger, NSError *)) { completion(source, 140, nil); };
        responseForRequest = ^NSData *(NSURLRequest *request) {
            if ([request.URL.path isEqual:@"/session/create"]) return SessionReply();
            if ([request.URL.path isEqual:@"/video-translation/translate"]) return Reply(6);
            assert([request.URL.path isEqual:@"/video-translation/audio"]);
            assert([request.HTTPMethod isEqual:@"PUT"]);
            NSData *body = Body(request);
            assert([[request valueForHTTPHeaderField:@"Vtrans-Signature"] isEqual:Signature(body)]);
            NSDictionary *fields = Decode(body, 6 * 1024 * 1024);
            assert([Text(fields,@1) isEqual:@"translation-id"]);
            NSDictionary *audioFields;
            NSString *metadata;
            if (size <= 5295308) {
                audioFields = Decode(fields[@6]); metadata = Text(audioFields,@1);
            } else {
                NSDictionary *partial = Decode(fields[@4], 6 * 1024 * 1024);
                assert(Number(partial,@2,0) == 2 && Number(partial,@4,0) == 1);
                metadata = Text(partial,@3);
                audioFields = Decode(partial[@1], 6 * 1024 * 1024);
                assert(Number(audioFields,@1,-1) == (NSInteger)chunkIndex++);
            }
            NSDictionary *info = [NSJSONSerialization JSONObjectWithData:[metadata dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            assert([info[@"itag"] integerValue] == 140 && [info[@"fileSize"] integerValue] == (NSInteger)size);
            NSData *chunk = audioFields[@2];
            assert(chunk.length == MIN(NSUInteger(5295308), size - uploaded));
            assert([chunk isEqual:[source subdataWithRange:NSMakeRange(uploaded, chunk.length)]]);
            uploaded += chunk.length;
            NSMutableData *reply = [NSMutableData data]; Integer(reply,1,uploaded == size ? 2 : 1); return reply;
        };
        [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) { progress = YES; } completion:^(__unused NSURL *url,__unused NSError *error) { assert(false); }];
        Until(^BOOL { return progress; }); assert(uploaded == size); [client cancel];
    }
    // A late source download after cancellation must never upload audio.
    __block void (^deliverAudio)(NSData *, NSInteger, NSError *);
    client.audioProvider = ^(void (^completion)(NSData *, NSInteger, NSError *)) { deliverAudio = [completion copy]; };
    responseForRequest = ^NSData *(NSURLRequest *request) { return [request.URL.path isEqual:@"/session/create"] ? SessionReply() : Reply(6); };
    [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) {} completion:^(__unused NSURL *url,__unused NSError *error) { assert(false); }];
    Until(^BOOL { return deliverAudio != nil; }); [client cancel]; NSUInteger beforeLateAudio = requests.count;
    deliverAudio([@"audio" dataUsingEncoding:NSUTF8StringEncoding],140,nil); Pump(0.03);
    assert(requests.count == beforeLateAudio); client.audioProvider = nil;

    // Retry a cached failure once, then report the error rather than loop forever.
    polls = 0; progress = NO; done = NO;
    client.audioProvider = ^(void (^completion)(NSData *, NSInteger, NSError *)) { (void)completion; assert(false); };
    responseForRequest = ^NSData *(NSURLRequest *request) {
        if ([request.URL.path isEqual:@"/session/create"]) return SessionReply();
        NSDictionary *fields = Decode(Body(request));
        assert(Number(fields,@17,0) == (polls++ == 0 ? 0 : 1));
        return Reply(0);
    };
    [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) { progress = YES; } completion:^(NSURL *url, NSError *error) { assert(!url && error); done = YES; }];
    Until(^BOOL { return progress; }); [client poll]; Until(^BOOL { return done; }); assert(polls == 2);
    client.audioProvider = nil;

    // Cancel video A while its response is in flight, then immediately start B.
    __block BOOL oldCompleted = NO; done = NO; responseDelay = 0.1;
    responseForRequest = ^NSData *(NSURLRequest *request) { return [request.URL.path isEqual:@"/session/create"] ? SessionReply() : Reply(1,audio); };
    [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) {} completion:^(__unused NSURL *url,__unused NSError *error) { oldCompleted = YES; }];
    Pump(0.03); [client cancel];
    [client translateVideoID:@"UF8uR6Z6KLc" duration:905 language:@"en" progress:^(__unused NSInteger n) {} completion:^(__unused NSURL *url,__unused NSError *error) { assert(url && !error); done = YES; }];
    Until(^BOOL { return done; }); Pump(0.15); assert(!oldCompleted); responseDelay = 0;

    // Invalid input makes no request; HTTP failure is surfaced, not polled forever.
    NSUInteger requestCount = requests.count; done = NO;
    [client translateVideoID:@"bad" duration:NAN language:@"en" progress:^(__unused NSInteger n) {} completion:^(__unused NSURL *url,__unused NSError *error) { assert(error); done = YES; }];
    assert(done && requests.count == requestCount);
    done = NO; httpStatus = 403;
    [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) {} completion:^(__unused NSURL *url,__unused NSError *error) { assert(!url && error); done = YES; }];
    Until(^BOOL { return done; }); httpStatus = 200;

    // A pending translation has a finite deadline, including timer-driven polls.
    progress = NO; done = NO;
    responseForRequest = ^NSData *(NSURLRequest *request) { return [request.URL.path isEqual:@"/session/create"] ? SessionReply() : Reply(2); };
    [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) { progress = YES; } completion:^(__unused NSURL *url, NSError *error) { assert(error); done = YES; }];
    Until(^BOOL { return progress; }); client.deadline = 0; [client poll]; assert(done);

    // Retry a transient HTTP response once, then finish successfully.
    done = NO; __block NSUInteger attempts = 0;
    responseForRequest = ^NSData *(NSURLRequest *request) {
        if ([request.URL.path isEqual:@"/session/create"]) { httpStatus = 200; return SessionReply(); }
        httpStatus = attempts++ == 0 ? 503 : 200;
        return Reply(1,audio);
    };
    [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) {} completion:^(NSURL *url, NSError *error) { assert(url && !error); done = YES; }];
    Pump(5.2); Until(^BOOL { return done; }); assert(attempts == 2);

    // Synchronization: start, pause, buffering, seek forward/backward, 2x and reset.
    YTKACETranslationClock clock;
    assert(!YTKACETranslationNeedsSeek(30, 29.5, 3, false, 1));
    assert(!YTKACETranslationNeedsSeek(30, 20, 3, true, 1)); // Do not interrupt buffering.
    assert(YTKACETranslationNeedsSeek(30, 20, 3, false, 1)); // Resync after buffering.
    assert(!YTKACETranslationNeedsSeek(30, 20, 3, false, 0.2));
    assert(YTKACETranslationNeedsSeek(30, NAN, 3, false, 1));
    assert(!clock.shouldPlay(20,1));
    assert(clock.shouldPlay(20.2,1.2));
    assert(clock.shouldPlay(20.2,1.3)); // Repeated callbacks do not interrupt playback.
    assert(!clock.shouldPlay(20.2,2)); // A stationary clock pauses the audio.
    assert(clock.shouldPlay(20.4,2.2));
    assert(!clock.shouldPlay(20.4,2.8));
    assert(!clock.shouldPlay(90,3));
    assert(clock.shouldPlay(90.4,3.2));
    assert(!clock.shouldPlay(10,3.4));
    assert(!clock.shouldPlay(NAN,3.6));
    clock.reset(); assert(!clock.shouldPlay(0,4));
    clock.reset(); assert(!clock.shouldPlay(20.4,4.1)); // Pause clears stale progress.
    clock.reset(); assert(!clock.shouldPlay(0, 10, 5));
    assert(clock.shouldPlay(3, 10.6, 5)); // Delayed timer at 5x is not a seek.
    assert(!clock.shouldPlay(30, 10.8, 5)); // Actual jump still resets progress.
    assert([YTKACETranslationLanguage(@[@{@"tags":@"acont=original:lang=ru-RU"}], @[]) isEqual:@"ru"]);
    assert([YTKACETranslationTrackLanguage(@"ru.4", nil, nil) isEqual:@"ru"]); // Selected Russian dub, no original flag.
    assert([YTKACETranslationTrackLanguage(@"en.0", @"lang=ru", @"Russian") isEqual:@"en"]); // Actual ID wins.
    assert([YTKACETranslationTrackLanguage(nil, @"acont%3Ddubbed%3Alang%3Dru", nil) isEqual:@"ru"]);
    assert([YTKACETranslationTrackLanguage(nil, nil, @"Русский (автоматический перевод)") isEqual:@"ru"]);
    assert([YTKACETranslationTrackLanguage(@"und", nil, @"Russian (original)") isEqual:@"ru"]);
    assert(YTKACETranslationTrackLanguage(nil, nil, @"Russian lessons in English").length == 0);
    assert(YTKACETranslationTrackLanguage(@42, NSNull.null, NSNull.null).length == 0);
    assert([YTKACETranslationLanguage(@[@{@"tags":@"acont=original:lang=en"}, @{@"tags":@"acont=dubbed:lang=ru"}], @[]) isEqual:@"en"]);
    assert([YTKACETranslationLanguage(@[], @[@{@"kind":@"asr", @"language":@"ru"}]) isEqual:@"ru"]);
    assert(YTKACETranslationLanguage(@[], @[@{@"kind":@"", @"language":@"ru"}]).length == 0);
    assert(YTKACETranslationLanguage(@[@{@"tags":@"acont=dubbed:lang=ru"}], @[]).length == 0);
    assert(YTKACETranslationLanguage(@[@{@"tags":@"acont=original:lang=ru"}, @{@"tags":@"acont=original:lang=en"}], @[]).length == 0);
    assert(!YTKACETranslationShouldStart(@"ru", @YES, YES));
    assert(!YTKACETranslationShouldStart(@"", nil, YES));
    assert(!YTKACETranslationShouldStart(@"en", @NO, YES));
    assert(YTKACETranslationShouldStart(@"en", nil, YES));
    assert(YTKACETranslationShouldStart(@"", @YES, NO));
    NSString *suite = [@"translation-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:suite]];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    YTKACETranslationStore *store = [[YTKACETranslationStore alloc] initWithDirectory:directory defaults:defaults];
    [store rememberVideo:@"Nbwv5wHQoj0" values:@{@"enabled":@NO, @"original":@0, @"translated":@0.7}];
    [store rememberVideo:@"Nbwv5wHQoj0" values:@{@"enabled":@YES}];
    store = [[YTKACETranslationStore alloc] initWithDirectory:directory defaults:defaults];
    assert([[store choiceForVideo:@"Nbwv5wHQoj0"][@"enabled"] boolValue]);
    assert([[store choiceForVideo:@"Nbwv5wHQoj0"][@"original"] doubleValue] == 0);
    assert([[store choiceForVideo:@"Nbwv5wHQoj0"][@"translated"] doubleValue] == 0.7);
    NSURL *file = [directory URLByAppendingPathComponent:@"Nbwv5wHQoj0-ru.mp3"];
    [[@"audio" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:file atomically:YES];
    assert([store cachedAudioForVideo:@"Nbwv5wHQoj0"] != nil);
    assert([store cachedAudioForVideo:@"../outside/"] == nil);
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-15 * 86400]} ofItemAtPath:file.path error:nil];
    assert([store cachedAudioForVideo:@"Nbwv5wHQoj0"] == nil);
    [NSData.data writeToURL:file atomically:YES];
    assert([store cachedAudioForVideo:@"Nbwv5wHQoj0"] == nil);
    NSURL *download = [directory URLByAppendingPathComponent:@"download.tmp"];
    [[@"audio" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:download atomically:YES];
    TranslationCacheTask *cacheTask = [TranslationCacheTask new];
    cacheTask.testResponse = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://test.yandex.net/audio"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"text/html"}];
    store.task = (id)cacheTask; store.downloadingVideo = @"Nbwv5wHQoj0";
    [store URLSession:NSURLSession.sharedSession downloadTask:(id)cacheTask didFinishDownloadingToURL:download];
    assert([store cachedAudioForVideo:@"Nbwv5wHQoj0"] == nil); // HTML cannot poison the cache.
    cacheTask.testResponse = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://test.yandex.net/audio"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"audio/mpeg"}];
    [store URLSession:NSURLSession.sharedSession downloadTask:(id)cacheTask didFinishDownloadingToURL:download];
    assert([store cachedAudioForVideo:@"Nbwv5wHQoj0"] != nil);
    [store URLSession:NSURLSession.sharedSession downloadTask:(id)cacheTask didWriteData:1 totalBytesWritten:1 totalBytesExpectedToWrite:FileLimit + 1];
    assert(cacheTask.wasCancelled);
    [store cancelDownload];
    assert(store.task == nil);
    for (NSUInteger i=0; i<205; i++) [store rememberVideo:[NSString stringWithFormat:@"%011lu", (unsigned long)i] values:@{@"enabled":@YES}];
    assert([defaults dictionaryForKey:@"YTKACE.Translation.VideoChoices"].count == 200);
    [defaults removePersistentDomainForName:suite];
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    puts("Translation protocol, synchronization, language, preferences and cache checks passed");
}}
