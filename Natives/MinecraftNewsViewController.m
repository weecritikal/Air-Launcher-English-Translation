//
//  MinecraftNewsViewController.m
//  Flux
//

#import "MinecraftNewsViewController.h"
#import "MinecraftNewsService.h"
#import "MinecraftNewsItem.h"
#import "BackgroundManager.h"
#import "IconLoader.h"
#import <SafariServices/SafariServices.h>
#import "FluxTheme.h"

/// Target thumbnail size (used for IconLoader downsampling)
static const CGFloat kNewsThumbnailTargetWidth = 400.0;
/// Spacing between cards
static const CGFloat kNewsCardSpacing = 12.0;
/// Card padding
static const CGFloat kNewsCardPadding = 12.0;
/// Card corner radius
static const CGFloat kNewsCardCornerRadius = 12.0;
/// Thumbnail corner radius
static const CGFloat kNewsThumbnailCornerRadius = 8.0;
/// Items per page
static const NSInteger kNewsPageSize = 24;

#pragma mark - MCNewsCollectionViewCell

@interface MCNewsCollectionViewCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *metaLabel;     // Author + time
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *readMoreLabel; // The "View details" button
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, copy) NSString *currentImageURL;
@property (nonatomic, copy) NSString *currentArticleURL;
@end

@implementation MCNewsCollectionViewCell

- (void)prepareForReuse {
    [super prepareForReuse];
    [IconLoader cancelLoadingForImageView:self.thumbnailView];
    self.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
    self.thumbnailView.tintColor = [UIColor secondaryLabelColor];
    self.titleLabel.text = nil;
    self.metaLabel.text = nil;
    self.summaryLabel.text = nil;
    self.currentImageURL = nil;
    self.currentArticleURL = nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.backgroundColor = [UIColor clearColor];

        // Card background: set to clearColor, with BackgroundManager.applyEffectToCollectionViewCell: injecting the frosted glass/translucency
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = kNewsCardCornerRadius;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        // contentView needs the same corner radius, so the injected blurView matches
        self.contentView.layer.cornerRadius = kNewsCardCornerRadius;
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        self.contentView.clipsToBounds = YES;

        // Thumbnail
        _thumbnailView = [[UIImageView alloc] init];
        _thumbnailView.translatesAutoresizingMaskIntoConstraints = NO;
        _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnailView.clipsToBounds = YES;
        _thumbnailView.layer.cornerRadius = kNewsThumbnailCornerRadius;
        _thumbnailView.layer.cornerCurve = kCACornerCurveContinuous;
        _thumbnailView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        _thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
        _thumbnailView.tintColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_thumbnailView];

        // Loading indicator (shown while the cover image loads)
        _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
        _loadingIndicator.hidesWhenStopped = YES;
        [_thumbnailView addSubview:_loadingIndicator];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.numberOfLines = 3;
        [self.contentView addSubview:_titleLabel];

        _metaLabel = [[UILabel alloc] init];
        _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _metaLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        _metaLabel.textColor = [UIColor tertiaryLabelColor];
        _metaLabel.numberOfLines = 1;
        [self.contentView addSubview:_metaLabel];

        _summaryLabel = [[UILabel alloc] init];
        _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _summaryLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _summaryLabel.textColor = [UIColor secondaryLabelColor];
        _summaryLabel.numberOfLines = 4;
        [self.contentView addSubview:_summaryLabel];

        _readMoreLabel = [[UILabel alloc] init];
        _readMoreLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _readMoreLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _readMoreLabel.textColor = FluxTheme.accent;
        _readMoreLabel.text = NSLocalizedString(@"mc_news.read_more", @"View details");
        _readMoreLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_readMoreLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_thumbnailView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:kNewsCardPadding],
            [_thumbnailView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kNewsCardPadding],
            [_thumbnailView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kNewsCardPadding],
            [_thumbnailView.heightAnchor constraintEqualToConstant:140],

            [_loadingIndicator.centerXAnchor constraintEqualToAnchor:_thumbnailView.centerXAnchor],
            [_loadingIndicator.centerYAnchor constraintEqualToAnchor:_thumbnailView.centerYAnchor],

            [_titleLabel.topAnchor constraintEqualToAnchor:_thumbnailView.bottomAnchor constant:8],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kNewsCardPadding],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kNewsCardPadding],

            [_metaLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
            [_metaLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_metaLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

            [_summaryLabel.topAnchor constraintEqualToAnchor:_metaLabel.bottomAnchor constant:6],
            [_summaryLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_summaryLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

            [_readMoreLabel.topAnchor constraintEqualToAnchor:_summaryLabel.bottomAnchor constant:6],
            [_readMoreLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_readMoreLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_readMoreLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-kNewsCardPadding],
        ]];
    }
    return self;
}

