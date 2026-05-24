---
title: 从源代码分析 Claude Code 多 Agent 设计
date: 2026-05-24 12:00:00
tags:
  - Claude Code
  - 源码分析
  - AI
---

---

**本文对普通用户帮助不大, 是作者通过 claude code 自己分析 claude code 泄漏源代码的总结. 如果没有一些基础知识,这篇文档会比较难读, 但是感兴趣的读者可以从文档里找出自己的问题, 并进一步自行探索**

---

本文介绍的是 claude code 的 multi-agent 设计, 主要包括 agent的不同种类, 以及 agent 的生命周期管理.

唯一的入口工具是 `AgentTool`（`src/tools/AgentTool/AgentTool.tsx`，1397 行）——所有多 agent 形态最终都要走它。

> **关于「决策指引写在哪」**：下文每个维度都会在末尾点一下「这条判定规则模型从哪里读到」。只有两层：主 system prompt（提供「该不该用 sub-agent」的最高层判断）和 AgentTool 自身的工具描述（具体的 sync/async、isolation、fork、续聊等所有判定规则都在这）。用户自定义 agent 的 frontmatter `description` 会被合并到 AgentTool 描述里的 agent list 节，是用户唯一能影响模型决策的入口。

---

## 1. 多 Agent 的几个正交维度

> 「fork」「isolate」「async」「parallel」这些词不在一个维度上——把它们放到同一句话里讨论会越说越乱。下面把它们拆到四个独立的维度上。

| 维度 | 选项 | 默认 |
|---|---|---|
| 上下文继承 | isolate（隔离）/ fork（继承父） | **isolate** |
| 执行时机 | sync（父等子）/ async（后台） | **sync** |
| 并发度 | 单次 / 并发（一回合多 tool_use） | 取决于父的决定 |
| 文件系统 | 共享父 cwd / worktree 隔离 | **共享父 cwd** |

第五个维度——「调度形态」——本质是「父 agent 的 system prompt 长什么样」，跟具体调用语义关系不大，放到本节末尾一句话带过。

### 1.1 维度一：上下文继承 —— isolate vs fork

**isolate**（默认）：子 agent 看不到父的对话历史。父跟子之间**只通过 `prompt` 字符串这一个字段传递信息**。子从零开始，自己的 system prompt + 父传过来的一段任务描述，仅此而已。

**fork**（`FORK_SUBAGENT` flag 开启时可选）：子 agent 继承父的**完整**对话历史 + 父的 system prompt 字节 + 父的 exact 工具数组。父 = 子的 API 请求前缀字节级相同，可以共享 prompt cache。

选择依据**不是「父能不能看到子的工具调用」**——无论 fork 还是 isolate，子的中间过程（thinking / 工具调用 / 工具结果）都不会进父的 messages，父只能拿到子的最终文本（详见 §3）。真正的区别在于**子需要什么**：

| 选 fork | 选 isolate |
|---|---|
| 子需要理解父跟用户聊过什么 | 子需要新视角 / 跟父对话无关 |
| 子是父思路的自然延伸（研究、实现接着 plan 走） | 子是个独立角色（code reviewer、特定 specialist） |
| 想要并发多路、又怕重复交代背景 | 子能力跟父不同，不该看父的工具选择 |
| 工具池跟父一致 | 工具池由 agent 定义决定，可能跟父完全不同 |
| 模型必须跟父一致（cache 共享要求） | 子可以用不同模型 |

> *决策指引位置*：「什么时候 fork」整段写在 AgentTool 的工具描述里，仅 `FORK_SUBAGENT` 开启时才拼进去。主 system prompt 这边只在「该不该用 sub-agent」总纲里一带而过。

外部用户拿到的 npm 版本 `FORK_SUBAGENT` 默认是关的，所以**默认就是 isolate**。下文未特别说明时，都默认讨论 isolate 路径。

### 1.2 维度二：执行时机 —— sync vs async

**sync**（默认）：父调用 `AgentTool` 后等到子跑完才继续。子的最终文本作为这次工具调用的返回值。

