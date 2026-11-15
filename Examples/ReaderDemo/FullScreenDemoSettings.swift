import UIKit
import BonePageTurnKit

/// 独立阅读示例的可保存输入；只保存值，不拥有阅读器、计时器或渲染资源。
struct FullScreenDemoSettings: Codable, Equatable {
    var effect: String = "slide"
    var axis: String = "horizontal"
    var readingOrder: String = "ltr"
    var pageLayout: String = "single"
    var spine: String = "automatic"
    var motion: String = "wholePage"
    var safeArea: Bool = true
    var reservedRegions: Bool = false
    var prefersSpread: Bool = true
    var minimumPageWidth: Double = 280
    var minimumPageHeight: Double = 240
    var spreadGap: Double = 16
    var firstPageIsCover: Bool = false
    var headerEnabled: Bool = true
    var footerEnabled: Bool = true
    var headerHeight: Double = 24
    var footerHeight: Double = 24
    var headerGap: Double = 10
    var footerGap: Double = 10
    var insetTop: Double = 16
    var insetLeft: Double = 24
    var insetBottom: Double = 16
    var insetRight: Double = 24
    var wallpaper: Bool = true
    var appearance: String = "system"
    var content: String = "text"
    var fontSize: Double = 20
    var sliceMode: String = "whole"
    var sliceRatio: Double = 1.5
    var zoomEnabled: Bool = false
    var zoomFit: String = "aspectFit"
    var maximumZoom: Double = 4
    var initialZoom: Double = 1
    var handoffThreshold: Double = 18
    var allowPagingWhileZoomed: Bool = false
    var paperPixels: Int = 4_194_304
    var paperStrips: Int = 128
    var coverCorner: Double = 36
    var shadowOpacity: Double = 0.32
    var shadowRadius: Double = 24
    var shadowX: Double = 12
    var shadowY: Double = 0
    var automaticMode: String = "manual"
    var pageInterval: Double = 5
    var scrollSpeed: Double = 40
    var animated: Bool = true
    var tapTurns: Bool = true
    var previousEnd: Double = 0.33
    var nextStart: Double = 0.67
    var panEnabled: Bool = true
    var userScrollEnabled: Bool = true
    var tapsEnabled: Bool = true
    var pauseAutomatic: Bool = false
    var deferInstallation: Bool = false
    var leadingViewports: Double = 1
    var trailingViewports: Double = 1
    var maximumRequests: Int = 16
    var maximumNoProgress: Int = 2
    var maximumAddedItems: Int = 256
    var loadBatch: Int = 4
    var loadDelay: Double = 0.8
    var simulateFailure: Bool = false
    var bookBoundary: String = "endOfBook"
    var paginationTotal: String = "exact"

    // MARK: - SDK 值映射

    /// 应先通过 validationMessage() 校验。连续模式的占位值不用于创建分页容器。
    var sdkEffect: PageTurnEffect {
        switch effect {
        case "none", "continuous": return .none
        case "slide": return .slide
        case "cover": return .cover
        case "curl": return .curl
        case "arch": return .arch
        default: preconditionFailure("请先校验翻页效果")
        }
    }

    /// 已校验的翻页轴；不从设备方向推断。
    var sdkAxis: PageTurnAxis {
        switch axis {
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        default: preconditionFailure("请先校验翻页方向")
        }
    }

    /// 已校验的内容顺序；不从系统语言推断。
    var sdkOrder: ReaderReadingOrder {
        switch readingOrder {
        case "ltr": return .leftToRight
        case "rtl": return .rightToLeft
        default: preconditionFailure("请先校验阅读顺序")
        }
    }

    /// 已校验的纸张书脊；实际组合由 PageTurnConfiguration.validate() 再检查。
    var sdkSpine: PageSpinePlacement {
        switch spine {
        case "automatic": return .automatic
        case "minimum": return .minimum
        case "center": return .center
        case "maximum": return .maximum
        default: preconditionFailure("请先校验书脊位置")
        }
    }

    /// 已校验的阅读外壳运动范围。
    var sdkMotion: ReaderSurfaceMotion {
        switch motion {
        case "contentOnly": return .contentOnly
        case "contentAndChrome": return .contentAndChrome
        case "wholePage": return .wholePage
        default: preconditionFailure("请先校验页面运动范围")
        }
    }

