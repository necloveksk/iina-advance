//
//  AppDelegate.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import MediaPlayer
import Sparkle

let IINA_ENABLE_PLUGIN_SYSTEM = Preference.bool(for: .iinaEnablePluginSystem)

/** Tags for "Open File/URL" menu item when "Always open file in new windows" is off. Vice versa. */
fileprivate let NormalMenuItemTag = 0
/** Tags for "Open File/URL in New Window" when "Always open URL" when "Open file in new windows" is off. Vice versa. */
fileprivate let AlternativeMenuItemTag = 1


@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {

  /// Each instance of IINA, when it starts, grabs the previous launch count from the prefs and increments it by 1, which becomes its launchID.
  static let launchID: Int = {
    let nextID = Preference.integer(for: .launchCount) + 1
    Preference.set(nextID, for: .launchCount)
    Logger.log("LaunchID: \(nextID)", level: .verbose)
    return nextID
  }()

  /// The unique name for this launch, used as a pref key
  static var launchName: String = Preference.UIState.launchName(forID: launchID)
  static var launchTime = Date().timeIntervalSince1970

  static var windowsHidden = Set<String>()
  static var windowsMinimized = Set<String>()

  /**
   Becomes true once `application(_:openFile:)` or `droppedText()` is called.
   Mainly used to distinguish normal launches from others triggered by drag-and-dropping files.
   */
  var openFileCalled = false
  var shouldIgnoreOpenFile = false

  private var commandLineStatus = CommandLineStatus()

  private var allPlayersHaveShutdown = false

  private(set) var isTerminating = false

  private var observers: [NSObjectProtocol] = []
  var observedPrefKeys: [Preference.Key] = [
    .logLevel,
    .enableLogging,
    .enableAdvancedSettings,
    .enableCmdN,
//    .hideWindowsWhenInactive, // TODO: #1, see below
  ]

  /// Longest time to wait for asynchronous shutdown tasks to finish before giving up on waiting and proceeding with termination.
  ///
  /// Ten seconds was chosen to provide plenty of time for termination and yet not be long enough that users start thinking they will
  /// need to force quit IINA. As termination may involve logging out of an online subtitles provider it can take a while to complete if
  /// the provider is slow to respond to the logout request.
  private let terminationTimeout: TimeInterval = 10

  // Windows

  lazy var initialWindow: InitialWindowController = InitialWindowController()
  lazy var openURLWindow: OpenURLWindowController = OpenURLWindowController()
  lazy var aboutWindow: AboutWindowController = AboutWindowController()
  lazy var fontPicker: FontPickerWindowController = FontPickerWindowController()
  lazy var inspector: InspectorWindowController = InspectorWindowController()
  lazy var historyWindow: HistoryWindowController = HistoryWindowController()
  lazy var guideWindow: GuideWindowController = GuideWindowController()
  lazy var logWindow: LogWindowController = LogWindowController()

  lazy var vfWindow: FilterWindowController = FilterWindowController(filterType: MPVProperty.vf,
                                                                     autosaveName: WindowAutosaveName.videoFilter.string)

  lazy var afWindow: FilterWindowController = FilterWindowController(filterType: MPVProperty.af,
                                                                     autosaveName: WindowAutosaveName.audioFilter.string)

  lazy var preferenceWindowController: PreferenceWindowController = {
    var list: [NSViewController & PreferenceWindowEmbeddable] = [
      PrefGeneralViewController(),
      PrefUIViewController(),
      PrefCodecViewController(),
      PrefSubViewController(),
      PrefNetworkViewController(),
      PrefControlViewController(),
      PrefKeyBindingViewController(),
      PrefAdvancedViewController(),
      // PrefPluginViewController(),
      PrefUtilsViewController(),
    ]

    if IINA_ENABLE_PLUGIN_SYSTEM {
      list.insert(PrefPluginViewController(), at: 8)
    }
    return PreferenceWindowController(viewControllers: list)
  }()

  // MARK: Other components

  // Need to store these somewhere which isn't only inside a struct.
  // Swift doesn't seem to count them as strong references
  private let bindingTableStateManger: BindingTableStateManager = BindingTableState.manager
  private let confTableStateManager: ConfTableStateManager = ConfTableState.manager

  /// Whether the shutdown sequence timed out.
  private var timedOut = false

  @IBOutlet var menuController: MenuController!

  @IBOutlet weak var dockMenu: NSMenu!

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath, let change = change else { return }

    if keyPath == AppDelegate.launchName {
      if let newLaunchStatus = change[.newKey] as? Int {
        guard !isTerminating else { return }
        guard newLaunchStatus != 0 else { return }
        Logger.log("Detected change to this instance's status pref (\(keyPath.quoted)). Probably a newer instance of IINA has started and is attempting to restore")
        Logger.log("Changing launch status back to 'stillRunning' so the other launch will skip this instance.")
        UserDefaults.standard.setValue(Preference.UIState.LaunchStatus.stillRunning, forKey: keyPath)
      }
      return
    }

    switch keyPath {
    case Preference.Key.enableAdvancedSettings.rawValue, Preference.Key.enableLogging.rawValue:
      Logger.updateEnablement()

    case Preference.Key.logLevel.rawValue:
      if let newValue = change[.newKey] as? Int {
        Logger.Level.preferred = Logger.Level(rawValue: newValue.clamped(to: 0...3))!
      }

    case PK.enableCmdN.rawValue:
      menuController.refreshBuiltInMenuItemBindings()
      break

      // TODO: #1, see above
//    case PK.hideWindowsWhenInactive.rawValue:
//      if let newValue = change[.newKey] as? Bool {
//        for window in NSApp.windows {
//          guard window as? PlayerWindow == nil else { continue }
//          window.hidesOnDeactivate = newValue
//        }
//      }

    default:
      break
    }
  }

  // MARK: - Logs

  /// Log details about when and from what sources IINA was built.
  ///
  /// For developers that take a development build to other machines for testing it is useful to log information that can be used to
  /// distinguish between development builds.
  ///
  /// In support of this the build populated `Info.plist` with keys giving:
  /// - The build date
  /// - The git branch
  /// - The git commit
  private func logBuildDetails() {
    guard let branch = InfoDictionary.shared.buildBranch,
          let commit = InfoDictionary.shared.buildCommit,
          let date = InfoDictionary.shared.buildDate else { return }
    Logger.log("Built \(date) from branch \(branch), commit \(commit)")
  }

  /// Log details about the Mac IINA is running on.
  ///
  /// Certain IINA capabilities, such as hardware acceleration, are contingent upon aspects of the Mac IINA is running on. If available,
  /// this method will log:
  /// - macOS version
  /// - model identifier of the Mac
  /// - kind of processor
  private func logPlatformDetails() {
    Logger.log("Running under macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    guard let cpu = Sysctl.shared.machineCpuBrandString, let model = Sysctl.shared.hwModel else { return }
    Logger.log("On a \(model) with an \(cpu) processor")
  }

  // MARK: - SPUUpdaterDelegate
  @IBOutlet var updaterController: SPUStandardUpdaterController!

  func feedURLString(for updater: SPUUpdater) -> String? {
    return Preference.bool(for: .receiveBetaUpdate) ? AppData.appcastBetaLink : AppData.appcastLink
  }

  // MARK: - App Delegate

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Check for legacy pref entries and migrate them to their modern equivalents.
    // Must do this before setting defaults so that checking for existing entries doesn't result in false positives
    LegacyMigration.migrateLegacyPreferences()

    // Must setup preferences before logging so log level is set correctly.
    registerUserDefaultValues()

    // Start the log file by logging the version of IINA producing the log file.
    Logger.log(InfoDictionary.shared.printableBuildInfo)

    // The copyright is used in the Finder "Get Info" window which is a narrow window so the
    // copyright consists of multiple lines.
    let copyright = InfoDictionary.shared.copyright
    copyright.enumerateLines { line, _ in
      Logger.log(line)
    }

    // Useful to know the versions of significant dependencies that are being used so log that
    // information as well when it can be obtained.

    // The version of mpv is not logged at this point because mpv does not provide a static
    // method that returns the version. To obtain version related information you must
    // construct a mpv object, which has side effects. So the mpv version is logged in
    // applicationDidFinishLaunching to preserve the existing order of initialization.

    Logger.log("FFmpeg \(String(cString: av_version_info()))")
    // FFmpeg libraries and their versions in alphabetical order.
    let libraries: [(name: String, version: UInt32)] = [("libavcodec", avcodec_version()), ("libavformat", avformat_version()), ("libavutil", avutil_version()), ("libswscale", swscale_version())]
    for library in libraries {
      // The version of FFmpeg libraries is encoded into an unsigned integer in a proprietary
      // format which needs to be decoded into a string for display.
      Logger.log("  \(library.name) \(AppDelegate.versionAsString(library.version))")
    }
    logBuildDetails()
    logPlatformDetails()

    Logger.log("App will launch")

    for key in self.observedPrefKeys {
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }

    // Call this *before* registering for url events, to guarantee that menu is init'd
    confTableStateManager.startUp()
    menuController.bindMenuItems()

    // register for url event
    NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(self.handleURLEvent(event:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

    // guide window
    let version = InfoDictionary.shared.version.0
    if FirstRunManager.isFirstRun(for: .init("firstLaunchAfter\(version)")) {
      guideWindow.show(pages: [.highlights])
    }

    // Hide Window > "Enter Full Screen" menu item, because this is already present in the Video menu
    UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")

    // handle command line arguments
    let arguments = ProcessInfo.processInfo.arguments.dropFirst()
    if !arguments.isEmpty {
      parseCommandLine(arguments)
    }
  }

  // TODO: refactor to put this all in CommandLineStatus class
  private func parseCommandLine(_ args: ArraySlice<String>) {
    var iinaArgs: [String] = []
    var iinaArgFilenames: [String] = []
    var dropNextArg = false

    Logger.log("Command-line arguments \("\(args)".pii)")
    for arg in args {
      if dropNextArg {
        dropNextArg = false
        continue
      }
      if arg.first == "-" {
        let indexAfterDash = arg.index(after: arg.startIndex)
        if indexAfterDash == arg.endIndex {
          // single '-'
          commandLineStatus.isStdin = true
        } else if arg[indexAfterDash] == "-" {
          // args starting with --
          iinaArgs.append(arg)
        } else {
          // args starting with -
          dropNextArg = true
        }
      } else {
        // assume args starting with nothing is a filename
        iinaArgFilenames.append(arg)
      }
    }

    commandLineStatus.parseArguments(iinaArgs)
    Logger.log("Filenames from args: \(iinaArgFilenames)")
    Logger.log("Derived mpv properties from args: \(commandLineStatus.mpvArguments)")

    print(InfoDictionary.shared.printableBuildInfo)

    guard !iinaArgFilenames.isEmpty || commandLineStatus.isStdin else {
      print("This binary is not intended for being used as a command line tool. Please use the bundled iina-cli.")
      print("Please ignore this message if you are running in a debug environment.")
      return
    }

    shouldIgnoreOpenFile = true
    commandLineStatus.isCommandLine = true
    commandLineStatus.filenames = iinaArgFilenames
  }

  deinit {
    ObjcUtils.silenced {
      for key in self.observedPrefKeys {
        UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    Logger.log("App launched")

    // FIXME: this actually causes a window to open in the background. Should wait until intending to show it
    // show alpha in color panels
    NSColorPanel.shared.showsAlpha = true

    // see https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html#/c:objc(cs)SPUUpdater(im)clearFeedURLFromUserDefaults
    updaterController.updater.clearFeedURLFromUserDefaults()

    // other initializations at App level
    if #available(macOS 10.12.2, *) {
      NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = false
      NSWindow.allowsAutomaticWindowTabbing = false
    }

    JavascriptPlugin.loadGlobalInstances()
    menuController.updatePluginMenu()
    menuController.refreshBuiltInMenuItemBindings()

    // Register to restore for successive launches. Set status to currently running so that it isn't restored immediately by the next launch
    UserDefaults.standard.setValue(Preference.UIState.LaunchStatus.stillRunning, forKey: AppDelegate.launchName)
    UserDefaults.standard.addObserver(self, forKeyPath: AppDelegate.launchName, options: .new, context: nil)

    let activePlayer = PlayerCore.active  // Load the first PlayerCore
    Logger.log("Using \(activePlayer.mpv.mpvVersion!)")

    if commandLineStatus.isCommandLine {
      // (Option A) Launch from command line
      startFromCommandLine()
    } else if openFileCalled {
      // (Option B) Launch app from UI with open file(s)
      // do nothing special here
    } else {
      // (Option C) Launch app (standalone)
      startWithNoOpenedFiles()
    }

    finishLaunching()
  }

  private func startWithNoOpenedFiles() {
    // Restore window state *before* hooking up the listener which saves state
    let restoredSomething = restoreWindowsFromPreviousLaunch()
    if !restoredSomething {
      // Fall back to default action
      doLaunchOrReopenAction()
    }
  }

  private func startFromCommandLine() {
    Preference.UIState.disableSaveAndRestoreUntilNextLaunch()

    var lastPlayerCore: PlayerCore? = nil
    let getNewPlayerCore = { () -> PlayerCore in
      let pc = PlayerCore.newPlayerCore
      self.commandLineStatus.assignMPVArguments(to: pc)
      lastPlayerCore = pc
      return pc
    }
    if commandLineStatus.isStdin {
      getNewPlayerCore().openURLString("-")
    } else {
      let validFileURLs: [URL] = commandLineStatus.filenames.compactMap { filename in
        if Regex.url.matches(filename) {
          return URL(string: filename.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? filename)
        } else {
          return FileManager.default.fileExists(atPath: filename) ? URL(fileURLWithPath: filename) : nil
        }
      }
      if commandLineStatus.openSeparateWindows {
        validFileURLs.forEach { url in
          getNewPlayerCore().openURL(url)
        }
      } else {
        getNewPlayerCore().openURLs(validFileURLs)
      }
    }

    if let pc = lastPlayerCore {
      if commandLineStatus.shufflePlaylist {
        pc.toggleShuffle()
      }

      if commandLineStatus.enterMusicMode {
        Logger.log("Entering music mode as specified via command line", level: .verbose)
        if commandLineStatus.enterPIP {
          // PiP is not supported in music mode. Combining these options is not permitted and is
          // rejected by iina-cli. The IINA executable must have been invoked directly with
          // arguments.
          Logger.log("Cannot specify both --music-mode and --pip", level: .error)
          // Command line usage error.
          exit(EX_USAGE)
        }
        pc.enterMusicMode()
      } else if #available(macOS 10.12, *), commandLineStatus.enterPIP {
        Logger.log("Entering PIP as specified via command line", level: .verbose)
        pc.windowController.enterPIP()
      }
    }
  }

  private func finishLaunching() {
    Logger.log("Adding window observers")

    // The "action on last window closed" action will vary slightly depending on which type of window was closed.
    // Here we add a listener which fires when *any* window is closed, in order to handle that logic all in one place.
    observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                            queue: .main, using: self.windowWillClose))

    if Preference.UIState.isSaveEnabled {
      // Save ordered list of open windows each time the order of windows changed.
      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                              queue: .main, using: self.keyWindowDidChange))

      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil,
                                                              queue: .main, using: self.windowDidMiniaturize))

      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil,
                                                              queue: .main, using: self.windowDidDeminiaturize))

    } else {
      // TODO: remove existing state...somewhere
      Logger.log("Note: UI state saving is disabled")
    }

    if #available(macOS 10.13, *) {
      if RemoteCommandController.useSystemMediaControl {
        Logger.log("Setting up MediaPlayer integration")
        RemoteCommandController.setup()
        NowPlayingInfoManager.updateInfo(state: .unknown)
      }
    }

    NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    NSApplication.shared.servicesProvider = self
  }

  func applicationShouldAutomaticallyLocalizeKeyEquivalents(_ application: NSApplication) -> Bool {
    // Do not re-map keyboard shortcuts based on keyboard position in different locales
    return false
  }

  func applicationDidBecomeActive(_ notfication: Notification) {
    // When using custom window style, sometimes AppKit will remove their entries from the Window menu (e.g. when hiding the app).
    // Make sure to add them again if they are missing:
    for player in PlayerCoreManager.playerCores {
      if player.windowController.loaded && !player.isShutdown {
        player.windowController.updateTitle()
      }
    }
  }

  func applicationWillResignActive(_ notfication: Notification) {
  }

  // MARK: - Opening/restoring windows

  // Saves an ordered list of current open windows (if configured) each time *any* window becomes the key window.
  private func keyWindowDidChange(_ notification: Notification) {
    // Query for the list of open windows and save it.
    // Don't do this too soon, or their orderIndexes may not yet be up to date.
    DispatchQueue.main.async { [self] in
      // This notification can sometimes happen if the app had multiple windows at shutdown.
      // We will ignore it in this case, because this is exactly the case that we want to save!
      guard !isTerminating else {
        return
      }
      Preference.UIState.saveCurrentOpenWindowList()
    }
  }

  private func windowDidMiniaturize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    let savedStateName = window.savedStateName
    guard !savedStateName.isEmpty else { return }

    Logger.log("Window did minimize; adding to minimized windows list: \(savedStateName.quoted)")
    AppDelegate.windowsMinimized.insert(savedStateName)
    DispatchQueue.main.async { [self] in
      guard !isTerminating else {
        return
      }
      Preference.UIState.saveCurrentOpenWindowList()
    }
  }

  private func windowDidDeminiaturize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    let savedStateName = window.savedStateName
    guard !savedStateName.isEmpty else { return }

    Logger.log("Window did unminimize; removing from minimized windows list: \(savedStateName.quoted)")
    AppDelegate.windowsMinimized.remove(savedStateName)
    DispatchQueue.main.async { [self] in
      guard !isTerminating else {
        return
      }
      Preference.UIState.saveCurrentOpenWindowList()
    }
  }

  private func doLaunchOrReopenAction() {
    let action: Preference.ActionAfterLaunch = Preference.enum(for: .actionAfterLaunch)
    Logger.log("Doing actionAfterLaunch: \(action)", level: .verbose)

    switch action {
    case .welcomeWindow:
      showWelcomeWindow()
    case .openPanel:
      openFile(self)
    case .historyWindow:
      showHistoryWindow(self)
    case .none:
      break
    }
  }

  private func restoreWindowsFromPreviousLaunch() -> Bool {
    guard Preference.UIState.isRestoreEnabled else {
      Logger.log("Not restoring windows because restore is disabled", level: .verbose)
      return false
    }

    let pastLaunches: [String] = Preference.UIState.collectPastLaunches()
    Logger.log("Found \(pastLaunches.count) past launches to restore", level: .verbose)
    if pastLaunches.isEmpty {
      return false
    }

    let stopwatch = Utility.Stopwatch()

    let isRestoreApproved: Bool // false means delete restored state
    if Preference.bool(for: .isRestoreInProgress) {
      // If this flag is still set, the last restore probably failed. If it keeps failing, launch will be impossible.
      // Let user decide whether to try again or delete saved state.
      Logger.log("Looks like there was a previous restore which didn't complete (pref \(Preference.Key.isRestoreInProgress.rawValue) == true). Asking user whether to retry or skip")
      isRestoreApproved = Utility.quickAskPanel("restore_prev_error", useCustomButtons: true)
    } else if Preference.bool(for: .alwaysAskBeforeRestoreAtLaunch) {
      Logger.log("Prompting user whether to restore app state, per pref", level: .verbose)
      isRestoreApproved = Utility.quickAskPanel("restore_confirm", useCustomButtons: true)
    } else {
      isRestoreApproved = true
    }

    if !isRestoreApproved {
      // Clear out old state. It may have been causing errors, or user wants to start new
      Preference.UIState.clearAllSavedLaunchState()
      Preference.set(false, for: .isRestoreInProgress)
      return false
    }

    // If too much time has passed (in particular if user took a long time to respond to confirmation dialog), consider the data stale.
    // Due to 1s delay in chosen strategy for verifying whether other instances are running, try not to repeat it twice.
    // Users who are quick with their user interface device probably know what they are doing and will be impatient.
    let pastLaunchesCache = stopwatch.msElapsed > 1000 ? nil : pastLaunches
    let savedWindowsBackToFront = Preference.UIState.consolidateOpenWindowsFromPastLaunches(pastLaunches: pastLaunchesCache)

    guard !savedWindowsBackToFront.isEmpty else {
      Logger.log("Not restoring windows: stored window list empty")
      return false
    }

    if savedWindowsBackToFront.count == 1 {
      let onlyWindow = savedWindowsBackToFront[0].saveName

      if onlyWindow == WindowAutosaveName.inspector {
        // Do not restore this on its own
        Logger.log("Not restoring windows because only open window was Inspector", level: .verbose)
        return false
      }

      let action: Preference.ActionAfterLaunch = Preference.enum(for: .actionAfterLaunch)
      if (onlyWindow == WindowAutosaveName.welcome && action == .welcomeWindow)
          || (onlyWindow == WindowAutosaveName.openURL && action == .openPanel)
          || (onlyWindow == WindowAutosaveName.playbackHistory && action == .historyWindow) {
        Logger.log("Not restoring windows because only open window was identical to launch action (\(action))",
                   level: .verbose)
        // Skip the prompts below because they are just unnecessary nagging
        return false
      }
    }

    Logger.log("Starting restore of \(savedWindowsBackToFront.count) windows", level: .verbose)
    Preference.set(true, for: .isRestoreInProgress)

    // Show windows one by one, starting at back and iterating to front:
    for savedWindow in savedWindowsBackToFront {
      var wc: NSWindowController? = nil
      switch savedWindow.saveName {
      case .playbackHistory:
        showHistoryWindow(self)
        wc = historyWindow
      case .welcome:
        showWelcomeWindow()
        wc = initialWindow
      case .preference:
        showPreferences(self)
        wc = preferenceWindowController
      case .about:
        showAboutWindow(self)
        wc = aboutWindow
      case .openURL:
        // TODO: persist isAlternativeAction too
        showOpenURLWindow(isAlternativeAction: true)
        wc = openURLWindow
      case .inspector:
        showInspectorWindow()
        wc = inspector
      case .videoFilter:
        showVideoFilterWindow(self)
        wc = vfWindow
      case .audioFilter:
        showAudioFilterWindow(self)
        wc = afWindow
      case .playerWindow(let id):
        let player = PlayerCoreManager.restoreFromPriorLaunch(playerID: id)
        wc = player.windowController
      default:
        Logger.log("Cannot restore unrecognized autosave enum: \(savedWindow.saveName)", level: .error)
        break
      }
      if savedWindow.isMinimized, let wc {
        wc.window?.miniaturize(self)
      }
    }

    Logger.log("Done restoring windows", level: .verbose)
    Preference.set(false, for: .isRestoreInProgress)

    // Count only "important windows" (IINA startup can open other windows which are hidden, such as color picker)
    let openWindowCount = NSApp.windows.reduce(0, {count, win in (win.isImportant() && win.isOpen()) ? count + 1 : count})
    if openWindowCount == 0 {
      Logger.log("Looks like none of the windows was restored successfully. Falling back to user launch preference")
      return false
    }
    return true
  }

  func showWelcomeWindow() {
    Logger.log("Showing WelcomeWindow", level: .verbose)
    let sw = Utility.Stopwatch()
    initialWindow.reloadData()
    Logger.log("Total WelcomeWindow reload time: \(sw) ms")
    initialWindow.showWindow(nil)
  }

  func showOpenURLWindow(isAlternativeAction: Bool) {
    Logger.log("Showing OpenURLWindow (isAlternativeAction: \(isAlternativeAction))", level: .verbose)
    openURLWindow.isAlternativeAction = isAlternativeAction
    openURLWindow.showWindow(nil)
    openURLWindow.resetFields()
  }

  func showInspectorWindow() {
    inspector.showWindow(self)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    Logger.log("applicationShouldTerminateAfterLastWindowClosed() entered", level: .verbose)
    // Certain events (like when PIP is enabled) can result in this being called when it shouldn't.
    guard !PlayerCore.active.windowController.isOpen else { return false }

    if Preference.bool(for: .quitWhenNoOpenedWindow) {
      Preference.UIState.clearSavedStateForThisLaunch()
      Logger.log("Will quit due to last window closed", level: .verbose)
      return true
    } else {
      self.doActionWhenLastWindowWillClose()
      return false
    }
  }

  private func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }

    guard !isTerminating else { return }

    let windowName = window.savedStateName
    if !windowName.isEmpty {
      AppDelegate.windowsHidden.remove(windowName)
      AppDelegate.windowsMinimized.remove(windowName)

      /// Query for the list of open windows and save it (excluding the window which is about to close).
      /// Most cases are covered by saving when `keyWindowDidChange` is called, but this covers the case where
      /// the user closes a window which is not in the foreground.
      Preference.UIState.saveCurrentOpenWindowList(excludingWindowName: window.savedStateName)

      // Player window was closed? Need to remove some additional state
      if let player = (window.windowController as? PlayerWindowController)?.player {
        Preference.UIState.clearPlayerSaveState(forPlayerID: player.label)

        // Check whether this is the last player closed; show welcome or history window if configured.
        // Other windows like Settings may be open, and user shouldn't need to close them all to get back the welcome window.
        if player.isOnlyOpenPlayer {
          player.log.verbose("Window was last player window open: \(window.savedStateName.quoted)")
          doActionWhenLastWindowWillClose()
          return
        }
      }
    }

    if window.isOnlyOpenWindow() {
      let quitForAction: Preference.ActionAfterLaunch?
      switch window.savedStateName {
      case WindowAutosaveName.playbackHistory.string:
        quitForAction = .historyWindow
      case WindowAutosaveName.welcome.string:
        guard !initialWindow.expectingAnotherWindowToOpen else {
          return
        }
        quitForAction = .welcomeWindow
      default:
        quitForAction = nil
      }
      doActionWhenLastWindowWillClose(quitFor: quitForAction)
    }
  }


  private func doActionWhenLastWindowWillClose(quitFor quitForAction: Preference.ActionAfterLaunch? = nil) {
    guard !isTerminating else { return }

    if let whatToDo = Preference.ActionAfterLaunch(key: .actionAfterLaunch) {
      Logger.log("ActionWhenNoOpenedWindow: \(whatToDo)", level: .verbose)
      if whatToDo == quitForAction {
        Logger.log("Last window closed was the configured ActionWhenNoOpenedWindow. Will quit instead of re-opening it.")
        Preference.UIState.clearSavedStateForThisLaunch()
        DispatchQueue.main.async {
          NSApp.terminate(nil)
        }
        return
      }

      switch whatToDo {
      case .welcomeWindow:
        showWelcomeWindow()
      case .historyWindow:
        showHistoryWindow(self)
      default:
        break
      }
    }
  }

  // MARK: Application termination

  @objc
  func shutdownTimedout() {
    timedOut = true
    if !allPlayersHaveShutdown {
      Logger.log("Timed out waiting for players to stop and shut down", level: .warning)
      // For debugging list players that have not terminated.
      for player in PlayerCoreManager.playerCores {
        let label = player.label
        if !player.isStopped {
          Logger.log("Player \(label) failed to stop", level: .warning)
        } else if !player.isShutdown {
          Logger.log("Player \(label) failed to shutdown", level: .warning)
        }
      }
      // For debugging purposes we do not remove observers in case players stop or shutdown after
      // the timeout has fired as knowing that occurred maybe useful for debugging why the
      // termination sequence failed to complete on time.
      Logger.log("Not waiting for players to shutdown; proceeding with application termination",
                 level: .warning)
    }
    if OnlineSubtitle.loggedIn {
      // The request to log out of the online subtitles provider has not completed. This should not
      // occur as the logout request uses a timeout that is shorter than the termination timeout to
      // avoid this occurring. Therefore if this message is logged something has gone wrong with the
      // shutdown code.
      Logger.log("Timed out waiting for log out of online subtitles provider to complete",
                 level: .warning)
    }
    Logger.log("Proceeding with application termination due to timeout", level: .warning)
    // Tell Cocoa to proceed with termination.
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Logger.log("App should terminate")
    isTerminating = true

    // Remove observers for IINA preferences.
    ObjcUtils.silenced {
      for key in self.observedPrefKeys {
        UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
      }
    }

    // Normally termination happens fast enough that the user does not have time to initiate
    // additional actions, however to be sure shutdown further input from the user.
    Logger.log("Disabling all menus")
    menuController.disableAllMenus()
    // Remove custom menu items added by IINA to the dock menu. AppKit does not allow the dock
    // supplied items to be changed by an application so there is no danger of removing them.
    // The menu items are being removed because setting the isEnabled property to false had no
    // effect under macOS 12.6.
    removeAllMenuItems(dockMenu)
    // If supported and enabled disable all remote media commands. This also removes IINA from
    // the Now Playing widget.
    if #available(macOS 10.13, *) {
      if RemoteCommandController.useSystemMediaControl {
        Logger.log("Disabling remote commands")
        RemoteCommandController.disableAllCommands()
      }
    }

    if Preference.UIState.isSaveEnabled {
      // unlock for new launch
      Logger.log("Updating status of \(AppDelegate.launchName.quoted) to 'done' in prefs", level: .verbose)
      UserDefaults.standard.setValue(Preference.UIState.LaunchStatus.done, forKey: AppDelegate.launchName)
    }

    // The first priority was to shutdown any new input from the user. The second priority is to
    // send a logout request if logged into an online subtitles provider as that needs time to
    // complete.
    if OnlineSubtitle.loggedIn {
      // Force the logout request to timeout earlier than the overall termination timeout. This
      // request taking too long does not represent an error in the shutdown code, whereas the
      // intention of the overall termination timeout is to recover from some sort of hold up in the
      // shutdown sequence that should not occur.
      OnlineSubtitle.logout(timeout: terminationTimeout - 1)
    }

    // Close all windows. When a player window is closed it will send a stop command to mpv to stop
    // playback and unload the file.
    Logger.log("Closing all windows")
    for window in NSApp.windows {
      window.close()
    }

    // Check if there are any players that are not shutdown. If all players are already shutdown
    // then application termination can proceed immediately. This will happen if there is only one
    // player and shutdown was initiated by typing "q" in the player window. That sends a quit
    // command directly to mpv causing mpv and the player to shutdown before application
    // termination is initiated.
    allPlayersHaveShutdown = true
    for player in PlayerCoreManager.playerCores {
      if !player.isShutdown {
        allPlayersHaveShutdown = false
        break
      }
    }
    if allPlayersHaveShutdown {
      Logger.log("All players have shut down")
    } else {
      // Shutdown of player cores involves sending the stop and quit commands to mpv. Even though
      // these commands are sent to mpv using the synchronous API mpv executes them asynchronously.
      // This requires IINA to wait for mpv to finish executing these commands.
      Logger.log("Waiting for players to stop and shut down")
    }

    // Usually will have to wait for logout request to complete if logged into an online subtitle
    // provider.
    var canTerminateNow = allPlayersHaveShutdown
    if OnlineSubtitle.loggedIn {
      canTerminateNow = false
      Logger.log("Waiting for logout of online subtitles provider to complete")
    }

    // If the user pressed Q and mpv initiated the termination then players will already be
    // shutdown and it may be possible to proceed with termination.
    if canTerminateNow {
      Logger.log("Proceeding with application termination")
      // Tell Cocoa that it is ok to immediately proceed with termination.
      return .terminateNow
    }

    // To ensure termination completes and the user is not required to force quit IINA, impose an
    // arbitrary timeout that forces termination to complete. The expectation is that this timeout
    // is never triggered. If a timeout warning is logged during termination then that needs to be
    // investigated.
    var timer: Timer
    if #available(macOS 10.12, *) {
      timer = Timer(timeInterval: terminationTimeout, repeats: false) { _ in
        // Once macOS 10.11 is no longer supported the contents of the method can be inlined in this
        // closure.
        self.shutdownTimedout()
      }
    } else {
      timer = Timer(timeInterval: terminationTimeout, target: self,
                    selector: #selector(self.shutdownTimedout), userInfo: nil, repeats: false)
    }
    RunLoop.main.add(timer, forMode: .common)

    // Establish an observer for a player core stopping.
    let center = NotificationCenter.default
    var observers: [NSObjectProtocol] = []
    var observer = center.addObserver(forName: .iinaPlayerStopped, object: nil, queue: .main) { note in
      guard !self.timedOut else {
        // The player has stopped after IINA already timed out, gave up waiting for players to
        // shutdown, and told Cocoa to proceed with termination. AppKit will continue to process
        // queued tasks during application termination even after AppKit has called
        // applicationWillTerminate. So this observer can be called after IINA has told Cocoa to
        // proceed with termination. When the termination sequence times out IINA does not remove
        // observers as it may be useful for debugging purposes to know that a player stopped after
        // the timeout as that indicates the stopping was proceeding as opposed to being permanently
        // blocked. Log that this has occurred and take no further action as it is too late to
        // proceed with the normal termination sequence.  If the log file has already been closed
        // then the message will only be printed to the console.
        Logger.log("Player stopped after application termination timed out", level: .warning)
        return
      }
      guard let player = note.object as? PlayerCore else { return }
      // Now that the player has stopped it is safe to instruct the player to terminate. IINA MUST
      // wait for the player to stop before instructing it to terminate because sending the quit
      // command to mpv while it is still asynchronously executing the stop command can result in a
      // watch later file that is missing information such as the playback position. See issue #3939
      // for details.
      player.shutdown()
    }
    observers.append(observer)

    /// Proceed with termination if all outstanding shutdown tasks have completed.
    ///
    /// This method is called when an observer receives a notification that a player has shutdown or an online subtitles provider logout
    /// request has completed. If there are no other termination tasks outstanding then this method will instruct AppKit to proceed with
    /// termination.
    func proceedWithTermination() {
      if !allPlayersHaveShutdown {
        // If any player has not shutdown then continue waiting.
        for player in PlayerCoreManager.playerCores {
          guard player.isShutdown else { return }
        }
        allPlayersHaveShutdown = true
        // All players have shutdown.
        Logger.log("All players have shut down")
      }
      guard !OnlineSubtitle.loggedIn else { return }
      // All players have shutdown. No longer logged into an online subtitles provider.
      Logger.log("Proceeding with application termination")
      // No longer need the timer that forces termination to proceed.
      timer.invalidate()
      // No longer need the observers for players stopping and shutting down, along with the
      // observer for logout requests completing.
      ObjcUtils.silenced {
        observers.forEach {
          NotificationCenter.default.removeObserver($0)
        }
      }
      // Tell AppKit to proceed with termination.
      NSApp.reply(toApplicationShouldTerminate: true)
    }

    // Establish an observer for a player core shutting down.
    observer = center.addObserver(forName: .iinaPlayerShutdown, object: nil, queue: .main) { _ in
      guard !self.timedOut else {
        // The player has shutdown after IINA already timed out, gave up waiting for players to
        // shutdown, and told Cocoa to proceed with termination. AppKit will continue to process
        // queued tasks during application termination even after AppKit has called
        // applicationWillTerminate. So this observer can be called after IINA has told Cocoa to
        // proceed with termination. When the termination sequence times out IINA does not remove
        // observers as it may be useful for debugging purposes to know that a player shutdown after
        // the timeout as that indicates shutdown was proceeding as opposed to being permanently
        // blocked. Log that this has occurred and take no further action as it is too late to
        // proceed with the normal termination sequence. If the log file has already been closed
        // then the message will only be printed to the console.
        Logger.log("Player shut down after application termination timed out", level: .warning)
        return
      }
      proceedWithTermination()
    }
    observers.append(observer)

    // Establish an observer for logging out of the online subtitle provider.
    observer = center.addObserver(forName: .iinaLogoutCompleted, object: nil, queue: .main) { _ in
      guard !self.timedOut else {
        // The request to log out of the online subtitles provider has completed after IINA already
        // timed out, gave up waiting for players to shutdown, and told Cocoa to proceed with
        // termination. This should not occur as the logout request uses a timeout that is shorter
        // than the termination timeout to avoid this occurring. Therefore if this message is logged
        // something has gone wrong with the shutdown code.
        Logger.log(
          "Logout of online subtitles provider completed after application termination timed out",
          level: .warning)
        return
      }
      proceedWithTermination()
    }
    observers.append(observer)

    // Instruct any players that are already stopped to start shutting down.
    for player in PlayerCoreManager.playerCores {
      if player.isStopped && !player.isShutdown {
        player.shutdown()
      }
    }

    // Tell AppKit that it is ok to proceed with termination, but wait for our reply.
    return .terminateLater
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // Once termination starts subsystems such as mpv are being shutdown. Accessing mpv
    // once it has been instructed to shutdown can trigger a crash. MUST NOT permit
    // reopening once termination has started.
    guard !isTerminating else { return false }
    guard !flag else { return true }
    Logger.log("Handle reopen")
    doLaunchOrReopenAction()
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    Logger.log("App will terminate")
    Logger.closeLogFiles()

    ObjcUtils.silenced {
      self.observers.forEach {
        NotificationCenter.default.removeObserver($0)
      }
    }
  }

  func application(_ sender: NSApplication, openFiles filePaths: [String]) {
    Logger.log("application(openFiles:) called with: \(filePaths.map{$0.pii})")
    openFileCalled = true
    // if launched from command line, should ignore openFile once
    if shouldIgnoreOpenFile {
      shouldIgnoreOpenFile = false
      return
    }
    let urls = filePaths.map { URL(fileURLWithPath: $0) }
    
    // if installing a plugin package
    if let pluginPackageURL = urls.first(where: { $0.pathExtension == "iinaplgz" }) {
      showPreferences(self)
      preferenceWindowController.performAction(.installPlugin(url: pluginPackageURL))
      return
    }

    DispatchQueue.main.async {
      Logger.log("Opening \(urls.count) files")
      // open pending files
      var playableFileCount = 0
      for url in urls {
        if let openedFileCount = PlayerCore.activeOrNew.openURLs([url]) {
          playableFileCount += openedFileCount
        }
      }
      if playableFileCount == 0 {
        Logger.log("Notifying user nothing was opened", level: .verbose)
        Utility.showAlert("nothing_to_open")
      }
    }
  }

  // MARK: - Accept dropped string and URL on Dock icon

  @objc
  func droppedText(_ pboard: NSPasteboard, userData:String, error: NSErrorPointer) {
    Logger.log("Text dropped on app's Dock icon", level: .verbose)
    if let url = pboard.string(forType: .string) {
      PlayerCore.active.openURLString(url)
    }
  }

  // MARK: - Dock menu

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    return dockMenu
  }

  /// Remove all menu items in the given menu and any submenus.
  ///
  /// This method recursively descends through the entire tree of menu items removing all items.
  /// - Parameter menu: Menu to remove items from
  private func removeAllMenuItems(_ menu: NSMenu) {
    for item in menu.items {
      if item.hasSubmenu {
        removeAllMenuItems(item.submenu!)
      }
      menu.removeItem(item)
    }
  }

  // MARK: - URL Scheme

  @objc func handleURLEvent(event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
    openFileCalled = true
    guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
    Logger.log("Handling URL event: \(url)")
    parsePendingURL(url)
  }

  /**
   Parses the pending iina:// url.
   - Parameter url: the pending URL.
   - Note:
   The iina:// URL scheme currently supports the following actions:

   __/open__
   - `url`: a url or string to open.
   - `new_window`: 0 or 1 (default) to indicate whether open the media in a new window.
   - `enqueue`: 0 (default) or 1 to indicate whether to add the media to the current playlist.
   - `full_screen`: 0 (default) or 1 to indicate whether open the media and enter fullscreen.
   - `pip`: 0 (default) or 1 to indicate whether open the media and enter pip.
   - `mpv_*`: additional mpv options to be passed. e.g. `mpv_volume=20`.
     Options starting with `no-` are not supported.
   */
  private func parsePendingURL(_ url: String) {
    Logger.log("Parsing URL \(url.pii)")
    guard let parsed = URLComponents(string: url) else {
      Logger.log("Cannot parse URL using URLComponents", level: .warning)
      return
    }
    
    if parsed.scheme != "iina" {
      // try to open the URL directly
      PlayerCore.activeOrNewForMenuAction(isAlternative: false).openURLString(url)
      return
    }
    
    // handle url scheme
    guard let host = parsed.host else { return }

    if host == "open" || host == "weblink" {
      // open a file or link
      guard let queries = parsed.queryItems else { return }
      let queryDict = [String: String](uniqueKeysWithValues: queries.map { ($0.name, $0.value ?? "") })

      // url
      guard let urlValue = queryDict["url"], !urlValue.isEmpty else {
        Logger.log("Cannot find parameter \"url\", stopped")
        return
      }

      // new_window
      let player: PlayerCore
      if let newWindowValue = queryDict["new_window"], newWindowValue == "1" {
        player = PlayerCore.newPlayerCore
      } else {
        player = PlayerCore.activeOrNewForMenuAction(isAlternative: false)
      }

      // enqueue
      if let enqueueValue = queryDict["enqueue"], enqueueValue == "1", !PlayerCore.lastActive.info.playlist.isEmpty {
        PlayerCore.lastActive.addToPlaylist(urlValue)
        PlayerCore.lastActive.sendOSD(.addToPlaylist(1))
      } else {
        player.openURLString(urlValue)
      }

      // presentation options
      if let fsValue = queryDict["full_screen"], fsValue == "1" {
        // full_screeen
        player.mpv.setFlag(MPVOption.Window.fullscreen, true)
      } else if let pipValue = queryDict["pip"], pipValue == "1" {
        // pip
        if #available(macOS 10.12, *) {
          player.windowController.enterPIP()
        }
      }

      // mpv options
      for query in queries {
        if query.name.hasPrefix("mpv_") {
          let mpvOptionName = String(query.name.dropFirst(4))
          guard let mpvOptionValue = query.value else { continue }
          Logger.log("Setting \(mpvOptionName) to \(mpvOptionValue)")
          player.mpv.setString(mpvOptionName, mpvOptionValue)
        }
      }

      Logger.log("Finished URL scheme handling")
    }
  }

  // MARK: - Menu actions

  @IBAction func openFile(_ sender: AnyObject) {
    Logger.log("Menu - Open file")
    let panel = NSOpenPanel()
    panel.title = NSLocalizedString("alert.choose_media_file.title", comment: "Choose Media File")
    panel.canCreateDirectories = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK {
      if Preference.bool(for: .recordRecentFiles) {
        for url in panel.urls {
          NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
      }
      let isAlternative = (sender as? NSMenuItem)?.tag == AlternativeMenuItemTag
      let playerCore = PlayerCore.activeOrNewForMenuAction(isAlternative: isAlternative)
      if playerCore.openURLs(panel.urls) == 0 {
        Logger.log("OpenFile: notifying user there is nothing to open", level: .verbose)
        Utility.showAlert("nothing_to_open")
      }
    }
  }

  @IBAction func openURL(_ sender: AnyObject) {
    Logger.log("Menu - Open URL")
    showOpenURLWindow(isAlternativeAction: sender.tag == AlternativeMenuItemTag)
  }

  /// Only used if `Preference.Key.enableCmdN` is set to `true`
  @IBAction func menuNewWindow(_ sender: Any) {
    showWelcomeWindow()
  }

  @IBAction func menuOpenScreenshotFolder(_ sender: NSMenuItem) {
    let screenshotPath = Preference.string(for: .screenshotFolder)!
    let absoluteScreenshotPath = NSString(string: screenshotPath).expandingTildeInPath
    let url = URL(fileURLWithPath: absoluteScreenshotPath, isDirectory: true)
      NSWorkspace.shared.open(url)
  }

  @IBAction func menuSelectAudioDevice(_ sender: NSMenuItem) {
    if let name = sender.representedObject as? String {
      PlayerCore.active.setAudioDevice(name)
    }
  }

  @IBAction func showPreferences(_ sender: AnyObject) {
    preferenceWindowController.showWindow(self)
  }

  @IBAction func showVideoFilterWindow(_ sender: AnyObject) {
    Logger.log("Showing Video Filter window", level: .verbose)
    vfWindow.showWindow(self)
  }

  @IBAction func showAudioFilterWindow(_ sender: AnyObject) {
    Logger.log("Showing Audio Filter window", level: .verbose)
    afWindow.showWindow(self)
  }

  @IBAction func showAboutWindow(_ sender: AnyObject) {
    Logger.log("Showing About window", level: .verbose)
    aboutWindow.showWindow(self)
  }

  @IBAction func showHistoryWindow(_ sender: AnyObject) {
    Logger.log("Showing History window", level: .verbose)
    historyWindow.showWindow(self)
  }

  @IBAction func showLogWindow(_ sender: AnyObject) {
    logWindow.showWindow(self)
  }

  @IBAction func showHighlights(_ sender: AnyObject) {
    guideWindow.show(pages: [.highlights])
  }

  @IBAction func helpAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.wikiLink)!)
  }

  @IBAction func githubAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.githubLink)!)
  }

  @IBAction func websiteAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.websiteLink)!)
  }

  private func registerUserDefaultValues() {
    UserDefaults.standard.register(defaults: [String: Any](uniqueKeysWithValues: Preference.defaultPreference.map { ($0.0.rawValue, $0.1) }))
  }

  // MARK: - FFmpeg version parsing

  /// Extracts the major version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MAJOR`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The major version number
  private static func avVersionMajor(_ version: UInt32) -> UInt32 {
    version >> 16
  }

  /// Extracts the minor version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MINOR`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The minor version number
  private static func avVersionMinor(_ version: UInt32) -> UInt32 {
    (version & 0x00FF00) >> 8
  }

  /// Extracts the micro version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MICRO`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The micro version number
  private static func avVersionMicro(_ version: UInt32) -> UInt32 {
    version & 0xFF
  }

  /// Forms a string representation from the given FFmpeg encoded version number.
  ///
  /// FFmpeg returns the version number of its libraries encoded into an unsigned integer. The FFmpeg source
  /// `libavutil/version.h` describes FFmpeg's versioning scheme and provides C macros for operating on encoded
  /// version numbers. Since the macros can't be used in Swift code we've had to code equivalent functions in Swift.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: A string containing the version number.
  private static func versionAsString(_ version: UInt32) -> String {
    let major = AppDelegate.avVersionMajor(version)
    let minor = AppDelegate.avVersionMinor(version)
    let micro = AppDelegate.avVersionMicro(version)
    return "\(major).\(minor).\(micro)"
  }
}


