#import "YandexTranslationClient.h"
#import "TranslationSync.h"
#import "TranslationStore.h"
#import "../../Settings/YTKACESettingsPages.h"
#import "../Downloads/StreamResolver.h"
#import "../Downloads/SABRDownloader.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/OverlayButtonHost.h"
#import "../../UI/Notice.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
extern AVPlayer *YTKACEActivePiPPlayer(void);

namespace {
id Object(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![target respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}
double Numeric(id target, NSString *name, double fallback = NAN) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (![target respondsToSelector:selector] || signature.numberOfArguments != 2) return fallback;
    switch (signature.methodReturnType[0]) {
        case 'd': return ((double (*)(id, SEL))objc_msgSend)(target, selector);
        case 'f': return ((float (*)(id, SEL))objc_msgSend)(target, selector);
        case 'B': return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
        case 'c': return ((signed char (*)(id, SEL))objc_msgSend)(target, selector);
        default: return fallback;
    }
}
BOOL CanSetVolume(id target) {
    NSMethodSignature *signature = [target methodSignatureForSelector:NSSelectorFromString(@"setVolume:")];
    return [target respondsToSelector:NSSelectorFromString(@"setVolume:")] && signature.numberOfArguments == 3 &&
        signature.methodReturnType[0] == 'v' && [signature getArgumentTypeAtIndex:2][0] == 'f' &&
        std::isfinite(Numeric(target, @"volume"));
}
void SetVolume(id target, float volume) {
    ((void (*)(id, SEL, float))objc_msgSend)(target, NSSelectorFromString(@"setVolume:"), volume);
}
NSString *VideoID(id controller) {
    id result = Object(controller, @"currentVideoID");
    return [result isKindOfClass:NSString.class] ? result : nil;
}
id ControllerForView(UIView *view) {
    Class cls = NSClassFromString(@"YTPlayerViewController");
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder)
        if (cls && [responder isKindOfClass:cls]) return responder;
    return nil;
}
NSString *SourceLanguage(id controller) {
    id format = Object(Object(controller, @"activeVideo"), @"selectedAudioFormat");
    id track = Object(format, @"audioTrack");
    id identifier = Object(format, @"audioTrackID");
    if (![identifier isKindOfClass:NSString.class] || ![identifier length]) identifier = Object(track, @"id_p");
    NSString *selected = YTKACETranslationTrackLanguage(identifier,
        Object(format, @"xtags"), Object(track, @"displayName"));
    if (selected.length) return selected;
    track = Object(Object(controller, @"activeVideoPlayerOverlay"), @"selectedAudioTrack");
    selected = YTKACETranslationTrackLanguage(Object(track, @"id_p"), nil, Object(track, @"displayName"));
    if (selected.length) return selected;
    id response = YTKACEHLSOriginalResponse(VideoID(controller)) ?: Object(controller, @"contentPlayerResponse");
    if (!Object(response, @"captions")) response = Object(response, @"playerData") ?: response;
    NSMutableArray *tracks = [NSMutableArray array], *captions = [NSMutableArray array];
    for (YTKACEStreamOption *option in [YTKACEStreamResolver optionsFromPlayerResponse:response]) {
        if (option.isAudioOnly) [tracks addObject:@{@"id":option.audioTrackID ?: @"", @"tags":option.xtags ?: @""}];
    }
    id list = Object(Object(response, @"captions"), @"playerCaptionsTracklistRenderer");
    id captionTracks = Object(list, @"captionTracksArray");
    if ([captionTracks isKindOfClass:NSArray.class]) for (id caption in captionTracks) {
        [captions addObject:@{@"kind":Object(caption, @"kind") ?: @"", @"language":Object(caption, @"languageCode") ?: @""}];
    }
    return YTKACETranslationLanguage(tracks, captions);
}
float TranslationVolume(NSString *key, float fallback) {
    id stored = YTKACEPreferenceObject(key);
    double value = stored ? [stored doubleValue] : fallback;
    return std::isfinite(value) ? (float)MIN(MAX(value, 0.0), 1.0) : fallback;
}
}

