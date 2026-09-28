#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// All calls and callbacks run on the main thread. cancel suppresses pending callbacks.
@interface YTKACEYandexTranslationClient : NSObject
// Called only when Yandex requests the source audio. Completion must run on main.
@property(nonatomic, copy, nullable) void (^audioProvider)(void (^completion)(NSData *_Nullable data, NSInteger itag, NSError *_Nullable error));
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration;
- (void)translateVideoID:(NSString *)videoID
               duration:(double)duration
               language:(NSString *)language
               progress:(void (^)(NSInteger remainingSeconds))progress
             completion:(void (^)(NSURL *_Nullable audioURL, NSError *_Nullable error))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
