# epdfinfo Rust 重写设计

日期：2026-11-09
状态：待评审
依据：`server/epdfinfo.c`（3929 行）、`server/epdfinfo.h`（246 行）、`lisp/pdf-info.el`，
以及 `/tmp/opencode/epdfinfo-inventory.md`、`/tmp/opencode/pdf-info-lisp-contract.md`。

## 1. 目标与范围

### 1.1 目标

用 Rust 重写 pdf-tools 的 PDF 后端 `epdfinfo`，唯一 PDF 引擎为 pdfcraft。
Rust 产物占用 `epdfinfo` 名称，C 产物改名 `epdfinfo-c`，默认构建与运行均使用 Rust 版。
`lisp/` 目录不做任何修改。

### 1.2 范围

覆盖当前 C 版命令表中全部 31 个唯一协议命令：

- 基础：`ping`、`features`、`open`、`close`、`quit`、`getoptions`、`setoptions`
- 搜索：`search-string`、`search-regexp`、`regexp-flags`
- 文档信息：`metadata`、`outline`、`number-of-pages`、`pagelinks`、`gettext`、
  `getselection`、`pagesize`、`boundingbox`、`charlayout`、`pagelabels`
- 注释：`getannots`、`getannot`、`addannot`、`delannot`、`editannot`、`save`
- 附件：`getattachment-from-annot`、`getattachments`
- SyncTeX：`synctex-forward-search`、`synctex-backward-search`
- 渲染：`renderpage`

`closeall` 不进入协议命令表，仅供 `quit` 内部调用。

### 1.3 不在范围

- 不新增 C 版没有的命令或参数。
- 不修改 `lisp/*.el`，不新增 Lisp 侧兼容分支。
- 不做字节级 PNG 复现。
- 不处理 Windows 原生构建；沿用仓库现有的 Unix/autotools 流程。

## 2. 验收标准

### 2.1 语义等价

对同一输入序列，Rust 版与 C 版满足：

- 命令名、参数个数、参数类型校验规则一致。
- 成功响应的记录条数、字段顺序、字段个数、分隔符一致。
- 字符串转义规则一致：`\n`、`\`、`:`。
- 页号基准为 1；归一化坐标区间为 `[0,1]`；颜色输出 `#rrggbb`。
- 数值可读性一致：浮点固定 6 位小数，整数无前导零。
- 错误场景返回 `ERR`，错误类别与触发条件一致；错误文案允许因底层引擎不同而不同。
- 二进制载荷（PNG、保存的 PDF、附件文件）不在协议流中，只返回临时文件路径。

### 2.2 Lisp 零改动

以未修改的 `lisp/pdf-info.el` 连接 Rust 版，以下路径必须可用：

- 打开、关闭、退出文档。
- 翻页渲染、搜索、文本选择、字符布局、边界框。
- 书签、链接、页面标签、元数据。
- 注释读取、创建、修改、删除、保存。
- 附件列举与提取。
- SyncTeX 双向搜索。

### 2.3 差分测试语料

只使用仓库现有文件：

- `test/test.pdf`：6 页，6 条注释，1 个附件，5 个书签，2 个链接。
- `test/encrypted.pdf`：密码路径。
- `test/test.tex`：配合 `test.pdf` 的 SyncTeX 样本。

### 2.4 明确豁免

- PNG 像素值、压缩字节、PNG 元数据不做逐字节比较；比较尺寸、颜色类型与
  非背景像素覆盖率。
- 浮点末位误差小于 `1e-5` 视为相等。
- 错误文案不逐字比较，只比较 `ERR` 与错误类别。
- 第 9 节的已记录行为差异在比较时按规则处理：`getannots` 与 `pagelinks`
  按集合比较，`getoptions` 忽略 `usecolors` 的跨字段值，临时路径归一化。

## 3. 方案选择

### 3.1 已选：A 一比一移植

按 C 版分层移植：`main` 读行，`protocol` 解析与编码，`session/document` 持有状态，
`commands` 按领域分文件，静态命令表与 C 版逐项对应。

理由：

- C 源码即行为规格，逐条命令可直接对照验证。
- 抽象最少，差异定位快。
- 目标不是架构创新，YAGNI。

未选方案：

- B 四层架构（transport/dispatcher/domain/backend，trait 化）：为一个固定行协议引入
  大量抽象，命令仍是静态分派，收益不足。
- C 枚举命令 + 类型化参数：参数校验更统一，但为 31 条命令增加一层与 C 命令表的映射，
  排错需跨层对照。

### 3.2 目录布局

```
server-rs/
  Cargo.toml
  Cargo.lock
  build.rs
  src/
    main.rs
    protocol/
      mod.rs
      split.rs
      encode.rs
      arg.rs
    session.rs
    document.rs
    options.rs
    tempfile.rs
    commands/
      mod.rs
      basic.rs
      search.rs
      info.rs
      annot.rs
      attach.rs
      synctex.rs
      render.rs
    pdf/
      mod.rs
      text.rs
      selection.rs
      region.rs
      recolor.rs
      png.rs
    synctex.rs
```

模块职责：

| 模块 | 职责 |
|---|---|
| `main.rs` | stdin 逐行读取、命令表、分派、响应刷新、退出 |
| `protocol/split.rs` | 复刻 `command_arg_split` |
| `protocol/encode.rs` | `print_response_string`、OK/ERR 块 |
| `protocol/arg.rs` | 参数类型校验，复刻 `command_arg_parse_arg` |
| `session.rs` | `HashMap<String, DocumentState>`、当前选项、进程生命周期 |
| `document.rs` | 单文档状态：cos 文档、渲染器、页信息、注释缓存 |
| `commands/*` | 各领域命令实现 |
| `pdf/text.rs` | 文本层、行/词分组、字符布局、search-string |
| `pdf/selection.rs` | `gettext`、`getselection` 的选区计算 |
| `pdf/region.rs` | 矩形合并，近似 cairo region |
| `pdf/recolor.rs` | `usecolors` 1/2 的像素重映射 |
| `pdf/png.rs` | PNG 编码 |
| `synctex.rs` | 1.21 源码 FFI 封装 |

