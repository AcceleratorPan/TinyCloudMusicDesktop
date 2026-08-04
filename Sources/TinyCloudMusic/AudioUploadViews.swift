import SwiftUI
import UniformTypeIdentifiers

struct AudioUploadTaskSheet: View {
    @Bindable var manager: AudioUploadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = manager.persistenceError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                Group {
                    if manager.itemOrder.isEmpty {
                        ContentUnavailableView("暂无上传任务", systemImage: "arrow.up.circle")
                    } else {
                        List {
                            ForEach(manager.itemOrder, id: \.self) { id in
                                if let item = manager.items[id] { task(item) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("上传任务")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task {
                            await manager.flushEdits()
                            dismiss()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 560)
        .onDisappear { Task { await manager.flushEdits() } }
    }

    @ViewBuilder
    private func task(_ item: AudioUploadItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: destinationSymbol(item.destination))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename).font(.headline).lineLimit(1)
                    Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                controls(item)
            }

            if case let .uploading(completed, total) = item.phase {
                ProgressView(value: Double(completed), total: Double(max(1, total)))
                    .accessibilityLabel("上传进度")
            }

            if item.phase == .paused, let metadata = item.metadata {
                Divider()
                if item.destination == .cloud {
                    TextField("标题", text: Binding(
                        get: { manager.items[item.id]?.metadata?.title ?? metadata.title },
                        set: { manager.updateMetadata(id: item.id, title: $0) }
                    ))
                    TextField("歌手", text: Binding(
                        get: { manager.items[item.id]?.metadata?.artist ?? metadata.artist },
                        set: { manager.updateMetadata(id: item.id, artist: $0) }
                    ))
                    TextField("专辑", text: Binding(
                        get: { manager.items[item.id]?.metadata?.album ?? metadata.album },
                        set: { manager.updateMetadata(id: item.id, album: $0) }
                    ))
                } else if let form = item.podcastForm {
                    TextField("名称", text: Binding(
                        get: { manager.items[item.id]?.podcastForm?.name ?? form.name },
                        set: { manager.updatePodcastForm(id: item.id, name: $0) }
                    ))
                    TextField("描述", text: Binding(
                        get: { manager.items[item.id]?.podcastForm?.description ?? form.description },
                        set: { manager.updatePodcastForm(id: item.id, description: $0) }
                    ), axis: .vertical)
                    .lineLimit(2...4)
                    Toggle("私密声音", isOn: Binding(
                        get: { manager.items[item.id]?.podcastForm?.isPrivate ?? form.isPrivate },
                        set: { manager.updatePodcastForm(id: item.id, isPrivate: $0) }
                    ))
                    Toggle("定时发布", isOn: Binding(
                        get: { (manager.items[item.id]?.podcastForm?.publishTimeMilliseconds ?? form.publishTimeMilliseconds) > 0 },
                        set: {
                            manager.updatePodcastForm(
                                id: item.id,
                                publishTimeMilliseconds: $0 ? Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000) : 0
                            )
                        }
                    ))
                    if form.publishTimeMilliseconds > 0 {
                        DatePicker(
                            "发布时间",
                            selection: Binding(
                                get: {
                                    Date(timeIntervalSince1970: TimeInterval(
                                        manager.items[item.id]?.podcastForm?.publishTimeMilliseconds
                                            ?? form.publishTimeMilliseconds
                                    ) / 1_000)
                                },
                                set: {
                                    manager.updatePodcastForm(
                                        id: item.id,
                                        publishTimeMilliseconds: Int64($0.timeIntervalSince1970 * 1_000)
                                    )
                                }
                            ),
                            in: Date()...
                        )
                    }
                    Stepper(
                        "顺序 \(form.order)",
                        value: Binding(
                            get: { manager.items[item.id]?.podcastForm?.order ?? form.order },
                            set: { manager.updatePodcastForm(id: item.id, order: $0) }
                        ),
                        in: 1...10_000
                    )
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func controls(_ item: AudioUploadItem) -> some View {
        HStack(spacing: 4) {
            switch item.phase {
            case .paused:
                iconButton("play.fill", help: "开始上传") {
                    Task { await manager.start(item.id) }
                }
            case .failed:
                if item.isPrepared {
                    iconButton("arrow.clockwise", help: "重试上传") {
                        Task { await manager.retry(item.id) }
                    }
                }
            case .reconciling:
                iconButton("checkmark.arrow.trianglehead.counterclockwise", help: "对账提交结果") {
                    manager.reconcile(item.id)
                }
            case .completed, .cleanupPending, .inspecting, .hashing:
                EmptyView()
            case .allocating, .uploading, .registering:
                iconButton("pause.fill", help: "暂停上传") {
                    Task { await manager.pause(item.id) }
                }
            }
            iconButton(item.phase == .completed ? "trash" : "xmark", help: item.phase == .completed ? "移除任务" : "取消上传") {
                Task { await manager.cancel(item.id) }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }

    private func detail(_ item: AudioUploadItem) -> String {
        let bytes = item.byteCount > 0
            ? ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
            : ""
        let duration = item.metadata.map { metadata in
            let seconds = max(0, metadata.durationMilliseconds / 1_000)
            return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
        } ?? ""
        return [bytes, duration, phaseText(item.phase)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func phaseText(_ phase: AudioUploadPhase) -> String {
        switch phase {
        case .inspecting: "正在检查"
        case .hashing: "正在计算 MD5"
        case .allocating: "正在分配上传"
        case let .uploading(completed, total):
            "\(Int(Double(completed) / Double(max(1, total)) * 100))%"
        case .registering: "正在提交"
        case .paused: "已暂停"
        case .reconciling: "等待对账"
        case .completed: "已完成"
        case let .cleanupPending(message): message
        case let .failed(message): message
        }
    }

    private func destinationSymbol(_ destination: AudioUploadDestination) -> String {
        switch destination {
        case .cloud: "externaldrive.badge.icloud"
        case .podcast: "mic"
        }
    }
}

struct MyPodcastUploadView: View {
    let library: LiveAudioContentLibrary
    @Bindable var manager: AudioUploadManager
    @Bindable var model: AppModel
    let accountID: Int64
    @Environment(\.dismiss) private var dismiss

    @State private var podcasts: [Podcast] = []
    @State private var selectedID: Int64?
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var showsTasks = false
    @State private var errorMessage: String?
    @State private var prepareTask: Task<Void, Never>?
    @State private var prepareTaskID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载")
                } else if podcasts.isEmpty {
                    ContentUnavailableView(
                        "没有可用播客",
                        systemImage: "mic.slash",
                        description: Text("请先在官方产品创建播客。")
                    )
                } else {
                    List(podcasts, selection: $selectedID) { podcast in
                        HStack(spacing: 12) {
                            AudioArtwork(
                                url: podcast.coverURL,
                                symbol: "dot.radiowaves.left.and.right",
                                size: 44
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(podcast.name).font(.body.weight(.medium))
                                Text(podcast.categoryName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(podcast.id)
                    }
                }
            }
            .navigationTitle("我创建的播客")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showsTasks = true } label: { Image(systemName: "tray.full") }
                        .help("查看上传任务")
                        .accessibilityLabel("查看上传任务")
                    Button { isImporting = true } label: { Image(systemName: "mic.badge.plus") }
                        .disabled(isLoading || selectedID == nil)
                        .help("上传声音")
                        .accessibilityLabel("上传声音")
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 560)
        .task(id: accountIdentity) { await load() }
        .onChange(of: accountIdentity) { _, _ in
            prepareTask?.cancel()
            prepareTask = nil
            prepareTaskID = nil
        }
        .onDisappear {
            prepareTask?.cancel()
            prepareTask = nil
            prepareTaskID = nil
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            guard case let .success(url) = result, let selectedID else {
                if case let .failure(error) = result { errorMessage = error.localizedDescription }
                return
            }
            guard model.currentUserID == accountID else { return }
            let taskID = UUID()
            let expectedCredentialRevision = credentialRevision
            prepareTask?.cancel()
            prepareTaskID = taskID
            prepareTask = Task { @MainActor in
                defer {
                    if prepareTaskID == taskID {
                        prepareTask = nil
                        prepareTaskID = nil
                    }
                }
                await prepare(
                    url,
                    podcastID: selectedID,
                    expectedCredentialRevision: expectedCredentialRevision
                )
            }
        }
        .sheet(isPresented: $showsTasks) { AudioUploadTaskSheet(manager: manager) }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var credentialRevision: UInt64 {
        library.transport.credentialSnapshotValue().revision
    }

    private var accountIdentity: String {
        "\(accountID):\(model.currentUserID ?? 0):\(credentialRevision)"
    }

    @MainActor
    private func load() async {
        let expectedAccountID = accountID
        let expectedCredentialRevision = credentialRevision
        prepareTask?.cancel()
        prepareTask = nil
        prepareTaskID = nil
        podcasts = []
        selectedID = nil
        isImporting = false
        isLoading = true
        guard model.currentUserID == expectedAccountID else { return }
        do {
            let loaded = try await library.myCreatedPodcasts(
                expectedCredentialRevision: expectedCredentialRevision
            )
            try Task.checkCancellation()
            guard model.currentUserID == expectedAccountID,
                  credentialRevision == expectedCredentialRevision
            else { return }
            podcasts = loaded
            selectedID = podcasts.first?.id
            errorMessage = nil
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard model.currentUserID == expectedAccountID,
                  credentialRevision == expectedCredentialRevision
            else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func prepare(
        _ url: URL,
        podcastID: Int64,
        expectedCredentialRevision: UInt64
    ) async {
        let expectedAccountID = accountID
        guard model.currentUserID == expectedAccountID else { return }
        do {
            let podcast = try await library.uploadPodcast(
                id: podcastID,
                expectedCredentialRevision: expectedCredentialRevision
            )
            try Task.checkCancellation()
            guard model.currentUserID == expectedAccountID,
                  credentialRevision == expectedCredentialRevision
            else { return }
            let form = PodcastUploadForm(
                name: url.deletingPathExtension().lastPathComponent,
                description: "",
                voiceListID: podcast.id,
                coverImageID: podcast.coverImageID,
                categoryID: podcast.categoryID,
                secondCategoryID: podcast.secondCategoryID,
                isPrivate: podcast.isPrivate
            )
            _ = try form.validated()
            manager.preparePodcastFile(url, form: form)
            showsTasks = true
        } catch is CancellationError {
        } catch {
            guard model.currentUserID == expectedAccountID,
                  credentialRevision == expectedCredentialRevision
            else { return }
            errorMessage = error.localizedDescription
        }
    }
}
