
#import "WMFFeedContentSource.h"
#import "WMFContentGroupDataStore.h"
#import "WMFArticlePreviewDataStore.h"
#import "WMFFeedContentFetcher.h"
#import "WMFContentGroup.h"

#import "WMFFeedDayResponse.h"
#import "WMFFeedArticlePreview.h"
#import "WMFFeedImage.h"
#import "WMFFeedTopReadResponse.h"
#import "WMFFeedNewsStory.h"

#import "WMFArticlePreview.h"
#import "WMFNotificationsController.h"

#define WMF_ALWAYS_LOAD_FEED_DATA DEBUG && 0
#define WMF_ALWAYS_NOTIFY DEBUG && 0

@import NSDate_Extensions;

NS_ASSUME_NONNULL_BEGIN

static NSInteger WMFFeedNotificationMinHour = 8;
static NSInteger WMFFeedNotificationMaxHour = 20;

#if !WMF_ALWAYS_NOTIFY
static NSTimeInterval WMFFeedNotificationArticleRepeatLimit = 30 * 24 * 60 * 60; // 30 days
static NSInteger WMFFeedInTheNewsNotificationMaxRank = 10;
#endif
static NSInteger WMFFeedInTheNewsNotificationViewCountDays = 5;

@interface WMFFeedContentSource ()

@property (readwrite, nonatomic, strong) NSURL *siteURL;

@property (readwrite, nonatomic, strong) WMFContentGroupDataStore *contentStore;
@property (readwrite, nonatomic, strong) WMFArticlePreviewDataStore *previewStore;
@property (readwrite, nonatomic, strong) MWKDataStore *userDataStore;
@property (readwrite, nonatomic, strong) WMFNotificationsController *notificationsController;

@property (readwrite, nonatomic, strong) WMFFeedContentFetcher *fetcher;

@end

@implementation WMFFeedContentSource

- (instancetype)initWithSiteURL:(NSURL *)siteURL contentGroupDataStore:(WMFContentGroupDataStore *)contentStore articlePreviewDataStore:(WMFArticlePreviewDataStore *)previewStore userDataStore:(MWKDataStore *)userDataStore notificationsController:(WMFNotificationsController *)notificationsController {
    NSParameterAssert(siteURL);
    NSParameterAssert(contentStore);
    NSParameterAssert(previewStore);
    self = [super init];
    if (self) {
        self.siteURL = siteURL;
        self.contentStore = contentStore;
        self.previewStore = previewStore;
        self.userDataStore = userDataStore;
        self.updateInterval = 30 * 60;
        self.notificationsController = notificationsController;
    }
    return self;
}

#pragma mark - Accessors

- (WMFFeedContentFetcher *)fetcher {
    if (_fetcher == nil) {
        _fetcher = [[WMFFeedContentFetcher alloc] init];
    }
    return _fetcher;
}

#pragma mark - WMFContentSource

- (void)loadNewContentForce:(BOOL)force completion:(nullable dispatch_block_t)completion {
    [self loadContentForDate:[NSDate date] completion:completion];
}

- (void)loadContentFromDate:(NSDate *)fromDate forwardForDays:(NSInteger)days completion:(nullable dispatch_block_t)completion {
    if (days <= 0) {
        if (completion) {
            completion();
        }
        return;
    }
    [self loadContentForDate:fromDate
                  completion:^{
                      NSCalendar *calendar = [NSCalendar wmf_utcGregorianCalendar];
                      NSDate *updatedFromDate = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:fromDate options:NSCalendarMatchStrictly];
                      [self loadContentFromDate:updatedFromDate forwardForDays:days - 1 completion:completion];
                  }];
}

- (void)preloadContentForNumberOfDays:(NSInteger)days completion:(nullable dispatch_block_t)completion {
    NSCalendar *calendar = [NSCalendar wmf_utcGregorianCalendar];
    NSDate *fromDate = [calendar dateByAddingUnit:NSCalendarUnitDay value:-days toDate:[NSDate date] options:NSCalendarMatchStrictly];
    [self loadContentFromDate:fromDate forwardForDays:days completion:completion];
}