@interface YTKACETranslationCoordinator : NSObject {
    YTKACETranslationClock _clock;
}
@property(nonatomic, strong) NSHashTable<UIButton *> *buttons;
@property(nonatomic, strong) YTKACEYandexTranslationClient *client;
@property(nonatomic, strong) YTKACESABRTask *sourceTask;
@property(nonatomic, weak) id controller;
@property(nonatomic, strong) id content;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, strong) AVPlayer *audio;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL seeking;
@property(nonatomic) BOOL ducked;
@property(nonatomic) BOOL pausedByYouTube;
@property(nonatomic) float savedVolume;
@property(nonatomic) NSTimeInterval audioWaitBegan;
@property(nonatomic) NSTimeInterval seekBegan;
@property(nonatomic) NSTimeInterval resumeGraceUntil;
@property(nonatomic) NSTimeInterval lastSeekCompleted;
@property(nonatomic, strong) AVPlayer *pipSource;
@property(nonatomic) float pipSavedVolume;
@property(nonatomic, strong) YTKACETranslationStore *store;
@property(nonatomic, weak) id watchedController;
@property(nonatomic, copy) NSString *languageVideoID;
@property(nonatomic, copy) NSString *sourceLanguage;
@property(nonatomic, copy) NSString *autoAttemptedVideo;
@property(nonatomic, copy) NSString *preparationStatus;
@property(nonatomic) NSTimeInterval metadataCheckedAt;
@property(nonatomic, copy) NSURL *remoteAudioURL;
@property(nonatomic) BOOL cacheStarted;
@property(nonatomic, weak) UIViewController *volumeController;
+ (instancetype)shared;
- (void)toggle:(UIButton *)button;
- (void)updateButtons;
- (void)stop;
- (void)tick;
- (void)playbackPaused:(BOOL)paused;
- (void)observeVideo:(id)controller;
- (void)startController:(id)controller;
- (void)prepareAudio:(NSURL *)url;
- (void)setPreparationStatus:(NSString *)status;
- (void)translationVolumeHold:(UILongPressGestureRecognizer *)gesture;
@end

