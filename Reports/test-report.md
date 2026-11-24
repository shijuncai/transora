# HymnTranslate 测试报告（单后端产品版）

生成时间: 2026-11-24T14:40:59Z

**结果: 493/493 通过, 0 失败**

唯一推理后端：`SherryBackend`（STQ1_0 1.3125 bpw 常驻 GEMV，NOT LUT4 / NOT affine INT4）。D-1 与 MLX Swift 后端已退役。

## Engine (11/11)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 后端如实声明「非真实模型推理」 | probe-v0 (TEST DOUBLE / NOT MODEL INFERENCE) |
| PASS | 流式输出 8 个 token + 1 个 final 标记 | chunks=9 |
| PASS | token 序号严格递增且属于同一请求 |  |
| PASS | 一次性翻译聚合文本与 token 数 | tokens=8 firstTokenNs=1601375 |
| PASS | 任务取消：wasCancelled=true 且提前停止 | tokens=7/200 |
| PASS | 取消响应延迟 < 100 ms | 28.55 ms |
| PASS | 12 个并发请求全部完成 | 12/12 |
| PASS | 单模型实例：后端并发峰值恒为 1 | peak=1 |
| PASS | 所有推理 token 均不在主线程产出 | main=0 total=48 |
| PASS | 引擎快照 maxConcurrency=1 且 completed=12 | completed=12 |
| PASS | 批量整体取消：无请求完整跑完 400 token | CANCELLED,CANCELLED,CANCELLED,CANCELLED,CANCELLED,CANCELLED |

## Glossary (8/8)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 最长匹配优先：attention layer 排在 attention 前 | attention layer > Transformer > attention |
| PASS | 大小写不敏感匹配 |  |
| PASS | 语言对过滤：只返回 en->zh | hits=3 |
| PASS | 去重：同一源术语只出现一次 | ["attention layer", "Transformer", "attention"] |
| PASS | prompt 含显式方向指令 |  |
| PASS | prompt 注入命中术语约束 | 将下面的英文翻译成中文。只输出中文译文，不要输出其它语言，不要解释。
术语约束："attention layer"→"注意力层"；"attention"→"注意力"。

The attention layer is fast. |
| PASS | prompt 以原文结尾 |  |
| PASS | 无命中时返回空且不附加约束 |  |

## MainThreadIsolation (5/5)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 主线程 tick 正常打点（>=20 次） | ticks=44 |
| PASS | 推理负载期间主线程最大 tick 间隔 < 100 ms | max=12.02 ms avg=10.01 ms |
| PASS | 后台 12 条负载全部完成 |  |
| PASS | 推理 token 全部来自非主线程 | main=0 total=360 |
| PASS | 后端并发峰值恒为 1 | peak=1 |

## SQLiteStore (11/11)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 内存库打开并完成 v1 迁移 | version=1 |
| PASS | 历史记录插入后字段往返一致 | id=1 rows=1 |
| PASS | 事务批量写入 1000 条全部落库 | count=1001 in 8 ms |
| PASS | 历史全文搜索命中 | hits=11 |
| PASS | LIKE 通配符转义不报错且返回空集 | hits=0 |
| PASS | 分页不重叠且按 created_at DESC | p1=[1, 1001, 1000, 999, 998] p2=[997, 996, 995, 994, 993] |
| PASS | 术语库按语言对过滤且按长度降序 | Transformer,attention |
| PASS | UPSERT 冲突时更新而非重复插入 | terms=3 |
| PASS | 删除历史记录生效 | count=1000 |
| PASS | 删除术语生效 | count=2 |
| PASS | 文件库关闭重开后数据完整（离线持久化） | terms=1 history=1 |

## Scheduler (6/6)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 首个请求立即获得模型使用权 |  |
| PASS | 快照 running == 首个请求 |  |
| PASS | 两个请求进入队列且并发度保持 1 | queued=2 |
| PASS | 高优先级请求优先获得模型 | runningAfterA=Optional(6FE39670-E70F-45E2-88CB-E951BFBE172F) low=true high=true |
| PASS | 排队中的请求被取消后 acquire 返回 false | gotY=false queued=0 |
| PASS | completed 计数与释放次数一致 | 3 |

## document-export (11/11)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | TXT 含标题、原文、译文与多记录顺序 | bytes=362 |
| PASS | CRC32 通过标准校验向量 123456789 |  |
| PASS | DOCX 是完整 ZIP（EOCD + 4 个 OOXML 部件） | parts=4 names=[Content_Types].xml,_rels/.rels,word/_rels/document.xml.rels,word/document.xml |
| PASS | ZIP 每个部件的 CRC 与实际数据一致 |  |
| PASS | document.xml 转义 XML 特殊字符并保留中文/emoji |  |
| PASS | document.xml 声明 OOXML 命名空间与正文结构 |  |
| PASS | 非法控制字符被剔除 |  |
| PASS | 同一文档两次生成字节完全一致（确定性） |  |
| PASS | 空记录文档仍生成合法 DOCX |  |
| PASS | UI 语言目录恰为 14 种且含简体中文 | zh,en,ja,ko,fr,de,es,pt,ru,it,ar,th,vi,id |
| PASS | 14 种均在模型卡 36 种之中，底层目录未缩水 |  |

