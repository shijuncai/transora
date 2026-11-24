import Foundation

public struct LanguagePair: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let source: String
    public let target: String
    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
    public var description: String { "\(source)->\(target)" }
}

public struct GlossaryHint: Sendable, Equatable {
    public let source: String
    public let target: String
    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public struct InferenceRequest: Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let languages: LanguagePair
    public let maxTokens: Int
    public let priority: Int
    public let glossaryHints: [GlossaryHint]

    public init(
        id: UUID = UUID(),
        text: String,
        languages: LanguagePair = .init(source: "en", target: "zh"),
        maxTokens: Int = 128,
        priority: Int = 0,
        glossaryHints: [GlossaryHint] = []
    ) {
        self.id = id
        self.text = text
        self.languages = languages
        self.maxTokens = maxTokens
        self.priority = priority
        self.glossaryHints = glossaryHints
    }
}

public struct TokenChunk: Sendable, Equatable {
    public let requestID: UUID
    public let index: Int
    public let text: String
    public let isFinal: Bool
    public init(requestID: UUID, index: Int, text: String, isFinal: Bool = false) {
        self.requestID = requestID
        self.index = index
        self.text = text
        self.isFinal = isFinal
    }
}

/// 具体错误类型（避免 `any Error` 在 Swift 6 严格并发下跨 actor 传递）。
public struct HymnFailure: Error, Sendable, CustomStringConvertible, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "[\(code)] \(message)" }

    public static func cancelled(_ id: UUID) -> HymnFailure {
        .init(code: "CANCELLED", message: "request \(id.uuidString.prefix(8)) cancelled")
    }
    public static func rejected(_ s: String) -> HymnFailure {
        .init(code: "FORMAT_REJECTED", message: s)
    }
    public static func unavailable(_ s: String) -> HymnFailure {
        .init(code: "BACKEND_UNAVAILABLE", message: s)
    }
    public static func invalid(_ s: String) -> HymnFailure {
        .init(code: "INVALID_INPUT", message: s)
    }
}

/// 推理后端契约。
///
/// ⚠️ 重要：`performsRealModelInference` 是每个后端**必须如实声明**的能力标志。
/// `FixtureBackend` 声明 false，仅用于调度/流式/批量/取消/线程隔离链路测试。
/// `SherryBackend` 声明 true，依据是真实 1.25bit GGUF（STQ1_0 / Q6_K）常驻权重、
/// 独立 Python golden 的逐元素解码与 32 层 forward 数值对齐（相关系数 0.999999），
/// 以及端到端真实译文冒烟。权重格式永远标注 STQ1_0 1.3125 bpw，
/// **不是 LUT4、不是 affine INT4**。D-1 与 MLX Swift 后端已退役。
public protocol InferenceBackend: Sendable {
    var identifier: String { get }
    var declaredWeightFormat: String { get }
    var performsRealModelInference: Bool { get }
    func prepare() async throws
    func stream(
        _ request: InferenceRequest,
        cancellation: CancellationRegistry
    ) -> AsyncThrowingStream<TokenChunk, any Error>
    func shutdown() async
}