- (void)configureWithItem:(MinecraftNewsItem *)item {
    self.titleLabel.text = item.title ?: @"";
    self.summaryLabel.text = item.summary ?: @"";

    NSString *author = item.author.length > 0 ? item.author : @"Minecraft";
    NSString *dateStr = item.formattedDateString;
    if (dateStr.length > 0) {
        self.metaLabel.text = [NSString stringWithFormat:@"%@ · %@", author, dateStr];
    } else {
        self.metaLabel.text = author;
    }

    self.currentArticleURL = item.articleURL;
    self.currentImageURL = item.imageURL;

    if (item.imageURL.length > 0) {
        [_loadingIndicator startAnimating];
        UIImage *placeholder = [UIImage systemImageNamed:@"newspaper.fill"];
        [IconLoader loadIconForImageView:_thumbnailView
                                     URL:item.imageURL
                             placeholder:placeholder
                                fallback:placeholder
                            targetSize:CGSizeMake(kNewsThumbnailTargetWidth, 200)
                                options:IconLoaderOptionsDefault
                             completion:^(UIImage *image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_loadingIndicator stopAnimating];
            });
        }];
    }
}

@end

#pragma mark - MinecraftNewsViewController

@interface MinecraftNewsViewController () <UICollectionViewDataSource, UICollectionViewDelegate, SFSafariViewControllerDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) NSMutableArray<MinecraftNewsItem *> *items;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) NSInteger currentPage;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL hasMore;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong) UIView *footerLoadingView;
@end

@implementation MinecraftNewsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"mc_news.title", @"Minecraft news");
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Adapt to the custom launcher background
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    self.items = [NSMutableArray array];
    self.currentPage = 0;
    self.hasMore = YES;

    [self setupUI];
    // Make the collectionView and cell backgrounds transparent, so they do not hide the global background
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.backgroundView = nil;

    // Listen for background effect changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [self loadFirstPage];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.backgroundView = nil;
    [self.collectionView reloadData];
}

- (void)setupUI {
    // Two-column waterfall layout (using the estimated size of CompositionalLayout for an effect like the PCL-CE WaterfallPanel)
    UICollectionViewLayout *layout = [self createCompositionalLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[MCNewsCollectionViewCell class] forCellWithReuseIdentifier:@"NewsCell"];
    self.collectionView.contentInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:self.collectionView];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    [self.collectionView addSubview:self.refreshControl];

    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.activityIndicator];

    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.textColor = [UIColor secondaryLabelColor];
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.hidden = YES;
    [self.view addSubview:self.errorLabel];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.retryButton setTitle:NSLocalizedString(@"mc_news.retry", @"Retry") forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [self.retryButton addTarget:self action:@selector(loadFirstPage) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;
    [self.view addSubview:self.retryButton];

    // Load-more indicator at the bottom
    self.footerLoadingView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
    UIActivityIndicatorView *footerIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    footerIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    footerIndicator.hidesWhenStopped = YES;
    [footerIndicator startAnimating];
    [self.footerLoadingView addSubview:footerIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [footerIndicator.centerXAnchor constraintEqualToAnchor:self.footerLoadingView.centerXAnchor],
        [footerIndicator.centerYAnchor constraintEqualToAnchor:self.footerLoadingView.centerYAnchor],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [self.errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
        [self.errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-32],

        [self.retryButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.retryButton.topAnchor constraintEqualToAnchor:self.errorLabel.bottomAnchor constant:12],
    ]];
}

/// Two-column self-sizing waterfall layout (equal column widths, with the cell height estimated from the content)
- (UICollectionViewLayout *)createCompositionalLayout {
    UICollectionViewCompositionalLayoutConfiguration *config = [[UICollectionViewCompositionalLayoutConfiguration alloc] init];
    config.interSectionSpacing = kNewsCardSpacing;
    config.scrollDirection = UICollectionViewScrollDirectionVertical;

    // The section provider block takes two parameters: sectionIndex and layoutEnvironment
    // The initializer is -initWithSectionProvider:configuration: (not +layoutWithConfiguration:sectionProvider:)
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection *(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> env) {
        // Two columns of equal width
        NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:0.5]
                                                                            heightDimension:[NSCollectionLayoutDimension estimatedDimension:280]];
        NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];

        NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                                                                                             heightDimension:[NSCollectionLayoutDimension estimatedDimension:280]]
                                                                                      subitems:@[item]];
        group.interItemSpacing = [NSCollectionLayoutSpacing fixedSpacing:kNewsCardSpacing];

        NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
        section.interGroupSpacing = kNewsCardSpacing;
        section.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 0, 0);
        return section;
    } configuration:config];
}

