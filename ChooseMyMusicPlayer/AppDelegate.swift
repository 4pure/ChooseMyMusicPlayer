//
// AppDelegate.swift
// AntiMusic
//
// Created by nift4 on 08.12.2023.
//

import Cocoa
import MediaPlayer
import ServiceManagement

private enum FakeArtwork {
  static let size = CGSize(width: 1024, height: 1024)
  static let lightBackground = NSColor(
    srgbRed: 0.8274509804, green: 0.8274509804, blue: 0.831372549, alpha: 1)
  static let darkBackground = NSColor(
    srgbRed: 0.3529411765, green: 0.3529411765, blue: 0.3764705882, alpha: 1)
}

@main
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {

  private let mediaRemote = MediaRemoteService()
  private let ownBundleID: String
  private var settingsVisible = false
  private var statusItemController: StatusItemController?
  private var settingsWindowController: NSWindowController?
  private var settingsViewController: ViewController?
  // Title is required so headset / media keys route to Remote Command Center.
  private var fakePlayer: [String: Any] = [MPMediaItemPropertyTitle: "<AntiMusic.app>"]
  private var isHoldingNowPlaying = true
  /// Safety net: reclaim if Now Playing was cleared while we should still intercept.
  private var nowPlayingWatchdog: Timer?
  /// Prevent media-command → open/activate feedback loops.
  private var isHandlingRemoteCommand = false
  private var lastRemoteCommandAt: Date = .distantPast
  /// Once the preferred player has owned Now Playing, do not steal the slot back
  /// while that app stays running (avoids fighting SodaPlus/Netease for headset).
  private var preferredHasOwnedNowPlaying = false
  private var pendingForwardWorkItems: [DispatchWorkItem] = []

  var ignoreMediaKey = false
  var playerPreset: MusicPlayerPreset = .appleMusic
  var customPlayerAppPath: String?
  var playerApp = "/System/Applications/Music.app"

  public override init() {
    ownBundleID = Bundle.main.bundleIdentifier ?? "org.nift4.AntiMusic"
    super.init()

    // Headset and system media keys are delivered through Now Playing.
    let infoCenter = MPNowPlayingInfoCenter.default()
    infoCenter.playbackState = .playing
    infoCenter.playbackState = .stopped

    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async {
        self?.handleRemoteCommand(.togglePlayPause, fromControlCenter: false)
      }
      return .success
    }
    commandCenter.playCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async {
        self?.handleRemoteCommand(.play, fromControlCenter: true)
      }
      return .success
    }
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async {
        self?.handleRemoteCommand(.pause, fromControlCenter: true)
      }
      return .success
    }
    commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async {
        self?.handleRemoteCommand(.nextTrack, fromControlCenter: false)
      }
      return .success
    }
    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async {
        self?.handleRemoteCommand(.previousTrack, fromControlCenter: false)
      }
      return .success
    }

    mediaRemote.onNowPlayingChanged { [weak self] in
      self?.loadSongInfo()
    }
    mediaRemote.start()

    DistributedNotificationCenter.default.addObserver(
      self,
      selector: #selector(interfaceModeChanged(sender:)),
      name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil
    )

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(appDidLaunch(_:)),
      name: NSWorkspace.didLaunchApplicationNotification,
      object: nil
    )

    loadPersistedSettings()
    refreshFakePlayerMetadata()
    loadSongInfo()
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    enableLaunchAtLoginIfNeeded()

    let status = StatusItemController()
    status.delegate = self
    statusItemController = status

    // Ensure we own the idle Now Playing slot after launch.
    reclaimNowPlaying()
    loadSongInfo()
    startNowPlayingWatchdog()
  }

  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    openSettings()
    return false
  }

  public func applicationDidResignActive(_ notification: Notification) {
    guard settingsVisible else { return }
    if settingsViewController?.hasOpenPanel == true { return }
    settingsWindowController?.close()
    NSApp.setActivationPolicy(.accessory)
    settingsVisible = false
  }

  func openSettings() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    OperationQueue.main.addOperation {
      NSMenu.setMenuBarVisible(false)
      OperationQueue.main.addOperation {
        NSMenu.setMenuBarVisible(true)
      }
    }

    let controller = ensureSettingsWindow()
    controller.delegate = self
    controller.reloadFromDelegate()
    settingsWindowController?.window?.center()
    settingsWindowController?.showWindow(nil)
    settingsVisible = true
  }

  private func ensureSettingsWindow() -> ViewController {
    if let existing = settingsViewController, settingsWindowController != nil {
      return existing
    }

    let controller = ViewController()
    controller.delegate = self
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 168),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "AntiMusic 设置"
    window.contentViewController = controller
    window.isReleasedWhenClosed = false
    window.center()

    let windowController = NSWindowController(window: window)
    settingsViewController = controller
    settingsWindowController = windowController
    return controller
  }

  func resolvedPlayerPath() -> String {
    if let path = playerPreset.resolvedPath(customPath: customPlayerAppPath) {
      return path
    }
    return playerApp
  }

  func applyPlayerPreset(_ preset: MusicPlayerPreset, customPath: String? = nil) {
    if preset == .custom {
      if let customPath {
        customPlayerAppPath = customPath
      }
      guard let path = customPlayerAppPath, !path.isEmpty else { return }
      playerPreset = .custom
      playerApp = path
    } else {
      playerPreset = preset
      if let path = preset.resolvedPath(customPath: nil) {
        playerApp = path
      }
    }
    writeSettings()
    refreshFakePlayerMetadata()
    refreshNowPlaying()
    statusItemController?.reloadMenu()
    settingsViewController?.reloadFromDelegate()
  }

  func setIgnoreMediaKey(_ value: Bool) {
    ignoreMediaKey = value
    writeSettings()
    statusItemController?.reloadMenu()
    settingsViewController?.reloadFromDelegate()
  }

  private func handleRemoteCommand(
    _ command: MediaRemoteCommand,
    fromControlCenter: Bool
  ) {
    guard isHoldingNowPlaying else { return }
    if ignoreMediaKey && !fromControlCenter {
      return
    }
    // Short debounce only — a 1s lock made headset feel dead right after wake.
    let now = Date()
    guard !isHandlingRemoteCommand, now.timeIntervalSince(lastRemoteCommandAt) > 0.35 else {
      return
    }
    lastRemoteCommandAt = now
    isHandlingRemoteCommand = true
    forwardCommandToPreferredPlayer(command)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      self?.isHandlingRemoteCommand = false
    }
  }

  func openPreferredPlayer() {
    openPreferredPlayer(activates: true)
  }

  private func openPreferredPlayer(activates: Bool) {
    let path = resolvedPlayerPath()
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let configuration = NSWorkspace.OpenConfiguration()
    // Media-key path must not steal focus; menu "打开默认播放器" still activates.
    configuration.activates = activates
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
      if let error {
        NSLog("AntiMusic: failed to open player %@: %@", path, String(describing: error))
      }
    }
  }

  private func preferredPlayerBundleIdentifier() -> String? {
    let path = resolvedPlayerPath()
    return Bundle(path: path)?.bundleIdentifier
  }

  private func forwardCommandToPreferredPlayer(_ command: MediaRemoteCommand) {
    let path = resolvedPlayerPath()
    let bundleID = preferredPlayerBundleIdentifier()

    guard let bundleID else {
      NSLog("AntiMusic: preferred player has no bundle id: %@", path)
      return
    }

    let alreadyRunning = isPreferredPlayerRunning()

    // Only launch when needed. Never steal focus if already running.
    if !alreadyRunning {
      openPreferredPlayer(activates: false)
    }

    if bundleID == "com.apple.Music" {
      sendAppleMusicCommand(command)
      suppressMusicAppIfNeeded()
      return
    }

    // Cold start: SodaPlus needs a moment for bridge + Remote Command Center.
    // Keep holding Now Playing and retry forward instead of yielding into a dead zone.
    pendingForwardWorkItems.forEach { $0.cancel() }
    pendingForwardWorkItems.removeAll()
    let delays: [TimeInterval] = alreadyRunning ? [0.0, 0.6] : [0.8, 1.8, 3.0]
    for delay in delays {
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.mediaRemote.send(command, toBundleIdentifier: bundleID)
        self.suppressMusicAppIfNeeded()
        self.yieldToPreferredPlayerIfRunning()
      }
      pendingForwardWorkItems.append(work)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    if alreadyRunning {
      preferredHasOwnedNowPlaying = true
    }
  }

  private func isPreferredPlayerRunning() -> Bool {
    guard let bundleID = preferredPlayerBundleIdentifier() else { return false }
    return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
  }

  private func suppressMusicAppIfNeeded() {
    guard preferredPlayerBundleIdentifier() != "com.apple.Music" else { return }
    let musicApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
    for app in musicApps where !app.isTerminated {
      NSLog("AntiMusic: terminating Music.app launched while preferred player is not Music")
      app.terminate()
    }
  }

  @objc private func appDidLaunch(_ notification: Notification) {
    guard
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
      app.bundleIdentifier == "com.apple.Music"
    else { return }
    // Ignore launches that happen while we ourselves are mid-command.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.suppressMusicAppIfNeeded()
      self?.yieldToPreferredPlayerIfRunning()
    }
  }

  private func sendAppleMusicCommand(_ command: MediaRemoteCommand) {
    let script: String
    switch command {
    case .play:
      script = "tell application \"Music\" to play"
    case .pause:
      script = "tell application \"Music\" to pause"
    case .togglePlayPause:
      script = "tell application \"Music\" to playpause"
    case .nextTrack:
      script = "tell application \"Music\" to next track"
    case .previousTrack:
      script = "tell application \"Music\" to previous track"
    }
    var errorInfo: NSDictionary?
    if let appleScript = NSAppleScript(source: script) {
      appleScript.executeAndReturnError(&errorInfo)
      if let errorInfo {
        NSLog("AntiMusic: Apple Music script failed: %@", String(describing: errorInfo))
      }
    }
  }

  func refreshFakePlayerMetadata() {
    let path = resolvedPlayerPath()
    playerApp = path
    fakePlayer[MPMediaItemPropertyTitle] = (path as NSString).lastPathComponent
    let targetSize = FakeArtwork.size
    let miniSize = CGSize(width: targetSize.width / 2, height: targetSize.height / 2)
    let playerAppPath = path

    fakePlayer[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: targetSize) { _ in
      let icon = NSWorkspace.shared.icon(forFile: playerAppPath)
      let frame = NSRect(origin: .zero, size: miniSize)
      guard let rep = icon.bestRepresentation(for: frame, context: nil, hints: nil) else {
        return NSImage(size: targetSize)
      }

      let iconImage = NSImage(size: rep.size)
      iconImage.addRepresentation(rep)

      return NSImage(size: targetSize, flipped: false) { rect in
        let dark = [NSAppearance.Name.darkAqua, NSAppearance.Name.vibrantDark]
          .contains(NSApp.effectiveAppearance.name)
        (dark ? FakeArtwork.darkBackground : FakeArtwork.lightBackground).drawSwatch(in: rect)
        iconImage.draw(
          in: CGRect(
            origin: CGPoint(x: miniSize.width / 2, y: miniSize.height / 2),
            size: miniSize
          )
        )
        return true
      }
    }
  }

  func refreshNowPlaying() {
    guard isHoldingNowPlaying else { return }
    let infoCenter = MPNowPlayingInfoCenter.default()
    infoCenter.nowPlayingInfo = fakePlayer
    // Keep stopped: reporting .playing caused repeated pause/play callbacks.
    infoCenter.playbackState = .stopped
  }

  func writeSettings() {
    UserDefaults.standard.set(ignoreMediaKey, forKey: SettingsKey.ignoreMediaKey)
    UserDefaults.standard.set(playerApp, forKey: SettingsKey.playerApp)
    UserDefaults.standard.set(playerPreset.rawValue, forKey: SettingsKey.playerPreset)
    UserDefaults.standard.set(customPlayerAppPath, forKey: SettingsKey.customPlayerApp)
  }

  private func loadPersistedSettings() {
    ignoreMediaKey = UserDefaults.standard.bool(forKey: SettingsKey.ignoreMediaKey)
    customPlayerAppPath = UserDefaults.standard.string(forKey: SettingsKey.customPlayerApp)

    if let raw = UserDefaults.standard.string(forKey: SettingsKey.playerPreset),
      let preset = MusicPlayerPreset(rawValue: raw)
    {
      playerPreset = preset
    } else if let legacyPath = UserDefaults.standard.string(forKey: SettingsKey.playerApp) {
      if let matched = MusicPlayerPreset.matchingBuiltIn(path: legacyPath) {
        playerPreset = matched
      } else {
        playerPreset = .custom
        customPlayerAppPath = legacyPath
      }
    }

    playerApp = resolvedPlayerPath()
  }

  private func loadSongInfo() {
    yieldToPreferredPlayerIfRunning()
    suppressMusicAppIfNeeded()
  }

  /// Yield while the preferred player owns (or recently owned) Now Playing.
  /// Keep holding only before it has ever claimed a session, so cold headset
  /// presses still open SodaPlus instead of Music.app.
  private func yieldToPreferredPlayerIfRunning() {
    guard let preferredBundle = preferredPlayerBundleIdentifier() else {
      preferredHasOwnedNowPlaying = false
      reclaimNowPlaying()
      return
    }

    let preferredApps = NSRunningApplication.runningApplications(
      withBundleIdentifier: preferredBundle
    )
    if preferredApps.isEmpty {
      preferredHasOwnedNowPlaying = false
      reclaimNowPlaying()
      return
    }

    let preferredPIDs = Set(preferredApps.map(\.processIdentifier))

    mediaRemote.fetchPlaybackOwner { [weak self] _, pid in
      guard let self else { return }
      if preferredPIDs.contains(pid) {
        self.preferredHasOwnedNowPlaying = true
        self.relinquishNowPlaying()
        return
      }

      self.mediaRemote.currentClientBundleIdentifier { [weak self] clientBundle in
        guard let self else { return }
        if clientBundle == preferredBundle {
          self.preferredHasOwnedNowPlaying = true
          self.relinquishNowPlaying()
          return
        }

        if self.preferredHasOwnedNowPlaying {
          // Preferred still running after owning NP — stay out of its way.
          self.relinquishNowPlaying()
        } else {
          self.reclaimNowPlaying()
        }
      }
    }
  }

  private func reclaimNowPlayingUnlessPreferredOwnsSession() {
    yieldToPreferredPlayerIfRunning()
  }

  private func setRemoteCommandsEnabled(_ enabled: Bool) {
    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.togglePlayPauseCommand.isEnabled = enabled
    commandCenter.playCommand.isEnabled = enabled
    commandCenter.pauseCommand.isEnabled = enabled
    commandCenter.nextTrackCommand.isEnabled = enabled
    commandCenter.previousTrackCommand.isEnabled = enabled
  }

  private func relinquishNowPlaying() {
    isHoldingNowPlaying = false
    let infoCenter = MPNowPlayingInfoCenter.default()
    setRemoteCommandsEnabled(false)
    infoCenter.nowPlayingInfo = nil
    infoCenter.playbackState = .stopped
  }

  private func reclaimNowPlaying() {
    isHoldingNowPlaying = true
    setRemoteCommandsEnabled(true)
    refreshNowPlaying()
  }

  private func startNowPlayingWatchdog() {
    nowPlayingWatchdog?.invalidate()
    let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
      DispatchQueue.main.async {
        self?.loadSongInfo()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    nowPlayingWatchdog = timer
  }

  @objc private func interfaceModeChanged(sender: NSNotification) {
    refreshFakePlayerMetadata()
    if isHoldingNowPlaying {
      refreshNowPlaying()
    }
  }

  private func enableLaunchAtLoginIfNeeded() {
    let service = SMAppService.mainApp
    guard service.status != .enabled else { return }
    do {
      try service.register()
    } catch {
      NSLog("AntiMusic: failed to enable launch at login: %@", String(describing: error))
    }
  }
}

extension AppDelegate: StatusItemControllerDelegate {
  func selectPlayerPreset(_ preset: MusicPlayerPreset) {
    applyPlayerPreset(preset)
  }

  func selectCustomPlayer(path: String) {
    applyPlayerPreset(.custom, customPath: path)
  }
}

extension AppDelegate: SettingsViewDelegate {}
