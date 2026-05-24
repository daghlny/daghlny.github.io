---
title: Claude Code Read 工具源码解读
date: 2026-05-24 11:00:00
tags:
  - Claude Code
  - 源码分析
  - AI
---

本文基于泄漏的 claude code 源代码解读CC的 **Read 工具**——模型每天用得最多的"读一个文件"工具。
视角是普通外部用户拿到的 npm 版本：feature flag 默认值、非 Anthropic 内部账号(因为源代码里有太多试验性分支)。

---

## 1. Read 到底是什么

> 把磁盘上的一个文件读出来，按特定格式塞给模型，并且在 session 内留下"我读过哪些文件、读到了什么版本"的记号。

后半句往往比前半句更重要。**Read 工具的核心价值不只是 I/O，而是它和 Edit/Write 的协作契约**——只有先经过 Read 留下记号的文件，Edit/Write 才肯动。后面会展开讲。

工具定义在 `src/tools/FileReadTool/FileReadTool.ts` 里，主体一千多行；真正动文件系统的代码不到 100 行，剩下都是"读完之后怎么让模型尽量少犯错"。

---

## 2. 输入与输出

### 2.1 输入

模型能传四个字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `file_path` | string，必填 | **必须是绝对路径**——工具描述里硬性写明 |
| `offset` | int，可选 | 1-indexed 起始行号 |
| `limit` | int，可选 | 读多少行；默认 `MAX_LINES_TO_READ = 2000` |
| `pages` | string，可选 | 仅 PDF 用，形如 `"1-5"`、`"10-20"` |

不传 `offset`/`limit` 就是"从头读最多 2000 行"。工具描述还会根据一个实验开关 `tengu_amber_wren` 在两种 hint 之间切换：

- **默认**："建议读整文件，不要传 offset/limit"
- **实验路径**："已知要读哪部分时只读那一段"

这条 hint 直接影响模型行为——默认 prompt 鼓励"先整读再说"，实验 prompt 鼓励"先定位再切片读"。

### 2.2 输出

输出是个**类型分发**结构：根据文件类型给七种不同的 payload，分别是 `text`、`image`、`notebook`、`pdf`、`parts`（PDF 抽页成图）、`file_unchanged`（dedup 命中的占位）以及空文件警告。不同类型走不同的渲染 pipeline 和模型侧编码，强行塞进一个统一 schema 反而别扭。

---

## 3. `readFileState`：Read 留下的"看过什么"账本

这是理解整个工具的关键概念

### 3.1 它是什么

每次 Read 成功读完一个文件，工具都会在一张表里登记：

```
路径 → {
  content:   文件内容（去掉行号、reminder 后的原始字节）
  timestamp: 读到时的 mtime
  offset:    本次读的起始行
  limit:     本次读的行数
}
```

