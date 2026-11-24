import Foundation
import HymnCore

// G4 / G8：Sherry STQ1_0 1.25bit GGUF 常驻推理后端（**唯一**推理后端）。
//
// performsRealModelInference = true 的依据：
//   · 真实 AngelSlim GGUF（461,860,800 B，SHA256 官方一致）常驻 MTLBuffer；
//   · STQ1_0 / Q6_K 解码即乘加由 SherryGEMV 的 MSL kernel 完成，
//     经独立 Python/PR #22836 golden 逐元素校验；
//   · 32 层 forward 与离线 fp32 参考 golden 对齐（见 sherry-forward-manifest.json）；
//   · 推理全程 Task.detached / RequestScheduler 单实例。
//
// ⚠️ 权重格式如实标注：**Sherry STQ1_0 1.3125 bpw 常驻 GEMV**，
// **不是 LUT4、不是 affine INT4、不是 fp16 展开缓存**。
// D-1 / MLX 两个并列后端已于 2026-11-21 退役；CLI 与 App 均只构造本后端。

private final class SherryCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// GGUF 目录定位（面向分发版）：
/// 1. `HYMN_SHERRY_MODEL_DIR` **严格优先**（不校验、不静默回退，便于故障注入）；
/// 2. 用户在 App「设置 → 选择模型目录」里保存的路径（校验 marker 存在）；
/// 3. **App 内嵌模型**（「App + 模型」合一包的 `Contents/Resources/Models/…`）；
/// 4. 工作目录与 Application Support 软链（开发机 / 轻量包）。
public func locateSherryModelDirectory() -> URL? {
    let fm = FileManager.default
    let marker = "Hy-MT2-1.8B-1.25Bit.gguf"
    if let env = ProcessInfo.processInfo.environment["HYMN_SHERRY_MODEL_DIR"], !env.isEmpty {
        return URL(fileURLWithPath: env, isDirectory: true)
    }
    if let saved = UserDefaults.standard.string(forKey: "hymn.modelDirectory"), !saved.isEmpty {
        let url = URL(fileURLWithPath: saved, isDirectory: true)
        if fm.fileExists(atPath: url.appendingPathComponent(marker).path) { return url }
    }
    var candidates: [URL] = []
    // 合一包：模型与 App 一起分发，路径是 <Bundle>/Contents/Resources/Models/…
    if let resources = Bundle.main.resourceURL {
        candidates.append(resources.appendingPathComponent(
            "Models/Hy-MT2-1.8B-1.25Bit-GGUF", isDirectory: true))
    }
    candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath)
        .appendingPathComponent("Models/Hy-MT2-1.8B-1.25Bit-GGUF", isDirectory: true))
    if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        candidates.append(support.appendingPathComponent(
            "HymnTranslate/Models/Hy-MT2-1.8B-1.25Bit-GGUF", isDirectory: true))
    }
    for url in candidates where fm.fileExists(atPath: url.appendingPathComponent(marker).path) {
        return url
    }
    return nil
}

public final class SherryBackend: InferenceBackend, @unchecked Sendable {
    public let identifier: String = "hymn-stq1_0-gguf-v1"
    public let declaredWeightFormat: String =
        "Sherry STQ1_0 1.3125 bpw 常驻 GEMV (NOT LUT4, NOT affine INT4, NOT fp16 展开缓存)"
    public let performsRealModelInference: Bool = true

    private let lock = NSLock()
    private var generator: SherryGenerator?
    private var tokenizer: HymnTokenizer?
    private let modelDirectory: URL?
    private let sampling: SamplingConfig

    public init(modelDirectory: URL? = nil, sampling: SamplingConfig = SamplingConfig()) {
        self.modelDirectory = modelDirectory ?? locateSherryModelDirectory()
        self.sampling = sampling
    }

