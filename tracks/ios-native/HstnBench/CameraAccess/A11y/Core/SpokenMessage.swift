/*
 * SpokenMessage - the sentences the app speaks, in one place
 *
 * Kept together so wording stays consistent across onboarding, the main screen and Siri, and so
 * it can be reviewed with BLV testers as one list. Rules (notes/a11y-onboarding.md): lead with
 * what happened, then one next step; short; no "something went wrong" without a cause.
 * Meta AI button names ("Connect") are from the notes and still need checking on the real app.
 */

enum SpokenMessage {
  // MARK: Onboarding

  static let welcome =
    "Welcome. This app works with your Oakley Meta glasses and talks to you through them. Do you want a guided setup, or skip to the app?"

  static let beforeMetaAIHandoff =
    "You'll switch to the Meta AI app to confirm. Choose Connect. When you come back here you'll hear a chime."

  static let speakerTestQuestion = "Did you hear that in the glasses?"

  /// Spoken once, during onboarding (see A11yPreferences.disclaimerHeard).
  static let disclaimer =
    "Before you start: this app is experimental and can be wrong. It is not a mobility aid, so don't use it to find your way or avoid obstacles. Don't rely on it for medication doses or money."

  static let privacy =
    "Photos are processed on your phone. Nothing leaves the phone unless you ask. The app doesn't identify faces."

  // MARK: Registration

  static func connected(deviceName: String) -> String {
    "Connected to \(deviceName)."
  }

  static let registrationCancelled = "Connection wasn't finished in Meta AI. You can try again."

  static let registrationTimedOut = "Meta AI didn't finish connecting in time. You can try again."

  static let unregistered = "This app is no longer connected to your glasses. You can reconnect."

  static let disconnectedByUser = "Disconnected from your glasses."

  static let openingMetaAI = "Opening Meta AI."

  /// Registration variant: before registering, the glasses also have to be paired in Meta AI.
  static let registrationMetaAINotInstalled =
    "The Meta AI app isn't installed. Install it from the App Store and pair your glasses there, then try again."

  static let registrationNoNetwork = "No internet connection. Connect to the internet, then try again."

  static let registrationConfigurationInvalid =
    "This app can't connect yet. In the Meta AI app, check that Developer Mode is on for your glasses."

  static let registrationFailed = "Connecting didn't start. You can try again."

  static let disconnectFailed = "Couldn't disconnect. You can try again."

  /// Meta AI started registration itself and handed it to us (handleUrl(_:onRegistrationRequest:)).
  static let metaAIRegistrationRequest =
    "Meta AI wants to connect your glasses to this app. Choose Continue to go back to Meta AI and finish, or Not now."

  static let metaAIRegistrationDeclined = "Not connected. You can connect later from this app."

  // MARK: Onboarding steps
  // Each step's key line, spoken when the step appears. The on-screen text says the same.

  static let resumingSetup = "Continuing setup where you left off."

  static let setupSkipped = "Setup skipped. You can replay it later."

  static let learnSoundsIntro =
    "Learn the sounds. Each item plays a sound and says what it means. Choose Continue when you're done."

  static let speakerTestPhrase = "This is the speaker test. If you can hear me, the sound is working."

  static func speakerTestIntro(output: String) -> String {
    "Speaker test. Sound is going to the \(output). Listen for a tone and a short sentence."
  }

  static let speakerTestFixes =
    "Try these: wear the glasses with the arms unfolded. In the phone's Bluetooth settings, check the glasses are connected. Turn the volume up with the phone's side buttons. Then choose Replay, or continue anyway."

  static let verbosityIntro =
    "How much detail? Hear the same sample answer at each level, then choose one."

  static func verbositySample(_ verbosity: Verbosity) -> String {
    switch verbosity {
    case .short: "A can of tomato soup."
    case .normal: "A can of tomato soup, 400 grams. Best before March 2027."
    case .detailed:
      "A can of tomato soup, 400 grams. Best before March 2027. The label is red and white, and the text is clear. Heat it on the stove or in the microwave."
    }
  }

  static func verbosityChosen(_ verbosity: Verbosity) -> String {
    "\(verbosity.title) chosen."
  }

  static let speechRateFollowsVoiceOver =
    "Speech uses your VoiceOver speaking rate. Change it in VoiceOver settings."

  static let disclaimerAgain = "Safety and privacy. The text is on screen. Choose Hear again to listen."

  static let connectAlreadyRegistered = "Your glasses are already connected to this app. Choose Finish setup."

  static let setupFinished = "Setup finished."

  // MARK: Updates

