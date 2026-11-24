import Foundation
import Darwin
import HymnCore
import HymnSTQ

// G4：常驻 STQ1_0 / Q6_K GEMV 的独立数值测试。
// golden 由 Scripts/gen-sherry-golden.py 独立 Python 实现生成，运行时不加载 Python。

private func sherryResidentGoldenDir() -> URL {
    if let d = ProcessInfo.processInfo.environment["HYMN_GOLDEN_DIR"] {
        return URL(fileURLWithPath: d)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Golden")
}

private func sherryResidentModelDir() -> URL {
    if let d = ProcessInfo.processInfo.environment["HYMN_SHERRY_MODEL_DIR"] {
        return URL(fileURLWithPath: d)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Models/Hy-MT2-1.8B-1.25Bit-GGUF", isDirectory: true)
}

private func residentReadF32(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    var out = [Float]()
    out.reserveCapacity(data.count / 4)
    data.withUnsafeBytes { raw in
        for i in 0..<(data.count / 4) {
            out.append(Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
        }
    }
    return out
}

private func residentReadJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw GGUFError.misaligned("manifest 不是 JSON object")
    }
    return obj
}

private func residentCorr(_ a: [Float], _ b: [Float]) -> Double {
    let n = min(a.count, b.count)
    guard n > 1 else { return 0 }
    var sa = 0.0, sb = 0.0
    for i in 0..<n { sa += Double(a[i]); sb += Double(b[i]) }
    let ma = sa / Double(n), mb = sb / Double(n)
    var num = 0.0, da = 0.0, db = 0.0
    for i in 0..<n {
        let x = Double(a[i]) - ma, y = Double(b[i]) - mb
        num += x * y; da += x * x; db += y * y
    }
    return (da > 0 && db > 0) ? num / (da.squareRoot() * db.squareRoot()) : 0
}

private func residentTopK(_ a: [Float], _ k: Int) -> [Int] {
    a.indices.sorted { a[$0] > a[$1] }.prefix(k).map { $0 }
}

private func residentMaxAbs(_ a: [Float], _ b: [Float]) -> Float {
    let n = min(a.count, b.count)
    var m: Float = 0
    for i in 0..<n { m = max(m, abs(a[i] - b[i])) }
    return m
}

private func makeNoCacheDirectory(_ src: URL) throws -> URL {
    let fm = FileManager.default
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hymn-sherry-nocache-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let names = ["Hy-MT2-1.8B-1.25Bit.gguf", "config.json", "tokenizer.json",
                 "tokenizer_config.json", "chat_template.jinja",
                 "generation_config.json", "special_tokens_map.json"]
    for n in names {
        let s = src.appendingPathComponent(n)
        if fm.fileExists(atPath: s.path) {
            try fm.createSymbolicLink(at: tmp.appendingPathComponent(n), withDestinationURL: s)
        }
    }
    return tmp
}

public func sherryResidentSuite() async throws -> [TestResult] {
    let suite = "sherry-resident"
    var out: [TestResult] = []
    let dir = sherryResidentModelDir()
    let golden = sherryResidentGoldenDir()
    let ggufURL = dir.appendingPathComponent("Hy-MT2-1.8B-1.25Bit.gguf")
    let goldenOK = FileManager.default.fileExists(atPath: ggufURL.path)
        && FileManager.default.fileExists(atPath: golden.appendingPathComponent("sherry-gemv-manifest.json").path)
        && FileManager.default.fileExists(atPath: golden.appendingPathComponent("sherry-forward-logits.f32").path)

    out.append(check(suite: suite, "1.25bit GGUF 与 G4 独立 golden 已落盘",
                     goldenOK, detail: ggufURL.path))
    guard goldenOK else { return out }

    let model: SherryResidentModel
    do {
        model = try SherryResidentModel(modelDirectory: dir, maxSequenceLength: 1024)
    } catch {
        out.append(check(suite: suite, "常驻模型初始化成功", false, detail: "\(error)"))
        return out
    }

    out.append(check(suite: suite, "常驻权重 461,860,800 B，未展开 3.58 GB fp16 缓存",
                     model.residentWeightBytes == 461_860_800
                     && model.gpuBufferBytes >= 461_860_800
                     && model.gpuBufferBytes < 500_000_000
                     && model.normBufferBytes < 1_000_000
                     && model.gguf.tensors.count == 354,
                     detail: "gguf=\(model.residentWeightBytes) gpu=\(model.gpuBufferBytes) "
                         + "norm=\(model.normBufferBytes) tensors=\(model.gguf.tensors.count)"))

    // 无 fp16 展开缓存也能 prepare：证明运行时依赖的只有 GGUF 原始字节。
    let tmp = try makeNoCacheDirectory(dir)
    var noCacheOK = false
    var noCacheDetail = ""
    do {
        let backend = SherryBackend(modelDirectory: tmp)
        try await backend.prepare()
        noCacheOK = backend.isReady
        await backend.shutdown()
        noCacheDetail = "tmp 目录无 weights.fp16.bin，prepare 成功"
    } catch {
        noCacheDetail = "\(error)"
    }
    try? FileManager.default.removeItem(at: tmp)
    out.append(check(suite: suite, "无 weights.fp16.bin 也能 prepare（常驻 GGUF）",
                     noCacheOK, detail: noCacheDetail))

    // ---- GEMV / embedding kernel 与独立 Python golden 逐元素对齐 ----
    let gemvManifest = try residentReadJSON(golden.appendingPathComponent("sherry-gemv-manifest.json"))
    let samples = gemvManifest["samples"] as? [[String: Any]] ?? []
    var gemvMax: Float = 0
    var gemvCorrMin = 1.0
    var gemvCompared = 0
    for s in samples {
        guard let name = s["tensor"] as? String,
              let rows = (s["rows"] as? NSNumber)?.intValue,
              let xf = s["x_file"] as? String,
              let yf = s["y_file"] as? String else { continue }
        let x = try residentReadF32(golden.appendingPathComponent(xf))
        let y = try residentReadF32(golden.appendingPathComponent(yf))
        let got = try model.gemv(ggufTensorName: name, x: x, maxOutFeatures: rows)
        let n = min(got.count, y.count)
        guard n > 0 else { continue }
        gemvMax = max(gemvMax, residentMaxAbs(got, y))
        gemvCorrMin = min(gemvCorrMin, residentCorr(got, y))
        gemvCompared += n
    }
    out.append(check(suite: suite, "常驻 STQ1_0/Q6_K GEMV 与独立 Python/PR golden 对齐",
                     gemvCompared > 0 && samples.count == 4 && gemvMax < 0.05 && gemvCorrMin > 0.999,
                     detail: "samples=\(samples.count) elements=\(gemvCompared) "
                         + "maxAbs=\(gemvMax) minCorr=\(gemvCorrMin)"))

    let embedRef = try residentReadF32(golden.appendingPathComponent("sherry-embed-120000.f32"))
    let embedGot = try model.embedRow(tokenID: 120000)
    let embedMax = residentMaxAbs(embedGot, embedRef)
    out.append(check(suite: suite, "Q6_K embedding 行解码与独立 golden 对齐",
                     embedMax < 0.002,
                     detail: "elements=\(embedRef.count) maxAbs=\(embedMax)"))

    // ---- 32 层完整 forward 与离线 fp32 参考 golden 对齐 ----
    let prompt = [120000, 120006, 28036, 120007]
    let fwd = try await Task.detached(priority: .userInitiated) {
        () -> (logits: [Float], hidden: [Float], onMain: Bool, metrics: ForwardMetrics) in
        var logits: [Float] = []
        for (pos, tid) in prompt.enumerated() {
            logits = try model.forward(tokenID: tid, position: pos)
        }
        return (logits, model.readHidden(), pthread_main_np() != 0, model.lastMetrics)
    }.value

    out.append(check(suite: suite, "完整 forward 不在主线程执行", !fwd.onMain,
                     detail: "pthread_main_np=\(fwd.onMain)"))
    out.append(check(suite: suite, "每 token 225 次常驻 GEMV + 258 个 Metal 算子",
                     fwd.metrics.gemmCount == 225 && fwd.metrics.computeKernelCount == 258,
                     detail: "gemm=\(fwd.metrics.gemmCount) compute=\(fwd.metrics.computeKernelCount) "
                         + "gpu=\(String(format: "%.2f", fwd.metrics.gpuMs)) ms"))

    let refLogits = try residentReadF32(golden.appendingPathComponent("sherry-forward-logits.f32"))
    let corrL = residentCorr(fwd.logits, refLogits)
    let maxAbsL = residentMaxAbs(fwd.logits, refLogits)
    let fwdManifest = try residentReadJSON(golden.appendingPathComponent("sherry-forward-manifest.json"))
    let expectedArgmax = ((fwdManifest["logits"] as? [String: Any])?["argmax"] as? NSNumber)?.intValue ?? -1
    let gotArgmax = residentTopK(fwd.logits, 1).first ?? -1
    let gotTop20 = Set(residentTopK(fwd.logits, 20))
    let refTop20 = Set(residentTopK(refLogits, 20))
    let overlap = gotTop20.intersection(refTop20).count
    out.append(check(suite: suite, "32 层 logits 与 fp32 golden 对齐",
                     corrL > 0.999 && overlap >= 19 && gotArgmax == expectedArgmax,
                     detail: String(format: "corr=%.6f maxAbs=%.4f top20=%d/20 argmax=%d(expected %d)",
                                    corrL, maxAbsL, overlap, gotArgmax, expectedArgmax)))

    let layerRef = try residentReadF32(golden.appendingPathComponent("sherry-forward-layer-hidden.f32"))
    let lastLayer = Array(layerRef[(31 * 2048)..<(32 * 2048)])
    let corrH = residentCorr(fwd.hidden, lastLayer)
    out.append(check(suite: suite, "layer32 hidden 与 fp32 golden 对齐",
                     corrH > 0.99,
                     detail: String(format: "corr=%.6f maxAbs=%.4f",
                                    corrH, residentMaxAbs(fwd.hidden, lastLayer))))

    // ---- H1：batched prefill 必须与逐 token forward 数值等价（无损优化） ----
    let prefilled = try await Task.detached(priority: .userInitiated) {
        () -> (logits: [Float], metrics: ForwardMetrics) in
        let l = try model.prefill(ids: prompt)
        return (l, model.lastMetrics)
    }.value
    var prefMaxAbs = 0.0
    if prefilled.logits.count == fwd.logits.count {
        for i in 0..<fwd.logits.count {
            prefMaxAbs = max(prefMaxAbs, Double(abs(prefilled.logits[i] - fwd.logits[i])))
        }
    }
    out.append(check(suite: suite, "H1 batched prefill logits 与逐 token forward 逐元素相等",
                     prefilled.logits.count == fwd.logits.count && prefMaxAbs == 0,
                     detail: "n=\(prefilled.logits.count) maxAbs=\(prefMaxAbs) "
                         + "commandBuffers=\(prefilled.metrics.commandBuffers) (单 token forward=1)"))
    out.append(check(suite: suite, "默认 KV cache 为 fp16 64 MiB（int8 需显式开启）",
                     model.kvCacheMode == .fp16 && model.kvCacheBytes == 67_108_864,
                     detail: "mode=\(model.kvCacheMode) bytes=\(model.kvCacheBytes)"))

    // ---- H1：int8 KV cache 真实推理路径（有损，默认关闭，必须如实量化误差） ----
    do {
        let int8Model = try SherryResidentModel(
            modelDirectory: dir, maxSequenceLength: 1024, kvCacheMode: .int8)
        let int8Result = try await Task.detached(priority: .userInitiated) {
            () -> (logits: [Float], corr: Double, maxAbs: Float, overlap: Int, argmax: Int) in
            let l = try int8Model.prefill(ids: prompt)
            let corr = residentCorr(l, fwd.logits)
            let maxAbs = residentMaxAbs(l, fwd.logits)
            let overlap = Set(residentTopK(l, 20))
                .intersection(Set(residentTopK(fwd.logits, 20))).count
            let argmax = residentTopK(l, 1).first ?? -1
            return (l, corr, maxAbs, overlap, argmax)
        }.value
        out.append(check(suite: suite, "H1 int8 KV cache 模式生效且显存占用更小",
                         int8Model.kvCacheMode == .int8
                         && int8Model.kvCacheBytes < model.kvCacheBytes
                         && int8Result.logits.count == fwd.logits.count,
                         detail: "int8=\(int8Model.kvCacheBytes)B fp16=\(model.kvCacheBytes)B "
                             + "saved=\(model.kvCacheBytes - int8Model.kvCacheBytes)B"))
        out.append(check(suite: suite, "H1 int8 KV cache logits 与 fp16 高度一致（有损但有界）",
                         int8Result.corr > 0.999 && int8Result.overlap >= 19
                         && int8Result.argmax == gotArgmax,
                         detail: String(format: "corr=%.6f maxAbs=%.4f top20=%d/20 argmax=%d",
                                        int8Result.corr, int8Result.maxAbs,
                                        int8Result.overlap, int8Result.argmax)))
    } catch {
        out.append(check(suite: suite, "H1 int8 KV cache 真实推理路径", false,
                         detail: "threw: \(error)"))
    }

    // 结构化落盘（数值对齐数据，非性能口径）。
    let report: [String: Any] = [
        "stage": "G4 常驻 STQ1_0/Q6_K GEMV + 32 层 forward 数值对齐",
        "note": "独立 Python/PR golden；非模型推理性能，非 TTFT/token·s⁻¹",
        "resident_weight_bytes": model.residentWeightBytes,
        "gpu_buffer_bytes": model.gpuBufferBytes,
        "norm_buffer_bytes": model.normBufferBytes,
        "gemv_samples": samples.count,
        "gemv_elements": gemvCompared,
        "gemv_max_abs": gemvMax,
        "gemv_min_corr": gemvCorrMin,
        "embed_max_abs": embedMax,
        "forward_logits_corr": corrL,
        "forward_logits_max_abs": maxAbsL,
        "forward_top20_overlap": overlap,
        "forward_argmax": gotArgmax,
        "forward_expected_argmax": expectedArgmax,
        "layer32_hidden_corr": corrH,
        "gemm_per_token": fwd.metrics.gemmCount,
        "compute_kernels_per_token": fwd.metrics.computeKernelCount,
        "forward_gpu_ms": fwd.metrics.gpuMs,
    ]
    let reportDir = ProcessInfo.processInfo.environment["HYMN_REPORT_DIR"]
        ?? (FileManager.default.currentDirectoryPath + "/Reports")
    if let json = try? JSONSerialization.data(withJSONObject: report,
                                              options: [.prettyPrinted, .sortedKeys]) {
        try? json.write(to: URL(fileURLWithPath: reportDir)
            .appendingPathComponent("sherry-resident-golden.json"))
    }
    out.append(check(suite: suite, "数值对齐数据已落盘", true,
                     detail: "Reports/sherry-resident-golden.json"))
    return out
}
