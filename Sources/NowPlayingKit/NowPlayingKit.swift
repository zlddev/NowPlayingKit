//
//  NowPlayingKit.swift
//  NowPlayingKit
//
//  Created by Adrian Castro on 8/5/25.
//

import Combine
import Foundation
import MusicKit
import UIKit
import MediaPlayer

public enum NowPlayingError: Error {
    case noCurrentEntry
    case unauthorized
}

public struct NowPlayingData: Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String?
    public let artworkURL: URL?
    public let playbackTime: TimeInterval
    public let duration: TimeInterval

    public init(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        artworkURL: URL? = nil,
        playbackTime: TimeInterval = 0,
        duration: TimeInterval = 1
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.playbackTime = playbackTime
        self.duration = duration
    }
}

public final class NowPlayingManager: @unchecked Sendable {
    public static let shared = NowPlayingManager()
    
    #if os(iOS)
    private let player = SystemMusicPlayer.shared
    #endif

    @Published public private(set) var isPlaying = false

    // Caches catalog-search fallback lookups (see resolveCatalogArtworkURL)
    // so a track without a usable artwork URL doesn't re-search Apple
    // Music's catalog on every ~1s playback poll. NSCache is thread-safe,
    // which matters since this class is `@unchecked Sendable` and its
    // methods can be called concurrently from multiple Tasks. NSCache can't
    // store nil, so a "not found" result is cached as `notFoundSentinel`
    // rather than skipping the cache entirely.
    private let artworkLookupCache = NSCache<NSString, NSURL>()
    private static let notFoundSentinel = NSURL(string: "x-irpc-not-found:")!

    // Publisher for immediate state changes
    private let playbackStateSubject = PassthroughSubject<Bool, Never>()
    public var playbackStatePublisher: AnyPublisher<Bool, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    private init() {
        #if os(iOS)
        // Set initial state
        self.isPlaying = player.state.playbackStatus == .playing
        
        // Emit initial state through publisher
        playbackStateSubject.send(isPlaying)
        
        // Use Combine publisher for state changes
        Task {
            // Monitor both state and queue changes
            for await _ in player.state.objectWillChange.values {
                await MainActor.run {
                    checkAndUpdatePlaybackState()
                }
            }
        }
        
        Task {
            for await _ in player.queue.objectWillChange.values {
                await MainActor.run {
                    checkAndUpdatePlaybackState()
                }
            }
        }
        
        // Setup notification observers for additional monitoring
        setupNotificationObservers()
        #endif
    }
    
    #if os(iOS)
    private func setupNotificationObservers() {
        // Listen to system notifications that might indicate playback changes
        let notificationCenter = NotificationCenter.default
        let notifications: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            NSNotification.Name.MPMusicPlayerControllerPlaybackStateDidChange,
            NSNotification.Name.MPMusicPlayerControllerNowPlayingItemDidChange
        ]
        
