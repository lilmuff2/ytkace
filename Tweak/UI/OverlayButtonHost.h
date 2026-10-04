#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACEOverlayConfigurator)(UIView *overlay, UIStackView *stack);

FOUNDATION_EXPORT UIStackView *YTKACEOverlayTopStack(UIView *overlay);

FOUNDATION_EXPORT void YTKACERegisterOverlayConfigurator(
    NSString *identifier,
    YTKACEOverlayConfigurator configurator
);

FOUNDATION_EXPORT UIButton *YTKACEOverlayButton(
    UIStackView *stack,
    NSString *identifier,
    NSString *symbolName,
    id target,
    SEL action
);

FOUNDATION_EXPORT void YTKACEPresentNativeSheet(
    NSString *_Nullable title,
    NSString *_Nullable subtitle,
    UIView *_Nullable sourceView,
    NSArray<NSDictionary *> *actions
);

FOUNDATION_EXPORT id _Nullable YTKACEMakeSheet(NSString *_Nullable title, NSString *_Nullable subtitle);

FOUNDATION_EXPORT BOOL YTKACEShowSheet(id _Nullable sheet, UIViewController *_Nullable presenter);

NS_ASSUME_NONNULL_END