**async**：父调用 `AgentTool` 立刻拿到一个「已启动」的占位结果（含 `agentId` 和 `outputFile` 路径），子在后台跑。真正的最终结果通过 §3.2 介绍的 `<task-notification>` 机制在**未来某一轮**作为 user 消息回报。触发 async 的途径有四种：

- 父显式传 `run_in_background: true`——AgentTool 的可选参数，唯一用户能直接控制的开关
- 父处于 **coordinator 模式**——一种默认未启用的形态，主 system prompt 被换成「只调度、不执行」的版本（详见附录）
- **FORK_SUBAGENT** flag 开启——这会让所有 spawn 都强制 async，不只是 fork 路径本身
- 父处于 **KAIROS** 模式——一种默认未启用的长驻 assistant 形态，强制所有 sub-agent 异步以避免主 loop 被卡住

什么时候用 async：

- 父想在等子的同时做别的事（包括同时再起多个 agent）
- 任务可能跑得很长，父不想被卡住

什么时候保持 sync：

- 父没下一步可做、就等子的结果
- 用户在交互式终端前等着看进度

> *决策指引位置*：sync/async 完全靠 AgentTool 工具描述里的 "Foreground vs background" 一段说明，主 system prompt 完全不涉及。fork、coordinator、team 模式（详见 §1.5）等强制 async 的场景下这一段会被删掉或改写。

### 1.3 维度三：并发度 —— 单次 vs 并发

并发**不是 AgentTool 的参数**，而是父在某一轮模型回复里**写了几个 tool_use 块**的自然结果。

模型在一条 assistant message 里输出 N 个 `tool_use`（其中若干是 `AgentTool`），引擎按到达顺序立即 dispatch 每一个，不等本轮完整流式结束。这套逻辑在 `src/services/tools/StreamingToolExecutor.ts:40`（`StreamingToolExecutor` 类，注释原话："Executes tools as they stream in with concurrency control"）。

具体而言：

- `AgentTool` 标记为 concurrency-safe，多个 AgentTool 互相之间并行执行
- 「非 concurrency-safe」的工具（如某些 Bash 模式）必须独占
- 结果按**收到 tool_use 的顺序**回拼到 messages（不是按完成顺序），保证父侧看到的顺序稳定

因此「并发跑多个 sub-agent」根本不需要特殊 API：模型在一次回复里输出多个 AgentTool 调用，引擎就并发跑。详见 §4。

> *决策指引位置*：通用的「无依赖工具尽量并发」写在主 system prompt 里（对所有工具都成立）；针对 AgentTool 的「想并发就一条消息里发多个」则在 AgentTool 工具描述里再强调一次。两层互相加强。

### 1.4 维度四：文件系统隔离 —— 共享 cwd vs worktree

`isolation: "worktree"` 是 AgentTool 的可选参数。设置后引擎调 `git worktree add` 在 `.git/worktrees/agent-<id>/` 下挂一份独立工作副本，子 agent 的所有文件读写都基于这个目录（通过 `runWithCwdOverride` 改 cwd）。

完成后：

- 子没改文件 → worktree 被删（透明清理）
- 子改了文件 → worktree 和分支保留，路径返回给父

适合「让 agent 大胆改一遍，我审查后再决定要不要要」的探索性工作。**这个维度跟 isolate/fork、sync/async 完全正交**——可以 fork + worktree，也可以 isolate + async + worktree。

`isolation: "remote"` 是同一维度上的另一选项，但只对 `USER_TYPE === 'ant'` 暴露，外部用户看不到。

> `USER_TYPE === 'ant'` 是 Claude Code 在源码里用来识别 Anthropic 内部员工的标志（`ant` = Anthropic）。下文出现「仅 ant 用户可见」「仅内部」都是这个意思。

> *决策指引位置*：worktree 参数怎么用、何时用，只在 AgentTool 工具描述里有一行说明；主 system prompt 不提。

### 1.5 维度五：调度形态（默认未开启，一句话）

普通模式下父 agent 既规划又执行；`COORDINATOR_MODE` flag 开启时父被换成一份「只调度、不执行」的 system prompt；`agentSwarmsEnabled` 开启时还能起一个长驻 teammate 团队（跑在独立 tmux/iTerm pane 里）。这两条都需要 feature flag + env var 双开关，外部 npm 版本默认全关，本文不展开。

