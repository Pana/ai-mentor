# 小熊读诗（古诗，网页版）

课本古诗按年级排好，学校的古诗考级按 1–6 级排好，诗库可以按朝代、体裁、选集、题材、诗人查找。每首诗都能请小熊“讲一讲”：诗里的画面、一句一句的意思、难懂的字词、诗人想说什么、写诗的小故事、认识诗人。以后集成到小熊伴学 iPad 端。

## 打开

页面由服务端提供，和作业 API 同一个地址：

```sh
cd server && npm start             # 本机：http://127.0.0.1:8787/poems/
scripts/lan-gateway.sh             # 同一 Wi-Fi 的 iPad：http://<Mac 的 IP>:8787/poems/
```

从服务端地址打开 `/poems/` 时会自动建立浏览器会话，“小熊讲一讲”不需要手动填凭证；跨地址访问时可以打开一次 `#token=<TUTOR_DEVICE_TOKEN>`。浏览和查找不需要凭证。

## 数据

| 部分 | 来源 |
| --- | --- |
| 课本古诗 | `server/src/poems-school.json`：统编版小学语文 1–6 年级的课文古诗、日积月累、古诗词诵读，课本版原文（和《全唐诗》常有不同，比如《静夜思》）。每首 `{grade, term, unit, kind, title, author, dynasty, lines, note}`，按课本顺序排，id 按顺序自动编（`s3a02` = 三年级上册第 2 首），所以**插入新诗会让后面的 id 变**，已经生成的讲解要重新生成 |
| 古诗考级 | `server/src/poems-levels.json`：学校发的古诗考级清单（2026.08 版）1–6 级，每首 `{level, title, author, dynasty, lines, note?}`，按清单顺序排。和课本原文一字不差的直接用课本那一首（id、讲解共用）；课本没有或课本是节选的用自己的 id（`k3a01` = 三级第 1 首自己的诗），原文照清单。页面在“课本古诗”的年级后面多一个“考级” |
| 诗库 | [chinese-poetry](https://github.com/chinese-poetry/chinese-poetry)（MIT）的全唐诗、全宋诗、全宋词，约 33 万首。`node scripts/poems/import.mjs <仓库目录>` 生成 `server/data/poems.db`（约 100 MB），部署时拷到服务器的 `DATA_DIR`。见下面“导入诗库” |
| 讲解 | 课本和考级的诗事先生成好，放在 `server/src/poems-explanations.json`，随代码发布，打开就有（见下面“事先生成”）。诗库里的诗第一次点“讲一讲”时由服务端配置的模型（`POEMS_MODEL_NAME`，默认 `MODEL_NAME`）生成，存在 `littlebear.db` 的 `poem_explanations` 表，以后直接读 |
| 拼音 | 讲解里带着拼音（按课本的读法）。没讲过的诗打开时页面单独请模型只标拼音（`POST /v1/poems/pinyin`，几秒），存在同一张表里。某一行的拼音个数和字数对不上时，那一行不显示拼音 |
| 朗读 | 火山引擎语音合成（和小熊老师同一个账号），题目和每一句各合成一段 mp3，存在 `DATA_DIR/poem-audio/`，同一句只合成一次；边放这一段边取下一段，读到哪句高亮哪句。服务端没配语音合成时用浏览器的 `speechSynthesis` |

### 导入诗库

```sh
git clone --depth 1 https://github.com/chinese-poetry/chinese-poetry ../chinese-poetry
node scripts/poems/import.mjs ../chinese-poetry
```

- 全唐诗和全宋诗是繁体，用 macOS 自带的 ICU 转成简体（`scripts/poems/hant2hans.swift`），所以只能在 Mac 上跑。ICU 按字转换，少数字（“嶽”、年号里的“乾”）在脚本的 `FIXES` 里修正。
- 括号里的校勘注（“一作……”“甲本作……”）和诗后面的出处说明都去掉了。
- 体裁按句子字数粗分：四句叫绝句、八句叫律诗、其他叫古诗（不看平仄）；《唐诗三百首》里标了体裁的用它的。宋词都算“词”，标题就是词牌。
- 名篇排在前面：按收进了几本选集（《唐诗三百首》《宋词三百首》《千家诗》《水墨唐诗》），再加上作者有几首诗进了选集。仓库 `rank/` 里的搜索结果数很乱（《静夜思》排在七千名开外），没用。
- 题材（送别、思乡、边塞……）只有《唐诗三百首》《宋词三百首》里的诗有，来自仓库的标签。

## 讲解怎么生成

`POST /v1/poems/explain {id}`：服务端按 id 查出诗文，连同标题、作者、朝代交给模型，要求返回固定格式的 JSON（提示词在 `server/src/poems.mjs`）。检查：

- 逐句意思的条数必须和诗的行数一样，不一样就重试一次，再不对就报错；
- 拼音每一行的个数必须和那一行的汉字数一样，不一样那一行就不显示拼音；
- 字词注释只留原文里真有的字词；
- “写诗的小故事”要求只写有可靠记载的，拿不准就留空。模型仍可能讲错，课本古诗的讲解以后要人过目（见 [路线图](../../docs/roadmap.md)）。

改了提示词或输出格式时，把 `EXPLAIN_VERSION` 加一，旧的讲解就不再使用。

### 事先生成

```sh
node --env-file=server/.env scripts/poems/pregenerate.mjs                  # 生成还没有的、诗文改过的、拼音不全的
node --env-file=server/.env scripts/poems/pregenerate.mjs --redo s1a01     # 重新生成这几首（逗号分隔）
```

结果写进 `server/src/poems-explanations.json`（`{id: {key, title, author, explanation}}`），按课本、考级的顺序排。可以直接改这个文件来修正讲解或拼音，改完提交就行；`key` 别动，它和诗文对不上时（诗文改了）这条就不用了，重新跑一次脚本。服务端先用这个文件，没有才查数据库、问模型。

“诗里的画面”下面留了插图的位置，现在显示“这里以后会有一幅画”。

## 已知限制

- 诗库的字句来自《全唐诗》，和课本、通行本常有不同；同题同作者的会提示“看课本版”。
- 超过 24 行或 400 字的长诗（如《长恨歌》）暂时不能讲解。
- 读诗的多音字由语音合成自己判断，个别字可能读得和拼音不一样。
- 超过 48 行或 800 字的诗不标拼音、不读。
