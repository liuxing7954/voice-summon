# VoiceSummon（喊我）

下楼摸鱼的时候，替你盯着办公室。有人叫你名字（或任何你设的关键词），立刻推到你手机上，附带**识别出来的原话**和**命中前后各 15 秒的录音**。

单二进制、无第三方依赖、无后端，Mac 本地跑，音频只在内存里滚动，命中才落盘。

---

## 一、装

1. 解压 `VoiceSummon-1.0.0-macOS.zip`，把 `VoiceSummon.app` 拖进 `/Applications`。
2. **第一次打开要右键 →「打开」**（未做苹果公证，双击会被 Gatekeeper 拦一次，之后正常）。
3. 系统会连弹两个授权框，都点**允许**：
   - 麦克风
   - 语音识别
4. 菜单栏出现波形图标 → 点开 → 加关键词 → 「开始监听」。

误点了「不允许」：

```
系统设置 → 隐私与安全性 → 麦克风 / 语音识别 → 勾上 VoiceSummon
```

如果提示「已损坏，无法打开」（ad-hoc 签名被 quarantine 标记）：

```bash
xattr -dr com.apple.quarantine /Applications/VoiceSummon.app
```

包内是通用二进制，Apple Silicon 和 Intel 都能跑：

```bash
lipo -info /Applications/VoiceSummon.app/Contents/MacOS/VoiceSummon
# arm64 x86_64
```

---

## 二、用

菜单栏面板就一页，默认只露最常用的：

| 区域 | 说明 |
| --- | --- |
| 顶部 | 监听开关、麦克风电平、最近听到的一句话、权限状态 |
| 关键词 | 想被叫到的名字/外号，可以加很多个 |
| 匹配强度 | 严格 / 同音 / 近音，默认「同音」；只要音对得上就选「近音」 |
| 通知渠道 | 每个渠道单独开关，点「设置」填参数 |
| 高级设置 | 前后录音秒数、静默期、录音格式、识别语言、开机启动等，默认折叠 |
| 最近命中 | 命中时间、原话、状态（发给了谁/失败原因），可直接播放录音 |

命中之后的动作顺序：

1. 命中瞬间记下录音的**帧位置**当锚点；
2. 等 `后 15 秒` 录完（面板显示「命中，15 秒后取录音」）；
3. 从环形缓冲里切 `前 15 秒 + 后 15 秒`，转成 16k 单声道 m4a；
4. 推送到所有启用的渠道，音频作为附件（Telegram / Webhook / 本机通知支持附件）。

录音落在：

```
~/Library/Application Support/VoiceSummon/Clips/2026-11-13/20261113-143205-张伟.m4a
```

超过保留天数（默认 14 天）自动清理。

---

## 三、渠道怎么配

| 渠道 | 需要填什么 | 在哪拿 |
| --- | --- | --- |
| **Bark** | Device Key（服务器留空即官方） | App Store 装 Bark，首页那串 key |
| **Server 酱** | SendKey | sct.ftqq.com 微信扫码登录 |
| **Telegram** | Bot Token + Chat ID | @BotFather 建 bot 拿 token；给 bot 发条消息后开 `https://api.telegram.org/bot<token>/getUpdates` 找 `chat.id` |
| **Webhook** | URL（+可选 token） | 自己服务器，收 `multipart/form-data` |
| **本机通知** | 不用配 | 弹系统通知，带录音附件 |

Webhook 收到的字段：

```
keyword     命中的关键词
text        识别文本（含上下文）
time        ISO8601 时间
via_pinyin  1 = 同音命中，0 = 原文命中
token       你在面板里填的 token（可选，做校验用）
audio       音频文件（m4a/wav）
```

> Bark 和 Server 酱只支持文本，音频不会带过去（这是它们接口的限制）。要音频就用 Telegram、Webhook 或本机通知。

面板底部有「测试通知」，配完先点一下，确认手机能收到。

---

## 四、参数说明

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| 命中前录音 | 15 秒 | 锚点之前留多长 |
| 命中后录音 | 15 秒 | 锚点之后留多长（命中后要等这么久才发） |
| 同一句话静默 | 30 秒 | 防止一句话反复触发 |
| 录音格式 | m4a | 30 秒约 100KB；wav 约 1MB |
| 只在本机识别 | 关 | 开了不联网、无频率限制，首次需要系统下载中文语音包 |
| 识别语言 | zh-CN | 中英混说建议保持 zh-CN |
| 阻止系统休眠 | 开 | 只挡「空闲休眠」，挡不住合盖 |
| 开机自动启动 | 关 | 走 SMAppService，需要 app 在 /Applications |

改「前/后录音」「识别语言」「本机识别」会自动重启监听链路（有 0.7 秒防抖），其它设置即时生效。

---

## 五、它是怎么工作的

```
麦克风 (AVAudioEngine)
   │ 每 2048 帧回调（音频线程）
   ├──► 环形缓冲：只留最近 40 秒，约 15MB 内存，不写盘
   └──► SFSpeechRecognizer：连续识别，50 秒滚动换会话
             │ partial 文本
             ▼
        关键词匹配（原文 → 带调拼音 → 无声调拼音）
             │ 命中
             ▼
        记帧号锚点 → 等后窗口 → 切片 → 重采样 16k 单声道 → m4a
             │
             ▼
        Bark / Server酱 / Telegram / Webhook / 本机通知
```