## gguf-reader (12/12)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 1.25bit GGUF 全量权重已落盘 | /Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate/Models/Hy-MT2-1.8B-1.25Bit-GGUF/Hy-MT2-1.8B-1.25Bit.gguf |
| PASS | GGUF v3 / 354 张量 / 34 metadata | version=3 tensors=354 kv=34 |
| PASS | 张量类型分布 224 STQ1_0 + 129 F32 + 1 Q6_K | 0:129 14:1 42:224 |
| PASS | 架构/采样 metadata 与现有模型一致 | arch=hunyuan-dense L=32 Q=16 KV=4 rope=11158840.0 temp=0.699999988079071 |
| PASS | data 区起点按 32 字节对齐且与 golden 一致 | headerEnd=5090196 dataStart=5090208 golden=5090208 |
| PASS | tied embedding：token_embd [2048,120818] 且无 output.weight | dims=[2048, 120818] type=14 tied=true |
| PASS | 32 层 × 7 线性层 + 4 norm 张量齐全且类型正确 | missing=0  |
| PASS | F32 output_norm 可直接读取且数值合理 | count=2048 first=4.0000,3.9062,4.0625,4.2188 |
| PASS | STQ1_0 解码与独立 Python/PR 参考逐元素零误差 | elements=5120 mismatch=0 maxAbs=0.0 |
| PASS | Q6_K 解码与独立 Python/ggml 参考逐元素零误差 | elements=1024 mismatch=0 maxAbs=0.0 |
| PASS | golden manifest 记录官方 SHA256 | cc497fe8f033b52b3b8b00a7669e9661435432f9d4cd43f7ed24400c01507a93 |
| PASS | 算子解码性能数据已落盘（非推理口径） | 2659547 elements/s, 2.31 ms |

## language-catalog (13/13)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 模型卡 36 种语言全部登记 | count=36 |
| PASS | 语言代码无重复 |  |
| PASS | 代码清单与模型卡一致 |  |
| PASS | 未受措辞修复影响的 7 个语言名逐字不变 |  |
| PASS | 评测发现的 7 个语言名已改为 XX语 | gu=古吉拉特语 te=泰卢固语 es=西班牙语 km=高棉语 mr=马拉地语 he=希伯来语 ur=乌尔都语 |
| PASS | 别名 iw 同步为希伯来语 |  |
| PASS | 36 种语言全部有真实中文名与短标签（无裸代码） |  |
| PASS | 别名 zh-cn / zh-hans → 简体中文 |  |
| PASS | 别名 zh-tw / zh-hant → 繁体中文 |  |
| PASS | 未知代码原样返回，不臆造语言名 |  |
| PASS | contains 对全部 36 个代码为真 |  |
| PASS | contains 对未知代码为假 |  |
| PASS | 此前漏映射的 8 种语言已有中文名 | th=泰文 bo=藏文 ug=维吾尔文 kk=哈萨克文 mn=蒙古文 my=缅甸文 km=高棉语 te=泰卢固语 |

## pdf-chart (21/21)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 柱状图被识别成图表区域 | PDFRect(x0: 80.0, y0: 282.0, x1: 347.0, y1: 450.0) |
| PASS | 图表区域覆盖所有柱子并略外扩 | PDFRect(x0: 80.0, y0: 282.0, x1: 347.0, y1: 450.0) |
| PASS | 折线图按端点数识别（路径只有 2 条） | 1 |
| PASS | 整页底色不算图表 |  |
| PASS | 已识别的表格网格不会被当图表 | 0 |
| PASS | 小装饰框不触发图表识别 |  |
| PASS | 图表内刻度/轴标题/图例保持原文 | tick=true axis=true legend=true |
| PASS | 图注（Fig. 3. …）仍然翻译 |  |
| PASS | 图表外的正文段落照常翻译 |  |
| PASS | 绘图区右侧的图例也保持原文 | true |
| PASS | 侧边整句不被当图例 |  |
| PASS | 伸进图区的正文段落不被误钉 |  |
| PASS | 公式块保持原文 |  |
| PASS | 带等号的句子不算公式 |  |
| PASS | 上标碎片把两行并回同一段 | 3 \| test parameters th |
| PASS | 上标碎片单独成块（将来按碎片钉住） | 2 块 |
| PASS | 段落文本不被上标污染 | test parameters that was quantiﬁed was board density. The mean density of the entire set of boards was found to be 0.340 g/cm with |
| PASS | 项目符号 `◦` 也算碎片 |  |
| PASS | 8pt 的数字不算上标碎片（可能是列表序号） |  |
| PASS | 0.19em 的词距也补空格（原 0.25em 阈值会粘连） | In looking at |
| PASS | 词内 0.2pt 间隙不插空格 | mycelium |

## pdf-object (47/47)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | number-int | 42 |
| PASS | number-real | -3.25 |
| PASS | number-leading-dot | .5 |
| PASS | reference | 12 0 R |
| PASS | reference-not-confused-with-array | 数组里两个引用 |
| PASS | name-escaped | A#20B → A B |
| PASS | string-nested-parens | 嵌套括号 |
| PASS | string-octal-escape | 八进制 \101\102 → AB |
| PASS | string-hex-odd | 奇数位补 0 |
| PASS | dictionary | Type/Count |
| PASS | dictionary-serialize-roundtrip | 序列化后再解析应相等 |
| PASS | real-format-no-exponent | 1.0→1 / 1.5→1.5 |
| PASS | flate-roundtrip | 原始 5200 B → 压缩 74 B |
| PASS | flate-zlib-header | 首字节 0x78 |
| PASS | flate-raw-deflate-fallback | 裸 deflate 兜底 |
| PASS | asciihex | 48656C6C6F → Hello |
| PASS | ascii85-roundtrip | "Hello world" → 87cURD]j7BEbo7~> |
| PASS | ascii85-zero-shorthand | z → 4 个 0 字节 |
| PASS | runlength | abc + 4×X |
| PASS | predictor-png-up | 两行 4 列 up |
| PASS | document-header | 版本 1.7 |
| PASS | document-startxref | startxref @476 |
| PASS | document-pagecount | 1 页 |
| PASS | document-catalog | Catalog 可解析 |
| PASS | document-not-encrypted | 未加密 |
| PASS | document-content-decoded | 解出 90 字符 |
| PASS | content-analyze-text-ops | Tj=1 BT=1 |
| PASS | content-analyze-graphics-ops | re=1 S=1 |
| PASS | evict-removes-glyphs | 删了 1 段 / 11 字节 |
| PASS | evict-keeps-graphics-bytes | 图形算子原样保留 |
| PASS | evict-keeps-text-block-shell | BT/ET/Tf 残留无害 |
| PASS | evict-four-operators | TJ/'/" 三段，re 保留 |
| PASS | evict-inline-image-intact | 内联图像字节保留，正文删除 |
| PASS | analyze-inline-image | BI=1 |
| PASS | evict-no-text-is-noop | 无文本时字节不变 |
| PASS | writer-grows-file | 659 → 890 B |
| PASS | writer-report | 改 1 个对象 |
| PASS | writer-reparse-pages | 1 页 |
| PASS | writer-reparse-content | 文本已消失，图形仍在 |
| PASS | writer-untouched-object-identical | 5 0 R 字体对象未变 |
| PASS | writer-new-startxref | startxref 476 → 797 |
| PASS | writer-prev-chain | /Prev 指回旧 xref |
| PASS | writer-end-marker | 以 %%EOF 结尾 |
| PASS | xrefstream-parse | 1 页，首段=stream |
| PASS | xrefstream-content | 内容流可解码 |
| PASS | xrefstream-writes-xref-stream | 新版仍是交叉引用流 |
| PASS | xrefstream-reparse | 1 页，文本已消失 |

