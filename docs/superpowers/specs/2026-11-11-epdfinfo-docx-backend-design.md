# epdfinfo 增加 DOCX/DOC 只读后端设计

日期：2026-11-11
状态：已实施，`.docx` 端到端验证通过；`.doc` 与加密包未验证
关联：`docs/superpowers/specs/2026-11-09-epdfinfo-rust-rewrite-design.md`

## 1 意图

让现有的 `epdfinfo` 服务在保持 PDF 行为不变的前提下，打开并显示 Word 文档（`.docx`、
`.doc`），由 pdf-tools 继续作为前端。目标是基本阅读：翻页、缩放、滚动、文本选择、keynav
光标。搜索、链接跳转、批注写入不属于本期目标。

为什么放进 `epdfinfo` 而不是新建 server：用户已经在用 pdf-tools，页面显示、缓存、
keynav、isearch 的骨架都已存在；新增一个独立 server 会重复这套 Lisp 侧逻辑。代价是
`epdfinfo` 从一个 PDF 专用后端变成多格式后端，二进制体积与编译时间增加。

## 2 目标与非目标

目标：

1. `.docx` 与 `.doc` 可以打开、关闭、翻页、按宽度渲染。
2. `number-of-pages`、`pagesize`、`pagelabels`、`metadata` 返回有意义的值。
3. `charlayout`、`getselection`、`gettext` 提供足以支撑 keynav、文本选择与复制的结果。
4. PDF 文档的现有行为与性能不发生回归。
5. 所有写操作在 Word 文档上明确失败，不产生半写状态。

非目标：

1. 编辑、保存、写回 docx 或 doc。
2. 注释、评论、修订的显示与编辑。
3. 搜索。`search-string` 与 `search-regexp` 返回空结果。
4. 链接、附件、SyncTeX。
5. 与 Microsoft Word 完全一致的分页、字体替换与断词。
6. Web/Draft/Read 视图与重排。

反目标（即使技术上可用也算失败）：

1. 把 docx 当作可写文档暴露给 pdf-annot，导致用户误以为批注会写回。
2. 打开失败时静默显示空白页。
3. 为支持 docx 而修改 PDF 分支的渲染结果。

## 3 约束

1. 唯一新增的文档引擎是 WordCraft，固定到 git rev
   `a34c94e4c1fce1b33776706a27be9396686f11d4`（2026-11-10 的 main）。
2. 现有 31 条 epdfinfo 命令与协议格式不变。
3. `[patch.crates-io]` 中 pdfcraft 的 `vello_cpu` 0.0.8 分叉必须保留。
4. WordCraft 使用 `LayoutOptions { view: ViewMode::Print }`，页面尺寸固定，不由窗口宽度决定。
5. 只读。Word 文档的 `save`、注释增删改、附件写入一律返回错误。
6. `CRAFT_I18N_DIR` 不设为必需。缺少时 craft-proof 只输出警告，不嵌入语言数据，断词
   能力下降；不影响编译。
7. 字体使用 `wordcraft_fonts::FontDb::global()`，它扫描内置字体与系统字体目录；不额外
   打包字体。

## 4 备选方案

### 方案 1：转换桥

`epdfinfo` 打开 docx 时先调用 WordCraft 导出 PDF，再交给现有 pdfcraft 管线。

放弃理由：用户明确要求文档原生后端；转换后分页、文本坐标都来自导出的 PDF，WordCraft
的文档模型（元数据、大纲、字符簇）反而被丢弃；每次打开多一次全文档导出，缓存失效
逻辑复杂。

### 方案 2：子进程渲染代理

`epdfinfo` 通过 `wordcraft-cli` 子进程取页面 PNG 与文本。

放弃理由：单次 CLI 调用实测 0.16 s 冷启动；翻页与缩放会触发频繁调用，延迟不可接受。
进程间传递大图与文本还需要额外协议与临时文件。依赖隔离是唯一优点，但用户要的是
单进程后端。

### 方案 3：进程内链接（已选）

在 `server-rs` 中直接依赖 `wordcraft-doc`、`wordcraft-docx`、`wordcraft-docbin`、
`wordcraft-layout`、`wordcraft-render`，与 pdfcraft 同进程。

已验证：pdfcraft 的 `vello_cpu` 0.0.8 与 WordCraft 需要的 `vello_cpu` 0.2.0 属于
semver 不兼容版本，Cargo 会同时保留两者；最小探针工程的 `cargo metadata` 解析成功，
没有 patch 冲突。

