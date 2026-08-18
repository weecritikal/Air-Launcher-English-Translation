//
//  AnnouncementDetailViewController.h
//  Amethyst
//
//  Announcement detail view controller
//  - Title at the top (large) + date (small, gray)
//  - Body rendered as an NSAttributedString by UITextView + MarkdownParser
//  - If the announcement has an actionURL, show a button at the bottom (opens SFSafariViewController)
//

#import <UIKit/UIKit.h>

@class AnnouncementItem;

NS_ASSUME_NONNULL_BEGIN

@interface AnnouncementDetailViewController : UIViewController

/// Build the detail page for the given announcement
- (instancetype)initWithAnnouncement:(AnnouncementItem *)item;

@end

NS_ASSUME_NONNULL_END
