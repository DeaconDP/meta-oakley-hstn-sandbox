/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// WearablesViewModel.swift
//
// Primary view model for the CameraAccess app that manages DAT SDK integration.
// Demonstrates how to listen to device availability changes using the DAT SDK's
// device stream functionality and handle permission requests.
//
// HstnBench: every registration outcome is heard as well as seen (notes/a11y-onboarding.md,
// stage 3 and "Recovery messages"): an earcon plus a spoken sentence, a working tick while
// waiting, a timeout and a cancel path so "Connecting…" can't stick, and one action per error.
//

import MWDATCore
import Observation
import SwiftUI

/// The single action an error alert offers, if there is one.
enum WearablesAlertAction: Sendable {
  case retryConnect
  case reconnect
  case openFirmwareUpdate
  case openGlassesAppUpdate

  var title: String {
    switch self {
    case .retryConnect: "Try again"
    case .reconnect: "Reconnect"
    case .openFirmwareUpdate, .openGlassesAppUpdate: "Update in Meta AI"
    }
  }
}

/// A registration request that Meta AI started and handed to this app. Identifiable so a sheet can
/// present it.
struct PendingRegistrationRequest: Identifiable {
  let id = UUID()
  let request: RegistrationRequest
}

/// One failure: a specific title, the sentence that is spoken, the tone before it, and an action.
struct WearablesProblem {
  var title: String
  var message: String
  var earcon: Earcon = .error
  var action: WearablesAlertAction?

  static let cancelled = WearablesProblem(
    title: "Not connected", message: SpokenMessage.registrationCancelled, action: .retryConnect)
  static let timedOut = WearablesProblem(
    title: "Connection timed out", message: SpokenMessage.registrationTimedOut, action: .retryConnect)
  static let unregistered = WearablesProblem(
    title: "Glasses disconnected", message: SpokenMessage.unregistered, earcon: .disconnected, action: .reconnect)
  static let metaAINotInstalled = WearablesProblem(
    title: "Meta AI not installed", message: SpokenMessage.registrationMetaAINotInstalled)
  static let noNetwork = WearablesProblem(
    title: "No internet connection", message: SpokenMessage.registrationNoNetwork, action: .retryConnect)
  static let configurationInvalid = WearablesProblem(
    title: "Can't connect yet", message: SpokenMessage.registrationConfigurationInvalid)
  static let registrationFailed = WearablesProblem(
    title: "Connection didn't start", message: SpokenMessage.registrationFailed, action: .retryConnect)
  static let disconnectFailed = WearablesProblem(
    title: "Couldn't disconnect", message: SpokenMessage.disconnectFailed)
  static let glassesAppUpdate = WearablesProblem(
    title: "Update needed", message: SpokenMessage.glassesAppUpdateNeeded, earcon: .attention,
    action: .openGlassesAppUpdate)
  static let appUpdate = WearablesProblem(
    title: "App update needed", message: SpokenMessage.appUpdateRequired, earcon: .attention)
  static let updateCouldNotOpen = WearablesProblem(
    title: "Couldn't open Meta AI", message: SpokenMessage.updateCouldNotOpen)

  static func firmwareUpdate(deviceName: String) -> WearablesProblem {
    WearablesProblem(
      title: "Update needed", message: SpokenMessage.firmwareUpdateNeeded(deviceName: deviceName),
      earcon: .attention, action: .openFirmwareUpdate)
  }

  static func registration(_ error: RegistrationError) -> WearablesProblem {
    switch error {
    case .metaAINotInstalled: .metaAINotInstalled
    case .networkUnavailable: .noNetwork
    case .configurationInvalid: .configurationInvalid
    default: .registrationFailed
    }
  }

  static func registrationRequest(_ error: RegistrationRequestError) -> WearablesProblem {
    switch error {
    case .metaAINotInstalled: .metaAINotInstalled
    case .networkUnavailable: .noNetwork
    case .configurationInvalid: .configurationInvalid
    default: .registrationFailed
    }
  }
}