## 4. 依赖与构建

### 4.1 运行时依赖

```toml
[dependencies]
pcre2 = "0.2"
png = "0.18"
libc = "0.2"

[dependencies.pdfcraft-render]
git = "https://github.com/storytold/pdfcraft"
rev = "c02341f6c0e0afe5b9c458794fcf236e16c34f90"

[dependencies.pdfcraft-cos]
git = "https://github.com/storytold/pdfcraft"
rev = "c02341f6c0e0afe5b9c458794fcf236e16c34f90"

[dependencies.pdfcraft-annot]
git = "https://github.com/storytold/pdfcraft"
rev = "c02341f6c0e0afe5b9c458794fcf236e16c34f90"

[build-dependencies]
cc = "1"
```

选择理由：

- `pdfcraft-render`：页面栅格化、文本字形、文档结构检视（书签、链接、注释、附件、
  字段、页面信息）。
- `pdfcraft-cos`：对象图读写、密码打开、保存、注释字典级字段。
- `pdfcraft-annot`：创建与修改注释、外观流生成。
- 不引 `pdfcraft-engine`：会连带 OCR、签名、表单、打印等大量依赖，且门面 API
  与需求不匹配。
- 不引 `pdfcraft-organize`：`pagelabels` 可直接用 `DocInfo.pages[i].label`。
  `pdfcraft_render::inspect` 已经读取 `/PageLabels`，无标签时回退为物理页号，
  与 poppler 的 `poppler_page_get_label` 行为一致。`test.pdf` 无 `/PageLabels`，
  C 版输出 `1` 至 `6`，即回退值。
- `pcre2`：C 版用 GLib `GRegex`，其底层即 PCRE2。语法、flags、错误语义最接近。
- `png`：直接控制颜色类型、filter、压缩级别。
- `cc`：编译仓库内置 SyncTeX 1.21 源码。

### 4.2 vendor patch 必须复刻

pdfcraft 工作区通过 `[patch.crates-io]` 把 hayro、lopdf、vello 等替换为 `vendor/`
下的本地版本。外部以 git 依赖引用时 patch 不继承，必须在本工程 `Cargo.toml` 重复：

每个条目使用完整表格写法，避免超过行宽：

```toml
[patch.crates-io.hayro]
git = "https://github.com/storytold/pdfcraft"
rev = "c02341f6c0e0afe5b9c458794fcf236e16c34f90"
package = "hayro"
```

需要复刻的 patch 包共 9 个：
`hayro`、`hayro-syntax`、`hayro-interpret`、`hayro-cmap`、`hayro-postscript`、
`hayro-jbig2`、`lopdf`、`vello_common`、`vello_cpu`。

关键事实：`patch` 只改变来源，不会强制降级。若依赖要求 `0.3.0` 而 registry 有
`0.3.1`，cargo 仍选 `0.3.1`，patch 被判 `unused`。因此 `Cargo.lock` 必须钉到
pdfcraft 自身锁定的版本，并随仓库提交：

| 包 | 版本 | 来源 |
|---|---|---|
| `hayro` | 0.7.1 | git patch |
| `hayro-syntax` | 0.7.2 | git patch |
| `hayro-interpret` | 0.7.0 | git patch |
| `hayro-cmap` | 0.1.0 | git patch |
| `hayro-postscript` | 0.1.0 | git patch |
| `hayro-jbig2` | 0.3.0 | git patch |
| `hayro-ccitt` | 0.3.0 | crates.io |
| `hayro-jpeg2000` | 0.3.5 | crates.io |
| `lopdf` | 0.45.0 | git patch |
| `vello_common` | 0.0.8 | git patch |
| `vello_cpu` | 0.0.8 | git patch |

锁定命令（在 `server-rs/` 下执行，结果写入 `Cargo.lock`）：

```
cargo update -p hayro-jbig2@0.3.1 --precise 0.3.0
cargo update -p hayro-cmap@0.1.1 --precise 0.1.0
cargo update -p hayro-postscript@0.2.0 --precise 0.1.0
cargo update -p hayro-ccitt@0.4.0 --precise 0.3.0
```

此路径已在 `/tmp/opencode/spike-rs` 验证：`cargo check` 通过。

### 4.3 SyncTeX

`build.rs` 编译 `../server/synctex_parser.c` 与 `../server/synctex_parser_utils.c`，
`include` 指向 `../server`，编译选项 `-D__GNUC__=1` 或在 Unix 下直接使用默认。
Rust 侧 `src/synctex.rs` 手写 `extern "C"` 声明，不使用 bindgen。

固定版本 1.21，理由是与当前 C 版行为一致。系统 `libsynctex` 为 2.0.0，
解析器行为可能不同，不采用。

### 4.4 Makefile 切换

- `server-rs/` 输出二进制名 `epdfinfo`。
- 顶层 `Makefile` 的 `server/epdfinfo` 目标改为执行
  `cargo build --release --manifest-path server-rs/Cargo.toml`，并复制产物。
- C 版构建目标改为 `server/epdfinfo-c`：
  - `server/Makefile.am`：`bin_PROGRAMS = epdfinfo-c`，源码变量按 autotools
    命名规则写为 `epdfinfo_c_SOURCES`。
  - 生成后的 `server/Makefile` 同步更新。
