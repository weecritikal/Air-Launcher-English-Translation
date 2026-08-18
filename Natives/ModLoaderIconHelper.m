//
//  ModLoaderIconHelper.m
//  Amethyst
//
//  Implementation of the unified mod loader icon helper
// Following the loader icon systems of FCL/ZL2, unifying the three parallel loader representations in this project
//

#import "ModLoaderIconHelper.h"

@implementation ModLoaderIconHelper

#pragma mark - Brand colors

/// The unified loader brand color map (shared across the project, removing the color inconsistencies between files)
/// The colors follow each loader's official brand guidelines and match the official colors used by FCL/ZL2
+ (UIColor *)brandColorForLoader:(NSString *)loader {
    if (!loader || loader.length == 0) {
        return [UIColor tertiaryLabelColor];
    }
    NSString *lower = loader.lowercaseString;

    // Mind the order: neoforge must come before forge (neoforge contains forge as a substring)
    // and optifabric must come before optifine (optifabric contains optifine as a substring)
    if ([lower containsString:@"neoforge"]) {
        // NeoForge official orange #E0732B
        return [UIColor colorWithRed:0.88 green:0.45 blue:0.17 alpha:1.0];
    }
    if ([lower containsString:@"forge"]) {
        // Forge official brown #8B5A2B
        return [UIColor colorWithRed:0.55 green:0.35 blue:0.20 alpha:1.0];
    }
    if ([lower containsString:@"optifabric"]) {
        // OptiFabric shares the OptiFine color family
        return [UIColor colorWithRed:0.90 green:0.60 blue:0.10 alpha:1.0];
    }
    if ([lower containsString:@"optifine"]) {
        // OptiFine official yellow #E6991A
        return [UIColor colorWithRed:0.90 green:0.60 blue:0.10 alpha:1.0];
    }
    if ([lower containsString:@"quilt"]) {
        // Quilt official purple-pink #D668AC
        return [UIColor colorWithRed:0.84 green:0.41 blue:0.67 alpha:1.0];
    }
    if ([lower containsString:@"fabric"]) {
        // Fabric official blue #5B8DF9
        return [UIColor colorWithRed:0.18 green:0.55 blue:0.95 alpha:1.0];
    }
    if ([lower containsString:@"iris"]) {
        // Iris official light blue #4DA6F2
        return [UIColor colorWithRed:0.30 green:0.65 blue:0.95 alpha:1.0];
    }
    if ([lower containsString:@"rift"]) {
        // Rift official green #33B280
        return [UIColor colorWithRed:0.20 green:0.70 blue:0.50 alpha:1.0];
    }
    if ([lower containsString:@"vanilla"]) {
        // Vanilla green #66CC66
        return [UIColor colorWithRed:0.40 green:0.80 blue:0.40 alpha:1.0];
    }
    // Unrecognized: return the system secondary label color (gray) as a fallback
    return [UIColor tertiaryLabelColor];
}

#pragma mark - SF Symbol names

/// The SF Symbol name for a loader (a symbol shaped like the official logo)
/// Used only as a fallback when the bundle has no matching PNG
+ (NSString *)symbolNameForLoader:(NSString *)loader {
    if (!loader || loader.length == 0) {
        return @"cube.box.fill";
    }
    NSString *lower = loader.lowercaseString;

    // The order matches brandColorForLoader
    if ([lower containsString:@"neoforge"]) {
        // NeoForge: a hammer shape (the official logo is a hammer)
        return @"hammer.fill";
    }
    if ([lower containsString:@"forge"]) {
        // Forge: an anvil shape (the official logo is an anvil)
        return @"anvil.fill";
    }
    if ([lower containsString:@"optifabric"] || [lower containsString:@"optifine"]) {
        // OptiFine: an eye shape (the official logo is an eye)
        return @"eye.fill";
    }
    if ([lower containsString:@"quilt"]) {
        // Quilt: a hexagonal grid (the official logo is a patchwork pattern)
        return @"circle.hexagongrid.fill";
    }
    if ([lower containsString:@"fabric"]) {
        // Fabric: a bolt/star (the official logo is a weaving needle, which no SF Symbol matches exactly, so a close one is used)
        return @"wand.and.stars";
    }
    if ([lower containsString:@"iris"]) {
        // Iris: a rainbow/circle (the official logo is a rainbow eye)
        return @"circle.lefthalf.filled";
    }
    if ([lower containsString:@"rift"]) {
        // Rift: a bolt (the official logo is a rift/bolt)
        return @"bolt.fill";
    }
    if ([lower containsString:@"vanilla"]) {
        // Vanilla: a cube (a vanilla block)
        return @"cube.fill";
    }
    // Default: a cube box
    return @"cube.box.fill";
}

