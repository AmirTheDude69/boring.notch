//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private static let lrcTimestampRegex = try? NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,2}))?\]"#
    )
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?
    private var lyricsFetchTask: Task<Void, Never>?
    private var activeLyricsRequestID: UUID?

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published var plainLyricsLines: [String] = []
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()
        lyricsFetchTask?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            if artworkChanged || state.artwork == nil {
                // Update last artwork change values
                self.lastArtworkTitle = state.title
                self.lastArtworkArtist = state.artist
                self.lastArtworkAlbum = state.album
                self.lastArtworkBundleIdentifier = state.bundleIdentifier
            }

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }

            // Fetch lyrics on content change
            self.fetchLyricsIfAvailable(
                bundleIdentifier: state.bundleIdentifier,
                title: state.title,
                artist: state.artist,
                album: state.album,
                duration: state.duration
            )
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    func toggleLyricsDisplay() {
        let enabled = !Defaults[.enableLyrics]
        Defaults[.enableLyrics] = enabled

        guard enabled else {
            clearLyrics()
            return
        }

        fetchLyricsIfAvailable(
            bundleIdentifier: bundleIdentifier,
            title: songTitle,
            artist: artistName,
            album: album,
            duration: songDuration
        )
    }

    private func fetchLyricsIfAvailable(
        bundleIdentifier: String?,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) {
        lyricsFetchTask?.cancel()

        let cleanTitle = normalizedQuery(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = normalizedQuery(artist).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAlbum = normalizedQuery(album).trimmingCharacters(in: .whitespacesAndNewlines)

        guard Defaults[.enableLyrics], !cleanTitle.isEmpty else {
            clearLyrics()
            return
        }

        let requestID = UUID()
        activeLyricsRequestID = requestID
        isFetchingLyrics = true
        currentLyrics = ""
        syncedLyrics = []
        plainLyricsLines = []

        lyricsFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let isAppleMusic = bundleIdentifier?.contains("com.apple.Music") == true
            var result = await self.fetchLyricsFromWeb(
                title: cleanTitle,
                artist: cleanArtist,
                album: cleanAlbum,
                duration: duration
            )

            if Task.isCancelled { return }

            if result == nil, isAppleMusic {
                result = await self.fetchNativeAppleMusicLyrics()
            }

            guard self.activeLyricsRequestID == requestID else { return }
            self.applyLyricsResult(result)
        }
    }

    private func clearLyrics() {
        lyricsFetchTask?.cancel()
        activeLyricsRequestID = nil
        isFetchingLyrics = false
        currentLyrics = ""
        syncedLyrics = []
        plainLyricsLines = []
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    @MainActor
    private func fetchLyricsFromWeb(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async -> LyricsFetchResult? {
        if duration > 0,
           let exactURL = lrclibURL(
            endpoint: "get",
            queryItems: lrclibQueryItems(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                includeAlbum: true
            )
           ) {
            let exactResult: LRCLibTrack? = await fetchLRCLibResult(from: exactURL)
            if let exactResult {
                return exactResult.lyricsResult()
            }
        }

        guard let searchURL = lrclibURL(
            endpoint: "search",
            queryItems: lrclibQueryItems(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                includeAlbum: false
            )
        ) else {
            return nil
        }

        let results: [LRCLibTrack]? = await fetchLRCLibResult(from: searchURL)
        guard let results else { return nil }
        return bestLyricsMatch(
            in: results,
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )?.lyricsResult()
    }

    private func lrclibQueryItems(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        includeAlbum: Bool
    ) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "track_name", value: title)]

        if !artist.isEmpty, artist.caseInsensitiveCompare("Unknown") != .orderedSame {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }

        if includeAlbum, !album.isEmpty, album.caseInsensitiveCompare("Unknown") != .orderedSame {
            items.append(URLQueryItem(name: "album_name", value: album))
        }

        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: "\(Int(duration.rounded()))"))
        }

        return items
    }

    private func lrclibURL(endpoint: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/\(endpoint)"
        components.queryItems = queryItems
        return components.url
    }

    private func fetchLRCLibResult<T: Decodable>(from url: URL) async -> T? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private func bestLyricsMatch(
        in tracks: [LRCLibTrack],
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> LRCLibTrack? {
        tracks
            .filter { $0.lyricsResult() != nil }
            .max { lhs, rhs in
                scoreLyricsMatch(lhs, title: title, artist: artist, album: album, duration: duration)
                    < scoreLyricsMatch(rhs, title: title, artist: artist, album: album, duration: duration)
            }
    }

    private func scoreLyricsMatch(
        _ track: LRCLibTrack,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> Int {
        var score = 0
        let requestedTitle = title.normalizedForLyricsMatching
        let requestedArtist = artist.normalizedForLyricsMatching
        let requestedAlbum = album.normalizedForLyricsMatching
        let foundTitle = track.trackName.normalizedForLyricsMatching
        let foundArtist = track.artistName.normalizedForLyricsMatching
        let foundAlbum = (track.albumName ?? "").normalizedForLyricsMatching

        if foundTitle == requestedTitle { score += 60 }
        else if foundTitle.contains(requestedTitle) || requestedTitle.contains(foundTitle) { score += 30 }

        if !requestedArtist.isEmpty {
            if foundArtist == requestedArtist { score += 45 }
            else if foundArtist.contains(requestedArtist) || requestedArtist.contains(foundArtist) { score += 18 }
        }

        if !requestedAlbum.isEmpty {
            if foundAlbum == requestedAlbum { score += 16 }
            else if foundAlbum.contains(requestedAlbum) || requestedAlbum.contains(foundAlbum) { score += 6 }
        }

        if duration > 0 {
            if let foundDuration = track.duration {
                let difference = abs(foundDuration - duration)
                switch difference {
                case 0...2: score += 35
                case 2...5: score += 20
                case 5...10: score += 8
                default: break
                }
            }
        }

        if let synced = track.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 10
        }

        return score
    }

    @MainActor
    private func fetchNativeAppleMusicLyrics() async -> LyricsFetchResult? {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return nil }

        let script = """
        tell application \"Music\"
            if it is running then
                if player state is playing or player state is paused then
                    try
                        set l to lyrics of current track
                        if l is missing value then
                            return \"\"
                        else
                            return l
                        end if
                    on error
                        return \"\"
                    end try
                else
                    return \"\"
                end if
            else
                return \"\"
            end if
        end tell
        """

        guard let result = try? await AppleScriptHelper.execute(script),
              let lyricsString = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lyricsString.isEmpty else {
            return nil
        }

        return LyricsFetchResult(plainLyrics: lyricsString, syncedLyrics: nil)
    }

    private func applyLyricsResult(_ result: LyricsFetchResult?) {
        isFetchingLyrics = false
        guard let result else {
            currentLyrics = ""
            syncedLyrics = []
            plainLyricsLines = []
            return
        }

        currentLyrics = result.plainLyrics
        plainLyricsLines = parsePlainLyrics(result.plainLyrics)

        if let syncedLyrics = result.syncedLyrics, !syncedLyrics.isEmpty {
            self.syncedLyrics = parseLRC(syncedLyrics)
        } else {
            self.syncedLyrics = []
        }
    }

    // MARK: - Synced lyrics helpers
    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        guard let regex = Self.lrcTimestampRegex else { return [] }

        var result: [(Double, String)] = []
        lrc.split(separator: "\n").forEach { lineSub in
            let line = String(lineSub)
            let nsLine = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let minStr = nsLine.substring(with: match.range(at: 1))
                let secStr = nsLine.substring(with: match.range(at: 2))
                let csRange = match.range(at: 3)
                let centiStr = csRange.location != NSNotFound ? nsLine.substring(with: csRange) : "0"
                let minutes = Double(minStr) ?? 0
                let seconds = Double(secStr) ?? 0
                let centis = Double(centiStr) ?? 0
                let time = minutes * 60 + seconds + centis / 100.0
                let textStart = match.range.location + match.range.length
                let text = nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    result.append((time, text))
                }
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private func parsePlainLyrics(_ lyrics: String) -> [String] {
        lyrics
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func lyricDisplayLine(at elapsed: Double) -> String? {
        if isFetchingLyrics {
            return "Searching lyrics..."
        }

        if !syncedLyrics.isEmpty || !plainLyricsLines.isEmpty {
            return lyricLine(at: elapsed)
        }

        return nil
    }

    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else {
            guard !plainLyricsLines.isEmpty else { return currentLyrics }
            guard songDuration > 0 else { return plainLyricsLines.first ?? currentLyrics }

            let progress = min(max(elapsed / songDuration, 0), 0.999)
            let index = min(Int(progress * Double(plainLyricsLines.count)), plainLyricsLines.count - 1)
            return plainLyricsLines[index]
        }
        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return syncedLyrics[idx].text
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}

private struct LRCLibTrack: Decodable {
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    func lyricsResult() -> LyricsFetchResult? {
        guard instrumental != true else { return nil }

        let plain = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let synced = syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !plain.isEmpty || !synced.isEmpty else { return nil }

        return LyricsFetchResult(
            plainLyrics: plain.isEmpty ? synced : plain,
            syncedLyrics: synced.isEmpty ? nil : synced
        )
    }
}

private struct LyricsFetchResult {
    let plainLyrics: String
    let syncedLyrics: String?
}

private extension String {
    var normalizedForLyricsMatching: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
