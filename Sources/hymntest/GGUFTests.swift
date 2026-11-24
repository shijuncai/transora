import Foundation
import Darwin
import HymnSTQ

// G1 / G2 / G3 / G4(CPU 参考)：GGUF 读取器与反量化算子的独立测试套件。
// golden 由 Scripts/gen-gguf-golden.py 用**独立 Python 实现**生成，
// 两者共同对照 llama.cpp PR #22836 / ggml-quants.c 的权威公式。

private func ggufModelURL() -> URL {
    if let p = ProcessInfo.processInfo.environment["HYMN_GGUF_MODEL"] {
        return URL(fileURLWithPath: p)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Models/Hy-MT2-1.8B-1.25Bit-GGUF/Hy-MT2-1.8B-1.25Bit.gguf")
}

private func ggufGoldenDir() -> URL {
    if let d = ProcessInfo.processInfo.environment["HYMN_GOLDEN_DIR"] {
        return URL(fileURLWithPath: d)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Golden")
}

private func ggufReadF32(_ url: URL) throws -> [Float] {
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

private func ggufReadJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw GGUFError.misaligned("manifest 不是 JSON object")
    }
    return obj
}

public func ggufReaderSuite() throws -> [TestResult] {
    let suite = "gguf-reader"
    var out: [TestResult] = []
    let url = ggufModelURL()
    let exists = FileManager.default.fileExists(atPath: url.path)

    out.append(check(suite: suite, "1.25bit GGUF 全量权重已落盘",
                     exists, detail: url.path))
    guard exists else { return out }

    let file = try GGUFFile(url: url)
    let golden = try ggufReadJSON(ggufGoldenDir().appendingPathComponent("gguf-golden-manifest.json"))

    out.append(check(suite: suite, "GGUF v3 / 354 张量 / 34 metadata",
                     file.version == 3 && file.tensors.count == 354 && file.metadata.count == 34,
                     detail: "version=\(file.version) tensors=\(file.tensors.count) kv=\(file.metadata.count)"))

    let hist = file.typeHistogram()
    out.append(check(suite: suite, "张量类型分布 224 STQ1_0 + 129 F32 + 1 Q6_K",
                     hist[42] == 224 && hist[0] == 129 && hist[14] == 1,
                     detail: "\(hist.map { "\($0.key):\($0.value)" }.sorted().joined(separator: " "))"))

    let arch = file.metadataString("general.architecture") ?? ""
    let blocks = file.metadataUInt("hunyuan-dense.block_count") ?? 0
    let heads = file.metadataUInt("hunyuan-dense.attention.head_count") ?? 0
    let kvHeads = file.metadataUInt("hunyuan-dense.attention.head_count_kv") ?? 0
    let rope = file.metadata["hunyuan-dense.rope.freq_base"]?.doubleValue ?? 0
    let temp = file.metadata["general.sampling.temp"]?.doubleValue ?? 0
    let bos = file.metadataUInt("tokenizer.ggml.bos_token_id") ?? 0
    let eos = file.metadataUInt("tokenizer.ggml.eos_token_id") ?? 0
    out.append(check(suite: suite, "架构/采样 metadata 与现有模型一致",
                     arch == "hunyuan-dense" && blocks == 32 && heads == 16 && kvHeads == 4
                     && abs(rope - 11158840.0) < 1 && abs(temp - 0.7) < 0.001
                     && bos == 120000 && eos == 120020,
                     detail: "arch=\(arch) L=\(blocks) Q=\(heads) KV=\(kvHeads) rope=\(rope) temp=\(temp)"))

    let expectedDataStart = (golden["data_start"] as? NSNumber)?.intValue ?? 0
    out.append(check(suite: suite, "data 区起点按 32 字节对齐且与 golden 一致",
                     file.dataStart % 32 == 0 && file.dataStart == expectedDataStart,
                     detail: "headerEnd=\(file.headerEnd) dataStart=\(file.dataStart) golden=\(expectedDataStart)"))

    let emb = file.tensor(named: "token_embd.weight")
    let tied = file.tensor(named: "output.weight") == nil && file.tensor(named: "output_norm.weight") != nil
    out.append(check(suite: suite, "tied embedding：token_embd [2048,120818] 且无 output.weight",
                     emb?.dimensions == [2048, 120818] && emb?.type == 14 && tied,
                     detail: "dims=\(emb?.dimensions ?? []) type=\(emb?.type ?? 0) tied=\(tied)"))

    var missing: [String] = []
    for layer in 0..<32 {
        for key in ["attn_q", "attn_k", "attn_v", "attn_output", "ffn_gate", "ffn_up", "ffn_down"] {
            let n = "blk.\(layer).\(key).weight"
            if file.tensor(named: n)?.type != 42 { missing.append(n) }
        }
        for key in ["attn_q_norm", "attn_k_norm", "attn_norm", "ffn_norm"] {
            let n = "blk.\(layer).\(key).weight"
            if file.tensor(named: n)?.type != 0 { missing.append(n) }
        }
    }
    out.append(check(suite: suite, "32 层 × 7 线性层 + 4 norm 张量齐全且类型正确",
                     missing.isEmpty, detail: "missing=\(missing.count) \(missing.prefix(3).joined(separator: ","))"))

    // F32 norm 可以直接按位读取，做一次健全性检查（RMSNorm 权重应有限且非零）。
    var normOK = false
    var normDetail = "unreadable"
    if let info = file.tensor(named: "output_norm.weight") {
        let vals = try file.withBytes(for: "output_norm.weight") { raw in
            try GGUF_F32.read(raw, count: info.elementCount)
        }
        normOK = vals.allSatisfy { $0.isFinite } && vals.filter({ abs($0) > 0.01 }).count > 1000
        normDetail = "count=\(vals.count) first=\(vals.prefix(4).map { String(format: "%.4f", $0) }.joined(separator: ","))"
    }
    out.append(check(suite: suite, "F32 output_norm 可直接读取且数值合理",
                     normOK, detail: normDetail))

    // ---- 与独立 Python golden 逐元素比对 ----
    let samples = golden["samples"] as? [[String: Any]] ?? []
    var stqMaxAbs: Float = 0
    var stqMismatch = 0
    var stqElements = 0
    var q6MaxAbs: Float = 0
    var q6Mismatch = 0
    var q6Elements = 0
    let start = DispatchTime.now().uptimeNanoseconds

    for sample in samples {
        guard let name = sample["tensor"] as? String,
              let blocksCount = (sample["blocks"] as? NSNumber)?.intValue,
              let fileName = sample["file"] as? String,
              let type = (sample["type"] as? NSNumber)?.uint32Value else { continue }
        let bytes = blocksCount * (type == 42 ? STQ1_0.blockBytes : Q6_K.blockBytes)
        let decoded: [Float] = try file.withBytes(for: name) { raw in
            let slice = UnsafeRawBufferPointer(start: raw.baseAddress, count: bytes)
            return type == 42
                ? try STQ1_0.dequantize(slice, blocks: blocksCount)
                : try Q6_K.dequantize(slice, blocks: blocksCount)
        }
        let reference = try ggufReadF32(ggufGoldenDir().appendingPathComponent(fileName))
        let n = min(decoded.count, reference.count)
        var localMax: Float = 0
        var localBad = 0
        for i in 0..<n {
            let diff = abs(decoded[i] - reference[i])
            if diff > localMax { localMax = diff }
            if diff != 0 { localBad += 1 }
        }
        if type == 42 {
            stqMaxAbs = max(stqMaxAbs, localMax); stqMismatch += localBad; stqElements += n
        } else {
            q6MaxAbs = max(q6MaxAbs, localMax); q6Mismatch += localBad; q6Elements += n
        }
    }
    let decodeNanos = DispatchTime.now().uptimeNanoseconds - start

    out.append(check(suite: suite, "STQ1_0 解码与独立 Python/PR 参考逐元素零误差",
                     stqElements > 0 && stqMismatch == 0,
                     detail: "elements=\(stqElements) mismatch=\(stqMismatch) maxAbs=\(stqMaxAbs)"))
    out.append(check(suite: suite, "Q6_K 解码与独立 Python/ggml 参考逐元素零误差",
                     q6Elements > 0 && q6Mismatch == 0,
                     detail: "elements=\(q6Elements) mismatch=\(q6Mismatch) maxAbs=\(q6MaxAbs)"))

    let sha = (golden["sha256"] as? String) ?? ""
    out.append(check(suite: suite, "golden manifest 记录官方 SHA256",
                     sha == "cc497fe8f033b52b3b8b00a7669e9661435432f9d4cd43f7ed24400c01507a93",
                     detail: sha))

    // 性能：仅算子解码吞吐，**不是模型推理**（不产出译文、不跑 forward）。
    let totalElements = stqElements + q6Elements
    let seconds = Double(decodeNanos) / 1_000_000_000
    let throughput = seconds > 0 ? Double(totalElements) / seconds : 0
    let report: [String: Any] = [
        "stage": "G1 / GGUF reader + STQ1_0 + Q6_K CPU 参考解码",
        "note": "反量化算子吞吐，非模型推理、非 TTFT、非 token/s",
        "gguf_bytes": file.fileSize,
        "header_end": file.headerEnd,
        "data_start": file.dataStart,
        "tensor_count": file.tensors.count,
        "stq1_0_elements_compared": stqElements,
        "q6_k_elements_compared": q6Elements,
        "decode_ms": Double(decodeNanos) / 1_000_000.0,
        "decode_elements_per_second": throughput,
        "stq1_0_max_abs_diff": stqMaxAbs,
        "q6_k_max_abs_diff": q6MaxAbs,
    ]
    let reportDir = ProcessInfo.processInfo.environment["HYMN_REPORT_DIR"]
        ?? (FileManager.default.currentDirectoryPath + "/Reports")
    if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? json.write(to: URL(fileURLWithPath: reportDir).appendingPathComponent("gguf-perf.json"))
    }
    out.append(check(suite: suite, "算子解码性能数据已落盘（非推理口径）",
                     throughput > 0, detail: "\(Int(throughput)) elements/s, \(String(format: "%.2f", Double(decodeNanos) / 1_000_000.0)) ms"))

    return out
}