#pragma mark - Data Loading

- (void)loadFirstPage {
    if (self.isLoading) return;
    self.isLoading = YES;
    self.currentPage = 0;
    self.hasMore = YES;
    [self.items removeAllObjects];
    [self.collectionView reloadData];

    if (self.currentPage == 0) {
        self.errorLabel.hidden = YES;
        self.retryButton.hidden = YES;
        [self.activityIndicator startAnimating];
    }

    __weak typeof(self) weakSelf = self;
    [[MinecraftNewsService sharedService] fetchLatestNewsWithCompletion:^(NSArray<MinecraftNewsItem *> *items, NSInteger totalCount, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.isLoading = NO;
        [strongSelf.activityIndicator stopAnimating];
        [strongSelf.refreshControl endRefreshing];

        if (error) {
            if (strongSelf.items.count == 0) {
                strongSelf.errorLabel.text = [NSString stringWithFormat:@"%@\n%@", NSLocalizedString(@"mc_news.load_failed", @"Load failed"), error.localizedDescription ?: @""];
                strongSelf.errorLabel.hidden = NO;
                strongSelf.retryButton.hidden = NO;
            }
            return;
        }

        [strongSelf.items addObjectsFromArray:items];
        strongSelf.totalCount = totalCount;
        strongSelf.currentPage = 1;
        strongSelf.hasMore = (strongSelf.items.count < totalCount) && (items.count > 0);
        strongSelf.errorLabel.hidden = YES;
        strongSelf.retryButton.hidden = YES;
        [strongSelf.collectionView reloadData];
    }];
}

- (void)loadNextPage {
    if (self.isLoading || !self.hasMore) return;
    self.isLoading = YES;
    self.footerLoadingView.hidden = NO;

    NSInteger nextPage = self.currentPage + 1;
    __weak typeof(self) weakSelf = self;
    [[MinecraftNewsService sharedService] fetchNewsWithPage:nextPage pageSize:kNewsPageSize completion:^(NSArray<MinecraftNewsItem *> *items, NSInteger totalCount, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.isLoading = NO;
        strongSelf.footerLoadingView.hidden = YES;

        if (error || items.count == 0) {
            strongSelf.hasMore = NO;
            return;
        }

        NSInteger oldCount = strongSelf.items.count;
        [strongSelf.items addObjectsFromArray:items];
        strongSelf.currentPage = nextPage;
        strongSelf.hasMore = (strongSelf.items.count < totalCount);

        // Insert the new rows incrementally
        NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray array];
        for (NSInteger i = oldCount; i < strongSelf.items.count; i++) {
            [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:0]];
        }
        [strongSelf.collectionView insertItemsAtIndexPaths:indexPaths];
    }];
}

- (void)pullToRefresh {
    [self loadFirstPage];
}

#pragma mark - UICollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    MCNewsCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"NewsCell" forIndexPath:indexPath];
    MinecraftNewsItem *item = self.items[indexPath.item];
    [cell configureWithItem:item];
    // Adapt to the custom launcher background: give the cell a frosted-glass/translucent effect
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:cell];
    return cell;
}

#pragma mark - UICollectionView Delegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    MinecraftNewsItem *item = self.items[indexPath.item];
    [self openArticleURL:item.articleURL];
}

/// Load the next page automatically when scrolling near the bottom
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat offsetY = scrollView.contentOffset.y;
    CGFloat contentHeight = scrollView.contentSize.height;
    CGFloat threshold = contentHeight - scrollView.bounds.size.height - 300;
    if (offsetY > threshold && offsetY > 0) {
        [self loadNextPage];
    }
}

/// Open the article inline in an SFSafariViewController (without leaving the app)
- (void)openArticleURL:(NSString *)urlString {
    if (urlString.length == 0) return;
    if (![MinecraftNewsService isSafeNewsLink:urlString]) {
        // Links outside the allowlist are ignored (see the IsSafeNewsLink safety filter in PCL-CE)
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
    safari.delegate = self;
    safari.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:safari animated:YES completion:nil];
}

#pragma mark - SFSafariViewControllerDelegate

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
}

@end
