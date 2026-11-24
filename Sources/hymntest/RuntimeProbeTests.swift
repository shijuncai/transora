import Foundation
import HymnSTQ

/// 上线自检套件：验证唯一后端运行所需资源齐备，且格式标注不造假。
/// 只读，不加载 440 MB 权重、不启动推理。
public func runtimeProbeSuite() -> [TestResult] {
    let suite = "runtime-probe"
    let s = SherryRuntimeProbe.status()
    var out: [TestResult] = []

    out.append(check(suite: suite, "运行时自检判定 READY", s.ready,
                     detail: s.summaryLines.joined(separator: " | ")))
    out.append(check(suite: suite, "GGUF v3 头与张量数正确",
                     s.ggufMagic == "GGUF" && s.ggufVersion == 3 && s.tensorCount == 354,
                     detail: "magic=\(s.ggufMagic ?? "-") version=\(s.ggufVersion ?? -1) tensors=\(s.tensorCount ?? -1)"))
    out.append(check(suite: suite, "config.json / tokenizer.json 齐备",
                     s.configPresent && s.tokenizerPresent,
                     detail: "config=\(s.configPresent) tokenizer=\(s.tokenizerPresent)"))
    out.append(check(suite: suite, "Metal 设备可用", s.metalDevice != nil,
                     detail: s.metalDevice ?? "none"))
    out.append(check(suite: suite, "GGUF 文件大小与官方一致（461,860,800 B）",
                     s.ggufBytes == 461_860_800,
                     detail: "\(s.ggufBytes ?? -1) B"))
    out.append(check(suite: suite, "权重格式如实标注 STQ1_0，不冒充 LUT4 / affine INT4",
                     s.weightFormat.contains("STQ1_0")
                        && s.weightFormat.contains("1.3125 bpw")
                        && s.weightFormat.contains("NOT LUT4")
                        && s.weightFormat.contains("NOT affine INT4"),
                     detail: s.weightFormat))
    out.append(check(suite: suite, "运行时声明全程离线", s.offlineOnly,
                     detail: "offlineOnly=\(s.offlineOnly)"))
    return out
}
