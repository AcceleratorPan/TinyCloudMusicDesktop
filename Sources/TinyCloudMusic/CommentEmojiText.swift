import CryptoKit
import Foundation

#if !COMMENT_EMOJI_CHECK
import AppKit
import SwiftUI
#endif

enum CommentEmojiPart: Equatable {
    case text(String)
    case emoji(token: String, url: URL)
}

enum CommentEmojiCatalog {
    static func parts(in text: String, remotePictureIDs: [String: String] = [:]) -> [CommentEmojiPart] {
        var parts: [CommentEmojiPart] = []
        var plainStart = text.startIndex
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let open = text[searchStart...].firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]") {
            let tokenEnd = text.index(after: close)
            let token = String(text[open..<tokenEnd])
            guard let url = imageURL(for: token, remotePictureIDs: remotePictureIDs) else {
                searchStart = text.index(after: open)
                continue
            }
            if plainStart < open {
                parts.append(.text(String(text[plainStart..<open])))
            }
            parts.append(.emoji(token: token, url: url))
            plainStart = tokenEnd
            searchStart = tokenEnd
        }

        if plainStart < text.endIndex {
            parts.append(.text(String(text[plainStart...])))
        }
        return parts
    }

    static func imageURL(for token: String, remotePictureIDs: [String: String] = [:]) -> URL? {
        guard let pictureID = remotePictureIDs[token] ?? pictureIDs[token] else { return nil }
        return URL(string: "https://p1.music.126.net/\(encryptedID(pictureID))/\(pictureID).jpg")
    }

    private static func encryptedID(_ value: String) -> String {
        let key = Array("3go8&$8*3*3h0k(2)2".utf8)
        let bytes = value.utf8.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        return Data(Insecure.MD5.hash(data: Data(bytes))).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private static let pictureIDs = [
        "[大笑]": "109951163626288227",
        "[可爱]": "109951163626292590",
        "[憨笑]": "109951163626287772",
        "[色]": "109951163626282488",
        "[亲亲]": "109951163626285344",
        "[惊恐]": "109951163626283490",
        "[流泪]": "109951163626284414",
        "[亲]": "109951163626290631",
        "[呆]": "109951163626287355",
        "[哀伤]": "109951163626285834",
        "[呲牙]": "109951163626292580",
        "[吐舌]": "109951163626283909",
        "[撇嘴]": "109951163626290628",
        "[怒]": "109951163626282485",
        "[奸笑]": "109951163626294536",
        "[汗]": "109951163626295545",
        "[痛苦]": "109951163626281966",
        "[惶恐]": "109951163626285341",
        "[生病]": "109951163626293558",
        "[口罩]": "109951163626288731",
        "[大哭]": "109951163626286820",
        "[晕]": "109951163626293560",
        "[发怒]": "109951163626288724",
        "[开心]": "109951163626291598",
        "[鬼脸]": "109951163626291602",
        "[皱眉]": "109951163626281977",
        "[流感]": "109951163626284872",
        "[爱心]": "109951163626286814",
        "[心碎]": "109951163626285338",
        "[钟情]": "109951163626295031",
        "[星星]": "109951163626284864",
        "[生气]": "109951163626290124",
        "[便便]": "109951163626287776",
        "[强]": "109951163626289189",
        "[弱]": "109951163626289199",
        "[拜]": "109951163626288212",
        "[牵手]": "109951163626289693",
        "[跳舞]": "109951163626292089",
        "[禁止]": "109951163626293561",
        "[这边]": "109951163626291590",
        "[爱意]": "109951163626292575",
        "[示爱]": "109951163626284417",
        "[嘴唇]": "109951163626283914",
        "[狗]": "109951163626291126",
        "[猫]": "109951163626283916",
        "[猪]": "109951163626294532",
        "[兔子]": "109951163626290633",
        "[小鸡]": "109951163626294542",
        "[公鸡]": "109951163626294064",
        "[幽灵]": "109951163626294055",
        "[圣诞]": "109951163626287360",
        "[外星]": "109951163626285830",
        "[钻石]": "109951163626295544",
        "[礼物]": "109951163626289683",
        "[男孩]": "109951163626290620",
        "[女孩]": "109951163626294052",
        "[蛋糕]": "109951163626292081",
        "[18]": "109951163626287765",
        "[圈]": "109951163626290623",
        "[叉]": "109951163626286350",
        "[多多大笑]": "109951163626285326",
        "[多多耍酷]": "109951163626286808",
        "[多多比耶]": "109951163626291112",
        "[多多大哭]": "109951163626288209",
        "[多多瞌睡]": "109951163626285332",
        "[多多难过]": "109951163626282475",
        "[多多笑哭]": "109951163626295026",
        "[多多可怜]": "109951163626289680",
        "[多多无语]": "109951163626291589",
        "[多多捂脸]": "109951163626287335",
        "[多多亲吻]": "109951163626285824",
        "[多多调皮]": "109951163626288207",
        "[西西心动]": "109951163626284860",
        "[西西发怒]": "109951163626291586",
        "[西西惊讶]": "109951163626290613",
        "[西西奸笑]": "109951163626285329",
        "[西西晕了]": "109951163626294527",
        "[西西机智]": "109951163626295022",
        "[西西惊吓]": "109951163626292571",
        "[西西流汗]": "109951163626281959",
        "[西西呕吐]": "109951163626287760",
        "[西西再见]": "109951163626290116",
        "[西西疑问]": "109951163626285827"
    ]
}

