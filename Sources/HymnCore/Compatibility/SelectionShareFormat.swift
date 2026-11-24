import Foundation

/// 把划词结果整理成「备忘录 / 提醒事项」需要的文本形态（纯计算，便于独立测试）。
///
/// 两处都只需要「单行标题 + 保留换行的正文」：备忘录走文件导入（首行即标题），
/// 提醒事项走 EventKit（`title` / `notes` 分开传）。
public enum SelectionShareFormat {
    /// 提醒事项正文（纯文本）。
    public static func plainBody(source: String, translation: String, pair: String) -> String {
        "原文（\(pair)）\n\(source)\n\n译文\n\(translation)"
    }

    /// 标题：取译文首行，超长截断并加省略号（备忘录标题与提醒名称都是单行展示）。
    public static func title(from translation: String, limit: Int) -> String {
        let line = translation
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = line.isEmpty ? fallback : line
        guard limit > 0 else { return base }
        return base.count > limit ? String(base.prefix(limit)) + "…" : base
    }
}
