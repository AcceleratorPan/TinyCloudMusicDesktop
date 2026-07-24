import ImageIO
import PDFKit
import SwiftUI

private enum MusicKnowledgeLoad<Value: Equatable>: Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

struct MusicStylesView: View {
    let library: LiveMusicKnowledgeLibrary
    let accountID: Int64?
    let onOpenRoute: (Route) -> Void

    @State private var phase: MusicKnowledgeLoad<[MusicStyle]> = .idle
    @State private var preferredIDs = Set<Int64>()
    @State private var reloadID = 0

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                ProgressView("正在加载曲风")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("曲风加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { reloadID += 1 }
                }
            case let .loaded(styles):
                if styles.isEmpty {
                    ContentUnavailableView("暂无曲风", systemImage: "guitars")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(styles) { style in
                                MusicStyleGroup(
                                    style: style,
                                    preferredIDs: preferredIDs,
                                    onOpenRoute: onOpenRoute
                                )
                            }
                        }
                        .frame(maxWidth: 1_120)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("曲风")
        .task(id: "\(accountID ?? 0):\(reloadID)") { await load() }
    }

    @MainActor
    private func load() async {
        phase = .loading
        do {
            async let styles = library.styles()
            let preferences = accountID == nil ? [] : (try? await library.preferredStyleIDs()) ?? []
            let loaded = try await styles
            try Task.checkCancellation()
            preferredIDs = Set(preferences)
            phase = .loaded(loaded)
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct MusicStyleGroup: View {
    let style: MusicStyle
    let preferredIDs: Set<Int64>
    let onOpenRoute: (Route) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 156, maximum: 240), spacing: 8, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MusicStyleButton(
                style: style,
                isPreferred: preferredIDs.contains(style.id),
                isHeading: true,
                onOpenRoute: onOpenRoute
            )

            if !style.children.isEmpty {
                Divider()
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(style.children) { child in
                        MusicStyleButton(
                            style: child,
                            isPreferred: preferredIDs.contains(child.id),
                            onOpenRoute: onOpenRoute
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65))
        }
    }
}

private struct MusicStyleButton: View {
    let style: MusicStyle
    let isPreferred: Bool
    var isHeading = false
    let onOpenRoute: (Route) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button {
            onOpenRoute(.musicStyle(style.id, style.name))
        } label: {
            HStack(spacing: 6) {
                Text(style.name)
                    .font(isHeading ? .headline.weight(.semibold) : .body.weight(.medium))
                    .lineLimit(2)
                if isPreferred {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                isHovered ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.name)
        .accessibilityValue(isPreferred ? "我的偏好" : "")
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
    }
}

struct MusicStyleDetailView: View {
    let styleID: Int64
    let styleName: String
    let library: LiveMusicKnowledgeLibrary
    let player: PlayerController
    let onOpenRoute: (Route) -> Void