### 主干路径总结

外部用户日常碰到的多 agent 配置，就是这四个维度上的几种常见组合：

| 场景 | 上下文 | 执行 | 并发 | 文件 |
|---|---|---|---|---|
| 找个 specialist 做一次性任务 | isolate | sync | 单次 | 共享 |
| 同时起多路独立调查 | isolate | sync 或 async | 并发 | 共享 |
| 让 agent 试改一版别动 main | isolate | sync | 单次 | worktree |
| 后台跑长任务，自己接着干别的 | isolate | async | 单次 | 共享 |

---

## 2. 一个 SubAgent 的参数从哪里来

调用 `AgentTool` 时父传入的 schema 字段非常少（`AgentTool.tsx:83-85` 附近）：

```ts
{
  description: string,           // 3-5 词的任务描述
  prompt: string,                // 真正交给子的指令文本
  subagent_type?: string,        // 子的角色（不填 → general-purpose，或 fork）
  run_in_background?: boolean,
  isolation?: 'worktree' | 'remote',
  model?: string,
  name?: string,                 // 给子起个名字方便后续 SendMessage 续聊
}
```

但子启动时实际生效的参数远不止这些。下面逐项说每个参数是**写死的**、**由父决定的**还是**混合**。

### 2.1 System prompt

子的 system prompt 由 `subagent_type` 选中的 agent 定义提供。每个 agent 定义实现 `getSystemPrompt()` 方法，返回该角色的固定指令文本。Agent 定义来源有两类：

- **内置**：`src/tools/AgentTool/built-in/` 下的 6 个文件——编译进二进制：
  - `generalPurposeAgent.ts`（兜底）
  - `exploreAgent.ts`（代码探索）
  - `planAgent.ts`（实现规划）
  - `verificationAgent.ts`（结果校验）
  - `claudeCodeGuideAgent.ts`（Claude Code 用法答疑）
  - `statuslineSetup.ts`（状态栏配置）
- **用户自定义**：`~/.claude/agents/*.md`、`./.claude/agents/*.md`、插件目录下的 Markdown，由 `loadAgentsDir.ts` 读 frontmatter 加载——用户可写、可改、可通过 `/agents` 命令管理

**父 agent 在调用时不能直接覆盖子的 system prompt**——这是个有意的设计：子的角色和能力由用户/系统预先定义，父只是把任务派过去。父能影响的只有「选哪一种」。

> 例外：`fork` 路径下子继承父的 system prompt 字节流（不是子自己定义的）；此外 SDK 集成给了 `customSystemPrompt` 通道，CLI 里 `--append-system-prompt` 可以追加。这些都不是主干。

子的 system prompt 渲染时还会拼上 env info（cwd、git 状态、平台、模型 ID），跟主 agent 的 system prompt 拼法一致——这部分是引擎层做的，跟父 / 子的对话内容无关。

### 2.2 用户消息（messages 数组）

子的初始 messages 数组里**只有一条 user 消息**，内容就是父调用 AgentTool 时传过来的 `prompt` 字符串。

```
messages = [ { role: 'user', content: <父传的 prompt> } ]
```

这条 user message 是 isolate 路径下父 → 子之间**唯一的信息通道**。父的对话历史、CLAUDE.md、用户的原始提问、之前的工具结果……子全都看不到。

所以「父怎么写这个 prompt」是 isolate 模式下最重要的事——AgentTool 的工具描述（`src/tools/AgentTool/prompt.ts`）大段都在教模型「这个 prompt 要写得像跟一个刚走进房间的同事介绍背景」。这一段具体讲了什么，见**附录：AgentTool 的 "Writing the prompt" 节**。

`description` 字段不进 prompt，只用来在父的 UI 上显示一行任务标签。

> **fork 路径下完全相反**：父把自己整个 messages 数组都传给子作为 history，包括 messages[0] 的 CLAUDE.md / MEMORY.md、用户的原始提问、所有历史 user/assistant 消息和工具调用结果。子启动后看到的就是「父此刻的对话快照」。这也是为什么 fork 的 prompt 写成 directive 风格（"接着干 X"）就够了，不需要交代背景——背景全都在继承过来的 history 里。

### 2.3 工具集