几个关键取舍：

- **锚点用帧号，不用墙钟**。音频回调有抖动，用时间戳对齐会漂；帧号是采样的绝对位置，切片永远准。
- **识别器必须滚动重启**。系统识别服务单会话上限约 1 分钟，到点不换会静默失效。这里每 50 秒换新会话，历史文本留 120 字做上下文。
- **不认字，认音**。名字被识别成同音字太常见，所以匹配分三档：
  - 严格：原文包含；
  - 同音（默认）：先比带声调拼音（`zhāng wěi`），再比无声调（`zhang wei`）——张伟 / 张玮 / 张维都算；
  - 近音：再把 zh→z、ch→c、sh→s、n/r→l、f→h、前后鼻音合并——张≈臧、李≈尼、飞≈黑、英≈因。
  单字关键词只做原文匹配（「喂/位/为」撞音太狠，全是假警报）。
- **切 16k 单声道**。语音只需要 8k~16k，体积是原始 48k 双声道的 1/6，手机听完全够。

---

## 六、已知限制（都是物理/系统级的）

- **合盖一定睡**。代码只能阻止空闲休眠；要合盖继续监听，得插电源 + 外接显示器（clamshell 模式），或者干脆开盖。
- **云端识别要联网**，且 Apple 对识别请求有频率限制。长时间挂着建议开「只在本机识别」。
- **匹配越宽松，误报越多**：「近音」档下别人说「李总说大力拿走」也可能撞上「李娜」。嫌吵就调回「同音」或「严格」。
- 面板上的「识别自检」会录 4 秒做一次完整识别，识别链路有问题时先点它。

### 识别不出东西时的排查顺序

1. 点「识别自检」，对着麦克风说一句话，看 5 秒后有没有结果。
2. 报「服务不可用」→ 检查网络，或在系统设置里确认「语音识别」权限已给。
3. 报「本机语音包未安装」→ 说明系统没下中文模型，此时会自动走云端；想用本机识别：
   ```
   系统设置 → 键盘 → 听写 → 语言 → 添加「普通话（中国大陆）」
   ```
   装完重启 VoiceSummon。
4. 面板顶部电平条不动 → 麦克风没采到声音，检查输入设备和权限。

---

## 七、命令行 / agent

app 里开了一个只监听 `127.0.0.1:18990` 的本地接口，`voicesummon` 就是它的薄包装（装在 `~/.local/bin`）。

```bash
voicesummon status          # 监听中？关键词？实时增益？
voicesummon start           # 开始监听
voicesummon stop            # 暂停
voicesummon hits            # 最近 10 次命中

voicesummon keyword add 张三 李四
voicesummon keyword remove 张三
voicesummon keyword list

voicesummon set cooldown 5          # 命中后静默几秒
voicesummon set preRoll 5           # 命中前录几秒
voicesummon set postRoll 5          # 命中后录几秒（也是通知延迟）
voicesummon set matchLevel fuzzy    # exact / homophone / fuzzy
voicesummon set maxBoostDB 24
voicesummon set audioUpload false
```

agent 可以直接打 HTTP：

```bash
curl 127.0.0.1:18990/status
curl -X POST 127.0.0.1:18990/stop
curl -X POST 127.0.0.1:18990/keywords -H 'Content-Type: application/json' -d '{"add":["张伟"]}'
curl -X POST 127.0.0.1:18990/config -H 'Content-Type: application/json' -d '{"cooldown":5}'
```

接口：`GET /status` `/hits` `/keywords`，`POST /start` `/stop` `/toggle` `/test-notify` `/keywords` `/config`。

## 八、自己构建

```bash
cd voice-summon
./scripts/make-app.sh      # 编译 arm64 + x86_64，lipo 合并，ad-hoc 签名，出 zip
```

产物：

```
dist/VoiceSummon.app
dist/VoiceSummon-1.0.0-macOS.zip
```

核心逻辑自测（不需要麦克风权限）：

```bash
swiftc -O -o /tmp/vs-selftest \
  Sources/VoiceSummon/{Support,Config,AudioHub,KeywordMatcher,ClipExporter,Notifier}.swift \
  Tests/SelfTest/main.swift
/tmp/vs-selftest
```

覆盖：文本归一化、拼音转换、关键词/同音匹配、48k 双声道→16k 单声道转码、m4a/wav 落盘、webhook multipart 报文、配置持久化。

代码结构：

```
Sources/VoiceSummon/
  VoiceSummonApp.swift   @main + 菜单栏入口
  PanelView.swift        面板 UI
  AppState.swift         状态机：监听、命中、裁切、推送
  AudioHub.swift         采集 + 环形缓冲 + 设备热插拔自愈
  Transcriber.swift      连续语音识别 + 会话滚动
  KeywordMatcher.swift   关键词 + 拼音匹配
  ClipExporter.swift     切片转码落盘
  Notifier.swift         五个通知渠道
  Config.swift           配置模型与持久化
  Support.swift          路径、日志、权限
```