- 默认 `make` 只构建 Rust 版；C 版仅在显式 `make epdfinfo-c` 时构建。
- 打包目标继续复制 `epdfinfo`，不复制 `epdfinfo-c`。

## 5. 协议层

### 5.1 读取循环

- stdin 按字节读取，按 `\n` 切分。
- 空行忽略，不产生响应，与 C 版一致。
- 不含 `\n` 的残余行在 EOF 前不处理。
- 命令名与参数均为字节序列；需要 UTF-8 的地方转成 `&str`，失败按空串处理并写
  stderr，不终止进程。
- 每条响应结束后立即 flush stdout。

### 5.2 参数切分

复刻 `command_arg_split`：

- 未转义 `:` 是分隔符。
- 转义 `\n` 变为换行字节。
- 其他 `\X` 变为字面 `X`，丢弃反斜杠。
- 空串产生 0 个参数。
- 连续冒号产生空参数；结尾冒号产生额外的空参数。

### 5.3 参数校验

| 类型 | 规则 | 失败响应 |
|---|---|---|
| `DOC` | 按文件名打开或命中缓存 | `Error opening <file>:<reason>` |
| `BOOL` | 仅 `0` 或 `1` | `Expected 0 or 1:<arg>` |
| `STRING` | 任意 | 无 |
| `NONEMPTY_STRING` | 非空 | `Non-empty string expected` |
| `NATNUM` | `strtol` 基数 0，非负，无剩余字符 | `Expected natural number:<arg>` |
| `EDGE` | 浮点，`[0,1]` | `Expected a relative edge: <arg>` |
| `EDGE_OR_NEGATIVE` | 浮点，允许负值 | 同上 |
| `EDGES` | 4 个浮点，全部 `[0,1]` | `Expected a relative rectangle: <arg>` |
| `EDGES_OR_POSITION` | 4 个浮点，前两个 `[0,1]`，后两个可负 | `Expected a relative position or rectangle: <arg>` |
| `COLOR` | 长度 7，`#rrggbb` | `Invalid color: <arg>` |
| `REST` | 仅最后一项，收集剩余 | 无 |

数量规则：

- 无 `REST`：实际个数必须等于规格长度。
- 有 `REST`：至少为规格长度减一。
- 不符：``Command `<name>' expects <n> argument(s), <m> given``。
- 零参数命令忽略多余参数。

`NATNUM` 的基数 0 语义必须保留：`0x10` 解析为 16，前导 `0` 解析为八进制。

### 5.4 响应编码

- `OK` 块：`OK\n` + 记录 + `.\n`。
- 无记录：`OK\n.\n`。
- 字符串字段转义：`\n` → `\\n`，`\` → `\\`，`:` → `\:`。
- 数字、类型名、矩形数值不转义。
- 错误块：`ERR\n` + 原文 + `\n.\n`。

错误消息保持单行。C 版把 GError 原文直接写入，可能含换行并破坏协议；Rust 版在写入前
把消息中的 `\n` 替换为空格。此项列为已记录差异 D-14。

## 6. 文档状态模型

```rust
struct DocumentState {
    filename: String,
    password: Option<String>,
    cos: pdfcraft_cos::Document,
    renderer: pdfcraft_render::PageRenderer,
    info: pdfcraft_render::DocInfo,
    options: RenderOptions,
    /// page index -> annotation keys in /Annots order
    annot_keys: HashMap<usize, Vec<String>>,
}
```

### 6.1 两个表示

- `cos`：权威对象图。注释增删改、保存、`/Info`、附件参数都读它。
- `renderer`：由 `Arc<Vec<u8>>` 构造，负责栅格化与文本层。

注释被修改后：

1. 用 `pdfcraft_cos::write_full` 产出新字节，与 poppler 的整文档保存语义一致。
2. 用新字节重建 `PageRenderer`。
3. 保留 `cos`，继续承接后续编辑。

注释修改频率低，重建成本可接受；这样避免维护两套互相独立的注释状态。

### 6.2 打开与缓存

- 缓存键为调用方传入的文件名原字符串。
- 命中直接返回，忽略新密码，与 C 版一致。
- 未命中：读文件字节，`cos::Document::open_with_password`；失败不缓存。
- `open` 的空密码转 `None`；`ARG_DOC` 隐式打开时密码恒为 `None`。
- 首次打开失败后允许换密码重试；首次成功后不能通过 `open` 更换密码。

### 6.3 选项

```rust
struct RenderOptions {
    usecolors: i64,
    printed: bool,
    foreground: [u16; 3],
    background: [u16; 3],
}
```

默认值：`usecolors=0`、`printed=false`、`foreground=#000000`、`background=#000000`。

C 版把 `usecolors` 声明为 `long` 却存入 `gboolean` 字段，`getoptions` 会跨字段读取，
例如设置 2 与 `printed=1` 后输出 `4294967298`。Rust 版使用独立的 `i64` 字段，
输出真实值。此项为已记录差异 D-01。

## 7. 逐命令实现

以下“C 行为”指当前二进制可观察输出；“实现”指 Rust + pdfcraft 的做法。

### 7.1 基础命令

| 命令 | 实现 |
|---|---|
| `ping` | 原样回显参数，按字符串转义。 |
| `features` | 常量 `case-sensitive-search:writable-annotations:markup-annotations`。 |
| `open` | 见 6.2；成功输出空 OK 块。 |
| `close` | 从缓存移除，输出 `1` 或 `0`。 |
| `quit` | 释放全部文档，输出 OK 块，`exit(0)`。 |
| `getoptions` | 按固定顺序输出 4 个 `名称:值`，名称含前导冒号并转义为 `\:render/...`。 |
| `setoptions` | 键值必须成对；先写局部副本，全部成功后整体提交，随后输出完整选项。 |