#if !COMMENT_EMOJI_CHECK
@MainActor
struct CommentEmojiText: View {
    let content: String
    private let parts: [CommentEmojiPart]

    @State private var images: [String: NSImage] = [:]

    init(content: String, remotePictureIDs: [String: String]) {
        self.content = content
        parts = CommentEmojiCatalog.parts(in: content, remotePictureIDs: remotePictureIDs)
    }

    var body: some View {
        renderedText
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityLabel(Text(content))
            .task(id: parts) { await loadImages() }
    }

    private var renderedText: Text {
        parts.reduce(Text("")) { result, part in
            switch part {
            case let .text(text):
                result + Text(text)
            case let .emoji(token, _):
                if let image = images[token] {
                    result + Text(Image(nsImage: image)).baselineOffset(-3)
                } else {
                    result + Text(token)
                }
            }
        }
    }

    private func loadImages() async {
        images = [:]
        var loadedImages: [String: NSImage] = [:]
        for case let .emoji(token, url) in parts where loadedImages[token] == nil {
            guard let request = ArtworkPipeline.request(for: url, size: CGSize(width: 24, height: 24)) else {
                continue
            }
            do {
                let loadedImage = try await ArtworkPipeline.shared.loadImage(for: request)
                try Task.checkCancellation()
                let image = loadedImage.copy() as? NSImage ?? loadedImage
                image.size = NSSize(width: 18, height: 18)
                loadedImages[token] = image
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
        guard !Task.isCancelled else { return }
        images = loadedImages
    }
}
#else
@main
private enum CommentEmojiCheck {
    static func main() {
        let cryURL = CommentEmojiCatalog.imageURL(for: "[多多大哭]")!
        assert(
            cryURL.absoluteString
                == "https://p1.music.126.net/XuQpmBaIzQ6uJ3mtmSBESQ==/109951163626288209.jpg"
        )
        assert(CommentEmojiCatalog.parts(in: "前[汗]中[多多大哭]后[未知]") == [
            .text("前"),
            .emoji(token: "[汗]", url: CommentEmojiCatalog.imageURL(for: "[汗]")!),
            .text("中"),
            .emoji(token: "[多多大哭]", url: cryURL),
            .text("后[未知]")
        ])
        let remotePictureIDs = ["[爆笑]": "109951171993690999"]
        assert(CommentEmojiCatalog.parts(in: "新[爆笑]", remotePictureIDs: remotePictureIDs) == [
            .text("新"),
            .emoji(
                token: "[爆笑]",
                url: CommentEmojiCatalog.imageURL(for: "[爆笑]", remotePictureIDs: remotePictureIDs)!
            )
        ])
        print("Comment emoji check passed")
    }
}
#endif
