import Foundation
import Metal

/// 上线自检：只读检查唯一后端运行所需的全部资源，不加载模型、不发起网络请求。
///
/// Sherry 常驻 GEMV 运行时只需要三样东西：GGUF、config.json、tokenizer.json；
/// 不需要 fp16 展开缓存、不需要 .metallib、不需要任何上游运行时。
public struct SherryRuntimeStatus: Sendable, Codable, Equatable {
    public let modelDirectory: String?
    public let ggufPath: String?
    public let ggufBytes: Int64?
    public let ggufMagic: String?
    public let ggufVersion: Int?
    public let tensorCount: Int?
    public let configPresent: Bool
    public let tokenizerPresent: Bool
    public let metalDevice: String?
    public let ready: Bool
    public let weightFormat: String
    public let offlineOnly: Bool

    public var summaryLines: [String] {
        [
            "模型目录   : \(modelDirectory ?? "未找到")",
            "GGUF      : \(ggufPath ?? "缺失")",
            "GGUF 大小 : \(ggufBytes.map { String($0) } ?? "-") B",
            "GGUF 头   : magic=\(ggufMagic ?? "-") version=\(ggufVersion.map(String.init) ?? "-") tensors=\(tensorCount.map(String.init) ?? "-")",
            "config    : \(configPresent ? "OK" : "缺失")",
            "tokenizer : \(tokenizerPresent ? "OK" : "缺失")",
            "Metal     : \(metalDevice ?? "不可用")",
            "权重格式  : \(weightFormat)",
            "运行时    : \(offlineOnly ? "全程离线（无网络调用）" : "异常")",
            "结论      : \(ready ? "READY" : "NOT READY")",
        ]
    }
}

public enum SherryRuntimeProbe {
    public static let weightFormat =
        "Sherry STQ1_0 1.3125 bpw 常驻 GEMV (NOT LUT4, NOT affine INT4, NOT fp16 展开缓存)"

    public static func status() -> SherryRuntimeStatus {
        let fm = FileManager.default
        let dir = locateSherryModelDirectory()
        let gguf = dir?.appendingPathComponent("Hy-MT2-1.8B-1.25Bit.gguf")
        let ggufPath = gguf?.path
        var bytes: Int64? = nil
        var magic: String? = nil
        var version: Int? = nil
        var tensors: Int? = nil
        if let gguf, let attrs = try? fm.attributesOfItem(atPath: gguf.path),
           let size = attrs[.size] as? NSNumber {
            bytes = size.int64Value
        }
        if let gguf, let handle = try? FileHandle(forReadingFrom: gguf) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 16), head.count >= 16 {
                magic = String(data: head.prefix(4), encoding: .ascii)
                version = head.withUnsafeBytes { raw in
                    Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                }
                tensors = head.withUnsafeBytes { raw in
                    Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
                }
            }
        }
        let configPath = dir?.appendingPathComponent("config.json").path
        let tokenizerPath = dir?.appendingPathComponent("tokenizer.json").path
        let config = configPath.map { fm.fileExists(atPath: $0) } ?? false
        let tokenizer = tokenizerPath.map { fm.fileExists(atPath: $0) } ?? false
        let device = MTLCreateSystemDefaultDevice()?.name
        let ready = bytes != nil && magic == "GGUF" && config && tokenizer && device != nil
        return SherryRuntimeStatus(
            modelDirectory: dir?.path,
            ggufPath: ggufPath,
            ggufBytes: bytes,
            ggufMagic: magic,
            ggufVersion: version,
            tensorCount: tensors,
            configPresent: config,
            tokenizerPresent: tokenizer,
            metalDevice: device,
            ready: ready,
            weightFormat: weightFormat,
            offlineOnly: true)
    }
}