## pdf-p1 (31/31)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | form-detected | 页面资源里 1 个 Form |
| PASS | form-reachable | [6] |
| PASS | form-evict-page-text | 页面文字已删，Do 算子保留 |
| PASS | form-evict-form-text | Form 内文字已删（P0 漏掉的正是这一层） |
| PASS | form-evict-keeps-graphics | Form 内矢量图形保留 |
| PASS | form-evict-report | Form 1 个，删 2 段 |
| PASS | nested-form-reachable | 外层 + 内层共 2 个 |
| PASS | nested-form-both-evicted | 两层文字都删掉 |
| PASS | shared-form-usage | Form 6 被 2 页引用 |
| PASS | shared-form-cloned-not-mutated | 未处理的第 2 页仍能读到原文 |
| PASS | shared-form-clone-evicted | 第 1 页的副本已删字 |
| PASS | shared-form-original-untouched | 原对象 6 0 R 一个字节没动 |
| PASS | shared-form-clone-count | 克隆 1 个 |
| PASS | font-load | 31058 字形 / upem 1000 / LinguaNovaSong-Regular |
| PASS | font-cmap-cjk | 「中」→ GID 8821 |
| PASS | font-composite-survey | 0 个复合字形（instancer 一般已扁平化） |
| PASS | composite-remap-synthetic | 组件 100/200 → 3/4，flags 与参数保留 |
| PASS | font-subset-size | 14851884 → 2212 字节 |
| PASS | font-subset-notdef | .notdef 固定为 0 |
| PASS | font-subset-reparse | 2 字形可回读 |
| PASS | font-subset-composite-remap | 组件最大 GID 0 < 2 |
| PASS | font-subset-width | 「中」字宽保持 1000 |
| PASS | font-subset-outline-preserved | 「中」轮廓 135 字节逐字节一致 |
| PASS | stamp-runs | 4 个 CID，子集 3540 字节 |
| PASS | stamp-page-count | 1 页 |
| PASS | stamp-image-bytes-identical | 图片流字节与字典完全一致 |
| PASS | stamp-font-type0 | Type0 / Identity-H |
| PASS | stamp-font-cidfont | CIDFontType2 / CIDToGIDMap Identity |
| PASS | stamp-fontfile-readable | FontFile2 解压后是可解析的 TTF |
| PASS | stamp-tounicode | ToUnicode CMap 存在且结构完整 |
| PASS | stamp-content-operators | BT..ET 已追加，原文字已删 |

## pdf-p2 (23/23)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | matrix-order | (1,1) → 先平移(10,0) 再缩放×2 = (22,2) |
| PASS | rect-iou | 同一矩形 IoU = 1 |
| PASS | cmap-bfchar | 两条 bfchar |
| PASS | cmap-bfrange | 递增区间 + 数组目标 |
| PASS | cmap-one-byte-codes | 1 字节码解析正确（不按 codespace 的 2 字节解释） |
| PASS | cmap-decode-two-byte | Type0 双字节切分 |
| PASS | encoding-winansi-specials | 0x92 → ’，0x80 → € |
| PASS | encoding-macroman | 0xA5 → •，0x80 → Ä |
| PASS | glyph-name-uni | uniXXXX 与标准名；未知名返回 nil |
| PASS | line-split-by-gap | 间隙 185pt 的两段文字 → 2 行 |
| PASS | line-keeps-close-runs | 间隙 5pt → 一行：Hello world |
| PASS | line-cjk-no-space | 中文不补空格，西文补 |
| PASS | columns-two | 2 栏，各 [10, 10] 行 |
| PASS | columns-single-not-split | 单栏 → 1 栏 |
| PASS | table-detected | 3×2 |
| PASS | table-rejects-single-box | 1×1 方框 → 0 张表 |
| PASS | table-rows-from-first-column | 3×2 |
| PASS | roundtrip-stamp | 20 字形 |
| PASS | roundtrip-read-back | 读回：高保真 PDF 翻译：图片与表格保持原样。 |
| PASS | roundtrip-translatable | translatable=true unmapped=0 |
| PASS | roundtrip-json-box | 块/行坐标与 top-down 盒子都在 |
| PASS | il-json-schema | 含 schema / pages / translatable |
| PASS | il-json-parses | 是合法 JSON |

