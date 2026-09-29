#import <Foundation/Foundation.h>

// Empty means unknown; only original tracks or automatic captions identify source speech.
NSString *YTKACETranslationLanguage(NSArray<NSDictionary *> *tracks, NSArray<NSDictionary *> *captions);
BOOL YTKACETranslationShouldStart(NSString *language, NSNumber *remembered, BOOL automatic);

@interface YTKACETranslationStore : NSObject <NSURLSessionDownloadDelegate>
- (instancetype)initWithDirectory:(NSURL *)directory defaults:(NSUserDefaults *)defaults;
- (NSDictionary *)choiceForVideo:(NSString *)videoID;
- (void)rememberVideo:(NSString *)videoID values:(NSDictionary *)values;
- (NSURL *)cachedAudioForVideo:(NSString *)videoID;
- (void)cacheAudio:(NSURL *)url video:(NSString *)videoID;
- (void)removeAudioForVideo:(NSString *)videoID;
- (void)cancelDownload;
@end
