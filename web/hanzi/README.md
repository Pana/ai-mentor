# 小熊写字（汉字笔顺字典，网页版）

孩子说出想写的字或词，页面给出笔顺动画，以及拼音、部首、结构、意思和组词。以后集成到小熊伴学 iPad 端。

## 打开

页面由服务端提供，和作业 API 同一个地址：

```sh
cd server && npm start             # 本机：http://127.0.0.1:8787/hanzi/
scripts/lan-gateway.sh             # 同一 Wi-Fi 的 iPad：http://<Mac 的 IP>:8787/hanzi/
```

从服务端地址打开 `/hanzi/` 时会自动建立浏览器会话，不需要手动填写凭证。跨地址访问或会话失效时，仍可访问 `#token=<TUTOR_DEVICE_TOKEN>` 一次，或点右上角 ⚙︎ 填写。没有凭证时只显示笔顺，看不到拼音和释义。

## 能怎么说

- 直接说字词：“蝴蝶”“我想写长江”
- 用组词说明：“妈妈的妈”“高兴的兴”
- 用偏旁或拆字说明：“三点水的江”“木子李”“弓长张”
- 带拼音或声调：“第三声的 ma”。会选最常用的字，其他同音字显示在“是不是想写”里

## 实现

| 部分 | 来源 |
| --- | --- |
| 笔顺数据 | [hanzi-writer-data](https://github.com/chanind/hanzi-writer-data) 2.0.1（来自 Make Me a Hanzi，约 9000 字）。服务端第一次用到某个字时从 jsDelivr 下载，失败再试 unpkg，存到 `DATA_DIR/hanzi-strokes/`，以后从本地读 |
| 字卡、大字、部首、组词里的楷书字形 | 同一份笔顺数据画成 SVG。安卓手机和国产浏览器没有可用的楷体（CSS 里的“楷体”会退成宋体），这样各设备显示一致，也和田字格里写的字一致；数据到之前先用系统字体 |
| 书写动画、描写判定 | [Hanzi Writer](https://hanziwriter.org) 3.7.3（MIT），在 `vendor/` 里 |
| 理解孩子说的话，定出要写哪个字 | `POST /v1/hanzi/lookup`，调用服务端配置的模型（见 `server/src/hanzi.mjs`） |
| 拼音、部首、意思、组词 | 同一个模型。字已经确定时（如直接输入单个汉字）走 `POST /v1/hanzi/detail`，不做语义解读。两个接口的答案共用缓存：先查内存，再查 `littlebear.db` 的 `hanzi_answers` 表（重启不失效），最后才问模型。笔顺和笔画数只用笔顺数据，不用模型的回答 |
| 语音输入 | 浏览器录制 16 kHz 单声道 PCM，由服务端调用豆包流式语音识别模型 2.0 的一句话模式；未配置或不可用时明确提示，不调用浏览器 Web Speech API |
| 朗读 | 浏览器的 `speechSynthesis`（中文语音） |

功能：孩子开口的瞬间旧字的动画就停；能猜到目标字的输入（单个汉字、键盘输入的纯汉字词、“妈妈的妈”“天空的空”这类说法）先立刻显示笔顺，拼音释义由字典服务随后补全；整字连续书写、“下一笔”逐笔演示、三档速度、部首笔画变色、笔顺分解图（点一格会在大格子里亮出那一笔）、“我来写”（用手指或笔按笔顺描，写错会提示）、最近查过的字（存在本机浏览器）。

## 手机和各浏览器

页面按手机竖屏、手机横屏、iPad、桌面分别排版：手机上话筒和提示并排、示例词横向滑动；触屏设备查完字会把田字格滚进第一屏；田字格平时可以按住滚动页面，只有“我来写”时才拦住手势。

改了样式后跑一遍布局检查（WebKit、Chromium、Firefox × iPhone/Android 竖横屏、iPad、桌面，部分加深色模式）：

```sh
scripts/hanzi-browsers.sh                  # 起一个临时服务端，字典离线（只显示笔顺）
HANZI_AI=1 scripts/hanzi-browsers.sh       # 用 server/.env 里的模型，带拼音释义
HANZI_URL=http://127.0.0.1:8787/hanzi/ scripts/hanzi-browsers.sh   # 检查已经在跑的服务
scripts/hanzi-browsers.sh webkit           # 只跑一个内核
```

WebKit 对应 iOS/iPadOS 上的所有浏览器和 Mac Safari，Chromium 对应 Android Chrome、Edge、三星和多数国产浏览器，Firefox 只能按尺寸检查、模拟不了手机触屏。真机 Safari 的地址栏会占掉横屏高度，Playwright 测不出来，横屏和触摸手势另用 iOS 模拟器的 Safari 打开 `http://127.0.0.1:8787/hanzi/` 看一下。

已知限制：笔顺数据和课本的规范笔顺基本一致，个别字可能不同；数据里没有笔画名称（横、竖、撇……），暂时不显示。
