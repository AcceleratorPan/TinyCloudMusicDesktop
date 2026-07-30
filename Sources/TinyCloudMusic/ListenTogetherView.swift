import AppKit
import SwiftUI

struct ListenTogetherView: View {
    @Bindable var controller: ListenTogetherController
    @Bindable var player: PlayerController

    @Environment(\.dismiss) private var dismiss
    @State private var mode = EntryMode.create
    @State private var invitationText = ""
    @State private var inviterID = ""
    @State private var inputError: String?
    @State private var invitationCopied = false
    @State private var showingEndConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection

                if let room = controller.room {
                    if case .recoveryAvailable = controller.phase {
                        recoverySection(room)
                    } else {
                        roomSections(room)
                    }
                } else {
                    entrySections
                }
            }
            .formStyle(.grouped)
            .navigationTitle("一起听")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismiss.callAsFunction) {
                        Image(systemName: "xmark")
                    }
                    .help("关闭一起听")
                    .accessibilityLabel("关闭一起听")
                }
            }
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 520, idealHeight: 620)
        .alert("结束一起听？", isPresented: $showingEndConfirmation) {
            Button("结束", role: .destructive) {
                Task { await controller.endRoom() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("房间内所有成员将退出一起听。")
        }
        .onChange(of: visibleError) { _, message in
            guard let message else { return }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
        .onChange(of: controller.invitationURL) { _, _ in
            invitationCopied = false
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let status = phaseStatus ?? controller.statusMessage {
            Section("状态") {
                HStack(spacing: 10) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(statusColor)
                            .accessibilityHidden(true)
                    }
                    Text(status)
                }
                .accessibilityElement(children: .combine)
            }
        }

        if let message = visibleError {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var entrySections: some View {
        Section {
            Picker("操作", selection: $mode) {
                Text("创建房间").tag(EntryMode.create)
                Text("加入房间").tag(EntryMode.join)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        switch mode {
        case .create:
            Section("当前播放") {
                currentSongRow
                Button {
                    Task { await controller.createRoom() }
                } label: {
                    Label("创建一起听房间", systemImage: "person.2.fill")
                }
                .disabled(player.currentSong == nil || isBusy)
            }
        case .join:
            Section("邀请") {
                TextField("邀请链接或房间 ID", text: $invitationText)
                    .onChange(of: invitationText) { _, _ in inputError = nil }
                    .onSubmit(submitInvitation)
                    .accessibilityLabel("邀请链接或房间 ID")
                if !isOfficialInvitationURL {
                    TextField("邀请者 ID", text: $inviterID)
                        .onChange(of: inviterID) { _, _ in inputError = nil }
                        .onSubmit(submitInvitation)
                        .accessibilityLabel("邀请者 ID")
                }
                HStack {
                    Button(action: checkInvitation) {
                        Label("检查邀请", systemImage: "checkmark.shield")
                    }
                    .disabled(invitationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)

                    if let invitation = readyInvitation, invitation == parsedInvitation {
                        Button {
                            Task { await controller.join(invitation) }
                        } label: {
                            Label("加入房间", systemImage: "rectangle.portrait.and.arrow.forward")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recoverySection(_ room: ListenTogetherRoom) -> some View {
        Section("待恢复房间") {
            LabeledContent("身份", value: roleText(room.role))
            LabeledContent("成员", value: "\(room.members.count) 人")
            durationRow(room)
            Button {
                controller.recover()
            } label: {
                Label("恢复一起听", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)

            Button(role: .destructive) {
                showingEndConfirmation = true
            } label: {
                Label("结束一起听", systemImage: "xmark.circle")
            }
        }
    }

    @ViewBuilder
    private func roomSections(_ room: ListenTogetherRoom) -> some View {
        Section("房间") {
            LabeledContent("身份", value: roleText(room.role))
            LabeledContent("成员", value: "\(room.members.count) 人")
            durationRow(room)
            currentSongRow
        }

        if !room.members.isEmpty {
            Section("成员") {
                ForEach(room.members) { member in
                    HStack {
                        Label(member.nickname, systemImage: member.id == room.creatorID ? "crown.fill" : "person.fill")
                        Spacer()
                        if member.id == room.creatorID {
                            Text("房主")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }

        if room.role == .host, let invitationURL = controller.invitationURL {
            Section("邀请") {
                ShareLink(item: invitationURL) {
                    Label("分享邀请", systemImage: "square.and.arrow.up")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    invitationCopied = NSPasteboard.general.setString(
                        invitationURL.absoluteString,
                        forType: .string
                    )
                } label: {
                    Label(
                        invitationCopied ? "邀请链接已复制" : "复制邀请链接",
                        systemImage: invitationCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                .help(invitationCopied ? "邀请链接已复制" : "复制邀请链接")
                .accessibilityLabel(invitationCopied ? "邀请链接已复制" : "复制邀请链接")
            }
        }

        Section("操作") {
            if !controller.isConnected, !isBusy {
                Button(action: controller.reconnect) {
                    Label("重新连接", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                showingEndConfirmation = true
            } label: {
                Label("结束一起听", systemImage: "xmark.circle")
            }
            .disabled(isBusy)
        }
    }

    @ViewBuilder
    private func durationRow(_ room: ListenTogetherRoom) -> some View {
        if let startedAt = room.startedAt {
            LabeledContent("一起听时长") {
                Text(startedAt, style: .timer)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var currentSongRow: some View {
        if let song = player.currentSong {
            LabeledContent("歌曲") {
                VStack(alignment: .trailing, spacing: 2) {
                    SongTitleText(song: song)
                        .lineLimit(1)
                    Text(song.artistsDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            LabeledContent("歌曲", value: "尚未播放")
        }
    }

    private var parsedInvitation: ListenTogetherInvitation? {
        try? ListenTogetherInvitation.parse(invitationText, inviterID: inviterID)
    }

    private var readyInvitation: ListenTogetherInvitation? {
        guard case let .readyToJoin(invitation) = controller.phase else { return nil }
        return invitation
    }

    private var isOfficialInvitationURL: Bool {
        guard let components = URLComponents(string: invitationText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return components.scheme == "https"
            && components.host == "st.music.163.com"
            && components.path == "/listen-together/share/"
    }

    private var isBusy: Bool {
        if controller.isSendingCommand || controller.isReconciling { return true }
        return switch controller.phase {
        case .creating, .checking, .joining, .reconnecting, .ending:
            true
        case .idle, .recoveryAvailable, .readyToJoin, .connected, .ended, .failed:
            false
        }
    }

    private var phaseStatus: String? {
        switch controller.phase {
        case .creating: "正在创建房间"
        case .checking: "正在检查邀请"
        case .readyToJoin: "邀请有效，可以加入"
        case .joining: "正在加入房间"
        case .connected:
            if controller.isSendingCommand { "正在同步播放操作" }
            else if controller.isReconciling { "正在同步房间状态" }
            else { "实时同步已连接" }
        case let .reconnecting(_, attempt): "正在重新连接，第 \(attempt) 次"
        case .ending: "正在结束一起听"
        case let .ended(reason): reason ?? "一起听已结束"
        case .recoveryAvailable: "发现未恢复的一起听房间"
        case .idle, .failed: nil
        }
    }

    private var statusSymbol: String {
        controller.isConnected ? "checkmark.circle.fill" : "person.2.fill"
    }

    private var statusColor: Color {
        controller.isConnected ? .green : .secondary
    }

    private var visibleError: String? {
        inputError ?? controller.errorMessage
    }

    private func checkInvitation() {
        do {
            let invitation = try ListenTogetherInvitation.parse(invitationText, inviterID: inviterID)
            inputError = nil
            Task { await controller.checkInvitation(invitation) }
        } catch {
            inputError = isOfficialInvitationURL ? "邀请链接无效" : "请填写有效的房间 ID 和邀请者 ID"
        }
    }

    private func submitInvitation() {
        guard !isBusy else { return }
        if let invitation = readyInvitation, invitation == parsedInvitation {
            Task { await controller.join(invitation) }
        } else {
            checkInvitation()
        }
    }

    private func roleText(_ role: ListenTogetherRole) -> String {
        role == .host ? "房主" : "成员"
    }
}

private enum EntryMode: Hashable {
    case create
    case join
}
