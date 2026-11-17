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
  // The one first-run screen (OnboardingView). Spoken together when it appears; the screen shows
  // the same words.

  static let welcomeIntro = "Hi, I'm SpeakUp. I read printed pages out loud through your glasses."

  /// The core of `disclaimer`, short enough to say on the first screen.
  static let safetyNote = "I can make mistakes, so don't rely on me for medicine doses, money or finding your way."

  /// Voice first: every spoken line leads with what to say. The buttons are on screen for VoiceOver.
  static let welcomeConnect =
    "First, let's connect your glasses. Say connect, and I'll open the Meta AI app. Choose Connect there, then come back."

  /// Replay setup with the glasses already connected.
  static let welcomeAlreadyConnected = "Your glasses are already connected. Say continue to start reading."

  /// After the reason a connection didn't finish (WearablesViewModel says that part).
  static let welcomeRetry = "Your glasses aren't connected yet. Say try again, or not now."

  /// Added to "Connected to …" when connecting finishes setup.
  static let connectedNext = "Hold up a page and say read."

  /// Setup finished without a fresh "Connected to …" line (already connected).
  static let setupConnected = "You're connected. Hold up a page and say read."

  static let setupNotNow = "OK. You can connect your glasses any time. Say connect when you're ready."

  /// Detected after connecting, instead of a speaker test.
  static let soundOnPhoneSpeaker =
    "Sound is coming from the phone speaker. To hear me in your glasses, check they're connected in the phone's Bluetooth settings."

  /// The home screen's line before the Meta AI handoff.
  static let beforeMetaAIHandoff =
    "You'll switch to the Meta AI app to confirm. Choose Connect. When you come back here you'll hear a chime."

  /// The full version, spoken once on the main screen if the first screen's safetyNote wasn't
  /// (see A11yPreferences.disclaimerHeard and CameraNarrator).
  static let disclaimer =
    "Before you start: this app is experimental and can be wrong. It is not a mobility aid, so don't use it to find your way or avoid obstacles. Don't rely on it for medication doses or money."

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
    "Meta AI wants to connect your glasses to this app. Say yes to finish connecting, or not now."

  static let metaAIRegistrationDeclined = "Not connected. You can connect later from this app."

  static let disconnectConfirm = "Disconnect your glasses? Say yes or no."

  static let disconnectKept = "OK, your glasses stay connected."

  static let disconnectNothing = "Your glasses aren't connected to this app, so there's nothing to disconnect."

  // MARK: Alerts by voice

  /// Said after an alert's sentence, so it can be answered without finding its buttons.
  static let alertSayTryAgain = "Say try again, or OK."
  static let alertSayYes = "Say yes, or OK."
  static let alertSayUpdate = "Say update, or not now."
  static let alertSayConnect = "Say try again, or not now."
  static let alertSayOK = "Say OK to close this."

  // MARK: Updates

  static func firmwareUpdateRequired(deviceName: String) -> String {
    "\(deviceName) needs an update. This opens the Meta AI app."
  }

  static let glassesAppUpdateRequired =
    "Meta AI needs to update this app on your glasses. This opens the Meta AI app."

  static func firmwareUpdateNeeded(deviceName: String) -> String {
    "\(deviceName) needs an update to work with this app. Say update to open the Meta AI app."
  }

  static let glassesAppUpdateNeeded =
    "Meta AI needs to update this app on your glasses. Say update to open the Meta AI app."

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

  static let glassesFolded = "Glasses folded. The camera is off."

  static func batteryLow(percent: Int) -> String {
    "Glasses battery \(percent) percent."
  }

  // MARK: Main screen

  static let glassesConnected = "Glasses connected. Ready to read."

  static let glassesNotWorn = "Glasses aren't on. Put them on to start."

  static let glassesFoldedIdle = "Glasses are folded. Unfold them to start."

  static let glassesOn = "Glasses on."

  static let readyToRead = "Ready to read."

  static let cameraEnded = "Camera off."

  static let cameraStarting = "Starting the camera."

  static let waitingForGlasses = "Waiting for the glasses."

  static let stopping = "Stopping."

  static let firmwareUpdateNeeded = "Your glasses need an update. Say update to open the Meta AI app."

  static let cameraOn = "Camera on. Ready to read."

  static let resumed = "Resumed."

  static let paused = "Paused. Tap your glasses to resume."

  // MARK: Camera permission, main screen

  /// Spoken (or shown) before the app sends the user to Meta AI for camera access.
  static let cameraPermissionBeforeRedirect =
    "To use the glasses camera, you'll switch to the Meta AI app to allow it, then come back here. Choose Allow always, otherwise you'll be sent to Meta AI each time."

  /// Spoken after cameraPermissionBeforeRedirect while the prompt is up (the alert shows only that).
  static let cameraPermissionSayYes = "Say yes to go on, or not now."

  /// A read was asked for while the camera prompt is still up.
  static let cameraPermissionWaiting = "Camera access is still waiting for you. Say yes to allow it in Meta AI, or not now."

  static let cameraPermissionGranted = "Camera access allowed."

  static let cameraPermissionNotGranted = "Camera access wasn't allowed. You can try again."

  static let cameraPermissionCancelled = "Camera access not requested. Read again when you're ready."

  static let cameraPermissionOff =
    "Camera permission is off. When you read, you'll be asked to allow it in the Meta AI app."

  static let metaAINotInstalled = "The Meta AI app isn't installed. Install it from the App Store, then try again."

  // MARK: Camera errors

  static let glassesTooHot = "Glasses are too hot, so the camera stopped. Let them cool down, then try again."

  static let glassesBatteryTooLow = "Glasses battery is too low for the camera. Charge them, then try again."

  static let glassesPowerLimit = "Glasses hit their power limit, so the camera stopped. Try again in a moment."

  static let cameraTimedOut = "The glasses didn't respond in time. Try again."

  static let cameraStreamFailed = "The camera feed stopped. Try reading again."

  static let photoFailed = "The photo wasn't taken. Try again."

}
