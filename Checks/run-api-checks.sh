#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

export TINYCLOUDMUSIC_COOKIE=${TINYCLOUDMUSIC_COOKIE-}
export TINYCLOUDMUSIC_MUSIC_U=${TINYCLOUDMUSIC_MUSIC_U-}

COMMON_SOURCES=(
  Sources/TinyCloudMusic/Models.swift
  Sources/TinyCloudMusic/ListeningReportModels.swift
  Sources/TinyCloudMusic/ListenTogetherModels.swift
  Sources/TinyCloudMusic/VideoModels.swift
  Sources/TinyCloudMusic/VideoDownload.swift
  Sources/TinyCloudMusic/AudioContentModels.swift
  Sources/TinyCloudMusic/MusicKnowledgeModels.swift
  Sources/TinyCloudMusic/RecommendationMemoryModels.swift
  Sources/TinyCloudMusic/Repository.swift
  Sources/TinyCloudMusic/CredentialSnapshot.swift
  Sources/TinyCloudMusic/CredentialStore.swift
  Sources/TinyCloudMusic/EAPITransport.swift
  Sources/TinyCloudMusic/MusicDownloadModels.swift
  Sources/TinyCloudMusic/MusicDownloadTransfer.swift
  Sources/TinyCloudMusic/MusicDownloadInfrastructure.swift
  Sources/TinyCloudMusic/TrackCache.swift
  Sources/TinyCloudMusic/CloudMusicModels.swift
  Sources/TinyCloudMusic/MusicLibraryModels.swift
  Sources/TinyCloudMusic/MusicExtraModels.swift
  Sources/TinyCloudMusic/PlaylistImageUpload.swift
  Sources/TinyCloudMusic/AudioUploadModels.swift
  Sources/TinyCloudMusic/NOSAudioUpload.swift
  Sources/TinyCloudMusic/AudioUploadAPI.swift
  Sources/TinyCloudMusic/AudioUploadManager.swift
  Sources/TinyCloudMusic/LiveMusicRepository.swift
  Sources/TinyCloudMusic/LiveMusicRepository+Search.swift
  Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift
  Sources/TinyCloudMusic/LiveMusicRepository+Home.swift
  Sources/TinyCloudMusic/LiveMusicLibrary.swift
  Sources/TinyCloudMusic/LiveListenTogetherService.swift
  Sources/TinyCloudMusic/LiveVideoLibrary.swift
  Sources/TinyCloudMusic/LiveAudioContentLibrary.swift
  Sources/TinyCloudMusic/LiveMusicKnowledgeLibrary.swift
  Sources/TinyCloudMusic/LiveMusicExtras.swift
)

swift build -j 4 -Xswiftc -warnings-as-errors
swiftc \
  Sources/TinyCloudMusic/Models.swift \
  Sources/TinyCloudMusic/CredentialSnapshot.swift \
  Sources/TinyCloudMusic/CredentialStore.swift \
  Sources/TinyCloudMusic/EAPITransport.swift \
  Sources/TinyCloudMusic/RecommendationMemoryModels.swift \
  Checks/main.swift \
  -o /tmp/tinycloudmusic-core-check
/tmp/tinycloudmusic-core-check
swiftc -parse-as-library -warnings-as-errors \
  Sources/TinyCloudMusic/Models.swift \
  Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/TrackCache.swift \
  Sources/TinyCloudMusic/StreamingByteRange.swift \
  Sources/TinyCloudMusic/TrackRangeCache.swift \
  Sources/TinyCloudMusic/AudioRangeResourceLoader.swift \
  Sources/TinyCloudMusic/PlayerController.swift \
  Checks/PersonalFMQueueCheck.swift \
  -o /tmp/tinycloudmusic-personal-fm-queue-check
/tmp/tinycloudmusic-personal-fm-queue-check
swiftc -warnings-as-errors \
  Sources/TinyCloudMusic/EAPITransport.swift \
  Sources/TinyCloudMusic/CredentialSnapshot.swift \
  Sources/TinyCloudMusic/CredentialStore.swift \
  Checks/EAPICheck.swift \
  -o /tmp/tinycloudmusic-eapi-check
/tmp/tinycloudmusic-eapi-check
swiftc -parse-as-library -warnings-as-errors \
  Sources/TinyCloudMusic/EAPITransport.swift \
  Sources/TinyCloudMusic/CredentialSnapshot.swift \
  Sources/TinyCloudMusic/CredentialStore.swift \
  Checks/CacheCheck.swift \
  -o /tmp/tinycloudmusic-cache-check