## pdf-p3 (28/28)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | metrics-linear | 「中」12.0pt ×2 = 24.0pt |
| PASS | metrics-scale | 宽度与字号成正比 |
| PASS | metrics-missing | 私用区码位应报缺字 |
| PASS | kinsoku-no-leading-period | 行首句号 0 处 |
| PASS | kinsoku-no-trailing-open | 行尾左括号 0 处 |
| PASS | latin-word-boundary | 切成 hello\|wonderful\|world |
| PASS | no-break-number-unit | 行尾孤零零的数字 0 处 |
| PASS | hard-break-preserved | 2 行，首行=第一行 |
| PASS | placeholder-normalize | 见 {{12}} 与{{3}} |
| PASS | placeholder-missing | 缺 {{1}}{{2}} |
| PASS | placeholder-duplicated | 重复 {{1}} |
| PASS | placeholder-order | 顺序变了 |
| PASS | placeholder-clean | 占位符完整 |
| PASS | typeset-fit | fit 12.0pt |
| PASS | typeset-shrink-above-floor | shrink 6.0pt |
| PASS | typeset-respects-floor | 下限 6pt，实际 6.0pt |
| PASS | typeset-expand-right | expand 宽度 40 → 58.0 |
| PASS | typeset-overflow-exit | overflowLong 溢出 23 行 |
| PASS | reflow-reading-order | l1→l2→r1→r2 |
| PASS | reflow-no-overlap | 4 块，重叠 0 对 |
| PASS | merge-interleaved-blocks | 合并为 1 块，行序 ["上", "中", "下"] |
| PASS | merge-keeps-columns | 两栏保持 2 块 |
| PASS | engine-source-text | 原文=Hello |
| PASS | engine-translated | translated=1 文本=你好世界 |
| PASS | engine-original-gone | 旧文本已删除=true |
| PASS | engine-vector-kept | 矩形绘制算子仍在 |
| PASS | engine-page-count | 1 页 → 1 页 |
| PASS | engine-keeps-original | 保留原文 1 块 |

## pdf-p4 (29/29)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | render-available | 1190×1684 @144dpi |
| PASS | render-deterministic | 同一页渲染两次逐字节相同（6011880 字节） |
| PASS | render-size-a4 | A4 595×842pt @144dpi 应为 1190×1684，实际 1190×1684 |
| PASS | render-blank-is-white | 空白页非白像素 0 |
| PASS | render-bad-data | 非法输入应返回 nil 而不是崩溃 |
| PASS | mask-hit | 框内命中 / 框外不命中 |
| PASS | mask-area | 覆盖 16441 px，期望 16000 |
| PASS | mask-dilate | 膨胀 3pt 后 21889 > 16441 |
| PASS | diff-identical | 同图最大差 0 |
| PASS | diff-shift-detected | 内容整体下移 3 行 → 差异 3606 px，最大差 255 |
| PASS | ssim-identical | 自比 1.000000000 |
| PASS | ssim-inverted-low | 反相 -0.0044 |
| PASS | structure-identical | 同图结构差 0 |
| PASS | structure-lost-block | 抹掉 200×200pt 实心块 → 丢失 160801 px |
| PASS | structure-ignores-glyphs | 40 个 4×6pt 墨点消失 → 结构丢失 0 px |
| PASS | order-single-column | 两段自上而下，逆序 0 |
| PASS | order-inversion-detected | 顺序颠倒后逆序 1 |
| PASS | order-two-columns | 两栏识别 2 栏，逆序 0 |
| PASS | repair-shrink-derived | 12pt 溢出 → 下限 10.8 |
| PASS | repair-reflow-derived | 阅读顺序错误 → 整页重排 |
| PASS | repair-revert-when-tiny | 5.6pt 仍溢出 → 回落原文 |
| PASS | repair-merge-monotonic | 合并后 minFontSize 8.0，revert true |
| PASS | repair-skip-unfixable | 缺字 → repairs 空、人工 1 条 |
| PASS | e2e-typeset-stamp | 9101 字节 |
| PASS | e2e-loop-runs | 1 轮，页 1 |
| PASS | e2e-structure-intact | 结构丢失 0 px |
| PASS | e2e-report-json | 分析结果可编码为 JSON |
| PASS | e2e-page-count | 页数 1 |
| PASS | e2e-content-hash | 内容哈希 dbd3136956026834 |

## pdf-p5 (13/13)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | render-content-scale | 矩形 (100,100)-(300,200) 渲染后墨迹 (100.0,100.0)-(300.0,200.0) |
| PASS | render-scale-invariant | 72dpi 与 144dpi 的页面坐标一致：100.0 / 100.0 |
| PASS | evict-keeps-range | 保留 World 后：Hello 在=false World 在=true 删除算子 1 个 |
| PASS | evict-keeps-all-is-noop | 全部保留时删除 0 个算子，字节是否原样 true |
| PASS | evict-all-removes-both | 删除 2 个算子 |
| PASS | evict-range-must-match | 区间整体后移 40 字节后仍删除 2 个算子（应为 2） |
| PASS | scrub-drops-unreferenced | 活对象 4，丢弃 2，标记字节还在=false |
| PASS | scrub-roundtrip-valid | 洗版后重新解析：页数 1，字节 475 |
| PASS | scrub-keeps-stream-bytes | 内容流字节原样保留（只重算 /Length 与字典顺序） |
| PASS | report-escapes-html | 尖括号与 & 已转义 |
| PASS | report-has-both-columns | 译文、页码、处理说明都在 |
| PASS | report-json-roundtrip | JSON schema 标记存在 |
| PASS | script-cjk-detect | 汉字/假名算 CJK；纯符号与数字不值得送模型 |