@implementation YTKACETranslationCoordinator
+ (instancetype)shared {
    static YTKACETranslationCoordinator *coordinator;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ coordinator = [self new]; });
    return coordinator;
}
- (instancetype)init {
    if ((self = [super init])) {
        _buttons = NSHashTable.weakObjectsHashTable;
        _client = [YTKACEYandexTranslationClient new];
        NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        _store = [[YTKACETranslationStore alloc] initWithDirectory:[caches URLByAppendingPathComponent:@"YTKACE-Translations"] defaults:NSUserDefaults.standardUserDefaults];
        __weak __typeof(self) weakSelf = self;
        _client.audioProvider = ^(void (^completion)(NSData *, NSInteger, NSError *)) {
            [weakSelf downloadSourceAudio:completion];
        };
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(videoActivated:) name:@"YTKACEVideoDidActivate" object:nil];
        [center addObserver:self selector:@selector(timeChanged:) name:@"YTKACEPlaybackTimeDidChange" object:nil];
        [center addObserver:self selector:@selector(preferencesChanged:) name:YTKACEPreferencesDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(interrupted:) name:AVAudioSessionInterruptionNotification object:nil];
        [center addObserver:self selector:@selector(interrupted:) name:AVAudioSessionRouteChangeNotification object:nil];
    }
    return self;
}
- (void)updateButtons {
    for (UIButton *button in self.buttons) {
        BOOL russian = [self.sourceLanguage isEqualToString:@"ru"] && [self.languageVideoID isEqualToString:VideoID(ControllerForView(button))];
        BOOL hidden = !YTKACEFeatureEnabled(YTKACETranslationKey) || russian;
        if (button.hidden != hidden) {
            button.hidden = hidden;
            [button.superview.superview setNeedsLayout];
        }
        button.tintColor = self.videoID ? UIColor.systemYellowColor : UIColor.whiteColor;
        NSString *state = !self.videoID ? @"Translate to Russian" : (self.loading ? @"Preparing translation. Tap to cancel." : @"Russian translation is on. Tap to turn off.");
        button.accessibilityLabel = YTKACELocalized(state);
        button.accessibilityValue = self.videoID ? (self.loading ? (self.preparationStatus ?: YTKACELocalized(@"Preparing translation…")) : YTKACELocalized(@"On")) : YTKACELocalized(@"Off");
        [button setImage:[UIImage systemImageNamed:self.loading ? @"hourglass" : @"character.bubble"] forState:UIControlStateNormal];
    }
}
- (void)setPreparationStatus:(NSString *)status {
    if ([_preparationStatus isEqualToString:status]) return;
    _preparationStatus = [status copy];
    [self updateButtons];
    if (status.length) YTKACEShowNotice(status);
}
- (void)observeVideo:(id)controller {
    if (!controller) return;
    self.watchedController = controller;
    NSString *videoID = VideoID(controller);
    if (!videoID.length) return;
    double now = NSProcessInfo.processInfo.systemUptime;
    if (![videoID isEqualToString:self.languageVideoID]) {
        self.languageVideoID = videoID; self.sourceLanguage = @"";
        self.autoAttemptedVideo = nil; self.metadataCheckedAt = 0;
        [self updateButtons];
    }
    if (now - self.metadataCheckedAt > 1) {
        self.metadataCheckedAt = now;
        NSString *language = SourceLanguage(controller);
        if (![language isEqualToString:self.sourceLanguage]) {
            if ([self.sourceLanguage isEqualToString:@"ru"]) self.autoAttemptedVideo = nil;
            self.sourceLanguage = language;
            [self updateButtons];
        }
    }
    if ([self.sourceLanguage isEqualToString:@"ru"]) {
        if ([self.videoID isEqualToString:videoID]) [self stop];
        return;
    }
    if (self.videoID || [self.autoAttemptedVideo isEqualToString:videoID] ||
        !YTKACEFeatureEnabled(YTKACETranslationKey) || [self unsupported:controller]) return;
    double duration = Numeric(controller, @"currentVideoTotalMediaTime");
    if (!std::isfinite(duration) || duration <= 0 || !CanSetVolume(Object(controller, @"activeVideo"))) return;
    id enabled = [self.store choiceForVideo:videoID][@"enabled"];
    if (YTKACETranslationShouldStart(self.sourceLanguage, [enabled isKindOfClass:NSNumber.class] ? enabled : nil,
        YTKACEFeatureEnabled(YTKACETranslationAutoKey))) {
        self.autoAttemptedVideo = videoID;
        [self startController:controller];
    }
}
- (void)restoreVolume {
    if (self.pipSource) { self.pipSource.volume = self.pipSavedVolume; self.pipSource = nil; }
    if (self.ducked) { SetVolume(self.content, self.savedVolume); self.ducked = NO; }
}
- (void)stop {
    self.generation++;
    [self.sourceTask cancel]; self.sourceTask = nil;
    [self.client cancel];
    [self.store cancelDownload]; self.remoteAudioURL = nil; self.cacheStarted = NO;
    [self.timer invalidate]; self.timer = nil;
    [self.audio pause]; [self.audio.currentItem cancelPendingSeeks]; self.audio = nil;
    [self restoreVolume];
    self.content = nil; self.controller = nil; self.videoID = nil;
    self.loading = NO; self.seeking = NO; self.audioWaitBegan = 0;
    _preparationStatus = nil;
    self.pausedByYouTube = NO;
    self.resumeGraceUntil = 0; self.lastSeekCompleted = 0;
    _clock.reset(); [self updateButtons];
}
- (void)fail:(NSString *)message {
    [self stop]; YTKACEShowNotice(YTKACELocalized(message));
}
- (void)downloadSourceAudio:(void (^)(NSData *, NSInteger, NSError *))completion {
    id response = YTKACEHLSOriginalResponse(self.videoID) ?: Object(self.controller, @"contentPlayerResponse");
    if (![[YTKACEStreamResolver videoIDFromPlayerResponse:response] isEqualToString:self.videoID])
        response = YTKACECachedPlayerResponse(self.videoID);
    YTKACEStreamOption *option = [YTKACEStreamResolver audioOptionsFromPlayerResponse:response].firstObject
        ?: [YTKACEStreamResolver bestAudioFromPlayerResponse:response];
    if (!option) {
        completion(nil, 0, [NSError errorWithDomain:@"YTKACE.YandexTranslation" code:1 userInfo:@{
            NSLocalizedDescriptionKey: YTKACELocalized(@"Could not load source audio for translation.")}]);
        return;
    }
    self.preparationStatus = YTKACELocalized(@"Downloading audio for Yandex translation…");
    NSUInteger generation = self.generation;
    __weak __typeof(self) weakSelf = self;
    self.sourceTask = [YTKACESABRDownloader downloadPlayerResponse:response videoOption:option
        audioOption:option audioOnly:YES videoID:self.videoID identifier:NSUUID.UUID.UUIDString
        progress:^(double audioProgress, double videoProgress, int64_t audioBytes, int64_t videoBytes, NSInteger phase) {
            __typeof(self) self = weakSelf;
            if (self && generation == self.generation && audioBytes > 256 * 1024 * 1024)
                [self fail:@"Source audio is too large for translation."];
        } completion:^(NSURL *videoURL, NSURL *audioURL, NSError *error) {
            __typeof(self) self = weakSelf;
            NSData *data = nil;
            if (self && generation == self.generation && !error && audioURL) {
                NSNumber *size;
                [audioURL getResourceValue:&size forKey:NSURLFileSizeKey error:&error];
                if (size.unsignedLongLongValue > 0 && size.unsignedLongLongValue <= 256 * 1024 * 1024)
                    data = [NSData dataWithContentsOfURL:audioURL options:NSDataReadingMappedIfSafe error:&error];
            }
            NSURL *scratch = audioURL.URLByDeletingLastPathComponent;
            if ([scratch.lastPathComponent hasPrefix:@"YTKACE-"])
                [NSFileManager.defaultManager removeItemAtURL:scratch error:nil];
            if (!self || generation != self.generation) return;
            self.sourceTask = nil;
            self.preparationStatus = YTKACELocalized(@"Uploading audio to Yandex…");
            completion(data, option.itag, error);
        }];
}
- (void)interrupted:(NSNotification *)notification {
    if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification] &&
        [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] != AVAudioSessionInterruptionTypeBegan) return;
    if ([notification.name isEqualToString:AVAudioSessionRouteChangeNotification] &&
        [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue] != AVAudioSessionRouteChangeReasonOldDeviceUnavailable) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.videoID) [self fail:@"Translation stopped. Tap the button to enable it again."];
    });
}
- (void)preferencesChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!YTKACEFeatureEnabled(YTKACETranslationKey)) [self stop];
        self.audio.volume = TranslationVolume(YTKACETranslationVolumeKey, 1);
        NSString *key = notification.userInfo[@"key"];
        if ([key isEqualToString:YTKACETranslationOriginalVolumeKey] || [key isEqualToString:YTKACETranslationVolumeKey]) {
            NSString *video = self.videoID ?: VideoID(self.watchedController);
            [self.store rememberVideo:video values:@{@"original":@(TranslationVolume(YTKACETranslationOriginalVolumeKey, 0.15)), @"translated":@(TranslationVolume(YTKACETranslationVolumeKey, 1))}];
        }
        if (self.ducked) {
            double value = [YTKACEPreferenceObject(YTKACETranslationOriginalVolumeKey) doubleValue];
            if (!std::isfinite(value)) value = 0.15;
            SetVolume(self.content, self.savedVolume * (float)MIN(MAX(value, 0.0), 1.0));
        }
        [self updateButtons];
        if ([key isEqualToString:YTKACETranslationAutoKey]) [self observeVideo:self.watchedController];
    });
}
- (void)videoActivated:(NSNotification *)notification {
    // Always cancel on activation, even if a replay uses the same video ID.
    dispatch_block_t block = ^{
        if (self.videoID && notification.object == self.controller) [self stop];
        self.languageVideoID = nil;
        [self observeVideo:notification.object];
    };
    if (NSThread.isMainThread) block(); else dispatch_async(dispatch_get_main_queue(), block);
}
- (void)timeChanged:(NSNotification *)notification {
    if (!NSThread.isMainThread) return; // The active timer also reads the real content clock.
    [self observeVideo:notification.object];
    if (self.videoID && self.controller == notification.object) [self tick];
}
- (BOOL)unsupported:(id)controller {
    return !controller || YTKACEPlayerIsShorts(controller) ||
        Numeric(controller, @"isPlayingAd", 0) || Numeric(controller, @"isPlayingAdIntro", 0) ||
        Numeric(controller, @"isPlayingAdSurvey", 0) ||
        Numeric(controller, @"isExternalPlaybackActive", 0) ||
        Numeric(controller, @"currentVideoIsLocal", 0);
}
- (void)toggle:(UIButton *)button {
    if (self.videoID) {
        [self.store rememberVideo:self.videoID values:@{@"enabled":@NO}];
        self.autoAttemptedVideo = self.videoID;
        [self stop]; YTKACEShowNotice(YTKACELocalized(@"Translation off")); return;
    }
    id controller = ControllerForView(button);
    [self startController:controller];
    if (self.videoID) {
        self.autoAttemptedVideo = self.videoID;
        [self.store rememberVideo:self.videoID values:@{@"enabled":@YES}];
    }
}
- (void)startController:(id)controller {
    if (self.videoID) return;
    id content = Object(controller, @"activeVideo");
    NSString *videoID = VideoID(controller);
    if ([SourceLanguage(controller) isEqualToString:@"ru"]) return;
    double duration = Numeric(controller, @"currentVideoTotalMediaTime");
    id response = Object(controller, @"contentPlayerResponse");
    id details = Object(response, @"videoDetails");
    id microformat = Object(Object(response, @"microformat"), @"playerMicroformatRenderer");
    if ([self unsupported:controller] || Numeric(details, @"isLive", 0) ||
        Numeric(details, @"isLiveContent", 0) || Numeric(microformat, @"hasLiveBroadcastDetails", 0) ||
        !videoID.length || !std::isfinite(duration) || duration <= 0 || duration > 14400) {
        YTKACEShowNotice(YTKACELocalized(@"Translation supports regular videos up to 4 hours.")); return;
    }
    if (!CanSetVolume(content)) {
        YTKACEShowNotice(YTKACELocalized(@"Translation is not compatible with this YouTube player.")); return;
    }
    self.controller = controller; self.content = content; self.videoID = videoID;
    self.watchedController = controller;
    NSDictionary *choice = [self.store choiceForVideo:videoID];
    if ([choice[@"original"] isKindOfClass:NSNumber.class]) YTKACESetPreferenceObject(YTKACETranslationOriginalVolumeKey, choice[@"original"]);
    if ([choice[@"translated"] isKindOfClass:NSNumber.class]) YTKACESetPreferenceObject(YTKACETranslationVolumeKey, choice[@"translated"]);
    self.loading = YES;
    NSUInteger generation = ++self.generation;
    [self updateButtons];
    self.preparationStatus = YTKACELocalized(@"Preparing translation…");
    self.timer = [NSTimer timerWithTimeInterval:0.2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    NSURL *cached = [self.store cachedAudioForVideo:videoID];
    if (cached) { [self prepareAudio:cached]; return; }
    __weak __typeof(self) weakSelf = self;
    // Leave source-language detection to Yandex (forceSourceLang is false).
    [self.client translateVideoID:videoID duration:duration language:@"en" progress:^(NSInteger seconds) {
        __typeof(self) self = weakSelf;
        if (!self || generation != self.generation) return;
        self.preparationStatus = YTKACELocalized(@"Waiting for Yandex translation…");
        for (UIButton *item in self.buttons)
            item.accessibilityValue = seconds > 0 ? [NSString stringWithFormat:YTKACELocalized(@"Preparing translation: about %ld seconds"), (long)seconds] : YTKACELocalized(@"Preparing translation…");
    } completion:^(NSURL *url, NSError *error) {
        __typeof(self) self = weakSelf;
        if (!self || generation != self.generation) return;
        if (error) { [self fail:error.localizedDescription]; return; }
        [self.sourceTask cancel]; self.sourceTask = nil;
        if (![videoID isEqualToString:VideoID(self.controller)]) { [self stop]; return; }
        [self prepareAudio:url];
    }];
}
- (void)prepareAudio:(NSURL *)url {
        self.remoteAudioURL = url.isFileURL ? nil : url;
        self.preparationStatus = YTKACELocalized(url.isFileURL ? @"Loading saved translation…" : @"Loading translated audio…");
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
        item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmTimeDomain;
        self.audio = [AVPlayer playerWithPlayerItem:item];
        self.audio.volume = TranslationVolume(YTKACETranslationVolumeKey, 1);
        self.audio.allowsExternalPlayback = NO;
        self.audioWaitBegan = NSProcessInfo.processInfo.systemUptime;
        [self tick];
}
- (void)tick {
    if (!self.videoID) return;
    id controller = self.controller;
    if (![self.videoID isEqualToString:VideoID(controller)] || self.content != Object(controller, @"activeVideo")) {
        [self stop]; return;
    }
    if (!YTKACEFeatureEnabled(YTKACETranslationKey) || [self unsupported:controller]) {
        [self fail:@"Translation stopped. Tap the button to enable it again."]; return;
    }
    if (!self.audio) return;
    double now = NSProcessInfo.processInfo.systemUptime;
    AVPlayerItem *item = self.audio.currentItem;
    if (item.status == AVPlayerItemStatusFailed || self.audio.status == AVPlayerStatusFailed) {
        [self.store removeAudioForVideo:self.videoID];
        [self fail:@"Could not play the translated audio. Try again."]; return;
    }
    if (item.status != AVPlayerItemStatusReadyToPlay) {
        if (now - self.audioWaitBegan > 30) [self fail:@"Could not play the translated audio. Try again."];
        return;
    }
    double time = Numeric(controller, @"currentVideoMediaTime");
    AVPlayer *pip = YTKACEActivePiPPlayer();
    if (pip != self.pipSource) {
        if (self.pipSource) self.pipSource.volume = self.pipSavedVolume;
        self.pipSource = pip;
        if (pip) self.pipSavedVolume = pip.volume;
        self.pausedByYouTube = NO;
        self.resumeGraceUntil = now + 0.5;
        _clock.reset();
    }
    id mediaPlayer = Object(self.content, @"mediaPlayer");
    double rate = pip ? pip.rate : Numeric(mediaPlayer, @"rate");
    if (pip) time = CMTimeGetSeconds(pip.currentTime);
    BOOL moved = std::isfinite(_clock.previousTime) && time > _clock.previousTime;
    BOOL advancing = _clock.shouldPlay(time, now, rate);
    if (moved) self.pausedByYouTube = NO;
    if ((!pip && self.pausedByYouTube) || rate == 0) { [self.audio pause]; return; }
    if (!std::isfinite(rate) || rate <= 0) rate = Numeric(Object(controller, @"activeVideoPlayerOverlay"), @"currentPlaybackRate");
    if (!std::isfinite(rate) || rate < 0.25 || rate > 5.0 || !std::isfinite(time) || time < 0) {
        [self fail:@"Translation supports playback speeds from 0.25x to 5x."]; return;
    }
    double audioDuration = CMTimeGetSeconds(item.duration);
    if (std::isfinite(audioDuration) && time >= audioDuration - 0.05) {
        [self.audio pause]; [self restoreVolume]; _clock.reset(); return;
    }
    // The advancing video clock handles startup, pauses and buffering without
    // relying on YouTube's private playback-intent flag.
    BOOL playing = advancing || now < self.resumeGraceUntil;
    double audioTime = CMTimeGetSeconds(self.audio.currentTime);
    if (!playing) [self.audio pause];
    if (self.seeking) {
        if (now - self.seekBegan > 10) [self fail:@"Could not play the translated audio. Try again."];
        return;
    }
    BOOL buffering = self.audio.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate;
    if (YTKACETranslationNeedsSeek(time, audioTime, rate, buffering, now - self.lastSeekCompleted)) {
        [self.audio pause]; self.seeking = YES; self.seekBegan = now;
        NSUInteger generation = self.generation;
        __weak __typeof(self) weakSelf = self;
        [self.audio seekToTime:CMTimeMakeWithSeconds(time, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof(self) self = weakSelf;
                if (!self || generation != self.generation) return;
                self.seeking = NO;
                self.lastSeekCompleted = NSProcessInfo.processInfo.systemUptime;
                if (!finished) [self fail:@"Could not play the translated audio. Try again."];
                else if ((!self.pausedByYouTube || YTKACEActivePiPPlayer()) && playing) {
                    AVPlayer *currentPiP = YTKACEActivePiPPlayer();
                    double currentRate = currentPiP ? currentPiP.rate : Numeric(Object(self.content, @"mediaPlayer"), @"rate");
                    if (std::isfinite(currentRate) && currentRate >= 0.25 && currentRate <= 5.0)
                        self.audio.rate = (float)currentRate;
                }
            });
        }];
        return;
    }
    if (!playing) return;
    if (self.pipSource) {
        double mix = [YTKACEPreferenceObject(YTKACETranslationOriginalVolumeKey) doubleValue];
        self.pipSource.volume = (float)(std::isfinite(mix) ? MIN(MAX(mix, 0.0), 1.0) : 0.15);
    }
    // Original-track mute/zero volume must not mute the independent translation.
    // Respect AVPlayer's buffer waiting; playImmediatelyAtRate bypasses it.
    if (fabs(self.audio.rate - rate) > 0.01) self.audio.rate = (float)rate;
    if (self.audio.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
        if (!self.cacheStarted && self.remoteAudioURL && item.isPlaybackLikelyToKeepUp) {
            self.cacheStarted = YES; [self.store cacheAudio:self.remoteAudioURL video:self.videoID];
        }
        if (self.loading) {
            self.loading = NO; [self updateButtons];
            YTKACEShowNotice(YTKACELocalized(@"Russian translation is on. Tap to turn off."));
        }
        self.audioWaitBegan = 0;
        if (!self.ducked) {
            self.savedVolume = (float)Numeric(self.content, @"volume");
            if (!std::isfinite(self.savedVolume) || self.savedVolume < 0 || self.savedVolume > 1) {
                [self fail:@"Translation is not compatible with this YouTube player."]; return;
            }
            self.ducked = YES;
        }
        double originalVolume = [YTKACEPreferenceObject(YTKACETranslationOriginalVolumeKey) doubleValue];
        if (!std::isfinite(originalVolume)) originalVolume = 0.15;
        float volume = self.savedVolume * (float)MIN(MAX(originalVolume, 0.0), 1.0);
        if (fabs(Numeric(self.content, @"volume") - volume) > 0.001) SetVolume(self.content, volume);
    } else {
        if (!self.audioWaitBegan) self.audioWaitBegan = now;
        if (now - self.audioWaitBegan > 30) [self fail:@"Could not play the translated audio. Try again."];
    }
}
- (void)playbackPaused:(BOOL)paused {
    if (YTKACEActivePiPPlayer()) return;
    self.pausedByYouTube = paused;
    _clock.reset();
    self.resumeGraceUntil = paused ? 0 : NSProcessInfo.processInfo.systemUptime + 0.5;
    if (paused) [self.audio pause]; else [self tick];
}
@end