- (void)loadContentForDate:(NSDate *)date completion:(nullable dispatch_block_t)completion {

#if !WMF_ALWAYS_LOAD_FEED_DATA
    WMFTopReadContentGroup *topRead = [self topReadForDate:date];

    //TODO: check which languages support most read???
    if (topRead != nil) {
        //Safe to assume we have everything since Top Read comes in last
        if (completion) {
            completion();
        }
        return;
    }
#endif

    [self.fetcher fetchFeedContentForURL:self.siteURL
        date:date
        failure:^(NSError *_Nonnull error) {
            if (completion) {
                completion();
            }

        }
        success:^(WMFFeedDayResponse *_Nonnull feedDay) {
            [self saveContentForFeedDay:feedDay onDate:date completion:completion];
        }];
}

- (void)removeAllContent {
    [self.contentStore removeAllContentGroupsOfKind:[WMFFeaturedArticleContentGroup kind]];
    [self.contentStore removeAllContentGroupsOfKind:[WMFPictureOfTheDayContentGroup kind]];
    [self.contentStore removeAllContentGroupsOfKind:[WMFTopReadContentGroup kind]];
    [self.contentStore removeAllContentGroupsOfKind:[WMFNewsContentGroup kind]];
}

#pragma mark - Save Groups

- (void)saveContentForFeedDay:(WMFFeedDayResponse *)feedDay onDate:(NSDate *)date completion:(dispatch_block_t)completion {
    [self scheduleNotificationsForFeedDay:feedDay onDate:date];
    [self saveGroupForFeaturedPreview:feedDay.featuredArticle date:date];
    [self saveGroupForTopRead:feedDay.topRead date:date];
    [self saveGroupForPictureOfTheDay:feedDay.pictureOfTheDay date:date];
    if ([date wmf_isTodayUTC]) {
        [self saveGroupForNews:feedDay.newsStories date:date];
    }
    [self.contentStore notifyWhenWriteTransactionsComplete:completion];
}

- (void)saveGroupForFeaturedPreview:(WMFFeedArticlePreview *)preview date:(NSDate *)date {

    WMFFeaturedArticleContentGroup *featured = [self featuredForDate:date];

    if (featured == nil) {
        featured = [[WMFFeaturedArticleContentGroup alloc] initWithDate:date siteURL:self.siteURL];
    }

    NSURL *featuredURL = [preview articleURL];

    [self.previewStore addPreviewWithURL:featuredURL updatedWithFeedPreview:preview];
    [self.contentStore addContentGroup:featured associatedContent:@[featuredURL]];
}

- (void)saveGroupForTopRead:(WMFFeedTopReadResponse *)topRead date:(NSDate *)date {

    WMFTopReadContentGroup *group = [self topReadForDate:date];

    if (group == nil) {
        group = [[WMFTopReadContentGroup alloc] initWithDate:date mostReadDate:topRead.date siteURL:self.siteURL];
    }

    [topRead.articlePreviews enumerateObjectsUsingBlock:^(WMFFeedTopReadArticlePreview *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
        NSURL *url = [obj articleURL];
        [self.previewStore addPreviewWithURL:url updatedWithFeedPreview:obj];
    }];

    [self.contentStore addContentGroup:group associatedContent:topRead.articlePreviews];
}

- (void)saveGroupForPictureOfTheDay:(WMFFeedImage *)image date:(NSDate *)date {

    WMFPictureOfTheDayContentGroup *group = [self pictureOfTheDayForDate:date];

    if (group == nil) {
        group = [[WMFPictureOfTheDayContentGroup alloc] initWithDate:date siteURL:self.siteURL];
    }

    [self.contentStore addContentGroup:group associatedContent:@[image]];
}