子的工具集**不是父的工具集**，而是这样算出来的：

1. 取 agent 定义里的 `tools`（白名单，列出能用的工具名）和 `disallowedTools`（黑名单）
2. 用父的 `toolPermissionContext`，但把 `mode` 替换成 `selectedAgent.permissionMode ?? 'acceptEdits'`
3. 调 `assembleToolPool(workerPermissionContext, mcp.tools)` 组装出最终工具集

代码在 `AgentTool.tsx:573-577`。三个要点：

- **能用哪些工具**由 agent 定义决定，跟父手里有什么工具无关——父用 `plan` 模式不能干活，但派给子的 `permissionMode` 可以是 `acceptEdits`，子能真改文件
- 父**不能**通过 AgentTool 的参数去 override 子的工具集
- MCP 工具会按 server 是否在 agent 的允许列表里被过滤

这个设计意味着：sub-agent 是一种**能力上预先定义好的角色**，而不是「父的拷贝」。

> 例外：fork 路径下子直接用父的 exact 工具数组（`useExactTools: true`），这是为了字节级 cache 共享，跟普通路径完全相反。

### 2.4 模型

agent 定义里的 `model` 字段决定子用哪个模型：

- `'inherit'`（最常见）→ 沿用父此刻的模型
- 具体模型 ID（`'claude-sonnet-4-6'` 之类）→ 强制用那个

父调用时也可以通过 `model` 参数覆盖（除 fork 路径外，因为换模型会破坏 cache）。

agent 定义和父的参数都没指定时，落到主线程当前模型。

> 注意：「沿用父」跟 §1.1 里 fork 的「继承父上下文」不是一回事。这里只是模型 ID 跟父一样，子的对话历史还是空的。

### 2.5 其他参数

| 参数 | 谁决定 | 说明 |
|---|---|---|
| `description` | 父 | 仅 UI 显示用，不进 prompt |
| `isolation` | 父 | `'worktree'` 或 `'remote'`，对子的运行环境做隔离 |
| `run_in_background` | 父 | 设为 true 就走 async；coordinator/fork/KAIROS 模式下会被强制为 true |
| `name` | 父 | 给子起个名字，父侧记下，后续 SendMessage 可以按名字找它 |
| `cwd` | KAIROS 内部 | 覆盖子的 cwd；普通用户场景下不可见、父不能直接传 |
| permission mode | agent 定义 | 详见 §2.3 |
| `background` | agent 定义 | 字段值置 true 时，无论父怎么传 `run_in_background` 都强制 async |

### 一句话总结

> **父能定的只有 "做什么"（prompt）、"找谁做"（subagent_type）、"做完怎么交付"（isolation / run_in_background / name）；"用什么能力做"（system prompt + tools + model）由 agent 定义写死。**

这是 isolate 路径的核心约定。fork 路径反过来：父几乎不参与决定，子直接复用父此刻的全部上下文。

---

## 3. SubAgent 的结果是怎么回传的

### 3.1 Sync 路径（默认）

父调用 `AgentTool` 后，引擎在父进程内同步跑子的整个 agent loop（递归调用 `query()`）。子跑到 `stop_reason: 'end_turn'` 时拿到的那条 assistant 最终文本（不含 thinking、不含 tool_use），就是 AgentTool 这次工具调用的返回值。

引擎把这个字符串包成一个 `tool_result` 块，塞进父的 messages 数组：

```
父的 assistant 块: [tool_use { name: 'Agent', input: {prompt: '...'} }]
父的 user 块:      [tool_result { tool_use_id: '...', content: '<子的最终文本>' }]
```

接下来父进入下一次模型调用，看到这条 tool_result，由模型自己决定怎么用这个结果（继续干活、回复用户、再调一个工具）。

子的中间过程（thinking、工具调用、工具结果）**不进父的 messages**。父只看到「子说了句话」。

这跟普通工具调用（Read、Bash……）的语义**完全一致**——AgentTool 在父看来就是一个返回字符串的工具，引擎不为它特殊化。

### 3.2 Async 路径（`run_in_background: true` 或被强制 async 时）

async 路径下 AgentTool 的「返回值」不是子的最终文本，而是一个占位结构（`AgentTool.tsx:757`）：

