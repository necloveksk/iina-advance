//
//  PlaybackInfo.swift
//  iina
//
//  Created by lhc on 21/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Foundation

class PlaybackInfo {
  unowned var log: Logger.Subsystem

  init(log: Logger.Subsystem) {
    self.log = log
  }

  /// Enumeration representing the status of the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  ///
  /// The A-B loop command cycles mpv through these states:
  /// - Cleared (looping disabled)
  /// - A loop point set
  /// - B loop point set (looping enabled)
  enum LoopStatus: Int {
    case cleared = 0
    case aSet
    case bSet
  }

  // MARK: - Playback lifecycle state
  // TODO: turn into enum?

  var isIdle: Bool = true {
    didSet {
      PlayerCore.checkStatusForSleep()
    }
  }

  /// Will be non-`nil` while restoring from a previous launch. Contains info needed to restore the UI state.
  var priorState: PlayerSaveState? =  nil

  var isRestoring: Bool {
    return priorState != nil
  }

  /// Opened or started file, but still waiting for `fileLoaded`
  // TODO: investigate combining this with `!fileLoaded` and `fileLoading`
  var justOpenedFile: Bool = true
  var timeLastFileOpenFinished: TimeInterval = 0
  var timeSinceLastFileOpenFinished: TimeInterval {
    Date().timeIntervalSince1970 - timeLastFileOpenFinished
  }

  var fileLoading: Bool = false
  var fileLoaded: Bool = false

  var shouldAutoLoadFiles: Bool = false
  var isMatchingSubtitles = false

  var isSeeking: Bool = false

  // -- PERSISTENT PROPERTIES BEGIN --

  var isPaused: Bool = false {
    willSet {
      if isPaused != newValue {
        log.verbose("Player mode changing to \(newValue ? "PAUSED" : "PLAYING")")
      }
    }
  }
  var isPlaying: Bool {
    return !isPaused
  }
  var pauseStateWasChangedLocally = false

  var currentURL: URL? {
    didSet {
      if let url = currentURL {
        mpvMd5 = Utility.mpvWatchLaterMd5(url.path)
        isNetworkResource = !url.isFileURL
      } else {
        mpvMd5 = nil
        isNetworkResource = false
      }
    }
  }

  // Derived from currentURL (no need to persist):
  var currentFolder: URL?
  var isNetworkResource: Bool = false
  var mpvMd5: String?

  var isMediaOnRemoteDrive: Bool {
    if let attrs = try? currentURL?.resourceValues(forKeys: Set([.volumeIsLocalKey])), !attrs.volumeIsLocal! {
      return true
    }
    return false
  }

  // MARK: - Geometry

  // When navigating in playlist, and user does not have any other predefined resizing strategy, try to maintain the same window width
  // even for different video sizes and aspect ratios. Since it may not be possible to fit all videos onscreen, some videos will need to
  // be shrunk down, and over time this would lead to the window shrinking into the smallest size. Instead, remember the last window size
  // which the user manually chose, and try to match that across videos.
  //
  // This is also useful when opening outside sidebars:
  // When opening a sidebar and there is not enough space on screen, the viewport will be shrunk so that the sidebar can open while
  // keeping the window fully within the bounds of the screen. But when the sidebar is closed again, the viewport / window wiil be
  // expanded again to the preferred container size.
  var intendedViewportSize: NSSize? = nil {
    didSet {
      if let newValue = intendedViewportSize {
        log.verbose("Updated intendedViewportSize to \(newValue)")
      } else {
        log.verbose("Updated intendedViewportSize to nil")
      }
    }
  }

  var videoParams: MPVVideoParams? = nil

  var videoRawWidth: Int? {
    return videoParams?.videoRawWidth
  }
  var videoRawHeight: Int? {
    return videoParams?.videoRawHeight
  }

  // Is refreshed as property change events arrive for `MPVOption.Video.videoRotate` ("video-rotate").
  // Not to be confused with the `MPVProperty.videoParamsRotate` ("video-params/rotate")
  var userRotation: Int {
    return videoParams?.userRotation ?? 0
  }

