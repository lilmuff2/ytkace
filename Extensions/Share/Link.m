#import "Link.h"

NSURL *YTKACEYouTubeAppURL(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString;
    if (![@[@"http", @"https"] containsObject:scheme] || url.user || url.password) return nil;
    if (url.port && !(([scheme isEqualToString:@"https"] && url.port.integerValue == 443) ||
                      ([scheme isEqualToString:@"http"] && url.port.integerValue == 80))) return nil;
    if (![@[@"youtube.com", @"www.youtube.com", @"m.youtube.com", @"youtu.be"] containsObject:host]) return nil;
    if ([host isEqualToString:@"youtu.be"]) {
        NSString *identifier = [url.path substringFromIndex:MIN((NSUInteger)1, url.path.length)];
        NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_-]{11}$" options:0 error:nil];
        if (![pattern firstMatchInString:identifier options:0 range:NSMakeRange(0, identifier.length)]) return nil;
        url.path = @"/watch";
        NSMutableArray *query = [NSMutableArray array];
        for (NSURLQueryItem *item in url.queryItems) {
            if (![item.name isEqualToString:@"v"]) [query addObject:item];
        }
        [query addObject:[NSURLQueryItem queryItemWithName:@"v" value:identifier]];
        url.queryItems = query;
    }
    url.scheme = @"youtube";
    url.host = @"www.youtube.com";
    url.port = nil;
    if (!url.path.length) url.path = @"/";
    return url.URL;
}