struct CommandLineStatus {
  var isCommandLine = false
  var isStdin = false
  var openSeparateWindows = false
  var enterMusicMode = false
  var enterPIP = false
  var shufflePlaylist = false
  var mpvArguments: [(String, String)] = []
  var iinaArguments: [(String, String)] = []
  var filenames: [String] = []

  mutating func parseArguments(_ args: [String]) {
    mpvArguments.removeAll()
    iinaArguments.removeAll()
    for arg in args {
      let splitted = arg.dropFirst(2).split(separator: "=", maxSplits: 1)
      let name = String(splitted[0])
      if (name.hasPrefix("mpv-")) {
        // mpv args
        let strippedName = String(name.dropFirst(4))
        if strippedName == "-" {
          isStdin = true
        } else {
          let argPair: (String, String)
          if splitted.count <= 1 {
            argPair = (strippedName, "yes")
          } else {
            argPair = (strippedName, String(splitted[1]))
          }

          if argPair.0 == "shuffle" && argPair.1 == "yes" {
            Logger.log("Found shuffle request in command-line args. Will convert it to \"playlist-shuffle\" command")
            shufflePlaylist = true
          } else {
            mpvArguments.append(argPair)
          }
        }
      } else {
        // other args
        if splitted.count <= 1 {
          iinaArguments.append((name, "yes"))
        } else {
          iinaArguments.append((name, String(splitted[1])))
        }
        if name == "stdin" {
          isStdin = true
        }
        if name == "separate-windows" {
          openSeparateWindows = true
        }
        if name == "music-mode" {
          enterMusicMode = true
        }
        if name == "pip" {
          enterPIP = true
        }
      }
    }
  }