  // Is refreshed as property change events arrive for `MPVProperty.videoParamsRotate` ("video-params/rotate")
  // IINA only supports one of [0, 90, 180, 270]
  var totalRotation: Int? {
    return videoParams?.totalRotation
  }

  var cachedWindowScale: Double = 1.0

  // MARK: - Filters & Equalizers

  /// The most up-to-date aspect ratio of the video (width/height), after `totalRotation` applied.
  /// Should match `videoParams.videoDisplayRotatedAspect`
  var videoAspect: CGFloat {
    set {
      videoAspectNormalized = Aspect.mpvPrecision(of: newValue)
      log.verbose("Updated videoAspect to \(videoAspectNormalized.stringMaxFrac6)")
    }
    get {
      return videoAspectNormalized
    }
  }

  private var videoAspectNormalized: CGFloat = 1.0

  /// The currently applied aspect, used for finding current aspect in menu & sidebar segmented control. Does not include rotation(s)
  var selectedAspectRatioLabel: String = AppData.defaultAspectName
  var selectedCropLabel: String = AppData.cropNone
  var selectedRotation: Int = 0
  var cropFilter: MPVFilter?
  var flipFilter: MPVFilter?
  var mirrorFilter: MPVFilter?
  var audioEqFilters: [MPVFilter?]?
  var delogoFilter: MPVFilter?

  // [filter.name ->  filter]
  var videoFiltersDisabled: [String: MPVFilter] = [:]

  var deinterlace: Bool = false
  var hwdec: String = "no"
  var hwdecEnabled: Bool {
    hwdec != "no"
  }
  var hdrAvailable: Bool = false
  var hdrEnabled: Bool = true

  // video equalizer
  var brightness: Int = 0
  var contrast: Int = 0
  var saturation: Int = 0
  var gamma: Int = 0
  var hue: Int = 0

  var volume: Double = 50
  var isMuted: Bool = false

  // time
  var audioDelay: Double = 0
  var subDelay: Double = 0

  var abLoopStatus: LoopStatus = .cleared

  var playSpeed: Double = 1.0
  var videoPosition: VideoTime?
  var videoDuration: VideoTime?

  var playlist: [MPVPlaylistItem] = []

  func constrainVideoPosition() {
    guard let duration = videoDuration, let position = videoPosition else { return }
    if position.second < 0 { videoPosition = VideoTime.zero }
    if position.second > duration.second { videoPosition = duration }
  }

  /** Selected track IDs. Use these (instead of `isSelected` of a track) to check if selected */
  var aid: Int?
  var sid: Int?
  var vid: Int?
  var secondSid: Int?

  var isAudioTrackSelected: Bool {
    if let aid {
      return aid != 0
    }
    return false
  }

  var isVideoTrackSelected: Bool {
    if let vid {
      return vid != 0
    }
    return false
  }

  var isSubVisible = true
  var isSecondSubVisible = true

  enum CurrentMediaAudioStatus {
    case unknown
    case isAudio
    case notAudio
  }

  var currentMediaAudioStatus: CurrentMediaAudioStatus {
    guard !isNetworkResource else { return .notAudio }
    let noVideoTrack = videoTracks.isEmpty
    let noAudioTrack = audioTracks.isEmpty
    if noVideoTrack && noAudioTrack {
      return .unknown
    }
    if noVideoTrack {
      return .isAudio
    }
    let allVideoTracksAreAlbumCover = !videoTracks.contains { !$0.isAlbumart }
    if allVideoTracksAreAlbumCover {
      return .isAudio
    }
    return .notAudio
  }

  // -- PERSISTENT PROPERTIES END --

  var currentMediaThumbnails: SingleMediaThumbnailsLoader? = nil

  var chapter = 0
  var chapters: [MPVChapter] = []

  var audioTracks: [MPVTrack] = []
  var videoTracks: [MPVTrack] = []
  var subTracks: [MPVTrack] = []