## pdf-p6 (13/13)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | multistream-tj-continuation | 跨流数组 + TJ：runs=3 text=CentreforRenewable |
| PASS | multistream-single-stream-baseline | 单流基线 runs=2 text=AlphaBeta |
| PASS | columns-two-columns-with-straddling-page-number | groups=3 left=12 right=12 first=left 0 last=5039 |
| PASS | columns-single-column-not-split | groups=1（标题不单独成栏，正文不拆） |
| PASS | line-merge-superscript | lines=["S. Sivaprasada", ", Sidharth K. Byju"] |
| PASS | line-inline-superscript-left-alone | lines=["a", "S. Sivaprasad , Sidharth K. Byju"]（行内上标保持独立，钉在原位） |
| PASS | line-unmapped-run-keeps-line-together | lines=1 text=The samples of dimension 30 cm 30 cm 1 cm is placed |
| PASS | line-table-cells-stay-separate | lines=3 |
| PASS | splitter-respects-sentence-boundary | chunks=7 sizes=[209, 210, 210, 210, 210, 210, 141] |
| PASS | splitter-keeps-abbreviation | first=As shown in Fig. 3 and Eq. 4, the values differ. |
| PASS | splitter-hard-cut-without-punctuation | pieces=5 max=100 |
| PASS | splitter-short-text-untouched | 短文本不应被切 |
| PASS | typesetter-strips-control-characters | lines=["第一行 第二行 带制表"] missing=[] |

## pdf-reflow (3/3)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 前一段被顶下去后，后一段也在它下面 | b1 正文底边=588.0 b2 顶边=584.0 |
| PASS | 排不下的块进 unplaced 名单 | unplaced=39 placed=2 |
| PASS | 4×4pt 的碎片不把段落顶下去 | y1=700.0 |

## pdf-region (20/20)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 14pt 栏缝也能切成两栏 | regions=2 |
| PASS | 两栏各 8 行、互不混入 | 8/8 |
| PASS | 左右两栏不会被并成假行 | lines=16 首行=Left column line 0 |
| PASS | 作者行与标题分成两个区域 | 6/4 |
| PASS | 作者名不会被粘到标题里 | Ángel T. Martínez1 \| Biodegradation of lignocellu- \| Mariela Speranza1 \| losics: microbial, chemical, \| Francisco J. Ruiz-Dueñas1 \| and enzymatic aspects of \| the fungal attack of lignin |
| PASS | 作者行的角标仍并回本行 | Ángel T. Martínez1 |
| PASS | 地址行不会和右栏正文并成一段 | Address line 0 |
| PASS | 只有一条基线时不当分栏 |  |
| PASS | 同一行的三个单元格仍是三行 | 3 |
| PASS | 两个 run 不单独成一个区域（交给字距判定） |  |
| PASS | 整幅空白带切成上下两块（顺序不变） | [3, 3] |
| PASS | 通栏页眉不阻止分栏 | 1/6/6 |
| PASS | 页眉单独一行，正文 12 行 | lines=13 |
| PASS | 缝不被端点抖动切成碎片 | 290.0..304.0 |
| PASS | 基线计数按 1pt 容差聚簇 |  |
| PASS | 缺字的下标换成 ASCII | H2O |
| PASS | 没有缺字时文本原样不动 |  |
| PASS | 装饰符号不被悄悄替换（缺字必须如实报告） |  |
| PASS | 缺字的土耳其字母退成基本字母 | Çulcuoglu |
| PASS | 字体有的变音字母不动（只在缺字时替换） | Çulcuoğlu |

## pdf-ruled-table (10/10)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 两条横线 + 对齐小字 → 认出表格 | 1 |
| PASS | 行数按基线数（含表头 12 行） | 12 |
| PASS | 列数按列首对齐（含表头 8 列） | 8 |
| PASS | 一格的文字不会被邻列吸走 | band 0 \| Lipids \| 1002 \| 1003 \| 1004 \| 1005 \| 1006 \| 1007 |
| PASS | 表头行属于表格（带子取最高的那一对横线） | TA |
| PASS | 上标碎片并进所在行，不多出一行 | 12 |
| PASS | 两条横线之间的正文段落不被当表格 |  |
| PASS | 只有一条横线时不猜表格 |  |
| PASS | 跨列长行让列边界不成立 → 不认 |  |
| PASS | 旋转的竖排标签不进表格 |  |

## runtime-probe (7/7)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 运行时自检判定 READY | 模型目录   : /Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate/Models/Hy-MT2-1.8B-1.25Bit-GGUF \| GGUF      : /Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate/Models/Hy-MT2-1.8B-1.25Bit-GGUF/Hy-MT2-1.8B-1.25Bit.gguf \| GGUF 大小 : 461860800 B \| GGUF 头   : magic=GGUF version=3 tensors=354 \| config    : OK \| tokenizer : OK \| Metal     : Apple M3 Pro \| 权重格式  : Sherry STQ1_0 1.3125 bpw 常驻 GEMV (NOT LUT4, NOT affine INT4, NOT fp16 展开缓存) \| 运行时    : 全程离线（无网络调用） \| 结论      : READY |
| PASS | GGUF v3 头与张量数正确 | magic=GGUF version=3 tensors=354 |
| PASS | config.json / tokenizer.json 齐备 | config=true tokenizer=true |
| PASS | Metal 设备可用 | Apple M3 Pro |
| PASS | GGUF 文件大小与官方一致（461,860,800 B） | 461860800 B |
| PASS | 权重格式如实标注 STQ1_0，不冒充 LUT4 / affine INT4 | Sherry STQ1_0 1.3125 bpw 常驻 GEMV (NOT LUT4, NOT affine INT4, NOT fp16 展开缓存) |
| PASS | 运行时声明全程离线 | offlineOnly=true |

## sampler-determinism (7/7)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 同一 seed 两次采样序列逐项一致 | len=24 head=[40, 55, 38, 38, 39, 39] |
| PASS | 不同 seed 产出不同序列（seed 真正生效，非死字段） | A=[40, 55, 38, 38, 39] B=[38, 38, 4, 21, 21] |
| PASS | greedy 序列确定且恒定 argmax | argmax=55 |
| PASS | 重建 Sampler 后不受前序 RNG 消耗影响 | rebuilt=[40, 55, 38, 38, 39, 39] |
| PASS | 端到端：同一请求跨其他请求复跑译文逐字一致 | a1=你好，很高兴见到你。 \| interrupt=机器学习正在改变世界。 \| a2=你好，很高兴见到你。 \| a3=你好，很高兴见到你。 |
| PASS | 端到端：不同输入确实产出不同译文（排除恒等假通过） | a=你好，很高兴见到你。 b=机器学习正在改变世界。 |
| PASS | 端到端：greedy 模式译文确定且不为空 | greedy=你好，很高兴见到你。 |

