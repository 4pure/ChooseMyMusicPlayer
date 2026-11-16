//
// MediaKeyTap.swift
// ChooseMyMusicPlayer
//
// Swallow hardware media keys (keyboard / Touch Bar) via CGEvent tap while
// "ignore media keys" is on. Headset AVRCP still needs Now Playing ownership;
// this tap covers the path that bypasses Remote Command Center.
// Requires Input Monitoring; a default (filter) tap also needs Accessibility.
//

import AppKit
import ApplicationServices
import CoreGraphics

final class MediaKeyTap {
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var permissionPrompted = false

  private static let systemDefinedRaw: UInt32 = 14  // NX_SYSDEFINED
  private static let mediaKeyCodes: Set<Int> = [
    16,  // NX_KEYTYPE_PLAY
    17,  // NX_KEYTYPE_NEXT
    18,  // NX_KEYTYPE_PREVIOUS
    19,  // NX_KEYTYPE_FAST
    20,  // NX_KEYTYPE_REWIND
  ]

  var hasRequiredPermissions: Bool {
    CGPreflightListenEventAccess() && AXIsProcessTrusted()
  }

  /// Trigger system prompts for Input Monitoring + Accessibility, then show guidance.
  /// Used by settings and by tap start when permissions are missing.
  func requestPermissions(forceGuidance: Bool = true) {
    let listenOK = CGPreflightListenEventAccess()
    let axOK = AXIsProcessTrusted()
    if !listenOK {
      CGRequestListenEventAccess()
    }
    if !axOK {
      let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        as CFDictionary
      AXIsProcessTrustedWithOptions(opts)
    }
    NSLog(
      "ChooseMyMusicPlayer: request permissions listen=%d accessibility=%d",
      listenOK ? 1 : 0,
      axOK ? 1 : 0
    )
    if forceGuidance || !listenOK || !axOK {
      promptForPermissions(force: forceGuidance)
    }
  }

  @discardableResult
  func start() -> Bool {
    stop()

    let listenOK = CGPreflightListenEventAccess()
    let axOK = AXIsProcessTrusted()
    if !listenOK || !axOK {
      requestPermissions(forceGuidance: false)
      return false
    }

    let mask = CGEventMask(1 << Self.systemDefinedRaw)
    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else {
        return Unmanaged.passUnretained(event)
      }
      let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
      return tap.handle(type: type, event: event)
    }
    let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

    let created =
      CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: userInfo
      )
      ?? CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: userInfo
      )

    guard let created else {
      NSLog("ChooseMyMusicPlayer: CGEvent.tapCreate failed with permissions granted")
      promptForPermissions(force: false)
      return false
    }

    tap = created
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
    if let runLoopSource {
      CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    CGEvent.tapEnable(tap: created, enable: true)
    NSLog("ChooseMyMusicPlayer: media key tap enabled")
    return true
  }

  func stop() {
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    runLoopSource = nil
    tap = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    guard type.rawValue == Self.systemDefinedRaw,
      let nsEvent = NSEvent(cgEvent: event),
      nsEvent.subtype.rawValue == 8
    else {
      return Unmanaged.passUnretained(event)
    }

    let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
    guard Self.mediaKeyCodes.contains(keyCode) else {
      return Unmanaged.passUnretained(event)
    }

    // Tap is only started while ignore-media-key mode is on.
    // Swallow both key-down and key-up so play/pause never reaches the player.
    return nil
  }

  private func promptForPermissions(force: Bool) {
    if !force {
      guard !permissionPrompted else { return }
      permissionPrompted = true
    } else {
      permissionPrompted = true
    }
    DispatchQueue.main.async {
      let listenOK = CGPreflightListenEventAccess()
      let axOK = AXIsProcessTrusted()
      let alert = NSAlert()
      if listenOK && axOK {
        alert.messageText = "权限已就绪"
        alert.informativeText = """
        「输入监控」和「辅助功能」均已允许。

        若刚勾选授权，请完全退出并重新打开本应用后再试屏蔽媒体键。
        """
      } else {
        alert.messageText = "需要「输入监控」和「辅助功能」"
        alert.informativeText = """
        屏蔽媒体键时，键盘 / Touch Bar 的播放键需要系统事件监听才能真正吞掉。

        当前状态：
        • 输入监控：\(listenOK ? "已允许" : "未允许")
        • 辅助功能：\(axOK ? "已允许" : "未允许")

        请在系统设置里允许这两项后，完全退出并重新打开本应用：
        • 隐私与安全性 › 输入监控
        • 隐私与安全性 › 辅助功能

        用仓库 scripts/package-dmg.sh 打包会使用稳定本地签名；授权一次后，后续重装一般不必再勾。若用 Xcode 临时 adhoc 签名覆盖安装，系统会当成新 App，需要重新授权。
        """
      }
      alert.alertStyle = .informational
      alert.addButton(withTitle: "打开输入监控")
      alert.addButton(withTitle: "打开辅助功能")
      alert.addButton(withTitle: "稍后")
      let result = alert.runModal()
      if result == .alertFirstButtonReturn {
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        {
          NSWorkspace.shared.open(url)
        }
      } else if result == .alertSecondButtonReturn {
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
          NSWorkspace.shared.open(url)
        }
      }
    }
  }
}