/tmp/tinycloudmusic-cache-check
swiftc -D TRACK_CACHE_CHECK -warnings-as-errors \
  Sources/TinyCloudMusic/TrackCache.swift \
  Tests/TinyCloudMusicTests/TrackCacheTests.swift \
  -o /tmp/tinycloudmusic-track-cache-check
/tmp/tinycloudmusic-track-cache-check
swiftc -parse-as-library -warnings-as-errors Checks/APIParityCheck.swift -o /tmp/tinycloudmusic-api-parity-check
/tmp/tinycloudmusic-api-parity-check
swiftc -warnings-as-errors "${COMMON_SOURCES[@]}" Checks/WriteAPIContractCheck.swift -o /tmp/tinycloudmusic-write-api-check
/tmp/tinycloudmusic-write-api-check
swiftc -warnings-as-errors "${COMMON_SOURCES[@]}" Checks/PlaybackAvailabilityCheck.swift -o /tmp/tinycloudmusic-playback-availability-check
/tmp/tinycloudmusic-playback-availability-check
swiftc -warnings-as-errors "${COMMON_SOURCES[@]}" Checks/RecommendationMemoryCheck.swift -o /tmp/tinycloudmusic-recommendation-memory-check
/tmp/tinycloudmusic-recommendation-memory-check
swiftc -D LISTENING_REPORT_CHECK -warnings-as-errors \
  "${COMMON_SOURCES[@]}" \
  Tests/TinyCloudMusicTests/ListeningReportTests.swift \
  -o /tmp/tinycloudmusic-listening-report-check
/tmp/tinycloudmusic-listening-report-check
swiftc -D VIDEO_CHECK -warnings-as-errors \
  "${COMMON_SOURCES[@]}" \
  Sources/TinyCloudMusic/MusicDownload.swift \
  Tests/TinyCloudMusicTests/VideoTests.swift \
  -o /tmp/tinycloudmusic-video-check
/tmp/tinycloudmusic-video-check
swiftc -D AUDIO_CONTENT_CHECK -warnings-as-errors \
  "${COMMON_SOURCES[@]}" \
  Tests/TinyCloudMusicTests/AudioContentTests.swift \
  -o /tmp/tinycloudmusic-audio-content-check
/tmp/tinycloudmusic-audio-content-check
swiftc -D AUDIO_UPLOAD_CHECK -warnings-as-errors \
  "${COMMON_SOURCES[@]}" \
  Tests/TinyCloudMusicTests/AudioUploadTests.swift \
  -o /tmp/tinycloudmusic-audio-upload-check
/tmp/tinycloudmusic-audio-upload-check
swiftc -D MUSIC_KNOWLEDGE_CHECK -warnings-as-errors \
  Sources/TinyCloudMusic/Models.swift \
  Sources/TinyCloudMusic/CredentialSnapshot.swift \
  Sources/TinyCloudMusic/CredentialStore.swift \
  Sources/TinyCloudMusic/EAPITransport.swift \
  Sources/TinyCloudMusic/MusicKnowledgeModels.swift \
  Sources/TinyCloudMusic/MusicSheetWorker.swift \
  Tests/TinyCloudMusicTests/MusicKnowledgeTests.swift \
  -o /tmp/tinycloudmusic-knowledge-check
/tmp/tinycloudmusic-knowledge-check
swiftc -D CLOUD_MUSIC_CHECK -warnings-as-errors \
  "${COMMON_SOURCES[@]}" \
  Sources/TinyCloudMusic/MusicDownload.swift \
  Tests/TinyCloudMusicTests/CloudMusicTests.swift \
  -o /tmp/tinycloudmusic-cloud-music-check
/tmp/tinycloudmusic-cloud-music-check
swiftc -D MUSIC_DOWNLOAD_CHECK -warnings-as-errors \
  "${COMMON_SOURCES[@]}" \
  Sources/TinyCloudMusic/MusicDownload.swift \
  Tests/TinyCloudMusicTests/MusicDownloadTests.swift \
  -o /tmp/tinycloudmusic-download-check
/tmp/tinycloudmusic-download-check
swiftc -warnings-as-errors "${COMMON_SOURCES[@]}" Checks/LiveAPICheck.swift -o /tmp/tinycloudmusic-live-api-check
/tmp/tinycloudmusic-live-api-check
