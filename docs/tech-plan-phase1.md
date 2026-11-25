# 一期技术方案：作业管理

日期：2026-11-09
对应需求：[一期需求：作业管理](./prd-phase1.md)
状态（2026-11-24 整理）：M1–M4 已实现；iOS 的 M5 奖励记账与计时已实现，系统级锁定仍待付费开发者账号及 Family Controls 权限；Android 奖励锁定已实现并有真机验证记录（见下文）。M6 推送尚未实现；已有连接部署服务端的真机记录，不能再标为“部署待服务器”。下文里程碑保留原计划，平台实现差异以本段及对应章节为准。
- 服务端：`server/src/api.mjs`；2026-11-24 重跑整个服务端 `npm test`，83 项通过（包含作业、网关、汉字、语音老师等，不仅是作业 API）。
- 客户端：`ipad/LittleBearTutor/Phase1/`，同步层单元测试；`scripts/phase1-e2e.sh` 在 iPhone 和 iPad 两个模拟器上跑通“录入（真实 AI 整理）→ 配对 → 拍照提交 → 批注打分 → 孩子看批改”。
- 推送暂由前台长轮询代替（`/v1/changes?wait=25`，iOS 与安卓相同）：App 在前台时，另一台设备的改动 1 秒内可见。

## 1. 总体结构

```
iPhone（家长）──┐                      ┌── 模型供应商（只用于 AI 整理作业）
                ├── HTTPS ── 服务端 ───┤
iPad（孩子）────┘    （数据 + 文件）    └── APNs（计划，未实现）
```

| 部分 | 现状 | 一期要做 |
| --- | --- | --- |
| `server/` | 无状态网关：`/v1/tutor`、`/v1/voice`，单一设备凭证 | 增加数据存储、文件存储、设备配对与角色、作业相关接口、同步、推送 |
| `ipad/` | iPad 客户端，数据存在本机 JSON | 改成**同一个 App 支持两种角色**：iPhone 上是家长端，iPad 上是孩子端；本机数据变成服务端的缓存 |
| `app/` | Android 旧版辅导 | 2026-11-13 起实现与 iOS 相同的作业管理，同一个 App 支持家长和孩子两种角色，见 [安卓一期](./android-phase1.md) |

## 2. 服务端

### 2.1 技术选择

- 继续使用 Node.js 22，不引入第三方 npm 依赖，与现有网关一致。
- 数据库：内置的 `node:sqlite`（Node 22.13 起不再需要实验参数，但仍会打印实验警告）。单家庭、低并发，SQLite 足够。部署时把 Node 固定到 22 LTS 的具体版本。
- 文件（照片、录音）：存在服务端磁盘目录，数据库只记录文件 ID、类型、大小和 SHA-256。
- 现有的 `/v1/tutor` 和 `/v1/voice` 保留不变；新接口放在同一个进程里，按路径分发。

### 2.2 设备、角色与鉴权

现在整个网关只有一个 `TUTOR_DEVICE_TOKEN`。一期需要区分家长设备和孩子设备：

| 角色 | 获得方式 | 权限 |
| --- | --- | --- |
| `parent` | 首次部署时由环境变量 `PARENT_BOOTSTRAP_TOKEN` 在家长 iPhone 上换取设备凭证 | 全部读写 |
| `child` | 家长端生成 6 位配对码（10 分钟有效），在 iPad 上输入后换取设备凭证 | 读自己家庭的作业；提交、打卡、使用奖励；不能改作业、批改或改规则 |

- 每台设备一条凭证，服务端只存凭证的哈希；家长端可以查看和撤销设备。
- 所有请求 `Authorization: Bearer <设备凭证>`，沿用现有的常量时间比较和限流。
- 现有 `TUTOR_DEVICE_TOKEN` 继续用于旧的 `/v1/tutor`，迁移完成后再合并。

### 2.3 数据模型

所有 ID 由客户端生成 UUID，重复提交同一个 ID 视为同一次操作（幂等）。每条记录有 `updatedAt` 和递增的 `version`。