- (void)saveGroupForNews:(NSArray<WMFFeedNewsStory *> *)news date:(NSDate *)date {

    WMFNewsContentGroup *group = [self newsForDate:date];

    if (group == nil) {
        group = [[WMFNewsContentGroup alloc] initWithDate:date siteURL:self.siteURL];
    }

    [news enumerateObjectsUsingBlock:^(WMFFeedNewsStory *_Nonnull story, NSUInteger idx, BOOL *_Nonnull stop) {
        [story.articlePreviews enumerateObjectsUsingBlock:^(WMFFeedArticlePreview *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
            NSURL *url = [obj articleURL];
            [self.previewStore addPreviewWithURL:url updatedWithFeedPreview:obj];
        }];
    }];

    [self.contentStore addContentGroup:group associatedContent:news];
}

#pragma mark - Find Groups

- (nullable WMFFeaturedArticleContentGroup *)featuredForDate:(NSDate *)date {

    return (id)[self.contentStore firstGroupOfKind:[WMFFeaturedArticleContentGroup kind] forDate:date];
}

- (nullable WMFPictureOfTheDayContentGroup *)pictureOfTheDayForDate:(NSDate *)date {
    return (id)[self.contentStore firstGroupOfKind:[WMFPictureOfTheDayContentGroup kind] forDate:date];
}

- (nullable WMFTopReadContentGroup *)topReadForDate:(NSDate *)date {
    return (id)[self.contentStore firstGroupOfKind:[WMFTopReadContentGroup kind] forDate:date];
}

- (nullable WMFNewsContentGroup *)newsForDate:(NSDate *)date {
    return (id)[self.contentStore firstGroupOfKind:[WMFNewsContentGroup kind] forDate:date];
}

#pragma mark - Notifications