### 7.2 搜索

#### `search-string`

参数：文档、首页、末页、搜索串、忽略大小写。

- 页范围：`first=max(1,first)`，`last = last<=0 ? n : min(last,n)`。
- 取 `PageRenderer::render(RequestKind::Text)` 得到 `PageText`。
- 匹配：`PageText::find_opts(needle, case_sensitive = !ignore_case, whole_words=false)`。
- 每条匹配输出：

```
<page>:<match>:<line>:<x1> <y1> <x2> <y2>
```

- `match`：匹配字形范围经 `text_of` 重建，去掉一个结尾换行。
- `line`：匹配矩形覆盖的整行文本，按行分组重建；矩形跨多行时用 `\n` 连接。
  与 C 版 `POPPLER_SELECTION_LINE` 语义对齐。
- 矩形：匹配字形 `rect` 的并集。pdfcraft 的 `rect` 已是页面视图坐标（左上原点、y 向下），
  直接除以页面宽高，不再做 y 翻转。
- 匹配文本与行文本转义；矩形字段不转义。

#### `search-regexp`

参数：文档、首页、末页、正则、编译标志、匹配标志。

- 用 `pcre2::bytes::RegexBuilder`，按 GLib flag 位映射到 PCRE2 选项。
- 在 `PageText::plain_text()` 上逐次匹配，得到字符区间。
- 建立“纯文本字符下标 → 字形下标”映射。与 `find_with` 不同，这里保留换行，
  不把换行折叠为空格。
- 每个匹配的字形矩形按 0.01 pt 精度取整后合并，等价于 C 版缩放因子 100 的
  cairo region。
- 输出：

```
<page>:<match>:<line>:<rect-list>
```

- `match` 为匹配文本；`line` 为匹配起始字符所在行的整行文本，
  与 C 版对首个匹配字符矩形调用 `POPPLER_SELECTION_LINE` 对齐。
- `rect-list`：多个 `x1 y1 x2 y2` 用 `:` 连接；空集合输出 `0.0 0.0 0.0 0.0`。
- 正则编译失败输出 `Invalid regexp: <reason>`。

GLib flag 到 PCRE2 的映射：

| GLib | 值 | PCRE2 |
|---|---|---|
| `caseless` | 1 | `CASELESS` |
| `multiline` | 2 | `MULTILINE` |
| `dotall` | 4 | `DOTALL` |
| `extended` | 8 | `EXTENDED` |
| `anchored` | 16 | `ANCHORED` |
| `dollar-endonly` | 32 | `DOLLAR_ENDONLY` |
| `ungreedy` | 512 | `UNGREEDY` |
| `raw` | 2048 | 关闭 UTF 模式 |
| `no-auto-capture` | 4096 | `NO_AUTO_CAPTURE` |
| `optimize` | 8192 | `NO_OPTIMIZE` 关闭，忽略 |
| `dupnames` | 524288 | `DUPNAMES` |
| `newline-cr` | 1048576 | `NEWLINE_CR` |
| `newline-lf` | 2097152 | `NEWLINE_LF` |
| `newline-crlf` | 3145728 | `NEWLINE_CRLF` |

匹配标志：

| GLib | 值 | PCRE2 |
|---|---|---|
| `match-anchored` | 16 | `ANCHORED` |
| `match-notbol` | 128 | `NOTBOL` |
| `match-noteol` | 256 | `NOTEOL` |
| `match-notempty` | 1024 | `NOTEMPTY` |
| `match-partial` | 32768 | `PARTIAL` |
| `match-newline-cr` | 1048576 | `NEWLINE_CR` |
| `match-newline-lf` | 2097152 | `NEWLINE_LF` |
| `match-newline-crlf` | 3145728 | `NEWLINE_CRLF` |
| `match-newline-any` | 4194304 | `NEWLINE_ANY` |

#### `regexp-flags`

静态输出 23 行，名称与值与 GLib 常量一致，顺序固定：

```
caseless:1
multiline:2
dotall:4
extended:8
anchored:16
dollar-endonly:32
ungreedy:512
raw:2048
no-auto-capture:4096
optimize:8192
dupnames:524288
newline-cr:1048576
newline-lf:2097152
newline-crlf:3145728
match-anchored:16
match-notbol:128
match-noteol:256
match-notempty:1024
match-partial:32768
match-newline-cr:1048576
match-newline-lf:2097152
match-newline-crlf:3145728
match-newline-any:4194304
```

### 7.3 文档信息

#### `metadata`

`pdfcraft_render::inspect` 的 `DocInfo` 提供 title、author、subject、keywords、creator、
producer、pdf_version，但不提供日期。日期从 `cos` 的 `/Info` 读取
`/CreationDate`、`/ModDate`。

`DocInfo.pdf_version` 形如 `1.5`；C 版 `poppler_document_get_pdf_version_string`
输出 `PDF-1.5`。实现时补前缀 `PDF-`，无法识别的版本输出 `PDF-Unknown`。

输出固定 9 字段：

```
title:author:subject:keywords:creator:producer:pdf-version:create-date:mod-date
```

日期格式复刻 `ctime`：`Wed Feb 11 07:54:01 2015`，去掉尾部换行，本地时区。
实现用 `libc::ctime_r`，与 C 版逐字一致。PDF 日期解析失败时该字段为空。

#### `outline`

遍历 `DocInfo.outline`，输出 `<level>:<ACTION>`，level 从 1 开始。
只输出可处理动作，子节点继续遍历。ACTION 规则见 7.3.1。

#### `number-of-pages`

输出 `DocInfo.pages.len()`。

