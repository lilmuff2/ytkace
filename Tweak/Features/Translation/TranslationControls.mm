#import "YandexTranslationClient.h"
#import "TranslationSync.h"
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

namespace {
id Object(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (![target respondsToSelector:selector] || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
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
+ (instancetype)shared;
- (void)toggle:(UIButton *)button;
- (void)updateButtons;
- (void)stop;
- (void)tick;
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
        button.hidden = !YTKACEFeatureEnabled(YTKACETranslationKey);
        button.tintColor = self.videoID ? UIColor.systemYellowColor : UIColor.whiteColor;
        NSString *state = !self.videoID ? @"Translate to Russian" : (self.loading ? @"Preparing translation. Tap to cancel." : @"Russian translation is on. Tap to turn off.");
        button.accessibilityLabel = YTKACELocalized(state);
        button.accessibilityValue = self.videoID ? YTKACELocalized(self.loading ? @"Preparing translation…" : @"On") : YTKACELocalized(@"Off");
        [button setImage:[UIImage systemImageNamed:self.loading ? @"hourglass" : @"character.bubble"] forState:UIControlStateNormal];
    }
}
- (void)restoreVolume {
    if (self.ducked) { SetVolume(self.content, self.savedVolume); self.ducked = NO; }
}
- (void)stop {
    self.generation++;
    [self.sourceTask cancel]; self.sourceTask = nil;
    [self.client cancel];
    [self.timer invalidate]; self.timer = nil;
    [self.audio pause]; [self.audio.currentItem cancelPendingSeeks]; self.audio = nil;
    [self restoreVolume];
    self.content = nil; self.controller = nil; self.videoID = nil;
    self.loading = NO; self.seeking = NO; self.audioWaitBegan = 0;
    self.pausedByYouTube = NO;
    _clock.reset(); [self updateButtons];
}
- (void)fail:(NSString *)message {
    [self stop]; YTKACEShowNotice(YTKACELocalized(message));
}
- (void)downloadSourceAudio:(void (^)(NSData *, NSInteger, NSError *))completion {
    id response = Object(self.controller, @"contentPlayerResponse");
    if (![[YTKACEStreamResolver videoIDFromPlayerResponse:response] isEqualToString:self.videoID])
        response = YTKACECachedPlayerResponse(self.videoID);
    YTKACEStreamOption *option = [YTKACEStreamResolver audioOptionsFromPlayerResponse:response].firstObject
        ?: [YTKACEStreamResolver bestAudioFromPlayerResponse:response];
    if (!option) {
        completion(nil, 0, [NSError errorWithDomain:@"YTKACE.YandexTranslation" code:1 userInfo:@{
            NSLocalizedDescriptionKey: YTKACELocalized(@"Could not load source audio for translation.")}]);
        return;
    }
    YTKACEShowNotice(YTKACELocalized(@"Downloading audio for Yandex translation…"));
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
        if (self.ducked) {
            double value = [YTKACEPreferenceObject(YTKACETranslationOriginalVolumeKey) doubleValue];
            if (!std::isfinite(value)) value = 0.15;
            SetVolume(self.content, self.savedVolume * (float)MIN(MAX(value, 0.0), 1.0));
        }
        [self updateButtons];
    });
}
- (void)videoActivated:(NSNotification *)notification {
    // Always cancel on activation, even if a replay uses the same video ID.
    dispatch_block_t block = ^{
        if (self.videoID && notification.object == self.controller) [self stop];
    };
    if (NSThread.isMainThread) block(); else dispatch_async(dispatch_get_main_queue(), block);
}
- (void)timeChanged:(NSNotification *)notification {
    if (!NSThread.isMainThread) return; // The active timer also reads the real content clock.
    if (self.videoID && self.controller == notification.object) [self tick];
}
- (BOOL)unsupported:(id)controller {
    return !controller || YTKACEPlayerIsShorts(controller) ||
        Numeric(controller, @"isPlayingAd", 0) || Numeric(controller, @"isPlayingAdIntro", 0) ||
        Numeric(controller, @"isPlayingAdSurvey", 0) || Numeric(controller, @"isPictureInPictureActive", 0) ||
        Numeric(controller, @"isExternalPlaybackActive", 0) ||
        Numeric(controller, @"currentVideoIsLocal", 0);
}
- (void)toggle:(UIButton *)button {
    if (self.videoID) { [self stop]; YTKACEShowNotice(YTKACELocalized(@"Translation off")); return; }
    id controller = ControllerForView(button);
    id content = Object(controller, @"activeVideo");
    NSString *videoID = VideoID(controller);
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
    self.loading = YES;
    NSUInteger generation = ++self.generation;
    [self updateButtons];
    YTKACEShowNotice(YTKACELocalized(@"Preparing translation…"));
    self.timer = [NSTimer timerWithTimeInterval:0.2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    __weak __typeof(self) weakSelf = self;
    // Leave source-language detection to Yandex (forceSourceLang is false).
    [self.client translateVideoID:videoID duration:duration language:@"en" progress:^(NSInteger seconds) {
        __typeof(self) self = weakSelf;
        if (!self || generation != self.generation) return;
        for (UIButton *item in self.buttons)
            item.accessibilityValue = seconds > 0 ? [NSString stringWithFormat:YTKACELocalized(@"Preparing translation: about %ld seconds"), (long)seconds] : YTKACELocalized(@"Preparing translation…");
    } completion:^(NSURL *url, NSError *error) {
        __typeof(self) self = weakSelf;
        if (!self || generation != self.generation) return;
        if (error) { [self fail:error.localizedDescription]; return; }
        [self.sourceTask cancel]; self.sourceTask = nil;
        if (![videoID isEqualToString:VideoID(self.controller)]) { [self stop]; return; }
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
        item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
        self.audio = [AVPlayer playerWithPlayerItem:item];
        self.audio.volume = 1.0;
        self.audio.allowsExternalPlayback = NO;
        self.audioWaitBegan = NSProcessInfo.processInfo.systemUptime;
        [self tick];
    }];
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
        [self fail:@"Could not play the translated audio. Try again."]; return;
    }
    if (item.status != AVPlayerItemStatusReadyToPlay) {
        if (now - self.audioWaitBegan > 30) [self fail:@"Could not play the translated audio. Try again."];
        return;
    }
    double time = Numeric(controller, @"currentVideoMediaTime");
    id mediaPlayer = Object(self.content, @"mediaPlayer");
    double rate = Numeric(mediaPlayer, @"rate");
    if (self.pausedByYouTube || rate == 0) { [self.audio pause]; _clock.reset(); return; }
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
    BOOL playing = _clock.shouldPlay(time, now);
    double audioTime = CMTimeGetSeconds(self.audio.currentTime);
    if (!playing) [self.audio pause];
    if (self.seeking) {
        if (now - self.seekBegan > 10) [self fail:@"Could not play the translated audio. Try again."];
        return;
    }
    if (!std::isfinite(audioTime) || fabs(time - audioTime) > 0.35) {
        [self.audio pause]; self.seeking = YES; self.seekBegan = now;
        NSUInteger generation = self.generation;
        __weak __typeof(self) weakSelf = self;
        [self.audio seekToTime:CMTimeMakeWithSeconds(time, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof(self) self = weakSelf;
                if (!self || generation != self.generation) return;
                self.seeking = NO;
                if (!finished) [self fail:@"Could not play the translated audio. Try again."];
                else if (!self.pausedByYouTube && playing) {
                    double currentRate = Numeric(Object(self.content, @"mediaPlayer"), @"rate");
                    if (std::isfinite(currentRate) && currentRate >= 0.25 && currentRate <= 5.0)
                        [self.audio playImmediatelyAtRate:(float)currentRate];
                }
            });
        }];
        return;
    }
    if (!playing) return;
    // Original-track mute/zero volume must not mute the independent translation.
    if (self.audio.rate != (float)rate) [self.audio playImmediatelyAtRate:(float)rate];
    if (self.audio.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
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
            double originalVolume = [YTKACEPreferenceObject(YTKACETranslationOriginalVolumeKey) doubleValue];
            if (!std::isfinite(originalVolume)) originalVolume = 0.15;
            originalVolume = MIN(MAX(originalVolume, 0.0), 1.0);
            self.ducked = YES; SetVolume(self.content, self.savedVolume * (float)originalVolume);
        }
    } else {
        if (!self.audioWaitBegan) self.audioWaitBegan = now;
        if (now - self.audioWaitBegan > 30) [self fail:@"Could not play the translated audio. Try again."];
    }
}
@end

