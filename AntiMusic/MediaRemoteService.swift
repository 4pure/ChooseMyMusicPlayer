//
// MediaRemoteService.swift
// AntiMusic
//
// Detects Now Playing ownership and forwards transport commands to a
// target player via MediaRemote private APIs.
//

import Foundation

enum MediaRemoteCommand: Int32 {
  case play = 0
  case pause = 1
  case togglePlayPause = 2
  case nextTrack = 4
  case previousTrack = 5
}

@MainActor
final class MediaRemoteService {
  private typealias GetNowPlayingClient =
    @convention(c) (DispatchQueue, @escaping (AnyObject) -> Void) -> Void
  private typealias GetBundleIdentifier = @convention(c) (AnyObject?) -> String
  private typealias RegisterForNotifications = @convention(c) (DispatchQueue) -> Void
  private typealias GetIsPlaying =
    @convention(c) (DispatchQueue, @escaping (ObjCBool) -> Void) -> Void
  private typealias GetPID = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
  private typealias CreateClient = @convention(c) (NSNumber?, NSString) -> AnyObject?
  private typealias SendCommandToClient = @convention(c) (
    Int32, AnyObject?, AnyObject?, AnyObject?, Int32, Int32, AnyObject?
  ) -> Void

  private let getNowPlayingClient: GetNowPlayingClient
  private let getBundleIdentifier: GetBundleIdentifier
  private let registerForNotifications: RegisterForNotifications
  private let getIsPlaying: GetIsPlaying
  private let getPID: GetPID
  private let createClient: CreateClient
  private let sendCommandToClient: SendCommandToClient
  private var infoObservers: [NSObjectProtocol] = []
  /// Keep fabricated MRClient instances alive across async MediaRemote work.
  private var fabricatedClients: [String: AnyObject] = [:]

  init() {
    let loaded = Self.loadSymbols()
    getNowPlayingClient = loaded.getNowPlayingClient
    getBundleIdentifier = loaded.getBundleIdentifier
    registerForNotifications = loaded.registerForNotifications
    getIsPlaying = loaded.getIsPlaying
    getPID = loaded.getPID
    createClient = loaded.createClient
    sendCommandToClient = loaded.sendCommandToClient
  }

  deinit {
    for observer in infoObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func start() {
    registerForNotifications(DispatchQueue.main)
  }

  func onNowPlayingChanged(_ handler: @escaping @MainActor () -> Void) {
    let names = [
      "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
      "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
      "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
    ]
    for name in names {
      let token = NotificationCenter.default.addObserver(
        forName: NSNotification.Name(name),
        object: nil,
        queue: .main
      ) { _ in
        Task { @MainActor in
          handler()
        }
      }
      infoObservers.append(token)
    }
  }

  func fetchPlaybackOwner(
    completion: @escaping @MainActor (_ isPlaying: Bool, _ pid: Int32) -> Void
  ) {
    getIsPlaying(DispatchQueue.main) { [weak self] playingFlag in
      guard let self else { return }
      self.getPID(DispatchQueue.main) { pid in
        Task { @MainActor in
          completion(playingFlag.boolValue, pid)
        }
      }
    }
  }

  func currentClientBundleIdentifier(completion: @escaping @MainActor (String?) -> Void) {
    getNowPlayingClient(DispatchQueue.main) { [weak self] client in
      guard let self else { return }
      let value = self.getBundleIdentifier(client)
      let bundleID = value.trimmingCharacters(in: .whitespacesAndNewlines)
      Task { @MainActor in
        completion(bundleID.isEmpty ? nil : bundleID)
      }
    }
  }

  /// Send a transport command to a specific app via MediaRemote.
  func send(_ command: MediaRemoteCommand, toBundleIdentifier bundleIdentifier: String) {
    let client: AnyObject
    if let existing = fabricatedClients[bundleIdentifier] {
      client = existing
    } else if let created = createClient(nil, bundleIdentifier as NSString) {
      fabricatedClients[bundleIdentifier] = created
      client = created
    } else {
      NSLog("AntiMusic: MRNowPlayingClientCreate failed for %@", bundleIdentifier)
      return
    }

    // Disable implicit launch so failed targets do not fall through to Music.app.
    let options: NSDictionary = [
      "kMRMediaRemoteOptionDisableImplicitAppLaunchBehaviors": true,
    ]
    sendCommandToClient(command.rawValue, options, nil, client, 1, 0, nil)
  }

  private static func loadSymbols() -> (
    getNowPlayingClient: GetNowPlayingClient,
    getBundleIdentifier: GetBundleIdentifier,
    registerForNotifications: RegisterForNotifications,
    getIsPlaying: GetIsPlaying,
    getPID: GetPID,
    createClient: CreateClient,
    sendCommandToClient: SendCommandToClient
  ) {
    let handle = dlopen(
      "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
      RTLD_NOW
    )
    func require(_ name: String) -> UnsafeMutableRawPointer {
      guard let pointer = dlsym(handle, name) else {
        fatalError("AntiMusic: MediaRemote symbol missing: \(name)")
      }
      return pointer
    }
    return (
      unsafeBitCast(require("MRMediaRemoteGetNowPlayingClient"), to: GetNowPlayingClient.self),
      unsafeBitCast(require("MRNowPlayingClientGetBundleIdentifier"), to: GetBundleIdentifier.self),
      unsafeBitCast(
        require("MRMediaRemoteRegisterForNowPlayingNotifications"),
        to: RegisterForNotifications.self),
      unsafeBitCast(
        require("MRMediaRemoteGetNowPlayingApplicationIsPlaying"), to: GetIsPlaying.self),
      unsafeBitCast(require("MRMediaRemoteGetNowPlayingApplicationPID"), to: GetPID.self),
      unsafeBitCast(require("MRNowPlayingClientCreate"), to: CreateClient.self),
      unsafeBitCast(require("MRMediaRemoteSendCommandToClient"), to: SendCommandToClient.self)
    )
  }
}