    /// 已校验的图片切片方式；源图尺寸仍由宿主在规划切片时提供。
    var sdkSliceMode: ComicSliceMode {
        switch sliceMode {
        case "whole": return .whole
        case "splitWide": return .splitWide
        case "vertical": return .vertical
        default: preconditionFailure("请先校验图片分片方式")
        }
    }

    /// 已校验的缩放适配方式；SDK 的此枚举位于主执行器。
    @MainActor var sdkZoomFit: ReaderZoomFit {
        switch zoomFit {
        case "aspectFit": return .aspectFit
        case "width": return .width
        default: preconditionFailure("请先校验图片适配方式")
        }
    }

    /// - Parameter layout: 宿主根据当前视口解析出的实际单页或双页形态。
    /// - Returns: 已通过 Demo 输入、组合及 SDK 验证的配置；连续模式使用真实的 continuous 展示值。
    /// - Throws: 输入或组合错误，或 SDK 的配置错误；不修改输入和当前阅读器。
    func pageConfiguration(layout: ReaderPageLayout) throws -> PageTurnConfiguration {
        try validateValues()
        try validateCombinations()
        return try checkedConfiguration(layout: layout)
    }

    /// 页眉或页脚关闭时不占用高度和间距，保存的输入仍留在设置中。
    var surfaceMetrics: ReaderSurfaceMetrics {
        .init(headerHeight: headerEnabled ? CGFloat(headerHeight) : 0,
              footerHeight: footerEnabled ? CGFloat(footerHeight) : 0,
              headerGap: headerEnabled ? CGFloat(headerGap) : 0,
              footerGap: footerEnabled ? CGFloat(footerGap) : 0,
              bodyInsets: .init(top: insetTop, left: insetLeft, bottom: insetBottom, right: insetRight))
    }

    /// 原样传入双页偏好。宿主另行处理运行时保留区域能力以及关闭安全区后的视口快照。
    var adaptivePolicy: ReaderAdaptiveLayoutPolicy {
        .init(prefersSpread: prefersSpread,
              minimumPageWidth: CGFloat(minimumPageWidth), minimumPageHeight: CGFloat(minimumPageHeight),
              spreadGap: CGFloat(spreadGap), horizontalSafeArea: safeArea && reservedRegions ? .reservedRegions : .system)
    }

    /// 无参数；返回经过 Demo 限额和 SDK 构造验证的连续补屏策略。
    /// - Throws: 任一输入值非法，或 ContinuousFillPolicy 拒绝该补屏参数。
    func fillPolicy() throws -> ContinuousFillPolicy {
        try validateValues()
        return try .init(leadingViewports: leadingViewports, trailingViewports: trailingViewports,
                         maximumRequests: maximumRequests, maximumNoProgressResults: maximumNoProgress,
                         maximumAddedItems: maximumAddedItems)
    }

