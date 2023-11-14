//
//  ThumbnailCache.swift
//  iina
//
//  Created by lhc on 14/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

fileprivate let subsystem = Logger.makeSubsystem("thumbcache")

class ThumbnailCache {
  private typealias CacheVersion = UInt8
  private typealias FileSize = UInt64
  private typealias FileTimestamp = Int64

  static let subsystem = Logger.Subsystem(rawValue: "thumbcache")

  private static let version: CacheVersion = 2
  
  private static let sizeofMetadata = MemoryLayout<CacheVersion>.size + MemoryLayout<FileSize>.size + MemoryLayout<FileTimestamp>.size

  private static let imageProperties: [NSBitmapImageRep.PropertyKey: Any] = [
    .compressionFactor: 0.75
  ]

  private static func fileExists(forName name: String, forWidth width: Int) -> Bool {
    return FileManager.default.fileExists(atPath: urlFor(name, width: width).path)
  }

  static func fileIsCached(forName name: String, forVideo videoPath: URL?, forWidth width: Int) -> Bool {
    guard let fileAttr = try? FileManager.default.attributesOfItem(atPath: videoPath!.path) else {
      Logger.log("Cannot get video file attributes", level: .error, subsystem: subsystem)
      return false
    }

    // file size
    guard let fileSize = fileAttr[.size] as? FileSize else {
      Logger.log("Cannot get video file size", level: .error, subsystem: subsystem)
      return false
    }

    // modified date
    guard let fileModifiedDate = fileAttr[.modificationDate] as? Date else {
      Logger.log("Cannot get video file modification date", level: .error, subsystem: subsystem)
      return false
    }
    let fileTimestamp = FileTimestamp(fileModifiedDate.timeIntervalSince1970)

    // Check metadate in the cache
    if self.fileExists(forName: name, forWidth: width) {
      guard let file = try? FileHandle(forReadingFrom: urlFor(name, width: width)) else {
        Logger.log("Cannot open cache file.", level: .error, subsystem: subsystem)
        return false
      }

      let cacheVersion = file.read(type: CacheVersion.self)
      if cacheVersion != version { return false }

      return file.read(type: FileSize.self) == fileSize &&
        file.read(type: FileTimestamp.self) == fileTimestamp
    }

    return false
  }

  /// Write thumbnail cache to file.
  /// This method is expected to be called when the file doesn't exist.
  static func write(_ thumbnails: [FFThumbnail], forName name: String, forVideo videoPath: URL?, forWidth width: Int) {
    Logger.log("Writing \(thumbnails.count) thumbnails with width \(width) to cache file", subsystem: subsystem)

    let maxCacheSize = Preference.integer(for: .maxThumbnailPreviewCacheSize) * FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue
    if maxCacheSize == 0 {
      return
    }
    let cacheSize = CacheManager.shared.getCacheSize()
    if cacheSize > maxCacheSize {
      Logger.log("Thumbnail cache size (\(cacheSize)) is larger than max allowed (\(maxCacheSize)) and will be cleared", subsystem: subsystem)
      CacheManager.shared.clearOldCache()
    }

    let pathURL = urlFor(name, width: width)

    Utility.createDirIfNotExist(url: pathURL.deletingLastPathComponent())

    let path = pathURL.path
    guard FileManager.default.createFile(atPath: pathURL.path, contents: nil, attributes: nil) else {
      Logger.log("Cannot create thumbnail cache file: \(path.pii.quoted)", level: .error, subsystem: subsystem)
      return
    }
    guard let file = try? FileHandle(forWritingTo: pathURL) else {
      Logger.log("Cannot write to thumbnail cache file: \(path.pii.quoted)", level: .error, subsystem: subsystem)
      return
    }

    // version
    let versionData = Data(bytesOf: version)
    file.write(versionData)

    guard let fileAttr = try? FileManager.default.attributesOfItem(atPath: videoPath!.path) else {
      Logger.log("Cannot get video file attributes (path: \(videoPath!.path.pii.quoted))", level: .error, subsystem: subsystem)
      return
    }

    // file size
    guard let fileSize = fileAttr[.size] as? FileSize else {
      Logger.log("Cannot get video file size from attributes", level: .error, subsystem: subsystem)
      return
    }
    let fileSizeData = Data(bytesOf: fileSize)
    file.write(fileSizeData)

    // modified date
    guard let fileModifiedDate = fileAttr[.modificationDate] as? Date else {
      Logger.log("Cannot get video file modification date from attributes", level: .error, subsystem: subsystem)
      return
    }
    let fileTimestamp = FileTimestamp(fileModifiedDate.timeIntervalSince1970)
    let fileModificationDateData = Data(bytesOf: fileTimestamp)
    file.write(fileModificationDateData)

    // data blocks
    for tb in thumbnails {
      let timestampData = Data(bytesOf: tb.realTime)
      guard let tiffData = tb.image?.tiffRepresentation else {
        Logger.log("Cannot generate tiff data.", level: .error, subsystem: subsystem)
        return
      }
      guard let jpegData = NSBitmapImageRep(data: tiffData)?.representation(using: .jpeg, properties: imageProperties) else {
        Logger.log("Cannot generate jpeg data.", level: .error, subsystem: subsystem)
        return
      }
      let blockLength = Int64(timestampData.count + jpegData.count)
      let blockLengthData = Data(bytesOf: blockLength)
      file.write(blockLengthData)
      file.write(timestampData)
      file.write(jpegData)
    }

    if #available(macOS 10.15, *) {
      do {
        try file.close()
      } catch {
        Logger.log("Failed to close file: \(path.pii.quoted)", level: .error, subsystem: subsystem)
      }
    }

