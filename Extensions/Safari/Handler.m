#import <Foundation/Foundation.h>

@interface YTKACESafariHandler : NSObject <NSExtensionRequestHandling>
@end
@implementation YTKACESafariHandler
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    [context completeRequestReturningItems:@[] completionHandler:nil];
}
@end