    /// 无参数；返回首个中文错误，全部输入及组合可用时返回 nil。不会修正或安装配置。
    func validationMessage() -> String? {
        do {
            try validateValues()
            try validateCombinations()
            if pageLayout == "adaptive" {
                _ = try checkedConfiguration(layout: .single)
                _ = try checkedConfiguration(layout: .spread)
            } else {
                _ = try checkedConfiguration(layout: pageLayout == "spread" ? .spread : .single)
            }
            try surfaceMetrics.validate()
            _ = try fillPolicy()
            _ = try ReaderTapConfiguration(previousEnd: previousEnd, nextStart: nextStart)
            // SDK 通过 layout(for:) 验证策略；这里不预测真实设备的最终布局。
            _ = try adaptivePolicy.layout(for: .init(bounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
                                                     widthClass: .regular))
            return nil
        } catch let error as SettingsError {
            return error.message
        } catch let error as PageTurnError {
            switch error {
            case .unsupportedPresentation: return "当前效果不支持所选翻页方向。覆盖翻页仅支持横向，连续阅读仅支持纵向。"
            case .unsupportedSpine:
                return "书脊位置不支持当前组合：非纸张效果请选择自动；纸张单页可选自动、最小端或最大端，纸张双页可选自动或中央。"
            case .unsupportedLayout, .invalidPageLayout: return "当前展示方式不支持所选页面布局。"
            case .invalidPaperOptions: return "纸张快照应为 65536～16777216 像素，条带数应为 32～256。"
            default: return "SDK 无法接受当前翻页配置，请检查效果、布局及书脊位置。"
            }
        } catch is ReaderTapConfigurationError {
            return "点击分区须满足 0 ≤ 上一页区域终点 ≤ 下一页区域起点 ≤ 1。"
        } catch is ContinuousFillPolicyError {
            return "补屏余量应为 0～8 屏，各项加载预算应为正整数。"
        } catch is ReaderSurfaceError {
            return "页眉、页脚、间距和正文边距必须是有限的非负数。"
        } catch is ReaderAdaptiveLayoutError {
            return "自适应布局的最小页宽、最小页高须为正数，双页间距须为非负数。"
        } catch is CoverRenderingError {
            return "覆盖翻页的圆角和阴影参数无效，请检查半径、透明度及偏移。"
        } catch {
            return "配置验证失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 验证规则

private extension FullScreenDemoSettings {
    struct SettingsError: Error {
        let message: String
    }

    /// 无参数及返回值；所有字段均检查，包括当前模式暂未启用的选项。
    func validateValues() throws {
        for group in Self.groups {
            for field in group.fields {
                switch field.input {
                case .toggle: break
                case .choice(let keyPath, let choices):
                    guard choices.contains(where: { $0.value == self[keyPath: keyPath] }) else {
                        throw SettingsError(message: "“\(field.title)”的选项无效，请重新选择。")
                    }
                case .number(let keyPath, let range, _):
                    let value = self[keyPath: keyPath]
                    guard value.isFinite, range.contains(value) else {
                        throw SettingsError(message: "“\(field.title)”须为 \(range.lowerBound)～\(range.upperBound) 范围内的有限数字。")
                    }
                case .integer(let keyPath, let range, _):
                    guard range.contains(self[keyPath: keyPath]) else {
                        throw SettingsError(message: "“\(field.title)”须为 \(range.lowerBound)～\(range.upperBound) 范围内的整数。")
                    }
                }
            }
        }
    }

    /// 无参数及返回值；拒绝不支持的组合，不替换用户选择。
    func validateCombinations() throws {
        if effect == "continuous" {
            guard axis == "vertical", pageLayout == "single", motion == "contentOnly", !zoomEnabled else {
                throw SettingsError(message: "连续阅读需要纵向、单页、仅正文运动，并关闭图片缩放。请同时调整这些选项后应用。")
            }
            guard automaticMode == "manual" || automaticMode == "scroll" else {
                throw SettingsError(message: "连续阅读支持手动或自动滚动；定时翻页和外部进度仅适用于分页阅读。")
            }
        } else if automaticMode == "scroll" {
            throw SettingsError(message: "自动滚动仅适用于连续阅读；分页阅读可选择手动、定时翻页或外部进度。")
        }
        if pageLayout != "single", motion != "wholePage" {
            throw SettingsError(message: "当前双页与自适应示例需要整页运动：每侧阅读外壳通过公开双页容器组合。请选择“整页运动”。")
        }
        if ["cover", "curl", "arch"].contains(effect), motion != "wholePage" {
            throw SettingsError(message: "覆盖、卷曲和拱形翻页需要整页运动，包括背景、页眉和页脚。")
        }
        if pageLayout == "adaptive", spine != "automatic" {
            throw SettingsError(message: "自适应布局会在单页与双页之间切换，两者可用书脊不同。此示例要求选择“自动书脊”，并分别验证两种形态。")
        }
        if zoomEnabled, content == "text" || effect == "continuous" {
            throw SettingsError(message: "图片缩放仅适用于分页阅读中的宽幅图片或长图，请修改内容或关闭缩放。")
        }
        guard initialZoom <= maximumZoom else {
            throw SettingsError(message: "初始放大倍数不能超过最大放大倍数。")
        }
        guard previousEnd <= nextStart else {
            throw SettingsError(message: "上一页区域终点不能超过下一页区域起点；二者之间为中央点击区。")
        }
    }

    /// - Parameter layout: 实际单页或双页布局。
    /// - Returns: SDK 已验证的配置；调用前必须完成值和组合检查。
    /// - Throws: PageTurnConfiguration.validate() 的原始错误。
    func checkedConfiguration(layout: ReaderPageLayout) throws -> PageTurnConfiguration {
        let presentation: PageTurnPresentation = effect == "continuous"
            ? .continuous(axis: sdkAxis) : .paged(effect: sdkEffect, axis: sdkAxis)
        let configuration = PageTurnConfiguration(
            presentation: presentation, spine: sdkSpine,
            paper: .init(maximumSnapshotPixels: paperPixels, stripCount: paperStrips),
            layout: layout, readingOrder: sdkOrder,
            cover: .init(cornerRadius: coverCorner, shadowOpacity: shadowOpacity,
                         shadowRadius: shadowRadius, shadowOffsetX: shadowX, shadowOffsetY: shadowY))
        try configuration.validate()
        return configuration
    }
}

// MARK: - 输入定义（表单与验证共用）

extension FullScreenDemoSettings {
    struct Choice {
        let value: String
        let title: String

        /// - Parameters: value: 保存的稳定值；title: 中文显示名称；无返回值。
        init(_ value: String, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    enum Input {
        case toggle(WritableKeyPath<FullScreenDemoSettings, Bool>)
        case choice(WritableKeyPath<FullScreenDemoSettings, String>, [Choice])
        case number(WritableKeyPath<FullScreenDemoSettings, Double>, ClosedRange<Double>, String)
        case integer(WritableKeyPath<FullScreenDemoSettings, Int>, ClosedRange<Int>, String)
    }

    struct Field {
        let name: String
        let title: String
        let hint: String
        let input: Input

        /// - Parameters: name: 字段名和辅助功能标识后缀；title: 中文名称；hint: 适用条件；input: 值绑定及允许范围；无返回值。
        init(_ name: String, _ title: String, _ hint: String, _ input: Input) {
            self.name = name
            self.title = title
            self.hint = hint
            self.input = input
        }

        /// - Parameters: name: 字段名；title: 中文名称；input: 值绑定及允许范围；无返回值，默认无额外说明。
        init(_ name: String, _ title: String, _ input: Input) {
            self.init(name, title, "", input)
        }
    }

    struct Group {
        let title: String
        let hint: String
        let fields: [Field]
    }

    /// 范围是示例的输入保护，不代表 SDK 对所有宿主的理论上限。
    static var groups: [Group] { [
        .init(title: "翻页布局", hint: "可以先修改多个选项再应用。连续阅读需要纵向、单页、仅正文运动；覆盖与纸张效果需要整页运动。", fields: [
            .init("effect", "翻页效果", "覆盖翻页仅支持横向。", .choice(\.effect, [
                .init("none", "无动画"), .init("slide", "平移"), .init("cover", "覆盖"),
                .init("curl", "卷曲纸张"), .init("arch", "拱形纸张"), .init("continuous", "连续阅读")])),
            .init("axis", "翻页方向", .choice(\.axis, [.init("horizontal", "横向"), .init("vertical", "纵向")])),
            .init("readingOrder", "阅读顺序", "纵向内容始终从上到下。", .choice(\.readingOrder, [.init("ltr", "从左到右"), .init("rtl", "从右到左")])),
            .init("pageLayout", "页面布局", "双页与自适应需要整页运动。", .choice(\.pageLayout, [.init("single", "单页"), .init("spread", "双页"), .init("adaptive", "自适应")])),
            .init("spine", "书脊位置", "自适应仅可用自动；纸张单页支持两端，纸张双页支持中央。", .choice(\.spine, [
                .init("automatic", "自动书脊"), .init("minimum", "最小端"), .init("center", "中央"), .init("maximum", "最大端")])),
            .init("motion", "页面运动范围", .choice(\.motion, [.init("contentOnly", "仅正文运动"), .init("contentAndChrome", "正文与页眉页脚运动"), .init("wholePage", "整页运动")])),
            .init("safeArea", "避开系统安全区", .toggle(\.safeArea)),
            .init("reservedRegions", "使用系统保留区域", "需支持此能力的工具链及 iOS 27.1 或更新版本；关闭安全区时不应用。", .toggle(\.reservedRegions)),
            .init("prefersSpread", "自适应时优先双页", "由可读尺寸及当前视口共同决定。", .toggle(\.prefersSpread)),
            .init("minimumPageWidth", "最小可读页宽", "用于自适应布局。", .number(\.minimumPageWidth, 1...2048, "点")),
            .init("minimumPageHeight", "最小可读页高", "用于自适应布局。", .number(\.minimumPageHeight, 1...2048, "点")),
            .init("spreadGap", "双页间距", .number(\.spreadGap, 0...200, "点")),
            .init("firstPageIsCover", "首张单独作为封面", "双页时封面另一侧留白。", .toggle(\.firstPageIsCover))
        ]),
        .init(title: "外壳度量", hint: "所有距离以点计。关闭页眉或页脚会释放其高度与间距，保留输入值供再次启用。", fields: [
            .init("headerEnabled", "显示页眉", .toggle(\.headerEnabled)),
            .init("footerEnabled", "显示页脚", .toggle(\.footerEnabled)),
            .init("headerHeight", "页眉高度", .number(\.headerHeight, 0...160, "点")),
            .init("footerHeight", "页脚高度", .number(\.footerHeight, 0...160, "点")),
            .init("headerGap", "页眉与正文间距", .number(\.headerGap, 0...160, "点")),
            .init("footerGap", "正文与页脚间距", .number(\.footerGap, 0...160, "点")),
            .init("insetTop", "正文上边距", .number(\.insetTop, 0...200, "点")),
            .init("insetLeft", "正文左边距", .number(\.insetLeft, 0...200, "点")),
            .init("insetBottom", "正文下边距", .number(\.insetBottom, 0...200, "点")),
            .init("insetRight", "正文右边距", .number(\.insetRight, 0...200, "点"))
        ]),
        .init(title: "自动阅读", hint: "定时翻页和自动滚动由 SDK 驱动；外部进度使用宿主控制入口。", fields: [
            .init("automaticMode", "阅读方式", .choice(\.automaticMode, [.init("manual", "手动阅读"), .init("timed", "定时翻页"), .init("scroll", "自动滚动"), .init("external", "外部进度")])),
            .init("pageInterval", "每页停留时间", "仅用于定时翻页，不含动画时间。", .number(\.pageInterval, 0.1...3600, "秒")),
            .init("scrollSpeed", "自动滚动速度", "仅用于连续阅读。", .number(\.scrollSpeed, 0.1...2000, "点／秒")),
            .init("animated", "程序翻页使用动画", "用于程序翻页及定时翻页；无动画效果仍直接切页。", .toggle(\.animated))
        ]),
        .init(title: "覆盖样式", hint: "这些装饰只在覆盖翻页过程中生效，稳定页面维持自身样式。", fields: [
            .init("coverCorner", "移动页圆角", .number(\.coverCorner, 0...100, "点")),
            .init("shadowOpacity", "阴影不透明度", .number(\.shadowOpacity, 0...1, "")),
            .init("shadowRadius", "阴影模糊半径", .number(\.shadowRadius, 0...100, "点")),
            .init("shadowX", "阴影水平偏移", "从右到左阅读时由 SDK 镜像。", .number(\.shadowX, -100...100, "点")),
            .init("shadowY", "阴影垂直偏移", .number(\.shadowY, -100...100, "点"))
        ]),
        .init(title: "纸张快照", hint: "仅卷曲和拱形效果消耗纸张快照；预算不包括正文图片及解码内存。", fields: [
            .init("paperPixels", "快照总像素上限", "当前页与目标页两张快照合计。", .integer(\.paperPixels, 65_536...16_777_216, "像素")),
            .init("paperStrips", "纸张条带数量", .integer(\.paperStrips, 32...256, "条"))
        ]),
        .init(title: "漫画缩放", hint: "分片参数用于图片。缩放仅支持分页图片，文字和连续阅读须关闭缩放。", fields: [
            .init("sliceMode", "图片分片方式", .choice(\.sliceMode, [.init("whole", "完整图片"), .init("splitWide", "宽图左右拆分"), .init("vertical", "长图纵向分片")])),
            .init("sliceRatio", "纵向分片最大高宽比", "仅纵向分片使用；源图仍受 SDK 的 256 片限制。", .number(\.sliceRatio, 0.1...10, "")),
            .init("zoomEnabled", "允许图片缩放", .toggle(\.zoomEnabled)),
            .init("zoomFit", "图片适配方式", "启用缩放时使用。", .choice(\.zoomFit, [.init("aspectFit", "完整适配"), .init("width", "宽度适配")])),
            .init("maximumZoom", "最大放大倍数", .number(\.maximumZoom, 1...20, "倍")),
            .init("initialZoom", "初始放大倍数", "不能超过最大倍数。", .number(\.initialZoom, 1...20, "倍")),
            .init("handoffThreshold", "图片边缘翻页距离", "到达图片边缘后继续拖动的距离。", .number(\.handoffThreshold, 1...200, "点")),
            .init("allowPagingWhileZoomed", "放大后仍允许边缘翻页", .toggle(\.allowPagingWhileZoomed))
        ]),
        .init(title: "点击暂停", hint: "这些开关控制阅读交互。打开设置面板的临时暂停由宿主单独管理，关闭面板后恢复。", fields: [
            .init("tapTurns", "点击两侧翻页", "分页阅读使用；中央区域交给阅读页面。", .toggle(\.tapTurns)),
            .init("previousEnd", "上一页区域终点", "沿翻页轴的归一化位置，不得超过下一页区域起点。", .number(\.previousEnd, 0...1, "")),
            .init("nextStart", "下一页区域起点", .number(\.nextStart, 0...1, "")),
            .init("panEnabled", "允许开始拖动", "分页与连续阅读的拖动开始门禁。", .toggle(\.panEnabled)),
            .init("userScrollEnabled", "允许手动连续滚动", "仅连续阅读生效。", .toggle(\.userScrollEnabled)),
            .init("tapsEnabled", "允许处理阅读点击", .toggle(\.tapsEnabled)),
            .init("pauseAutomatic", "暂停自动阅读", "保留当前自动阅读意图。", .toggle(\.pauseAutomatic)),
            .init("deferInstallation", "暂缓安装连续内容", "仅连续阅读生效，已加载内容等待恢复后安装。", .toggle(\.deferInstallation))
        ]),
        .init(title: "连续加载", hint: "补屏策略仅连续阅读生效。批量、延迟及失败开关控制示例数据源，不是网络或识别服务。", fields: [
            .init("leadingViewports", "前方可读余量", .number(\.leadingViewports, 0...8, "屏")),
            .init("trailingViewports", "后方可读余量", .number(\.trailingViewports, 0...8, "屏")),
            .init("maximumRequests", "每方向请求上限", .integer(\.maximumRequests, 1...256, "次")),
            .init("maximumNoProgress", "无可读进展次数上限", .integer(\.maximumNoProgress, 1...256, "次")),
            .init("maximumAddedItems", "每方向新增内容上限", .integer(\.maximumAddedItems, 1...4096, "块")),
            .init("loadBatch", "每次加载数量", .integer(\.loadBatch, 1...30, "块")),
            .init("loadDelay", "模拟加载延迟", .number(\.loadDelay, 0...10, "秒")),
            .init("simulateFailure", "模拟加载失败", .toggle(\.simulateFailure))
        ]),
        .init(title: "内容显示", hint: "内容及外观由示例提供。总数选项只决定元数据的确定程度，实际页数、内容身份和绑定属于运行状态。", fields: [
            .init("content", "示例内容", .choice(\.content, [.init("text", "文字"), .init("wideImage", "宽幅图片"), .init("tallImage", "长图")])),
            .init("fontSize", "正文字号", "仅文字内容使用。", .number(\.fontSize, 12...40, "点")),
            .init("wallpaper", "显示阅读壁纸", .toggle(\.wallpaper)),
            .init("appearance", "显示外观", .choice(\.appearance, [.init("system", "跟随系统"), .init("light", "浅色"), .init("dark", "深色")])),
            .init("bookBoundary", "内容末端含义", .choice(\.bookBoundary, [.init("endOfBook", "全书完结"), .init("latestAvailable", "已到最新内容"), .init("unknown", "边界未知")])),
            .init("paginationTotal", "总数确定程度", .choice(\.paginationTotal, [.init("exact", "确定总数"), .init("estimated", "估算总数"), .init("unknown", "总数未知")]))
        ])
    ] }
}