@Observable
@MainActor
final class WearablesViewModel {
  var devices: [DeviceIdentifier]
  var registrationState: RegistrationState
  var showError: Bool = false
  var errorTitle: String = ""
  var errorMessage: String = ""
  var errorAction: WearablesAlertAction?
  var requiresFirmwareUpdate: Bool = false

  /// True from the user choosing Connect until success, cancel, failure or timeout. The UI uses
  /// this instead of the SDK's `.registering`, which stays set if the user backs out of Meta AI.
  private(set) var isConnecting = false
  /// The last unsuccessful outcome, shown next to the connect button so it can be read as well as
  /// heard. Cleared when a new attempt starts or registration succeeds.
  private(set) var connectionNotice: String?
  /// A registration Meta AI started, waiting for the user's Continue or Not now.
  var pendingRegistrationRequest: PendingRegistrationRequest?
  /// Appended to the next "Connected to …" line, e.g. onboarding's "Setup finished.". One line
  /// instead of two, so nothing can be spoken out of order or cut between them.
  @ObservationIgnored var connectedFollowUp: String?

  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var deviceStreamTask: Task<Void, Never>?
  @ObservationIgnored private var setupDeviceStreamTask: Task<Void, Never>?
  private let wearables: WearablesInterface
  private var deviceCompatibility: [DeviceIdentifier: Compatibility] = [:]
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]

  // Handoff tracking. Time spent in Meta AI doesn't count towards the timeout: the clock starts
  // (again) each time the app becomes active while a connection is pending.
  @ObservationIgnored private var isAppActive = true
  @ObservationIgnored private var leftAppDuringHandoff = false
  @ObservationIgnored private var callbackReceived = false
  @ObservationIgnored private var returnWatch: Task<Void, Never>?
  @ObservationIgnored private var userRequestedDisconnect = false
  @ObservationIgnored private var ownsWorkingTick = false
  /// The user chose "Not now" on Meta AI's request; the SDK falling back from `.registering`
  /// afterwards is that choice, not a cancelled connection, so no error follows.
  @ObservationIgnored private var userDeclinedRequest = false
  @ObservationIgnored private var updateDeviceName = "Your glasses"

  /// After coming back without a callback URL, how long to wait before calling it cancelled. The
  /// callback normally arrives together with the return, so this only needs to absorb ordering.
  private static let returnGrace: Duration = .seconds(5)
  /// How long a pending connection may sit with the app in front before it is called timed out.
  private static let registrationTimeout: Duration = .seconds(90)

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.registrationState = wearables.registrationState

    // Set up device stream immediately to handle MockDevice events
    setupDeviceStreamTask = Task {
      await setupDeviceStream()
    }

    registrationTask = Task {
      for await registrationState in wearables.registrationStateStream() {
        self.registrationStateChanged(registrationState)
      }
    }
  }

  isolated deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
    setupDeviceStreamTask?.cancel()
    returnWatch?.cancel()
  }

  private func setupDeviceStream() async {
    if let task = deviceStreamTask, !task.isCancelled {
      task.cancel()
    }

    deviceStreamTask = Task {
      for await devices in wearables.devicesStream() {
        self.devices = devices
        // Monitor compatibility for each device
        monitorDeviceCompatibility(devices: devices)
      }
    }
  }

  private func monitorDeviceCompatibility(devices: [DeviceIdentifier]) {
    // Remove listeners for devices that are no longer present
    let deviceSet = Set(devices)
    compatibilityListenerTokens = compatibilityListenerTokens.filter { deviceSet.contains($0.key) }
    deviceCompatibility = deviceCompatibility.filter { deviceSet.contains($0.key) }
    updateFirmwareUpdateRequired()

    // Add listeners for new devices
    for deviceId in devices {
      guard compatibilityListenerTokens[deviceId] == nil else { continue }
      guard let device = wearables.deviceForIdentifier(deviceId) else { continue }
      deviceCompatibility[deviceId] = device.compatibility()
      updateFirmwareUpdateRequired()

      // Capture device name before the closure to avoid Sendable issues
      let deviceName = device.nameOrId()
      if deviceCompatibility[deviceId] == .deviceUpdateRequired { updateDeviceName = deviceName }
      let token = device.addCompatibilityListener { [weak self] compatibility in
        Task { [weak self] in
          await self?.handleCompatibilityChange(
            compatibility,
            deviceId: deviceId,
            deviceName: deviceName
          )
        }
      }
      compatibilityListenerTokens[deviceId] = token
    }
  }

  // MARK: - Registration

  func connectGlasses() {
    // Not the SDK's `.registering`: after a timeout or cancel it may still say registering, and
    // the user must be able to try again.
    guard !isConnecting else { return }
    userDeclinedRequest = false
    beginHandoff()
    Task { @MainActor in
      do throws(RegistrationError) {
        try await wearables.startRegistration()
        // Still here and in front (e.g. Meta AI never opened): start the clock now, so the wait
        // can't be endless. Leaving for Meta AI cancels it; coming back restarts it.
        if isConnecting, isAppActive, !leftAppDuringHandoff { watchForReturn(afterLeaving: false) }
      } catch .alreadyRegistered {
        finishHandoff()
      } catch {
        failHandoff(.registration(error))
      }
    }
  }

  func disconnectGlasses() {
    userRequestedDisconnect = true
    Task { @MainActor in
      do {
        try await wearables.startUnregistration()
      } catch {
        userRequestedDisconnect = false
        present(.disconnectFailed)
      }
    }
  }

  /// Every URL the app is opened with comes here. The SDK returns false for URLs that aren't its
  /// own, so no pre-filtering: Meta AI's own registration requests may not carry the same query
  /// item as callbacks for registrations this app started.
  func handleCallbackURL(_ url: URL) async {
    if isConnecting { callbackReceived = true }
    do {
      _ = try await wearables.handleUrl(url) { [weak self] request in
        Task { @MainActor [weak self] in self?.receiveRegistrationRequest(request) }
      }
    } catch .registrationError {
      // Meta AI sent us back without a registration: most often the user cancelled there.
      if userDeclinedRequest {
        userDeclinedRequest = false
        finishHandoff()
      } else if isConnecting {
        failHandoff(.cancelled)
      } else {
        present(.registrationFailed)
      }
    } catch {
      userRequestedDisconnect = false
      present(.disconnectFailed)
    }
  }

  /// Called from the scene's phase. Leaving for Meta AI pauses the tick and the timeout; coming
  /// back restarts the clock.
  func scenePhaseChanged(_ phase: ScenePhase) {
    isAppActive = phase == .active
    switch phase {
    case .active:
      // Back from Meta AI, or a pending connection that began while the scene wasn't active
      // (e.g. during onOpenURL) and so has no timeout yet.
      if isConnecting, leftAppDuringHandoff || returnWatch == nil {
        let afterLeaving = leftAppDuringHandoff
        leftAppDuringHandoff = false
        watchForReturn(afterLeaving: afterLeaving)
      }
    case .background:
      if isConnecting {
        leftAppDuringHandoff = true
        returnWatch?.cancel()
        returnWatch = nil
      }
    default:
      break
    }
    updateWorkingTick()
  }

  // MARK: Registration requested by Meta AI

  private func receiveRegistrationRequest(_ request: RegistrationRequest) {
    pendingRegistrationRequest = PendingRegistrationRequest(request: request)
    Announcer.shared.announce(SpokenMessage.metaAIRegistrationRequest, earcon: .attention)
  }

  func continueRegistrationRequest() {
    guard let pending = pendingRegistrationRequest else { return }
    pendingRegistrationRequest = nil
    userDeclinedRequest = false
    beginHandoff()
    Task { @MainActor in
      do throws(RegistrationRequestError) {
        try await pending.request.continueRegistration()
        if isConnecting, isAppActive, !leftAppDuringHandoff { watchForReturn(afterLeaving: false) }
      } catch {
        failHandoff(.registrationRequest(error))
      }
    }
  }

  func declineRegistrationRequest() {
    guard let pending = pendingRegistrationRequest else { return }
    pendingRegistrationRequest = nil
    userDeclinedRequest = true
    finishHandoff()
    Announcer.shared.say(SpokenMessage.metaAIRegistrationDeclined)
    // Meta AI only needs the answer; if sending it fails the request lapses, which is also a no.
    Task { try? await pending.request.cancelRegistration() }
  }

  // MARK: Handoff bookkeeping

  private func registrationStateChanged(_ state: RegistrationState) {
    let previous = registrationState
    registrationState = state
    guard state != previous else { return }
    switch state {
    case .registered:
      finishHandoff()
      connectionNotice = nil
      userRequestedDisconnect = false
      userDeclinedRequest = false
      // The "chime" SpokenMessage.beforeMetaAIHandoff promises.
      var line = SpokenMessage.connected(deviceName: connectedDeviceName)
      if let followUp = connectedFollowUp { line += " \(followUp)" }
      connectedFollowUp = nil
      Announcer.shared.announce(line, earcon: .connected)
    case .registering:
      // Also covers a registration that Meta AI carried on by itself. Nothing else arms the
      // timeout in that case, so do it here (or on becoming active, see scenePhaseChanged).
      if !isConnecting, !userDeclinedRequest {
        beginHandoff()
        if isAppActive { watchForReturn(afterLeaving: false) }
      }
    case .available, .unavailable:
      if previous == .registered {
        if userRequestedDisconnect {
          userRequestedDisconnect = false
          Announcer.shared.announce(SpokenMessage.disconnectedByUser, earcon: .disconnected)
        } else {
          // Unregistered in Meta AI, or another app took the single Developer Mode slot.
          present(.unregistered)
        }
      } else if previous == .registering, userDeclinedRequest {
        userDeclinedRequest = false
        finishHandoff()
      } else if previous == .registering, isConnecting, isAppActive {
        failHandoff(.cancelled)
      }
    @unknown default:
      break
    }
  }

  private var connectedDeviceName: String {
    devices.first.flatMap { wearables.deviceForIdentifier($0)?.nameOrId() } ?? "your glasses"
  }

  private func beginHandoff() {
    isConnecting = true
    connectionNotice = nil
    callbackReceived = false
    leftAppDuringHandoff = false
    returnWatch?.cancel()
    returnWatch = nil
    updateWorkingTick()
  }

  private func finishHandoff() {
    isConnecting = false
    callbackReceived = false
    leftAppDuringHandoff = false
    returnWatch?.cancel()
    returnWatch = nil
    updateWorkingTick()
  }

  private func failHandoff(_ problem: WearablesProblem) {
    guard isConnecting else { return }
    finishHandoff()
    connectionNotice = problem.message
    present(problem)
  }

  /// Back in the app with a connection pending. Without a callback URL the user came back on
  /// their own, which means it wasn't finished; with one, the SDK gets the full timeout to settle.
  private func watchForReturn(afterLeaving: Bool) {
    returnWatch?.cancel()
    returnWatch = Task { @MainActor [weak self] in
      var waited: Duration = .zero
      if afterLeaving {
        try? await Task.sleep(for: Self.returnGrace)
        waited = Self.returnGrace
        guard let self, !Task.isCancelled, self.isConnecting else { return }
        if !self.callbackReceived {
          self.failHandoff(.cancelled)
          return
        }
      }
      try? await Task.sleep(for: Self.registrationTimeout - waited)
      guard let self, !Task.isCancelled else { return }
      self.failHandoff(.timedOut)
    }
  }

  /// Ticks only while waiting in front of the user; a tick playing over Meta AI would be confusing.
  private func updateWorkingTick() {
    let shouldTick = isConnecting && isAppActive
    if shouldTick, !ownsWorkingTick {
      ownsWorkingTick = true
      EarconPlayer.shared.startWorkingTick(owner: "registration")
    } else if !shouldTick, ownsWorkingTick {
      ownsWorkingTick = false
      EarconPlayer.shared.stopWorkingTick(owner: "registration")
    }
  }

  // MARK: - Updates

  func openFirmwareUpdate() async {
    await speakBeforeLeaving(SpokenMessage.firmwareUpdateRequired(deviceName: updateDeviceName))
    do {
      try await wearables.openFirmwareUpdate()
    } catch {
      present(navigationProblem(error))
    }
  }

  func openDATGlassesAppUpdate() async {
    await speakBeforeLeaving(SpokenMessage.glassesAppUpdateRequired)
    do {
      try await wearables.openDATGlassesAppUpdate()
    } catch {
      present(navigationProblem(error))
    }
  }

  /// For the camera screen: a session failed with `datAppOnTheGlassesUpdateRequired`. Shows the
  /// update alert with its one action instead of the generic session error.
  func presentGlassesAppUpdateRequired() {
    present(.glassesAppUpdate)
  }

  private func navigationProblem(_ error: NavigationError) -> WearablesProblem {
    switch error {
    case .notRegistered: .unregistered
    default: .updateCouldNotOpen
    }
  }

  /// Says where the user is about to go and waits until it has been said (or cut): leaving the
  /// app would otherwise cut the sentence off. Announcer always calls onFinish, VoiceOver lines
  /// included, so this can't hang.
  private func speakBeforeLeaving(_ text: String) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      Announcer.shared.announce(text, earcon: .attention) { _ in continuation.resume() }
    }
  }

  // MARK: - Errors

  /// Shows the alert and makes it heard. With VoiceOver running, VoiceOver reads the alert
  /// itself, so only the tone plays; speaking too would have two voices say the same sentence.
  func present(_ problem: WearablesProblem) {
    errorTitle = problem.title
    errorMessage = problem.message
    errorAction = problem.action
    showError = true
    if UIAccessibility.isVoiceOverRunning {
      EarconPlayer.shared.play(problem.earcon)
    } else {
      Announcer.shared.announce(problem.message, earcon: problem.earcon)
    }
  }

  /// Kept for callers that only have a message.
  func showError(_ error: String) {
    present(WearablesProblem(title: "Glasses problem", message: error))
  }

  func performErrorAction() {
    let action = errorAction
    dismissError()
    switch action {
    case .retryConnect, .reconnect:
      connectGlasses()
    case .openFirmwareUpdate:
      Task { await openFirmwareUpdate() }
    case .openGlassesAppUpdate:
      Task { await openDATGlassesAppUpdate() }
    case nil:
      break
    }
  }

  func dismissError() {
    showError = false
  }

  private func updateFirmwareUpdateRequired() {
    requiresFirmwareUpdate = deviceCompatibility.values.contains(.deviceUpdateRequired)
  }

  private func handleCompatibilityChange(
    _ compatibility: Compatibility,
    deviceId: DeviceIdentifier,
    deviceName: String
  ) {
    let previous = deviceCompatibility[deviceId]
    deviceCompatibility[deviceId] = compatibility
    updateFirmwareUpdateRequired()
    guard compatibility != previous else { return }
    switch compatibility {
    case .deviceUpdateRequired:
      updateDeviceName = deviceName
      present(.firmwareUpdate(deviceName: deviceName))
    case .sdkUpdateRequired:
      present(.appUpdate)
    default:
      break
    }
  }
}
