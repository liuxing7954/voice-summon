import AppKit
import ServiceManagement
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var state: AppState
    @State private var newKeyword = ""
    @State private var showAdvanced = false
    @State private var note: String?
    @State private var inputDevices: [AudioDeviceManager.Device] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    keywordSection
                    channelSection
                    advancedSection
                    hitSection
                    logSection
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 400, height: 620)
        .task {
            inputDevices = AudioDeviceManager.inputs()
        }
    }

    // MARK: - 顶部状态

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                Text(state.isRunning ? "正在监听" : "已暂停")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(state.isRunning ? "暂停" : "开始监听") { state.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                LevelBar(level: state.level)
                Text(String(format: "×%.1f", state.gainFactor))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(state.gainFactor > 1.5 ? .green : .secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Text(state.status)
                if !state.sessionState.isEmpty {
                    Text("·")
                    Text(state.sessionState)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !state.liveText.isEmpty {
                Text("👂 \(String(state.liveText.suffix(50)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(state.permissionSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !state.engineInfo.isEmpty {
                    Text("· \(state.engineInfo)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("权限设置") { Permissions.openMicrophoneSettings() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }

            if let error = state.lastError {
                Text("⚠️ \(error)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(14)
    }

    // MARK: - 关键词

    private var keywordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("听到这些词就叫我", icon: "ear")

            FlowLayout(spacing: 6) {
                ForEach(state.config.keywords, id: \.self) { keyword in
                    HStack(spacing: 4) {
                        Text(keyword).font(.system(size: 12))
                        Button {
                            state.removeKeyword(keyword)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
            }

            if state.config.keywords.isEmpty {
                Text("先加一个你自己的名字或外号，加了才会开始监听")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 6) {
                TextField("加一个关键词，比如你的名字", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitKeyword)
                Button("添加", action: commitKeyword)
                    .controlSize(.small)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("匹配强度", selection: $state.config.matchLevel) {
                    ForEach(MatchLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(state.config.matchLevel.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitKeyword() {
        state.addKeyword(newKeyword)
        newKeyword = ""
    }

    // MARK: - 渠道

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("通知渠道", icon: "paperplane")
                Spacer()
                Menu("添加") {
                    ForEach(Channel.Kind.allCases) { kind in
                        Button(kind.title) { state.addChannel(kind) }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 52)
                .font(.caption)
            }

            if state.config.channels.isEmpty {
                Text("还没有渠道，点「添加」选一个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(state.config.channels) { channel in
                ChannelRow(
                    channel: channelBinding(channel),
                    onDelete: { state.removeChannel(channel.id) }
                )
                Divider()
            }
        }
    }

    private func channelBinding(_ channel: Channel) -> Binding<Channel> {
        Binding(
            get: { state.config.channels.first(where: { $0.id == channel.id }) ?? channel },
            set: { newValue in
                guard let index = state.config.channels.firstIndex(where: { $0.id == channel.id }) else { return }
                state.config.channels[index] = newValue
            }
        )
    }

    // MARK: - 高级

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                numberRow("命中前录音", value: $state.config.preRoll, range: 1...120, unit: "秒")
                numberRow("命中后录音", value: $state.config.postRoll, range: 0...120, unit: "秒")
                numberRow("同一句话静默", value: $state.config.cooldown, range: 5...300, unit: "秒")

                Picker("录音格式", selection: $state.config.clipFormat) {
                    ForEach(ClipFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .font(.caption)

                Toggle("录音传公网，通知里带播放链接", isOn: $state.config.audioUpload.enabled)
                Text("默认传到 litterbox.catbox.moe，72 小时后自动删。链接是公开的，谁拿到都能听。Server 酱和 Bark 会带上它。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Toggle("远场增强（3 米外小声也抓）", isOn: $state.config.farFieldBoost)

                HStack {
                    Text("最大增益").font(.caption)
                    Slider(value: $state.config.maxBoostDB, in: 6...30, step: 1)
                    Text("\(Int(state.config.maxBoostDB)) dB")
                        .font(.caption.monospacedDigit())
                        .frame(width: 46, alignment: .trailing)
                }

                HStack {
                    Text("输入设备").font(.caption)
                    Picker("", selection: $state.config.inputDeviceUID) {
                        Text("系统默认").tag("")
                        ForEach(inputDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .font(.caption)
                }

                Text("增益那个 ×8 就是现在放大了 8 倍；换麦克风会重启采集，切完等两秒再说话。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Toggle("只在本机识别（不联网，省流量）", isOn: $state.config.onDeviceRecognition)
                Toggle("命中时本机响一声", isOn: $state.config.playSoundOnHit)
                Toggle("运行时阻止系统休眠", isOn: $state.config.preventSleep)
                Toggle("启动后自动开始监听", isOn: $state.config.autoStart)
                Toggle("开机自动启动", isOn: launchAtLoginBinding)

                HStack {
                    Text("识别语言").font(.caption)
                    TextField("zh-CN", text: $state.config.localeID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text("录音保留").font(.caption)
                    TextField("14", value: $state.config.keepDays, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 46)
                    Text("天").font(.caption)
                }

                Text("改「前/后录音」「语言」「本机识别」会自动重启监听，其它设置即时生效。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 8)
        } label: {
            sectionTitle("高级设置", icon: "slider.horizontal.3")
        }
    }

    private func numberRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title).font(.caption)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue)) \(unit)")
                .font(.caption.monospacedDigit())
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                        note = "已加入开机启动"
                    } else {
                        try SMAppService.mainApp.unregister()
                        note = "已取消开机启动"
                    }
                } catch {
                    note = "开机启动设置失败：\(error.localizedDescription)"
                }
            }
        )
    }

    // MARK: - 命中记录 / 日志

    @ViewBuilder
    private var hitSection: some View {
        if !state.hits.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.hits.prefix(6)) { hit in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(hit.keyword).font(.system(size: 12, weight: .semibold))
                                if hit.matchWay != "原文" {
                                    Text(hit.matchWay).font(.system(size: 9)).padding(.horizontal, 4)
                                        .background(Color.orange.opacity(0.2), in: Capsule())
                                }
                                Text(hit.date.clockText).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(hit.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text(hit.text.suffix(80)).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                if let url = hit.clipURL {
                                    Button("播放录音") { NSWorkspace.shared.open(url) }
                                        .buttonStyle(.link).font(.caption2)
                                    Button("在 Finder 里看") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                        .buttonStyle(.link).font(.caption2)
                                }
                            }
                        }
                        Divider()
                    }
                }
                .padding(.top, 6)
            } label: {
                sectionTitle("最近命中（\(state.hits.count)）", icon: "bell")
            }
        }
    }

    private var logSection: some View {
        DisclosureGroup {
            ScrollView {
                Text(Log.recentText)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 130)
        } label: {
            sectionTitle("运行日志", icon: "text.alignleft")
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("测试通知") {
                    Task {
                        let result = await state.sendTestNotification()
                        note = result
                    }
                }
                .controlSize(.small)
                Button("识别自检") {
                    note = "正在录 4 秒，对着麦克风说句话…"
                    Task {
                        let result = await state.runRecognitionProbe()
                        note = result
                    }
                }
                .controlSize(.small)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("录音文件夹") { state.openClipsFolder() }
                    .controlSize(.small)
                Button("复制诊断") {
                    state.copyDiagnostics()
                    note = "诊断信息已复制到剪贴板"
                }
                .controlSize(.small)
                Spacer()
                Text(AppVersion.display)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .help(AppVersion.diagnostic)
            }
        }
        .padding(12)
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
    }
}

// MARK: - 组件

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(level > 0.85 ? Color.red : (level > 0.5 ? Color.orange : Color.green))
                    .frame(width: max(2, proxy.size.width * CGFloat(min(max(level, 0), 1))))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: 5)
    }
}

struct ChannelRow: View {
    @Binding var channel: Channel
    var onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: $channel.enabled).labelsHidden().controlSize(.mini)
                Text(channel.kind.shortTitle).font(.system(size: 12, weight: .medium))
                if channel.kind.supportsAudio {
                    Text("带录音").font(.system(size: 9))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer()
                Button(expanded ? "收起" : "设置") { expanded.toggle() }
                    .buttonStyle(.link).font(.caption2)
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    switch channel.kind {
                    case .bark:
                        field("Device Key", $channel.token, "Bark App 首页那串 key")
                        HStack(spacing: 6) {
                            Text("提醒级别").font(.caption2).frame(width: 82, alignment: .leading)
                            Picker("", selection: $channel.barkLevel) {
                                Text("普通").tag("active")
                                Text("时效性（穿透专注模式）").tag("timeSensitive")
                                Text("关键警报（穿透静音）").tag("critical")
                            }
                            .labelsHidden()
                            .font(.system(size: 11))
                        }
                        field("服务器", $channel.endpoint, "留空用 https://api.day.app")
                    case .serverChan:
                        field("SendKey", $channel.token, "SCT 开头，官方地址已内置")
                    case .telegram:
                        field("Bot Token", $channel.token, "123456:AA...")
                        field("Chat ID", $channel.chatID, "你的 user id 或群 id")
                    case .wecomBot:
                        field("Webhook Key", $channel.token, "群机器人 Webhook 里 key= 后面那段")
                        Text("文字 + 录音文件都会发到群里，手机上点开就能听。")
                            .font(.caption2).foregroundStyle(.secondary)
                    case .webhook:
                        field("URL", $channel.endpoint, "https://example.com/hook")
                        field("Token（可选）", $channel.token, "会随表单一起 POST")
                    case .macNotification:
                        Text("弹本机通知，带录音附件，不需要配置。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    private func field(_ title: String, _ binding: Binding<String>, _ placeholder: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).frame(width: 82, alignment: .leading)
            TextField("", text: binding, prompt: Text(placeholder).font(.caption2))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }
}

/// 自动换行的胶囊布局。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