#### `pagelinks`

参数：文档、页码。

- 页码非法：`No such page <n>`。
- 遍历 `DocInfo.links` 中该页的链接，按 `/Annots` 顺序输出。
- 矩形：`Link.rect` 为用户空间，经 `PageInfo::user_to_view` 转成视图坐标，
  再除以宽高。
- 输出 `<x1> <y1> <x2> <y2>:<ACTION>`。

C 版用 `g_list_last` 反向遍历，输出顺序与原始顺序相反；Rust 版按原始顺序。
此项为已记录差异 D-05。

#### `gettext`

参数：文档、页码、选区、selection-style。

- 页码非法：`No such page <n>`。
- 选区坐标乘以页面宽高。
- 按字形矩形与选区矩形求交，不用 `PageText::glyphs_in` 的中心点判定。
- `selection-style` 0/1/2 分别按字符、词、行扩展选区内的字形。
- 按行分组重建文本，行间 `\n`。
- 输出转义文本一行。

#### `getselection`

参数同 `gettext`。

- 取与选区相交的字形，按 selection-style 扩展。
- 合并为互不重叠的矩形集合，按 `pdf/region.rs`。
- 每条一个 `x1 y1 x2 y2`，归一化，不翻转。

#### `pagesize`

输出 `<width>:<height>`，单位 point，固定 6 位小数。
宽度取 `PageInfo.width`，已包含 `/Rotate` 与 `/UserUnit`。

#### `boundingbox`

参数：文档、页码。

- 页码非法：`No such page <n>`。
- 以 `width = (int) pt_width` 渲染，scale = width/pt_width，高度
  `(int)(scale*pt_height+0.5)`。
- 复刻 C 版扫描算法：以左上角像素为背景基准，扫描上下左右四条边带，
  求非背景包围盒。
- 空页输出 `0:0:1:1`。
- 否则输出四个归一化 `%f`，字段间 `:`。
- 渲染失败：`Failed to render page`。

#### `charlayout`

参数：文档、页码、区域或位置。

- `y2 < 0` 判定为位置模式。
- 位置模式：`(x1*width, y1*height)` 落在字形矩形内（含边界）。
- 区域模式：字形矩形完全位于 `(x1..x2, y1..y2)` 乘以宽高后的区域内。
- 每条 `<x1> <y1> <x2> <y2>:<char>`，矩形归一化，字符转义。
- 必须覆盖 `plain_text` 的每个字符，包括空格与换行。pdfcraft 的字形层不保存
  空白字形，只给出 `space_before` 与 `line_of`，因此按以下规则补记录：
  - 同一行内 `space_before[i]` 为真时，在前后字形之间插入空格记录，
    横向范围为前字形右边界到当前字形左边界，纵向取该行范围。
  - 行号变化时插入换行记录，横向取前一字符右边界，纵向取前一行范围。
- 连字字形按字符数把矩形等分，每个字符一条。C 版由 poppler 给出逐字符矩形；
  pdfcraft 以连字为最小单位。此项为已记录差异 D-07。

#### `pagelabels`

逐页输出 `DocInfo.pages[i].label`。
`pdfcraft_render::inspect` 已解析 `/PageLabels`，无标签时回退为物理页号，
与 `poppler_page_get_label` 一致。
标签为空时输出空行。

#### 7.3.1 ACTION 编码

`LinkTarget` 与 `OutlineItem` 的 `view` 映射：

| 来源 | 输出 |
|---|---|
| `LinkTarget::Page(page, view)` | `goto-dest:<title>:<page+1>:<top>` |
| `LinkTarget::Uri(uri)` | `uri:<title>:<uri>` |
| `LinkTarget::RemoteGoTo { file, destination, .. }` | `goto-remote:<title>:<file>:<page+1>:<top>` |
| 其他 | 跳过 |

`OutlineItem` 有 `page: Option<usize>` 与 `view`，无标题以外的动作类型，
统一按 `goto-dest` 输出。

`top` 计算：

```
top = (height - dest_top) / height
```

- `DestView::Top`、`Fit`：输出 `0`。
- `DestView::Xyz { top: Some(v), .. }`：输出 `%f`。
- `DestView::Xyz { top: None, .. }`：字段为空。
- `DestView::FitH { .. }`：输出 `0`，与 C 版一致。
- `DestView::FitV { .. }`、`FitR { .. }`：C 版对这些类型无条件输出 `%f`，
  其 `dest->top` 为 0，因此输出 `1.000000`。此结论来自 C 源码，现有
  `test.pdf` 的命名目标均为 XYZ，未在差分中覆盖。

`LinkTarget::RemoteGoTo` 的 `RemoteDestination::Default` 或 `Named` 无法解析到页时，
输出 `goto-remote:<title>:<file>:`，与 C 版 `printf(":")` 后换行一致。
`OutlineItem.page` 为 `None` 时输出 `goto-dest:<title>:`。
内部链接没有标题，`<title>` 为空字段。

标题、文件名、URI 转义；类型名、页码、`top` 不转义。

C 版把 `POPPLER_ACTION_NAMED` 也输出为 `goto-dest`，Rust 版同样无法区分，
行为一致。

### 7.4 注释

注释统一用 `pdfcraft_cos` 的字典级读写，必要时调用 `pdfcraft_annot` 创建对象与外观。

`DocInfo.annotations` 会排除 `Link`、`Widget`、`Popup`、`Screen` 等类型，而 C 版
`poppler_page_get_annot_mapping` 全部返回。因此 `getannots`、`getannot`、
`delannot`、`editannot`、`getattachment-from-annot` 不依赖该字段，直接按页读取
`/Annots` 数组，跳过非字典项，键的下标按有效注释顺序计数。