## selection-actions (31/31)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 出厂 7 个按钮且顺序固定 | copy,txt,docx,notes,reminders,speak,main |
| PASS | 出厂清单恰好等于上限 | 7 |
| PASS | 出厂清单不含任何在线动作 |  |
| PASS | 序列化往返一致 | copy,txt,docx,notes,reminders,speak,main |
| PASS | 空字符串回落到出厂清单 |  |
| PASS | 未知码被忽略并回落到出厂清单 | copy |
| PASS | 重复码去重 |  |
| PASS | 乱序输入按声明顺序归一 | copy,txt,main |
| PASS | 已满 7 个时不能再加 | 7 |
| PASS | 取消一个后剩 6 个 | copy,txt,notes,reminders,speak,main |
| PASS | 空位后可以加入 Bing | copy,txt,notes,reminders,speak,main,bing |
| PASS | 新加入的按钮排在声明顺序位置（末尾） | copy,txt,notes,reminders,speak,main,bing |
| PASS | 再次点击即移除（开关语义） |  |
| PASS | 只剩 1 个时不能再关 |  |
| PASS | 只剩 1 个时仍可再开 | speak,main |
| PASS | 全部在线动作可同时开启（4 个） | bing,google,weibo,taobao |
| PASS | 换行与连续空白压成单个空格 | hello world |
| PASS | 纯空白返回 nil |  |
| PASS | 超长文本按 1000 字符截断 | 1000 |
| PASS | Bing 主机与查询参数名正确 | www.bing.com |
| PASS | Bing 查询串保留 & = # 等特殊字符（不截断） | C++ & Rust=快 #1 |
| PASS | Google 主机正确 |  |
| PASS | 淘宝主机正确 |  |
| PASS | 微博走分享页且参数名为 title | service.weibo.com title=今天天气不错 |
| PASS | 全部为 https |  |
| PASS | 本机动作没有网页地址 |  |
| PASS | 空译文不产出网页地址 |  |
| PASS | 存文件与回主窗口不要求译文 |  |
| PASS | 复制/朗读/网页动作要求有译文 |  |
| PASS | 在线标记只覆盖 4 个网页动作 | bing,google,weibo,taobao |
| PASS | 每个动作都有名称/图标/说明且图标互不重复 |  |

## selection-capture-policy (32/32)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 空采样不采用 |  |
| PASS | 单样本不采用（必须连续两次一致） |  |
| PASS | 两次一致才采用 |  |
| PASS | 两次不一致不采用（避免半截选区） |  |
| PASS | 三样本只看最后两次，旧采样不干扰 |  |
| PASS | 三样本最后两次不一致仍不采用 |  |
| PASS | 纯空白选区不采用 |  |
| PASS | 首尾空白被归一化 |  |
| PASS | 超长选区钳到 4000 字符 |  |
| PASS | 旧 token 晚完成不能覆盖新结果 |  |
| PASS | 前台应用中途切换则结果作废 |  |
| PASS | 选区不稳定则结果作废 |  |
| PASS | 最新 token + 同应用 + 稳定则采用 |  |
| PASS | PID 未知时不做额外否决 |  |
| PASS | 剪贴板内容未变化视为 ⌘C 未生效 |  |
| PASS | 剪贴板出现新文本视为有效 |  |
| PASS | 剪贴板空白文本视为无效 |  |
| PASS | 剪贴板无文本视为无效 |  |
| PASS | 只读观察：nil 文本不采用 |  |
| PASS | 只读观察：纯空白不采用 |  |
| PASS | 只读观察：用户 ⌘C 的内容等于原剪贴板仍采用（旧规则会放弃） |  |
| PASS | 只读观察：反复划同一个词每次都采用 |  |
| PASS | 普通单击不触发捕获 |  |
| PASS | 真实拖拽 20pt 触发捕获 |  |
| PASS | 有 dragged 但位移仅 1pt 不触发（抖动） |  |
| PASS | 仅坐标差大但无 dragged 事件不触发（异步漂移防护） |  |
| PASS | 微小位移 5pt 不算拖拽 |  |
| PASS | 双击选词触发捕获 |  |
| PASS | 两次点击间隔过长不算双击 |  |
| PASS | 两次点击位置相距过远不算双击 |  |
| PASS | 斜向拖拽按欧氏距离判定 |  |
| PASS | 稳定等待长于采样间隔，硬超时更长 |  |

