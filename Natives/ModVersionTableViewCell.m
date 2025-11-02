#import "ModVersionTableViewCell.h"

@interface ModVersionTableViewCell ()
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *versionNumberLabel;
@property (nonatomic, strong) UILabel *datePublishedLabel;
@property (nonatomic, strong) UILabel *fileSizeLabel;
@property (nonatomic, strong) UILabel *gameVersionsLabel;
@property (nonatomic, strong) UIStackView *infoStackView;
@property (nonatomic, strong) UIStackView *rightStackView;
@end

@implementation ModVersionTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    // Left side: Name and Version Number
    self.nameLabel = [UILabel new];
    self.nameLabel.font = [UIFont boldSystemFontOfSize:16];

    self.versionNumberLabel = [UILabel new];
    self.versionNumberLabel.font = [UIFont systemFontOfSize:14];
    self.versionNumberLabel.textColor = [UIColor secondaryLabelColor];

    UIStackView *leftStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.nameLabel, self.versionNumberLabel]];
    leftStackView.axis = UILayoutConstraintAxisVertical;
    leftStackView.spacing = 4;
    leftStackView.alignment = UIStackViewAlignmentLeading;

    // Right side: Date, File Size, Game Versions
    self.datePublishedLabel = [UILabel new];
    self.datePublishedLabel.font = [UIFont systemFontOfSize:12];
    self.datePublishedLabel.textColor = [UIColor grayColor];

    self.fileSizeLabel = [UILabel new];
    self.fileSizeLabel.font = [UIFont systemFontOfSize:12];
    self.fileSizeLabel.textColor = [UIColor grayColor];

    self.gameVersionsLabel = [UILabel new];
    self.gameVersionsLabel.font = [UIFont systemFontOfSize:12];
    self.gameVersionsLabel.textColor = [UIColor grayColor];
    self.gameVersionsLabel.textAlignment = NSTextAlignmentRight;

    self.rightStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.datePublishedLabel, self.fileSizeLabel, self.gameVersionsLabel]];
    self.rightStackView.axis = UILayoutConstraintAxisVertical;
    self.rightStackView.spacing = 4;
    self.rightStackView.alignment = UIStackViewAlignmentTrailing;

    // Main layout
    [self.contentView addSubview:leftStackView];
    [self.contentView addSubview:self.rightStackView];

    leftStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightStackView.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [leftStackView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [leftStackView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [leftStackView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        [leftStackView.trailingAnchor constraintLessThanOrEqualToAnchor:self.rightStackView.leadingAnchor constant:-8],

        [self.rightStackView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.rightStackView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]
    ]];
}

- (void)configureWithVersion:(ModVersion *)version {
    self.nameLabel.text = version.name;
    self.versionNumberLabel.text = version.versionNumber;

    NSISO8601DateFormatter *dateFormatter = [[NSISO8601DateFormatter alloc] init];
    NSDate *date = [dateFormatter dateFromString:version.datePublished];
    if (date) {
        NSDateFormatter *displayFormatter = [[NSDateFormatter alloc] init];
        displayFormatter.dateStyle = NSDateFormatterShortStyle;
        displayFormatter.timeStyle = NSDateFormatterNoStyle;
        self.datePublishedLabel.text = [displayFormatter stringFromDate:date];
    } else {
        self.datePublishedLabel.text = @"未知日期";
    }

    if (version.primaryFile) {
        self.fileSizeLabel.text = [NSByteCountFormatter stringFromByteCount:[version.primaryFile[@"size"] longValue] countStyle:NSByteCountFormatterCountStyleFile];
    } else {
        self.fileSizeLabel.text = @"未知大小";
    }

    self.gameVersionsLabel.text = [version.gameVersions componentsJoinedByString:@", "];
}

@end
