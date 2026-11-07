// ReaderHealth - what can go wrong around the reader, turned into things worth saying
//
// A blind reader can't glance at a status icon, so every condition that stops or threatens reading
// has to be spoken, once, when it changes: Bluetooth off, no glasses linked, glasses disconnected or
// back, taken off or put on again, battery running down (glasses and phone), overheating, update
// required. HealthMonitor gets snapshots of the world and returns only the edges: no repeats while a
// condition holds, and battery warnings fire once per threshold until the battery recovers.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

enum class Heat {
  NORMAL,
  /** Getting warm: the glasses may throttle. */
  HOT,
  /** Too hot: they'll stop the camera or shut down. */
  TOO_HOT,
}

data class GlassesSnapshot(
    /** At least one pair is linked to this app via Meta AI. */
    val paired: Boolean,
    /** The pair is connected right now. */
    val connected: Boolean,
    /** null = the glasses don't say. */
    val worn: Boolean? = null,
    /** 1..100, or null if unknown. */
    val battery: Int? = null,
    val charging: Boolean? = null,
    val heat: Heat? = null,
    val updateRequired: Boolean = false,
)

data class PhoneSnapshot(
    val bluetoothOn: Boolean = true,
    val battery: Int? = null,
    val charging: Boolean? = null,
)

sealed interface HealthAlert {
  data object BluetoothOff : HealthAlert

  data object BluetoothOn : HealthAlert

  data object NoGlassesPaired : HealthAlert

  data object GlassesDisconnected : HealthAlert

  data object GlassesConnected : HealthAlert

  data object GlassesRemoved : HealthAlert

  data object GlassesWornAgain : HealthAlert

  data object UpdateRequired : HealthAlert

  data class GlassesBattery(val percent: Int, val level: BatteryLevel) : HealthAlert

  data class PhoneBattery(val percent: Int, val level: BatteryLevel) : HealthAlert

  data object GlassesHot : HealthAlert

  data object GlassesTooHot : HealthAlert

  data object GlassesCooled : HealthAlert
}

enum class BatteryLevel(val threshold: Int) {
  LOW(20),
  VERY_LOW(10),
  CRITICAL(5),
}

class HealthMonitor {

  private var glasses: GlassesSnapshot? = null
  private var phone: PhoneSnapshot? = null
  private var glassesBatteryWarned: BatteryLevel? = null
  private var phoneBatteryWarned: BatteryLevel? = null

  /** Feed the latest state of both; returns what changed, in the order worth saying it. */
  @Synchronized
  fun update(newGlasses: GlassesSnapshot, newPhone: PhoneSnapshot): List<HealthAlert> {
    val out = mutableListOf<HealthAlert>()
    val oldG = glasses
    val oldP = phone

    // Bluetooth first: it explains everything below it.
    if (oldP?.bluetoothOn != newPhone.bluetoothOn) {
      if (!newPhone.bluetoothOn) out += HealthAlert.BluetoothOff
      else if (oldP != null) out += HealthAlert.BluetoothOn
    }

    if (newPhone.bluetoothOn) {
      if (!newGlasses.paired && (oldG == null || oldG.paired || oldP?.bluetoothOn == false)) {
        out += HealthAlert.NoGlassesPaired
      } else if (newGlasses.paired) {
        val wasConnected = oldG?.connected
        if (wasConnected != newGlasses.connected) {
          if (!newGlasses.connected) out += HealthAlert.GlassesDisconnected
          else if (wasConnected == false) out += HealthAlert.GlassesConnected
        }
        if (newGlasses.updateRequired && oldG?.updateRequired != true) {
          out += HealthAlert.UpdateRequired
        }
      }
    }

    if (newGlasses.connected) {
      val wasWorn = if (oldG?.connected == true) oldG.worn else null
      if (wasWorn == true && newGlasses.worn == false) out += HealthAlert.GlassesRemoved
      if (wasWorn == false && newGlasses.worn == true) out += HealthAlert.GlassesWornAgain

      val oldHeat = oldG?.heat ?: Heat.NORMAL
      val heat = newGlasses.heat ?: Heat.NORMAL
      if (heat != oldHeat) {
        out +=
            when (heat) {
              Heat.TOO_HOT -> HealthAlert.GlassesTooHot
              Heat.HOT -> if (oldHeat == Heat.NORMAL) HealthAlert.GlassesHot else HealthAlert.GlassesCooled
              Heat.NORMAL -> HealthAlert.GlassesCooled
            }
      }

      battery(newGlasses.battery, newGlasses.charging, glassesBatteryWarned)?.let { (alert, level) ->
        glassesBatteryWarned = level
        if (alert != null) out += HealthAlert.GlassesBattery(newGlasses.battery!!, alert)
      }
    }

    battery(newPhone.battery, newPhone.charging, phoneBatteryWarned)?.let { (alert, level) ->
      phoneBatteryWarned = level
      if (alert != null) out += HealthAlert.PhoneBattery(newPhone.battery!!, alert)
    }

    glasses = newGlasses
    phone = newPhone
    return out
  }

  /**
   * Returns (alert to say or null, new warned level) when the warned level changes, else null.
   * Charging, or climbing back above a threshold (+3 % hysteresis), re-arms the warnings.
   */
  private fun battery(
      percent: Int?,
      charging: Boolean?,
      warned: BatteryLevel?,
  ): Pair<BatteryLevel?, BatteryLevel?>? {
    if (percent == null || percent <= 0) return null
    if (charging == true) return if (warned != null) null to null else null
    val level = BatteryLevel.entries.lastOrNull { percent <= it.threshold }
    if (level == null) {
      // Above every threshold. Re-arm once clearly above the last warning.
      return if (warned != null && percent > warned.threshold + 3) null to null else null
    }
    if (warned == null || level.ordinal > warned.ordinal) return level to level
    return null
  }
}