static void YTKACETranslationVolumeHold(UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIButton *button = (UIButton *)gesture.view;
    UIViewController *controller = button.window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    YTKACETranslationCoordinator *coordinator = YTKACETranslationCoordinator.shared;
    coordinator.watchedController = ControllerForView(button);
    if (!coordinator.videoID) {
        NSDictionary *choice = [coordinator.store choiceForVideo:VideoID(coordinator.watchedController)];
        if ([choice[@"original"] isKindOfClass:NSNumber.class]) YTKACESetPreferenceObject(YTKACETranslationOriginalVolumeKey, choice[@"original"]);
        if ([choice[@"translated"] isKindOfClass:NSNumber.class]) YTKACESetPreferenceObject(YTKACETranslationVolumeKey, choice[@"translated"]);
    }
    UIViewController *options = YTKACEMakeTranslationOptionsController();
    options.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:coordinator action:@selector(closeTranslationOptions)];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:options];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    navigation.sheetPresentationController.prefersGrabberVisible = YES;
    coordinator.volumeController = navigation;
    [controller presentViewController:navigation animated:YES completion:nil];
}

@implementation YTKACETranslationCoordinator (VolumeMenu)
- (void)closeTranslationOptions { [self.volumeController dismissViewControllerAnimated:YES completion:nil]; }
- (void)translationVolumeHold:(UILongPressGestureRecognizer *)gesture {
    YTKACETranslationVolumeHold(gesture);
}
@end