代价：两套光栅化器同时编译，编译时间与二进制体积增加；两套字体与布局代码常驻内存。
收益：无进程间调用、无临时文件、布局与光栅可缓存、WordCraft 的文本模型可直接映射。

## 5 架构

### 5.1 文档类型分派

`Session` 保持按文件名字符串缓存。`Document` 从单一 PDF 结构改为两个变体：

```rust
pub enum Document {
    Pdf(PdfDocument),
    Word(WordDocument),
}
```

`PdfDocument` 承接现有全部字段（`cos`、`renderer`、`info`、`page_refs`、`annots`、
`options`、`raster_cache`），方法签名不变。`WordDocument` 持有：

```rust
pub struct WordDocument {
    pub filename: String,
    pub doc: wordcraft_doc::Document,
    pub layout: DocLayout,
    pub options: Options,
    raster_cache: Option<RasterCache>,
}
```

打开时按内容分派，扩展名只作为提示：

| 检测 | 处理 |
|---|---|
| 前 5 字节为 `%PDF-` | `PdfDocument::from_bytes` |
| `wordcraft_docx::is_encrypted` 为真 | `wordcraft_docx::read_with_password`，解密 OOXML 包 |
| ZIP 头 `PK\x03\x04` | `wordcraft_docx::read_with_password`，识别 DOCX |
| XML 头 `<?xml` 或 `<` 开头 | `wordcraft_docx::read_xml`，识别 Flat OPC 与 WordML 2003 |
| CFB 头 `D0 CF 11 E0 A1 B1 1A E1` | 先 `wordcraft_docbin::read_with_password`；失败再试 `wordcraft_docx::read_with_password` |
| 其他 | 按 DOCX 包解析，失败则返回原始解析错误 |

CFB 容器既可能是 Word 97-2003（`WordDocument` 流），也可能是加密 OOXML（`EncryptionInfo`
加 `EncryptedPackage` 流）。加密 OOXML 先由 `wordcraft_docx::is_encrypted` 识别并直接交给
docx 解密；其余 CFB 先试 docbin 覆盖 Word 97-2003，docbin 报 `NotWord` 时再交给 docx。
两条路径都失败时返回 docbin 的原始错误。

加密文档的解析失败信息统一改写为 `Document is encrypted`，与现有
`pdf-info-encrypted-p` 的判定一致。

### 5.2 统一文档接口

命令层不再直接访问 PDF 专用字段。`Document` 提供以下方法，PDF 与 Word 各自实现：

| 方法 | 语义 |
|---|---|
| `page_count()` | 页数 |
| `page_size(page)` | 页面宽高，单位 pt |
| `render_page_rgb(...)` | 渲染并重着色，返回 `RgbImage` |
| `page_chars(page)` | 字符矩形列表，页面坐标 |
| `metadata_fields()` | 9 个元数据字段，与 PDF 分支一致 |
| `outline_items()` | 大纲条目 |
| `page_labels()` | 页码标签 |
| `is_read_only()` | Word 为 true |
| `save()` | Word 返回错误 |

现有命令中只有 8 处直接访问 PDF 字段（`info.rs` 的元数据、大纲、链接、页码标签、
附件，`annot.rs` 的注释列表、添加、保存）。这些点改为调用上述方法。

### 5.3 命令行为矩阵

| 命令 | PDF | DOCX/DOC |
|---|---|---|
| `ping` `features` `open` `close` `quit` | 支持 | 支持 |
| `getoptions` `setoptions` | 支持 | 支持，`usecolors`、`foreground`、`background` 生效 |
| `number-of-pages` | 支持 | 支持 |
| `pagesize` | 支持 | 支持 |
| `renderpage` | 支持 | 支持；`:crop-to`、`:foreground`、`:background`、`:alpha`、`:selection-style`、`:highlight-region`、`:highlight-text`、`:highlight-line` 全部生效 |
| `boundingbox` | 支持 | 支持，基于渲染像素 |
| `metadata` | 支持 | 支持，来自 `CoreProps` |
| `pagelabels` | 支持 | 返回 `1..n` 的十进制字符串 |
| `outline` | 支持 | 从 `outline_level` 构造；无标题时返回空 |
| `pagelinks` | 支持 | 空 |
| `charlayout` | 支持 | 支持 |
| `getselection` | 支持 | 支持 |
| `gettext` | 支持 | 支持 |
| `search-string` `search-regexp` | 支持 | 返回空列表，不报错 |
| `getannots` `getannot` | 支持 | 返回空列表 |
| `addannot` `editannot` `delannot` | 支持 | 返回 `Document is read-only` |
| `save` | 支持 | 返回 `Document is read-only` |
| `getattachments` `getattachment-from-annot` | 支持 | 返回空列表 |
| `synctex-forward-search` `synctex-backward-search` | 支持 | 返回错误 |
| `regexp-flags` | 支持 | 不变 |

