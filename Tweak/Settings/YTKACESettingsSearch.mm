#import "YTKACESettingsSearch.h"
#import "YTKACESettingsPages.h"
#import "../Runtime/Localization.h"
#import "../UI/Assets.h"

#import <objc/message.h>
#import <objc/runtime.h>

static UIViewController *YTKACEControllerForPageID(NSString *pageID) {
    static NSDictionary<NSString *, UIViewController *(^)(void)> *builders;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        builders = @{
            @"sponsorblock": ^UIViewController *{ return YTKACEMakeSponsorBlockController(); },
            @"player": ^UIViewController *{ return YTKACEMakePlayerControlsController(); },
            @"overlay": ^UIViewController *{ return YTKACEMakeOverlayOptionsController(); },
            @"playback": ^UIViewController *{ return YTKACEMakeStreamingOptionsController(); },
            @"navigation": ^UIViewController *{ return YTKACEMakeNavigationOptionsController(); },
            @"glass": ^UIViewController *{ return YTKACEMakeGlassOptionsController(); },
            @"tabs": ^UIViewController *{ return YTKACEMakeTabBarOptionsController(); },
            @"shorts": ^UIViewController *{ return YTKACEMakeShortsOptionsController(); },
            @"other": ^UIViewController *{ return YTKACEMakeMiscOptionsController(); },
            @"gestures": ^UIViewController *{ return YTKACEMakeGestureOptionsController(); }
        };
    });
    UIViewController *(^builder)(void) = builders[pageID ?: @""];
    return builder != nil ? builder() : nil;
}

static NSArray<NSDictionary *> *YTKACESearchIndex(void) {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSDictionary *page in YTKACEAllPageDefinitions()) {
        NSArray *sections = page[@"sections"];
        NSArray *headers = page[@"headers"];
        NSString *pageTitle = YTKACELocalized(page[@"title"]);
        for (NSUInteger section = 0; section < sections.count; section++) {
            NSArray *items = sections[section];
            NSString *header = section < headers.count
                ? YTKACELocalized(headers[section]) : @"";
            for (NSUInteger row = 0; row < items.count; row++) {
                NSDictionary *item = items[row];
                NSString *title = item[@"title"];
                if (![title isKindOfClass:NSString.class] || title.length == 0) continue;
                if ([item[@"type"] isEqualToString:@"text"]) continue;
                NSString *subtitle = [item[@"subtitle"] isKindOfClass:NSString.class]
                    ? item[@"subtitle"] : @"";
                [records addObject:@{
                    @"item": item,
                    @"pageID": page[@"id"],
                    @"pageTitle": pageTitle,
                    @"header": header,
                    @"title": title,
                    @"subtitle": subtitle,
                    @"section": @(section),
                    @"row": @(row)
                }];
            }
        }
    }
    return records;
}

static NSInteger YTKACEMatchScore(NSDictionary *record, NSString *query) {
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSRange inTitle = [record[@"title"] rangeOfString:query options:options];
    if (inTitle.location == 0) return 0;
    if (inTitle.location != NSNotFound) return 1;
    if ([record[@"subtitle"] rangeOfString:query options:options].location != NSNotFound) return 2;
    if ([record[@"header"] rangeOfString:query options:options].location != NSNotFound ||
        [record[@"pageTitle"] rangeOfString:query options:options].location != NSNotFound) return 3;
    return NSNotFound;
}

NSArray<NSDictionary *> *YTKACEFilterSettings(NSString *query) {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    if (trimmed.length == 0) return @[];
    NSMutableArray<NSDictionary *> *scored = [NSMutableArray array];
    for (NSDictionary *record in YTKACESearchIndex()) {
        NSInteger score = YTKACEMatchScore(record, trimmed);
        if (score == NSNotFound) continue;
        NSMutableDictionary *entry = [record mutableCopy];
        entry[@"score"] = @(score);
        [scored addObject:entry];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [a[@"score"] compare:b[@"score"]];
        return order != NSOrderedSame ? order : [a[@"title"] compare:b[@"title"]];
    }];
    return scored;
}

