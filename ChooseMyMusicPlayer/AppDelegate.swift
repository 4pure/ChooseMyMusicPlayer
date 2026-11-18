//
// AppDelegate.swift
// ChooseMyMusicPlayer
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
  private let mediaKeyTap = MediaKeyTap()
  private let ownBundleID: String
  private var settingsVisible = false
  private var statusItemController: StatusItemController?
  private var settingsWindowController: NSWindowController?
  private var settingsViewController: ViewController?
  // Title is required so headset / media keys route to Remote Command Center.
  private var fakePlayer: [String: Any] = [MPMediaItemPropertyTitle: "<ChooseMyMusicPlayer.app>"]
  private var isHoldingNowPlaying = false
  /// Safety net: reclaim if Now Playing was cleared while we should still intercept.
  private var nowPlayingWatchdog: Timer?
  /// Prevent media-command → open/activate feedback loops.
  private var isHandlingRemoteCommand = false
  private var lastRemoteCommandAt: Date = .distantPast
  /// While true, do not reclaim Now Playing — preferred must be free to take it
  /// after we relinquish for MediaRemote forward.
  private var isForwardingToPreferred = false
  /// Once the preferred player has owned Now Playing, do not steal the slot back
  /// while that app stays running (avoids fighting SodaPlus/Netease for headset).
  private var preferredHasOwnedNowPlaying = false
  /// After a cold-start open-only wake, keep holding NP until the next transport
  /// command so the first real play/pause is forwarded by us (not lost on a
  /// half-ready player session).
  private var keepHoldingAfterColdLaunch = false
  /// Timestamp of the last cold-start open; used to stretch MediaRemote retries
  /// until Netease/SodaPlus finish coming up.
  private var coldLaunchAt: Date?
  /// Swallow RCC callbacks caused by our own Now Playing registration pulse.
  private var suppressRemoteCommands = false
  private var pendingForwardWorkItems: [DispatchWorkItem] = []
  private var pendingMusicSuppressWorkItems: [DispatchWorkItem] = []

  var ignoreMediaKey = false
  var playerPreset: MusicPlayerPreset = .appleMusic
  var customPlayerAppPath: String?
  var playerApp = "/System/Applications/Music.app"

  public override init() {
    ownBundleID = Bundle.main.bundleIdentifier ?? "org.nift4.ChooseMyMusicPlayer"
    super.init()

    // Do not claim Now Playing in init — wait for applicationDidFinishLaunching
    // so we can yield to an already-playing preferred player instead of stealing.

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
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    enableLaunchAtLoginIfNeeded()

    let status = StatusItemController()
    status.delegate = self
    statusItemController = status

    // Steal/hold first so headset is not stuck on Douyin/others. loadSongInfo
    // yields only when the preferred player actually owns Now Playing.
    if ignoreMediaKey {
      startIgnoringMediaKeys()
    } else {
      reclaimNowPlaying()
      loadSongInfo()
    }
    startNowPlayingWatchdog()
  }

  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    openSettings(nearStatusItemRect: nil)
    return false
  }

  public func applicationDidResignActive(_ notification: Notification) {
    guard settingsVisible else { return }
    if settingsViewController?.hasOpenPanel == true { return }
    settingsWindowController?.close()
    NSApp.setActivationPolicy(.accessory)
    settingsVisible = false
  }

  func openSettings(nearStatusItemRect preferredAnchor: NSRect?) {
    // Resolve the anchor before flipping activation policy — that transition
    // can briefly make the live status-item frame unusable.
    let anchor =
      preferredAnchor
      ?? statusItemController?.statusItemScreenRect()

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    let controller = ensureSettingsWindow()
    controller.delegate = self
    controller.reloadFromDelegate()
    guard let window = settingsWindowController?.window else { return }

    applyStatusItemAnchor(anchor, to: window)
    settingsWindowController?.showWindow(nil)
    window.orderFrontRegardless()
    settingsVisible = true

    // Accessory → regular apps often need a menu-bar flash to accept key focus,
    // but hiding the menu bar can shove windows onto another screen. Re-assert
    // the anchor after the flash settles.
    OperationQueue.main.addOperation {
      NSMenu.setMenuBarVisible(false)
      OperationQueue.main.addOperation {
        NSMenu.setMenuBarVisible(true)
        OperationQueue.main.addOperation {
          self.applyStatusItemAnchor(anchor, to: window)
        }
      }
    }
  }

  /// Place the settings window under the status item on the same screen.
  private func applyStatusItemAnchor(_ anchor: NSRect?, to window: NSWindow) {
    guard let anchor else {
      window.center()
      return
    }
    positionWindow(window, nearStatusItemRect: anchor)
  }

  private func positionWindow(_ window: NSWindow, nearStatusItemRect anchor: NSRect) {
    var frame = window.frame
    frame.origin.x = anchor.midX - frame.width / 2
    frame.origin.y = anchor.minY - frame.height - 8

    if let visible = StatusItemLayout.screen(containing: anchor)?.visibleFrame {
      frame.origin.x = min(
        max(frame.origin.x, visible.minX + 8),
        visible.maxX - frame.width - 8
      )
      frame.origin.y = min(
        max(frame.origin.y, visible.minY + 8),
        visible.maxY - frame.height - 8
      )
    }
    window.setFrame(frame, display: true)
  }

  private func ensureSettingsWindow() -> ViewController {
    if let existing = settingsViewController, settingsWindowController != nil {
      return existing
    }

    let controller = ViewController()
    controller.delegate = self
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "ChooseMyMusicPlayer 设置"
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
    // Drop ownership latch for the previous preferred player so the next
    // headset press targets the newly selected app instead of the old one.
    preferredHasOwnedNowPlaying = false
    keepHoldingAfterColdLaunch = false
    coldLaunchAt = nil
    cancelPendingForwards()
    writeSettings()
    refreshFakePlayerMetadata()
    if ignoreMediaKey {
      reclaimNowPlayingForIgnore()
    } else {
      reclaimNowPlaying()
    }
    statusItemController?.reloadMenu()
    settingsViewController?.reloadFromDelegate()
  }

  func setIgnoreMediaKey(_ value: Bool) {
    ignoreMediaKey = value
    writeSettings()
    if value {
      startIgnoringMediaKeys()
    } else {
      stopIgnoringMediaKeys()
    }
    statusItemController?.reloadMenu()
    settingsViewController?.reloadFromDelegate()
  }

  var hasMediaKeyPermissions: Bool {
    mediaKeyTap.hasRequiredPermissions
  }

  func requestMediaKeyPermissions() {
    mediaKeyTap.requestPermissions(forceGuidance: true)
    if ignoreMediaKey, mediaKeyTap.hasRequiredPermissions {
      _ = mediaKeyTap.start()
    }
    settingsViewController?.reloadFromDelegate()
  }

  /// Ignore mode: never launch / never forward. Steal Now Playing with
  /// `.playing` so an already-active Netease/SodaPlus session is displaced;
  /// swallow Remote Command Center events; CGEvent tap covers keyboard keys.
  private func startIgnoringMediaKeys() {
    cancelPendingForwards()
    isHandlingRemoteCommand = false
    preferredHasOwnedNowPlaying = false
    reclaimNowPlayingForIgnore()
    _ = mediaKeyTap.start()
  }

  private func stopIgnoringMediaKeys() {
    mediaKeyTap.stop()
    cancelPendingForwards()
    isHandlingRemoteCommand = false
    // Re-evaluate yield/hold with normal rules (preferred may already own NP).
    preferredHasOwnedNowPlaying = false
    reclaimNowPlaying()
    loadSongInfo()
  }

  private func cancelPendingForwards() {
    pendingForwardWorkItems.forEach { $0.cancel() }
    pendingForwardWorkItems.removeAll()
    isForwardingToPreferred = false
  }

  private func cancelPendingMusicSuppress() {
    pendingMusicSuppressWorkItems.forEach { $0.cancel() }
    pendingMusicSuppressWorkItems.removeAll()
  }

  /// Keep killing Music.app for a short window after wake/forward — a single
  /// terminate often loses the race when MediaRemote briefly re-launches it.
  private func scheduleMusicSuppression(for duration: TimeInterval = 3.0) {
    cancelPendingMusicSuppress()
    suppressMusicAppIfNeeded()
    let steps = stride(from: 0.15, through: duration, by: 0.35).map { $0 }
    for delay in steps {
      let work = DispatchWorkItem { [weak self] in
        self?.suppressMusicAppIfNeeded()
      }
      pendingMusicSuppressWorkItems.append(work)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
  }

  private func handleRemoteCommand(_ command: MediaRemoteCommand) {
    // Ignore first: even if we are mid-transition, never launch/forward.
    if ignoreMediaKey {
      reclaimNowPlayingForIgnore()
      return
    }
    if suppressRemoteCommands {
      return
    }
    guard isHoldingNowPlaying else { return }
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
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
      NSLog("ChooseMyMusicPlayer: preferred player path missing: %@", path)
      return
    }
    NSLog(
      "ChooseMyMusicPlayer: opening preferred player activates=%d path=%@",
      activates ? 1 : 0, path)
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) {
      [weak self] app, error in
      if let error {
        NSLog(
          "ChooseMyMusicPlayer: NSWorkspace open failed %@: %@ — falling back to /usr/bin/open",
          path, String(describing: error))
        self?.openPreferredPlayerViaOpenCommand(activates: activates)
        return
      }
      NSLog(
        "ChooseMyMusicPlayer: opened preferred player pid=%d",
        app?.processIdentifier ?? -1)
      guard activates else { return }
      DispatchQueue.main.async {
        self?.forceActivatePreferredPlayer(app)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
        self?.forceActivatePreferredPlayer(nil)
      }
    }
  }

  private func openPreferredPlayerViaOpenCommand(activates: Bool) {
    let path = resolvedPlayerPath()
    guard !path.isEmpty else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = activates ? [path] : ["-g", path]
    do {
      try process.run()
      NSLog("ChooseMyMusicPlayer: /usr/bin/open launched %@", path)
    } catch {
      NSLog(
        "ChooseMyMusicPlayer: /usr/bin/open failed %@: %@", path, String(describing: error))
    }
  }

  private func forceActivatePreferredPlayer(_ app: NSRunningApplication?) {
    if let app {
      app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    } else if let bundleID = preferredPlayerBundleIdentifier() {
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first?
        .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
    activatePreferredPlayerViaAppleScript()
  }

  private func activatePreferredPlayerViaAppleScript() {
    let path = resolvedPlayerPath()
    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    guard !name.isEmpty else { return }
    let script = "tell application \"\(name)\" to activate"
    var errorInfo: NSDictionary?
    if let appleScript = NSAppleScript(source: script) {
      appleScript.executeAndReturnError(&errorInfo)
      if let errorInfo {
        NSLog(
          "ChooseMyMusicPlayer: activate script failed: %@", String(describing: errorInfo))
      }
    }
  }

  private func preferredPlayerBundleIdentifier() -> String? {
    let path = resolvedPlayerPath()
    return Bundle(path: path)?.bundleIdentifier
  }

  private func forwardCommandToPreferredPlayer(_ command: MediaRemoteCommand) {
    // Hard stop: ignore mode must never open or poke another player.
    guard !ignoreMediaKey else { return }

    let path = resolvedPlayerPath()
    let bundleID = preferredPlayerBundleIdentifier()

    guard let bundleID else {
      NSLog("ChooseMyMusicPlayer: preferred player has no bundle id: %@", path)
      return
    }

    let alreadyRunning = isPreferredPlayerRunning()

    // Cold start: open + focus only. Do NOT auto-play. Keep holding Now Playing
    // until the next key so play/pause is forwarded once the app is ready.
    if !alreadyRunning {
      preferredHasOwnedNowPlaying = false
      keepHoldingAfterColdLaunch = true
      coldLaunchAt = Date()
      openPreferredPlayer(activates: true)
      reclaimNowPlaying()
      scheduleMusicSuppression(for: 4.0)
      return
    }

    if bundleID == "com.apple.Music" {
      keepHoldingAfterColdLaunch = false
      coldLaunchAt = nil
      sendAppleMusicCommand(command)
      suppressMusicAppIfNeeded()
      return
    }

    // Already running (including the first control press after cold launch).
    cancelPendingForwards()
    let recentlyColdLaunched =
      coldLaunchAt.map { Date().timeIntervalSince($0) < 15 } ?? false
    keepHoldingAfterColdLaunch = false
    preferredHasOwnedNowPlaying = true
    isForwardingToPreferred = true
    relinquishNowPlaying()
    scheduleMusicSuppression(for: 5.0)

    // Client send targets the preferred app. Global send without DisableImplicit
    // is needed for Netease play/pause; Music fallout is handled by suppress.
    // Stretch retries after a cold wake — Netease/SodaPlus ignore early commands.
    let delays: [TimeInterval] =
      recentlyColdLaunched
      ? [0.6, 1.4, 2.4, 3.6]
      : [0.15, 0.45, 0.9, 1.5]
    for delay in delays {
      let work = DispatchWorkItem { [weak self] in
        guard let self, !self.ignoreMediaKey else { return }
        self.mediaRemote.send(command, toBundleIdentifier: bundleID)
        _ = self.mediaRemote.sendGlobal(command, disableImplicitLaunch: false)
        self.suppressMusicAppIfNeeded()
      }
      pendingForwardWorkItems.append(work)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    let finish = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.isForwardingToPreferred = false
      self.coldLaunchAt = nil
      self.scheduleMusicSuppression(for: 2.0)
      if self.ignoreMediaKey {
        self.reclaimNowPlayingForIgnore()
      } else {
        self.yieldToPreferredPlayerIfRunning()
      }
    }
    pendingForwardWorkItems.append(finish)
    let settle: TimeInterval = recentlyColdLaunched ? 4.2 : 2.0
    DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: finish)
  }

  private func isPreferredPlayerRunning() -> Bool {
    guard let bundleID = preferredPlayerBundleIdentifier() else { return false }
    return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
  }

  private func suppressMusicAppIfNeeded() {
    guard preferredPlayerBundleIdentifier() != "com.apple.Music" else { return }
    let musicApps = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.apple.Music")
    for app in musicApps where !app.isTerminated {
      NSLog(
        "ChooseMyMusicPlayer: force-terminating Music.app launched while preferred is not Music")
      // Soft terminate loses the race against MediaRemote re-launch storms.
      app.forceTerminate()
    }
  }

  @objc private func appDidLaunch(_ notification: Notification) {
    guard
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
      app.bundleIdentifier == "com.apple.Music"
    else { return }
    // Kill Music immediately when preferred is not Music — delay let it bounce.
    DispatchQueue.main.async { [weak self] in
      self?.suppressMusicAppIfNeeded()
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
        NSLog("ChooseMyMusicPlayer: Apple Music script failed: %@", String(describing: errorInfo))
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
    // Always report .playing while holding. Idle .stopped cannot displace
    // Douyin/other active sessions, so headset AVRCP never reaches us and
    // the preferred player cannot be woken. Callback storms are absorbed by
    // debounce + suppressRemoteCommands; ignore mode still swallows.
    var info = fakePlayer
    info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
    info[MPMediaItemPropertyPlaybackDuration] = 3600.0
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 1.0
    let infoCenter = MPNowPlayingInfoCenter.default()
    infoCenter.nowPlayingInfo = info
    infoCenter.playbackState = .playing
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
    if ignoreMediaKey {
      // Keep / re-steal the Now Playing slot so headset AVRCP stays blocked
      // even when Netease/SodaPlus was already playing.
      reclaimNowPlayingForIgnore()
      return
    }
    if isForwardingToPreferred {
      return
    }
    yieldToPreferredPlayerIfRunning()
    suppressMusicAppIfNeeded()
  }

  /// Yield while the preferred player currently owns Now Playing.
  /// Keep holding the idle slot otherwise so media keys still forward.
  private func yieldToPreferredPlayerIfRunning() {
    if ignoreMediaKey {
      return
    }
    if isForwardingToPreferred {
      return
    }
    // Stay in the idle slot after cold-start wake so the next headset press
    // still reaches us (avoids a dead first pause on a half-ready player).
    // Do not re-pulse if we already hold — that would re-arm suppressRemoteCommands
    // and swallow the next real headset press.
    if keepHoldingAfterColdLaunch {
      if !isHoldingNowPlaying {
        reclaimNowPlaying()
      }
      return
    }

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
      guard let self, !self.ignoreMediaKey else { return }
      if preferredPIDs.contains(pid) {
        self.preferredHasOwnedNowPlaying = true
        self.relinquishNowPlaying()
        return
      }

      self.mediaRemote.currentClientBundleIdentifier { [weak self] clientBundle in
        guard let self, !self.ignoreMediaKey else { return }
        if clientBundle == preferredBundle {
          self.preferredHasOwnedNowPlaying = true
          self.relinquishNowPlaying()
          return
        }

        // Preferred is not the NP client (Douyin/others may own it). Steal the
        // slot so headset keys reach us and can open/forward to preferred.
        // Do NOT stay yielded just because preferred once owned NP.
        self.reclaimNowPlaying()
      }
    }
  }

  private func reclaimNowPlayingUnlessPreferredOwnsSession() {
    yieldToPreferredPlayerIfRunning()
  }

  private var remoteCommandTargetsInstalled = false

  private func setRemoteCommandsEnabled(_ enabled: Bool) {
    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.togglePlayPauseCommand.isEnabled = enabled
    commandCenter.playCommand.isEnabled = enabled
    commandCenter.pauseCommand.isEnabled = enabled
    commandCenter.nextTrackCommand.isEnabled = enabled
    commandCenter.previousTrackCommand.isEnabled = enabled
  }

  /// Removing targets while forwarding prevents MRMediaRemoteSendCommand from
  /// looping back into this process after we clear Now Playing.
  private func removeRemoteCommandTargets() {
    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.togglePlayPauseCommand.removeTarget(nil)
    commandCenter.playCommand.removeTarget(nil)
    commandCenter.pauseCommand.removeTarget(nil)
    commandCenter.nextTrackCommand.removeTarget(nil)
    commandCenter.previousTrackCommand.removeTarget(nil)
    remoteCommandTargetsInstalled = false
    setRemoteCommandsEnabled(false)
  }

  private func installRemoteCommandTargetsIfNeeded() {
    guard !remoteCommandTargetsInstalled else {
      setRemoteCommandsEnabled(true)
      return
    }
    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async { self?.handleRemoteCommand(.togglePlayPause) }
      return .success
    }
    commandCenter.playCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async { self?.handleRemoteCommand(.play) }
      return .success
    }
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async { self?.handleRemoteCommand(.pause) }
      return .success
    }
    commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async { self?.handleRemoteCommand(.nextTrack) }
      return .success
    }
    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      DispatchQueue.main.async { self?.handleRemoteCommand(.previousTrack) }
      return .success
    }
    remoteCommandTargetsInstalled = true
    setRemoteCommandsEnabled(true)
  }

  private func relinquishNowPlaying() {
    isHoldingNowPlaying = false
    removeRemoteCommandTargets()
    let infoCenter = MPNowPlayingInfoCenter.default()
    infoCenter.nowPlayingInfo = nil
    infoCenter.playbackState = .stopped
  }

  private func reclaimNowPlaying() {
    let needsRegistrationPulse = !isHoldingNowPlaying
    isHoldingNowPlaying = true
    installRemoteCommandTargetsIfNeeded()
    // Pulse .playing only when first taking the slot so the system registers
    // us. Re-pulsing while already holding re-arms suppress and drops real keys.
    if needsRegistrationPulse {
      suppressRemoteCommands = true
      MPNowPlayingInfoCenter.default().playbackState = .playing
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
        self?.suppressRemoteCommands = false
      }
    }
    refreshNowPlaying()
  }

  private func reclaimNowPlayingForIgnore() {
    isHoldingNowPlaying = true
    installRemoteCommandTargetsIfNeeded()
    // Ignore callbacks are swallowed in handleRemoteCommand before suppress checks,
    // so a .playing refresh here is safe and required to displace active players.
    refreshNowPlaying()
  }

  private func startNowPlayingWatchdog() {
    nowPlayingWatchdog?.invalidate()
    // Faster than 5s: Douyin/others can steal NP and leave headset dead until
    // we notice and reclaim with .playing.
    let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
      DispatchQueue.main.async {
        self?.ensureNowPlayingInterceptIfNeeded()
        self?.loadSongInfo()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    nowPlayingWatchdog = timer
  }

  /// If we believe we should intercept media keys but another non-preferred
  /// app currently owns Now Playing, steal it back.
  private func ensureNowPlayingInterceptIfNeeded() {
    if ignoreMediaKey {
      reclaimNowPlayingForIgnore()
      return
    }
    if isForwardingToPreferred || keepHoldingAfterColdLaunch {
      if !isHoldingNowPlaying {
        reclaimNowPlaying()
      }
      return
    }
    guard let preferredBundle = preferredPlayerBundleIdentifier() else {
      reclaimNowPlaying()
      return
    }
    mediaRemote.currentClientBundleIdentifier { [weak self] clientBundle in
      guard let self, !self.ignoreMediaKey else { return }
      if clientBundle == preferredBundle {
        return
      }
      if clientBundle == self.ownBundleID {
        return
      }
      // Empty or foreign owner (e.g. Douyin) — reclaim so headset can wake preferred.
      NSLog(
        "ChooseMyMusicPlayer: NP owned by %@ — reclaiming for preferred %@",
        clientBundle ?? "<none>", preferredBundle)
      self.reclaimNowPlaying()
    }
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
      NSLog("ChooseMyMusicPlayer: failed to enable launch at login: %@", String(describing: error))
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
