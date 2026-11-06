import Foundation

/// 纸张动画的局部资源预算，不包含宿主正文、图片解码或渲染视图本身的内存。
public struct PaperRenderingOptions: Sendable, Equatable {
    /// 当前页和目标页两张原始快照的合计像素上限。
    public let maximumSnapshotPixels: Int
    /// 预切条带数量上限；每帧复用几何与图像，不在热路径重新裁图。
    public let stripCount: Int
    public static let standard = PaperRenderingOptions()

    /// - Parameters: maximumSnapshotPixels: 65536...16777216 像素；stripCount: 32...256 条。
    public init(maximumSnapshotPixels: Int = 4_194_304, stripCount: Int = 128) {
        self.maximumSnapshotPixels = maximumSnapshotPixels
        self.stripCount = stripCount
    }

    /// - Throws: 非法预算；不把错误配置静默钳制为另一档。
    public func validate() throws {
        guard (65_536...16_777_216).contains(maximumSnapshotPixels), (32...256).contains(stripCount) else {
            throw PageTurnError.invalidPaperOptions
        }
    }
}
