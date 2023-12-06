//
//  CurrentMediaThumbnails.swift
//  iina
//
//  Created by Matt Svoboda on 12/4/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

struct Thumbnail {
  let image: NSImage
  let timestamp: Double
}

class SingleMediaThumbnailsLoader: NSObject, FFmpegControllerDelegate {
  unowned let player: PlayerCore!
  let mediaFilePath: String
  let mediaFilePathMD5: String
  let thumbnailWidth: Int
  let rotationDegrees: Int

  var isCancelled = false
  var thumbnailsProgress: Double = 0
  var ffThumbnails: [FFThumbnail] = []
  var thumbnails: [Thumbnail] = []
  var lastThumbFFTimestamp: Double = -1

  lazy var ffmpegController: FFmpegController = {
    let controller = FFmpegController()
    controller.delegate = self
    return controller
  }()

  var log: Logger.Subsystem {
    return player.log
  }

  init(_ player: PlayerCore, mediaFilePath: String, mediaFilePathMD5: String, videoRawSize: NSSize, rotationDegrees: Int) {
    self.player = player
    self.mediaFilePath = mediaFilePath
    self.mediaFilePathMD5 = mediaFilePathMD5
    self.thumbnailWidth = SingleMediaThumbnailsLoader.determineWidthOfThumbnail(from: videoRawSize, log: player.log)
    self.rotationDegrees = rotationDegrees
  }

  /// We want the requested length of thumbnail to correspond to whichever video dimension is longer, and then get the corresponding width.
  /// Example: if video's native size is 600 W x 800 H and requested thumbnail size is 100, then `thumbWidth` should be 75.
  private static func determineWidthOfThumbnail(from videoRawSize: NSSize, log: Logger.Subsystem) -> Int {
    let sizeOption: Preference.ThumbnailSizeOption = Preference.enum(for: .thumbnailSizeOption)
    switch sizeOption {
    case .scaleWithViewport:
      let rawSizePercentage = CGFloat(min(max(0, Preference.integer(for: .thumbnailRawSizePercentage)), 100))
      let thumbWidth = Int(round(videoRawSize.width * rawSizePercentage / 100))
      log.verbose("Thumbnail native width will be \(thumbWidth)px (\(rawSizePercentage)% of video's \(Int(videoRawSize.width))px)")
      return thumbWidth
    case .fixedSize:
      let requestedLength = CGFloat(Preference.integer(for: .thumbnailFixedLength))
      let thumbWidth: CGFloat
      if videoRawSize.height > videoRawSize.width {
        // Match requested size to video height
        if requestedLength > videoRawSize.height {
          // Do not go bigger than video's native width
          thumbWidth = videoRawSize.width
          log.debug("Video's height is longer than its width, and thumbLength (\(requestedLength)) is larger than video's native height (\(videoRawSize.height)); clamping thumbWidth to \(videoRawSize.width)")
        } else {
          thumbWidth = round(requestedLength * videoRawSize.aspect)
          log.debug("Video's height (\(videoRawSize.height)) is longer than its width (\(videoRawSize.width)); scaling down thumbWidth to \(thumbWidth)")
        }
      } else {
        // Match requested size to video width
        if requestedLength > videoRawSize.width {
          log.debug("Requested thumblLength (\(requestedLength)) is larger than video's native width; clamping thumbWidth to \(videoRawSize.width)")
          thumbWidth = videoRawSize.width
        } else {
          thumbWidth = requestedLength
        }
      }
      let thumbWidthInt = Int(thumbWidth)
      log.verbose("Using fixed thumbnail width of \(thumbWidthInt)")
      return thumbWidthInt
    }
  }

  func loadThumbnails() {
    dispatchPrecondition(condition: .onQueue(PlayerCore.thumbnailQueue))

    let cacheName = mediaFilePathMD5
    if ThumbnailCache.fileIsCached(forName: cacheName, forVideo: mediaFilePath, forWidth: thumbnailWidth) {
      log.debug("Found matching thumbnail cache \(cacheName.quoted), width: \(thumbnailWidth)px")
      if let thumbnails = ThumbnailCache.read(forName: cacheName, forWidth: thumbnailWidth) {
        if thumbnails.count >= AppData.minThumbnailsPerFile {
          addThumbnails(thumbnails)
          thumbnailsProgress = 1
          DispatchQueue.main.async{ [self] in
            player.refreshTouchBarSlider()
          }
          return
        } else {
          log.error("Expected at least \(AppData.minThumbnailsPerFile) thumbnails, but found only \(thumbnails.count) (width \(thumbnailWidth)px). Will try to regenerate")
        }
      } else {
        log.error("Cannot read thumbnails from cache \(cacheName.quoted), width \(thumbnailWidth)px. Will try to regenerate")
      }
    }

    log.debug("Generating new thumbnails for file \(mediaFilePath.pii.quoted), width=\(thumbnailWidth)")
    ffmpegController.generateThumbnail(forFile: mediaFilePath, thumbWidth:Int32(thumbnailWidth))
  }