```ts
{
  isAsync: true,
  status: 'async_launched',
  agentId: 'agent-...',
  description: '...',
  prompt: '...',
  outputFile: '/path/to/transcript',
  canReadOutputFile: boolean,
}
```

引擎把这个结构序列化成 tool_result 文本塞进父 messages。父在下一次模型调用里看到的就是「子已启动，agentId = …，输出文件 = …」。

子真正跑完时，引擎调 `enqueuePendingNotification`，构造一段 XML：

```xml
<task-notification>
  <task-id>agent-xyz</task-id>
  <status>completed|failed|killed</status>
  <summary>Agent "..." completed</summary>
  <result>...子的最终文本...</result>
  <usage>...token / 耗时...</usage>
</task-notification>
```

这段 XML 进**全局待处理通知队列**。父 `queryLoop` 的下一次 `while` 迭代顶部（即父下一次模型调用之前），src/query.ts:1631 附近把队列里所有 `mode === 'task-notification'` 的命令序列化成 **user-role 消息**塞进父的 messages 数组。如果父正空闲、没有活跃的 queryLoop，通知就一直挂在队列里，等用户开口启动新 trajectory 才会被消费。

父在那一轮拼好的 messages 里就会出现这样一条 user 消息（最小精简版本）：

```json
{
  "role": "user",
  "content": [
    {
      "type": "text",
      "text": "<task-notification>\n  <task-id>agent-a1b</task-id>\n  <status>completed</status>\n  <summary>Agent \"Investigate auth bug\" completed</summary>\n  <result>Found null pointer in src/auth/validate.ts:42 ...</result>\n</task-notification>"
    }
  ]
}
```

它在 messages 数组里跟普通 user 消息**结构完全一样**——`role: 'user'` + 一个 text 块，引擎和 API 都不为它特殊化。模型靠看到内容以 `<task-notification>` 开头来识别「这不是用户真发的话、是系统通知」。模型按通知里的 `<result>` 字段决定下一步。

几个关键点：

- **父看到结果的时机不是子完成的瞬间**，而是父 `queryLoop` 下一次 `while` 迭代顶部（同上一段）。coordinator 模式下父被专门教育成「launched 后就停在那、什么也别做、别 fabricate 结果」，正是因为父在通知到达前没有任何真实信息可用
- **task-notification 是 user-role 消息**，不是某种特殊事件类型。模型自己分辨「这是个通知、不是真用户在说话」是靠看 XML 标签
- 通知里的 `<result>` 字段就是 sync 路径下作为 tool_result 内容的那个字符串——同一个东西，只是通过不同信道送达
- **`outputFile`** 是子全程的 transcript 落盘路径。父需要细节时可以主动 Read 这个文件，但 prompt 明确警告："Don't peek"——读了就会把子的工具噪声拉进父上下文，丢了 async 的好处

### 3.3 Fork、remote 路径

外部默认未启用，简单说明：

- **fork**：`FORK_SUBAGENT` flag 开启后，所有 spawn 都被强制 async（`AgentTool.tsx:557` `forceAsync = isForkSubagentEnabled()`），结果走 §3.2 的 task-notification 通路
- **remote**：返回 `status: 'remote_launched'`，远端跑完时通过 WebSocket → adapter 转成 task-notification

### 3.4 续聊：SendMessageTool

不属于「结果回传」的范畴，但跟多 agent 关系密切：父或某个 teammate 可以用 `SendMessageTool` 给一个已经存在的 async agent 发后续消息（用 `agentId` 或 `name` 寻址）。这相当于「跟同一个 agent 续聊一轮」——它的所有上下文都保留着，不必从头交代。

这是 coordinator workflow 的核心模式：用一个 worker 做研究，研究完不要丢，而是继续 SendMessage 让它接着 implement——避免再起个新 agent 重新读一遍代码。

#### 消息怎么送到子那边

SendMessage 把消息送到目标 sub-agent 的途径，**跟 §3.2 的 task-notification 走的是两套不同的队列**。当目标处于 `running` 状态时（`SendMessageTool.ts:808-820`）：

```ts
if (task.status === 'running') {
  queuePendingMessage(agentId, input.message, setAppState)
  return { message: "Message queued for delivery to ${name} at its next tool round." }
}
```

