//
// StatusItemController.swift
// ChooseMyMusicPlayer
//

import AppKit
import UniformTypeIdentifiers

@MainActor
protocol StatusItemControllerDelegate: AnyObject {
  var ignoreMediaKey: Bool { get }
  var playerPreset: MusicPlayerPreset { get }
  var customPlayerAppPath: String? { get }

  func resolvedPlayerPath() -> String
  func selectPlayerPreset(_ preset: MusicPlayerPreset)
  func selectCustomPlayer(path: String)
  func setIgnoreMediaKey(_ value: Bool)
  func openPreferredPlayer()
  func openSettings(nearStatusItemRect: NSRect?)
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  weak var delegate: StatusItemControllerDelegate?

  private let statusItem: NSStatusItem
  private let statusMenu = NSMenu()
  /// Captured while the menu is open; live measurement after dismiss/activation
  /// policy changes is occasionally wrong on multi-monitor setups.
  private var cachedStatusItemScreenRect: NSRect?
  private var pendingAfterMenuClose: (() -> Void)?

  override init() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()

    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: "music.note", accessibilityDescription: "ChooseMyMusicPlayer")
      button.image?.isTemplate = true
    }

    statusMenu.delegate = self
    statusItem.menu = statusMenu
    rebuildMenu()
  }

  func reloadMenu() {
    rebuildMenu()
  }

  /// Prefer a live button frame; fall back to the last good frame from menu open.
  func statusItemScreenRect() -> NSRect? {
    if let live = measureLiveStatusItemScreenRect() {
      cachedStatusItemScreenRect = live
      return live
    }
    return cachedStatusItemScreenRect
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard menu == statusMenu else { return }
    refreshCachedStatusItemScreenRect()
  }

  func menuDidClose(_ menu: NSMenu) {
    guard menu == statusMenu else { return }
    refreshCachedStatusItemScreenRect()
    let pending = pendingAfterMenuClose
    pendingAfterMenuClose = nil
    guard let pending else { return }
    // Let AppKit finish tearing down the menu window before presenting.
    DispatchQueue.main.async {
      pending()
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    if menu == statusMenu {
      rebuildMenu()
    }
  }

  private func rebuildMenu() {
    statusMenu.removeAllItems()
    guard let delegate else { return }

    let playerRoot = NSMenuItem(title: "默认播放器", action: nil, keyEquivalent: "")
    let playerMenu = NSMenu(title: "默认播放器")
    for preset in MusicPlayerPreset.builtIn {
      let item = NSMenuItem(
        title: preset.displayName,
        action: #selector(selectPreset(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = preset.rawValue
      item.state = delegate.playerPreset == preset ? .on : .off
      playerMenu.addItem(item)
    }

    if let customPath = delegate.customPlayerAppPath, !customPath.isEmpty {
      let name = (customPath as NSString).lastPathComponent
      let item = NSMenuItem(
        title: "自定义（\(name)）",
        action: #selector(selectCustomPreset(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.state = delegate.playerPreset == .custom ? .on : .off
      playerMenu.addItem(item)
    }

    playerMenu.addItem(.separator())
    let pickItem = NSMenuItem(
      title: "选取其他应用…",
      action: #selector(pickCustomApp(_:)),
      keyEquivalent: ""
    )
    pickItem.target = self
    playerMenu.addItem(pickItem)
    playerRoot.submenu = playerMenu
    statusMenu.addItem(playerRoot)

    let openPlayerItem = NSMenuItem(
      title: "打开默认播放器",
      action: #selector(openPreferredPlayer(_:)),
      keyEquivalent: ""
    )
    openPlayerItem.target = self
    statusMenu.addItem(openPlayerItem)

    let ignoreItem = NSMenuItem(
      title: "屏蔽媒体键操作",
      action: #selector(toggleIgnoreMediaKey(_:)),
      keyEquivalent: ""
    )
    ignoreItem.target = self
    ignoreItem.state = delegate.ignoreMediaKey ? .on : .off
    statusMenu.addItem(ignoreItem)

    statusMenu.addItem(.separator())

    let settingsItem = NSMenuItem(
      title: "设置",
      action: #selector(openSettings(_:)),
      keyEquivalent: ","
    )
    settingsItem.target = self
    statusMenu.addItem(settingsItem)

    let quitItem = NSMenuItem(
      title: "退出 ChooseMyMusicPlayer",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    statusMenu.addItem(quitItem)
  }

  private func refreshCachedStatusItemScreenRect() {
    if let live = measureLiveStatusItemScreenRect() {
      cachedStatusItemScreenRect = live
    }
  }

  private func measureLiveStatusItemScreenRect() -> NSRect? {
    guard let button = statusItem.button, let buttonWindow = button.window else {
      return nil
    }
    let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    // During menu teardown / activation-policy flips the button window can
    // briefly report an empty or off-screen frame — treat those as unusable.
    guard rect.width > 1, rect.height > 1 else { return nil }
    let mid = NSPoint(x: rect.midX, y: rect.midY)
    let onAnyScreen = NSScreen.screens.contains { NSMouseInRect(mid, $0.frame, false) }
    return onAnyScreen ? rect : nil
  }

  private func runAfterMenuCloses(_ work: @escaping () -> Void) {
    pendingAfterMenuClose = work
  }

  @objc private func selectPreset(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let preset = MusicPlayerPreset(rawValue: raw)
    else { return }
    delegate?.selectPlayerPreset(preset)
  }

  @objc private func selectCustomPreset(_ sender: NSMenuItem) {
    guard let path = delegate?.customPlayerAppPath, !path.isEmpty else { return }
    delegate?.selectCustomPlayer(path: path)
  }

  @objc private func pickCustomApp(_ sender: NSMenuItem) {
    // Snapshot while the menu (and status-item button) are still laid out.
    let anchor = statusItemScreenRect()
    runAfterMenuCloses { [weak self] in
      self?.presentCustomAppPicker(nearStatusItemRect: anchor)
    }
  }

  private func presentCustomAppPicker(nearStatusItemRect anchor: NSRect?) {
    let panel = NSOpenPanel()
    panel.message = "选择要用于媒体键的音乐播放器应用"
    panel.prompt = "选择"
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.application]
    panel.level = .floating

    let size = NSSize(width: 720, height: 480)
    let panelFrame = StatusItemLayout.centeredFrame(size: size, near: anchor)

    NSApp.activate(ignoringOtherApps: true)
    // NSOpenPanel often ignores setFrame before begin and recenters on the
    // main screen — pin it again once the panel window exists.
    panel.begin { [weak self] result in
      guard result == .OK, let url = panel.url else { return }
      do {
        let resolved = try URL(resolvingAliasFileAt: url)
        self?.delegate?.selectCustomPlayer(path: resolved.path)
      } catch {
        NSLog(
          "ChooseMyMusicPlayer: failed picking custom app %@: %@",
          url.absoluteString,
          String(describing: error)
        )
      }
    }
    if let panelFrame {
      panel.setFrame(panelFrame, display: true)
      DispatchQueue.main.async {
        panel.setFrame(panelFrame, display: true)
      }
    }
  }

  @objc private func toggleIgnoreMediaKey(_ sender: NSMenuItem) {
    guard let delegate else { return }
    delegate.setIgnoreMediaKey(!delegate.ignoreMediaKey)
  }

  @objc private func openPreferredPlayer(_ sender: NSMenuItem) {
    runAfterMenuCloses { [weak self] in
      self?.delegate?.openPreferredPlayer()
    }
  }

  @objc private func openSettings(_ sender: NSMenuItem) {
    // Capture before menu teardown / activation-policy change can move the item.
    let anchor = statusItemScreenRect()
    runAfterMenuCloses { [weak self] in
      self?.delegate?.openSettings(nearStatusItemRect: anchor)
    }
  }
}

enum StatusItemLayout {
  /// Screen that best contains the status-item rect (midpoint, then max overlap,
  /// then mouse location — useful right after a status-item click).
  static func screen(containing rect: NSRect?) -> NSScreen? {
    if let rect {
      let mid = NSPoint(x: rect.midX, y: rect.midY)
      if let hit = NSScreen.screens.first(where: { NSMouseInRect(mid, $0.frame, false) }) {
        return hit
      }
      if let overlap = NSScreen.screens.max(by: {
        intersectionArea($0.frame, rect) < intersectionArea($1.frame, rect)
      }), intersectionArea(overlap.frame, rect) > 0 {
        return overlap
      }
    }
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
  }

  static func centeredFrame(size: NSSize, near rect: NSRect?) -> NSRect? {
    guard let visible = screen(containing: rect)?.visibleFrame else { return nil }
    return NSRect(
      x: visible.midX - size.width / 2,
      y: visible.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
    let inter = a.intersection(b)
    guard !inter.isNull, !inter.isEmpty else { return 0 }
    return inter.width * inter.height
  }
}
