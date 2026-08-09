import SwiftUI

struct IOSDiscoverView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发现音乐")
                            .font(.title2.bold())
                        Text("为今天挑一些合适的声音")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.open(.musicStyles) } label: {
                        Label("曲风", systemImage: "guitars")
                    }
                    .buttonStyle(.bordered)
                }

                ForEach(model.homeSlots) { slot in
                    IOSHomeSectionView(slot: slot, model: model, player: player)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .navigationTitle("发现")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.loadHome() } label: {
                    Label("刷新首页", systemImage: "arrow.clockwise")
                }
            }
        }
        .refreshable { model.loadHome() }
    }
}

private struct IOSHomeSectionView: View {
    let slot: HomeSlot
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch slot.load {
            case .idle, .loading:
                IOSHomeSectionHeader(title: slot.title, subtitle: nil)
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在载入")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 112)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在载入\(slot.title)")
            case let .failed(message):
                IOSHomeSectionHeader(title: slot.title, subtitle: nil)
                IOSInlineRetry(message: message) {
                    model.retryHomeSection(id: slot.id)
                }
            case let .loaded(section):
                IOSHomeSectionHeader(title: section.title, subtitle: section.subtitle)
                if section.items.isEmpty {
                    Label("本栏目暂时没有内容", systemImage: "music.note")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 88)
                } else {
                    let songs = section.items.compactMap(\.song)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(section.items) { item in
                                IOSHomeItemButton(
                                    item: item,
                                    songs: songs,
                                    model: model,
                                    player: player
                                )
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 4)
                    }
                    .scrollClipDisabled()
                }
            }
        }
    }
}

private struct IOSHomeSectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.red)
                .frame(width: 3)
                .offset(x: -9)
                .accessibilityHidden(true)
        }
        .padding(.leading, 9)
    }
}

private struct IOSHomeItemButton: View {
    let item: HomeItem
    let songs: [Song]
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                IOSArtworkView(artwork: item.artwork)
                    .frame(width: 152, height: 152)
                    .overlay(alignment: .bottomTrailing) {
                        if item.song != nil {
                            Image(systemName: "play.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(.red, in: Circle())
                                .padding(8)
                                .accessibilityHidden(true)
                        }
                    }
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: 152, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(IOSPressedButtonStyle())
        .accessibilityLabel(item.title)
        .accessibilityHint(item.song == nil ? "打开详情" : "播放")
        .contextMenu {
            if let song = item.song {
                IOSSongActionsMenu(
                    song: song,
                    songs: songs,
                    model: model,
                    player: player
                )
            }
        }
    }

    private func open() {
        if let song = item.song {
            player.play(song, in: songs)
        } else if let route = item.route {
            model.open(route)
        }
    }
}