空结果而非错误的原则：pdf-tools 在打开、mode line 刷新、isearch 中会调用这些命令；返回
错误会打断流程，返回空列表只会让功能显示为“无结果”。

`features` 的返回内容保持
`case-sensitive-search:writable-annotations:markup-annotations` 不变，避免 Lisp 侧
按能力分支的逻辑出现两套。写操作由具体命令拒绝。

## 6 渲染管线

```text
wordcraft_render::render_page(doc, page, scale, &RenderOptions::default())
  → Rendered { width, height, pixels: premultiplied RGBA }
  → 复合到白底
  → 现有 recolor::recolor（usecolors / foreground / background）
  → 现有 :crop-to 裁剪
  → 现有 png::encode（RGB8，deflate level 1）
```

细节：

1. `scale = requested_width / page.w`，与 PDF 分支一致。
2. `render_page` 输出宽度为 `ceil(page.w * scale)`，可能比请求宽 1 像素。按行裁剪到
   请求宽度，与 PDF 分支的处理相同。
3. 像素为预乘 RGBA。复合到白底的公式是 `out = c + (255 - a)`，不需要先反预乘。
4. `usecolors = 0` 时走 `recolor::recolor`，把背景映射为白色、前景映射为黑色；行为与
   PDF 分支相同。
5. 光栅缓存键为 `(page, width, usecolors, foreground, background)`，与 PDF 分支一致。
6. 页面高度按 `page.h` 计算，不额外加边距；WordCraft 的 `Page` 已包含页边距。
7. 高亮选项：`:highlight-region` 复用 `fill_rounded_rect` 与 `stroke_rounded_rect`；
   `:highlight-text` 与 `:highlight-line` 需要文本层。现有
   `RgbImage::highlight_text` 的参数是 pdfcraft 的 `PageText`；Word 分支新增
   `RgbImage::highlight_rects(&[[f32; 4]], scale, fg, bg, alpha)`，按字符矩形直接着色，
   Word 分支先用 `WordDocument::selected_chars` 求出矩形集合。

`RenderOptions` 使用默认值：白纸、无标记、不做文字加深与 hinting。这些选项影响像素
级外观，但不影响布局与分页。

## 7 文本层

### 7.1 数据来源

页面上的文本行来自 `Placed::Lines`，分布在三处：`page.header`、`page.items`
（正文与表格单元格）、`page.footer`。读取顺序固定为页眉、正文、页脚。每个
`Placed::Lines` 提供 `para: Arc<ParaLayout>`、`l0..l1`、`x`、`y`。行内字符簇由
`Line::c0..c1` 给出，横向位置用
`Line::cl_left(k)` 与 `Line::cl_right(k)`，两者已处理双向文本与竖排。

坐标换算：

```text
top     = y + (line.top - para.lines[l0].top)
bottom  = top + line.height
left    = x + line.cl_left(k)
right   = x + line.cl_right(k)
```

文本来自 `doc.para(story, path).text` 的字节区间 `cluster.start..cluster.end`。一个簇
可能包含多个 Unicode 字符（组合序列、连字）。处理规则：簇内每个字符按等宽切分簇矩形，
顺序按字符在文本中的逻辑顺序；双向文本的视觉顺序由 `cl_left` 已给出的几何决定。

取舍规则：

1. 簇的字节区间落在 `para.left_out` 中时跳过该簇，隐藏文字不进入文本层。
2. 簇在 `para.shown` 中有条目时使用该条目的文本（字段结果、脚注编号、公式结果）。
3. `para.label` 的列表符号挂在段首行，行号与该行相同。
4. U+FFFC 是图片、图表、书签等对象的占位符，一律跳过；图片本身不产生字符。
5. 竖排（`turn.is_turned()`）的表格文字不进入文本层，其坐标不在页面轴向内，暂不支持。

### 7.1.1 字符流与行号

`WordDocument::chars(page)` 返回按阅读顺序排列的 `CharBox { ch, rect, line }`，
`line` 是页内逐行递增的编号。`charlayout` 与 `gettext` 都由这个流派生，保证两者逐字符
对齐：