| 表 | 主要字段 |
| --- | --- |
| `families` | id, name, timezone（Asia/Shanghai） |
| `children` | id, familyId, name, grade, avatar |
| `devices` | id, familyId, role, childId?, tokenHash, apnsToken?, lastSeenAt, revokedAt? |
| `homework` | id, childId, subject（CHINESE / MATH / ENGLISH / OTHER）, date（显示在哪一天）, dueDate?（老师的截止日期）, content, rawText?, mode（OFFLINE / ONLINE）, onlineKind?（TIMER / RECORDING / VIDEO）, durationMinutes?, parentTodo?, status, source（PASTE / MANUAL / ROUTINE）, routineId?, attachmentIds[] |
| `routines` | id, childId, title, subject, mode, onlineKind?, durationMinutes?, quantity?, weekdays[], active, sortOrder |
| `submissions` | id, homeworkId, attempt（第几次提交）, fileIds[], submittedAt（设备时间）, receivedAt（服务端时间）, onTime |
| `reviews` | id, submissionId, grade（EXCELLENT / GOOD / FAIR / TRY_AGAIN）, comment, requireCorrection, annotations（每页一层）, reviewedAt |
| `reward_rules` | familyId, finishTime（每天完成时间，默认 19:30）, onTime, gradeExcellent, gradeGood, gradeFair, checkin, streak7, dailyCap, windowStart, windowEnd, requireAllSubmitted |
| `reward_ledger` | id, childId, minutes（正为获得，负为使用）, reason, refId, createdAt；`(reason, refId)` 唯一，保证不重复入账 |
| `files` | id, familyId, kind（IMAGE / AUDIO / VIDEO / ANNOTATION）, mime, bytes, sha256, createdAt |
| `changes` | seq（自增）, familyId, entity, entityId, op（UPSERT / DELETE） |

- **每天坚持**不预先生成多天的作业，而是在孩子当天第一次请求时，按 `routines` 生成当天的 `homework`（`source = ROUTINE`，同一天同一项只生成一次），这样暂停和修改只影响以后的日子。
- 每个孩子的 `routines` 中 `active = true` 的最多 5 条，由服务端校验，超出返回 409 `routine_limit`。
- 批注存成矢量笔迹（PencilKit 的 `PKDrawing` 数据）作为 `ANNOTATION` 文件，同时生成一张合成后的 PNG 供 iPad 直接显示。

### 2.4 状态机

```
NOT_STARTED ──提交──▶ SUBMITTED ──批改──▶ REVIEWED
                         ▲               └─要求订正─▶ NEEDS_CORRECTION ──再提交──┘
```

- 只有服务端改状态；客户端提交或批改后由服务端返回新状态。
- 只需计时、不需要家长看的每天坚持，打卡直接到 `REVIEWED`（无评分）。

### 2.5 奖励计算

奖励在服务端计算，写入 `reward_ledger`，客户端只显示余额和明细。

| 事件 | 入账 |
| --- | --- |
| 提交且 `onTime` | `reason = ON_TIME, refId = homeworkId`，每项作业只算第一次提交 |
| 批改评分 | `reason = GRADE, refId = homeworkId`；订正后评分提高时，再入一条差额（`refId` 带上 attempt） |
| 每天坚持打卡 | `reason = CHECKIN, refId = homeworkId` |
| 连续 7 天 | `reason = STREAK7, refId = routineId + 日期` |
| 使用奖励时间 | `reason = SPEND`，负数，见 4.3 |

**按时**：`submittedAt` 早于当天的 `finishTime`。用设备时间判断，这样断网排队后补传的提交不会被误判为迟交；家庭场景下信任设备时间，同时记录 `receivedAt` 供核对。

### 2.6 接口

所有接口前缀 `/v1`，JSON 请求和响应；文件单独上传。

| 方法与路径 | 角色 | 说明 |
| --- | --- | --- |
| `POST /devices/bootstrap` | — | 用 `PARENT_BOOTSTRAP_TOKEN` 换取家长设备凭证 |
| `POST /devices/pairing-codes` | parent | 生成孩子设备配对码 |
| `POST /devices/pair` | — | iPad 用配对码换取孩子设备凭证 |
| `GET /devices`、`DELETE /devices/:id` | parent | 查看、撤销设备 |
| `PUT /devices/self/push-token` | 全部 | 登记 APNs 推送 token |
| `PUT /devices/self/lock` | child | 安卓平板的奖励时间锁定心跳，见 3.6 |
| `GET/PUT /children/:id` 等 | parent | 孩子管理 |
| `POST /homework/parse` | parent | AI 整理粘贴的文字，见 2.7 |
| `POST /homework` | parent | 批量新建（接受数组） |
| `PATCH /homework/:id`、`DELETE /homework/:id` | parent | 修改、删除 |
| `GET /homework?childId&from&to` | 全部 | 按日期范围查询，孩子设备只能查到自己家的孩子 |
| `GET/POST/PATCH/DELETE /routines` | parent（读：全部） | 每天坚持 |
| `PUT /files/:id` | 全部 | 上传一个文件，`Content-Type` 为 `image/jpeg`、`audio/mp4`、`video/mp4` 或 `application/octet-stream`（批注）；边收边写盘 |
| `GET /files/:id` | 全部 | 下载文件，只能下载自己家庭的；支持 `Range`，视频可以边下边播 |
| `PUT /files/:id/thumb`、`GET /files/:id/thumb` | 全部 | 照片的缩略图，由上传照片的 App 生成（服务端没有图片解码），列表先显示它；没有时 404，App 改为加载原图 |
| `POST /homework/:id/submissions` | child | 提交，引用已上传的文件 ID |
| `POST /submissions/:id/review` | parent | 批改：评分、评语、批注文件、是否要求订正 |
| `GET/PUT /reward-rules` | parent（读：全部） | 奖励规则 |
| `GET /rewards?childId` | 全部 | 余额与明细 |
| `POST /rewards/sessions` | child | 开始使用奖励时间，服务端检查规则后扣减并返回可用分钟数 |
| `GET /changes?since=<seq>` | 全部 | 增量同步，见 2.8 |

