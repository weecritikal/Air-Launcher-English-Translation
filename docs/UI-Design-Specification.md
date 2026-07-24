# Air 启动器 UI 设计规范

> 版本：1.2 · 适用于 Amethyst-iOS-MyRemastered（Air）项目全部原生界面
>
> 本规范基于对项目中"好看的下载类界面"（DownloadViewController / ModVersionViewController / VersionCardCell 等）与"难看的实例管理界面"（VersionManagerViewController）的对比分析提炼而成。下载类界面是本规范的**正面基准**，实例管理界面是**反面教材**。
>
> v1.1 融合 ZalithLauncher2（ZL2）的 Material Design 3 Expressive 实践：引入 **MD3 Surface 容器层级**、**CardPosition 拼接机制**、**JellyBounce 缓动**、**连锁进场动画**、**Shimmer 骨架屏**等。Air 仍以 iOS 原生毛玻璃 + 系统色为基底，MD3 元素作为视觉层次的补充。
>
> v1.2 新增 **语义化颜色访问器**（15.9）、**四种缓动类型**（15.10）、**背景透明度联动**（15.11）三节，进一步对齐 ZL2 的工程化实践。

---

## 目录

1. [设计理念](#1-设计理念)
2. [颜色系统](#2-颜色系统)
3. [字体系统](#3-字体系统)
4. [间距与布局](#4-间距与布局)
5. [圆角、阴影与边框](#5-圆角阴影与边框)
6. [卡片容器规范](#6-卡片容器规范)
7. [Pill 标签系统](#7-pill-标签系统)
8. [图标规范](#8-图标规范)
9. [状态与交互](#9-状态与交互)
10. [状态视图（空/加载/错误）](#10-状态视图空加载错误)
11. [Bento Grid 便当盒布局](#11-bento-grid-便当盒布局)
12. [禁止清单（反面教材）](#12-禁止清单反面教材)
13. [组件复用指南](#13-组件复用指南)
14. [自检清单](#14-自检清单)
15. [MD3 Expressive 融合（v1.1 新增，v1.2 扩展）](#15-md3-expressive-融合v11-新增v12-扩展)

---

## 1. 设计理念

Air 的视觉语言可概括为 **"克制中的层次"**，核心有四：

1. **毛玻璃 + 自定义壁纸**：通过 `BackgroundManager` 让所有卡片透出用户壁纸，这是 Air 区别于 PojavLauncher 原版的核心卖点。
2. **纯色 + 圆角 + 阴影 + 边框**：**不使用渐变色、不使用装饰条**，仅靠四要素的组合营造高级感，符合 iOS HIG 的克制美学与 Bento Grid 设计语言。
3. **系统色优先 + 语义化品牌色**：文字一律用 `labelColor` 系列系统色自动适配深浅模式与亮色壁纸；类型/来源/加载器用固定的语义色块区分。
4. **MD3 Expressive 层次补充**（v1.1）：借鉴 ZL2 的 MD3 实践，引入 **5 级 Surface 容器层级**、**CardPosition 拼接**、**JellyBounce 缓动**、**连锁进场动画**等，作为视觉层次的补充。Air 仍是 iOS 原生界面，不使用 Compose/Material Theme，仅吸收 MD3 的设计理念映射到 UIKit。

**三句话判断一个界面是否符合规范**：
- 换成亮色壁纸后，文字是否仍然清晰可读？
- 卡片是否有"扁平 → 立体 → 详情"的视觉层次（含 MD3 Surface 容器层级）？
- 关键信息是否突出、次要信息是否弱化、操作入口是否明显？

---

## 2. 颜色系统

### 2.1 文字色 —— 强制使用系统色

**所有文字必须使用 `labelColor` 系列系统色，禁止硬编码 `[UIColor whiteColor]` 或硬编码 RGB。**

| 层级 | 用途 | 颜色 |
|------|------|------|
| 主文字 | 标题、名称、版本号 | `UIColor.labelColor` |
| 副文字 | 副标题、日期、作者 | `UIColor.secondaryLabelColor` |
| 元文字 | 描述、提示、计数 | `UIColor.tertiaryLabelColor` |
| 占位 | 极次要信息 | `UIColor.quaternaryLabelColor` |

理由：系统色会随深浅模式**和用户壁纸亮度**自动适配。硬编码白色在亮色壁纸下几乎不可见——这是实例管理页面难看的根本原因。

```objc
// ✅ 正确
self.nameLabel.textColor = [UIColor labelColor];
self.versionLabel.textColor = [UIColor secondaryLabelColor];

// ❌ 错误（实例管理页的反面教材）
self.nameLabel.textColor = [UIColor whiteColor];
self.versionLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
```

### 2.2 主题强调色

使用全局函数 `accentColor()`，默认 `#429CF5`，可通过 `general.accent_color` 偏好覆盖。

```objc
UIColor *accent = accentColor(); // 不要用 [UIColor systemBlueColor] 硬编码
```

**适用场景**：选中态边框、进行中状态、推荐标记、进度条、主要操作按钮、选中徽章。

### 2.3 语义状态色（三态固定映射）

| 状态 | 颜色 | SF Symbol | 含义 |
|------|------|-----------|------|
| 成功/已完成/稳定版 | `systemGreenColor` | `checkmark.circle.fill` | Release、已安装、下载完成 |
| 进行中/选中/推荐 | `accentColor()` | `circle.dotted` | 下载中、当前选中、推荐项 |
| 待办/未选中/占位 | `tertiaryLabelColor` | `circle` | 未开始、默认态 |
| 失败/警告/测试版 | `systemOrangeColor` | `exclamationmark.triangle.fill` | Beta、出错 |
| 危险/Alpha/远古 | `systemRedColor` / `systemPurpleColor` | — | Alpha、删除操作 |

**禁止自创状态色**，必须从上表选取。

### 2.4 资源类型语义色

| 资源类型 | 颜色 | SF Symbol |
|----------|------|-----------|
| Mod | `systemOrangeColor` | `puzzlepiece.fill` |
| Shader 光影 | `systemPurpleColor` | `paintbrush.fill` |
| Resourcepack 资源包 | `systemBlueColor` | `photo.stack.fill` |
| Datapack 数据包 | `systemTealColor` | `doc.text.fill` |
| World 世界 | `systemGreenColor` | `globe.asia.australia.fill` |
| Modpack 整合包 | `systemPinkColor` | `shippingbox.fill` |

### 2.5 下载源品牌色（强制彩色 box）

| 来源 | 颜色 |
|------|------|
| Modrinth | `systemGreenColor` |
| CurseForge | `systemOrangeColor` |
| BMCLAPI | `systemBlueColor` |
| 官方/其他 | `systemGrayColor` |

**来源标签必须用彩色 pill box，禁止用纯文本**（如 `"[Modrinth·server] 下载:xxx"`）。

### 2.6 加载器品牌色

统一委托 `ModLoaderIconHelper.brandColorForLoader:`，禁止各处自行硬编码：

| 加载器 | 颜色 |
|--------|------|
| Fabric | 蓝 |
| Forge | 棕 |
| Quilt | 红 |
| NeoForge | 橙 |
| Iris / OptiFine | 紫 |

### 2.7 MD3 Surface 容器层级（v1.1 · 借鉴 ZL2）

借鉴 ZL2 的 MD3 Surface 容器层级，Air 将"卡片背景三层策略"扩展为**五级 Surface 容器 + Dim/Bright**，用于精细控制卡片的视觉浮起程度。**毛玻璃仍是基底**，Surface 容器层级通过 alpha 微调实现。

| MD3 角色 | Air 映射（深色） | Air 映射（浅色） | 用途 |
|----------|------------------|------------------|------|
| `surfaceContainerLowest` | 白 0.04 alpha | 白 0.50 alpha | 最低层：嵌套卡片底色、列表分隔区 |
| `surfaceContainerLow` | 白 0.06 alpha | 白 0.55 alpha | 低层：扁平条目（L1）背景 |
| `surfaceContainer` | 白 0.08 alpha | 白 0.60 alpha | 默认层：标准卡片（L2）背景 |
| `surfaceContainerHigh` | 白 0.10 alpha | 白 0.65 alpha | 高层：详情卡片（L3）背景 |
| `surfaceContainerHighest` | 白 0.12 alpha | 白 0.70 alpha | 最高层：浮球、FAB、模态弹窗 |
| `surfaceDim` | 白 0.04 + 黑 0.10 叠加 | 白 0.45 + 黑 0.05 叠加 | 暗化背景：禁用态卡片、阴影区 |
| `surfaceBright` | 白 0.14 alpha | 白 0.75 alpha | 提亮卡片：选中态浮起、焦点卡片 |

**映射原则**：iOS 没有 MD3 的 tone 系统，Air 通过"白色 alpha 叠加 + 毛玻璃"模拟 Surface 容器层级。**所有 Surface 容器层级都必须叠加 `BackgroundManager` 毛玻璃**，禁止用纯色替代。

```objc
// ✅ v1.1 推荐：通过 AirSurface 工具类获取容器色（待抽取）
UIColor *cardBg = [AirSurface containerColorForLevel:AirSurfaceLevelDefault];  // 白 0.08
UIColor *highBg = [AirSurface containerColorForLevel:AirSurfaceLevelHigh];      // 白 0.10
// 毛玻璃仍由 BackgroundManager 提供
[[BackgroundManager sharedManager] applyEffectToView:card];
```

**禁止**：
- 跳过层级直接用 `surfaceContainerHighest`（白 0.12）做扁平条目——会破坏视觉层次
- 在同一界面内混用超过 3 个层级——视觉混乱

### 2.8 Outline 边框语义（v1.1 · 借鉴 ZL2）

借鉴 MD3 的 `outline` / `outlineVariant`，Air 将边框色语义化：

| MD3 角色 | Air 映射 | 用途 |
|----------|----------|------|
| `outline` | 白 0.20 alpha（深色）/ 黑 0.12 alpha（浅色） | 强调边框：输入框未聚焦、分隔线 |
| `outlineVariant` | 白 0.10 alpha（深色）/ 黑 0.06 alpha（浅色） | 弱化边框：卡片默认描边、chip 未选中描边 |

```objc
// ✅ v1.1 推荐
card.layer.borderColor = [AirOutline variantColor].CGColor;  // 默认描边
inputField.layer.borderColor = [AirOutline outlineColor].CGColor;  // 强调描边
```

### 2.9 Disabled 状态规范（v1.1 · 借鉴 ZL2）

统一禁用态透明度为 **0.38**（对齐 MD3 官方 `DisabledAlpha`）：

```objc
// ✅ v1.1 推荐
if (!self.enabled) {
    self.alpha = 0.38;  // 整体禁用态
    // 或仅文字禁用
    self.titleLabel.textColor = [[UIColor labelColor] colorWithAlphaComponent:0.38];
}
```

**禁止**：禁用态使用 0.3 / 0.5 / 0.45 等其他透明度值（项目历史遗留不一致）。

---

## 3. 字体系统

### 3.1 字号梯度（必须严格遵守）

| Token | 字号 | 字重 | 用途 |
|-------|------|------|------|
| `display` | 36pt | Heavy | 安装百分比等超大数字 |
| `title1` | 20–26pt | Bold | 页面主标题、安装页标题 |
| `title2` | 18pt | Bold | 详情头部标题 |
| `title3` | 15–16pt | Semibold | 卡片主标题（版本号、名称） |
| `body` | 13pt | Medium | 列表项标题 |
| `subhead` | 12pt | Regular | 副标题、版本号副、chip 文字 |
| `caption1` | 11pt | Regular | 日期、大小、游戏版本、元信息 |
| `caption2` | 10pt | Medium | 尺寸标签、极次要信息 |
| `pill` | 11pt | Bold | 类型 pill、徽章文字 |
| `badge` | 9pt | Bold | 加载器徽章、发布类型徽章 |

**禁止使用上表以外的字号**。

### 3.2 API 规范

```objc
// ✅ 推荐：统一使用带 weight 的 API
[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];

// ⚠️ 仅在明确不需要字重控制时使用
[UIFont boldSystemFontOfSize:15];

// ❌ 禁止：不同文件混用多种 API 风格
//    VersionManager 用 [ScreenUtils sp:13]
//    ModTableViewCell 用 [UIFont boldSystemFontOfSize:13]
//    NewsVC 用 [UIFont systemFontOfSize:15 weight:...]
```

### 3.3 数字与对齐

- 文件大小：统一用 `NSByteCountFormatterCountStyleFile`。
- 下载量：用 `1.2K / 1.2M` 格式化。
- 百分比/计数等需对齐的数字：可用 `[UIFont monospacedDigitSystemFontOfSize:weight:]`。

### 3.4 Dynamic Type

- 主体内容（卡片标题/副标题）允许设置 `adjustsFontSizeToFitWidth = YES` + `minimumScaleFactor = 0.7~0.8`，保证极端宽度不截断。
- 空状态/说明文字鼓励用 `[UIFont preferredFontForTextStyle:UIFontTextStyleBody]` 启用 Dynamic Type。
- 紧凑型磁贴（Bento Grid 磁贴）可关闭 `adjustsFontForContentSizeCategory` 以维持布局稳定。

### 3.5 MD3 Type Scale 对齐（v1.1 · 借鉴 ZL2）

ZL2 直接使用 MD3 默认 Typography（Display/Headline/Title/Body/Label 各 Large/Medium/Small 共 15 级）。Air 仍以 iOS 系统字号为主，但**新增语义化字体角色映射**，便于跨平台对齐：

| MD3 角色 | Air Token（第 3.1 节） | 用途对齐 |
|----------|------------------------|----------|
| `displayLarge` | `display` (36pt Heavy) | 安装百分比、超大数字 |
| `headlineLarge` | `title1` (20-26pt Bold) | 页面主标题 |
| `headlineMedium` | `title2` (18pt Bold) | 详情头部标题 |
| `titleMedium` | `title3` (15-16pt Semibold) | 卡片主标题 |
| `bodyMedium` | `body` (13pt Medium) | 列表项标题 |
| `bodySmall` | `subhead` (12pt Regular) | 副标题 |
| `labelLarge` | `pill` (11pt Bold) | Pill 标签、按钮文字 |
| `labelSmall` | `badge` (9pt Bold) | 加载器徽章 |
| `bodySmall` (次要) | `caption1` (11pt Regular) | 日期、大小 |

**映射原则**：Air 不强制使用 MD3 字号，但新增界面应能从上表找到对应的语义角色。**禁止**使用上表以外的字号（与原规范一致）。

---

## 4. 间距与布局

### 4.1 间距令牌

| Token | 值 | 用途 |
|-------|----|------|
| `space-xs` | 3pt | 磁贴 item 内边距、stack 内极小间距 |
| `space-bento` | 2pt | **Bento Grid 卡片拼接间距**（v1.1 · 借鉴 ZL2 `SettingsCardColumn.spacedBy(2.dp)`） |
| `space-sm` | 4pt | 卡片上下外间距、表格行间距、筛选行间距、卡片内 tight 元素间距 |
| `space-md` | 6pt | chip 间距、筛选面板内边距 |
| `space-lg` | 8pt | 卡片内 padding（上下）、sectionInset 上下、按钮 icon-text 间距 |
| `space-xl` | 12pt | Bento Grid 卡片间距、卡片内 padding（左右）、屏幕外边距、主流卡片间距 |
| `space-2xl` | 14pt | Bento Grid contentInset 左右、版本卡片左右内边距 |
| `space-3xl` | 16pt | sectionInset 左右、大卡片内 padding、卡片内 innerPadding |

**v1.1 新增 `space-bento` (2pt)**：用于 Bento Grid 卡片拼接（CardPosition 拼接机制，见第 15.2 节），让多张卡片视觉上合并为一个"便当盒"分组。**禁止**用 `space-sm`(4pt) 或更大间距做拼接——会破坏视觉合并效果。

### 4.2 卡片内边距标准

| 卡片类型 | 上下 | 左右 |
|----------|------|------|
| 版本卡片（VersionCardCell） | 14pt | 14pt |
| Mod/Shader 卡片 | 8–14pt | 10pt |
| 详情大卡片（AssetDetailHeaderView） | 16pt | 16pt |
| Bento 磁贴 | 12pt | 12pt |

### 4.3 列表间距标准

```objc
// UICollectionViewFlowLayout
layout.minimumLineSpacing = 4;
layout.sectionInset = UIEdgeInsetsMake(8, 16, 8, 16);

// UITableView
self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone; // 用卡片间距代替分隔线
```

### 4.4 布局方式

- **统一使用代码 + `NSLayoutConstraint`**，禁止 Storyboard / XIB。
- 顶部约束用 `safeAreaLayoutGuide.topAnchor`（全屏覆盖式页面除外）。
- iPhone/iPad 适配用 `UIDevice.model` 物理检测，宽度常量分 `Pad` / `Phone` 两套。

---

## 5. 圆角、阴影与边框

### 5.1 圆角分层（核心规范）

| 层级 | 元素 | 圆角 | `cornerCurve` | MD3 对应（v1.1） |
|------|------|------|---------------|-------------------|
| L1 扁平条目 | ModernAssetCell、按钮 | 8pt | `kCACornerCurveContinuous` | `shapes.small` (8dp) |
| L2 标准卡片 | 版本卡片、Mod/Shader 卡片 | 12pt | `kCACornerCurveContinuous` | `shapes.medium` (12dp) |
| L3 大卡片 | 详情头部、浮动卡片 | 16pt | `kCACornerCurveContinuous` | `shapes.large` (16dp) |
| L4 磁贴 | Bento Grid 磁贴 | 12pt | `kCACornerCurveContinuous` | `shapes.medium` (12dp) |
| L5 圆形 | 头像、FAB、徽章圆点 | = 高度/2 | — | `CircleShape` |
| L6 超大卡片（v1.1） | Bento 分组外框、模态卡片 | 28pt | `kCACornerCurveContinuous` | `shapes.extraLarge` (28dp) |
| L7 微圆角（v1.1） | 标签内嵌元素、分隔块 | 4pt | `kCACornerCurveContinuous` | `shapes.extraSmall` (4dp) |
| L8 胶囊形（v1.1） | 搜索框、Pill 标签 | = 高度/2 | `kCACornerCurveContinuous` | `RoundedCornerShape(percent=50)` |

**必须设置 `cornerCurve = kCACornerCurveContinuous`**（iOS 13+ 连续圆角，比传统圆弧更柔和）。

**v1.1 新增档位**：
- **L6 超大卡片 (28pt)**：借鉴 ZL2 `shapes.extraLarge`，用于 Bento Grid 分组外框（CardPosition 拼接的整组卡片）、模态弹窗、设置分组。**仅用于视觉焦点**，不可滥用。
- **L7 微圆角 (4pt)**：借鉴 ZL2 `shapes.extraSmall`，用于卡片内嵌的小元素（如 MemoryPreview、Tile 内部分隔块）。
- **L8 胶囊形**：借鉴 ZL2 `RoundedCornerShape(percent=50)`，用于搜索框、Pill 标签。圆角 = 高度/2，形成完美圆形端。

**禁止使用** 4/8/12/16/28 以外的圆角值（14pt 是反面教材，来自 ThirdPartyLoginViewController 内部不一致；24pt 也不再允许，统一用 28pt）。

### 5.2 阴影规格（仅三档）

| 档位 | opacity | radius | offset | 适用 |
|------|---------|--------|--------|------|
| 轻阴影 | 0.10 | 4 | (0, 2) | 标准卡片 Cell |
| 中阴影 | 0.12 | 6–8 | (0, 3–4) | 大卡片、Bento 磁贴 |
| 重阴影 | 0.18 | 12 | (0, 4) | 浮动元素（FAB、下载浮球） |

**禁止使用** 上表以外的阴影参数。实例管理页的 `(0.12, 6, (0,3))` 与下载页的 `(0.10, 4, (0,2))` 不一致是已知问题，新建界面一律按上表对齐。

**注意**：设置阴影时 `masksToBounds` 必须 = `NO`；若同时需要裁剪子视图的圆角，用 `shadowPath` 而非 `masksToBounds = YES`（否则阴影被裁掉，见 LauncherRightPanelViewController 启动按钮的反面教材）。

```objc
// ✅ 正确：用 shadowPath 保留阴影
self.layer.shadowOpacity = 0.10;
self.layer.shadowRadius = 4;
self.layer.shadowOffset = CGSizeMake(0, 2);
self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:12].CGPath;
self.layer.masksToBounds = NO; // 保留阴影
self.contentView.layer.cornerRadius = 12;
self.contentView.layer.masksToBounds = YES; // 仅裁剪 contentView
```

### 5.3 边框规格

| 场景 | width | color |
|------|-------|-------|
| 默认卡片描边 | 0.5pt | `[UIColor whiteColor]` alpha 0.10 |
| 选中态描边 | 1.5pt | `accentColor()` |
| 推荐态描边 | 1.0pt | `[accentColor() colorWithAlphaComponent:0.4]` |
| 输入框描边 | 0.5–1.0pt | `separatorColor` / 焦点态 `accentColor()` |

---

## 6. 卡片容器规范

### 6.1 三层视觉分层（下载界面好看的核心）

界面内必须存在**渐进的视觉层次**，禁止所有卡片用同一规格：

| 层级 | 角色 | 圆角 | 阴影 | 典型元素 |
|------|------|------|------|----------|
| L1 | 列表项（信息密集） | 8pt | 无 | ModernAssetCell |
| L2 | 标准卡片（中等信息） | 12pt | 轻阴影 | VersionCardCell、ModVersionTableViewCell |
| L3 | 详情/焦点卡片（突出） | 16pt | 中阴影 | AssetDetailHeaderView、下载浮球 |
| L4 | Bento 磁贴（可交互） | 12pt | 中阴影 + 按压动画 | VMTileBaseCell 系列 |

### 6.2 卡片背景三层策略（强制）

所有卡片必须按以下三层叠加：

```objc
// 第 1 层：浅色半透明基底
card.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08]; // 0.06~0.10

// 第 2 层：BackgroundManager 毛玻璃
[[BackgroundManager sharedManager] applyEffectToView:card];

// 第 3 层：边框 + 阴影（见第 5 章）
card.layer.cornerRadius = 12;
card.layer.cornerCurve = kCACornerCurveContinuous;
card.layer.borderWidth = 0.5;
card.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
card.layer.shadowColor = [UIColor blackColor].CGColor;
card.layer.shadowOpacity = 0.10;
card.layer.shadowRadius = 4;
card.layer.shadowOffset = CGSizeMake(0, 2);
```

**禁止用纯色 `secondarySystemBackgroundColor` 替代毛玻璃**（ForgeInstallSchemeViewController 的反面教材，在自定义壁纸下视觉割裂）。

### 6.3 卡片 alpha 统一

- 半透明基底 alpha 统一 **0.08**（范围 0.06~0.10）。
- 主界面壳层卡片叠加自定义色时 alpha 统一（当前 RootVC=0.85 / CardLayoutVC=0.7 不一致，新代码统一取 **0.7**，与便当盒外边距风格配套）。

---

## 7. Pill 标签系统

所有标签（chip、徽章、类型标记）统一使用 **pill 样式**：圆角 = 高度 / 2，形成完美圆形端。

### 7.1 Chip 筛选条（统一实现）

```objc
- (UIButton *)createFilterChipWithTitle:(NSString *)title selected:(BOOL)selected {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    [chip setTitle:title forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    chip.titleLabel.adjustsFontSizeToFitWidth = YES;
    chip.titleLabel.minimumScaleFactor = 0.75;
    chip.contentEdgeInsets = UIEdgeInsetsMake(4, 12, 4, 12);
    chip.layer.cornerRadius = 14;                       // = 高度 28 / 2
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.layer.masksToBounds = YES;
    [chip.heightAnchor constraintEqualToConstant:28].active = YES;
    [self applyChipStyle:chip selected:selected];
    return chip;
}

- (void)applyChipStyle:(UIButton *)chip selected:(BOOL)selected {
    if (selected) {
        chip.backgroundColor = accentColor();
        [chip setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        chip.layer.borderWidth = 0;
    } else {
        chip.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [chip setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        chip.layer.borderWidth = 0.5;
        chip.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15].CGColor;
    }
}
```

**此实现已在 ModVersion/ShaderVersion/AssetVersion 三个 VC 重复 3 次，新代码必须抽取为公共组件 `FilterChipPanel`，禁止第 4 次复制。**

### 7.2 加载器徽章

- 高度 ~16pt，圆角 8pt，9pt Bold 白字。
- 背景 = `ModLoaderIconHelper.brandColorForLoader:` 返回值。
- 最多显示 4 个，超出用 `+N` pill 兜底。

### 7.3 版本类型 pill

- 高度 ~18pt，圆角 9pt，11pt Bold 白字。
- release → `systemGreenColor` + `cube.fill` 图标
- snapshot → `systemOrangeColor` + `hammer.fill`
- old_alpha / old_beta → `systemPurpleColor` + `clock.fill`

### 7.4 来源标签（强制彩色 box）

```objc
// ✅ 正确：彩色 pill
UILabel *badge = ...;
badge.backgroundColor = isModrinth ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
badge.textColor = [UIColor whiteColor];

// ❌ 错误：纯文本（ServerListViewController / ModUpdateViewController 的违规点）
cell.detailTextLabel.text = @"[Modrinth·server] 下载:123";
```

---

## 8. 图标规范

### 8.1 尺寸规格

| 元素 | 尺寸 | 圆角 |
|------|------|------|
| 列表项小图标（ModernAssetCell） | 26×26 | 5pt |
| 标准卡片图标本体 | 22×22 | — |
| 标准卡片图标容器 | 40×40 | 10pt |
| 详情头部封面 | 72×72 | 14pt |
| Bento 磁贴图标 | 24–30pt | — |
| 已安装徽章 | 14×14 | 7pt（圆点） |
| 选中徽章 | 16–20×16–20 | 8–10pt |
| FAB 浮动按钮 | 36×36 | 18pt（圆） |

### 8.2 图标容器（强制）

**图标必须放在带背景色的圆角容器内，禁止裸放 SF Symbol。**

```objc
// ✅ 正确：VersionCardCell 的图标容器
self.iconContainer = [[UIView alloc] init];
self.iconContainer.backgroundColor = [UIColor systemGreenColor]; // 类型语义色
self.iconContainer.layer.cornerRadius = 10;
self.iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
self.iconImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"VanillaIcon"]];
// 22×22 图标本体居中在 40×40 容器内

// ❌ 错误：VMVersionCardCell 的裸图标（反面教材）
self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
self.iconView.tintColor = [UIColor systemBlueColor]; // 单调蓝，无容器无类型色
```

### 8.3 图标加载

- 远程图标统一用 `IconLoader loadIconForImageView:URL:placeholder:fallback:targetSize:options:completion:`，自带双层缓存 + CDN 镜像 + 降采样。
- `prepareForReuse` 必须调用 `cancelLoadingForImageView:` 防止复用竞态。
- **禁止用 AFNetworking 的 `setImageWithURL:`**（ServerListViewController 的违规点）。

### 8.4 占位与兜底

- 占位图：按资源类型用对应 SF Symbol（见 2.4）。
- 加载失败：回退到占位 SF Symbol，禁止显示破图。

---

## 9. 状态与交互

### 9.1 选中态三层强化

选中态必须同时具备以下三层视觉反馈（实例管理页只有第 1 层，不够）：

1. **边框**：1.5pt `accentColor()` 描边
2. **徽章**：右上角 `accentColor()` 圆点 + 白色 `checkmark`
3. **背景**（可选）：`[accentColor() colorWithAlphaComponent:0.08]` 轻染色

```objc
if (isSelected) {
    self.contentView.layer.borderColor = accentColor().CGColor;
    self.contentView.layer.borderWidth = 1.5;
    self.selectedBadge.hidden = NO;
} else {
    self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
    self.contentView.layer.borderWidth = 0.5;
    self.selectedBadge.hidden = YES;
}
```

### 9.2 按压动画（Bento 磁贴必备）

```objc
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.25 delay:0
         usingSpringWithDamping:0.7 initialSpringVelocity:0.8
         options:UIViewAnimationOptionAllowUserInteraction
         animations:^{ self.transform = CGAffineTransformMakeScale(0.96, 0.96); }
         completion:nil];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.25 delay:0
         usingSpringWithDamping:0.7 initialSpringVelocity:0.8
         options:UIViewAnimationOptionAllowUserInteraction
         animations:^{ self.transform = CGAffineTransformIdentity; }
         completion:nil];
}
// touchesCancelled 同 touchesEnded
```

### 9.3 操作入口可见性

**禁止把主要操作藏在长按手势里**（实例管理页的反面教材）。

| 操作优先级 | 展示方式 |
|------------|----------|
| 主操作（启动/切换实例） | Cell 内显式按钮，或整卡可点 + chevron 暗示 |
| 次操作（启用/禁用、下载） | Cell 内显式按钮/开关 |
| 危险操作（删除） | 长按菜单或滑动操作 |
| 批量操作 | 导航栏"编辑"按钮进入多选 |

**Cell 可点击时必须显示 `chevron.right` 暗示**（`tertiaryLabelColor`），实例管理页缺失 chevron 是严重问题。

### 9.4 chevron 指示

```objc
self.chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
self.chevronView.tintColor = [UIColor tertiaryLabelColor];
```

### 9.5 Focused 边框动画（v1.1 · 借鉴 ZL2）

借鉴 ZL2 `SmallOutlinedEditField` 的焦点态：**边框宽度 1pt → 2pt 动画 + 颜色切换**。

```objc
// ✅ v1.1 推荐：输入框焦点态
- (void)updateFocusState:(BOOL)focused {
    [UIView animateWithDuration:0.2 animations:^{
        self.layer.borderWidth = focused ? 2.0 : 1.0;
        self.layer.borderColor = focused
            ? accentColor().CGColor
            : [AirOutline outlineColor].CGColor;
    }];
}
```

### 9.6 Selected 扩散动画（v1.1 · 借鉴 ZL2）

借鉴 ZL2 `TextRailItem` 的选中态：**胶囊背景从中心向两侧扩散**（300ms `FastOutSlowInEasing`）。

```objc
// ✅ v1.1 推荐：NavigationRail 项选中态
- (void)updateSelectedState:(BOOL)selected {
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.selectedBgWidth.constant = selected ? self.maxWidth : self.minWidth;
        self.selectedBgCenterX.constant = 0;  // 始终居中
        [self.layoutIfNeededIfNeeded];
    }];
}
```

### 9.7 Disabled 状态（v1.1 · 借鉴 ZL2）

统一禁用态透明度为 **0.38**（见第 2.9 节），禁止使用其他透明度值。

---

## 10. 状态视图（空/加载/错误）

### 10.1 统一规范

所有列表页必须实现三种状态视图，禁止"无空状态"（实例管理页的反面教材）：

| 状态 | 实现 | 内容 |
|------|------|------|
| 加载中 | `UIActivityIndicatorView`（Large，居中）+ `hidesWhenStopped = YES` | 可选副标题"正在加载…" |
| 空 | 居中 `UILabel` + SF Symbol 图标 | 文案 + 引导操作（如"去下载"按钮） |
| 错误 | `InlineMessageView` 或居中错误图 + 重试按钮 | 错误描述 + "重试"按钮 |

### 10.2 空状态实现参考

```objc
self.emptyLabel.text = hasQuery ? @"未匹配到版本" : @"暂无版本";
self.emptyLabel.textColor = [UIColor secondaryLabelColor];
self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; // 启用 Dynamic Type
self.emptyLabel.textAlignment = NSTextAlignmentCenter;
```

**实例管理页首次安装时只有 1 个默认 profile，必须显示引导卡**（"还没有版本，点右上角 + 下载吧"），禁止显示孤零零一行。

### 10.3 加载状态

- 列表首次加载：中央大转圈。
- 分页加载更多：底部小转圈或自动加载。
- Cell 内异步操作：`activityIndicatorView` 作为 `accessoryView`。

### 10.4 错误状态

- API 错误优先用 `InlineMessageView`（含 Loading/Error/Success/Info 四态），不用 `UIAlertController` 打断。
- 仅在需要用户确认的危险操作上用 `UIAlertController`。

---

## 11. Bento Grid 便当盒布局

### 11.1 布局原则

- 用 `UICollectionViewCompositionalLayout`（禁用老旧的 `UICollectionViewFlowLayout` 做主页）。
- 卡片之间有 `space-xl (12pt)` 间距 + 外边距（iPad 12pt / iPhone 8pt）。
- 每个 section 有明显的视觉分组（header + 留白）。

### 11.2 磁贴基类

所有 Bento 磁贴继承 `VMTileBaseCell`（或抽取的公共基类），统一获得：
- 阴影（中阴影档）
- 圆角（12pt + continuous）
- 毛玻璃（`applyEffectToCollectionViewCell:`）
- 按压弹簧动画

### 11.3 禁止"伪 Bento"

实例管理页的失败教训：原本设计的"快捷操作磁贴 + 渲染器选择磁贴"被砍掉后，bento grid 退化成"横向小卡片 + 纵向列表"两条列表，**丧失了便当盒的视觉魅力**。

**Bento Grid 必须至少有 2 种以上不同尺寸的磁贴混排**，禁止全部磁贴等高等宽。

### 11.4 Section Header

```objc
// 毛玻璃背景 + 标题 + 副标题
header.backgroundView = 毛玻璃视图;
header.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
header.titleLabel.textColor = [UIColor labelColor]; // 不要硬编码白色
header.subtitleLabel.font = [UIFont systemFontOfSize:11];
header.subtitleLabel.textColor = [UIColor secondaryLabelColor];
```

---

## 12. 禁止清单（反面教材）

以下问题均来自实例管理页（VersionManagerViewController）的实际代码，**新建/重构界面时必须规避**：

### 12.1 颜色类

- ❌ 硬编码 `[UIColor whiteColor]` 作为文字色 → 亮色壁纸下不可见
- ❌ 硬编码 RGB 作为徽章色 → 不适配深色模式（AccountListViewController 也犯此错）
- ❌ `systemBlueColor` 硬编码替代 `accentColor()`（LauncherProfileEditorViewController）
- ❌ 同一界面内 cornerRadius 出现 14pt 和 16pt 两种值（ThirdPartyLoginViewController）

### 12.2 图标类

- ❌ 裸放 SF Symbol 无圆角容器（VMVersionCardCell）
- ❌ 所有版本用同一个 `cube.box.fill` 蓝色图标，无类型色无加载器色
- ❌ 用 AFNetworking `setImageWithURL:` 而非 `IconLoader`（ServerListViewController）

### 12.3 交互类

- ❌ 缺 chevron 暗示可点击
- ❌ 主操作藏在 0.5s 长按手势里
- ❌ 无批量操作（编辑/多选/批量删除）
- ❌ 无空状态引导
- ❌ 选中态仅靠 1.5pt 边框，无背景/徽章对比

### 12.4 信息密度类

- ❌ 卡片只显示 3 个字段（name/version/lastPlayed），无 Mod 数量、加载器、版本类型
- ❌ 用户最关心的"最后游玩"反而用最弱的 10pt + 0.45 alpha
- ❌ Cell 固定 78pt 偏矮，3 行文字挤在一起

### 12.5 布局类

- ❌ Bento Grid 退化成"上下两条列表"（砍掉快捷操作/渲染器磁贴后未补回）
- ❌ 游戏目录卡片 64pt 过矮，与版本卡片 78pt 视觉节奏不统一
- ❌ Section header 与卡片之间无留白，分组层次弱
- ❌ 无"当前选中实例"大卡片作为视觉焦点

### 12.6 工程类

- ❌ `.h` 声明 `UITableViewController`，`.m` 实际用 `UICollectionView`（LauncherProfilesViewController）
- ❌ 死代码：`VMQuickActionCell` / `VMRendererCell` 写了完整实现但从未注册
- ❌ 同名 Cell 两个实现：`VersionCardCell`（下载页，好看）vs `VMVersionCardCell`（实例页，难看），未复用

### 12.7 阴影类

- ❌ 设置阴影参数但 `masksToBounds = YES` 把阴影裁掉（LauncherRightPanelViewController 启动按钮）
- ❌ 同项目两套阴影标准（0.10/4 vs 0.12/6）

---

## 13. 组件复用指南

### 13.1 必须复用的现有资产

| 资产 | 文件 | 用途 |
|------|------|------|
| `BackgroundManager` | `BackgroundManager.h/.m` | 所有毛玻璃/透明化/导航栏外观 |
| `accentColor()` | `LauncherPreferences.m` | 主题强调色 |
| `ModLoaderIconHelper` | `ModLoaderIconHelper.h` | 加载器图标 + 品牌色 |
| `IconLoader` | `IconLoader.h/.m` | 异步图标加载（双层缓存+CDN） |
| `InlineMessageView` | `InlineMessageView.h/.m` | 内联消息（Loading/Error/Success/Info） |
| `PLPrefTableViewController` | `PLPrefTableViewController.h/.m` | 设置类页面基类 |
| `VMTileBaseCell` | `VersionManagerViewController.m` | Bento 磁贴基类（含按压动画） |
| `AssetDetailHeaderView` | `AssetDetailHeaderView.h/.m` | 项目详情头部 |

### 13.2 待抽取的公共组件（当前重复代码）

以下重复代码应在重构时抽取，**禁止在新代码中第 N 次复制**：

| 待抽取组件 | 消除重复 | 来源 |
|------------|----------|------|
| `UIComponents`（颜色/圆角/阴影/字号常量） | 4 处 `hexColor` 重复 + 30+ 处硬编码圆角 | 全项目 |
| `FilterChipPanel` | ~600 行重复 | ModVersion/ShaderVersion/AssetVersion |
| `AssetTableViewCell` 基类 | Mod/Shader Cell 几乎完全相同 | ModTableViewCell/ShaderTableViewCell |
| `BlurCardTableViewCell` | 4 处系统 Cell 内联毛玻璃 | ResourcePacks/DataPacks/Worlds/ServerList |
| `BaseResourceListViewController` | 6 处搜索栏+背景监听模板 | 6 个管理类 VC |
| `CapsuleProgressBar` | 进度条重复实现 | DPVCProgressBar / DPCProgressBar |
| `MD3Colors` | 12 个动态颜色函数复制 2 份 | 两个 CurseForgeAPIKeyViewController |
| `EmptyStateView` | 空状态散乱实现 | 多处 |

### 13.3 基类选择决策树

```
新建页面是设置/表单类？
  ├─ 是 → 继承 PLPrefTableViewController
  └─ 否 → 新建页面是列表/管理类？
           ├─ 是 → 资源类型统一？
           │       ├─ 是 → 抽取 AssetTableViewCell 基类
           │       └─ 否 → 自定义 Cell，但卡片规范遵循第 6 章
           └─ 否 → 新建页面是 Bento Grid 主页？
                    ├─ 是 → 磁贴继承 VMTileBaseCell
                    └─ 否 → 自定义，但颜色/字体/圆角遵循本规范
```

---

## 14. 自检清单

提交 UI 代码前，逐项核对：

### 颜色
- [ ] 文字色全部用 `labelColor` 系列，无硬编码白色/RGB？
- [ ] 主题色用 `accentColor()`，无 `systemBlueColor` 硬编码？
- [ ] 来源标签用彩色 pill，无纯文本？
- [ ] 加载器品牌色通过 `ModLoaderIconHelper` 获取？
- [ ] **（v1.1）** Surface 容器层级使用第 2.7 节映射，未跳级？
- [ ] **（v1.1）** 边框色用 `outline`/`outlineVariant` 语义，非硬编码 alpha？
- [ ] **（v1.2）** 卡片色用 `AirSurface` 语义访问器，无魔法数字 alpha？
- [ ] **（v1.2）** 卡片色随壁纸透明度联动（factor 1.0→0.55）？

### 字体
- [ ] 字号在第 3.1 节梯度表内？
- [ ] API 风格统一用 `systemFontOfSize:weight:`？
- [ ] 文件大小用 `NSByteCountFormatterCountStyleFile`？
- [ ] **（v1.1）** 新增字号能映射到 MD3 Type Scale（第 3.5 节）？

### 圆角/阴影/边框
- [ ] 圆角值在 4/8/12/16/28 五档内（圆形/胶囊除外）？
- [ ] 设置了 `cornerCurve = kCACornerCurveContinuous`？
- [ ] 阴影参数在第 5.2 节三档内？
- [ ] 阴影未被 `masksToBounds = YES` 裁掉？

### 卡片
- [ ] 卡片有三层背景（半透明 + 毛玻璃 + 边框/阴影）？
- [ ] 界面内有 L1/L2/L3 视觉分层，非全部等规格？
- [ ] 未用纯色 `secondarySystemBackgroundColor` 替代毛玻璃？
- [ ] **（v1.1）** Bento 分组用 CardPosition 拼接（2pt 间距 + 28/4pt 圆角）？

### 图标
- [ ] 图标放在带类型色的圆角容器内？
- [ ] 远程图标用 `IconLoader`，非 AFNetworking？
- [ ] 有占位图和兜底图？

### 交互
- [ ] 可点击 Cell 有 chevron 暗示？
- [ ] 主操作有显式按钮，未藏在长按里？
- [ ] 选中态有边框+徽章（至少两层）反馈？
- [ ] Bento 磁贴有按压弹簧动画？
- [ ] **（v1.1）** 禁用态透明度为 0.38？
- [ ] **（v1.1）** 输入框焦点态边框 1→2pt 动画？

### 状态视图
- [ ] 实现了空/加载/错误三态？
- [ ] 空状态有引导操作？
- [ ] 首次使用有引导卡？
- [ ] **（v1.1）** 加载状态用 Shimmer 骨架屏（而非转圈）？

### 布局
- [ ] 用代码 + NSLayoutConstraint，无 Storyboard？
- [ ] Bento Grid 有 ≥2 种尺寸磁贴混排，非等高列表？
- [ ] Section header 与卡片间有留白？

### 动效（v1.1 新增）
- [ ] 列表进场有连锁动画（每项延迟 50ms）？
- [ ] 按压用 JellyBounce 缓动或 Spring 0.7 阻尼？
- [ ] 主题切换有遮罩动画（圆形扩散）？
- [ ] **（v1.2）** 过渡动画用四种缓动类型之一（Close/JellyBounce/Bounce/SliceIn），未自创？

### 工程
- [ ] `.h` 声明与 `.m` 实现一致？
- [ ] 未复制粘贴已存在的公共组件代码？
- [ ] 未留下未注册的死代码 Cell？

---

## 15. MD3 Expressive 融合（v1.1 新增，v1.2 扩展）

本章集中介绍借鉴 ZL2（ZalithLauncher2）Material Design 3 Expressive 实践的增强规范。这些规范**不替代** Air 原有的 iOS 原生设计，而是作为视觉层次的补充。**原则：iOS 优先，MD3 补充**。v1.2 新增 15.9-15.11 三节，进一步对齐 ZL2 的工程化实践。

### 15.1 JellyBounce 缓动函数

借鉴 ZL2 `JellyBounce` 缓动（基于阻尼余弦模型），用于按压回弹、卡片进场等需要"果冻感"的场景。

**数学公式**：`f(t) = 1 - 0.6 * exp(-8*t) * cos(6*π*t)`，3 个震荡周期。

```objc
// ✅ v1.1 推荐：JellyBounce 缓动（用 CAKeyframeAnimation 实现）
- (CAKeyframeAnimation *)jellyBounceAnimation {
    CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    anim.duration = 0.6;
    anim.values = @[@0.95, @1.08, @0.96, @1.03, @1.0];
    anim.keyTimes = @[@0, @0.3, @0.5, @0.75, @1];
    anim.timingFunctions = @[
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]
    ];
    return anim;
}
```

**适用场景**：
- Bento 磁贴按压回弹（替代原 9.2 节的 Spring 0.7 阻尼）
- 卡片进场动画
- 按钮点击反馈

**与 Spring 动画的关系**：原 9.2 节的 `usingSpringWithDamping:0.7` 仍然有效，JellyBounce 是"更果冻"的替代方案，二选一即可。**不强制**使用 JellyBounce。

### 15.2 CardPosition 拼接机制（Bento Grid 核心）

借鉴 ZL2 `_SettingsCard.kt` 的 `CardPosition` 枚举 + `rememberSettingsCardShape`，Air 实现 Bento Grid 卡片拼接：多张卡片用 2pt 间距拼接，外圆角 28pt、内圆角 4pt，视觉上合并为一个"便当盒"分组。

**CardPosition 枚举**（v1.1 新增）：

```objc
typedef NS_ENUM(NSInteger, AirCardPosition) {
    AirCardPositionSingle,       // 独立块：四角 28pt
    AirCardPositionTop,          // 顶部块：上 28pt，下 4pt
    AirCardPositionTopStart,     // 左上块：左上 28pt，其余 4pt
    AirCardPositionTopEnd,       // 右上块：右上 28pt，其余 4pt
    AirCardPositionMiddle,       // 中间块：四角 4pt
    AirCardPositionBottom,       // 底部块：上 4pt，下 28pt
    AirCardPositionBottomStart,  // 左下块：左下 28pt，其余 4pt
    AirCardPositionBottomEnd     // 右下块：右下 28pt，其余 4pt
};
```

**圆角生成**（用 `UIBezierPath bezierPathWithRoundedRect:byRoundingCorners:cornerRadii:`）：

```objc
// ✅ v1.1 推荐：根据 CardPosition 生成圆角路径
- (UIBezierPath *)cornerPathForPosition:(AirCardPosition)position bounds:(CGRect)bounds {
    UIRectCorner corners = 0;
    CGFloat outerRadius = 28, innerRadius = 4;
    CGFloat topLeft, topRight, bottomLeft, bottomRight;
    
    switch (position) {
        case AirCardPositionSingle:
            return [UIBezierPath bezierPathWithRoundedRect:bounds
                                        cornerRadius:outerRadius];
        case AirCardPositionTop:
            corners = UIRectCornerTopLeft | UIRectCornerTopRight;
            return [UIBezierPath bezierPathWithRoundedRect:bounds
                                        byRoundingCorners:corners
                                        cornerRadii:CGSizeMake(outerRadius, outerRadius)];
        case AirCardPositionMiddle:
            return [UIBezierPath bezierPathWithRoundedRect:bounds
                                        cornerRadius:innerRadius];
        case AirCardPositionBottom:
            corners = UIRectCornerBottomLeft | UIRectCornerBottomRight;
            return [UIBezierPath bezierPathWithRoundedRect:bounds
                                        byRoundingCorners:corners
                                        cornerRadii:CGSizeMake(outerRadius, outerRadius)];
        // ... 其他位置类似
    }
}
```

**拼接规范**：
- 间距：`space-bento` (2pt)
- 外圆角：28pt（L6 超大卡片）
- 内圆角：4pt（L7 微圆角）
- 拼接方向：垂直拼接（`UIStackView` axis=vertical, spacing=2）
- 同一分组内卡片**必须**用 CardPosition 拼接，禁止用 12pt 间距独立排列

**适用场景**：
- 设置页分组（替代 `PLPrefTableViewController` 的 section 分组）
- 实例管理页的"快捷操作"分组
- 任何需要"便当盒"视觉合并的场景

### 15.3 连锁进场动画

借鉴 ZL2 `AnimatedColumn` / `AnimatedLazyColumn`，Air 实现列表/卡片的连锁进场：每个 item 延迟 50ms，从上方 -40pt 滑入 + 淡入。

```objc
// ✅ v1.1 推荐：连锁进场动画
- (void)animateItemsInChain:(NSArray<UIView *> *)items {
    CGFloat baseDelay = 0.0;
    CGFloat increment = 0.05;  // 50ms
    for (NSInteger i = 0; i < items.count; i++) {
        UIView *item = items[i];
        CGAffineTransform originalTransform = item.transform;
        item.transform = CGAffineTransformTranslate(originalTransform, 0, -40);
        item.alpha = 0;
        [UIView animateWithDuration:0.5
                              delay:baseDelay + i * increment
             usingSpringWithDamping:0.85 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            item.transform = originalTransform;
            item.alpha = 1;
        } completion:nil];
    }
}
```

**参数规范**：
- 延迟递增：50ms（`delayIncrement`）
- 滑入距离：-40pt（从上方）
- 动画时长：500ms
- 缓动：Spring 0.85 阻尼 + 0.4 初始速度
- 最多 10 个 item 参与连锁（超过则同时进场，避免等待过久）

**适用场景**：
- 列表首次加载（替代简单的 fadeIn）
- Bento Grid 磁贴进场
- 设置项展开

**禁止**：
- 对超过 20 个 item 使用连锁动画——用户等待过久
- 在 `scrollViewDidScroll` 中触发连锁——会重复触发

### 15.4 主题切换遮罩动画

借鉴 ZL2 `activeMaskView`，Air 实现深浅主题切换的圆形扩散遮罩：截图当前界面 → 从触摸点（或屏幕中心）向外扩散圆形镂空 → 遮罩下切换主题。

```objc
// ✅ v1.1 推荐：主题切换遮罩
- (void)switchThemeWithMaskAnimation {
    UIView *snapshot = [self.view snapshotViewAfterScreenUpdates:NO];
    snapshot.frame = self.view.bounds;
    [self.view addSubview:snapshot];
    
    // 创建圆形遮罩（从中心扩散）
    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    CGPoint center = self.view.center;
    CGFloat maxRadius = sqrt(pow(self.view.bounds.size.width, 2) +
                             pow(self.view.bounds.size.height, 2));
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"path"];
    anim.duration = 0.8;
    anim.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    // ... 设置 path 从小圆到大圆
    
    // 在动画中点切换主题
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.4 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [self applyNewTheme];
    });
    
    [anim setValue:@(YES) forKey:@"themeSwitch"];
    anim.delegate = self;
    [maskLayer addAnimation:anim forKey:@"expand"];
    snapshot.layer.mask = maskLayer;
}
```

**参数规范**：
- 动画时长：800ms
- 缓动：`kCAMediaTimingFunctionEaseInEaseOut`
- 扩散起点：触摸点（若有）或屏幕中心
- 主题切换时机：动画 50% 处（400ms）

**适用场景**：
- 用户手动切换深浅模式
- 不适用于跟随系统切换（系统切换时无需遮罩）

### 15.5 Shimmer 骨架屏

借鉴 ZL2 `Shimmer.kt` 的 `infiniteShimmer`，Air 实现加载态的骨架屏：alpha 0.3 ↔ 0.6 循环（1000ms `LinearEasing` `RepeatMode.Reverse`）。

```objc
// ✅ v1.1 推荐：Shimmer 骨架屏
- (void)startShimmerOnView:(UIView *)shimmerView {
    CABasicAnimation *shimmer = [CABasicAnimation animationWithKeyPath:@"opacity"];
    shimmer.fromValue = @0.3;
    shimmer.toValue = @0.6;
    shimmer.duration = 1.0;
    shimmer.repeatCount = INFINITY;
    shimmer.autoreverses = YES;
    shimmer.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionLinear];
    [shimmerView.layer addAnimation:shimmer forKey:@"shimmer"];
}
```

**适用场景**：
- 列表首次加载（替代 `UIActivityIndicatorView`，更现代）
- 卡片内容加载中
- 图标加载占位

**与转圈的关系**：
- **列表/卡片加载**：优先用 Shimmer 骨架屏
- **按钮内加载/全屏加载**：仍用 `UIActivityIndicatorView`
- **下拉刷新**：仍用系统 `UIRefreshControl`

**禁止**：
- 对单个按钮使用 Shimmer——视觉过重
- Shimmer 与转圈混用于同一加载场景

### 15.6 FakeShadow 分隔阴影

借鉴 ZL2 `_FakeShadow.kt`，Air 在深色背景下用 4pt 渐变阴影分隔列表/卡片（弥补 MD3 elevation 阴影在深色下不明显的问题）。

```objc
// ✅ v1.1 推荐：FakeShadow 分隔
- (UIView *)fakeShadowViewWithDirection:(AirShadowDirection)direction {
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = CGRectMake(0, 0, self.bounds.size.width, 4);
    // 透明 → 0x3A000000 (约 23% 黑)
    gradient.colors = @[
        (__bridge id)[UIColor clearColor].CGColor,
        (__bridge id)[[UIColor blackColor] colorWithAlphaComponent:0.23].CGColor
    ];
    // 根据方向调整 startPoint/endPoint
    if (direction == AirShadowDirectionDown) {
        gradient.startPoint = CGPointMake(0.5, 0);
        gradient.endPoint = CGPointMake(0.5, 1);
    } // ... 其他方向
    
    UIView *shadowView = [[UIView alloc] init];
    [shadowView.layer addSublayer:gradient];
    return shadowView;
}
```

**适用场景**：
- 深色模式下列表项之间的分隔（替代 `separatorColor`）
- 卡片拼接处的视觉强化
- Bento Grid 分组之间的分隔

**与原阴影规格的关系**：
- 原 5.2 节的三档阴影仍用于卡片立体感
- FakeShadow 仅用于"平面分隔"，不增加立体感
- **禁止**用 FakeShadow 替代卡片阴影

### 15.7 卡片头/身分段结构

借鉴 ZL2 `BackgroundCard.kt` 的 `CardTitleLayout`，Air 卡片支持"标题栏 + 内容区"分段：标题栏用半透明 `surface` 色（alpha 0.5）+ 底部分隔线。

```objc
// ✅ v1.1 推荐：卡片头/身分段
- (void)setupCardWithTitle {
    // 标题栏
    self.titleBar = [[UIView alloc] init];
    self.titleBar.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.04];  // surface 0.5 alpha
    [self addSubview:self.titleBar];
    
    // 标题
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor labelColor];
    
    // 分隔线
    UIView *divider = [[UIView alloc] init];
    divider.backgroundColor = [AirOutline variantColor];
    
    // 内容区
    self.contentArea = [[UIView alloc] init];
    // ... 布局
}
```

**适用场景**：
- 设置分组卡片（标题 + 多个设置项）
- 详情卡片（标题 + 描述）
- Bento Grid 分组（Section header + 卡片）

**与原 Section header 的关系**：
- 原 11.4 节的 Section header 仍用于 UICollectionView section
- 卡片头/身分段用于**单张卡片内部**的标题/内容分隔
- 二者不冲突，可叠加使用

### 15.8 用户可调动画倍速（可选）

借鉴 ZL2 `AllSettings.launcherAnimateSpeed`（0-10，线性映射 1500ms-375ms），Air 可选实现全局动画倍速设置。

```objc
// ✅ v1.1 可选：动画倍速
+ (NSTimeInterval)scaledDuration:(NSTimeInterval)baseDuration {
    NSInteger speed = [[NSUserDefaults standardUserDefaults]
        integerForKey:@"general.animation_speed"];  // 0-10，默认 5
    CGFloat factor = 1.0 - (speed / 10.0) * 0.75;  // 1.0 → 0.25
    return baseDuration * factor;
}

// 使用
[UIView animateWithDuration:[AirAnimation scaledDuration:0.5] animations:^{
    // ...
}];
```

**注意**：此为**可选**功能，不强制实现。若实现，需在设置页提供滑块（0-10，默认 5）。

### 15.9 语义化颜色访问器（借鉴 ZL2 Palette.kt）

借鉴 ZL2 `Palette.kt` 的"用途导向"二次封装思路，Air 将第 2.7 节的 Surface 容器层级封装为**语义化访问器**，让业务代码只关心"用途"而不关心原始层级。这是 v1.1 推荐的工程化模式。

**访问器清单**（建议封装在 `AirSurface` 工具类）：

| 访问器 | 取值来源 | 用途 | 对应 ZL2 函数 |
|--------|----------|------|---------------|
| `+ (UIColor *)backgroundColor` | `surfaceContainer`（白 0.08） | 应用/页面背景 | `backgroundColor()` |
| `+ (UIColor *)cardColor` | `surfaceBright`（白 0.14） | 卡片背景（比页面亮一档） | `cardColor()` |
| `+ (UIColor *)cardTitleColor` | `surface` alpha 0.5 | 卡片标题栏半透明底色 | `cardTitleColor(0.5f)` |
| `+ (UIColor *)itemColor` | `surfaceContainerHigh`（白 0.10） | 卡片内嵌 Item 背景 | `itemColor()` |
| `+ (UIColor *)onCardColor` | `labelColor` | 卡片主文字（= labelColor） | `onCardColor()` |
| `+ (UIColor *)onBackgroundColor` | `secondaryLabelColor` | 页面背景上的次级文字 | `onBackgroundColor()` |

```objc
// ✅ v1.1 推荐：业务代码用语义化访问器，不直接操作 Surface 层级
card.backgroundColor = [AirSurface cardColor];            // 不用 surfaceContainerHigh
titleBar.backgroundColor = [AirSurface cardTitleColor];   // 不用 surface alpha 0.5
itemBg.backgroundColor = [AirSurface itemColor];          // 不用 surfaceContainerHigh
self.view.backgroundColor = [AirSurface backgroundColor]; // 不用 surfaceContainer

// 毛玻璃仍由 BackgroundManager 提供
[[BackgroundManager sharedManager] applyEffectToView:card];
```

**禁止**：
- 业务代码直接写 `[[UIColor whiteColor] colorWithAlphaComponent:0.10]` 等魔法数字——必须通过访问器
- 一个界面混用 `cardColor` 和 `itemColor` 做**同级**卡片背景——层级语义会混乱

**与原 2.7 节的关系**：第 2.7 节定义了 5 级 Surface 容器 + Dim/Bright 的**原始层级**，本节定义**用途封装**。业务代码用本节访问器，工具类内部用 2.7 节层级。

### 15.10 三种缓动类型（借鉴 ZL2 TransitionAnimationType）

借鉴 ZL2 `TransitionAnimationType` 枚举（CLOSE / JELLY_BOUNCE / BOUNCE / SLICE_IN），Air 将进场/过渡动画规范为**四种缓动类型**，由 `general.transition_animation_type` 偏好控制。第 15.1 节的 JellyBounce 是其中之一。

**枚举定义**（v1.1 新增）：

```objc
typedef NS_ENUM(NSInteger, AirTransitionAnimationType) {
    AirTransitionAnimationClose,        // 0：无动画（snap）
    AirTransitionAnimationJellyBounce,  // 1：果冻回弹（默认）
    AirTransitionAnimationBounce,       // 2：标准弹跳
    AirTransitionAnimationSliceIn       // 3：平滑切入
};
```

**四种类型的实现**：

| 类型 | 缓动函数 | 时长 | 适用场景 |
|------|----------|------|----------|
| `Close` | `snap`（无动画） | 0ms | 用户关闭动效偏好 |
| `JellyBounce` | `1 - 0.6*exp(-8t)*cos(6πt)` | 600ms | 卡片进场、按压回弹（默认） |
| `Bounce` | iOS `UIViewAnimationOptionCurveEaseInOut` + Spring 0.6 阻尼 | 500ms | 列表项展开、模态弹出 |
| `SliceIn` | `CubicBezier(0.16, 1, 0.3, 1)` 平滑切入 | 400ms | 页面切换、内容切换 |

```objc
// ✅ v1.1 推荐：根据偏好选择缓动
- (void)animateItem:(UIView *)item type:(AirTransitionAnimationType)type {
    NSTimeInterval duration = [AirAnimation durationForType:type];
    UIViewAnimationOptions options = [AirAnimation optionsForType:type];
    
    [UIView animateWithDuration:duration delay:0 options:options animations:^{
        // ...
    } completion:nil];
}

+ (NSTimeInterval)durationForType:(AirTransitionAnimationType)type {
    switch (type) {
        case AirTransitionAnimationClose:        return 0;
        case AirTransitionAnimationJellyBounce:  return 0.6;
        case AirTransitionAnimationBounce:       return 0.5;
        case AirTransitionAnimationSliceIn:      return 0.4;
    }
}
```

**与第 15.1 节的关系**：15.1 节单独描述 JellyBounce 的数学公式与 CAKeyframeAnimation 实现，本节将其纳入完整的四类型体系。**默认用 JellyBounce**，但用户可在设置中切换。

**禁止**：
- 自创第五种缓动类型
- 同一界面内混用多种类型——保持节奏一致

### 15.11 背景透明度联动（借鉴 ZL2 influencedByBackground）

借鉴 ZL2 `influencedByBackgroundColor` 思路：当用户设置了较透明的壁纸时，卡片色 alpha 应**自动降低**以透出壁纸，但保持可读性。这是 Air"毛玻璃 + 自定义壁纸"卖点的工程化保障。

**联动规则**：

| 壁纸透明度偏好 | 卡片色 alpha 调整 | 视觉效果 |
|----------------|-------------------|----------|
| 0%（完全透明壁纸） | 不调整（用原始 alpha） | 卡片浮于纯色背景 |
| 30% | 卡片色 alpha × 0.85 | 轻微透出壁纸 |
| 60% | 卡片色 alpha × 0.70 | 明显透出壁纸 |
| 100%（完全不透明壁纸） | 卡片色 alpha × 0.55 | 强烈透出壁纸 |

```objc
// ✅ v1.1 推荐：卡片色随壁纸透明度联动
+ (UIColor *)cardColorInfluencedByBackground {
    UIColor *base = [AirSurface cardColor];  // surfaceBright 白 0.14
    CGFloat bgOpacity = [[NSUserDefaults standardUserDefaults]
        floatForKey:@"general.background_opacity"];  // 0.0 - 1.0
    // 联动因子：1.0 → 0.55，线性映射
    CGFloat factor = 1.0 - bgOpacity * 0.45;
    return [base colorWithAlphaComponent:[base alphaComponent] * factor];
}
```

**适用场景**：
- `BackgroundManager` 已应用壁纸时，所有卡片色都应联动
- 浮球、FAB 等浮动元素**不联动**（保持强可见性）
- 文字色**不联动**（始终用系统色，由系统自动适配）

**与 BackgroundManager 的关系**：
- `BackgroundManager` 负责毛玻璃模糊与壁纸挂载
- 本节负责卡片**底色**的 alpha 联动
- 二者协作：毛玻璃模糊强 → 卡片色可更低；毛玻璃模糊弱 → 卡片色需更高

**禁止**：
- 联动文字色——文字必须始终用 `labelColor` 系统色
- 联动浮球/FAB——浮动元素需保持强可见性
- 跳过 `BackgroundManager` 直接调整壁纸透明度

### 15.12 MD3 融合决策树

```
新建界面是否需要 MD3 融合？
  ├─ 否 → 遵循原规范第 1-14 章
  └─ 是 → 需要哪种 MD3 元素？
           ├─ 视觉层次不足 → 用 Surface 容器层级（第 2.7 节）
           ├─ 卡片色访问混乱 → 用语义化访问器（第 15.9 节）
           ├─ 卡片拼接分组 → 用 CardPosition 拼接（第 15.2 节）
           ├─ 进场动画平淡 → 用连锁进场（第 15.3 节）
           ├─ 缓动类型单一 → 用四种缓动类型（第 15.10 节）
           ├─ 主题切换突兀 → 用遮罩动画（第 15.4 节）
           ├─ 加载态过时 → 用 Shimmer 骨架屏（第 15.5 节）
           ├─ 深色分隔弱 → 用 FakeShadow（第 15.6 节）
           ├─ 卡片标题/内容混 → 用头/身分段（第 15.7 节）
           ├─ 壁纸透出弱 → 用背景透明度联动（第 15.11 节）
           └─ 按压无弹性 → 用 JellyBounce（第 15.1 节）
```

**重要原则**：
1. **iOS 优先**：MD3 元素是补充，不替代 iOS 原生设计
2. **毛玻璃不变**：所有 MD3 Surface 容器层级仍叠加 `BackgroundManager` 毛玻璃
3. **系统色不变**：文字仍用 `labelColor` 系列，不引入 MD3 `onSurface` 等角色
4. **不引入 Compose**：Air 仍是 UIKit，MD3 仅借鉴设计理念
5. **渐进采用**：新界面可选用 MD3 元素，旧界面不强制重构

---

## 附录：基准文件清单

实现新界面时，以下文件是**正面基准**，请直接参照其代码：

- `Natives/DownloadViewController.m` —— 下载主界面 + ModernAssetCell（L1 扁平条目基准）
- `Natives/VersionCardCell.m` —— 版本卡片（L2 标准卡片基准，含图标容器/类型 pill/chevron/已安装徽章）
- `Natives/ModVersionTableViewCell.m` —— Mod 版本卡片（L2 基准，含加载器徽章 pill）
- `Natives/AssetDetailHeaderView.m` —— 详情头部（L3 大卡片基准）
- `Natives/ModVersionViewController.m` —— chips 筛选条基准
- `Natives/BackgroundManager.m` —— 毛玻璃/透明化统一调度

以下文件是**反面教材**，重构时需对照本规范修正：

- `Natives/VersionManagerViewController.m` —— 实例管理页（文字硬编码白色/裸图标/无 chevron/无空状态/伪 Bento）
- `Natives/AccountLoginViewController.m` —— 标题硬编码白色
- `Natives/AccountListViewController.m` —— 徽章硬编码 RGB
- `Natives/ThirdPartyLoginViewController.m` —— cornerRadius 内部不一致（14 vs 16）
- `Natives/LauncherRightPanelViewController.m` —— 阴影被 masksToBounds 裁掉
- `Natives/ServerListViewController.m` —— 来源标签纯文本违规
- `Natives/ModUpdateViewController.m` —— 来源标签纯文本违规
- `Natives/installer/ForgeInstallSchemeViewController.m` —— 卡片无毛玻璃，纯色割裂

---

**本规范为活文档，随项目演进持续更新。新增组件或设计模式时，请同步修订对应章节并更新自检清单。**
