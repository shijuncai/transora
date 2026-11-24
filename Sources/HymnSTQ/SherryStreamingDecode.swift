import Foundation

// 流式译文增量解码（修复 1260 全方向评测暴露的字符级损坏）。
//
// 背景：HymnTokenizer.decode 把 accumulated byte-level BPE 字节一次性交给
// String(decoding: as: UTF8.self)。逐 token 解码时，若最后一个多字节字符
// 尚未收齐，尾部会出现 U+FFFD（替换字符）；下一个 token 补齐后，该 U+FFFD
// 会变成一个真实字符，**前缀不稳定**。
//
// 旧的 delta 用 Array(String) = [Character]（grapheme cluster）比较前缀：
//   · 天城文/高棉文等组合字符会与后随符号合并成新的 grapheme，使前缀进一步失配；
//   · 于是同一段文本被重复 yield，且先前 yield 的 U+FFFD 无法撤回，
//     拼接后出现「替换字符 + 相邻字符重复」（例如 「ཚཚ」「वव」「कक」）。
//
// 修复：按 **Unicode scalar 计数**做增量，并且只发送「不含尾部未完成多字节字符」
// 的稳定前缀（屏蔽尾部连续 U+FFFD）。U+FFFD 永不进入流，
// scalars 序列是稳定单调增长的，因此既不会残留替换字符，也不会重复输出。
//
// 这是纯字符串层修复，不改变任何模型算子、权重或采样逻辑。

public struct StreamingTextDecoder: Sendable {
    private var sentScalarCount: Int = 0

    public init() {}

    /// 输入：到目前为止全部 token 一次性 decode 的结果。
    /// 输出：本次应该追加到流式译文的增量片段（可能为空）。
    public mutating func delta(fullDecoded: String) -> String {
        let scalars = Array(fullDecoded.unicodeScalars)
        // 只截掉「尾部」连续的 U+FFFD：它们代表尚未收齐的多字节字符。
        // 中间出现的 U+FFFD 是模型真实产出的无效字节，保留并如实输出。
        var stable = scalars.count
        while stable > 0 && scalars[stable - 1] == "\u{FFFD}" { stable -= 1 }
        guard stable > sentScalarCount else { return "" }
        let start = sentScalarCount
        sentScalarCount = stable
        var out = ""
        out.unicodeScalars.append(contentsOf: scalars[start..<stable])
        return out
    }

    /// 生成结束时的冲刷：把仍被屏蔽的尾部 U+FFFD 对应的内容收尾。
    /// 正常情况下模型以 EOS 结束且字节已收齐，返回空串；
    /// 若被 maxTokens 截断导致尾部确有未完成字节，返回单个替换字符如实标注截断。
    public mutating func finish(fullDecoded: String) -> String {
        let tail = delta(fullDecoded: fullDecoded)
        let scalars = Array(fullDecoded.unicodeScalars)
        let replacement = Unicode.Scalar(0xFFFD)!
        let hasPendingReplacement = scalars.count > sentScalarCount
            && scalars[sentScalarCount...].contains(replacement)
        return tail + (hasPendingReplacement ? "\u{FFFD}" : "")
    }

    /// 仅用于测试/诊断：复现修复前的旧逻辑（grapheme 前缀差）。
    /// 不要在产品路径使用。
    public static func legacyDelta(from old: String, to new: String) -> String {
        let a = Array(old), b = Array(new)
        var i = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        return String(b[i...])
    }
}