上传大小限制：照片单张 2MB（JPEG，客户端缩放压缩：作业照片长边 1400 像素、质量 70，一般 300KB 左右；另传一张长边 480 像素的缩略图），录音单条 10MB，视频单个 300MB（客户端压缩到 480p、约 0.8 Mbps，30 分钟约 200MB），单次提交最多 6 页。为了能传完大视频，服务端整个请求的超时是 30 分钟（请求头仍须 10 秒内到齐）。

### 2.7 AI 整理作业：`POST /homework/parse`

请求：`{ text, date, childIds, imageFileIds? }`。响应：

```json
{
  "items": [
    {
      "subject": "MATH",
      "content": "口算本第 12 页，第 1–20 题，竖式写在本子上。",
      "dueText": "明早交",
      "dueDate": "2026-11-10",
      "mode": "OFFLINE",
      "parentTodo": null
    }
  ],
  "message": "拆成了 3 项，请核对"
}
```

- 复用现有网关的模型配置、JSON 模式、空回复重试和超时、取消逻辑，新增一套专用提示词。
- 提示词要求：按科目拆分；去掉寒暄、口语和表情代码，但**不改变作业量和要求**（页码、题号、遍数原样保留）；不确定的科目标 `OTHER`；签字、检查一类单独放进 `parentTodo`；只根据原文推算截止时间，没提就为空。
- 服务端校验返回结构，非法时返回 502，不把模型原文透传给客户端。
- 只整理不保存：家长确认后，客户端再调用 `POST /homework` 保存。原文作为 `rawText` 一起保存。
- 用 `scripts/provider-check.mjs` 增加若干条真实风格的群消息样例做回归。

### 2.8 同步

- 服务端是唯一数据来源。每次写入都在 `changes` 表追加一条记录。
- 客户端保存上次同步到的 `seq`，在打开 App、回到前台、收到推送时调用 `GET /changes?since=`，再按变更去拉对应记录。App 在前台时每 30 秒同步一次。
- 写操作在线时直接调用接口；断网时，孩子端的**提交和打卡**放进本机队列（带客户端 UUID），联网后按顺序重发，幂等保证不会重复。家长端的写操作要求在线。
- 冲突很少（家长写作业，孩子写提交，双方不写同一条记录），一律以服务端为准。

### 2.9 推送通知

- 使用 APNs（基于 token 的 `.p8` 密钥，HTTP/2 直接调用，不引入依赖）。**需要付费的 Apple Developer 账号。**
- 推送只带简短文字和需要同步的提示，不带作业内容；客户端收到后通过 `/changes` 拉取。
- “接近完成时间还没交”的提醒由服务端定时检查发出。

### 2.10 部署

- 家长的 iPhone 不一定在家里 Wi-Fi 下，服务端需要公网 HTTPS：云服务器 + Caddy（自动证书）反向代理到 Node 进程。
- 数据库和文件目录每日备份；日志只记录方法、路径模板、状态码和耗时。
- `scripts/lan-gateway.sh` 继续用于本机联调。

## 3. 客户端（iOS）

### 3.1 一个 App，两种角色

沿用 `ipad/` 工程（XcodeGen），App 改为同时支持 iPhone 和 iPad：

- 首次启动选择“我是家长”（输入家长凭证）或“这是孩子的 iPad”（输入配对码），角色存入 Keychain。
- 根视图按**角色**而不是设备尺寸切换：家长端为底部标签栏（作业 / 录入 / 每天坚持 / 奖励），孩子端为横屏顶部导航（今天 / 全部作业 / 我的进步）。
- 现有的辅导、练习、知识证据、语音等代码保留，一期孩子端不放入口。