`queuePendingMessage` 就是往目标 task 的 `task.pendingMessages` 数组里 push 一条字符串。子 agent 在自己 `queryLoop` 的下一次 `while` 迭代开始时（即下一次模型调用之前）调 `drainPendingMessages` 把队列掏空、构造成 user 消息追加到 messages 数组，然后才发下一次模型调用。

跟 task-notification 路径对比：

| 项 | task-notification（§3.2） | SendMessage → 运行中 sub-agent |
|---|---|---|
| 队列在哪 | **全局** `pendingCommands` 队列 | **每个 task 自己**的 `task.pendingMessages` 数组 |
| 消费者 | 父 agent | 这个 sub-agent 自己 |
| 触发时机 | 父 `queryLoop` 下一次迭代顶部 | 子 `queryLoop` 下一次迭代顶部 |
| 落地形态 | user 消息，含 `<task-notification>` XML | user 消息，纯文本（SendMessage 的 `message` 原文） |

「队列 + 下一次 `while` 迭代开始时 drain」这个模式是两边共享的，但**实例是分开的两套**——前者管「子完成时通知父」、后者管「外部给子续派任务」。

#### 子已经停了怎么办

如果目标 sub-agent 不是 `running` 状态（已经跑完返回过结果、或被 stop 过），SendMessage **不走队列**，而是直接调 `resumeAgentBackground`（SendMessageTool.ts:824 / :851）——从磁盘 transcript 把子的旧上下文恢复出来、把这条消息当作**新的 entry prompt** 启动子的新一轮 agent loop。这种情况下子等于「被新唤起」，不是「在已有 loop 里看到一条消息」。两条路径在 SendMessage 的返回信息里有不同措辞，方便父知道走了哪条。

---

## 4. 并发与结果汇总

### 4.1 怎么同时发起多个

不需要专门 API。**父在某一轮模型回复里输出多个 `tool_use` 块**就是并发。例如：

```
assistant message {
  tool_use { id: a, name: 'Agent', input: { prompt: '调查 auth 模块', subagent_type: 'Explore' } }
  tool_use { id: b, name: 'Agent', input: { prompt: '调查 logging 模块', subagent_type: 'Explore' } }
  tool_use { id: c, name: 'Agent', input: { prompt: '调查 config 模块', subagent_type: 'Explore' } }
}
```

模型自己在一次回复里决定输出几个 tool_use；引擎不知道也不在乎这是「故意并发」还是「就一个个调」。

关于「想要并发就一次回复里发多个 tool_use」这条规则**写在两个地方**：

- 主 system prompt（`prompts.ts:310`，`getUsingYourToolsSection`）—— 通用版："You can call multiple tools in a single response. If you intend to call multiple tools and there are no dependencies between them, make all independent tool calls in parallel..."。这是对所有工具的通用建议
- AgentTool 工具描述里有两条更具体的提醒：":248" 的 "Launch multiple agents concurrently whenever possible"、以及 ":271" 的 "If the user specifies that they want you to run agents 'in parallel', you MUST send a single message with multiple Agent tool use content blocks"

两层互相加强——模型即便看不到 AgentTool 描述里的提醒（比如 coordinator 模式下的 worker），主 system prompt 那一句仍然在，仍然知道可以一次发多个 tool_use。

### 4.2 引擎层怎么并发执行

入口：`src/services/tools/StreamingToolExecutor.ts:40`。注释里写得清楚：

> Executes tools as they stream in with concurrency control.
> - Concurrent-safe tools can execute in parallel with other concurrent-safe tools
> - Non-concurrent tools must execute alone (exclusive access)
> - Results are buffered and emitted in the order tools were received

关键机制：

1. **流式 dispatch**：流式协议下 assistant 消息是边收边解析的。引擎每解析到一个 `tool_use` 块的 `content_block_stop` 事件，就立即调 `addTool()` 把这个工具加入执行队列——**不等 assistant 消息全部流式结束**
2. **AgentTool 是 concurrency-safe**：多个 AgentTool 调用之间互不阻塞，都立即开始跑
3. **结果有序**：虽然子任务可能乱序完成，引擎的 buffer 保证最终拼回父 messages 的 tool_result 块**按 tool_use 收到的顺序**排列。模型不会看到乱序的结果对