## selection-language (37/37)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 中文短句判为 zh | Optional("zh") |
| PASS | 中文长段落判为 zh |  |
| PASS | 日文假名混汉字优先判为 ja（不误判为 zh） | Optional("ja") |
| PASS | 韩文判为 ko |  |
| PASS | 泰文判为 th |  |
| PASS | 阿拉伯文判为 ar |  |
| PASS | 西里尔文字判为 ru |  |
| PASS | 英文句子判为 en | Optional("en") |
| PASS | 长英文夹单个汉字不误判为中文 | Optional("en") |
| PASS | 法语句子判为 fr | Optional("fr") ← Bonjour, je voudrais |
| PASS | 德语句子判为 de | Optional("de") ← Guten Tag, ich möcht |
| PASS | 西班牙语句子判为 es | Optional("es") ← Buenos días, quiero  |
| PASS | 葡萄牙语句子判为 pt | Optional("pt") ← Bom dia, gostaria de |
| PASS | 意大利语句子判为 it | Optional("it") ← Buongiorno, vorrei p |
| PASS | 越南语句子判为 vi | Optional("vi") ← Xin chào, tôi muốn đ |
| PASS | 印尼语句子判为 id | Optional("id") ← Selamat pagi, saya i |
| PASS | 法语单词问候判为 fr | Optional("fr") ← Bonjour |
| PASS | 西班牙语短问候判为 es | Optional("es") ← Hola amigo |
| PASS | 德语短谢判为 de | Optional("de") ← Danke schön |
| PASS | 噪声短词 OK 不臆造语言 | nil |
| PASS | 噪声短词 test 不臆造语言 | nil |
| PASS | 噪声短词 Hello 不臆造语言 | nil |
| PASS | 噪声短词 a 不臆造语言 | nil |
| PASS | 噪声短词 123 不臆造语言 | nil |
| PASS | 噪声短词 3.14 不臆造语言 | nil |
| PASS | en→zh 划法语改为 fr→zh（不再标成英文） | fr→zh |
| PASS | zh→en 划德语改为 de→en（目标不被改写成中文） | de→en |
| PASS | 中英混排以中文为主时判为 zh | Optional("zh") |
| PASS | en→zh 划中文时改为 zh→en（不再原样照抄） | zh→en |
| PASS | en→zh 划英文保持 en→zh | en→zh |
| PASS | zh→en 划英文时改为 en→zh（不自译） | en→zh |
| PASS | en→zh 划日文保持目标 zh | ja→zh |
| PASS | 源目标同为 zh 时自动选非同语言目标 | zh→en |
| PASS | 49 组文本×语言对组合均不自译 |  |
| PASS | 短划词至少 128 tokens |  |
| PASS | 长划词按长度放宽但不超过 512 | 332 |
| PASS | 超长划词钳到 512 |  |

## selection-popup-layout (12/12)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 短划词使用 compact 档窄窗 | tier=compact width=320.0 height=182.0 |
| PASS | 宽度随划词量单调递增且不超上限 | 320.0 < 380.0 < 520.0 <= 520.0 |
| PASS | 高度随划词量增长且不小于最小高度 | 182.0 < 197.0 < 356.0 (min=182.0) |
| PASS | 加载态 / 空译文给出可用最小窗口 | height=182.0 translationHeight=45.0 |
| PASS | 视图/面板尺寸恒等式对所有档位成立 | height = base + sourceHeight + translationHeight |
| PASS | 超长划词钳到屏幕安全上限并改为窗内滚动 | scrolls=true height=558.0 tier=max |
| PASS | 原文行数限制随档位放宽 | short=2/1 long=6/9 |
| PASS | 复杂脚本按更宽单位估算折行 | CJK 全角权重 2，拉丁 1 |
| PASS | 显式换行按段落累加行数 | 3 段至少 3 行 |
| PASS | 窄屏宽度被钳在安全范围内 | screenWidth=340 -> width=308.0 |
| PASS | 错误文案参与尺寸计算 | height=182.0 translationHeight=45.0 |
| PASS | 同一输入结果确定性一致 | 纯函数、无随机与状态 |

## selection-share (6/6)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 纯文本保留换行与语言对 | 原文（中 → 英）
第一行
第二行

译文
L1
L2 |
| PASS | 标题取译文首行 |  |
| PASS | 标题超长截断并加省略号 |  |
| PASS | 标题长度恰好等于上限时不截断 |  |
| PASS | 空译文标题为空（不产生省略号垃圾） |  |
| PASS | 首行为空时回落到整体内容 | 实际内容 |

## sherry-backend (11/11)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 1.25bit GGUF 常驻权重已落盘 | /Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate/Models/Hy-MT2-1.8B-1.25Bit-GGUF/Hy-MT2-1.8B-1.25Bit.gguf |
| PASS | 如实声明真实推理且绝不冒充 LUT4 / affine INT4 | Sherry STQ1_0 1.3125 bpw 常驻 GEMV (NOT LUT4, NOT affine INT4, NOT fp16 展开缓存) |
| PASS | Sherry 常驻后端 prepare 成功（含 Metal kernel 预热） | 787.0 ms |
| PASS | 运行时仅常驻 461,860,800 B GGUF（非 3.58 GB fp16） | gguf=461860800 gpu=461860800 norm=282624 |
| PASS | 引擎识别为真实推理且后端标识正确 | real=true id=hymn-stq1_0-gguf-v1 |
| PASS | en→zh 产出真实译文（非占位 token） | 你好，很高兴见到你。 |
| PASS | zh→en 产出真实译文 | Machine learning is changing the world. |
| PASS | 并发请求经单实例调度且并发峰值恒为 1 | maxConcurrency=1 |
| PASS | 取消链路可用（CANCELLED） | cancelled=true 3942.7 ms |
| PASS | 真实推理期间主线程 10ms tick 最大间隔 < 100ms | ticks=80 max=12.27 ms avg=10.00 ms |
| PASS | 性能 / 译文数据已落盘（单次测量口径） | Reports/sherry-resident-perf.json |

