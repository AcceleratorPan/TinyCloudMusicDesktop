struct LibrarySnapshot {
    let user: MusicLibraryUser
    let songs: [Song]
    var playlists: [Playlist]
    let following: [MusicLibraryFollow]
    let recommendedUsers: [MusicRecommendedUser]
}