这意味着 sync 多 agent 并发的总耗时 ≈ 最慢那个的耗时，不是各个相加。

### 4.3 结果如何汇总

**引擎层不汇总**——它只是把 N 个 tool_result 按顺序拼到一条 user message 里。「汇总」是父在**下一次模型调用**里看到这些 tool_result 时由模型自己做的。

具体形态分两种：

**全部 sync**：N 个 AgentTool 都同步跑，引擎等齐 N 个最终文本，拼成：

```
user 块: [
  tool_result { tool_use_id: a, content: '<子 A 的最终文本>' },
  tool_result { tool_use_id: b, content: '<子 B 的最终文本>' },
  tool_result { tool_use_id: c, content: '<子 C 的最终文本>' },
]
```

父的下一轮就看到这条 user message，模型在 thinking 里 synthesize 三个结果给用户。

**全部 async**：N 个 AgentTool 都返回 `async_launched` 占位（同一回合就拼回去了，跟 sync 一样按顺序），父立刻可以做别的事。N 个子各自跑完时各自把 `<task-notification>` 进队列。父 `queryLoop` 下一次 `while` 迭代顶部一次性 drain 所有已完成的通知，构造成多条 user 消息块塞进 messages：

```
user 块: [<task-notification> 子 A 完成 </task-notification>]
user 块: [<task-notification> 子 C 完成 </task-notification>]
（子 B 还没完成，没出现）
```

下下一次迭代再 drain 一次拿到子 B。也就是说**多个 async agent 的结果可能分批到达**，每次只能看到「目前完成了哪些」。

**混合**（部分 sync 部分 async）：sync 的那几个跟前面一样在本回合就回拼；async 的那几个走 task-notification 通路。父收到的是混合形态。

**关键事实**：「汇总」这件事**永远由模型在下一次模型调用里做**，不是引擎做的——引擎只负责把字符串塞进合适的 messages 位置。所以「汇总质量」取决于父 system prompt 是不是教过模型怎么合成多路结果（coordinator 的 system prompt 里大段就在讲这件事）。

### 4.4 实战注意点

这些是 AgentTool 描述（`src/tools/AgentTool/prompt.ts`）里反复教模型的事：

- **想并发就在一次回复里发多个**——分两次回复发等于串行，每次模型调用是同步的
- **没依赖才并发**——如果 B 的 prompt 要用 A 的结果，必须先等 A
- **并发多个 async 比并发多个 sync 更划算**——sync 多个还是要等齐才能进下一轮；async 多个父可以立刻继续干别的，结果各自到达后再各自处理
- **fork 多路特别便宜**——所有 fork 子共享父的 prompt cache 前缀（详见 §1.1），并发起 5 路 fork 远比 5 路 isolate 便宜

---

## Appendix：AgentTool 的 "Writing the prompt" 节

§2.2 说 isolate 路径下 `prompt` 字段是父 → 子之间唯一的信息通道，并提到 AgentTool 的工具描述里有一节专门教模型怎么写好这个 prompt。这一节大约 15 行（`src/tools/AgentTool/prompt.ts:99-113`，函数 `writingThePromptSection`），下面把核心内容译写出来。

### 总框架：「刚走进房间的同事」

> Brief the agent like a smart colleague who just walked into the room — it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters.

把子 agent 当成刚走进房间的聪明同事——他**没看过你跟用户的对话**、**不知道你已经试过什么**、**不知道这件事为什么重要**。父必须把这三件事讲清楚，子才知道该往哪走。

这个比喻把 isolate 路径的根本约束讲透了：子的能力（智商、经验）跟父相当，但**他完全没有共享的上下文**。所以 prompt 不是「指令」，而是「briefing」——既要派活，也要交代背景。

### 5 条具体要求

