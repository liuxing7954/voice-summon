# VoiceSummon

> The few minutes you're away from your desk, someone calls your name — your phone buzzes.

[中文](README.md) | English

## Why this exists

There's a particularly enthusiastic colleague at the office: the moment I leave my desk, he starts calling my name across the room — and offering some unsolicited commentary about me while he's at it. By the time I come back with my coffee, the show is over and I'm left clueless.

So I built a tireless ear. It listens all day, and the moment someone says my name it pushes **the exact words** plus **the few seconds of audio around them** straight to my phone. Who was looking for me, and what they said — no more guessing.

## What it does

- Lives in the menu bar, mic always on, the last 40 seconds of audio **roll in memory only, never written to disk**
- Multiple keywords, with homophone / near-homophone matching (张伟 ≈ 张玮 ≈ 张维 ≈ 臧伟)
- On a hit, cuts `N seconds before + N seconds after` and encodes 16k mono m4a (~100KB for 30s)
- Pushes the transcript + clip to Bark / Server Chan / WeCom bot / Telegram / Webhook / local notification
- Catches a whisper from 3 meters away: adaptive gain + high-pass filter + keyword biasing for the recognizer
- Single binary, zero third-party dependencies, universal (Apple Silicon + Intel)

## Install

1. Unzip, drag `VoiceSummon.app` into `/Applications`
2. **First launch: right-click → Open** (not notarized, Gatekeeper blocks a plain double-click once)
3. Allow both dialogs: Microphone and Speech Recognition
4. A waveform icon appears in the menu bar → add keywords → start listening

Denied by accident: System Settings → Privacy & Security → Microphone / Speech Recognition → enable VoiceSummon.

The `voicesummon` CLI installs itself to `~/.local/bin` — no manual setup.

## Configuration

One panel, advanced options collapsed by default. The ones you'll actually touch:

| Setting | Default | Notes |
| --- | --- | --- |
| Keywords | — | Names/nicknames to listen for, as many as you like |
| Match level | fuzzy | exact / homophone / fuzzy |
| Seconds before | 5 | Pre-roll of the clip |
| Seconds after | 5 | Post-roll, also the main source of notification latency |
| Cooldown | 5 | Suppresses repeats of the same sentence |
| Far-field boost | on | Adaptive gain, up to +24dB |
| Clip format | m4a | ~100KB per 30s |

Add notification channels as needed, each with its own toggle. Bark supports the `critical` level, which punches through silent mode and Focus.

## CLI

```bash
voicesummon status                 # state, keywords, live gain
voicesummon start | stop | toggle
voicesummon hits                   # last 10 hits

voicesummon keyword add Alice Bob
voicesummon keyword remove Alice

voicesummon set cooldown 5
voicesummon set postRoll 5
voicesummon set matchLevel fuzzy   # exact / homophone / fuzzy
voicesummon test                   # send a test notification
```

There's also a local-only HTTP API on `127.0.0.1:18990`, handy for agents:

```bash
curl 127.0.0.1:18990/status
curl -X POST 127.0.0.1:18990/stop
curl -X POST 127.0.0.1:18990/keywords -H 'Content-Type: application/json' -d '{"add":["Alice"]}'
```

## How it works

```
Microphone (AVAudioEngine)
  │ every 2048 frames
  ├──► ring buffer: last 40s, memory only
  └──► far-field boost (AGC + high-pass) → SFSpeechRecognizer, session rolled every 50s
            │ partial transcript
            ▼
       keyword match (literal → tonal pinyin → toneless → fuzzy)
            │ hit
            ▼
       frame anchor → wait post-roll → slice → 16k mono m4a
            │
            ▼
       Bark / Server Chan / WeCom / Telegram / Webhook / local
```

A few deliberate choices:

- **Anchors are frame numbers, not wall clock.** Audio callbacks jitter; frame counts are absolute and slicing stays exact.
- **The recognizer must be restarted on a rolling basis.** A single system session caps out around one minute and fails silently past it.
- **Matching cares about sound, not characters.** Tonal pinyin first, then toneless, then fuzzy (zh/z, n/l, dropped nasal endings).
- **Text-only channels fire immediately.** Bark / Server Chan don't wait for the clip; only attachment-capable channels wait for the post-roll.

## Known limits

- Closing the lid puts the Mac to sleep, and no code can stop that. Clamshell listening needs power + an external display.
- Cloud recognition needs a network and is rate-limited. For all-day use, switch on on-device recognition (requires the Chinese speech assets).
- Looser matching means more false positives — under `fuzzy`, "记一下" also hits "季".
- Public clip hosting defaults to the author's own short-lived storage (auto-purged after 7 days). Point it at your own uploader for long-term use.

## Build

```bash
./scripts/make-app.sh      # build arm64 + x86_64, sign, zip
./scripts/install.sh       # build + install to /Applications + relaunch
```

Self-test (no microphone permission needed):

```bash
swiftc -O -o /tmp/vs-selftest \
  Sources/VoiceSummon/{Support,Config,AudioHub,KeywordMatcher,ClipExporter,Notifier}.swift \
  Tests/SelfTest/main.swift
/tmp/vs-selftest
```

Requires macOS 14+ and Xcode Command Line Tools. No third-party packages.

## License

MIT
