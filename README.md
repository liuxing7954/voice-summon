# VoiceSummon（喊我）

> 离开工位的那几分钟，有人叫你，手机会响。

中文 | [English](README.en.md)

## 为什么要做这个

公司里有位特别热情的同事：我前脚离开工位，他后脚就开始大声找我，顺带对我进行一些客观评价。等我端着咖啡回来，热闹早散了，只剩一脸茫然。

所以我做了个不知疲倦的耳朵。它一直听着，听到我的名字就立刻把「那句原话 + 前后各几秒的录音」推到我手机上——谁在找、说了什么，一目了然。

## 它能做什么

- 常驻菜单栏，麦克风一直采，最近 40 秒音频**只在内存里滚动，不落盘**
- 关键词可配多个，支持同音/近音匹配（张伟 ≈ 张玮 ≈ 张维 ≈ 臧伟）
- 命中后裁出「前 N 秒 + 后 N 秒」，转成 16k 单声道 m4a（30 秒约 100KB）
- 推送识别文字 + 录音：Bark / Server 酱 / 企业微信机器人 / Telegram / Webhook / 本机通知
- 3 米外压着嗓子说话也能抓：自适应增益 + 高通滤波 + 给识别器灌关键词热词
- 单二进制，无第三方依赖，Apple Silicon / Intel 通用

## 安装

1. 下载 `VoiceSummon-*.zip`，解压后把 `VoiceSummon.app` 拖进「应用程序」
2. **第一次右键 → 打开**（未公证，双击会被 Gatekeeper 拦一次）
3. 麦克风、语音识别两个弹窗都点允许
4. 菜单栏出现波形图标 → 点开 → 加关键词 → 开始监听

误点了「不允许」：系统设置 → 隐私与安全性 → 麦克风 / 语音识别 → 勾上 VoiceSummon。

命令行工具会随 app 一起自动装到 `~/.local/bin/voicesummon`，不需要手动配置。

## 配置

面板一页搞定，高级项默认折叠。常用参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| 关键词 | — | 想被叫到的名字/外号，可加多个 |
| 匹配强度 | 近音 | 严格 / 同音 / 近音 |
| 命中前录音 | 5 秒 | 锚点之前留多长 |
| 命中后录音 | 5 秒 | 锚点之后留多长，也是通知延迟的大头 |
| 同一句话静默 | 5 秒 | 防止一句话反复触发 |
| 远场增强 | 开 | 自适应增益，最多 +24dB |
| 录音格式 | m4a | 30 秒约 100KB |

通知渠道按需添加，每个渠道单独开关。Bark 支持「关键警报」级别，能穿透静音和专注模式。

## 命令行

```bash
voicesummon status                 # 状态、关键词、实时增益
voicesummon start | stop | toggle  # 开关监听
voicesummon hits                   # 最近 10 次命中

voicesummon keyword add 张三 李四
voicesummon keyword remove 张三

voicesummon set cooldown 5
voicesummon set postRoll 5
voicesummon set matchLevel fuzzy   # exact / homophone / fuzzy
voicesummon test                   # 发条测试通知
```

也开了个只监听 `127.0.0.1:18990` 的 HTTP 接口，方便 agent 直接调：

```bash
curl 127.0.0.1:18990/status
curl -X POST 127.0.0.1:18990/stop
curl -X POST 127.0.0.1:18990/keywords -H 'Content-Type: application/json' -d '{"add":["张伟"]}'
```

## 工作原理

```
麦克风 (AVAudioEngine)
  │ 每 2048 帧
  ├──► 环形缓冲：最近 40 秒，只在内存
  └──► 远场增强（AGC + 高通）→ SFSpeechRecognizer，50 秒滚动换会话
            │ partial 文本
            ▼
       关键词匹配（原文 → 带调拼音 → 无声调 → 模糊音）
            │ 命中
            ▼
       记帧号锚点 → 等后窗口 → 切片 → 16k 单声道 m4a
            │
            ▼
       Bark / Server酱 / 企业微信 / Telegram / Webhook / 本机通知
```

几个关键取舍：

- **锚点用帧号不用墙钟**：音频回调有抖动，帧号是采样的绝对位置，切片永远准
- **识别器必须滚动重启**：系统单会话上限约 1 分钟，到点不换会静默失效
- **匹配不认字只认音**：先比带调拼音，再比无声调，近音档还会合并 zh/z、n/l、前后鼻音
- **纯文字渠道先发**：Bark / Server 酱 不等录音，命中即推；要音频的渠道才等后窗口

## 已知限制

- 合盖一定睡，代码拦不住。要合盖继续听，得插电 + 外接显示器
- 云端识别要联网，且有频率限制；长时间挂着建议开「只在本机识别」（需要系统装中文语音包）
- 匹配越宽松误报越多，「近音」档下「记一下」也会撞上「季」
- 录音传公网默认走作者自建的临时存储，7 天自动清理；要长期用请换成自己的上传服务

## 构建

```bash
./scripts/make-app.sh      # 编译 arm64 + x86_64，签名，出 zip
./scripts/install.sh       # 编译 + 装到 /Applications + 重启
```

自测（不需要麦克风权限）：

```bash
swiftc -O -o /tmp/vs-selftest \
  Sources/VoiceSummon/{Support,Config,AudioHub,KeywordMatcher,ClipExporter,Notifier}.swift \
  Tests/SelfTest/main.swift
/tmp/vs-selftest
```

需要 macOS 14+ 和 Xcode Command Line Tools，没有第三方依赖。

## License

MIT
