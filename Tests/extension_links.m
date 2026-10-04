#import <Foundation/Foundation.h>
#import "../Extensions/Share/Link.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        NSArray *cases = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!cases.count) return 2;
        for (NSDictionary *test in cases) {
            NSString *result = YTKACEYouTubeAppURL(test[@"input"]).absoluteString;
            id expected = test[@"output"];
            if (expected == NSNull.null ? result != nil : ![expected isEqual:result]) {
                NSLog(@"Failed %@: %@ (expected %@)", test[@"input"], result, expected);
                return 1;
            }
        }
        NSLog(@"Share: %lu link cases passed", (unsigned long)cases.count);
    }
    return 0;
}