#### 注释键与顺序

- 键格式 `annot-<page>-<index>`，page 为 1 基，index 为该页 `/Annots` 数组下标。
- `getannots` 首次访问某页时按 `/Annots` 顺序生成键，输出顺序与 `/Annots` 一致。
- C 版用 `g_list_prepend`，输出顺序相反；Rust 版按原始顺序。已记录差异 D-05。
- `getannot`、`delannot`、`editannot`、`getattachment-from-annot` 若尚未扫描该页，
  先按需扫描，不再要求先调用 `getannots`。此项修复 C 版缓存缺陷，已记录差异 D-03。

#### `annotation_print` 字段

固定 8 字段：

```
page:edges:type:key:flags:color:contents:modified
```

- `page`：1 基页号。
- `edges`：`x1 y1 x2 y2`，用户空间矩形经视图变换后归一化。
- `type`：poppler 风格类型名。映射表见 7.4.1。
- `key`：转义。
- `flags`：`/F` 的整数。
- `color`：`#rrggbb`；缺失时为空。
- `contents`：`/Contents`，转义。
- `modified`：`/M`，转义。

markup 注释追加 6 字段：

```
label:subject:opacity:popup-edges:popup-is-open:create-date
```

- `label`：`/T`，即注释标题；poppler 的 `poppler_annot_markup_get_label`
  读取的就是该键。`test.pdf` 中为 `PDF Tools`。
- `subject`：`/Subj`。
- `opacity`：`/CA`，缺失按 1.0。
- `popup-edges`：`/Popup` 引用的矩形，缺失为空。
- `popup-is-open`：`/Popup` 的 `/Open`，缺失为空。
- `create-date`：`/CreationDate` 解析为日期后按 `%x` 本地化格式化；无效为空。

text 注释追加 3 字段：

```
icon:state:is-open
```

- `icon`：`/Name`，映射为 poppler icon 名。
- `state`：`/State` 小写。
- `is-open`：`/Open`。

text-markup 注释追加 1 字段：

```
quad-list
```

多个四边形用 `:` 连接，每个 `x1 y1 x2 y2`，按 `/QuadPoints` 归一化。
无四边形输出 `0.0 0.0 0.0 0.0`。

#### 7.4.1 类型名映射

| PDF `/Subtype` | 输出 |
|---|---|
| `Text` | `text` |
| `Link` | `link` |
| `FreeText` | `free-text` |
| `Line` | `line` |
| `Square` | `square` |
| `Circle` | `circle` |
| `Polygon` | `polygon` |
| `PolyLine` | `poly-line` |
| `Highlight` | `highlight` |
| `Underline` | `underline` |
| `Squiggly` | `squiggly` |
| `StrikeOut` | `strike-out` |
| `Stamp` | `stamp` |
| `Caret` | `caret` |
| `Ink` | `ink` |
| `Popup` | `popup` |
| `FileAttachment` | `file` |
| `Sound` | `sound` |
| `Movie` | `movie` |
| `Widget` | `widget` |
| `Screen` | `screen` |
| 其他 | `unknown` |

#### `getannots`

参数：文档、首页、末页。页范围手工归一化，同 7.2。
逐页扫描注释，输出每条 `annotation_print`。

#### `getannot`

参数：文档、键。按需扫描对应页后输出一条记录。

#### `addannot`

参数：文档、页码、类型、selection-style、矩形或位置、markup 区域。

- 页码非法：`Unable to get page <pn>`。
- 矩形缩放：`x1,y1,x2,y2` 乘页面宽高；`y2<0` 时 `y2=y1+24`；
  `x2<0` 时 `x2=x1+24`。
- `text`：REST 必须为空，创建 `/Subtype /Text` 注释。
- `highlight`、`squiggly`、`strike-out`、`underline`：REST 每项按 `EDGES` 解析，
  乘页面宽高后生成四边形；REST 为空时用整个矩形。
- 区域为空：`Unable to create empty markup annotation`。
- 未知类型：`Unknown annotation type: <type>`。
- 创建后 key 从当前注释数开始查重递增。
- 成功输出新注释记录。
- 失败：`Creating annotation failed: <reason>`。

实现优先用 `pdfcraft_annot::add_annotation`；若其 `Shape` 不覆盖某种类型，
按 PDF 规范直接构造字典与外观流。

#### `delannot`

按需扫描，删除 `/Annots` 条目与关联对象。
成功输出空 OK 块。

#### `editannot`

REST 为 `KEY VALUE` 对。先整体校验，再应用。

| KEY | 类型 | 允许的注释 | 实现 |
|---|---|---|---|
| `flags` | NATNUM | 任意 | 写 `/F` |
| `color` | COLOR | 任意 | 写 `/C` |
| `contents` | STRING | 任意 | 写 `/Contents` |
| `edges` | EDGES_OR_POSITION | 任意 | 写 `/Rect`，带保宽高逻辑 |
| `label` | STRING | markup | 写 markup label 字段 |
| `opacity` | EDGE | markup | 写 `/CA` |
| `popup` | EDGES | markup | 写或创建 `/Popup` |
| `popup-is-open` | BOOL | markup | 写 `/Popup /Open` |
| `icon` | STRING | text | 写 `/Name` |
| `is-open` | BOOL | text | 写 `/Open` |

不允许的属性：``Can modify `<key>' property only for <类型> annotations``。
单值解析失败：``Internal error while parsing arg `<arg>''``。

C 版此处页码未加 1：`Unable to get page <index> for annotation`。Rust 版改为
`Unable to get page <index+1>`，与其他命令一致。已记录差异 D-06。

#### `save`