  private func addThumbnails(_ ffThumbnails: [FFThumbnail]) {
    let sw = Utility.Stopwatch()
    if rotationDegrees != 0 {
      log.verbose("Rotating \(ffThumbnails.count) thumbnails by \(rotationDegrees)° clockwise")
    }

    for ffThumbnail in ffThumbnails {
      guard let rawImage = ffThumbnail.image else { continue }

      let image: NSImage
      if rotationDegrees != 0 {
        // Rotation is an expensive procedure. Do it up front so that thumbnail display is snappier.
        // Reverse the rotation direction because mpv is opposite direction of Core Graphics
        image = rawImage.rotated(degrees: -rotationDegrees)
      } else {
        image = rawImage
      }
      self.ffThumbnails.append(ffThumbnail)
      let thumb = Thumbnail(image: image, timestamp: ffThumbnail.realTime)
      self.thumbnails.append(thumb)
    }

    if rotationDegrees != 0 {
      log.verbose("Rotated thumbnails in \(sw) ms")
    }
  }

  func getThumbnail(forSecond sec: Double) -> Thumbnail? {
    guard !thumbnails.isEmpty else { return nil }
    var tb = thumbnails.last!
    for i in 0..<thumbnails.count {
      if thumbnails[i].timestamp >= sec {
        tb = thumbnails[(i == 0 ? i : i - 1)]
        break
      }
    }
    return tb
  }

  // MARK: - FFmpegControllerDelegate implementation

  func didUpdate(_ thumbnails: [FFThumbnail]?, forFile filename: String, thumbWidth width: Int32, withProgress progress: Int) {
    guard !isCancelled else {
      log.debug("Discarding thumbnails update (\(width)px width, progress \(progress)) due to cancel")
      return
    }
    guard mediaFilePath == filename, width == thumbnailWidth else {
      log.warn("Discarding thumbnails update (\(width)px width, progress \(progress)): either sourcePath or thumbnailWidth does not match expected")
      return
    }
    let targetCount = ffmpegController.thumbnailCount
    PlayerCore.thumbnailQueue.async { [self] in
      if let thumbnails = thumbnails, thumbnails.count > 0 {
        addThumbnails(thumbnails)
      }
      log.debug("Got \(thumbnails?.count ?? 0) more \(width)px thumbs (\(self.thumbnails.count) so far), progress: \(progress) / \(targetCount)")
      thumbnailsProgress = Double(progress) / Double(targetCount)
      DispatchQueue.main.async { [self] in
        // TODO: this call is currently unnecessary. But should add code to make thumbnails displayable as they come in.
        player.refreshTouchBarSlider()
      }
    }
  }

  func didGenerate(_ thumbnails: [FFThumbnail], forFile filename: String, thumbWidth width: Int32, succeeded: Bool) {
    guard !isCancelled else {
      log.debug("Discarding thumbnails (\(width)px), due to cancel")
      return
    }
    guard mediaFilePath == filename, width == thumbnailWidth else {
      log.error("Ignoring generated thumbnails (\(width)px width): either filePath or thumbnailWidth does not match expected")
      return
    }
    log.debug("Done generating thumbnails: success=\(succeeded) count=\(thumbnails.count) width=\(width)px")
    if succeeded {
      player.refreshTouchBarSlider()

      PlayerCore.thumbnailQueue.async { [self] in
        guard !ffThumbnails.isEmpty else {
          log.verbose("No thumbnails to write")
          return
        }
        ThumbnailCache.write(ffThumbnails, forName: mediaFilePathMD5, forVideo: mediaFilePath, forWidth: Int(width))
        ffThumbnails = []  // free the memory - not needed anymore
      }
      player.events.emit(.thumbnailsReady)
    }
  }
}