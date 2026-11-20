// GlassesLink - the glasses-only half of the camera seam (DAT types live here, not in PageCamera)
//
// CameraViewModel implements both PageCamera (frames, stills, motion) and this. ToolHub uses it to
// bring the glasses up without dialogs, to attach on-glasses speech recognition and the display
// card to the session, and for "disconnect". The phone camera has no GlassesLink.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import kotlinx.coroutines.flow.Flow

interface GlassesLink {
  /** The running DAT session, or null. Voice and the display card attach to it. */
  val deviceSession: DeviceSession?

  /** Every compressed frame's size while streaming. Hot; frames are dropped if not collected. */
  val frameSizes: Flow<StreamFrameSize>

  /**
   * Starts the session if needed, then the stream, with no confirmation dialogs: a blind user
   * launching straight into a tool can't see them. If camera access isn't granted yet,
   * [requestPermission] is called (it opens the Meta AI app).
   */
  fun connectAndStream(requestPermission: suspend (Permission) -> PermissionStatus)

  /** Ends the glasses session ("disconnect", or switching to the phone). The app stays registered. */
  fun endSession()
}
