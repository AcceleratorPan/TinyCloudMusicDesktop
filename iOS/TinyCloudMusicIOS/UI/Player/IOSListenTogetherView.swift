import SwiftUI

struct IOSListenTogetherView: View {
    @Bindable var controller: ListenTogetherController
    @Bindable var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var invitation = ""
    @State private var inviterID = ""
    @State private var validationMessage: String?
    @State private var showingEndConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if let room = controller.room {
                    Section("房间") {
                        LabeledContent("房间号", value: room.id)
                        LabeledContent("身份", value: room.role == .host ? "房主" : "成员")
                        LabeledContent("成员", value: "\(room.members.count) 人")
                        if let startedAt = room.startedAt {
                            LabeledContent("一起听时长") {
                                Text(startedAt, style: .timer).monospacedDigit()
                            }
                        }
                        currentSong
                        LabeledContent("状态", value: controller.statusMessage ?? phaseText)
                    }

                    if !controller.members.isEmpty {
                        Section("成员") {
                            ForEach(controller.members) { member in
                                Label(
                                    member.nickname,
                                    systemImage: member.id == room.creatorID ? "crown" : "person"
                                )
                            }
                        }
                    }

                    if let url = controller.invitationURL {
                        Section {
                            ShareLink(item: url) {
                                Label("分享邀请", systemImage: "square.and.arrow.up")
                                    .frame(minHeight: 44)
                            }
                        }
                    }

                    Section {
                        if case .recoveryAvailable = controller.phase {
                            Button("恢复房间", systemImage: "arrow.clockwise") { controller.recover() }
                        }
                        if case .reconnecting = controller.phase {
                            Button("立即重连", systemImage: "antenna.radiowaves.left.and.right") {
                                controller.reconnect()
                            }
                        }
                        Button("结束并退出", role: .destructive) {
                            showingEndConfirmation = true
                        }
                        .disabled(isBusy)
                    }
                } else {
                    Section("当前播放") {
                        currentSong
                        Button("创建一起听房间", systemImage: "person.2.badge.plus") {
                            Task { await controller.createRoom() }
                        }
                        .disabled(player.currentSong == nil || isBusy)
                    }

                    Section("加入邀请") {
                        TextField("邀请链接或房间号", text: $invitation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("邀请人 ID", text: $inviterID)
                            .keyboardType(.numberPad)
                        if let validationMessage {
                            Text(validationMessage).font(.footnote).foregroundStyle(.red)
                        }
                        Button("检查并加入", systemImage: "rectangle.portrait.and.arrow.right") {
                            join()
                        }
                        .disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                    }
                }

                if let message = controller.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("一起听")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .alert("结束一起听？", isPresented: $showingEndConfirmation) {
            Button("结束", role: .destructive) {
                Task { await controller.endRoom() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("房间内所有成员将退出一起听。")
        }
    }

    @ViewBuilder
    private var currentSong: some View {
        if let song = player.currentSong {
            LabeledContent("歌曲") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(song.primaryName).lineLimit(1)
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

    private var isBusy: Bool {
        if controller.isSendingCommand || controller.isReconciling { return true }
        return switch controller.phase {
        case .creating, .checking, .joining, .reconnecting, .ending:
            true
        case .idle, .recoveryAvailable, .readyToJoin, .connected, .ended, .failed:
            false
        }
    }

    private var phaseText: String {
        switch controller.phase {
        case .idle: "未连接"
        case .creating: "正在创建"
        case .checking: "正在检查邀请"
        case .readyToJoin: "邀请有效，可以加入"
        case .joining: "正在加入"
        case .connected: "已连接"
        case let .reconnecting(_, attempt): "正在重连，第 \(attempt) 次"
        case .recoveryAvailable: "可恢复"
        case .ending: "正在结束"
        case let .ended(reason): reason ?? "已结束"
        case let .failed(message): message
        }
    }

    private func join() {
        do {
            let parsed = try ListenTogetherInvitation.parse(invitation, inviterID: inviterID)
            validationMessage = nil
            Task {
                await controller.checkInvitation(parsed)
                guard !Task.isCancelled, case .readyToJoin = controller.phase else { return }
                await controller.join(parsed)
            }
        } catch {
            validationMessage = "邀请格式不正确"
        }
    }
}