    CacheManager.shared.needsRefresh = true
    Logger.log("Finished writing thumbnail cache: \(path.pii.quoted)", subsystem: subsystem)
  }

  /// Read thumbnail cache to file.
  /// This method is expected to be called when the file exists.
  static func read(forName name: String, forWidth width: Int) -> [FFThumbnail]? {
    let pathURL = urlFor(name, width: width)
    guard let file = try? FileHandle(forReadingFrom: pathURL) else {
      Logger.log("Cannot open thumbnail cache file: \(pathURL.path.pii.quoted)", level: .error, subsystem: subsystem)
      return nil
    }
    Logger.log("Reading thumbnail cache from \(pathURL.path.pii.quoted)", subsystem: subsystem)

    var result: [FFThumbnail] = []

    // get file length
    file.seekToEndOfFile()
    let eof = file.offsetInFile

    // skip metadata
    file.seek(toFileOffset: UInt64(sizeofMetadata))

    // data blocks
    while file.offsetInFile != eof {
      // length and timestamp
      guard let blockLength = file.read(type: Int64.self),
            let timestamp = file.read(type: Double.self) else {
        Logger.log("Cannot read image header. Cache file will be deleted: \(pathURL.absoluteString.pii.quoted)",
                   level: .warning, subsystem: subsystem)
        file.closeFile()
        deleteCacheFile(at: pathURL)
        return nil
      }
      // jpeg
      let jpegData = file.readData(ofLength: Int(blockLength) - MemoryLayout.size(ofValue: timestamp))
      guard let image = NSImage(data: jpegData) else {
        Logger.log("Cannot read image. Cache file will be deleted: \(pathURL.absoluteString.pii.quoted)", level: .warning, subsystem: subsystem)
        file.closeFile()
        deleteCacheFile(at: pathURL)
        return nil
      }
      // construct
      let tb = FFThumbnail()
      tb.realTime = timestamp
      tb.image = image
      result.append(tb)
    }

    file.closeFile()
    Logger.log("Finished reading thumbnail cache, \(result.count) in total", subsystem: subsystem)
    return result
  }

  private static func deleteCacheFile(at pathURL: URL) {
    // try deleting corrupted cache
    do {
      try FileManager.default.removeItem(at: pathURL)
    } catch {
      Logger.log("Cannot delete corrupted cache: \(pathURL.absoluteString.pii.quoted)", level: .error, subsystem: subsystem)
    }
  }

  // Thumbnail cache URL
  private static func urlFor(_ name: String, width: Int) -> URL {
    return Utility.thumbnailCacheURL.appendingPathComponent("\(width)").appendingPathComponent(name)
  }

}