#pragma mark - Display names

/// The localized display name of a loader (for the badge text)
+ (NSString *)displayNameForLoader:(NSString *)loader {
    if (!loader || loader.length == 0) {
        return @"Unknown";
    }
    NSString *lower = loader.lowercaseString;

    if ([lower containsString:@"neoforge"])   return @"NeoForge";
    if ([lower containsString:@"forge"])      return @"Forge";
    if ([lower containsString:@"optifabric"]) return @"OptiFabric";
    if ([lower containsString:@"optifine"])   return @"OptiFine";
    if ([lower containsString:@"quilt"])      return @"Quilt";
    if ([lower containsString:@"fabric"])     return @"Fabric";
    if ([lower containsString:@"iris"])       return @"Iris";
    if ([lower containsString:@"rift"])       return @"Rift";
    if ([lower containsString:@"vanilla"])    return @"Vanilla";

    // Unknown loader: return it capitalized
    if (loader.length > 0) {
        NSString *firstChar = [[loader substringToIndex:1] uppercaseString];
        NSString *rest = [loader substringFromIndex:1];
        return [NSString stringWithFormat:@"%@%@", firstChar, rest];
    }
    return @"Unknown";
}

#pragma mark - Icon loading

/// Load a loader icon (preferring a bundled PNG, falling back to an SF Symbol)
/// Load order:
///   1. ModLoaderIcons/{key}.png (the HMCL official standard single file, with no light/dark variants, a transparent PNG in brand colors)
///   2. ModLoaderIcons/{key}_{light|dark}.png (the old format, kept for compatibility, with per-theme files)
///   3. An SF Symbol tinted with the brand color (the fallback)
+ (UIImage *)iconImageForLoader:(NSString *)loader
                 traitCollection:(UITraitCollection *)traitCollection {
    if (!loader || loader.length == 0) {
        return [UIImage systemImageNamed:@"cube.box.fill"];
    }

    // Vanilla: use the VanillaIcon grass block from Assets.xcassets
    // matching the vanilla icon on the version cards in VersionCardCell (the standard grass block that ships with the HMCL repo)
    if ([loader.lowercaseString containsString:@"vanilla"]) {
        UIImage *vanillaIcon = [UIImage imageNamed:@"VanillaIcon"];
        if (vanillaIcon) {
            return vanillaIcon;
        }
        // If VanillaIcon fails to load, fall back to an SF Symbol
        return [UIImage systemImageNamed:@"cube.fill"];
    }

    // Extract the normalized loader name (used to match the PNG file name)
    NSString *pngKey = [self pngKeyForLoader:loader];
    if (pngKey) {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *resourcePath = [bundle resourcePath];

        // 1. Prefer the HMCL official standard single file (with no light/dark variants)
        NSString *standardPath = [resourcePath stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"ModLoaderIcons/%@.png", pngKey]];
        UIImage *image = [UIImage imageWithContentsOfFile:standardPath];
        if (image) {
            return image;
        }

        // 2. Fall back to the old format (with light/dark themes)
        BOOL isDarkMode = NO;
        if (traitCollection) {
            isDarkMode = (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
        }
        NSString *theme = isDarkMode ? @"dark" : @"light";
        NSString *themedPath = [resourcePath stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"ModLoaderIcons/%@_%@.png", pngKey, theme]];
        image = [UIImage imageWithContentsOfFile:themedPath];
        if (image) {
            return image;
        }
        // Try the opposite theme
        theme = isDarkMode ? @"light" : @"dark";
        themedPath = [resourcePath stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"ModLoaderIcons/%@_%@.png", pngKey, theme]];
        image = [UIImage imageWithContentsOfFile:themedPath];
        if (image) {
            return image;
        }
    }

    // 3. No PNG, or loading failed: fall back to an SF Symbol
    NSString *symbolName = [self symbolNameForLoader:loader];
    UIImage *symbolImage = [UIImage systemImageNamed:symbolName];
    return symbolImage ?: [UIImage systemImageNamed:@"cube.box.fill"];
}