- 创建临时文件。
- 用 `pdfcraft_cos::write_full` 写出当前对象图。
- 成功返回绝对路径；失败返回 `Error while saving <file>:<reason>`。
- 不自动删除临时文件。

### 7.5 附件

#### `getattachments`

遍历 `DocInfo.attachments` 中 `source` 为 `Document` 的项，id 为
`attachment-document-<i>`。`DocInfo.attachments` 同时包含注释级附件，
C 版 `getattachments` 只列文档级附件。

#### `getattachment-from-annot`

按注释 key 定位 `AttachmentSource::Annotation`。
错误分支：

- `No such annotation: <key>`
- `Not a file annotation: <key>`
- `Unable to get attachment: <key>`

成功后 id 为 `attachment-<key>`。

#### 附件记录

```
<id>:<name>:<description>:<size>:<mtime>:<ctime>:<checksum>[:<tempfile>]
```

- `id`、`name`、`description`、`checksum` 转义。
- `size`：`/Params /Size`；缺失输出 `-1`。
- `mtime`、`ctime`：`/Params /ModDate`、`/CreationDate` 经 `ctime` 格式化；
  缺失或非正输出空。
- `checksum`：`/Params /CheckSum`，输出十六进制串。
- 保存标志为真时用 `pdfcraft_render::attachment_data` 取字节写入临时文件；
  成功才输出路径，失败字段为空。

### 7.6 SyncTeX

#### `synctex-forward-search`

参数：文档、源文件、行、列。

1. `synctex_scanner_new_with_output_file(doc.filename)`。
2. 失败：`Unable to create synctex scanner, did you run latex with `--synctex=1' ?`。
3. `synctex_display_query`，取首个结果。
4. 失败：`Destination not found`。
5. 页面不存在：`Page not found`。
6. 计算 `x1,y1,x2,y2`，除以页面宽高。
7. 输出 `<page>:<x1>:<y1>:<x2>:<y2>`。

#### `synctex-backward-search`

1. 创建 scanner，错误同上。
2. 页面不存在：`Page not found`。
3. 归一化坐标乘页面宽高。
4. `synctex_edit_query` 取首个结果。
5. 失败：`Destination not found`。
6. 输出 `<file>:<line>:<column>`，文件名转义。

### 7.7 `renderpage`

参数：文档、页码、像素宽、REST 选项。

处理顺序与 C 版一致：

1. 页码非法：`No such page <pn>`。
2. 渲染整页到 RGBA 缓冲区。选项 `printed` 影响注释与表单绘制：
   pdfcraft 统一绘制，C 版在 `printed` 时调用 poppler 打印模式。行为差异已记录
   为 D-09。
3. 若 `usecolors` 为 1 或 2，立即对整页做重着色，等价于 C 版
   `image_render_page` 内的调用顺序。
4. 建立页面坐标系，按 `width/pt_width` 缩放。
5. 按顺序解析选项并立即绘制。
6. 若裁剪窗口不是整页，按像素裁剪。
7. 写 PNG 临时文件，返回路径。

默认值：

- `fg = #000000`
- `bg = #ff0000`（与 C 版一致，默认背景为红色，仅影响 highlight 填充）
- `alpha = 1.0`
- `line_width = 1.5`
- `selection_style = 0`
- 裁剪窗口 `[0,0,1,1]`

选项：

| 关键字 | 值 | 行为 |
|---|---|---|
| `:foreground` | COLOR | 设置 fg |
| `:background` | COLOR | 设置 bg |
| `:alpha` | EDGE | 设置 alpha |
| `:crop-to` | EDGES | 相对当前裁剪窗口组合新窗口 |
| `:highlight-region` | EDGES | 圆角矩形：bg+alpha 填充，fg 描边 |
| `:highlight-text` | EDGES | 选区重着色 |
| `:highlight-line` | EDGES | 先把矩形压成中线，再选区重着色 |
| `:selection-style` | NATNUM | 0/1/2，非法回退 0 |

其余规则：