static void YTKACETranslationVolumeHold(UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIButton *button = (UIButton *)gesture.view;
    UIViewController *controller = button.window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:YTKACELocalized(@"Original audio during translation") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *value in @[@0.0, @0.15, @0.3, @0.5, @1.0]) {
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)llround(value.doubleValue * 100)];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            YTKACESetPreferenceObject(YTKACETranslationOriginalVolumeKey, value);
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = button;
    menu.popoverPresentationController.sourceRect = button.bounds;
    [controller presentViewController:menu animated:YES completion:nil];
}

@implementation YTKACETranslationCoordinator (VolumeMenu)
- (void)translationVolumeHold:(UILongPressGestureRecognizer *)gesture {
    YTKACETranslationVolumeHold(gesture);
}
@end

static IMP OriginalTranslationPause, OriginalTranslationPlay;
static void TranslationPause(id receiver, SEL selector, int reason) {
    dispatch_block_t pause = ^{
        YTKACETranslationCoordinator *coordinator = YTKACETranslationCoordinator.shared;
        if (coordinator.content == receiver) {
            coordinator.pausedByYouTube = YES;
            [coordinator.audio pause];
        }
    };
    if (NSThread.isMainThread) pause(); else dispatch_async(dispatch_get_main_queue(), pause);
    ((void (*)(id, SEL, int))OriginalTranslationPause)(receiver, selector, reason);
}
static void TranslationPlay(id receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalTranslationPlay)(receiver, selector);
    dispatch_block_t play = ^{
        YTKACETranslationCoordinator *coordinator = YTKACETranslationCoordinator.shared;
        if (coordinator.content == receiver) { coordinator.pausedByYouTube = NO; [coordinator tick]; }
    };
    if (NSThread.isMainThread) play(); else dispatch_async(dispatch_get_main_queue(), play);
}
void YTKACEInstallTranslationHooks(void) {
    YTKACEInstallInstanceHook(@"YTSingleVideoController", @"pauseWithStoppageReason:",
        (IMP)TranslationPause, &OriginalTranslationPause);
    YTKACEInstallInstanceHook(@"YTSingleVideoController", @"play",
        (IMP)TranslationPlay, &OriginalTranslationPlay);
    YTKACERegisterOverlayConfigurator(@"translation", ^(UIView *overlay, UIStackView *stack) {
        YTKACETranslationCoordinator *coordinator = YTKACETranslationCoordinator.shared;
        UIButton *button = YTKACEOverlayButton(stack, @"YTKACE Yandex Translation", @"character.bubble", coordinator, @selector(toggle:));
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
    });
}
