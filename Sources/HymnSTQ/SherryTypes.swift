import Foundation

/// 单层 forward 的计时/计数指标。
///
/// 历史上该结构随 D-1 的 HymnModel 一起定义；D-1 退役后由 Sherry 常驻 GEMV
/// 模型独占使用，字段语义保持不变，避免改动已验证的 golden/性能口径。
public struct ForwardMetrics: Sendable {
    public var commandBuffers: Int = 0
    public var gemmCount: Int = 0
    public var computeKernelCount: Int = 0
    public var gpuMs: Double = 0
    public var wallMs: Double = 0

    public init(commandBuffers: Int = 0, gemmCount: Int = 0,
                computeKernelCount: Int = 0, gpuMs: Double = 0, wallMs: Double = 0) {
        self.commandBuffers = commandBuffers
        self.gemmCount = gemmCount
        self.computeKernelCount = computeKernelCount
        self.gpuMs = gpuMs
        self.wallMs = wallMs
    }
}