- `layout_chars(page)` 在相邻两条不同 `line` 之间插入零面积 `\n`（矩形为上一行末端的
  `[x, y, x, y]`）；整页查询时即使该点正好落在页面底边也保留。
- `gettext` 对选中的字符按流顺序拼接，`line` 变化时插入 `\n`。
- `pdf-keynav` 把 `pdf-info-gettext` 的结果加一个结尾换行后与 `charlayout` 比较，
  两者长度与字符位置因此一致；`pdf-keynav-lineends` 依据零面积元素识别行尾。
- `pdf-info-textregions` 走 `getselection` 的整页 glyph 查询，不需要单独命令。

### 7.2 charlayout

输出格式与 PDF 分支完全一致：

```text
left top right bottom:escaped-char
```

坐标为相对值：`left / page.w`、`top / page.h`、`right / page.w`、`bottom / page.h`。
区域过滤与命中规则复用 `commands/info.rs::charlayout` 的现有实现，只替换数据来源。

### 7.3 gettext 与 getselection

输入是相对坐标矩形与 selection style（glyph/word/line）。处理步骤：

1. 相对矩形换算为页面坐标。
2. 选出与矩形相交的字符；style 为 `word` 时在同一行内扩展到词边界，`line` 时扩展到
   整行。
3. 按字符流顺序拼接，`line` 变化时插入换行符；同一行内不额外插入空格，保持文档原始
   字符。
4. `getselection` 按行合并字符矩形，转回相对坐标输出。

限制：表格单元格、页眉页脚中的文本按布局顺序参与拼接，跨单元格的阅读顺序与视觉顺序
可能与人工预期不同。这是可接受的已知差异。

## 8 元数据与大纲

### 8.1 metadata

`wordcraft_doc::CoreProps` 映射到 `pdf-info.el` 实际解析的 9 个线上字段，顺序固定：