    public func prepare() async throws {
        guard let dir = modelDirectory else {
            throw HymnFailure.unavailable(
                "未找到 1.25bit GGUF 目录（HYMN_SHERRY_MODEL_DIR 或 Models/Hy-MT2-1.8B-1.25Bit-GGUF）")
        }
        let gguf = dir.appendingPathComponent("Hy-MT2-1.8B-1.25Bit.gguf")
        guard FileManager.default.fileExists(atPath: gguf.path) else {
            throw HymnFailure.unavailable("缺少 Hy-MT2-1.8B-1.25Bit.gguf")
        }
        let loaded = try await Task.detached(priority: .userInitiated) {
            () -> (SherryGenerator, HymnTokenizer) in
            let tok = try HymnTokenizer(modelDirectory: dir)
            // 2048 而不是 1024：PDF 逐段翻译的一段正文常有 800~1500 字符，
            // 提示词本身就要吃掉 400~900 token，1024 的窗口连一段都放不下，
            // 生成器只能截断（旧版更糟：直接抛错、整段回落英文）。
            // 代价是 KV 从 4 MB 涨到 8 MB，threadgroup 从 8 KB 涨到 16 KB（上限 32 KB）。
            let model = try SherryResidentModel(modelDirectory: dir, maxSequenceLength: 2048)
            // 前置首次 Metal kernel / pipeline 编译，避免计入首个请求 TTFT。
            _ = try model.forward(tokenID: 0, position: 0)
            return (SherryGenerator(model: model, tokenizer: tok), tok)
        }.value
        storeLoaded(loaded.0, loaded.1)
    }

    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return generator != nil
    }

    /// 常驻权重/GPU buffer 字节数（测试与性能报告用；未 prepare 时为 nil）。
    public var residentWeightBytes: Int? { currentGenerator?.model.residentWeightBytes }
    public var gpuBufferBytes: Int? { currentGenerator?.model.gpuBufferBytes }
    public var normBufferBytes: Int? { currentGenerator?.model.normBufferBytes }

    public func stream(
        _ request: InferenceRequest,
        cancellation: CancellationRegistry
    ) -> AsyncThrowingStream<TokenChunk, any Error> {
        let flag = SherryCancelFlag()
        let samplingConfig = sampling
        let backend = self

        return AsyncThrowingStream<TokenChunk, any Error> { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    guard let gen = backend.currentGenerator, let tok = backend.currentTokenizer else {
                        throw HymnFailure.unavailable("Sherry 后端未 prepare()")
                    }
                    let prompt = try SherryPromptBuilder.buildPrompt(request, tokenizer: tok)
                    // 上限按「剩余窗口」收敛，别让请求里的 1024 顶着提示词一起溢出。
                    let capacity = max(16, gen.model.maxSeq - prompt.count - 1)
                    let budget = min(max(request.maxTokens, 1), capacity)
                    var generated: [Int] = []
                    // 按 Unicode scalar 增量，屏蔽尾部未完成多字节字符，
                    // 避免复杂脚本语言出现 U+FFFD 残留与字符重复。
                    var decoder = StreamingTextDecoder()
                    var lastDecoded = ""
                    var index = 0

                    let metrics = try gen.generate(
                        promptIDs: prompt,
                        maxTokens: budget,
                        sampling: samplingConfig,
                        onToken: { id in
                            generated.append(id)
                            let full = tok.decode(generated)
                            let delta = decoder.delta(fullDecoded: full)
                            lastDecoded = full
                            if !delta.isEmpty {
                                continuation.yield(
                                    TokenChunk(requestID: request.id, index: index, text: delta))
                                index += 1
                            }
                        },
                        isCancelled: { Task.isCancelled || flag.isSet }
                    )
                    let registryCancelled = await cancellation.isCancelled(request.id)
                    if Task.isCancelled || flag.isSet || registryCancelled || metrics.cancelled {
                        continuation.finish(throwing: HymnFailure.cancelled(request.id))
                        return
                    }
                    // 冲刷尾部：正常以 EOS 结束时为空；被 maxTokens 截断且尾部
                    // 有未完成多字节字节时，如实补一个替换字符，不静默吞字。
                    let tail = decoder.finish(fullDecoded: lastDecoded)
                    if !tail.isEmpty {
                        continuation.yield(
                            TokenChunk(requestID: request.id, index: index, text: tail))
                        index += 1
                    }
                    continuation.yield(
                        TokenChunk(requestID: request.id, index: index, text: "", isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            let watchdog = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    if await cancellation.isCancelled(request.id) {
                        flag.set()
                        worker.cancel()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000)
                }
            }

            continuation.onTermination = { @Sendable _ in
                worker.cancel()
                watchdog.cancel()
            }
        }
    }

    public func shutdown() async { clearLoaded() }

    private func storeLoaded(_ gen: SherryGenerator, _ tok: HymnTokenizer) {
        lock.lock(); generator = gen; tokenizer = tok; lock.unlock()
    }
    private func clearLoaded() {
        lock.lock(); generator = nil; tokenizer = nil; lock.unlock()
    }
    private var currentGenerator: SherryGenerator? {
        lock.lock(); defer { lock.unlock() }; return generator
    }
    private var currentTokenizer: HymnTokenizer? {
        lock.lock(); defer { lock.unlock() }; return tokenizer
    }

}
