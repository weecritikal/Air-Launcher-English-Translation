//
//  MarkdownParser.h
//  Amethyst
//
//  Lightweight Markdown -> NSAttributedString converter
//  No third-party libraries, pure UIKit. Supports: h1-h3, bold **text**, italic *text*,
//  inline code `code`, unordered lists - item, ordered lists 1. item, links [text](url),
//  horizontal rules ---, paragraphs and block quotes > text.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MarkdownParser : NSObject

/// Convert Markdown text into an NSAttributedString (with the system 15pt font as the base)
/// @param markdown The raw Markdown text
+ (NSAttributedString *)parseMarkdown:(NSString *)markdown;

/// Convert Markdown text into an NSAttributedString
/// @param markdown The raw Markdown text
/// @param baseFont The base font (the system 15pt font by default)
+ (NSAttributedString *)parseMarkdown:(NSString *)markdown baseFont:(UIFont *)baseFont;

@end

NS_ASSUME_NONNULL_END
