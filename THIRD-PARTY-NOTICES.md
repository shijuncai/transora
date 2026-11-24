# 第三方组件与素材

本仓库的代码以 [MIT](LICENSE) 发布，但下面这些内容由第三方提供、遵循各自许可，
不在 MIT 覆盖范围内。

## 字体

| 文件 | 来源 | 许可 |
| -- | -- | -- |
| `Resources/Fonts/LinguaNovaSong-Regular.ttf` | 思源宋体（Source Han Serif）实例化并改名 | SIL Open Font License 1.1 |
| `Resources/Fonts/LinguaNovaSong-Bold.ttf` | 同上 | SIL Open Font License 1.1 |

许可证全文见 `Resources/Fonts/OFL.txt`。字体随附是为了让 PDF 版式重建能把中文写回
PDF；它与代码许可相互独立，替换或再分发时请遵守 OFL（保留许可证、不得单独售卖字体）。

## 模型权重

`Models/Hy-MT2-1.8B-1.25Bit-GGUF/` 下的量化权重**不包含在本仓库中**。
模型由腾讯混元发布，使用须遵守上游模型发布方的许可条款，与本项目的 MIT 许可无关。
仓库只提供加载与推理代码，以及用于对齐输出的 golden 数据。

## 测试语料

`Reports/` 下的对比报告引用了若干公开论文 PDF 的排版结果，仅作为开发期回归证据；
论文原文（`Sample/`）不在仓库内。