1. **讲做什么、也讲为什么** — 不光是任务本身，还要让子知道这个结果将用于什么。子据此判断该深挖到什么粒度
2. **讲已经排除了什么** — 你试过哪些路、为什么不行。避免子重复你走过的死路
3. **留出判断空间** — 给周围背景，让子在边界情况下能自己拍板。不要把指令收得太死，否则子遇到没预想到的情况就只能干瞪眼
4. **明确输出格式 / 长度** — 想要 200 字以内的总结、想要结构化报告，就在 prompt 里直说，否则子默认会写得很详细
5. **区分 lookup 和 investigation**
   - 已经知道要查什么 → 直接给 exact command（"run `grep -r foo src/`"）
   - 不确定要查什么 → 把问题原样交过去（"调查 src 下哪些文件提到了 foo"）。**不要预先指定步骤**——如果你对问题的前提判断错了，预定的步骤也就全废了

### 核心反模式：「Never delegate understanding」

AgentTool prompt 里最有力的一句教训：

> **Never delegate understanding.** Don't write "based on your findings, fix the bug" or "based on the research, implement it." Those phrases push synthesis onto the agent instead of doing it yourself.

「根据你的研究结果……」这种 prompt 等于父没有自己读懂研究结果、把综合理解的活推回给子。问题在于：

- 子并不知道父跟用户聊过什么，做不出真正符合用户诉求的综合
- 如果子之前是 isolate 跑的，那「your findings」根本不在子的上下文里——子会完全摸不着头脑
- 即便是续聊 / fork 路径下子有这些上下文，父没自己消化就直接转手，做出来的活质量上限就是子的临场猜测

对比：

| 反模式 | 正例 |
|---|---|
| 「根据研究结果修复那个 auth bug」 | 「修复 `src/auth/validate.ts:42` 的 null pointer：Session 的 user 字段在会话过期、token 还缓存时为 undefined。在访问 `user.id` 前加 null 检查，null 时返回 401」 |
| 「实现刚才讨论的方案」 | 「在 `src/api/handlers.ts` 新增 `POST /refresh` handler，调用 `RefreshTokenService.rotate()`，复用 `validateRequest()` 中间件做认证」 |

差别不在长度，**在父有没有自己读懂、然后把读懂的结果写进 prompt**。

### 一句总结

> Terse command-style prompts produce shallow, generic work.

简短的命令式 prompt，出来的活也是肤浅、千篇一律的。子产出的质量上限就是父 prompt 的质量上限。

### 顺带：coordinator 模式有个加强版

coordinator 模式（默认未启用）下，主 system prompt 里专门有 "Writing Worker Prompts" 一整节（`src/coordinator/coordinatorMode.ts:251-336`），比 AgentTool 的版本长得多，多出 "synthesize findings"、"add a purpose statement"、"continue vs spawn"、好/坏 prompt 完整对比等内容。本质是同一套思路的扩展版——一旦父被定位成纯调度者，"写好 prompt" 就成了它唯一的产出，所以要讲得更细。

---

## Appendix：默认未启用的几种形态

仅做索引，不展开。

| 形态 | 默认状态 | 启用条件 | 跟主干的关系 |
|---|---|---|---|
| **fork** | 关 | `FORK_SUBAGENT` 编译期 flag | 维度一的另一选项；启用后所有 spawn 强制 async |
| **coordinator** | 关 | `COORDINATOR_MODE` flag + `CLAUDE_CODE_COORDINATOR_MODE` env | 维度五；把主 agent 换成「只调度」的 system prompt，跟 fork 互斥 |
| **teammate / team** | 关 | `agentSwarmsEnabled` | 平行体系，不是 AgentTool 的派生——通过 `TeamCreateTool` 建一批长驻 teammate，跑在独立 tmux/iTerm pane |
| **remote** | 部分关 | `isolation: "remote"` 参数，仅 `USER_TYPE === 'ant'` 暴露 | 维度四的另一选项 |
| **KAIROS** | 关 | `KAIROS` flag | 强制所有 sub-agent async，保护长驻 assistant 的主 loop |

每种形态的代码位置：

- fork：`src/tools/AgentTool/forkSubagent.ts`（210 行）
- coordinator：`src/coordinator/coordinatorMode.ts`（369 行）
- teammate：`src/utils/teammate*.ts` + `src/utils/swarm/`（数千行）
- remote：`src/remote/` + `src/tasks/RemoteAgentTask/`
- KAIROS：散落多处，搜 `feature('KAIROS')`
