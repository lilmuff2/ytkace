// Run: bash Scripts/test-translation.sh (macOS with Xcode command line tools).
#import "../Tweak/Features/Translation/YandexTranslationClient.mm"
#import "../Tweak/Features/Translation/TranslationSync.h"
#include <cassert>
#include <initializer_list>

static NSMutableArray<NSURLRequest *> *requests;
static NSData *(^responseForRequest)(NSURLRequest *);
static NSInteger httpStatus = 200;
static double responseDelay = 0;

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
    // The service's audio fallback uses PUT and no upload of the user's media.
    [requests removeAllObjects]; __block BOOL progress = NO;
    responseForRequest = ^NSData *(NSURLRequest *request) {
        NSString *path = request.URL.path;
        if ([path isEqual:@"/session/create"]) return SessionReply();
        if ([path isEqual:@"/video-translation/translate"]) return Reply(6);
        assert([request.HTTPMethod isEqual:@"PUT"]);
        if ([path isEqual:@"/video-translation/fail-audio-js"]) return [@"{\"status\":1}" dataUsingEncoding:NSUTF8StringEncoding];
        assert([path isEqual:@"/video-translation/audio"]);
        NSMutableData *data = [NSMutableData data]; Integer(data,1,2); return data;
    };
    [client translateVideoID:@"jNQXAC9IVRw" duration:19 language:@"en" progress:^(__unused NSInteger n) { progress = YES; } completion:^(__unused NSURL *url,__unused NSError *error) { assert(false); }];
    Until(^BOOL { return progress; }); assert(requests.count == 4); [client cancel];

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
    puts("Translation protocol, cancellation and clock checks passed");
}}