## sherry-resident (14/14)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 1.25bit GGUF 与 G4 独立 golden 已落盘 | /Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate/Models/Hy-MT2-1.8B-1.25Bit-GGUF/Hy-MT2-1.8B-1.25Bit.gguf |
| PASS | 常驻权重 461,860,800 B，未展开 3.58 GB fp16 缓存 | gguf=461860800 gpu=461860800 norm=282624 tensors=354 |
| PASS | 无 weights.fp16.bin 也能 prepare（常驻 GGUF） | tmp 目录无 weights.fp16.bin，prepare 成功 |
| PASS | 常驻 STQ1_0/Q6_K GEMV 与独立 Python/PR golden 对齐 | samples=4 elements=80 maxAbs=7.6293945e-06 minCorr=0.9999999996441361 |
| PASS | Q6_K embedding 行解码与独立 golden 对齐 | elements=2048 maxAbs=0.0 |
| PASS | 完整 forward 不在主线程执行 | pthread_main_np=false |
| PASS | 每 token 225 次常驻 GEMV + 258 个 Metal 算子 | gemm=225 compute=258 gpu=40.55 ms |
| PASS | 32 层 logits 与 fp32 golden 对齐 | corr=0.999999 maxAbs=0.0127 top20=20/20 argmax=28036(expected 28036) |
| PASS | layer32 hidden 与 fp32 golden 对齐 | corr=1.000000 maxAbs=0.0084 |
| PASS | H1 batched prefill logits 与逐 token forward 逐元素相等 | n=120818 maxAbs=0.0 commandBuffers=1 (单 token forward=1) |
| PASS | 默认 KV cache 为 fp16 64 MiB（int8 需显式开启） | mode=fp16 bytes=67108864 |
| PASS | H1 int8 KV cache 模式生效且显存占用更小 | int8=34603008B fp16=67108864B saved=32505856B |
| PASS | H1 int8 KV cache logits 与 fp16 高度一致（有损但有界） | corr=0.999993 maxAbs=0.0400 top20=20/20 argmax=28036 |
| PASS | 数值对齐数据已落盘 | Reports/sherry-resident-golden.json |

## streaming-decode (6/6)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 旧 grapheme 前缀差会残留 U+FFFD（bug 复现） | legacy="A�中B" |
| PASS | 新 scalar 增量无 U+FFFD 残留且文本完整 | fixed="A中B" |
| PASS | 旧 grapheme 前缀差在天城文组合字符上重复输出（bug 复现） | legacy="कक्क्म" expected="क्म" |
| PASS | 新 scalar 增量完整还原组合字符且不重复 | fixed="क्म" |
| PASS | 真实 tokenizer：旧逻辑在复杂脚本上确实损坏译文 | bad=4/5 tokens=60 legacy="�ខខ្�ញ�ញុ�ញុំ�ស�សូ�ម�ព�នន្�យ�ល�ល់�ព�ពី�កកា�រ�ប�បោ�បោះ�ឆឆ្�ន�នោ�ត�រ�ប�ស�ស់�យ�យើ�ង" fixed="ខ្ញុំសូមពន្យល់ពីការបោះឆ្នោតរបស់យើង" |
| PASS | 真实 tokenizer：新逻辑逐 token 拼接与一次性 decode 完全一致 | bad=0/5 tokens=60 legacy="�ខខ្�ញ�ញុ�ញុំ�ស�សូ�ម�ព�នន្�យ�ល�ល់�ព�ពី�កកា�រ�ប�បោ�បោះ�ឆឆ្�ន�នោ�ត�រ�ប�ស�ស់�យ�យើ�ង" fixed="ខ្ញុំសូមពន្យល់ពីការបោះឆ្នោតរបស់យើង" |

## text-chunker (8/8)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 空白页被跳过，页码仍精确保留 | chunks=6 pages=[1, 3, 4] |
| PASS | 超长段落按上限硬切且不丢字符 | 第 3 页块数=4 |
| PASS | 块序号连续且不与页码混淆 |  |
| PASS | 短页按原有换行边界保留段落 |  |
| PASS | 同输入结果确定性一致 |  |
| PASS | 归一化剔除控制字符并压缩连续空行 | AB\n\nC |
| PASS | 全空输入不产生任何块 |  |
| PASS | 几百页规模仍保持线性且每块不超限 | 320 页规模 |

## tokenizer (7/7)

| 结果 | 用例 | 详情 |
|---|---|---|
| PASS | 原生分词器从 tokenizer.json 初始化成功 | vocabSize=120818 init=551.8 ms |
| PASS | 特殊 token id 与 checkpoint 一致 | bos=120000 eos=120020 user=120006 asst=120007 |
| PASS | 分词器输出与官方 HF tokenizers 逐项一致 | samples=31 mismatch=0 |
| PASS | decode 与官方 ByteLevel decoder 逐项一致 | mismatch=0 |
| PASS | chat_template 渲染与 jinja2 官方输出逐字符一致 | cases=5 mismatch=0 |
| PASS | 聊天提示词 token id 与官方一致（含 system / 多轮 / 占位符） | mismatch=0 |
| PASS | 分词器可用且吞吐可测 | 108515 tokens/s (3280 tokens, 30.2 ms, 20 repeats) |


> 说明：`scheduler` / `engine` / `thread-isolation` / `performance` 各组仍使用 `ProbeBackend` / `FixtureBackend` 测试替身验证调度、批量、取消与主线程响应性，不产生译文；`runtime-probe` 只读校验上线所需资源与格式标注；`sherry-resident` 用常驻 STQ1_0/Q6_K Metal GEMV 与独立 Python golden 做字节级解码、32 层 forward 数值对齐；`sherry-backend` 为端到端真实译文与性能；`sampler-determinism` 验证请求级可复现（每请求按 seed 重建采样器，同一请求跨其他请求复跑译文逐字一致）；`streaming-decode` 实证并修复复杂脚本流式译文的 U+FFFD 残留与字符重复；`selection-popup-layout` 验证划词浮窗尺寸随划词量自适应、屏幕上限与视图/面板尺寸恒等式；`selection-language` 实证划词请求不再复用主窗口语言对造成「中译中」原样照抄，并覆盖 49 组文本×语言对组合均不自译；`selection-capture-policy` 验证选区双读稳定、旧请求/切应用结果作废、剪贴板假阳性过滤（修复浮窗显示旧窗口词或半截选区）；`selection-actions` 验证浮窗底排按钮可配置的清单约束（最多 7 个、至少 1 个、去重、按声明顺序归一）、偏好序列化往返，以及网页动作 URL 编码（中文与 `&` `=` `#` 不被截断）；`document-export` 验证零依赖 DOCX(OOXML/ZIP store/CRC32) 与 TXT 写出、XML 转义、确定性及 14 语言目录；`text-chunker` 验证 PDF 按页分块、长段落硬切、空白页跳过与几百页规模。
