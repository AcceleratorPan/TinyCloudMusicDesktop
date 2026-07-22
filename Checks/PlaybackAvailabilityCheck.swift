import Foundation

@main
enum PlaybackAvailabilityCheck {
    static func main() throws {
        let playable = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":1,"url":"https://m1.music.126.net/1.mp3","code":200,"level":"exhigh","type":"mp3","fee":0,"payed":0,"message":null,"freeTrialInfo":null}]}"#.utf8),
            expectedSongID: 1,
            requestedLevel: "standard"
        )
        precondition(playable.availability == .playable(level: "exhigh"))

        do {
            _ = try LiveMusicRepository.decodePlaybackSource(
                Data(#"{"code":200,"data":[{"id":1,"url":"https://example.com/1.mp3","code":200,"level":"standard"}]}"#.utf8),
                expectedSongID: 1,
                requestedLevel: "standard"
            )
            preconditionFailure("Untrusted playback host was accepted")
        } catch EAPIError.invalidResponse {
        }

        do {
            _ = try LiveMusicRepository.decodePlaybackSource(
                Data(#"{"code":200,"data":[{"id":1,"url":"https://m1.music.126.net/1.flac","code":200,"level":"lossless"}]}"#.utf8),
                expectedSongID: 1,
                requestedLevel: "jyeffect",
                requiresExactLevel: true
            )
            preconditionFailure("Explicit quality selection accepted a downgraded source")
        } catch let error as AppError {
            precondition(error == .unavailable("服务端未返回所选音质，已保留当前音质"))
        }

        let trial = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":2,"url":"https://m1.music.126.net/2.mp3","code":200,"level":"standard","type":"mp3","fee":1,"payed":0,"message":null,"freeTrialInfo":{"end":30}}]}"#.utf8),
            expectedSongID: 2,
            requestedLevel: "standard"
        )
        precondition(trial.availability == .trial(level: "standard", endSeconds: 30))

        do {
            _ = try LiveMusicRepository.decodePlaybackSource(
                Data(#"{"code":200,"data":[{"id":3,"url":null,"code":404,"level":null,"type":null,"fee":0,"payed":0,"message":null,"freeTrialInfo":null,"freeTrialPrivilege":{"cannotListenReason":1}}]}"#.utf8),
                expectedSongID: 3,
                requestedLevel: "standard"
            )
            preconditionFailure("Unavailable playback entry decoded as playable")
        } catch let error as PlaybackUnavailableError {
            precondition(error.reason == "这首歌因版权或地区限制暂时无法播放")
        }

        do {
            _ = try LiveMusicRepository.decodePlaybackSource(
                Data(#"{"code":503,"message":"temporary"}"#.utf8),
                expectedSongID: 1,
                requestedLevel: "standard"
            )
            preconditionFailure("Top-level failure decoded as playback unavailability")
        } catch let error as EAPIError {
            precondition(error == .service(code: 503, message: "temporary"))
        }

        do {
            _ = try LiveMusicRepository.decodePlaybackSource(
                Data(#"{"code":200,"data":[{"id":4,"url":null,"code":-110,"fee":0,"payed":0,"message":"https://secret.example/audio","freeTrialInfo":null}]}"#.utf8),
                expectedSongID: 4,
                requestedLevel: "standard"
            )
            preconditionFailure("Sensitive service message decoded as playable")
        } catch let error as PlaybackUnavailableError {
            precondition(error.reason == "这首歌暂时无法播放")
        }

        let qualities = try LiveMusicRepository.decodeSongQualityDetails(
            Data(#"{"code":200,"data":{"l":{"br":128000,"size":1000,"sr":44100},"h":{"br":320000,"size":3000,"sr":48000},"sq":{"br":900000,"size":9000,"sr":96000},"future":{"br":2,"size":2,"sr":2}}}"#.utf8),
            privileges: Data(#"{"code":200,"privileges":[{"maxBrLevel":"lossless","playMaxBrLevel":"lossless","plLevel":"exhigh","dlLevel":"lossless","flLevel":"none"}]}"#.utf8)
        )
        precondition(qualities.map(\.id) == ["lossless", "exhigh", "standard"])
        precondition(qualities.map(\.isAvailable) == [false, true, true])
        let premiumQualities = try LiveMusicRepository.decodeSongQualityDetails(
            Data(#"{"code":200,"data":{"jm":{"br":1900000,"size":19000,"sr":192000},"sk":{"br":900000,"size":9000,"sr":48000}}}"#.utf8),
            privileges: Data(#"{"code":200,"privileges":[{"plLevel":"sky","flLevel":"exhigh"}]}"#.utf8)
        )
        precondition(premiumQualities.map(\.id) == ["jymaster", "sky"])
        precondition(SongQualityDetail.highestAvailableLevel(in: premiumQualities) == "jymaster")
        precondition(premiumQualities.allSatisfy(\.isAvailable))

        let repository = LiveMusicRepository()
        let emptyAlternatives = try repository.decodeCopyrightAlternatives(
            Data(#"{"code":200,"data":{"rcmd":null}}"#.utf8)
        )
        precondition(emptyAlternatives.isEmpty)
        let alternatives = try repository.decodeCopyrightAlternatives(
            Data(#"{"code":200,"data":{"rcmd":{"id":9,"name":"替代版本","ar":[{"id":8,"name":"歌手"}],"al":{"id":7,"name":"专辑"},"dt":120000}}}"#.utf8)
        )
        precondition(alternatives.map(\.id) == [9])
        print("Playback availability checks passed")
    }
}