- (void)scheduleNotificationsForFeedDay:(WMFFeedDayResponse *)feedDay onDate:(NSDate *)date {
    if (![date wmf_isTodayUTC]) { //in the news notifications only valid for the current day
        return;
    }
    NSArray<WMFFeedTopReadArticlePreview *> *articlePreviews = feedDay.topRead.articlePreviews;
    NSMutableDictionary<NSString *, WMFFeedTopReadArticlePreview *> *topReadArticlesByKey = [NSMutableDictionary dictionaryWithCapacity:articlePreviews.count];
    for (WMFFeedTopReadArticlePreview *articlePreview in articlePreviews) {
        NSString *key = articlePreview.articleURL.wmf_databaseKey;
        if (!key) {
            continue;
        }
        topReadArticlesByKey[key] = articlePreview;
    }

    for (WMFFeedNewsStory *newsStory in feedDay.newsStories) {
#if WMF_ALWAYS_NOTIFY
        WMFFeedArticlePreview *articlePreviewToNotifyAbout = nil;
#else
        WMFFeedTopReadArticlePreview *articlePreviewToNotifyAbout = nil;
#endif

        NSMutableArray<NSURL *> *articleURLs = [NSMutableArray arrayWithCapacity:newsStory.articlePreviews.count];
        for (WMFFeedArticlePreview *articlePreview in newsStory.articlePreviews) {
            NSURL *articleURL = articlePreview.articleURL;
            if (!articleURL) {
                continue;
            }
            NSString *key = articleURL.wmf_databaseKey;
            if (!key) {
                continue;
            }
            [articleURLs addObject:articleURL];
#if WMF_ALWAYS_NOTIFY
            if (YES) {
#else
            WMFFeedTopReadArticlePreview *topReadArticlePreview = topReadArticlesByKey[key];
            if (topReadArticlePreview && topReadArticlePreview.rank.integerValue < WMFFeedInTheNewsNotificationMaxRank) {
#endif
#if WMF_ALWAYS_NOTIFY
                articlePreviewToNotifyAbout = articlePreview;
#else
                MWKHistoryEntry *entry = [self.userDataStore entryForURL:articlePreview.articleURL];
                BOOL notifiedRecently = entry.inTheNewsNotificationDate && [entry.inTheNewsNotificationDate timeIntervalSinceNow] < WMFFeedNotificationArticleRepeatLimit;
                BOOL viewedRecently = entry.dateViewed && [entry.dateViewed timeIntervalSinceNow] < WMFFeedNotificationArticleRepeatLimit;
                if (notifiedRecently || viewedRecently) {
                    articlePreviewToNotifyAbout = nil;
                    break;
                }

                if (!articlePreviewToNotifyAbout || topReadArticlePreview.rank < articlePreviewToNotifyAbout.rank) {
                    articlePreviewToNotifyAbout = topReadArticlePreview;
                }
#endif
            }
        }
        NSURL *articleURLToNotifyAbout = articlePreviewToNotifyAbout.articleURL;
        if (articlePreviewToNotifyAbout && articleURLToNotifyAbout) {
            NSDate *startDate = [[NSCalendar wmf_utcGregorianCalendar] dateByAddingUnit:NSCalendarUnitDay value:-1 - WMFFeedInTheNewsNotificationViewCountDays toDate:date options:NSCalendarMatchStrictly];
            NSDate *endDate = [[NSCalendar wmf_utcGregorianCalendar] dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:date options:NSCalendarMatchStrictly];
            [self.fetcher fetchPageviewsForURL:articleURLToNotifyAbout
                startDate:startDate
                endDate:endDate
                failure:^(NSError *_Nonnull error) {
                    DDLogError(@"Error fetching pageviews for article: %@ from: %@ to: %@ error: %@", articleURLToNotifyAbout, startDate, endDate, error);
                }
                success:^(NSArray<NSNumber *> *_Nonnull results) {
                    [self scheduleNotificationForNewsStory:newsStory articlePreview:articlePreviewToNotifyAbout viewCounts:results];
                }];
            break;
        }
    }
}

- (BOOL)scheduleNotificationForNewsStory:(WMFFeedNewsStory *)newsStory articlePreview:(WMFFeedArticlePreview *)articlePreview viewCounts:(NSArray<NSNumber *> *)viewCounts {
    NSString *articleURLString = articlePreview.articleURL.absoluteString;
    NSString *storyHTML = newsStory.storyHTML;
    NSString *displayTitle = articlePreview.displayTitle;

    if (!storyHTML || !articleURLString || !displayTitle || !viewCounts) {
        return NO;
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:4];
    info[WMFNotificationInfoStoryHTMLKey] = storyHTML;
    info[WMFNotificationInfoArticleTitleKey] = displayTitle;
    info[WMFNotificationInfoViewCountsKey] = viewCounts;
    info[WMFNotificationInfoArticleURLStringKey] = articleURLString;
    NSString *thumbnailURLString = articlePreview.thumbnailURL.absoluteString;
    if (thumbnailURLString) {
        info[WMFNotificationInfoThumbnailURLStringKey] = thumbnailURLString;
    }
    NSString *snippet = articlePreview.snippet ?: articlePreview.wikidataDescription;
    if (snippet) {
        info[WMFNotificationInfoArticleExtractKey] = snippet;
    }

    NSString *title = NSLocalizedString(@"in-the-news-notification-title", nil);
    NSString *body = [storyHTML wmf_stringByRemovingHTML];

    NSDate *now = [NSDate date];
    NSCalendar *calendar = [NSCalendar autoupdatingCurrentCalendar];
    NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute fromDate:now];
    if (components.hour < WMFFeedNotificationMinHour || components.hour > WMFFeedNotificationMaxHour) {
        // Send it tomorrow
        NSDate *tomorrow = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:now options:NSCalendarMatchStrictly];
        components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour fromDate:tomorrow];
        components.hour = WMFFeedNotificationMinHour;
    }

    [self.notificationsController sendNotificationWithTitle:title body:body categoryIdentifier:WMFInTheNewsNotificationCategoryIdentifier userInfo:info atDateComponents:components];

    return YES;
}

@end

NS_ASSUME_NONNULL_END
