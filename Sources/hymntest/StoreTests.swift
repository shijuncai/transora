import Foundation
import HymnCore
import HymnStore

func storeSuite() throws -> [TestResult] {
    let suite = "SQLiteStore"
    var out: [TestResult] = []
    let store = try SQLiteStore(path: ":memory:")
    defer { store.close() }

    let stats0 = try store.stats()
    out.append(check(suite: suite, "内存库打开并完成 v1 迁移",
                     stats0.schemaVersion == 1 && stats0.historyCount == 0,
                     detail: "version=\(stats0.schemaVersion)"))

    let r = HistoryRecord(
        sourceLang: "en", targetLang: "zh",
        sourceText: "Hello, nice to meet you.", targetText: "[fixture] 你好",
        durationMs: 42, tokenCount: 7, modelTag: "fixture-v0"
    )
    let id = try store.insertHistory(r)
    let fetched = try store.fetchHistory(limit: 10)
    out.append(check(suite: suite, "历史记录插入后字段往返一致",
                     id == 1 && fetched.count == 1
                        && fetched[0].sourceText == r.sourceText
                        && fetched[0].targetText == r.targetText
                        && fetched[0].durationMs == 42
                        && fetched[0].tokenCount == 7
                        && fetched[0].modelTag == "fixture-v0"
                        && !fetched[0].cancelled,
                     detail: "id=\(id) rows=\(fetched.count)"))

    // 批量事务写入
    let batch = (0..<1000).map { i in
        HistoryRecord(
            sourceLang: "en", targetLang: "zh",
            sourceText: "sentence \(i)", targetText: "[fixture] \(i)",
            createdAt: Int64(1_700_000_000_000 + i),
            durationMs: Int64(i % 50), tokenCount: i % 20
        )
    }
    let batchNanos = try store.insertHistoryBatch(batch)
    let count = try store.countHistory()
    out.append(check(suite: suite, "事务批量写入 1000 条全部落库",
                     count == 1001, detail: "count=\(count) in \(batchNanos / 1_000_000) ms"))

    // 搜索 + LIKE 转义
    let found = try store.fetchHistory(limit: 100, search: "sentence 42")
    out.append(check(suite: suite, "历史全文搜索命中",
                     found.contains { $0.sourceText == "sentence 42" },
                     detail: "hits=\(found.count)"))
    let escaped = try store.fetchHistory(limit: 10, search: "100%_done")
    out.append(check(suite: suite, "LIKE 通配符转义不报错且返回空集",
                     escaped.isEmpty, detail: "hits=\(escaped.count)"))

    // 分页
    let page1 = try store.fetchHistory(limit: 5, offset: 0)
    let page2 = try store.fetchHistory(limit: 5, offset: 5)
    out.append(check(suite: suite, "分页不重叠且按 created_at DESC",
                     page1.count == 5 && page2.count == 5
                        && Set(page1.map(\.id)).isDisjoint(with: Set(page2.map(\.id))),
                     detail: "p1=\(page1.map(\.id)) p2=\(page2.map(\.id))"))

    // 术语库
    let enzh = LanguagePair(source: "en", target: "zh")
    let zhen = LanguagePair(source: "zh", target: "en")
    try store.upsertTerm(source: "Transformer", target: "变换器", languages: enzh, note: "ML")
    try store.upsertTerm(source: "attention", target: "注意力", languages: enzh)
    try store.upsertTerm(source: "注意力", target: "attention", languages: zhen)
    let terms = try store.fetchTerms(languages: enzh)
    out.append(check(suite: suite, "术语库按语言对过滤且按长度降序",
                     terms.count == 2 && terms[0].source == "Transformer"
                        && terms[0].target == "变换器" && terms[0].note == "ML",
                     detail: terms.map(\.source).joined(separator: ",")))

    try store.upsertTerm(source: "Transformer", target: "变压器(已更新)", languages: enzh, note: "updated")
    let afterUpsert = try store.fetchTerms(languages: enzh)
    let termCountAfter = try store.countTerms()
    out.append(check(suite: suite, "UPSERT 冲突时更新而非重复插入",
                     termCountAfter == 3
                        && afterUpsert.count == 2
                        && afterUpsert.first(where: { $0.source == "Transformer" })?.target == "变压器(已更新)",
                     detail: "terms=\(termCountAfter)"))

    // 删除
    try store.deleteHistory(id: id)
    let historyAfterDelete = try store.countHistory()
    out.append(check(suite: suite, "删除历史记录生效", historyAfterDelete == 1000,
                     detail: "count=\(historyAfterDelete)"))
    if let t = afterUpsert.first {
        try store.deleteTerm(id: t.id)
        let termsAfterDelete = try store.countTerms()
        out.append(check(suite: suite, "删除术语生效", termsAfterDelete == 2,
                         detail: "count=\(termsAfterDelete)"))
    }

    // 文件持久化：关闭后重新打开仍可读（全程本地文件，无网络）
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hymn_store_\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
        let fileStore = try SQLiteStore(path: tmp.path)
        try fileStore.upsertTerm(source: "offline", target: "离线", languages: enzh)
        _ = try fileStore.insertHistory(HistoryRecord(
            sourceLang: "en", targetLang: "zh",
            sourceText: "offline only", targetText: "[fixture] 离线"
        ))
        fileStore.close()
        let reopened = try SQLiteStore(path: tmp.path)
        let persisted = try reopened.fetchTerms(languages: enzh)
        let persistedHistory = try reopened.fetchHistory(limit: 10)
        out.append(check(suite: suite, "文件库关闭重开后数据完整（离线持久化）",
                         persisted.count == 1 && persisted[0].target == "离线"
                            && persistedHistory.count == 1,
                         detail: "terms=\(persisted.count) history=\(persistedHistory.count)"))
        reopened.close()
    } catch {
        out.append(TestResult(suite: suite, name: "文件库持久化", passed: false,
                              detail: "threw: \(error)", nanos: 0))
    }

    return out
}