| 位置 | pdf-tools 键 | 来源 |
|---|---|---|
| 1 | title | `core.title` |
| 2 | author | `core.creator` |
| 3 | subject | `core.subject` |
| 4 | keywords-raw 与 keywords | `core.keywords`；Lisp 侧按逗号切分得到 `keywords` |
| 5 | creator | 固定 `WordCraft` |
| 6 | producer | 固定 `WordCraft` |
| 7 | format | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` |
| 8 | created | `core.created`，无值时为空字符串 |
| 9 | modified | `core.modified`，无值时为空字符串 |

字段数必须是 9：`pdf-info-query` 的 `metadata` 分支只消费 9 个字段，第 4 个字段同时用作
`keywords-raw` 的原始值和 `keywords` 的切分来源。多一个或少一个都会让后续字段整体错位。

WordCraft 的 `CoreProps` 没有独立的 author 字段；它把作者写入 `creator`，因此 author
映射到 `core.creator`，而应用程序名固定为 `WordCraft`。`creator` 与 `producer` 在
pdf-tools 中只用于展示。

日期保持 WordCraft 给出的原样（实测为 ISO 8601，如 `2025-02-15T10:31:00Z`）。pdf-tools
只把这两个字段用于展示，不参与解析。

### 8.2 outline

本期不实现大纲。Word 文档的 `outline` 命令返回空列表，`pdf-outline-minor-mode` 显示空
大纲，不报错。实现方式（大纲级别与 `DocLayout.index` 映射）留待后续。

### 8.3 pagelabels

返回连续十进制字符串，长度为页数。WordCraft 的节可以重排页码，但 pdf-tools 的
`pdf-info-pagelabels` 只用于 mode line 与跳转，本期不使用节页码。

## 9 只读保证

Word 文档在以下位置拒绝写入：

1. `save` 命令直接返回 `Document is read-only`。
2. `addannot`、`editannot`、`delannot` 返回同一错误。
3. 附件写入命令不提供 Word 分支。
4. Lisp 侧在 docx buffer 中关闭 `pdf-annot-minor-mode`、`pdf-sync-minor-mode` 与
   `pdf-links-minor-mode`。

`pdf-view-mode` 会把 `pdf-view-save-buffer` 注册到 `write-contents-functions`，它会调用
`pdf-info-save`。因此即使缓冲区被误按 `C-x C-s`，也会得到明确的只读错误，不会覆盖源文件；
不需要清空 `write-contents-functions`，否则普通保存可能绕过该保护。

## 10 Emacs 侧改动

改动全部位于 dotfiles 的 pdf-tools 配置，不进入 pdf-tools 仓库：

1. `pdf-tools` 的 `:mode` 增加 `("\\\\.docx?\\\\'" . pdf-view-mode)`，并把 `doc-view`
   原有的 `("\\.docx\\'" . doc-view-mode)` 绑定移除，避免二者冲突。
2. `pdf-view-mode-hook` 增加 `yc/pdf-view-word-setup`，深度 95，保证在
   `pdf-tools-enable-minor-modes` 之后运行；匹配 `.docx` / `.doc` 时关闭
   `pdf-annot-minor-mode`、`pdf-sync-minor-mode` 与 `pdf-links-minor-mode`。
   保留 `pdf-keynav-mode`、`pdf-isearch-minor-mode` 等其余模式。
3. isearch 在 Word 文档上得到空结果，显示 “no matches”，不报错。
4. keynav 依赖的 `pdf-keynav-charlayout` 与 `pdf-keynav-text` 由服务端保证逐字符对齐，
   见 §7.1.1。

## 11 性能与缓存

实测基线（官方 CLI，3 页 docx，73 词）：

| 操作 | 耗时 | RSS |
|---|---|---|
| 首次布局 | 818 ms | 未单独记录 |
| 渲染 1191×1684 | 0.16 s | 142 MB |
| 导出 PDF | 0.20 s | 178 MB |

进程内实测（release 构建，本机，含进程启动、字体扫描与协议往返）：

| 样本 | 操作 | 耗时 | RSS |
|---|---|---|---|
| `custom-reference.docx` | `open`（解析加布局） | 0.55 s | 114 MB |
| `sample.docx`（1 页） | `open` | 0.59 s | 103 MB |
| `custom-reference.docx` | 首次 `renderpage` 1191 像素宽 | 0.26 s | 约 144 MB |
| `custom-reference.docx` | 命中光栅缓存的 `renderpage` | 0.16 s | 约 144 MB |
| `test.pdf` | `open` | 0.03 s | 8.4 MB |
| `test.pdf` | 首次 `renderpage` 1191 像素宽 | 0.08 s | 未单独记录 |

结论：

1. Word 打开成本主要由全文档布局与系统字体扫描构成，远高于 PDF 的懒加载；常驻 server
   只付一次。大文档的布局耗时与内存尚未实测。
2. 翻页渲染与 pdfcraft 同量级；命中光栅缓存时只做重着色与 PNG 编码。
3. 内存：布局保留全文档页面与段落数据，3 页文档约 100 MB 量级。
4. 二进制体积：加入 WordCraft 后 release 可执行文件从约 14.2 MiB 增至约 31.2 MiB；
   两套 `vello_cpu`（0.0.8 与 0.2.0）同时存在是主要原因。
5. 增量 `cargo check` 约 2 分钟；release 重编译（含 thin LTO 链接）约 1.5 分钟。

## 12 错误处理

| 情况 | 行为 |
|---|---|
| 文件不存在 | `Error opening <path>:<io error>` |
| 加密且无密码 | `Document is encrypted` |
| 加密且密码错误 | `Document is encrypted` |
| WordCraft 解析失败 | `Error opening <path>:<parser error>` |
| 页号越界 | `No such page N` |
| 渲染超限（像素预算） | 与 PDF 分支相同，返回渲染失败 |

不捕获 panic。`wordcraft-*` 的 crate 在库内 `deny(clippy::unwrap_used)` 等，但
`epdfinfo` 不在 unwind 边界内；如果出现 panic，进程退出，pdf-tools 会重连。这是现有
行为，本期不引入 `catch_unwind`。

## 13 测试与验收

样本：

1. `/home/yyc/.dot-files/utils/.local/share/pandoc/custom-reference.docx`
   （3 页，含标题、列表、页脚；不在仓库内，测试时使用绝对路径）作为主样本。
2. `/tmp/opencode/docx-test/sample.docx`：由 pandoc 从 Markdown 生成，含标题、编号列表、
   项目符号列表、表格与中英文混排，用于本地验证，不进入仓库。
3. 真实 `.doc`：本机没有有效 CFB 样本，标记为待补充；没有样本时跳过，不伪造通过。

验收项：

1. `number-of-pages` 等于 WordCraft CLI `info` 的页数。
2. `pagesize` 与 `render --scale 1` 的像素尺寸一致（允许 1 像素取整差）。
3. `renderpage` 返回 PNG，宽度等于请求宽度，宽高比与页面一致。
4. `charlayout` 非空，所有坐标在 `[0, 1]` 内，字符总数与页面可见文本的字符数量级一致。
5. `gettext` 全页返回文本包含标题文本；`getselection` 返回至少一个矩形。
6. 在 docx 上执行 `pdf-keynav-next-line` 与 `pdf-keynav-previous-line` 不报错，光标移动。
7. `isearch-forward` 在 docx 上显示无匹配，不抛错。
8. `save`、`addannot` 返回只读错误。
9. 现有 PDF 测试与差分脚本全部通过。
10. 关闭并重新打开同一 docx，页数与渲染结果一致。

### 13.1 实测结果

2026-11-11，release 构建，Linux 本机。

| 项 | 结果 |
|---|---|
| `number-of-pages` / `pagesize` | `custom-reference.docx` 3 页 595.3×841.9 pt；`sample.docx` 1 页 612×792 pt |
| `renderpage` | 400 像素宽分别为 400×566 与 400×518，与页面比例一致 |
| `charlayout` | 两样本非空，坐标均在 `[0, 1]`，字符流与 `gettext` 逐字符对齐 |
| keynav 契约 | `gettext + "\n"` 与 `charlayout + 末尾换行元素` 等长且逐字符相同，`pdf-keynav-lineends` 有值 |
| `getselection` / `textregions` | `sample.docx` 16 行矩形，`custom-reference.docx` 4 行矩形 |
| `metadata` | 9 字段，Lisp 侧解析出 title/author/creator/producer/format/created/modified |
| `outline` / `getattachments` / `search-string` | 返回空结果，不报错 |
| `save` / `addannot` | `Document is read-only` |
| 错误路径 | 缺失文件返回 `No such file or directory`；非 zip 返回 `not a valid zip package` |
| `pdf-view-mode` | `.docx` 进入 `pdf-view-mode`；annot/sync/links 关闭，`size-indication` 保留 |
| PDF 回归 | `test.pdf` 的 open/pagesize/metadata/gettext/charlayout/getselection/getannots/search/renderpage/save 与改动前一致 |

未覆盖：真实 `.doc`（无有效 CFB 样本）与加密 OOXML 包（无样本）。两者的分派代码已编译
通过，但未做端到端验证。

## 14 风险

| 风险 | 影响 | 处置 |
|---|---|---|
| 两套 vello 编译后体积与编译时间显著增加 | 构建体验下降 | 实现阶段实测；必要时只依赖 `wordcraft-render` 的最小 feature 集 |
| WordCraft 分页与 Word 不一致 | 用户看到的页码与 Word 不同 | 文档与 mode line 注明由 WordCraft 排版；不承诺一致 |
| 字体缺失导致替换 | 行宽与页数变化 | 使用系统字体；缺字时在日志中记录 |
| `.doc` 无有效样本 | 无法验证 | 标记为未验证；优先保证 `.docx` |
| 表格、页眉页脚、RTL 的文本顺序 | keynav 定位偏差 | 已知差异写入文档；按行与视觉顺序排序 |
| `pdf-tools` 在打开时调用未实现命令 | 打开失败 | 命令矩阵中全部返回空结果而非错误 |
| 大文档布局耗时 | 打开慢 | 只布局一次并缓存；不做增量布局 |

## 15 规模与阶段

按一个人全职投入估算，总计约 10 个工作日，置信度中等：

| 阶段 | 内容 | 估算 |
|---|---|---|
| 1 | 依赖接入、`Document` 变体、内容分派、现有 PDF 分支不回归 | 2 天 |
| 2 | Word 渲染、页面命令、只读命令矩阵 | 3 天 |
| 3 | 文本层（charlayout、getselection、gettext、高亮） | 3 天 |
| 4 | Emacs 侧配置、keynav 与 isearch 端到端 | 1 天 |
| 5 | 样本测试、性能与体积记录、文档更新 | 1 天 |

未计入的时间：两套 vello 的首次全量编译、WordCraft 依赖锁定与版本升级。首次编译
可能需要 10 分钟以上，并且会占用较大磁盘空间。

## 16 留给实现者的决定

1. `Document` 用 enum 还是 trait 对象。倾向 enum，避免动态分派与生命周期复杂度。
2. 光栅缓存是否与 PDF 共用同一结构。倾向共用，键已包含文档类型隐含在实例内。
3. 字符簇多字符时的矩形切分方式。倾向等宽切分，优先保证 keynav 的行定位而非逐字精度。
4. outline 的深度基准。倾向把 `outline_level` 直接作为深度，与 pdf-tools 的 0 起算对齐。
5. 是否在 `features` 中声明只读能力。倾向不改，避免 Lisp 侧新增分支。
