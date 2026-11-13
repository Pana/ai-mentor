# 小熊老师：语音老师技术方案

2026-11-13 起草。状态：第一版（P0 语音 + P1 白板的最小闭环）已实现。网页版用替身上游在 Chromium 里端到端跑通；**火山和 DeepSeek 尚未接真实服务测过，iPad Safari 未真机验收，iPad 原生端未编译。**

## 目标

孩子在 iPad 上和“小熊老师”直接语音对话，体验对标 Claude 的语音模式：不用按住按钮，随时可以打断，有实时字幕。和普通语音助手的区别有两点：

1. **懂学情**：知道孩子的年级、最近的作业、完成状态和家长批改；以后还要知道各科进度和知识点掌握情况。
2. **图文并茂**：讲题时边说边在白板上画，数学用竖式、数轴、点子图、线段图、钟面等板书讲解。

## 已定的决定

| 问题 | 决定 | 理由 |
| --- | --- | --- |
| 语音供应商 | 火山引擎豆包语音 | 2026-11-13 确定 |
| 接入方式 | 自己编排：流式 ASR → LLM → 流式 TTS（不用端到端模型或 RTC 托管） | 每段白板变化要和那一句话对齐，只有自己编排才能按段送 TTS、按段下发白板。端到端实时语音 3.0 正式开放后可以评估接入闲聊部分 |
| LLM | 沿用 DeepSeek（`TEACHER_MODEL_NAME`，默认 `MODEL_NAME`） | 2026-11-13 确定 |
| 形态 | 先做网页版：服务端在 `/teacher/` 提供，iPad 用 Safari 打开（[说明](../web/teacher/README.md)）。原生页面的代码保留在 `ipad/…/Teacher/`，未编译 | 2026-11-13 确定。开发环境没有 Swift 工具链，网页版可以在这里实际运行和检查；等真机试过再决定是在 App 里内嵌这个页面，还是继续做原生 |

## 链路

```
iPad                                   服务端 /v1/teacher                     上游
麦克风 ─ 系统回声消除 ─ VAD ─ 16k PCM ──▶ 流式 ASR 会话 ───────────────────▶ 火山 bigmodel_async
                                         ◀── 实时字幕 input.transcript.partial
                    input.audio.end ──▶ 定稿 ─▶ 提示词（规则 + 学情 + 历史 + 白板）─▶ DeepSeek（stream）
                                         ◀── 一行一段 JSON，逐段校验白板 op
白板 ◀─ segment {speech, board, await} ◀─┤
扬声器 ◀─ 24k PCM（4 字节头）◀───────────┴─ 每段送合成 ──────────────────────▶ 火山 TTS（HTTP Chunked）
```

- **打断**：小熊说话或思考时孩子开口，客户端立即停播、发 `response.cancel`；服务端中止模型和合成请求。点一下小熊也能打断。
- **只记孩子听到的**：回复生成得比播放快得多，孩子在第 2 段打断时，服务端往往已经生成完全部 4 段。所以取消时客户端报告“播到了第几段”（`played`），服务端把这次回复在对话历史里截到那一段，并把白板状态退回到孩子看到的样子。下一轮模型才知道自己实际讲到了哪里。
- **回声**：采音和播放走同一个音频上下文，开启回声消除（网页用浏览器的 `echoCancellation`，原生用同一个 `AVAudioEngine` 的 voice processing）；小熊说话期间开口检测的起始阈值再提高 8 dB，避免残余回声被当成插话。
- **同步**：一段的白板变化在这段开始播放时执行，这段音频播完才开始下一段，所以画面跟着声音走。没有 TTS 时，每段按字数停留（每字 0.22 秒，至少 1.5 秒）。
- **降级**：没配 ASR 只能打字；没配 TTS 只显示字幕；没配模型且 `VOICE_MOCK=true` 时回复固定的竖式演示。
- **音频中断**：来电、Siri、插拔耳机或切到后台会让系统停掉音频引擎。回到前台或中断结束后自动重建；麦克风恢复不了时退到只播放，并提示孩子改用打字。

## 协议 `littlebear.teacher.v1`

WebSocket `/v1/teacher`，凭证是一期的设备凭证（家长或孩子设备）。原生客户端用 `Authorization: Bearer <凭证>`；浏览器不能给 WebSocket 加请求头，改为提供两个子协议 `littlebear.teacher.v1, littlebear.token.<凭证>`，服务端只回选 `littlebear.teacher.v1`。

上行：

| 消息 | 说明 |
| --- | --- |
| `{"type":"session.start","childId":"…"}` | 必须先发；服务端加载该孩子的学情 |
| 二进制帧 | 孩子说话时的 PCM16LE、16 kHz、单声道音频，第一帧开启一次识别 |
| `{"type":"input.audio.end","turn":3}` / `input.audio.cancel` | 一句话说完 / 丢弃（说到一半静音、误触发） |
| `{"type":"input.text","text":"…","turn":4}` | 打字或点建议；正在听的那句话会被丢弃 |
| `{"type":"response.cancel","response":5,"played":2}` | 打断。带 `response` 时只取消那一次回复，避免迟到的取消误杀新回复；`played` 是已经开始播放的段数，服务端据此截断历史、回退白板 |

`turn` 是客户端自己递增的句子编号，服务端在定稿和 `response.start` 里原样带回。客户端只展示“最新一句、且之后没有被打断”的回复，其余的按编号取消。这样孩子连着说两句、或在识别还没出结果时点小熊打断，都不会播出过时的回复。

下行：

