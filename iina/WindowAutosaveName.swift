//
//  WindowAutosaveName.swift
//  iina
//
//  Created by Matt Svoboda on 8/5/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

struct SavedWindow {
  static let minimizedPrefix = "M:"
  let saveName: WindowAutosaveName
  let isMinimized: Bool

  init(saveName: WindowAutosaveName, isMinimized: Bool) {
    self.saveName = saveName
    self.isMinimized = isMinimized
  }

  init?(_ string: String) {
    let saveNameString: String
    var isMinimized = false
    if string.starts(with: SavedWindow.minimizedPrefix) {
      saveNameString = String(string.dropFirst(SavedWindow.minimizedPrefix.count))
      isMinimized = true
    } else {
      saveNameString = string
    }
    
    if let saveName = WindowAutosaveName(saveNameString) {
      self = SavedWindow(saveName: saveName, isMinimized: isMinimized)
    } else {
      return nil
    }
  }

  // Includes minimized state
  var saveString: String {
    return isMinimized ? "\(SavedWindow.minimizedPrefix)\(saveName.string)" : saveName.string
  }
}

enum WindowAutosaveName: Equatable {
  static let playerWindowPrefix = "PWin-"
  static let playerWindowFmt = "\(playerWindowPrefix)%@"

  static func formatPlayerWindow(playerUID id: String) -> String {
    String(format: WindowAutosaveName.playerWindowFmt, id)
  }

  case preference
  case welcome
  case openFile
  case openURL
  case about
  case inspector  // not always treated like a real window
  case playbackHistory
  // TODO: what about Guide?
  case videoFilter
  case audioFilter
  case fontPicker
  case playerWindow(id: String)

  var string: String {
    switch self {
    case .preference:
      return "Preferences"
    case .welcome:
      return "Welcome"
    case .openFile:
      return "OpenFile"
    case .openURL:
      return "OpenURL"
    case .about:
      return "About"
    case .inspector:
      return "Inspector"
    case .playbackHistory:
      return "History"
    case .videoFilter:
      return "VideoFilters"
    case .audioFilter:
      return "AudioFilters"
    case .fontPicker:
      return "FontPicker"
    case .playerWindow(let id):
      return WindowAutosaveName.formatPlayerWindow(playerUID: id)
    }
  }

  init?(_ string: String) {
    switch string {
    case WindowAutosaveName.preference.string:
      self = .preference
    case WindowAutosaveName.welcome.string:
      self = .welcome
    case WindowAutosaveName.openFile.string:
      self = .openFile
    case WindowAutosaveName.openURL.string:
      self = .openURL
    case WindowAutosaveName.about.string:
      self = .about
    case WindowAutosaveName.inspector.string:
      self = .inspector
    case WindowAutosaveName.playbackHistory.string:
      self = .playbackHistory
    case WindowAutosaveName.videoFilter.string:
      self = .videoFilter
    case WindowAutosaveName.audioFilter.string:
      self = .audioFilter
    case WindowAutosaveName.fontPicker.string:
      self = .fontPicker
    default:
      if let id = WindowAutosaveName.parseID(from: string, mustStartWith: WindowAutosaveName.playerWindowPrefix) {
        self = .playerWindow(id: id)
      } else {
        return nil
      }
    }
  }

  /// Returns `id` if `self` is type `.playerWindow`; otherwise `nil`
  var playerWindowID: String? {
    switch self {
    case .playerWindow(let id):
      return id
    default:
      break
    }
    return nil
  }

  var playerWindowLaunchID: Int? {
    if let playerWindowID {
      let splitted = playerWindowID.split(separator: "-")
      if !splitted.isEmpty {
        return Int(splitted[0])
      }
    }
    return nil
  }

  private static func parseID(from string: String, mustStartWith prefix: String) -> String? {
    if string.starts(with: prefix) {
      let splitted = string.split(separator: "-", maxSplits: 1)
      if splitted.count == 2 {
        return String(splitted[1])
      }
    }
    return nil
  }
}