/// Convert a loader name into the PNG file name key (such as "fabric-loader" -> "fabric")
/// Used to match the PNG files in the ModLoaderIcons/ folder
+ (nullable NSString *)pngKeyForLoader:(NSString *)loader {
    if (!loader || loader.length == 0) return nil;
    NSString *lower = loader.lowercaseString;

    // Mind the order: neoforge before forge, and optifabric before optifine
    if ([lower containsString:@"neoforge"])   return @"neoforge";
    if ([lower containsString:@"forge"])      return @"forge";
    if ([lower containsString:@"optifabric"]) return @"optifine"; // Shares the OptiFine icon
    if ([lower containsString:@"optifine"])   return @"optifine"; // The official HMCL PNG
    if ([lower containsString:@"quilt"])      return @"quilt";    // The official HMCL PNG
    if ([lower containsString:@"fabric"])     return @"fabric";
    if ([lower containsString:@"iris"])       return nil; // No official PNG yet, so fall back to an SF Symbol
    if ([lower containsString:@"rift"])       return nil; // No official PNG yet, so fall back to an SF Symbol
    if ([lower containsString:@"vanilla"])    return nil; // Uses VanillaIcon from Assets.xcassets
    return nil;
}

#pragma mark - UIImageView configuration

/// Configure a UIImageView to show a loader icon
/// PNG icons keep their own colors and are not tinted; SF Symbols are tinted with the brand color
+ (void)configureImageView:(UIImageView *)imageView
                forLoader:(NSString *)loader
           traitCollection:(UITraitCollection *)traitCollection {
    if (!imageView) return;

    UIImage *image = [self iconImageForLoader:loader traitCollection:traitCollection];
    imageView.image = image;
    imageView.contentMode = UIViewContentModeScaleAspectFit;

    // Work out whether this is a PNG or VanillaIcon (not tinted) or an SF Symbol (tinted)
    // Vanilla uses the grass block icon from Assets.xcassets and keeps its own colors
    if ([loader.lowercaseString containsString:@"vanilla"]) {
        imageView.tintColor = nil;
        return;
    }

    // The load order matches iconImageForLoader: the standard single file first, then the theme files
    NSString *pngKey = [self pngKeyForLoader:loader];
    BOOL hasPng = NO;
    if (pngKey) {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *resourcePath = [bundle resourcePath];
        // 1. Check the HMCL official standard single file first
        NSString *standardPath = [resourcePath stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"ModLoaderIcons/%@.png", pngKey]];
        if ([NSFileManager.defaultManager fileExistsAtPath:standardPath]) {
            hasPng = YES;
        } else {
            // 2. Then check the old-format theme file
            BOOL isDarkMode = traitCollection ? (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) : NO;
            NSString *theme = isDarkMode ? @"dark" : @"light";
            NSString *themedPath = [resourcePath stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"ModLoaderIcons/%@_%@.png", pngKey, theme]];
            if ([NSFileManager.defaultManager fileExistsAtPath:themedPath]) {
                hasPng = YES;
            } else {
                theme = isDarkMode ? @"light" : @"dark";
                themedPath = [resourcePath stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"ModLoaderIcons/%@_%@.png", pngKey, theme]];
                if ([NSFileManager.defaultManager fileExistsAtPath:themedPath]) {
                    hasPng = YES;
                }
            }
        }
    }

    if (hasPng) {
        // PNG icon: keep its own colors, do not tint
        imageView.tintColor = nil;
    } else {
        // SF Symbol: tint with the brand color
        imageView.tintColor = [self brandColorForLoader:loader];
    }
}