- 关键字缺值：``Keyword is `<kw>' missing an argument``。
- 未知关键字：`Unknown render command: <kw>`。
- `:crop-to`、`:highlight-*` 的坐标相对当前裁剪窗口，而非整页。
- `:highlight-region` 的四边内缩 `line_width/2`，圆角半径
  `min(5, min(w,h)/2)`。

#### 7.7.1 选区重着色

pdfcraft 没有 `poppler_page_render_selection`。实现方式：

- 对选区内的每个字形，按 `selection-style` 扩展后取矩形。
- 在已渲染像素上，对矩形内像素按亮度在 fg 与 bg 之间线性插值，
  等价于 `usecolors=1` 的映射，只作用于选区。
- `:highlight-line` 先把矩形压成一条中线，避免渲染相邻行。

这样保留字形形状与文本可读性，颜色语义与 poppler 的 fg/bg 一致。
像素级差异已记录为豁免（2.4）。

#### 7.7.2 `usecolors`

`getoptions` 的 `:render/usecolors` 取值：

- 0：不处理。
- 1：按亮度权重 `(0.30, 0.59, 0.11)` 在 bg 与 fg 之间线性插值。
- 2：Oklab 保持色相的重映射，带单条缓存。
- 其他：C 版 `internal_error` 直接退出进程。Rust 版改为忽略该值，
  保持不处理。已记录差异 D-02。

算法逐字移植 C 版 `image_recolor`（c:470-625），包括 `rgb2oklab`、`oklab2rgb`、
`cairo` 的 ARGB32 通道顺序与小端字节序。

#### 7.7.3 PNG

- 8 位 RGB，无 alpha。
- 颜色类型 `RGB`，无隔行。
- filter `PNG_FILTER_NONE`。
- 压缩级别 1。
- 文件权限 `0600`。
- 失败：`Unable to write image`。

### 7.8 临时文件

- 目录：`std::env::temp_dir()`。
- 文件名前缀 `epdfinfo`，创建时使用 `O_CREAT | O_EXCL` 与随机后缀。
- 创建失败重试 3 次。
- 失败写 stderr，不终止进程。
- 不复刻 `tempnam` 的已弃用行为；路径形态不同，Lisp 只读取路径。

## 8. 差分测试

### 8.1 工具

新增 `server-rs/tests/differential.rs` 与 `server-rs/tests/diff.sh`。
两个二进制：

- `server/epdfinfo`（Rust）
- `server/epdfinfo-c`（C）

测试脚本启动进程，发送同一命令序列，读取响应到终止符 `.`。

### 8.2 归一化

比较前对两边响应做归一化：

- 临时文件路径替换为 `<TMP>`。
- 浮点数按 `1e-5` 容差比较。
- 错误文案只保留 `ERR` 标记。
- PNG 只比较宽高与文件非空。

### 8.3 用例

| 组 | 命令 |
|---|---|
| 协议 | 空行、未知命令、参数不足、参数过多、转义、`\:` 键 |
| 基础 | `ping`、`features`、`getoptions`、`setoptions` |
| 文档 | `open`、`close`、`quit`、`number-of-pages`、`pagesize` |
| 信息 | `metadata`、`outline`、`pagelinks`、`pagelabels` |
| 文本 | `gettext`、`getselection`、`charlayout`、`boundingbox` |
| 搜索 | `search-string`、`search-regexp`、`regexp-flags` |
| 注释 | `getannots`、`getannot`、`addannot`、`editannot`、`delannot`、`save` |
| 附件 | `getattachments`、`getattachment-from-annot` |
| 渲染 | `renderpage` 无选项、`:crop-to`、`:highlight-region`、`:selection-style` |
| SyncTeX | `synctex-forward-search`、`synctex-backward-search` |
| 加密 | `open` 错误密码、正确密码 |

### 8.4 流程

1. 构建两套二进制。
2. 启动两个进程。
3. 发送用例命令。
4. 读取完整响应。
5. 归一化后比较。
6. 输出差异报告，非零退出码表示失败。

## 9. 与 C 版的已记录差异

| 编号 | 差异 | 理由 |
|---|---|---|
| D-01 | `usecolors` 存为 `i64`，不再跨字段读写；`getoptions` 输出真实值 | 修复 C 版结构体尺寸不匹配 |
| D-02 | `usecolors > 2` 时忽略，不退出进程 | 避免任意选项杀死服务器 |
| D-03 | `getannot`、`delannot`、`editannot`、附件命令按需扫描页面 | 修复未先 `getannots` 时的误报 |
| D-04 | `close` 在释放后不再读取文档指针 | 修复 use-after-free |
| D-05 | 注释与链接按 `/Annots` 原始顺序输出 | 去掉无意义的反向输出 |
| D-06 | `editannot` 报错页码加 1 | 与其他命令一致 |
| D-07 | `charlayout` 连字按字符数等分矩形 | pdfcraft 以连字为字形单位 |
| D-08 | `metadata` 日期用 `libc::ctime_r` 复刻本地时区格式 | 与 C 版输出一致 |
| D-09 | `:render/printed` 不切换到打印模式 | pdfcraft 无对应开关 |
| D-10 | `:highlight-text`、`:highlight-line` 用像素重着色近似 | pdfcraft 无选区渲染 API |
| D-11 | `boundingbox` 以 pdfcraft 渲染结果扫描 | 引擎不同，边界像素可能不同 |
| D-12 | 错误文案来自 pdfcraft，措辞可能不同 | 底层错误类型不同 |
| D-13 | 临时文件命名规则不同 | 不复刻已弃用的 `tempnam` |
| D-14 | 错误消息中的换行替换为空格 | 保证行协议不被破坏 |
| D-15 | 空白行仍静默忽略 | 保持 C 版行为 |

## 10. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| pdfcraft 文本阅读顺序与 poppler 不同 | 搜索、选区、字符布局差异 | 差分测试逐项确认；必要时按 poppler 行分组启发式调整 |
| pdfcraft 不支持某些 poppler 注释属性 | `getannots` 字段缺失 | 字典级读写补齐 |
| 注释编辑后重建渲染器开销 | 大批量注释操作变慢 | 先测量；必要时延迟重建 |
| SyncTeX FFI 与 Rust 生命周期 | 崩溃或泄漏 | 封装 RAII，所有节点访问在 scanner 存活期内 |
| git 依赖拉取整仓 | 构建时间长 | 锁 rev，缓存 `~/.cargo/git`；后续可改 vendor |
| `patch` 版本漂移 | 编译失败 | `Cargo.lock` 入库，CI 用 `--locked` |

## 11. 里程碑

| 阶段 | 内容 | 验证 |
|---|---|---|
| M1 | 协议层 + `ping`、`features`、`open`、`close`、`quit`、`getoptions`、`setoptions` | 协议差分通过 |
| M2 | 文档信息命令 + 文本层 | `test.pdf` 信息与文本差分通过 |
| M3 | 搜索命令 + `pcre2` | `search-string`、`search-regexp` 差分通过 |
| M4 | 渲染命令 + 重着色 + PNG | 尺寸与非背景像素通过 |
| M5 | 注释命令 | 增删改查与保存通过 |
| M6 | 附件命令 | 提取与元数据通过 |
| M7 | SyncTeX | 双向搜索通过 |
| M8 | Makefile 切换与默认化 | `make` 产出 Rust 版 `epdfinfo` |
| M9 | 全量差分与 Lisp 端手工验收 | 全部用例通过 |