static IMP OriginalTranslationPause, OriginalTranslationPlay, OriginalTranslationAudioTrackChanged;
static void TranslationAudioTrackChanged(id receiver, SEL selector, id track, NSInteger source) {
    ((void (*)(id, SEL, id, NSInteger))OriginalTranslationAudioTrackChanged)(receiver, selector, track, source);
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACETranslationCoordinator *coordinator = YTKACETranslationCoordinator.shared;
        coordinator.metadataCheckedAt = 0;
        [coordinator observeVideo:coordinator.watchedController];
    });
}
static void TranslationPause(id receiver, SEL selector, int reason) {
    dispatch_block_t pause = ^{
        YTKACETranslationCoordinator *coordinator = YTKACETranslationCoordinator.shared;
        if (coordinator.content == receiver) {
            [coordinator playbackPaused:YES];
        }
    };
    if (NSThread.isMainThread) pause(); else dispatch_async(dispatch_get_main_queue(), pause);
    ((void (*)(id, SEL, int))OriginalTranslationPause)(receiver, selector, reason);
}
static void TranslationPlay(id receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalTranslationPlay)(receiver, selector);
    dispatch_block_t play = ^{
        YTKACETranslationCoordinator *coordinator = YTKACETranslationCoordinator.shared;
        if (coordinator.content == receiver) {
            [coordinator playbackPaused:NO];
        }
    };
    if (NSThread.isMainThread) play(); else dispatch_async(dispatch_get_main_queue(), play);
}
void YTKACEInstallTranslationHooks(void) {
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController", @"audioTrackDidChange:source:",
        (IMP)TranslationAudioTrackChanged, &OriginalTranslationAudioTrackChanged);
    YTKACEInstallInstanceHook(@"YTSingleVideoController", @"pauseWithStoppageReason:",
        (IMP)TranslationPause, &OriginalTranslationPause);
    YTKACEInstallInstanceHook(@"YTSingleVideoController", @"play",
        (IMP)TranslationPlay, &OriginalTranslationPlay);
    YTKACERegisterOverlayConfigurator(@"translation", ^(UIView *overlay, UIStackView *stack) {
        YTKACETranslationCoordinator *coordinator = YTKACETranslationCoordinator.shared;
        UIButton *button = YTKACEOverlayButton(YTKACEOverlayTopStack(overlay), @"YTKACE Yandex Translation", @"character.bubble", coordinator, @selector(toggle:));
        BOOL registered = [coordinator.buttons containsObject:button];
        [coordinator.buttons addObject:button];
        if (!registered) {
        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:nil action:nil];
        [hold addTarget:coordinator action:@selector(translationVolumeHold:)];
        hold.minimumPressDuration = 0.55;
        [button addGestureRecognizer:hold];
        }
        for (NSLayoutConstraint *constraint in button.constraints) {
            if (constraint.firstItem == button && constraint.secondItem == nil &&
                (constraint.firstAttribute == NSLayoutAttributeWidth || constraint.firstAttribute == NSLayoutAttributeHeight))
                constraint.constant = 44;
        }
        [coordinator updateButtons];
        dispatch_async(dispatch_get_main_queue(), ^{ [coordinator observeVideo:ControllerForView(button)]; });
    });
}