| 消息 | 说明 |
| --- | --- |
| `hello` → `session.ready {child, audio:{input, output}}` | `input`/`output` 为 null 表示没配 ASR/TTS |
| `input.transcript.partial / final {turn} / empty {turn}` | 实时字幕、定稿、没听到内容 |
| `response.start {response, turn}` | 一次回复开始；`response` 是递增编号 |
| `segment {response, index, speech, board, await}` | 一段要说的话和白板 op；`await` 表示在等孩子回答 |
| 二进制帧 | 前 4 字节：uint16 回复编号、uint16 段号（大端），后面是 PCM16LE（每帧都是完整的 16 位采样），采样率见 `audio.output` |
| `segment.audio.done {response, index, audio}` | 这段音频发完；`audio:false` 表示没有声音 |
| `response.done` / `response.cancelled` / `error {code}` | |

## 白板 DSL

模型不画坐标，只放语义化元素，客户端负责排版和动画（`server/src/board.mjs` 校验；网页 `web/teacher/board.mjs`、原生 `ipad/…/Teacher/TeacherBoard.swift` 渲染）。竖式的结果、进位和退位由客户端自己计算，不用模型给的数。

操作：`clear`、`add {el}`、`update {id, set}`、`remove {id}`。服务端把 `update` 合并成完整元素再下发，所以客户端收到的 `add`/`update` 都是整个元素。最多 12 个元素，无效 op 直接丢弃，不影响同段的其他内容。

| 元素 | 字段 | 用途 |
| --- | --- | --- |
| `text` | `text`，`style`: title / body / answer / hint | 题目、结论、提示 |
| `vertical` | `a`、`b`、`operator`（+ − ×）、`reveal`（从个位起写出几位）、`focus`（高亮哪一位） | 竖式，进位和退位标记自动画 |
| `number_line` | `from`、`to`、`step`、`marks`、`jumps [{from,to,label}]` | 数轴、跳数 |
| `dots` | `groups`、`per`、`highlight`、`label` | 乘法、除法、分组 |
| `bar` | `rows [{label, parts [{value, label}]}]`、`total` | 线段图，未知量 `value: null` 画成虚线 |
| `clock` | `hour`、`minute`、`label` | 认识时间 |

讲题时用 `update` 一步步推进，例如先只列竖式，问孩子个位得几，再 `{"op":"update","id":"v1","set":{"reveal":1,"focus":0}}` 写出个位。

## 学情

第一版只用已有的事实数据：孩子姓名年级、最近 7 天到明天的作业（科目、内容、状态、交作业日期、家长评分和评语），以摘要形式放进系统提示词。

后续（P2）：

- `subject_progress`：教材版本和当前单元，先由家长设置，再尝试从作业内容推断。
- `skill_mastery`：知识点掌握度，来源是批改结果、讲题时孩子的回答。
- `learning_events` 流水和每次对话的摘要，作为小熊的长期记忆（“上次那道进位加法会了吗？”）。
- 数据变多后改为工具调用按需查询，不再整段塞进提示词。

## 教学和安全

- 作业题引导式：一次只推进一步，问完等孩子回答，不直接说答案；好奇心问题可以直接讲。
- 只聊学习，不索取个人信息；学情、白板和孩子的话都按数据处理，不能改变规则。
- 服务端不保存音频和对话内容。家长端查看对话摘要、使用时长限制放到后续。

## 分期

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| P0 语音 | 流式 ASR + TTS、VAD、打断、字幕、学情摘要 | 网页版已实现，替身上游下跑通；待接真实服务和真机 |
| P1 白板 | 协议 segments、6 种元素、按段同步 | 网页版已实现并截图检查；待真实模型输出 |
| P2 学情画像 | 进度、掌握度、对话记忆、家长端查看 | 未开始 |
| P3 扩展 | 孩子在白板上写、拍题讲解、汉字笔顺（复用小熊写字）、语文英语的图文讲解 | 未开始 |

## 验收前要做的

1. 配好 `VOLC_ASR_API_KEY`、`VOLC_TTS_SPEAKER` 和 DeepSeek，在 iPad Safari 上打开 `/teacher/`，按 [网页版说明](../web/teacher/README.md) 的清单验：首句延迟、回声下的误打断、打断是否干脆、白板和语音是否对齐。用孩子的声音测识别（童声错误率通常明显高于成人），必要时配数学术语热词。
2. 原生端要用时：Mac 上 `xcodegen generate` 后编译、跑 `TeacherTests`（没有在 Xcode 里编译过，只做过代码审查）。
3. 检查 DeepSeek 的输出：是否守住“一行一段”格式、白板 op 的合法率、是否直接说出答案。先用 10 道二三年级数学题冒烟，再建分年级的评测集（调研建议 300–500 题），换模型时用它对比。

已知的取舍：检测到孩子开口就取消整段回复。咳嗽或环境噪声误触发时，这段回复会丢。真机上如果误打断多，改成“先暂停，识别出文字才取消，否则继续播”。

## 参考

[K12 数字老师 Agent：开源模型选型调研](https://claude.ai/artifact/Rjd6Sgm5jMS7waDGki23Xz)（2026-11-13，数字未逐页复核）。和本方案一致的部分：级联语音、say/draw 结构化白板、服务端校验、按段同步、不让模型给坐标。从中采纳、尚未实现的：

- **验算**：流程拆成解题、代码验算、生成讲解。现在模型一遍输出；竖式的结果由 iPad 自己计算，不会错，但应用题的口头结论可能算错。
- **拍题**：题图直接交给多模态模型，不先 OCR。
- **模型升级路径**：先用 API，量大后评估单卡自部署。大脑走 OpenAI 兼容接口，换模型只改环境变量。