  func assignMPVArguments(to playerCore: PlayerCore) {
    Logger.log("Setting mpv properties from arguments: \(mpvArguments)")
    for arg in mpvArguments {
      playerCore.mpv.setString(arg.0, arg.1)
    }
  }
}

@available(macOS 10.13, *)
class RemoteCommandController {
  static let remoteCommand = MPRemoteCommandCenter.shared()

  static var useSystemMediaControl: Bool = Preference.bool(for: .useMediaKeys)

  static func setup() {
    remoteCommand.playCommand.addTarget { _ in
      PlayerCore.lastActive.resume()
      return .success
    }
    remoteCommand.pauseCommand.addTarget { _ in
      PlayerCore.lastActive.pause()
      return .success
    }
    remoteCommand.togglePlayPauseCommand.addTarget { _ in
      PlayerCore.lastActive.togglePause()
      return .success
    }
    remoteCommand.stopCommand.addTarget { _ in
      PlayerCore.lastActive.stop()
      return .success
    }
    remoteCommand.nextTrackCommand.addTarget { _ in
      PlayerCore.lastActive.navigateInPlaylist(nextMedia: true)
      return .success
    }
    remoteCommand.previousTrackCommand.addTarget { _ in
      PlayerCore.lastActive.navigateInPlaylist(nextMedia: false)
      return .success
    }
    remoteCommand.changeRepeatModeCommand.addTarget { _ in
      PlayerCore.lastActive.togglePlaylistLoop()
      return .success
    }
    remoteCommand.changeShuffleModeCommand.isEnabled = false
    // remoteCommand.changeShuffleModeCommand.addTarget {})
    remoteCommand.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1, 1.5, 2]
    remoteCommand.changePlaybackRateCommand.addTarget { event in
      PlayerCore.lastActive.setSpeed(Double((event as! MPChangePlaybackRateCommandEvent).playbackRate))
      return .success
    }
    remoteCommand.skipForwardCommand.preferredIntervals = [15]
    remoteCommand.skipForwardCommand.addTarget { event in
      PlayerCore.lastActive.seek(relativeSecond: (event as! MPSkipIntervalCommandEvent).interval, option: .defaultValue)
      return .success
    }
    remoteCommand.skipBackwardCommand.preferredIntervals = [15]
    remoteCommand.skipBackwardCommand.addTarget { event in
      PlayerCore.lastActive.seek(relativeSecond: -(event as! MPSkipIntervalCommandEvent).interval, option: .defaultValue)
      return .success
    }
    remoteCommand.changePlaybackPositionCommand.addTarget { event in
      PlayerCore.lastActive.seek(absoluteSecond: (event as! MPChangePlaybackPositionCommandEvent).positionTime)
      return .success
    }
  }

  static func disableAllCommands() {
    remoteCommand.playCommand.removeTarget(nil)
    remoteCommand.pauseCommand.removeTarget(nil)
    remoteCommand.togglePlayPauseCommand.removeTarget(nil)
    remoteCommand.stopCommand.removeTarget(nil)
    remoteCommand.nextTrackCommand.removeTarget(nil)
    remoteCommand.previousTrackCommand.removeTarget(nil)
    remoteCommand.changeRepeatModeCommand.removeTarget(nil)
    remoteCommand.changeShuffleModeCommand.removeTarget(nil)
    remoteCommand.changePlaybackRateCommand.removeTarget(nil)
    remoteCommand.skipForwardCommand.removeTarget(nil)
    remoteCommand.skipBackwardCommand.removeTarget(nil)
    remoteCommand.changePlaybackPositionCommand.removeTarget(nil)
  }
}