  static func firmwareUpdateRequired(deviceName: String) -> String {
    "\(deviceName) needs an update. This opens the Meta AI app."
  }

  static let glassesAppUpdateRequired =
    "Meta AI needs to update this app on your glasses. This opens the Meta AI app."

  static func firmwareUpdateNeeded(deviceName: String) -> String {
    "\(deviceName) needs an update to work with this app. Update opens the Meta AI app."
  }

  static let glassesAppUpdateNeeded =
    "Meta AI needs to update this app on your glasses. Update opens the Meta AI app."

  /// Compatibility.sdkUpdateRequired: the toolkit inside this app is too old for the glasses.
  static let appUpdateRequired = "This app needs an update to work with your glasses."

  static let updateCouldNotOpen = "Couldn't open Meta AI. Check that it's installed, then try again."

  // MARK: Camera permission

  static let cameraPermissionNeeded =
    "The app needs to use the glasses camera. You'll switch to the Meta AI app to allow it. Choosing Allow always means you won't be sent there each time."

  static let cameraPermissionDenied = "Camera access needs to be allowed again. This opens the Meta AI app."

  // MARK: Device state

  static let ready = "Ready."

  static let glassesNotConnected = "Glasses aren't connected. Check Bluetooth."

  static let glassesRemoved = "Glasses removed, paused."

  static let glassesFolded = "Glasses folded, session ended."

  static func batteryLow(percent: Int) -> String {
    "Glasses battery \(percent) percent."
  }

  // MARK: Camera screen

  static let glassesConnected = "Glasses connected. Start a session to use the camera."

  static let glassesNotWorn = "Glasses aren't on. Put them on to start."

  static let glassesFoldedIdle = "Glasses are folded. Unfold them to start."

  static let glassesOn = "Glasses on."

  static let sessionStarting = "Starting session."

  static let sessionStarted = "Session started. Start the preview to use the camera."

  static let sessionEnded = "Session ended."

  static let readyToStartSession = "Ready. Start a session to use the camera."

  static let readyToStartPreview = "Ready. Start the preview to use the camera."

  static let cameraStarting = "Starting the camera."

  static let waitingForGlasses = "Waiting for the glasses."

  static let stopping = "Stopping."

  static let firmwareUpdateNeeded = "Your glasses need an update. Use Update firmware to open the Meta AI app."

  static let cameraOn = "Camera on. Ready to take a photo."

  static let cameraOff = "Preview off."

  static let resumed = "Resumed."

  static let paused = "Paused. Tap your glasses to resume."

  static let photoInProgress = "Still taking the last photo."

  static let recordingStarted = "Recording."

  static let recordingStopped = "Recording stopped."

  static func recording(elapsed: String) -> String {
    "Recording, \(elapsed)."
  }

  static let recordingNoSound = "The glasses microphone isn't available. Recording video without sound."

  static let videoReady = "Video ready. Share it, or close to go back."

  static let recordingSaved = "Recording stopped. Video ready. Share it, or close to go back."

  static let backToCamera = "Back to camera."

  // MARK: Camera permission, main screen

  /// Spoken (or shown) before the app sends the user to Meta AI for camera access.
  static let cameraPermissionBeforeRedirect =
    "To use the glasses camera, you'll switch to the Meta AI app to allow it, then come back here. Choose Allow always, otherwise you'll be sent to Meta AI every session."

  static let cameraPermissionGranted = "Camera access allowed. Starting the camera."

  static let cameraPermissionNotGranted = "Camera access wasn't allowed. You can try again."

  static let cameraPermissionCancelled = "Camera access not requested. Start the preview when you're ready."

  static let cameraPermissionOff =
    "Camera permission is off. When you start the preview, you'll be asked to allow it in the Meta AI app."

  static let metaAINotInstalled = "The Meta AI app isn't installed. Install it from the App Store, then try again."

  // MARK: Camera errors

  static let sessionFailed = "The session couldn't start. Make sure your glasses are on and connected, then try again."

  static let glassesTooHot = "Glasses are too hot, so the camera stopped. Let them cool down, then start again."

  static let glassesBatteryTooLow = "Glasses battery is too low for the camera. Charge them, then start again."

  static let glassesPowerLimit = "Glasses hit their power limit, so the camera stopped. Start again in a moment."

  static let cameraTimedOut = "The glasses didn't respond in time. Try again."

  static let cameraStreamFailed = "The camera feed stopped. Start the preview again."

  static let photoFailed = "The photo wasn't taken. Try again."

  static let startSessionFirst = "Start a session before the preview."

  static let recordingNotStarted = "Recording didn't start. Try again."

  static let recordingNotSaved = "The recording couldn't be saved. Try again."
}
