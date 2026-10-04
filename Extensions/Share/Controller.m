#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Link.h"

@interface YTKACEShareController : UIViewController
@property(nonatomic) UILabel *status;
@property(nonatomic) UIButton *retry;
@property(nonatomic) NSURL *link;
@property(nonatomic) BOOL started;
@property(nonatomic) NSUInteger attempt;
@property(nonatomic) BOOL finished;
@end

@implementation YTKACEShareController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [UILabel new];
    title.text = @"Открыть в YouTube";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    title.textColor = UIColor.labelColor;
    title.numberOfLines = 0;
    self.status = [UILabel new];
    self.status.text = @"Проверяю ссылку…";
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.status.adjustsFontForContentSizeCategory = YES;
    self.status.textColor = UIColor.labelColor;
    self.status.numberOfLines = 0;
    self.retry = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retry setTitle:@"Открыть" forState:UIControlStateNormal];
    [self.retry addTarget:self action:@selector(openLink) forControlEvents:UIControlEventTouchUpInside];
    self.retry.enabled = NO;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"Закрыть" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    for (UIButton *button in @[self.retry, close]) {
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, self.status, self.retry, close]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
        [self.retry.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [close.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.started) return;
    self.started = YES;
    NSMutableArray<NSItemProvider *> *providers = [NSMutableArray array];
    for (NSExtensionItem *item in self.extensionContext.inputItems) [providers addObjectsFromArray:item.attachments ?: @[]];
    [self loadProviders:providers index:0];
}
- (void)loadProviders:(NSArray<NSItemProvider *> *)providers index:(NSUInteger)index {
    if (index >= providers.count) {
        self.status.text = @"В меню «Поделиться» не найдена ссылка YouTube.";
        return;
    }
    NSItemProvider *provider = providers[index];
    NSString *type = [provider hasItemConformingToTypeIdentifier:@"public.url"] ? @"public.url" : @"public.plain-text";
    if (![provider hasItemConformingToTypeIdentifier:type]) { [self loadProviders:providers index:index + 1]; return; }
    __weak typeof(self) weakSelf = self;
    [provider loadItemForTypeIdentifier:type options:nil completionHandler:^(id value, NSError *error) {
        NSString *text = [value isKindOfClass:NSURL.class] ? [value absoluteString] : ([value isKindOfClass:NSString.class] ? value : nil);
        NSURL *link = YTKACEYouTubeAppURL(text);
        if (!link && text) {
            NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
            for (NSTextCheckingResult *match in [detector matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
                link = YTKACEYouTubeAppURL(match.URL.absoluteString);
                if (link) break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.finished) return;
            if (link) { self.link = link; [self openLink]; }
            else [self loadProviders:providers index:index + 1];
        });
    }];
}
- (void)close {
    self.finished = YES;
    [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
}
- (void)result:(BOOL)success attempt:(NSUInteger)attempt {
    if (self.finished || attempt != self.attempt) return;
    if (success) { [self close]; return; }
    self.status.text = @"iOS не разрешила открыть YouTube. Открой эту ссылку в Safari и нажми «Открыть в YouTube».";
    self.retry.enabled = YES;
}
- (void)openLink {
    if (!self.link || self.finished) return;
    self.retry.enabled = NO;
    self.status.text = @"Открываю YouTube…";
    NSUInteger attempt = ++self.attempt;
    __weak typeof(self) weakSelf = self;
    [self.extensionContext openURL:self.link completionHandler:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.finished || self.attempt != attempt) return;
            if (success) { [self result:YES attempt:attempt]; return; }
            // Share extensions don't always support NSExtensionContext.openURL.
            // Sideloaded apps use the host's UIApplication bridge. Resolve it at
            // runtime: no entitlement or app group is required, and failure stays visible.
            Class cls = NSClassFromString(@"UIApplication");
            SEL shared = NSSelectorFromString(@"sharedApplication");
            id application = [cls respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
            SEL open = NSSelectorFromString(@"openURL:options:completionHandler:");
            if (![application respondsToSelector:open]) {
                for (UIResponder *responder = self; responder; responder = responder.nextResponder) {
                    if ([responder respondsToSelector:open]) { application = responder; break; }
                }
            }
            if ([application respondsToSelector:open]) {
                ((void (*)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)))objc_msgSend)(application, open, self.link, @{}, ^(BOOL opened) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf result:opened attempt:attempt]; });
                });
            } else [self result:NO attempt:attempt];
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self && self.attempt == attempt && !self.finished && !self.retry.enabled) [self result:NO attempt:attempt];
    });
}
@end