这张表跨 trajectory 累积(可以参考https://bytetech.info/articles/7637478618704117786)、整个 session 生命周期内有效，由 LRU 管理，最多 100 条 / 25 MB。key 做了路径归一化，避免 `/a/../b` 和 `/b` 占两个槽。

### 3.2 它的三个用途

**(1) 让 Edit/Write 拒绝"没读过就改"**

这是 Read 工具最重要的隐性副作用。Edit / Write 在动文件前会先查 `readFileState`：

```ts
// FileEditTool.ts:275
const readTimestamp = toolUseContext.readFileState.get(fullFilePath)
if (!readTimestamp || readTimestamp.isPartialView) {
  return {
    result: false,
    behavior: 'ask',
    message: 'File has not been read yet. Read it first before writing to it.',
  }
}
```

模型如果跳过 Read 直接 Edit，会立刻吃一条 tool error，下一轮自然就先 Read。这是一个**软契约硬效果**的设计——工具层不强制规则，但谁不遵守谁就报错重来。

Edit 之后还会进一步检查 mtime——如果文件被外部（用户、linter、其他 agent）改过，会要求重新 Read。

**(2) Read 自己的 dedup 起点**

简单说, 同一个文件如果有重复读的请求, 那么不需要在上下文里注入两次文件内容, 具体逻辑见第5部分.

**(3) 区分"模型看到的内容"和"磁盘真实内容"是否一致**

`FileState` 上有个 `isPartialView` 标志，专门处理**自动注入**的场景：CLAUDE.md / MEMORY.md 这类文件在 session 启动时被自动塞进 system prompt，塞之前会剥 HTML 注释、截断超长内容。这时表里存的是磁盘原始字节（内部 diff 要用），但模型见到的是裁剪版——表跟模型见过的内容不一致，所以叫 partial view。

注意这跟"切片读 vs 整文件读"是两回事——模型用 `offset=100, limit=10` 切片读一个普通文件，`isPartialView` 依然是 false，因为模型见到的就是磁盘那 10 行的真实字节。

带 `isPartialView: true` 的 entry 会被 Edit/Write 视同没读过，强制要求一次真正的 Read。Read 自己写入的条目永远不带这个标志。

---

## 4. 文本文件怎么读出来

绝大多数 Read 调用都是读文本文件，主流程经过六个阶段，任意一步失败或短路就提前结束：

| # | 阶段 | 做什么 |
|---|---|---|
| 1 | 权限检查 | 路径在工作目录 / allow 规则里吗，是不是 UNC / 设备文件 |
| 2 | 输入校验 | 路径展开成绝对路径、扩展名不是已知二进制、PDF `pages` 范围合法 |
| 3 | **dedup 短路** | 上次 Read 过、范围一致、文件 mtime 没变 → 返回占位，**结束** |
| 4 | 读盘 | 按扩展名分发：text / image / PDF / notebook 各走各的路径 |
| 5 | 登记 | 内容、mtime、`offset` / `limit` 写进 `readFileState` |
| 6 | 加工后返回 | 给文本拼行号、新鲜度提示、网络安全 reminder → 发给模型 |

下面这部分展开 4-6 这几个文本特有的步骤。 其他部分可以走后续的章节阅读到. 

### 4.1 两种物理读法

`readFileInRange` 里有两条路径：

| 路径 | 触发条件 | 实现 |
|---|---|---|
| Fast | 普通文件且 < 10 MB | 一次性 `readFile` 读完，内存里 split 行 |
| Streaming | ≥ 10 MB / 管道 / 设备文件 | `createReadStream` 流式扫，**range 外的行只数 `\n` 不累积** |

第二条路径的关键设计是不累积 range 外的内容——所以读一个 100 GB 文件的前 5 行不会爆内存。

两条路径都做 UTF-8 BOM 剥除、CRLF → LF 归一、通过已经打开的文件描述符拿 mtime。

### 4.2 两层大小限制：bytes 卡入、tokens 卡出

这是工具内部一个挺重要的设计——读多大有**两个独立天花板**：

| 限制 | 默认值 | 检查时机 | 卡的是什么 |
|---|---|---|---|
| `maxSizeBytes` | 256 KB | 读盘前（stat 后立刻判） | 文件**总**字节数 |
| `maxTokens` | 25 000 | 读盘后（tokenize 估算） | 真实输出 token |

为什么两层都要？因为单看任何一个都漏：

- 字节小 token 高：大量 emoji / CJK / minified JSON，256KB 可能 3 万 token。
- 字节大 token 低：大段空格 / 重复字符的源码，10MB 可能才几千 token。

bytes 防"读盘 OOM"，tokens 防"context 浪费"。

token 估算是分两步的：先用基于文件类型的粗估算法，超过 `maxTokens / 4` 才真打 token-count API 拿精确值——省一次往返。

还有个不对称行为值得知道：**只在"不传 limit、读整文件"时检查 `maxSizeBytes`**，传了 limit 的切片读认为模型自己负责。源码里有一段注释说他们实验过把"超过字节上限"从抛错改成截断到上限，结果工具错误率掉了，但平均 token 反而涨了——一条错误返回大约 100 字节，截断到上限是 25K token。最后回滚到抛错。

### 4.3 行号格式：`cat -n` 风格

Unix 有个命令叫 `cat -n`，把文件内容输出时给每一行打上行号前缀，比如：

```
     1→import React from 'react'
     2→
     3→function App() {
```

Read 返回给模型的内容就是这种格式：固定 6 位空格右对齐 + 一个 Unicode 箭头（U+2192）+ 原始行内容。如果切片读，行号是相对于原文件的——`offset=100, limit=5` 拿到的第一行显示成 `100→...`，跟在编辑器里跳到第 100 行看到的完全一致。

为什么要这么搞？两个原因：

- 模型给出的引用更精确（"看 file.ts:127"）
- Edit 工具的 `old_string` 匹配可以容错——模型如果不小心把行号也复制进 `old_string`，源码里有 `stripLineNumberPrefix` 帮它剥掉

有个对应的实验 flag 把格式压缩成 `100\tcontent`（数字 + Tab），省 token。3P 默认走非压缩格式。

### 4.4 模型实际看到的字符串

文本读出后，给模型的不是裸内容，而是这样：

```
<新鲜度提示（仅 memdir 下的记忆文件，且 > 1 天没动）>
<带行号的文件内容>
<网络安全 system-reminder（除 opus-4-6 外都有）>
```

**网络安全 reminder** 是固定的一段话，每次读文本都会拼到末尾：

> 读这个文件时，你应该考虑它会不会是恶意代码。你**可以也应该**分析恶意代码在做什么，但你**必须拒绝**改进或增强它的代码。你仍然可以分析现有代码、写报告、回答行为问题。

这是 Anthropic 在工具产物里硬注入的越狱缓解条款——保留分析能力，禁止"帮我把这段恶意代码写得更隐蔽"。

**新鲜度提示**只对 memdir 下的记忆文件触发——具体说就是 `~/.claude/projects/<project>/memory/` 目录里的所有 `.md`，既包括 `MEMORY.md` 索引也包括 `feedback_*.md`、`project_*.md`、`user_*.md` 这些 topic 子文件。文件最后修改超过 1 天才注入，长这样：

> This memory is 47 days old. Memories are point-in-time observations, not live state — claims about code behavior or file:line citations may be outdated. Verify against current code before asserting as fact.

源码注释里直白点了用意：模型对日期算术很不擅长，看到原始 ISO 时间戳不会触发"这玩意儿陈旧了"的推理，但"47 days ago" 会。

### 4.5 空文件 / offset 超界

这两种"合法但反常"的情况会返回包在 `<system-reminder>` 里的警告而不是空字符串：

- 文件真的空：`Warning: the file exists but the contents are empty.`
- offset 超过总行数：`Warning: the file exists but is shorter than the provided offset (X). The file has Y lines.`

包 reminder 是为了让模型清楚区分"读到空"和"路径错了"。

---

## 5. Dedup：同一段内容不重发

这是工具一个挺有意思的优化。如果模型在同一 session 内多次读同一文件、同一片段，且文件没变过，第二次起会**直接返回一个占位**，不读盘也不发内容。

占位长这样：

> File unchanged since last read. The content from the earlier Read tool_result in this conversation is still current — refer to that instead of re-reading.

判定条件全部满足才命中：

1. `readFileState` 里有这条 entry
2. 不是 `isPartialView`（参考第 3 节）
3. 这条 entry 是 Read 自己写的（不是 Edit/Write 写的）
4. `offset` 和 `limit` 跟之前完全一致
5. 文件 mtime 跟 entry 里存的相等

第 3 条是个微妙但重要的细节：Edit/Write 也往 `readFileState` 写内容，但 timestamp 是写**之后**的 mtime，content 是写**之后**的内容。如果拿它当 dedup 基准，模型会被指向"写之前的旧 Read 输出"，错位——dedup 占位让模型"翻回历史里那次 Read 的 tool_result"，但 Edit 不产生 Read 的 tool_result，对话历史里能翻到的只有 Edit **之前**那次 Read 的旧内容。Read 自己写入时 `offset` 字段始终有值，Edit/Write 写入时是 `undefined`——靠这个字段区分。

为什么要做这件事？源码注释里给了数据："约 18% 的 Read 调用是同文件重复读，最高占整个 fleet `cache_creation` 的 2.64%。先前那次的 tool_result 还在 prompt cache 里，再发一份会让整段重新进 cache_creation 区，浪费 token 又拖响应。"

dedup 只对文本 / notebook 生效——图片 / PDF 不进 `readFileState`，永远 miss。

---

## 6. 非文本：图片 / PDF / Notebook

### 6.1 图片

支持 png / jpg / jpeg / gif / webp。**Node 自己不做图像处理**——resize 和压缩全部委托给 `sharp`（npm 包，底层是 C 写的图像引擎 libvips）。

整条链路：

```
fs.readFile            → Buffer（原始编码字节，未解码）
sharp(...).resize      → 等比例缩放到目标尺寸
sharp(...).jpeg/png    → 重新编码成目标格式
buffer.toString('base64')  → 包进 Messages API 的 image content block
```

**压缩是阶梯式的**——目标是把字节数压到 token 预算之内（25 000 token 折算约 150 KB 原始字节），按下面顺序逐档加大力度，能停就停：

| 档位 | 做法 |
|---|---|
| 1 | 原图够小 → 直接用 |
| 2 | 等比例缩到 75% → 50% → 25%，保持原格式 |
| 3 | PNG 专路：缩到 800×800、转 64 色调色板 |
| 4 | 转 JPEG，缩到 600×600、quality=50 |
| 5 | 兜底：缩到 400×400、quality=20 JPEG |

JPEG 的 `quality` 是个"画质 vs 体积"的旋钮——80 是工业默认（肉眼基本无损）、50 看得出一点糊、20 明显模糊但体积极小。PNG 的"调色板模式"是把真彩色压成"全图只用 64 种颜色"，对截图 / 图标省得多，照片就糊。

**token 预算怎么反算成字节预算**：base64 编码大约 1 个字符 ≈ 0.125 token，且 base64 把每 3 字节扩成 4 字符，所以 `字节预算 = maxTokens / 0.125 × 0.75`。

**最终发给模型的形态**：压完的字节做 base64，塞进一个 Anthropic Messages API 的 image content block：

```ts
{ type: 'image', source: { type: 'base64', data: '<base64>', media_type: 'image/jpeg' } }
```

base64 只是传输层编码——JSON 装不下任意二进制字节，必须 ASCII 化（代价是体积涨 4/3）。服务端收到后 base64 解码、过 vision encoder 转成视觉 token，跟文本 token 一起喂给模型。因此**图片不进 `readFileState`**（字段是 `content: string`，存不下图像），dedup 对图片永远 miss。

### 6.2 PDF

PDF 是分支最复杂的类型，关键决策点：

- **传了 `pages` 参数**：抽指定页转 JPG，作为图像 block 塞给模型，单次最多 20 页。
- **没传 `pages` 且页数 > 10**：直接报错，强制模型加 `pages`。这是防止它无脑读 500 页 PDF 把上下文炸掉。
- **没传 `pages`、大小 ≤ 3MB、模型原生支持 PDF**：当成 `application/pdf` 的 base64 document 整个塞过去。
- **以上都不满足**：走 poppler 抽页路径，每页变 JPG。需要本地装 `poppler-utils`。

### 6.3 Jupyter Notebook

`.ipynb` 走单独的解析路径——解 cell 数组、JSON 序列化、按 cell 边界给模型。`readFileState` 里存的是 JSON 序列化后的字符串，dedup 仍然按 mtime 判定。

---

## 7. 权限与安全屏障

Read 走读权限检查（`checkReadPermissionForTool`），按下面顺序判。其中"规则"指的是 `settings.json` 里 `permissions` 字段下的条目，从几个层级合并加载（管理员策略 → `~/.claude/settings.json` → 项目 `.claude/settings.json` → 项目 `.claude/settings.local.json`）：

```json
{
  "permissions": {
    "deny":  ["Read(/etc/**)", "Read(**/.env)"],
    "ask":   ["Read(/Users/*/Documents/**)"],
    "allow": ["Read(/Users/me/work/**)"]
  }
}
```

`Read(...)` 是工具名，括号内是 gitignore 风格的 path pattern，用 `ignore` 库匹配。下面提到的"read deny / ask / allow 规则"分别对应这三个数组里所有 `Read(...)` 模式：

1. **UNC 路径**（`\\server\share` 或 `//server/share`）→ 一律 ask。防 SMB / NTLM 凭证泄露。
2. **可疑 Windows 路径模式** → ask。包括 ADS（文件名带冒号）、短名（`PROGRA~1`）、`\\?\` 长路径前缀、连续三点等。
3. **read deny 规则** → deny（**必须在 allow 之前**判，避免被 "write 隐含 read" 绕过）。
4. **read ask 规则** → ask。
5. **write 权限隐含 read** → allow。
6. **工作目录内** → allow。
7. **内部 harness 路径**（session-memory、plans、agent 输出等）→ 单独允许列表。
8. **read allow 规则** → allow。
9. 都不匹配 → ask。

工具内部还有两道额外屏障，不走 permission 系统：

**二进制扩展名拒绝**：除了 PDF / 图片 / SVG 外，碰到 `.exe`、`.zip`、`.so` 这种已知二进制后缀直接拒。这是个纯**扩展名判断**——不读字节，所以改了名的二进制还是会被当文本读出来，反过来也一样。是个有意的简化：`validateInput` 阶段不允许做 I/O。

**会阻塞的设备文件**：硬编码黑名单挡掉一批"读了会卡死或返回无限数据"的设备：`/dev/zero`、`/dev/random`、`/dev/urandom`、`/dev/full`、`/dev/stdin`、`/dev/tty`、`/dev/console`、`/dev/stdout`、`/dev/stderr`、`/dev/fd/{0,1,2}`、`/proc/*/fd/{0,1,2}`。`/dev/null` **不在黑名单里**——它是合法的"立刻 EOF"。

---

## 8. 错误降级

Read 在 ENOENT 上有两层兜底，让"看似路径错了"的常见场景能自愈。

**macOS 截图的"薄空格"回退**

macOS 不同版本截图文件名里 AM/PM 前面的空格可能是 ASCII 空格也可能是 U+202F（窄不换行空格）。用户经常把截图路径直接粘贴/拖进 Claude，但终端 / 浏览器对薄空格的处理不一致，导致键入和落盘时不同字符。

第一次读不到时，工具会把这个空格换成另一种再试一次。

**"你是不是想读 X" 建议**

仍然读不到时，并行跑两个查找：

- cwd 下找同名文件
- 按编辑距离找名字相似的文件

优先返回 cwd 内的建议。错误形如："File does not exist. Note: filesystem operations are performed from /Users/jane/foo. Did you mean /Users/jane/foo/src/Bar.ts?"

---

## 9. UI 渲染：只显示摘要

值得单独提一句：**文件内容永远不会显示在用户终端里**，只渲染一行摘要：

```
Read 42 lines
Read image (128 KB)
Read 12 cells
Read PDF (3.4 MB)
Unchanged since last read    ← dedup 命中
```

模型看到的是"内容 + 行号 + reminder"，用户看到的是这一行摘要。两条管线完全分开。

`/search` 历史检索也不索引 Read 的结果——它返回的是文件内容而不是"模型的发现"。

特殊情况下显示名字会变：路径在 plans 目录下显示 "Reading Plan"，路径是 sub-agent 输出文件时显示 "Read agent output" 并把 task ID 标在工具名旁边。

---

## 10. 一图总结

| 阶段 | 做了什么 | 关键产物 |
|---|---|---|
| `validateInput` | 路径展开、deny 规则、UNC、二进制扩展名、设备文件、`pages` 范围 | 是否放行 |
| `checkPermissions` | 9 步权限判定 | allow / ask / deny |
| `call` 前段 | dedup 短路、skill 触发副作用 | 命中则直接返回占位 |
| `callInner` | 按扩展名分发到 text / image / pdf / notebook | 各类型的 payload |
| 写 `readFileState` | 登记读过此文件、哪段、什么时候 | 给 Edit/Write 用 |
| 模型侧编码 | 行号 + reminder + 新鲜度提示 | 模型看到的字符串 |
| UI 渲染 | 一行摘要 | 用户看到的 |

Read 这个工具的实际定位是——**核心 fs 调用只有几十行；剩下大部分代码是在维护"模型容易踩的坑"的护栏**：

- 先 Edit 再 Read → `readFileState` 契约挡住
- 读过的文件重复读 → dedup 替换成占位
- 把不该读的二进制硬塞过来 → 扩展名 / 设备文件名单挡住
- 把陈旧记忆当真 → 新鲜度 reminder 提醒
- 读到恶意代码就帮着改进 → 网络安全 reminder 提醒

跟整份代码库一贯的取向一致：把模型的"软"约束放在工具层的副作用和 reminder 里，而不是堆在 system prompt 里。