### 3.2 本机存储

- 现在的 `Family` 本机 JSON 改为“服务端数据的缓存 + 待上传队列”，保留读取旧数据的兼容，首次登录后提示家长是否把旧的本机作业上传（或直接丢弃示例数据）。
- 照片和录音缓存在 App 的 Caches 目录，按文件 ID 命名。家长端同步后在后台预先下载等批改作业的缩略图和照片，打开时不用再等下载。

### 3.3 家长端要点

- 粘贴：读取剪贴板（`UIPasteboard`，iOS 会弹系统提示），也支持手动输入。
- 图片：`PhotosPicker` 和相机；上传前统一缩放、转 JPEG，沿用现有 `PhotoCapture`、`ImageCropping`。
- 批注：在照片上叠加 `PKCanvasView`，工具限定为红笔、打勾、圈出、文字和撤销；保存 `PKDrawing` 数据和合成后的 PNG。

### 3.4 孩子端要点

- 拍照提交：沿用现有相机预览，改为可以拍多页、逐页预览删除；用亮度和清晰度做简单检测，提示重拍。
- 在线作业：计时（离开页面暂停，复用现有学习计时）和录音（`AVAudioRecorder`，AAC，上传后删除本机副本）。

### 3.5 奖励时间：屏幕使用时间

使用 FamilyControls、ManagedSettings、DeviceActivity 三个框架，只在孩子的 iPad 上运行：

1. **授权**：孩子的 iPad 登录的是孩子自己的 Apple ID（2026-11-09 确认），使用 `AuthorizationCenter.requestAuthorization(for: .child)`。授权时需要家长在 iPad 上用家长的 Apple ID 批准；之后孩子不能自行撤销授权，也不能自行删除 App。前提是孩子的账号在家长的家庭共享里，首次授权前要确认这一点。
2. **选择 App**：在 iPad 上家长验证后，用 `FamilyActivityPicker` 选择允许的动画和游戏 App。选择结果是设备本地的不透明 token，不能在 iPhone 上选好再传过来，所以这一步留在 iPad 上做。
3. **平时锁住**：`ManagedSettingsStore` 对选中的 App 设置 shield。
4. **使用奖励时间**：孩子选 5 / 10 / 15 分钟 → 调用 `POST /rewards/sessions` 由服务端检查规则并扣减 → 本机解除 shield，并用 `DeviceActivityCenter` 启动一个对应时长的监控。
5. **到时重新锁上**：DeviceActivity Monitor 扩展（新增 App Extension target）在时间结束时重新设置 shield；App 被杀掉也能生效。

权限：需要 `com.apple.developer.family-controls` entitlement。开发和真机调试可以直接用；TestFlight 和 App Store 分发需要先向苹果申请，**需要尽早提交申请**。

### 3.6 奖励时间：安卓（无障碍服务）

2026-11-21 选定，代码在 `app/.../homework/RewardLock.kt`（判断逻辑、服务）和 `RewardLockSettings.kt`（家长设置）：

1. **开启**：孩子平板的“家长 → 家长设置”（先过锁屏密码）里分四步：开启无障碍服务“小熊伴学 · 奖励时间锁定”；选择要锁住的 App（列出桌面上的 App，不含桌面和系统设置）；开启“设备管理器”防止卸载（不申请任何管理策略）；小米平板打开自启动、省电策略**必须**选“无限制”（见第 5 条）。
2. **平时锁住**：服务监听前台窗口变化。前台是被锁的 App 且不在奖励时间里，就回到桌面，并在屏幕中间显示一张提示卡片（无障碍悬浮层；Toast 在没有通知权限时会被系统丢掉）。孩子一直停在游戏里时没有窗口事件，所以每 5 秒再查一次，并在奖励时间结束时立刻查一次。
3. **使用奖励时间**：服务端扣减成功后，本机用开机后经过的时间（`elapsedRealtime`）加开机次数计时，改系统日期延长不了；重启后奖励时间结束。时间按平板算，不按孩子算；时间没用完时再开一次会接着往后加。
4. **防止关掉锁定**：有 App 被锁时，系统设置类 App（设置、手机管家、安装器、权限管理）的页面里只要出现“小熊伴学”，就退回桌面。这样能挡住无障碍列表、应用信息、设备管理器和卸载确认页。副作用：孩子在设置的应用列表里滑到小熊伴学时也会被退出。家长验证通过后，到关闭家长设置之前（最多 10 分钟）不锁任何东西。
5. **HyperOS 的冻结**：省电策略是默认的“智能限制后台运行”时，别的 App 一启动，系统就会冻结小熊伴学的进程，而且不再解冻（`dumpsys greezer` 里的 `LM FZ`），锁定随之失效。就算有无障碍服务和前台服务也一样。改成“无限制”后不再被冻结，重装后这个设置也还在。小熊伴学读不到这个设置，所以服务每 5 秒自查一次：`uptimeMillis` 中间断了 20 秒以上（深度睡眠时它会停，被冻结时不会），就记为“被暂停过”，在家长设置里提醒改成“无限制”。
6. **局限**：设置页靠文字识别，换了系统版本可能漏掉某个页面，会进系统设置的孩子还是可能找到别的路关掉服务；HyperOS 自带的家长模式能不能挡住进设置，还没验证。真机上无障碍服务曾在一夜之间被关掉，原因没查到：不是强制停止，不是重装，平板也没重启。所以加了心跳（下一条）。

