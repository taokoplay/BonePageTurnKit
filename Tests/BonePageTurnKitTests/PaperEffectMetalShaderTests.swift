#if canImport(UIKit)
import XCTest
import Metal
@testable import BonePageTurnKit

/// 编译共享效果着色库：保证七个片段函数与通用顶点函数能通过 MSL 编译并
/// 正确链接为渲染管线。着色库随渲染层一起仅在 UIKit 平台参与编译，
/// 测试在 iOS 模拟器／真机上运行即可覆盖。
@MainActor
final class PaperEffectMetalShaderTests: XCTestCase {
    /// 各整页 GPU 效果对应的片段函数名；与 PageTurnEffect.metalFragmentName 一致。
    static let fragmentNames = ["burnFragment", "glitchFragment", "foldFragment", "shatterFragment",
                                "inkwashFragment", "icecrackFragment", "waveFragment"]

    func testSharedShaderLibraryCompilesAllEffectFragments() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("无 Metal 设备") }
        let library = try device.makeLibrary(source: PaperEffectMetalContext.shader, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "effectVertex"))
        for name in Self.fragmentNames {
            XCTAssertNotNil(library.makeFunction(name: name), "缺少片段函数 \(name)")
        }
    }

    func testAllEffectPipelinesCompile() throws {
        guard case .success(let context) = PaperEffectMetalContext.shared else { throw XCTSkip("无 Metal 设备") }
        for name in Self.fragmentNames {
            XCTAssertNoThrow(try context.pipeline(fragment: name), "管线编译失败 \(name)")
        }
        // 碎片飞散的几何路径：背景与碎片三角形的混合管线。
        XCTAssertNoThrow(try context.shardPipelines(), "碎片几何管线编译失败")
    }
}
#endif