    @State private var detail: MusicStyleDetail?
    @State private var detailError: String?
    @State private var selectedKind = MusicStyleResourceKind.songs
    @State private var pages: [MusicStyleResourceKind: MusicStylePage] = [:]
    @State private var loadingKinds = Set<MusicStyleResourceKind>()
    @State private var errors: [MusicStyleResourceKind: String] = [:]
    @State private var reloads: [MusicStyleResourceKind: Int] = [:]
    @State private var loadMoreRetries: [MusicStyleResourceKind: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail?.name ?? styleName)
                        .font(.title.bold())
                    if let description = detail?.description, !description.isEmpty {
                        Text(description)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(12)
                    } else if let detailError {
                        Text(detailError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .task(id: styleID) { await loadDetail() }

                Picker("曲风内容", selection: $selectedKind) {
                    ForEach(MusicStyleResourceKind.allCases, id: \.self) { kind in
                        Label(kind.rawValue, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 620)
            }
            .frame(maxWidth: 1_120, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider()

            ScrollView {
                content
                    .task(id: "\(styleID):\(selectedKind.rawValue):\(reloads[selectedKind, default: 0])") {
                        await loadInitialPage(selectedKind)
                    }
                    .frame(maxWidth: 1_120, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle(styleName)
    }

    @ViewBuilder
    private var content: some View {
        if let page = pages[selectedKind] {
            if page.items.isEmpty {
                ContentUnavailableView("暂无\(selectedKind.rawValue)", systemImage: selectedKind.symbol)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(page.items) { item in
                        resourceRow(item, page: page)
                        Divider().padding(.leading, 72)
                    }
                    if let cursor = page.nextCursor {
                        Group {
                            if let message = errors[selectedKind] {
                                VStack(spacing: 8) {
                                    Text(message).font(.caption).foregroundStyle(.secondary)
                                    Button("重试") {
                                        errors[selectedKind] = nil
                                        loadMoreRetries[selectedKind, default: 0] += 1
                                    }
                                }
                                .padding()
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .task(id: "\(styleID):\(selectedKind.rawValue):\(cursor):\(loadMoreRetries[selectedKind, default: 0])") {
                            guard errors[selectedKind] == nil else { return }
                            await loadMore(selectedKind)
                        }
                    }
                }
            }
        } else if let message = errors[selectedKind] {
            ContentUnavailableView {
                Label("加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { reloads[selectedKind, default: 0] += 1 }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            ProgressView("正在加载\(selectedKind.rawValue)")
                .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private func resourceRow(_ item: MusicStyleResource, page: MusicStylePage) -> some View {
        let songs = page.items.compactMap { item -> Song? in
            guard case let .song(song) = item else { return nil }
            return song
        }
        let searchItem: SearchItem = switch item {
        case let .song(value): .song(value)
        case let .album(value): .album(value)
        case let .artist(value): .artist(value)
        case let .playlist(value): .playlist(value)
        }
        return SearchResultRow(item: searchItem, onOpenRoute: onOpenRoute) {
            if case let .song(song) = item {
                player.play(song, in: songs)
            } else if let route = item.route {
                onOpenRoute(route)
            }
        }
    }

    @MainActor
    private func loadDetail() async {
        do {
            detail = try await library.styleDetail(id: styleID, name: styleName)
        } catch is CancellationError {
        } catch {
            detailError = error.localizedDescription
        }
    }

    @MainActor
    private func loadInitialPage(_ kind: MusicStyleResourceKind) async {
        guard pages[kind] == nil, !loadingKinds.contains(kind) else { return }
        loadingKinds.insert(kind)
        errors[kind] = nil
        defer { loadingKinds.remove(kind) }
        do {
            pages[kind] = try await library.stylePage(id: styleID, kind: kind)
        } catch is CancellationError {
        } catch {
            errors[kind] = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore(_ kind: MusicStyleResourceKind) async {
        guard let page = pages[kind], let cursor = page.nextCursor,
              !loadingKinds.contains(kind)
        else { return }
        loadingKinds.insert(kind)
        errors[kind] = nil
        defer { loadingKinds.remove(kind) }
        do {
            let next = try await library.stylePage(id: styleID, kind: kind, cursor: cursor)
            try Task.checkCancellation()
            let appended = page.appending(next)
            pages[kind] = MusicStylePage(
                items: appended.items,
                nextCursor: next.nextCursor == cursor ? nil : next.nextCursor
            )
        } catch is CancellationError {
        } catch {
            errors[kind] = error.localizedDescription
        }
    }
}

struct MusicKnowledgeSection: View {
    let resource: MusicKnowledgeResource
    let library: LiveMusicKnowledgeLibrary
    var fallbackText = ""
    var showsTitle = true
    let onOpenRoute: (Route) -> Void

    @State private var phase: MusicKnowledgeLoad<[MusicKnowledgeBlock]> = .idle
    @State private var reloadID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTitle {
                Text("音乐百科")
                    .font(.title3.weight(.semibold))
            }
            switch phase {
            case .idle, .loading:
                ProgressView("正在加载百科")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 160)
            case let .failed(message):
                if fallbackBlocks.isEmpty {
                    ContentUnavailableView {
                        Label("百科加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { reloadID += 1 }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    knowledgeContent(fallbackBlocks)
                    HStack(spacing: 8) {
                        Label("扩展百科加载失败", systemImage: "wifi.exclamationmark")
                        Button("重试") { reloadID += 1 }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case let .loaded(blocks):
                knowledgeContent(blocks.isEmpty ? fallbackBlocks : blocks)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(resource):\(reloadID)") { await load() }
    }

    private var fallbackBlocks: [MusicKnowledgeBlock] {
        let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [.text(id: "fallback", title: "简介", body: text)]
    }

    @ViewBuilder
    private func knowledgeContent(_ blocks: [MusicKnowledgeBlock]) -> some View {
        if blocks.isEmpty {
            ContentUnavailableView(
                "暂无百科资料",
                systemImage: "text.book.closed",
                description: Text("该资源还没有可显示的百科内容。")
            )
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(blocks) { block in
                    knowledgeBlock(block)
                }
            }
        }
    }

    @ViewBuilder
    private func knowledgeBlock(_ block: MusicKnowledgeBlock) -> some View {
        switch block {
        case let .text(_, title, body):
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(body)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .image(_, url, caption):
            VStack(alignment: .leading, spacing: 5) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image): image.resizable().scaledToFit()
                    case .empty: ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                    case .failure:
                        ContentUnavailableView("图片加载失败", systemImage: "photo")
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                }
                .frame(maxWidth: 760, minHeight: 180, maxHeight: 460)
                if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
        case let .metric(_, title, value):
            LabeledContent(title, value: value)
                .frame(maxWidth: 520)
        case let .resource(_, title, route):
            Button { onOpenRoute(route) } label: {
                Label(title, systemImage: "arrow.up.right.square")
            }
        }
    }

    @MainActor
    private func load() async {
        phase = .loading
        do {
            let blocks = try await library.knowledge(for: resource)
            try Task.checkCancellation()
            phase = .loaded(blocks)
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct MusicKnowledgeModalHeader: View {
    let title: String
    let symbol: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭\(title)")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.ultraThinMaterial)
    }
}

struct MusicSheetsView: View {
    let song: Song
    let library: LiveMusicKnowledgeLibrary
    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var phase: MusicKnowledgeLoad<[MusicSheetSummary]> = .idle
    @State private var selectedSheet: MusicSheetSummary?
    @State private var reloadID = 0

    var body: some View {
        VStack(spacing: 0) {
            MusicKnowledgeModalHeader(title: "乐谱", symbol: "music.quarternote.3") { dismiss() }
            Divider()
            Group {
                switch phase {
                case .idle, .loading:
                    ProgressView("正在加载乐谱")
                case let .failed(message):
                    ContentUnavailableView {
                        Label("乐谱加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { reloadID += 1 }
                    }
                case let .loaded(sheets):
                    if sheets.isEmpty {
                        ContentUnavailableView("暂无乐谱", systemImage: "music.quarternote.3")
                    } else {
                        List(sheets) { sheet in
                            Button { selectedSheet = sheet } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "music.quarternote.3")
                                        .frame(width: 24)
                                        .foregroundStyle(.red)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(sheet.title).font(.body.weight(.medium)).lineLimit(2)
                                        Text([sheet.instrument, sheet.pageCount.map { "\($0) 页" }]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.inset)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 520)
        .task(id: "\(song.id):\(reloadID)") { await load() }
        .sheet(item: $selectedSheet) { sheet in
            MusicSheetPreviewView(song: song, sheet: sheet, library: library, model: model)
        }
    }

    @MainActor
    private func load() async {
        phase = .loading
        do {
            let sheets = try await library.sheets(songID: song.id)
            try Task.checkCancellation()
            phase = .loaded(sheets)
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct MusicSheetPreviewView: View {
    let song: Song
    let sheet: MusicSheetSummary
    let library: LiveMusicKnowledgeLibrary
    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var phase: MusicKnowledgeLoad<MusicSheetPreview> = .idle
    @State private var pageIndex = 0
    @State private var pageAspectRatio = 0.707
    @State private var zoom = 1.0
    @State private var pdfFile: URL?
    @State private var pdfError: String?
    @State private var isDownloading = false
    @State private var downloadCompleted = false
    @State private var downloadError: String?
    @State private var reloadID = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheet.title).font(.headline).lineLimit(1)
                Spacer()
                if case let .loaded(.images(images)) = phase {
                    Button(action: previousPage) { Image(systemName: "chevron.left") }
                        .disabled(pageIndex == 0)
                        .help("上一页")
                    Text("\(pageIndex + 1) / \(images.count)")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 54)
                    Button(action: nextPage) { Image(systemName: "chevron.right") }
                        .disabled(pageIndex + 1 >= images.count)
                        .help("下一页")
                    Divider().frame(height: 20)
                    Button { zoom = max(0.5, zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("缩小")
                    Button { zoom = min(3, zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("放大")
                }
                Divider().frame(height: 20)
                Button(action: downloadSheet) {
                    Group {
                        if isDownloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: downloadCompleted ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(downloadCompleted ? Color.green : Color.primary)
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .disabled(!canDownload || isDownloading || downloadCompleted)
                .help(downloadCompleted ? "琴谱已保存" : isDownloading ? "正在下载琴谱" : "下载 PDF 琴谱")
                .accessibilityLabel(downloadCompleted ? "琴谱已保存" : isDownloading ? "正在下载琴谱" : "下载琴谱")
                Divider().frame(height: 20)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: Circle())
                }
                .help("关闭")
                .accessibilityLabel("关闭乐谱预览")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .frame(height: 56)
            Divider()
            previewContent
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .task(id: "\(sheet.id):\(reloadID)") { await load() }
        .onDisappear { MusicSheetTemporaryFiles.remove(pdfFile) }
        .alert("琴谱下载失败", isPresented: downloadErrorPresented) {
            Button("好") { downloadError = nil }
        } message: {
            Text(downloadError ?? "")
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch phase {
        case .idle, .loading:
            ProgressView("正在加载预览").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            failure(message)
        case .loaded(.unsupported):
            ContentUnavailableView("不支持预览", systemImage: "doc.questionmark")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(.images(images)):
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    CachedAsyncImage(
                        url: images[pageIndex],
                        onSuccess: updatePageAspectRatio
                    ) { imagePhase in
                        switch imagePhase {
                        case let .success(image): image.resizable().scaledToFit()
                        case .empty: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .failure:
                            ContentUnavailableView("本页加载失败", systemImage: "photo")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(
                        width: max(1, proxy.size.width - 40) * zoom,
                        height: max(1, proxy.size.height - 40) * zoom
                    )
                    .padding(20)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
                .overlay {
                    HStack(spacing: 0) {
                        MusicSheetEdgePageButton(
                            symbol: "chevron.left",
                            help: "上一页",
                            isEnabled: pageIndex > 0,
                            action: previousPage
                        )
                        Spacer(minLength: 0)
                        MusicSheetEdgePageButton(
                            symbol: "chevron.right",
                            help: "下一页",
                            isEnabled: pageIndex + 1 < images.count,
                            action: nextPage
                        )
                    }
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        case .loaded(.pdf):
            if let pdfFile {
                MusicPDFView(url: pdfFile)
            } else if let pdfError {
                failure(pdfError)
            } else {
                ProgressView("正在准备 PDF").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func previousPage() {
        pageIndex = max(0, pageIndex - 1)
    }

    private func nextPage() {
        guard case let .loaded(.images(images)) = phase else { return }
        pageIndex = min(images.count - 1, pageIndex + 1)
    }

    private var canDownload: Bool {
        guard case let .loaded(preview) = phase else { return false }
        return switch preview {
        case let .images(images): !images.isEmpty
        case .pdf: true
        case .unsupported: false
        }
    }

    private var downloadErrorPresented: Binding<Bool> {
        Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )
    }

    private func downloadSheet() {
        guard !isDownloading, case let .loaded(preview) = phase else { return }
        let destination = model.sheetFolderURL
        if MusicSheetFiles.existingPDF(song: song, sheet: sheet, in: destination) != nil {
            downloadCompleted = true
            model.showToast("琴谱已存在，已跳过下载")
            return
        }

        isDownloading = true
        downloadCompleted = false
        downloadError = nil
        Task { @MainActor in
            var temporaryFile: URL?
            defer {
                MusicSheetTemporaryFiles.remove(temporaryFile)
                isDownloading = false
            }
            do {
                let source: URL
                switch preview {
                case let .images(images):
                    source = try await MusicSheetPDFLoader.makePDF(from: images)
                    temporaryFile = source
                case let .pdf(url):
                    if let pdfFile {
                        source = pdfFile
                    } else {
                        source = try await MusicSheetPDFLoader.download(url)
                        temporaryFile = source
                    }
                case .unsupported:
                    return
                }
                let result = try MusicSheetFiles.savePDF(
                    at: source,
                    song: song,
                    sheet: sheet,
                    to: destination
                )
                downloadCompleted = true
                model.showToast(result.saved ? "琴谱下载完成" : "琴谱已存在，已跳过下载")
            } catch is CancellationError {
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private var previewSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1_000, height: 900)
        let maximum = CGSize(
            width: min(1_400, max(560, screen.width - 80)),
            height: min(1_200, max(680, screen.height - 80))
        )
        let pageHeight = min(maximum.height - 97, (maximum.width - 40) / pageAspectRatio)
        return CGSize(width: pageHeight * pageAspectRatio + 40, height: pageHeight + 97)
    }

    private func updatePageAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        pageAspectRatio = size.width / size.height
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("预览加载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试") { reloadID += 1 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func load() async {
        MusicSheetTemporaryFiles.remove(pdfFile)
        pdfFile = nil
        pdfError = nil
        pageIndex = 0
        pageAspectRatio = 0.707
        zoom = 1
        phase = .loading
        do {
            let preview = try await library.sheetPreview(id: sheet.id)
            try Task.checkCancellation()
            phase = .loaded(preview)
            if case let .pdf(url) = preview {
                do {
                    let file = try await MusicSheetPDFLoader.download(url)
                    try Task.checkCancellation()
                    pdfFile = file
                } catch is CancellationError {
                } catch {
                    pdfError = error.localizedDescription
                }
            }
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct MusicSheetEdgePageButton: View {
    let symbol: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 56)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .frame(width: 88)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .opacity(isHovered && isEnabled ? 0.82 : 0)
        .allowsHitTesting(isEnabled)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovered)
        .help(help)
        .accessibilityHidden(true)
    }
}

private struct MusicPDFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

private final class MusicSheetRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(MusicSheetURLPolicy.isAllowed) == true ? request : nil)
    }
}

enum MusicSheetPDFLoader {
    static let maximumBytes = 50 * 1_024 * 1_024
    static let maximumImageBytes = 25 * 1_024 * 1_024
    static let maximumDocumentBytes = 100 * 1_024 * 1_024
    static let maximumPageCount = 100

    static func download(_ url: URL) async throws -> URL {
        guard MusicSheetURLPolicy.isAllowed(url) else { throw EAPIError.invalidPayload }
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard data.count <= maximumBytes,
              valid(response),
              data.starts(with: Data("%PDF".utf8))
        else { throw EAPIError.invalidResponse }
        try Task.checkCancellation()
        return try MusicSheetTemporaryFiles.write(data)
    }

    @MainActor
    static func makePDF(from urls: [URL]) async throws -> URL {
        guard !urls.isEmpty, urls.count <= maximumPageCount,
              urls.allSatisfy(MusicSheetURLPolicy.isAllowed)
        else { throw EAPIError.invalidPayload }
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        let document = PDFDocument()
        var totalBytes = 0
        for url in urls {
            let (data, response) = try await session.data(from: url)
            let nextTotal = totalBytes.addingReportingOverflow(data.count)
            guard !nextTotal.overflow,
                  data.count <= maximumImageBytes,
                  nextTotal.partialValue <= maximumDocumentBytes,
                  valid(response),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let page = PDFPage(image: NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height)
                  ))
            else { throw EAPIError.invalidResponse }
            document.insert(page, at: document.pageCount)
            totalBytes = nextTotal.partialValue
            try Task.checkCancellation()
        }
        guard let data = document.dataRepresentation(),
              data.count <= maximumDocumentBytes,
              data.starts(with: Data("%PDF".utf8))
        else { throw EAPIError.invalidResponse }
        return try MusicSheetTemporaryFiles.write(data)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(
            configuration: configuration,
            delegate: MusicSheetRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private static func valid(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              response.url.map(MusicSheetURLPolicy.isAllowed) == true
        else { return false }
        return true
    }
}