7. **心跳**（2026-11-22）：平板在这些时候向 `PUT /v1/devices/self/lock` 报告锁定状态：小熊伴学回到前台时、无障碍服务连上和被关掉时（关掉会解绑服务，趁进程还在时报告）、服务运行中每 30 分钟、检测到被暂停时，以及每小时一次闹钟（不唤醒设备，服务关了也照常跑）。服务端存在 `devices.lock_state`，`/v1/me` 给家长返回 `locks`；只有家长看到的内容变了才写入变化流。安卓和 iPhone 家长端在每个标签页顶部显示提醒，奖励页列出每台平板的状态。还没有推送：家长要打开 App 才看到。

真机验证（2026-11-21/22，小米平板 9 Pro，HyperOS 4，Android 17）：被锁的 App 在平板闲置 5、30、60 秒后打开都在 1 秒内被送回桌面；小熊伴学的应用信息页被挡住；连部署的服务端开 5 分钟奖励时间，期间学习强国可以正常使用，结束后 0.4 秒被退回桌面，余额扣 5 分钟。没验证的：“被暂停过”提醒的真机触发、多个孩子共用一台平板、重启后奖励时间结束。

## 4. 里程碑

| 阶段 | 内容 | 完成标准 |
| --- | --- | --- |
| M1 服务端 | SQLite 与文件存储、设备配对与角色、作业 / 每天坚持 / 提交 / 批改 / 奖励接口、`/homework/parse`、`/changes` | `npm test` 覆盖权限、幂等、状态机、奖励计算、每天坚持上限；`provider-check` 增加群消息样例 |
| M2 iOS 基础 | 角色选择与配对、同步层与待上传队列、本机缓存迁移 | 模拟器上 iPhone 和 iPad 两个实例连同一个本机服务端，数据能互相看到 |
| M3 家长端 | 录入与 AI 整理、完成情况、批注与打分、每天坚持、奖励规则 | 按设计稿完成，UI 测试覆盖录入到批改 |
| M4 孩子端 | 今天、全部作业、拍照提交、在线计时与录音、看批改、订正 | 按设计稿完成，端到端测试覆盖“录入 → 提交 → 批改 → 订正” |
| M5 奖励 | 奖励余额与明细、屏幕使用时间锁定与解锁、DeviceActivity 扩展 | 真机上验证锁定、解锁、到时重新锁上 |
| M6 上线准备 | APNs 推送、HTTPS 部署与备份、真机验收 | 按需求文档第 11 节逐项验收 |

M1 和 M2 是其他阶段的基础；M3、M4 可以并行；M5 依赖孩子端；M6 依赖付费开发者账号与服务器。

## 5. 风险与依赖

| 事项 | 影响 | 应对 |
| --- | --- | --- |
| 没有付费 Apple Developer 账号 | 无法推送、无法 TestFlight，屏幕使用时间无法正式分发 | 先用个人账号做开发与真机调试；推送前用前台轮询顶替 |
| Family Controls 分发权限审批 | 审批时间不确定 | 开发开始时就提交申请 |
| 孩子的 Apple ID 不在家庭共享里 | `.child` 授权会失败 | 首次授权前确认孩子账号已加入家长的家庭共享 |
| AI 整理改动了作业量 | 孩子少做或多做作业 | 提示词明确保留页码和题号；家长逐项核对后才保存；保留原文对照 |
| 服务端开始保存孩子的作业照片和录音 | 隐私要求提高 | 仅 HTTPS；文件按家庭隔离；日志不含内容；提供删除；明确保留期限 |
| `node:sqlite` 仍标记为实验特性 | API 可能变动 | 固定 Node 版本；数据访问集中在一个模块里，必要时可替换 |