  func replaceTracks(audio: [MPVTrack], video: [MPVTrack], sub: [MPVTrack]) {
    infoLock.withLock {
      audioTracks = audio
      videoTracks = video
      subTracks = sub
    }
  }

  func trackList(_ type: MPVTrack.TrackType) -> [MPVTrack] {
    switch type {
    case .video: return videoTracks
    case .audio: return audioTracks
    case .sub, .secondSub: return subTracks
    }
  }

  func trackId(_ type: MPVTrack.TrackType) -> Int? {
    switch type {
    case .video: return vid
    case .audio: return aid
    case .sub: return sid
    case .secondSub: return secondSid
    }
  }

  func currentTrack(_ type: MPVTrack.TrackType) -> MPVTrack? {
    let id: Int?, list: [MPVTrack]
    switch type {
    case .video:
      id = vid
      list = videoTracks
    case .audio:
      id = aid
      list = audioTracks
    case .sub:
      id = sid
      list = subTracks
    case .secondSub:
      id = secondSid
      list = subTracks
    }
    if let id = id {
      return list.first { $0.id == id }
    } else {
      return nil
    }
  }

  // MARK: - Subtitles

  var subEncoding: String?

  var haveDownloadedSub: Bool = false

  /// Map: { video `path` for each `info` of `currentVideosInfo` -> `url` for each of `info.relatedSubs` }
  @Atomic var matchedSubs: [String: [URL]] = [:]

  func getMatchedSubs(_ file: String) -> [URL]? { $matchedSubs.withLock { $0[file] } }

  var currentSubsInfo: [FileInfo] = []
  var currentVideosInfo: [FileInfo] = []

  // MARK: - Cache

  var pausedForCache: Bool = false
  var cacheUsed: Int = 0
  var cacheSpeed: Int = 0
  var cacheTime: Int = 0
  var bufferingState: Int = 0

  // The cache is read by the main thread and updated by a background thread therefore all use
  // must be through the class methods that properly coordinate thread access.
  private var cachedVideoDurationAndProgress: [String: (duration: Double?, progress: Double?)] = [:]
  private var cachedMetadata: [String: (title: String?, album: String?, artist: String?)] = [:]

  private let infoLock = Lock()

  func calculateTotalDuration() -> Double? {
    infoLock.withLock {
      let playlist: [MPVPlaylistItem] = playlist

      var totalDuration: Double? = 0
      for p in playlist {
        if let duration = cachedVideoDurationAndProgress[p.filename]?.duration {
          totalDuration! += duration > 0 ? duration : 0
        } else {
          // Cache is missing an entry, can't provide a total.
          return nil
        }
      }
      return totalDuration
    }
  }

  func calculateTotalDuration(_ indexes: IndexSet) -> Double {
    infoLock.withLock {
      let playlist = playlist
      return indexes
        .compactMap { cachedVideoDurationAndProgress[playlist[$0].filename]?.duration }
        .compactMap { $0 > 0 ? $0 : 0 }
        .reduce(0, +)
    }
  }

  func getCachedVideoDurationAndProgress(_ file: String) -> (duration: Double?, progress: Double?)? {
    infoLock.withLock {
      cachedVideoDurationAndProgress[file]
    }
  }

  func setCachedVideoDuration(_ file: String, _ duration: Double) {
    infoLock.withLock {
      cachedVideoDurationAndProgress[file]?.duration = duration
    }
  }

  func setCachedVideoDurationAndProgress(_ file: String, _ value: (duration: Double?, progress: Double?)) {
    infoLock.withLock {
      cachedVideoDurationAndProgress[file] = value
    }
  }

  func getCachedMetadata(_ file: String) -> (title: String?, album: String?, artist: String?)? {
    infoLock.withLock {
      cachedMetadata[file]
    }
  }

  func setCachedMetadata(_ file: String, _ value: (title: String?, album: String?, artist: String?)) {
    infoLock.withLock {
      cachedMetadata[file] = value
    }
  }
}