#pragma mark - Badge views

/// Build a loader badge view (an icon + text pill, following the loader tags of FCL/ZL2)
/// The rounded background uses a translucent brand color, with the icon plus white text
+ (UIView *)createBadgeViewForLoader:(NSString *)loader
                      traitCollection:(UITraitCollection *)traitCollection {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIColor *brandColor = [self brandColorForLoader:loader];

    // Rounded background
    container.backgroundColor = [brandColor colorWithAlphaComponent:0.18];
    container.layer.cornerRadius = 8;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.layer.borderWidth = 0.5;
    container.layer.borderColor = [brandColor colorWithAlphaComponent:0.35].CGColor;

    // Icon
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self configureImageView:iconView forLoader:loader traitCollection:traitCollection];
    [container addSubview:iconView];

    // Text
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = [self displayNameForLoader:loader];
    label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    label.textColor = brandColor;
    label.textAlignment = NSTextAlignmentCenter;
    [container addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:6],
        [iconView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:12],
        [iconView.heightAnchor constraintEqualToConstant:12],

        [label.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:3],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-6],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:3],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-3],

        [iconView.topAnchor constraintEqualToAnchor:container.topAnchor constant:3],
        [iconView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-3],
    ]];

    return container;
}

/// Build an icon-only badge (no text, just the icon on a rounded brand-colored background)
/// For tight spaces, such as the small loader icon on the right of a version row
+ (UIView *)createIconBadgeForLoader:(NSString *)loader
                      traitCollection:(UITraitCollection *)traitCollection
                                size:(CGFloat)size {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIColor *brandColor = [self brandColorForLoader:loader];

    // Rounded background
    container.backgroundColor = [brandColor colorWithAlphaComponent:0.15];
    container.layer.cornerRadius = size / 3.0;
    container.layer.cornerCurve = kCACornerCurveContinuous;

    // Icon
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self configureImageView:iconView forLoader:loader traitCollection:traitCollection];
    [container addSubview:iconView];

    CGFloat iconSize = size * 0.62;
    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:size],
        [container.heightAnchor constraintEqualToConstant:size],

        [iconView.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:iconSize],
        [iconView.heightAnchor constraintEqualToConstant:iconSize],
    ]];

    return container;
}

#pragma mark - Utility methods

/// Whether a loader name is a known loader (used to filter what is shown)
+ (BOOL)isKnownLoader:(NSString *)loader {
    if (!loader || loader.length == 0) return NO;
    NSString *lower = loader.lowercaseString;
    if ([lower containsString:@"fabric"])     return YES;
    if ([lower containsString:@"quilt"])      return YES;
    if ([lower containsString:@"forge"])      return YES;
    if ([lower containsString:@"neoforge"])   return YES;
    if ([lower containsString:@"optifine"])   return YES;
    if ([lower containsString:@"optifabric"]) return YES;
    if ([lower containsString:@"iris"])       return YES;
    if ([lower containsString:@"rift"])       return YES;
    if ([lower containsString:@"vanilla"])    return YES;
    return NO;
}

/// Detect the loader type from a version ID string
/// For example "1.20.1-Fabric-0.15.7" -> "fabric" and "1.20.1-forge-47.2.0" -> "forge"
+ (NSString *)detectLoaderFromVersionId:(NSString *)versionId {
    if (!versionId || versionId.length == 0) return nil;
    NSString *lower = [versionId lowercaseString];

    // Mind the order: neoforge before forge
    if ([lower containsString:@"neoforge"])   return @"neoforge";
    if ([lower containsString:@"forge"])      return @"forge";
    if ([lower containsString:@"optifabric"]) return @"optifabric";
    if ([lower containsString:@"optifine"])   return @"optifine";
    if ([lower containsString:@"quilt"])      return @"quilt";
    if ([lower containsString:@"fabric"])     return @"fabric";
    if ([lower containsString:@"iris"])       return @"iris";
    if ([lower containsString:@"rift"])       return @"rift";
    return nil;
}

@end