        for notification in notifications {
            notificationCenter.addObserver(
                self,
                selector: #selector(handlePlaybackStateChange),
                name: notification,
                object: nil
            )
        }
    }
    #endif
    
    private func checkAndUpdatePlaybackState() {
        #if os(iOS)
        let currentState = player.state.playbackStatus == .playing
        if self.isPlaying != currentState {
            print("🎵 Playback state updating: \(self.isPlaying) -> \(currentState)")
            self.isPlaying = currentState
            
            // Emit through the publisher for immediate updates
            playbackStateSubject.send(currentState)
        }
        #endif
    }
    
    @objc private func handlePlaybackStateChange() {
        checkAndUpdatePlaybackState()
    }

    public func authorize() async -> MusicAuthorization.Status {
        #if os(iOS)
            return await MusicAuthorization.request()
        #else
            return .notDetermined
        #endif
    }

    public func getCurrentPlayback() async throws -> NowPlayingData {
        #if os(iOS)
            let authStatus = MusicAuthorization.currentStatus
            guard authStatus == .authorized else {
                throw NowPlayingError.unauthorized
            }

            guard let entry = player.queue.currentEntry else {
                throw NowPlayingError.noCurrentEntry
            }

            var id = ""
            let title = entry.title
            var artist = ""
            var album: String? = nil
            var duration: TimeInterval = 1
            var catalogArtwork: MusicKit.Artwork? = nil

            if let item = entry.item {
                switch item {
                case .song(let song):
                    id = song.id.rawValue
                    duration = song.duration ?? 1
                    artist = song.artistName
                    album = song.albumTitle
                    catalogArtwork = song.artwork
                case .musicVideo(let musicVideo):
                    id = musicVideo.id.rawValue
                    duration = musicVideo.duration ?? 1
                    artist = musicVideo.artistName
                    catalogArtwork = musicVideo.artwork
                @unknown default:
                    duration = 1
                }
            }

            // Prefer the catalog item's own artwork (a real https CDN URL)
            // over the queue entry's artwork. For tracks in the user's
            // personal library, `entry.artwork` frequently resolves to a
            // private `musicKit://artwork/library/...` reference that only
            // MusicKit's on-device renderer (e.g. SwiftUI's ArtworkImage)
            // can load — not a fetchable network URL, so it just hangs for
            // AsyncImage or any remote consumer (like Discord Rich Presence).
            let candidateURL =
                catalogArtwork?.url(width: 300, height: 300)
                ?? entry.artwork?.url(width: 300, height: 300)
            var artworkURL = candidateURL.flatMap { url -> URL? in
                guard let scheme = url.scheme?.lowercased(),
                    scheme == "http" || scheme == "https"
                else {
                    print(
                        "⚠️ Ignoring non-network artwork URL (scheme: \(url.scheme ?? "none")): \(url.absoluteString)"
                    )
                    return nil
                }
                return url
            }

            // Local-library tracks with no catalog match never get a
            // network artwork URL from the queue entry itself — fall back
            // to searching the Apple Music catalog by title/artist for a
            // best-effort match with real https artwork, instead of
            // shipping no artwork at all.
            if artworkURL == nil, !id.isEmpty, !title.isEmpty {
                artworkURL = await resolveCatalogArtworkURL(id: id, title: title, artist: artist)
            }

            return NowPlayingData(
                id: id,
                title: title,
                artist: artist,
                album: album,
                artworkURL: artworkURL,
                playbackTime: player.playbackTime,
                duration: duration
            )
        #else
            throw NowPlayingError.unauthorized
        #endif
    }

    #if os(iOS)
    /// Best-effort fallback for tracks whose queue entry has no fetchable
    /// artwork URL (private on-device `musicKit://artwork/library/...`
    /// references, which is what the personal library hands back for
    /// tracks that aren't 1:1 matched to an Apple Music catalog item).
    /// Searches the catalog by title/artist and uses the top match's
    /// artwork — a heuristic, not a guaranteed-correct match, but far
    /// better than shipping no artwork.
    private func resolveCatalogArtworkURL(id: String, title: String, artist: String) async -> URL? {
        let key = id as NSString
        if let cached = artworkLookupCache.object(forKey: key) {
            return cached === Self.notFoundSentinel ? nil : cached as URL
        }

        do {
            var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
            request.limit = 1
            let response = try await request.response()
            let resolved = response.songs.first?.artwork?.url(width: 300, height: 300)
            artworkLookupCache.setObject(resolved.map { $0 as NSURL } ?? Self.notFoundSentinel, forKey: key)
            if let resolved {
                print("🖼️ Resolved catalog artwork for \(title): \(resolved.absoluteString)")
            } else {
                print("⚠️ No catalog match found for \(title) by \(artist)")
            }
            return resolved
        } catch {
            print("⚠️ Catalog artwork search failed for \(title): \(error.localizedDescription)")
            // Deliberately not cached — a transient network/token failure
            // shouldn't permanently blacklist this track for the rest of
            // the session.
            return nil
        }
    }
    #endif

    deinit {
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        #endif
    }
}

extension SystemMusicPlayer {
    public static let playbackStateDidChangeNotification = NSNotification.Name("SystemMusicPlayerPlaybackStateDidChange")
}