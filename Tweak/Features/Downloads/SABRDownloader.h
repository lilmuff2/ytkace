#import <Foundation/Foundation.h>

@class YTKACEStreamOption;

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACESABRProgress)(double audioProgress,
                                  double videoProgress,
                                  int64_t audioBytes,
                                  int64_t videoBytes,
                                  NSInteger mediaPhase);
typedef void (^YTKACESABRCompletion)(NSURL * _Nullable videoURL,
                                    NSURL * _Nullable audioURL,
                                    NSError * _Nullable error);
typedef void (^YTKACEPlayerReloadCompletion)(id _Nullable playerResponse,
                                             NSError * _Nullable error);
typedef void (^YTKACENativeRequestCompletion)(
    NSURLRequest * _Nullable request,
    NSInteger requestNumber,
    NSError * _Nullable error);

FOUNDATION_EXPORT void YTKACESABRSetPoToken(id _Nullable token);
FOUNDATION_EXPORT void YTKACESABRSetStandaloneClient(NSString *identifier,
    NSData * _Nullable clientInfo, NSDictionary<NSString *, NSString *> * _Nullable headers);
FOUNDATION_EXPORT NSString *_Nullable YTKACESABRPoTokenString(void);
FOUNDATION_EXPORT NSUInteger YTKACESABRPoTokenLength(void);
FOUNDATION_EXPORT void YTKACESABRSetNativeHeaders(
    NSDictionary<NSString *, NSString *> *headers);
FOUNDATION_EXPORT void YTKACESABRSetNativeRequest(NSURLRequest *request);
FOUNDATION_EXPORT void YTKACESABRSetCurrentVideoID(NSString * _Nullable videoID);
FOUNDATION_EXPORT id _Nullable YTKACECachedPlayerResponse(NSString *videoID);
FOUNDATION_EXPORT void YTKACEStorePlayerResponse(NSString *videoID, id response);
FOUNDATION_EXPORT NSString * _Nullable YTKACESABRCurrentVideoIDValue(void);
FOUNDATION_EXPORT NSUInteger YTKACEPurgeDownloadScratch(BOOL includeActive);
FOUNDATION_EXPORT void YTKACEPreparePlayerWithRoute(NSString *videoID,
                                                    BOOL forcePlayerRoute,
                                                    YTKACEPlayerReloadCompletion completion);
FOUNDATION_EXPORT void YTKACEPreparePlayer(NSString *videoID,
                                           YTKACEPlayerReloadCompletion completion);
FOUNDATION_EXPORT BOOL YTKACEPlaybackTemplateReady(void);
FOUNDATION_EXPORT void YTKACESABRRestoreSeed(void);
FOUNDATION_EXPORT void YTKACERestorePlayerRequest(void);
FOUNDATION_EXPORT void YTKACEInstallFeedDownloadHooks(void);
FOUNDATION_EXPORT void YTKACEDiscardRestoredRequest(void);
FOUNDATION_EXPORT void YTKACEResolvePlayerResponse(
    NSString *videoID,
    YTKACEPlayerReloadCompletion completion);
FOUNDATION_EXPORT void YTKACEReloadPlayer(NSString * _Nullable videoID,
                                         NSString *token,
                                         YTKACEPlayerReloadCompletion completion);
FOUNDATION_EXPORT BOOL YTKACEHasNativeOnesieSession(NSString *videoID);
FOUNDATION_EXPORT void YTKACEBuildNativeOnesieRequest(
    NSString *videoID,
    YTKACENativeRequestCompletion completion);

@interface YTKACESABRTask : NSObject
- (void)cancel;
@end

@interface YTKACESABRDownloader : NSObject

+ (YTKACESABRTask *)downloadPlayerResponse:(id)playerResponse
                   videoOption:(YTKACEStreamOption *)videoOption
                   audioOption:(YTKACEStreamOption *)audioOption
                     audioOnly:(BOOL)audioOnly
                       videoID:(NSString *)videoID
                     identifier:(NSString *)identifier
                      progress:(nullable YTKACESABRProgress)progress
                    completion:(YTKACESABRCompletion)completion;

@end

NS_ASSUME_NONNULL_END
