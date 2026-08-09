import SwiftUI

struct IOSSearchView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var isSearchPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("搜索类型")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("搜索类型", selection: scopeBinding) {
                        ForEach(SearchScope.allCases, id: \.self) { scope in
                            Label(scope.rawValue, systemImage: scope.symbol)
                                .tag(scope)
                        }
                    }
                } label: {
                    Label(model.searchState.scope.rawValue, systemImage: model.searchState.scope.symbol)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()
            searchContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("搜索")
        .searchable(
            text: queryBinding,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "歌曲、歌手、专辑、歌单、用户、MV 或视频"
        )
        .searchSuggestions {
            ForEach(Array(model.searchHints.enumerated()), id: \.offset) { _, hint in
                Button { select(hint) } label: {
                    Label(hint, systemImage: suggestionSymbol)
                }
            }
        }
        .onSubmit(of: .search) {
            model.search(offset: 0)
            isSearchPresented = false
        }
        .task { model.loadSearchHints() }
    }

    @ViewBuilder
    private var searchContent: some View {
        if trimmedQuery.isEmpty {
            IOSSearchLanding(model: model, select: select)
        } else {
            switch model.searchLoad {
            case .idle:
                IOSSearchAssistance(
                    hints: model.searchHints,
                    directMatches: model.searchDirectMatches,
                    model: model,
                    player: player,
                    select: select
                )
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在搜索\(trimmedQuery)")
                        .foregroundStyle(.secondary)
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("搜索失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { model.search(offset: 0) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            case let .loaded(page):
                if page.items.isEmpty && model.searchDirectMatches.isEmpty {
                    ContentUnavailableView(
                        "没有找到结果",
                        systemImage: "magnifyingglass",
                        description: Text("换一个关键词或搜索类型试试")
                    )
                } else {
                    IOSSearchResults(
                        page: page,
                        directMatches: model.searchDirectMatches,
                        model: model,
                        player: player
                    )
                }
            }
        }
    }

    private var trimmedQuery: String {
        model.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestionSymbol: String {
        trimmedQuery.isEmpty ? "sparkles" : "magnifyingglass"
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { model.searchState.query },
            set: { model.updateSearchQuery($0) }
        )
    }

    private var scopeBinding: Binding<SearchScope> {
        Binding(
            get: { model.searchState.scope },
            set: { model.setSearchScope($0) }
        )
    }

    private func select(_ value: String) {
        model.selectSearchHint(value)
        isSearchPresented = false
    }
}

private struct IOSSearchLanding: View {
    @Bindable var model: AppModel
    let select: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !model.searchHints.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("推荐搜索", systemImage: "sparkles")
                            .font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(Array(model.searchHints.enumerated()), id: \.offset) { _, hint in
                                    Button(hint) { select(hint) }
                                        .buttonStyle(.bordered)
                                        .frame(minHeight: 44)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("热搜", systemImage: "flame")
                            .font(.headline)
                        Spacer()
                        if model.isHotSearchLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if model.hotSearchItems.isEmpty {
                        if !model.isHotSearchLoading {
                            Text("输入关键词开始搜索")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 96)
                        }
                    } else {
                        ForEach(Array(model.hotSearchItems.enumerated()), id: \.offset) { index, item in
                            Button { select(item.keyword) } label: {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.body.monospacedDigit().weight(index < 3 ? .semibold : .regular))
                                        .foregroundStyle(index < 3 ? Color.red : Color.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.keyword)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        if !item.detail.isEmpty {
                                            Text(item.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if item.score > 0 {
                                        Text(item.score.formatted())
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(IOSPressedButtonStyle())
                            .accessibilityLabel(hotSearchLabel(item, rank: index + 1))
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func hotSearchLabel(_ item: HotSearchItem, rank: Int) -> String {
        ["热搜第\(rank)名", item.keyword, item.detail]
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }
}

private struct IOSSearchAssistance: View {
    let hints: [String]
    let directMatches: [SearchDirectMatch]
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let select: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !directMatches.isEmpty {
                    Text("最佳匹配")
                        .font(.headline)
                        .padding(.vertical, 12)
                    let songs = directMatches.compactMap(\.item.song)
                    ForEach(directMatches) { match in
                        IOSSearchItemRow(
                            item: match.item,
                            songs: songs,
                            model: model,
                            player: player
                        )
                        Divider().padding(.leading, 64)
                    }
                }
                if !hints.isEmpty {
                    Text("搜索建议")
                        .font(.headline)
                        .padding(.vertical, 12)
                    ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                        Button { select(hint) } label: {
                            Label(hint, systemImage: "magnifyingglass")
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(IOSPressedButtonStyle())
                        Divider().padding(.leading, 30)
                    }
                } else if directMatches.isEmpty {
                    ContentUnavailableView(
                        "搜索音乐",
                        systemImage: "music.note.list",
                        description: Text("输入关键词后按搜索")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct IOSSearchResults: View {
    let page: SearchPage
    let directMatches: [SearchDirectMatch]
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !directMatches.isEmpty {
                    Text("最佳匹配")
                        .font(.headline)
                        .padding(.vertical, 12)
                    let directSongs = directMatches.compactMap(\.item.song)
                    ForEach(directMatches) { match in
                        IOSSearchItemRow(
                            item: match.item,
                            songs: directSongs,
                            model: model,
                            player: player
                        )
                        Divider().padding(.leading, 64)
                    }
                    Text("搜索结果")
                        .font(.headline)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                }

                let songs = page.items.compactMap(\.song)
                ForEach(page.items) { item in
                    IOSSearchItemRow(item: item, songs: songs, model: model, player: player)
                    Divider().padding(.leading, 64)
                }

                if let message = model.searchLoadMoreError {
                    IOSInlineRetry(message: message) { model.loadMoreSearchResults() }
                } else if page.hasMore {
                    HStack(spacing: 10) {
                        if model.isSearchLoadingMore {
                            ProgressView()
                            Text("正在载入更多结果")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("载入更多") { model.loadMoreSearchResults() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .onAppear {
                        if !model.isSearchLoadingMore { model.loadMoreSearchResults() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

private struct IOSSearchItemRow: View {
    let item: SearchItem
    let songs: [Song]
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @ViewBuilder
    var body: some View {
        if let song = item.song {
            IOSSongRow(song: song, songs: songs, model: model, player: player)
        } else {
            Button(action: open) {
                HStack(spacing: 12) {
                    IOSArtworkView(artwork: item.artwork)
                        .clipShape(
                            item.isPerson
                                ? AnyShape(Circle())
                                : AnyShape(RoundedRectangle(cornerRadius: 8))
                        )
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        if case let .playlist(playlist) = item {
                            Text("\(playlist.trackCount.formatted()) 首歌曲")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24)
                }
                .frame(minHeight: 68)
                .contentShape(Rectangle())
            }
            .buttonStyle(IOSPressedButtonStyle())
            .accessibilityLabel("打开\(item.title)")
        }
    }

    private func open() {
        guard let route = item.route else { return }
        model.searchState.selectedID = item.numericID
        model.open(route)
    }
}

private extension SearchItem {
    var song: Song? {
        guard case let .song(song) = self else { return nil }
        return song
    }

    var isPerson: Bool {
        switch self {
        case .artist, .user: true
        default: false
        }
    }
}
