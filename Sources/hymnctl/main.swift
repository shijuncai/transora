import Foundation
import Darwin
import HymnCore
import HymnStore
import HymnSTQ

/// HymnTranslate 命令行工具（单后端产品版）。
///
/// 唯一推理后端：Sherry STQ1_0 1.3125 bpw 常驻 GEMV（NOT LUT4 / NOT affine INT4）。
/// 运行时不依赖 MLX、不依赖 fp16 展开缓存、不访问网络。
@main
struct HymnCtl {
    static func option(_ args: [String], _ name: String, _ fallback: String) -> String {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
        return args[i + 1]
    }

    static func usage() {
        print("""
        HymnTranslate CLI — Swift 6 / Metal / 全程离线 / 单后端

          hymnctl verify [--json]           上线自检：模型、config、tokenizer、Metal、格式标注
          hymnctl translate --text "..."    流式翻译（唯一后端 Sherry STQ1_0 1.25bit GGUF）
                 [--from en] [--to zh] [--tokens 96] [--db <path>] [--fixture]
          hymnctl evaluate --input <jsonl>  离线翻译质量评测：一次 prepare，批量产出译文假说
                 [--out <jsonl>] [--limit N] [--tokens 96]
                 [--seed <uint64>] [--greedy]
                                            每请求按 seed 独立重建采样器（请求级可复现）；
                                            --greedy 用 temperature=0 消除采样随机性；
                                            Python 仅离线算 BLEU/chrF/COMET，不参与运行时推理
          hymnctl bench-h1 [--runs 5]       H1 基准：逐 token / batched prefill / int8 KV 的
                                            数值等价、KV 内存与 prefill 耗时实测
          hymnctl batch --count 20          批量翻译链路演示（测试替身，非译文）
          hymnctl cancel                    任务取消演示（测试替身，非译文）

          ── PDF 对象层（P0/P1，纯本地、不改语义）──
          hymnctl pdf-dump <file> [--json]  解析结构：版本/页数/xref/对象数/是否加密
          hymnctl pdf-inspect <file>        逐页内容流算子统计（Tj/TJ/re/Do/BI 计数）
                 [--page N] [--json]
          hymnctl pdf-evict <in> <out>      文本驱逐：删除 Tj/TJ/'/" 四个显示算子，
                 [--page N] [--json]        递归进入 Form XObject；其余字节原样保留
                                            （增量更新写回），用于验证「非文本区域结构不变」
          hymnctl pdf-stamp <in> <out>      驱逐原文 + 用思源宋体画一行字，
                 --text "…" [--page N]      验证「接管文本」链路（内嵌子集字体）
                 [--size 14] [--x 72 --y 100]
                 [--bold] [--font path] [--keep-forms] [--json]
          hymnctl pdf-structure <file>      结构提取：行 → 段落块 → 表格/插图，
                 [--page N] [--out path]       输出 IL JSON（schema=linguanova.il/1）
                 [--json] [--no-tables] [--no-lines] [--spans] [--minified]
                 [--runs [--dump-content p]]   诊断：逐 run 打印几何/字体，
                                               并可导出整页合并后的内容流
                                               （环境变量 HYMN_TRACE_OPS=1 打开算子级追踪）
          hymnctl pdf-typeset <in> <out>     排版：译文写回原版式（驱逐原文 + 按框重排）
          hymnctl pdf-analyze <in> <out>    排版 + R1–R7 校验 + 自动修复（闭环）
          hymnctl pdf-report <in> <out.html> 排版 + 逐段对照报告（原文/译文/处理结果）
                 [--translations map.json] [--page N] [--pseudo]
                 [--no-tables] [--no-orphans] [--margin pt]
                 [--report report.json] [--json]
          hymnctl pdf-verify <before> <after>
                                            逐对象比对：页数一致 + 图片流字节相同
                                            （PASS/FAIL，FAIL 退出码 5）
          hymnctl sherry-cache [--rebuild]  把 1.25bit GGUF 解码为 fp16 缓存（仅离线 golden 用）
                 [--gguf <path>]            运行时不需要此缓存

          模型目录：HYMN_SHERRY_MODEL_DIR 严格优先，其次为工作目录或
          ~/Library/Application Support/HymnTranslate/Models 下的
          Hy-MT2-1.8B-1.25Bit-GGUF（需含 .gguf / config.json / tokenizer.json）。
        """)
    }

    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first ?? "help" {
        case "verify": try verify(json: args.contains("--json"))
        case "sherry-cache": try sherryCacheCommand(args)
        case "translate": try await translate(args)
        case "evaluate": try await evaluate(args)
        case "bench-h1": try benchH1(args)
        case "batch": try await batch(args)
        case "cancel": try await cancelDemo()
        case "pdf-dump": try pdfDump(args)
        case "pdf-inspect": try pdfInspect(args)
        case "pdf-evict": try pdfEvict(args)
        case "pdf-stamp": try pdfStamp(args)
        case "pdf-structure": try pdfStructure(args)
        case "pdf-typeset": try pdfTypeset(args)
        case "pdf-verify": try pdfVerify(args)
        case "pdf-analyze": try pdfAnalyze(args)
        case "pdf-report": try pdfReport(args)
        case "pdf-diff": try pdfDiff(args)
        case "help", "--help", "-h": usage()
        default:
            fputs("未知命令: \(args.first ?? "")\n", stderr)
            usage()
            exit(2)
        }
    }

    // MARK: - 上线自检（只读，不加载模型）

    static func verify(json: Bool) throws {
        let status = SherryRuntimeProbe.status()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(status)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("=== HymnTranslate 运行时自检（唯一后端） ===")
            status.summaryLines.forEach { print($0) }
            print(status.ready
                  ? "VERIFY_READY 运行时资源齐备，可全程离线推理。"
                  : "VERIFY_NOT_READY 请补齐缺失项后重试。")
        }
        if !status.ready { exit(2) }
    }

    // MARK: - G1：GGUF(STQ1_0/Q6_K) → fp16 权重缓存（仅离线 golden）

    static func sherryCacheCommand(_ args: [String]) throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let defaultGGUF = root.appendingPathComponent(
            "Models/Hy-MT2-1.8B-1.25Bit-GGUF/Hy-MT2-1.8B-1.25Bit.gguf")
        let ggufURL = URL(fileURLWithPath: option(args, "--gguf", defaultGGUF.path))
        let dir = ggufURL.deletingLastPathComponent()
        let cacheURL = dir.appendingPathComponent("weights.fp16.bin")

        if !args.contains("--rebuild"), fm.fileExists(atPath: cacheURL.path) {
            print("SHERRY_CACHE_EXISTS \(cacheURL.path)")
            return
        }
        // 运行时不需要缓存；config / tokenizer 必须由 GGUF 目录自带，
        // 不再从已退役的 4bit 目录复制，避免出现隐藏的数据依赖。
        for name in ["config.json", "tokenizer.json"] {
            guard fm.fileExists(atPath: dir.appendingPathComponent(name).path) else {
                fputs("缺少 \(name)：\(dir.path)\n", stderr)
                exit(2)
            }
        }
        let gguf = try GGUFFile(url: ggufURL)
        print("GGUF v\(gguf.version) tensors=\(gguf.tensors.count) dataStart=\(gguf.dataStart)")
        let report = try SherryCacheBuilder.build(gguf: gguf, destination: cacheURL)
        print("SHERRY_CACHE_OK \(report)")
    }

    // MARK: - translate

    static func translate(_ args: [String]) async throws {
        let text = option(args, "--text", "Hello, nice to meet you.")
        let from = option(args, "--from", "en")
        let to = option(args, "--to", "zh")
        let tokens = Int(option(args, "--tokens", "96")) ?? 96
        let dbPath = option(args, "--db", "")
        let useFixture = args.contains("--fixture")

        let backend: any InferenceBackend = useFixture
            ? FixtureBackend(tokenCount: tokens, tokenDelayNanos: 1_000_000)
            : SherryBackend()
        let engine = TranslationEngine(backend: backend)
        try await engine.prepare()

        print("后端: \(backend.identifier)")
        print("权重格式: \(backend.declaredWeightFormat)")
        print("真实模型推理: \(backend.performsRealModelInference ? "YES" : "NO")")
        if !backend.performsRealModelInference {
            print("⚠️  输出为 [fixture] 占位 token，不是译文（仅链路演示）。")
        }
        print("输入: \(text)  (\(from) -> \(to))")
        print("--- stream ---")

        let languages = LanguagePair(source: from, target: to)
        var store: SQLiteStore? = nil
        if !dbPath.isEmpty { store = try SQLiteStore(path: dbPath) }
        defer { store?.close() }

        let matcher = GlossaryMatcher(entries: store.flatMap { try? $0.fetchTerms(languages: languages) } ?? [])
        let req = InferenceRequest(
            text: text, languages: languages, maxTokens: tokens,
            glossaryHints: matcher.hints(for: text, languages: languages))
        let start = DispatchTime.now().uptimeNanoseconds
        var assembled = ""
        var count = 0
        for try await chunk in await engine.stream(req) {
            if chunk.isFinal { continue }
            assembled += chunk.text
            count += 1
            print(chunk.text, terminator: "")
            fflush(stdout)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        print("")
        print("--- end ---")
        print("tokens=\(count) elapsed=\(String(format: "%.2f", Double(elapsed) / 1_000_000))ms")

        if let store {
            _ = try store.insertHistory(HistoryRecord(
                requestID: req.id.uuidString, sourceLang: from, targetLang: to,
                sourceText: text, targetText: assembled,
                durationMs: Int64(elapsed / 1_000_000), tokenCount: count,
                cancelled: false,
                modelTag: useFixture
                    ? "fixture-v0 (TEST DOUBLE, 非模型推理)"
                    : "\(backend.identifier) (REAL INFERENCE, STQ1_0, NOT LUT4)"
            ))
            print("history rows=\(try store.countHistory()) @ \(dbPath)")
        }
        await engine.shutdown()
    }

    // MARK: - 批量翻译评测（Swift 侧只产出译文假说）

    /// 读取由 `Scripts/fetch-eval-data.py` 从权威平行语料抽取的 JSONL，
    /// 一次 prepare 后循环翻译，写出带参考译文的 JSONL 供离线 BLEU/chrF 打分。
    static func evaluate(_ args: [String]) async throws {
        let inputPath = option(args, "--input", "Eval/opus100-samples.jsonl")
        let outPath = option(args, "--out", "Reports/translation-hypotheses.jsonl")
        let limit = Int(option(args, "--limit", "0")) ?? 0
        let maxTokens = Int(option(args, "--tokens", "96")) ?? 96
        // 请求级可复现：seed 现在真正生效（每个请求重建 Sampler）。
        // --greedy 用 temperature=0 / top_k=1 走 argmax，完全不消耗 RNG。
        var sampling = SamplingConfig()
        if args.contains("--greedy") { sampling = .greedy }
        let seedArg = option(args, "--seed", "")
        if let parsed = UInt64(seedArg), parsed != 0 { sampling.seed = parsed }
        let backend = SherryBackend(sampling: sampling)

        let raw = try String(contentsOfFile: inputPath, encoding: .utf8)
        struct Sample {
            let id: String, from: String, to: String, source: String, reference: String
        }
        var samples: [Sample] = []
        for line in raw.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let data = String(line).data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = obj["id"] as? String,
                  let from = obj["source_lang"] as? String,
                  let to = obj["target_lang"] as? String,
                  let source = obj["source"] as? String,
                  let reference = obj["reference"] as? String
            else { continue }
            samples.append(Sample(id: id, from: from, to: to, source: source, reference: reference))
            if limit > 0 && samples.count >= limit { break }
        }
        guard !samples.isEmpty else {
            print("EVAL_FAIL 输入为空或格式不正确: \(inputPath)")
            exit(2)
        }

        let engine = TranslationEngine(backend: backend)
        try await engine.prepare()

        try? FileManager.default.removeItem(atPath: outPath)
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        defer { try? handle.close() }

        print("EVAL_START backend=\(backend.identifier) format=\(backend.declaredWeightFormat) "
              + "samples=\(samples.count) maxTokens=\(maxTokens) "
              + "seed=\(sampling.seed) greedy=\(sampling.temperature == 0) "
              + "request_level_reproducible=true")
        fflush(stdout)
        var ok = 0, failed = 0
        for (i, sample) in samples.enumerated() {
            let req = InferenceRequest(
                text: sample.source,
                languages: LanguagePair(source: sample.from, target: sample.to),
                maxTokens: maxTokens)
            let start = DispatchTime.now().uptimeNanoseconds
            var hypothesis = "", chunks = 0, errorText = ""
            do {
                for try await chunk in await engine.stream(req) {
                    if chunk.isFinal { continue }
                    hypothesis += chunk.text
                    chunks += 1
                }
            } catch {
                errorText = String(describing: error)
            }
            let wallMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let row: [String: Any] = [
                "id": sample.id,
                "backend": backend.identifier,
                "source_lang": sample.from,
                "target_lang": sample.to,
                "source": sample.source,
                "reference": sample.reference,
                "hypothesis": hypothesis,
                "chunks": chunks,
                "wall_ms": wallMs,
                "error": errorText,
                "sampling_mode": sampling.temperature == 0 ? "greedy" : "sample",
                "sampling_seed": String(sampling.seed),
                "request_level_reproducible": true,
            ]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
            if errorText.isEmpty && !hypothesis.isEmpty { ok += 1 } else { failed += 1 }
            if (i + 1) % 25 == 0 || i + 1 == samples.count {
                print("EVAL_PROGRESS \(i + 1)/\(samples.count) ok=\(ok) failed=\(failed)")
                fflush(stdout)
            }
        }
        print("EVAL_DONE backend=\(backend.identifier) total=\(samples.count) ok=\(ok) "
              + "failed=\(failed) out=\(outPath)")
        await engine.shutdown()
    }

    // MARK: - H1 基准（数值等价 / KV 内存 / prefill 耗时，全部真实推理）

    /// 同一 prompt 跑三条路径：
    ///   baseline = 逐 token forward（G4 原路径）
    ///   batched  = 分块提交 + 跳过中间 token 的 lm_head（H1-a，无损）
    ///   int8     = batched + int8 KV cache（H1-b，有损）
    /// Python 不参与；所有数字来自本机 Metal 实际执行。
    static func benchH1(_ args: [String]) throws {
        let runs = max(1, Int(option(args, "--runs", "5")) ?? 5)
        let text = option(args, "--text", "Hello, nice to meet you.")
        guard let dir = locateSherryModelDirectory() else {
            fputs("BENCH_H1_FAIL 未找到 1.25bit GGUF 目录\n", stderr)
            exit(2)
        }
        let tok = try HymnTokenizer(modelDirectory: dir)
        let req = InferenceRequest(text: text,
                                   languages: LanguagePair(source: "en", target: "zh"),
                                   maxTokens: 32)
        let prompt = try SherryPromptBuilder.buildPrompt(req, tokenizer: tok)

        let f16 = try SherryResidentModel(modelDirectory: dir, maxSequenceLength: 1024,
                                          kvCacheMode: .fp16)
        let i8 = try SherryResidentModel(modelDirectory: dir, maxSequenceLength: 1024,
                                         kvCacheMode: .int8)
        // 预热 pipeline / kernel 编译，避免计入首轮计时。
        _ = try f16.forward(tokenID: 0, position: 0)
        _ = try i8.forward(tokenID: 0, position: 0)

        func baseline() throws -> [Float] {
            var l: [Float] = []
            for (p, t) in prompt.enumerated() { l = try f16.forward(tokenID: t, position: p) }
            return l
        }
        func batched() throws -> [Float] { try f16.prefill(ids: prompt) }
        func int8Path() throws -> [Float] { try i8.prefill(ids: prompt) }

        let bl = try baseline()
        let bt = try batched()
        let i8l = try int8Path()

        var maxAbsBatched = 0.0, maxAbsInt8 = 0.0
        let n = min(bl.count, min(bt.count, i8l.count))
        for i in 0..<n {
            maxAbsBatched = max(maxAbsBatched, Double(abs(bl[i] - bt[i])))
            maxAbsInt8 = max(maxAbsInt8, Double(abs(bl[i] - i8l[i])))
        }
        let exact = (bl.count == bt.count) && (bl == bt)

        func pearson(_ a: [Float], _ b: [Float]) -> Double {
            let m = min(a.count, b.count)
            var sa = 0.0, sb = 0.0
            for i in 0..<m { sa += Double(a[i]); sb += Double(b[i]) }
            let ma = sa / Double(m), mb = sb / Double(m)
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<m {
                let x = Double(a[i]) - ma, y = Double(b[i]) - mb
                num += x * y; da += x * x; db += y * y
            }
            return da > 0 && db > 0 ? num / (da.squareRoot() * db.squareRoot()) : 0
        }
        func topK(_ l: [Float], _ k: Int) -> [Int] {
            Array(l.indices.sorted { l[$0] > l[$1] }.prefix(k))
        }
        func argmax(_ l: [Float]) -> Int { l.indices.max { l[$0] < l[$1] } ?? -1 }
        let overlap = Set(topK(bl, 20)).intersection(Set(topK(i8l, 20))).count

        func timed(_ f: () throws -> [Float]) throws -> [Double] {
            var xs: [Double] = []
            for _ in 0..<runs {
                let t = DispatchTime.now().uptimeNanoseconds
                _ = try f()
                xs.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000.0)
            }
            return xs
        }
        let tB = try timed(baseline), tT = try timed(batched), tI = try timed(int8Path)
        func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

        // 端到端 greedy 译文（确定性）：确认优化是否改变实际输出。
        func generated(_ gen: SherryGenerator) throws -> String {
            var ids: [Int] = []
            _ = try gen.generate(promptIDs: prompt, maxTokens: 32, sampling: .greedy,
                                 onToken: { ids.append($0) })
            return tok.decode(ids)
        }
        let textF16 = try generated(SherryGenerator(model: f16, tokenizer: tok))
        let textI8 = try generated(SherryGenerator(model: i8, tokenizer: tok))

        let mB = median(tB), mT = median(tT), mI = median(tI)
        let saved = f16.kvCacheBytes - i8.kvCacheBytes
        let report: [String: Any] = [
            "stage": "H1: batched prefill / int8 KV cache / fused dequant-GEMM 口径",
            "backend": "Sherry STQ1_0 1.3125 bpw 常驻 GEMV (NOT LUT4 / NOT affine INT4 / NOT fp16 展开缓存)",
            "prompt_tokens": prompt.count,
            "runs": runs,
            "numerical_equivalence": [
                "baseline_vs_batched_bit_exact": exact,
                "baseline_vs_batched_max_abs": maxAbsBatched,
                "baseline_vs_int8_pearson_corr": pearson(bl, i8l),
                "baseline_vs_int8_max_abs": maxAbsInt8,
                "baseline_vs_int8_top20_overlap": overlap,
                "argmax_baseline": argmax(bl),
                "argmax_batched": argmax(bt),
                "argmax_int8": argmax(i8l),
            ],
            "prefill_ms": [
                "baseline_median": mB, "batched_median": mT, "int8_median": mI,
                "speedup_batched": mT > 0 ? mB / mT : 0,
                "baseline_runs": tB, "batched_runs": tT, "int8_runs": tI,
                "note": "纯 prefill 墙钟中位数；不含 decode、不含模型加载。",
            ],
            "kv_cache_bytes": [
                "fp16": f16.kvCacheBytes, "int8": i8.kvCacheBytes,
                "saved_bytes": saved, "saved_mib": Double(saved) / 1_048_576.0,
                "note": "int8 路径额外含 per-(token,kvHead) fp32 scale buffer；收益有限，如实标注。",
            ],
            "end_to_end_greedy": [
                "fp16_batched": textF16, "int8_batched": textI8,
                "identical": textF16 == textI8,
            ],
            "default_kv_cache_mode": "fp16",
            "fused_dequant_gemm": "stq1_0_gemv 自 G4 起已是「解码即乘加」融合，无中间 fp16 权重缓存；本轮不重复造算子、不重复计功。",
            "notes": [
                "batched prefill 与逐 token forward 使用完全相同的 kernel 顺序与临时 buffer，故 logits 应逐元素相等。",
                "int8 KV cache 是有损优化，默认关闭；启用方式 HYMN_KV_INT8=1 或显式 .int8。",
                "KV cache 节省量小（约 31 MiB），这是 32 层 × 4 KV heads × head_dim 128 × seq 1024 的真实量级，不夸大。",
            ],
        ]
        let out = "Reports/h1-optimization-bench.json"
        let data = try JSONSerialization.data(withJSONObject: report,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: out))
        print("BENCH_H1_OK prompt=\(prompt.count) runs=\(runs)")
        print("  bit_exact(batched)=\(exact) maxAbs=\(maxAbsBatched)")
        print(String(format: "  int8 corr=%.6f maxAbs=%.4f top20=%d/20",
                     pearson(bl, i8l), maxAbsInt8, overlap))
        print(String(format: "  prefill baseline=%.1fms batched=%.1fms int8=%.1fms speedup=%.2fx",
                     mB, mT, mI, mT > 0 ? mB / mT : 0))
        print("  kv_cache fp16=\(f16.kvCacheBytes)B int8=\(i8.kvCacheBytes)B saved=\(saved)B")
        print("  greedy fp16=\(textF16) | int8=\(textI8) | identical=\(textF16 == textI8)")
        print("  WROTE \(out)")
    }

    // MARK: - 链路演示（测试替身，明确标注不产生译文）

    static func batch(_ args: [String]) async throws {
        let count = Int(option(args, "--count", "20")) ?? 20
        let backend = FixtureBackend(tokenCount: 6, tokenDelayNanos: 300_000)
        let engine = TranslationEngine(backend: backend)
        try await engine.prepare()
        let reqs = (0..<count).map { InferenceRequest(text: "batch-\($0)", maxTokens: 6) }
        let start = DispatchTime.now().uptimeNanoseconds
        let outcomes = await BatchTranslator(engine: engine).translateAll(reqs, maxInFlight: 8)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let ok = outcomes.filter(\.succeeded).count
        print("⚠️  后端: \(backend.identifier)（测试替身，非模型推理）")
        print("batch count=\(count) succeeded=\(ok) elapsed=\(String(format: "%.2f", Double(elapsed) / 1_000_000))ms")
        print("throughput=\(String(format: "%.1f", Double(count) / (Double(elapsed) / 1_000_000_000))) req/s")
        let snap = await engine.snapshot()
        print("scheduler completed=\(snap.scheduler.completed) maxConcurrency=\(snap.scheduler.maxConcurrency)")
    }

    static func cancelDemo() async throws {
        let backend = FixtureBackend(tokenCount: 10_000, tokenDelayNanos: 1_000_000)
        let engine = TranslationEngine(backend: backend)
        try await engine.prepare()
        let req = InferenceRequest(text: "long running", maxTokens: 10_000)
        let task = Task { try await engine.translate(req) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        await engine.cancel(id: req.id)
        let result = try await task.value
        print("⚠️  后端: \(backend.identifier)（测试替身，非模型推理）")
        print("cancelled=\(result.wasCancelled) tokens_before_stop=\(result.tokenCount)/10000")
        print("cancel_latency=\(String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))ms")
    }
}
