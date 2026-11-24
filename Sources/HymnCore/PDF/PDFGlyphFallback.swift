import Foundation

/// 字体缺字时的 ASCII 替身。
///
/// 只处理**带语义**的上下标。实测事故：模型把 `m³` 译成 `米³`、把 `H2O` 写成 `H₂O`，
/// 而思源宋体没有 `₂`（U+2082）——这个字被直接丢掉，"H₂O" 印出来是 "H O"，
/// 化学式就错了。换成 ASCII 数字 `H2O` 语义无损，字也画得出来。
///
/// **装饰符号不在表内**（`⇑`、`✓`、`★` 之类）：换成别的字符反而可能误导，
/// 让缺字报告如实显示更好——它是缺陷，不该被悄悄糊过去。
public enum PDFGlyphFallback {
    public static let substitutions: [UInt32: String] = [
        // 下标数字
        0x2080: "0", 0x2081: "1", 0x2082: "2", 0x2083: "3", 0x2084: "4",
        0x2085: "5", 0x2086: "6", 0x2087: "7", 0x2088: "8", 0x2089: "9",
        // 上标数字（含 ¹²³ 这三个拉丁补充区里的老码位）
        0x2070: "0", 0x00B9: "1", 0x00B2: "2", 0x00B3: "3",
        0x2074: "4", 0x2075: "5", 0x2076: "6", 0x2077: "7", 0x2078: "8", 0x2079: "9",
        // 上下标的正负号
        0x207A: "+", 0x207B: "-", 0x208A: "+", 0x208B: "-",
        // 下标字母里最常见的一个（`log₂`、`CO₂` 之外的 `ₓ`）
        0x2093: "x",

        // 带变音符的拉丁字母 → 基本字母。
        //
        // 内置宋体（思源宋体实例化）只收了拉丁-1 与拼音用到的组合，
        // 参考文献里的土耳其/北欧/东欧人名就会缺字：实测
        // `E. Çulcuoğlu, E. Ünay, F. Karaosmanoğlu` 里的 ğ（U+011F）画不出来，
        // 名字直接少一个字母。去掉变音符写成 "Culcuoglu" 语义仍然可辨，
        // 比丢一个字好；字体真有这个字形时（下表只在缺字时生效）不会被动到。
        0x011E: "G", 0x011F: "g",   // Ğ ğ
        0x015E: "S", 0x015F: "s",   // Ş ş
        0x0130: "I", 0x0131: "i",   // İ ı（土耳其语带点/无点 i）
        0x0160: "S", 0x0161: "s",   // Š š
        0x017D: "Z", 0x017E: "z",   // Ž ž
        0x010C: "C", 0x010D: "c",   // Č č
        0x0158: "R", 0x0159: "r",   // Ř ř
        0x0141: "L", 0x0142: "l",   // Ł ł
        0x0110: "D", 0x0111: "d",   // Đ đ
        0x00D8: "O", 0x00F8: "o",   // Ø ø
        0x00C6: "AE", 0x00E6: "ae", // Æ æ
        0x0152: "OE", 0x0153: "oe", // Œ œ
        0x00DF: "ss",               // ß
        0x0104: "A", 0x0105: "a",   // Ą ą
        0x0118: "E", 0x0119: "e",   // Ę ę
        0x0102: "A", 0x0103: "a",   // Ă ă
    ]

    /// 只替换**字体确实画不出**且表里有替身的字符，其余原样保留。
    public static func apply(_ text: String, missing: [UInt32]) -> String {
        guard !missing.isEmpty else { return text }
        let set = Set(missing)
        guard missing.contains(where: { substitutions[$0] != nil }) else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if set.contains(scalar.value), let replacement = substitutions[scalar.value] {
                out += replacement
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