void YTKACEOpenSettingsRecord(NSDictionary *record, UIViewController *presenter) {
    UIViewController *page = YTKACEControllerForPageID(record[@"pageID"]);
    if (page == nil || presenter == nil) return;
    NSIndexPath *target = [NSIndexPath indexPathForRow:[record[@"row"] integerValue]
                                             inSection:[record[@"section"] integerValue]];
    SEL push = NSSelectorFromString(@"pushViewController:");
    if ([presenter respondsToSelector:push]) {
        ((void (*)(id, SEL, id))objc_msgSend)(presenter, push, page);
    } else if (presenter.navigationController != nil) {
        [presenter.navigationController pushViewController:page animated:YES];
    } else {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![page isKindOfClass:UITableViewController.class]) return;
        UITableView *table = ((UITableViewController *)page).tableView;
        if (target.section >= [table numberOfSections] ||
            target.row >= [table numberOfRowsInSection:target.section]) return;
        [table scrollToRowAtIndexPath:target
                     atScrollPosition:UITableViewScrollPositionMiddle
                             animated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UITableViewCell *cell = [table cellForRowAtIndexPath:target];
            if (cell == nil) return;
            UIColor *original = cell.contentView.backgroundColor;
            cell.contentView.backgroundColor =
                [YTKACEAccentColor() colorWithAlphaComponent:0.28];
            [UIView animateWithDuration:0.9 delay:0.4
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{ cell.contentView.backgroundColor = original; }
                             completion:nil];
        });
    });
}

@interface YTKACESearchOverlayController : UIViewController
    <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, weak) UIViewController *hostController;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, copy) NSArray<NSDictionary *> *results;
@end

@implementation YTKACESearchOverlayController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.results = @[];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.searchBar = [UISearchBar new];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = YTKACELocalized(@"Search");
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.tintColor = YTKACEAccentColor();
    self.searchBar.searchTextField.tintColor = YTKACEAccentColor();
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.searchBar];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero
                                              style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.table];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.searchBar becomeFirstResponder];
}

- (void)dismissOverlay {
    [self.searchBar resignFirstResponder];
    [self willMoveToParentViewController:nil];
    [self.view removeFromSuperview];
    [self removeFromParentViewController];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    (void)searchBar;
    self.results = YTKACEFilterSettings(text);
    [self.table reloadData];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:NO animated:YES];
    [self dismissOverlay];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const identifier = @"YTKACEOverlayRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    NSDictionary *record = self.results[(NSUInteger)indexPath.row];
    NSString *header = record[@"header"];
    cell.textLabel.text = record[@"title"];
    cell.detailTextLabel.text = header.length != 0
        ? [NSString stringWithFormat:@"%@ › %@", record[@"pageTitle"], header]
        : record[@"pageTitle"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.backgroundColor = UIColor.clearColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *record = self.results[(NSUInteger)indexPath.row];
    UIViewController *host = self.hostController;
    [self dismissOverlay];
    YTKACEOpenSettingsRecord(record, host);
}

@end

void YTKACEPresentSettingsSearchOverlay(UIViewController *host) {
    if (host == nil || !host.isViewLoaded) return;
    for (UIViewController *child in host.childViewControllers) {
        if ([child isKindOfClass:YTKACESearchOverlayController.class]) return;
    }
    YTKACESearchOverlayController *overlay = [YTKACESearchOverlayController new];
    overlay.hostController = host;
    [host addChildViewController:overlay];
    overlay.view.frame = host.view.bounds;
    overlay.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host.view addSubview:overlay.view];
    [overlay didMoveToParentViewController:host];
}

NSArray<NSArray<NSDictionary *> *> *YTKACESearchResultSections(
        NSString *query, NSArray<NSString *> **sectionTitles) {
    NSArray<NSDictionary *> *matches = YTKACEFilterSettings(query);
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSDictionary *> *> *sections =
        [NSMutableArray array];
    for (NSDictionary *record in matches) {
        NSDictionary *item = record[@"item"];
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *page = record[@"pageTitle"] ?: @"";
        NSString *area = record[@"header"] ?: @"";
        NSString *group = area.length != 0
            ? [NSString stringWithFormat:@"%@ › %@", page, area] : page;
        NSUInteger index = [titles indexOfObject:group];
        if (index == NSNotFound) {
            [titles addObject:group];
            [sections addObject:[NSMutableArray array]];
            index = titles.count - 1;
        }
        [sections[index] addObject:item];
    }
    if (sectionTitles != NULL) *sectionTitles = [titles copy];
    return [sections copy];
}
