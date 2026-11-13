## VoiceSummon

离开工位的那几分钟，有人叫你，手机会响。菜单栏常驻，听到你的名字就把「识别原话 + 命中前后各几秒录音」推过来。

**下载下面的 `VoiceSummon-*-macOS.zip`** · Universal（Apple Silicon + Intel）· 约 1MB

### 安装

1. 解压，把 `VoiceSummon.app` 拖进「应用程序」
2. **第一次右键 → 打开**（未公证，双击会被 Gatekeeper 拦一次）
3. 麦克风和语音识别两个弹窗都点允许
4. 菜单栏出现波形图标 → 点开 → 加关键词 → 开始监听

命令行工具会自动装到 `~/.local/bin/voicesummon`。

### 要求

macOS 14+。音频只在内存里滚动（最近 40 秒），命中才落盘。

---

Menu-bar sidekick that listens while you're away from your desk: when someone says your name, your phone gets the transcript plus the few seconds of audio around the hit.

Universal binary (Apple Silicon + Intel), macOS 14+. Not notarized — **right-click → Open** on first launch.

```bash
voicesummon status
voicesummon keyword add Alice
voicesummon start
```
