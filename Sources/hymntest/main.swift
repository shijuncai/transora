import Foundation
import Darwin
import HymnCore
import HymnStore
import HymnSTQ

@main
struct HymnTestMain {
    static func reportDir() -> String {
        if let d = ProcessInfo.processInfo.environment["HYMN_REPORT_DIR"] { return d }
        return FileManager.default.currentDirectoryPath + "/Reports"
    }

    static func stage(_ name: String) {
        print("# STAGE \(name)")
        fflush(stdout)
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        var all: [TestResult] = []
        // 单后端产品版：D-1（native-weights / weight-cache / metal-ops / forward /
        // real-backend）与 MLX（mlx-backend）、三选一偏好（backend-preference）、
        // 4bit 兼容性探测（compatibility）套件随后端一并退役，不再注册。
        stage("runtime-probe");   all += runtimeProbeSuite()
        stage("language-catalog"); all += languageCatalogSuite()
        stage("selection-popup-layout"); all += selectionPopupLayoutSuite()
        stage("selection-language");  all += selectionLanguageSuite()
        stage("selection-capture-policy"); all += selectionCapturePolicySuite()
        stage("selection-share");  all += selectionShareFormatSuite()
        stage("selection-actions"); all += selectionActionSuite()
        stage("pdf-chart");       all += pdfChartSuite()
        stage("pdf-region");      all += pdfRegionSuite()
        stage("pdf-ruled-table"); all += pdfRuledTableSuite()
        stage("pdf-reflow");      all += pdfReflowSuite()
        stage("document-export"); all += documentWriterSuite()
        stage("text-chunker"); all += textChunkerSuite()
        stage("pdf-object");  all += pdfObjectSuite()
        stage("pdf-p1");      all += pdfP1Suite()
        stage("pdf-p2");      all += pdfP2Suite()
        stage("pdf-p3");      all += pdfP3Suite()
        stage("pdf-p4");      all += pdfP4Suite()
        stage("pdf-p5");      all += pdfP5Suite()
        stage("pdf-p6");      all += pdfP6Suite()
        stage("gguf-reader");     all += try ggufReaderSuite()
        stage("tokenizer");       all += try tokenizerSuite()
        stage("streaming-decode"); all += try streamingDecodeSuite()
        stage("sherry-resident"); all += try await sherryResidentSuite()
        stage("sherry-backend");  all += try await sherryBackendSuite()
        stage("sampler-determinism"); all += try await samplerDeterminismSuite()
        stage("scheduler");       all += await schedulerSuite()
        stage("engine");          all += try await engineSuite()
        stage("store");           all += try storeSuite()
        stage("glossary");        all += try glossarySuite()
        stage("thread-isolation"); all += try await threadIsolationSuite()
        stage("performance")

        // TAP 输出
        print("TAP version 13")
        print("1..\(all.count)")
        for (i, r) in all.enumerated() {
            let mark = r.passed ? "ok" : "not ok"
            print("\(mark) \(i + 1) - [\(r.suite)] \(r.name)"
                  + (r.detail.isEmpty ? "" : "  # \(r.detail)"))
        }
        let passed = all.filter(\.passed).count
        let failed = all.count - passed
        print("# pass \(passed)  fail \(failed)  total \(all.count)")

        // Markdown 测试报告
        let dir = reportDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var md = "# HymnTranslate 测试报告（单后端产品版）\n\n"
        md += "生成时间: \(ISO8601DateFormatter().string(from: Date()))\n\n"
        md += "**结果: \(passed)/\(all.count) 通过, \(failed) 失败**\n\n"
        md += "唯一推理后端：`SherryBackend`（STQ1_0 1.3125 bpw 常驻 GEMV，"
        md += "NOT LUT4 / NOT affine INT4）。D-1 与 MLX Swift 后端已退役。\n\n"
        let suites = Dictionary(grouping: all, by: \.suite)
        for suite in suites.keys.sorted() {
            let items = suites[suite] ?? []
            md += "## \(suite) (\(items.filter(\.passed).count)/\(items.count))\n\n"
            md += "| 结果 | 用例 | 详情 |\n|---|---|---|\n"
            for item in items {
                md += "| \(item.passed ? "PASS" : "FAIL") | \(item.name) | \(item.detail.replacingOccurrences(of: "|", with: "\\|")) |\n"
            }
            md += "\n"
        }
        md += "\n> 说明：`scheduler` / `engine` / `thread-isolation` / `performance` 各组仍使用 "
        md += "`ProbeBackend` / `FixtureBackend` 测试替身验证调度、批量、取消与主线程响应性，不产生译文；"
        md += "`runtime-probe` 只读校验上线所需资源与格式标注；"
        md += "`sherry-resident` 用常驻 STQ1_0/Q6_K Metal GEMV 与独立 Python golden 做字节级解码、"
        md += "32 层 forward 数值对齐；`sherry-backend` 为端到端真实译文与性能；"
        md += "`sampler-determinism` 验证请求级可复现（每请求按 seed 重建采样器，"
        md += "同一请求跨其他请求复跑译文逐字一致）；`streaming-decode` 实证并修复"
        md += "复杂脚本流式译文的 U+FFFD 残留与字符重复；`selection-popup-layout` "
        md += "验证划词浮窗尺寸随划词量自适应、屏幕上限与视图/面板尺寸恒等式；"
        md += "`selection-language` 实证划词请求不再复用主窗口语言对造成「中译中」原样照抄，"
        md += "并覆盖 49 组文本×语言对组合均不自译；"
        md += "`selection-capture-policy` 验证选区双读稳定、旧请求/切应用结果作废、"
        md += "剪贴板假阳性过滤（修复浮窗显示旧窗口词或半截选区）；"
        md += "`selection-actions` 验证浮窗底排按钮可配置的清单约束（最多 7 个、至少 1 个、去重、"
        md += "按声明顺序归一）、偏好序列化往返，以及网页动作 URL 编码"
        md += "（中文与 `&` `=` `#` 不被截断）；"
        md += "`document-export` 验证零依赖 DOCX(OOXML/ZIP store/CRC32) 与 TXT 写出、"
        md += "XML 转义、确定性及 14 语言目录；`text-chunker` 验证 PDF 按页分块、"
        md += "长段落硬切、空白页跳过与几百页规模。\n"
        try md.write(toFile: dir + "/test-report.md", atomically: true, encoding: .utf8)

        // 性能基准
        let report = try await performanceBench()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        try json.write(to: URL(fileURLWithPath: dir + "/perf.json"))
        print("# perf -> \(dir)/perf.json")
        for key in report.metrics.keys.sorted() {
            print(String(format: "#   %-40s %.4f", (key as NSString).utf8String!, report.metrics[key] ?? 0))
        }
        print("# report -> \(dir)/test-report.md")
        exit(failed == 0 ? 0 : 1)
    }
}
