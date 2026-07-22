import Testing
@testable import TinyCloudMusic

@Suite("Live homepage decoding")
struct HomeRepositoryTests {
    @Test("Qt nested playlist and item shapes retain presentation and routes")
    func nestedHomepageShapes() throws {
        let rank = try HomeBlockDecoder.decode(
            block: [
                "bizCode": "PAGE_RECOMMEND_RANK",
                "dslData": [
                    "rcmd_rank_module_v2": [
                        "blockResource": [
                            "title": "官方榜",
                            "subTitle": "每天更新",
                            "resources": [[
                                "resourceType": "toplist",
                                "resourceId": "19723756",
                                "title": "飙升榜",
                                "subTitle": "刚刚更新",
                                "coverImg": "https://example.com/rank.jpg",
                                "playCount": "42"
                            ]]
                        ]
                    ]
                ]
            ],
            requestedID: "PAGE_RECOMMEND_RANK",
            decodeSong: { _ in nil }
        )
        #expect(rank.title == "官方榜")
        #expect(rank.subtitle == "每天更新")
        #expect(rank.resources.count == 1)
        #expect(rank.resources[0].kind == .playlist)
        #expect(rank.resources[0].id == 19_723_756)
        #expect(rank.resources[0].title == "飙升榜")
        #expect(rank.resources[0].subtitle == "刚刚更新 · (42)")
        #expect(rank.resources[0].artwork.remoteURL?.absoluteString == "https://example.com/rank.jpg")

        let monthly = try HomeBlockDecoder.decode(
            block: [
                "bizCode": "PAGE_RECOMMEND_MONTH_YEAR_PLAYLIST",
                "dslData": [
                    "rcmd_annual_and_monthly_playlist_list_module_1": [
                        "blockResource": [
                            "header": ["title": "年度歌单"],
                            "items": [[
                                "resourceType": "playList",
                                "resourceId": 9,
                                "title": "年度精选",
                                "coverImg": "https://example.com/year.jpg"
                            ]]
                        ]
                    ]
                ]
            ],
            requestedID: "PAGE_RECOMMEND_MONTH_YEAR_PLAYLIST",
            decodeSong: { _ in nil }
        )
        #expect(monthly.title == "年度歌单")
        #expect(monthly.resources.map(\.id) == [9])

        let localCharts = try HomeBlockDecoder.decode(
            block: [
                "bizCode": "PAGE_RECOMMEND_LBS",
                "dslData": [
                    "home_position_rank_module_v1": [
                        "blockResourceVO": [
                            "title": "地方特色",
                            "resources": [[
                                "resourceType": "cityStyleCharts",
                                "name": "上海",
                                "coverImg": "https://example.com/shanghai.jpg",
                                "playBtn": ["playAction": ["songIds": [7, "8"]]]
                            ]]
                        ]
                    ]
                ]
            ],
            requestedID: "PAGE_RECOMMEND_LBS",
            decodeSong: { _ in nil }
        )
        #expect(localCharts.resources.map(\.id) == [7, 8])
        #expect(localCharts.resources.allSatisfy { $0.title.isEmpty && $0.subtitle == "上海" })
    }
}
