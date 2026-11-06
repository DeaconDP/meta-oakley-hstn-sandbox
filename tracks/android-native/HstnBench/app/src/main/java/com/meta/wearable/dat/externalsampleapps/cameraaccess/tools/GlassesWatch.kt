// GlassesWatch - live snapshots of the glasses and the phone for HealthMonitor
//
// Glasses: DAT device metadata (link, worn, battery, charging, thermal, compatibility) for every
// linked pair, preferring the one that's connected and worn (as Meta's BirdSpotter sample does).
// Folding the glasses has no signal of its own; it shows up as the link dropping.
// Phone: Bluetooth on/off and battery, from system broadcasts.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.util.Log
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.ChargingState
import com.meta.wearable.dat.core.types.DeviceCompatibility
import com.meta.wearable.dat.core.types.DonState
import com.meta.wearable.dat.core.types.LinkState
import com.meta.wearable.dat.core.types.ThermalLevel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlassesSnapshot
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Heat
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.PhoneSnapshot
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf

class GlassesWatch(context: Context) {

  private val appContext = context.applicationContext

  @OptIn(ExperimentalCoroutinesApi::class)
  fun glasses(): Flow<GlassesSnapshot> =
      Wearables.devices
          .flatMapLatest { ids ->
            val readings = ids.mapNotNull { Wearables.devicesMetadata[it] }
            if (readings.isEmpty()) {
              flowOf(GlassesSnapshot(paired = false, connected = false))
            } else {
              combine(readings) { all ->
                val chosen =
                    all.minByOrNull {
                      when {
                        it.linkState == LinkState.CONNECTED && it.donState == DonState.DONNED -> 0
                        it.linkState == LinkState.CONNECTED -> 1
                        else -> 2
                      }
                    }!!
                GlassesSnapshot(
                    paired = true,
                    connected = chosen.linkState == LinkState.CONNECTED,
                    worn =
                        when (chosen.donState) {
                          DonState.DONNED -> true
                          DonState.DOFFED -> false
                          else -> null
                        },
                    battery = chosen.batteryLevel.takeIf { it in 1..100 },
                    charging =
                        when (chosen.chargingState) {
                          ChargingState.CHARGING -> true
                          ChargingState.NOT_CHARGING -> false
                          else -> null
                        },
                    heat =
                        when (chosen.thermalLevel) {
                          ThermalLevel.NONE,
                          ThermalLevel.LIGHT -> Heat.NORMAL
                          ThermalLevel.MODERATE,
                          ThermalLevel.SEVERE -> Heat.HOT
                          ThermalLevel.CRITICAL,
                          ThermalLevel.EMERGENCY,
                          ThermalLevel.SHUTDOWN -> Heat.TOO_HOT
                          else -> null
                        },
                    updateRequired =
                        chosen.compatibility == DeviceCompatibility.DEVICE_UPDATE_REQUIRED ||
                            chosen.compatibility == DeviceCompatibility.SDK_UPDATE_REQUIRED,
                )
              }
            }
          }
          .distinctUntilChanged()

  fun phone(): Flow<PhoneSnapshot> =
      callbackFlow {
            fun snapshot(battery: Intent?): PhoneSnapshot {
              val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
              val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
              val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
              return PhoneSnapshot(
                  bluetoothOn = bluetoothOn(),
                  battery = if (level >= 0 && scale > 0) level * 100 / scale else null,
                  charging =
                      when (status) {
                        BatteryManager.BATTERY_STATUS_CHARGING,
                        BatteryManager.BATTERY_STATUS_FULL -> true
                        -1 -> null
                        else -> false
                      },
              )
            }
            var lastBattery: Intent? = null
            val receiver =
                object : BroadcastReceiver() {
                  override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action == Intent.ACTION_BATTERY_CHANGED) lastBattery = intent
                    trySend(snapshot(lastBattery))
                  }
                }
            val filter =
                IntentFilter().apply {
                  addAction(Intent.ACTION_BATTERY_CHANGED)
                  addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
                }
            // ACTION_BATTERY_CHANGED is sticky: registering returns the current state.
            lastBattery = appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            trySend(snapshot(lastBattery))
            awaitClose { appContext.unregisterReceiver(receiver) }
          }
          .distinctUntilChanged()

  fun both(): Flow<Pair<GlassesSnapshot, PhoneSnapshot>> =
      combine(glasses(), phone()) { g, p -> g to p }.distinctUntilChanged()

  /**
   * True if Bluetooth is on, or can't matter: no adapter (emulator) or the Mock Device Kit, which
   * doesn't use Bluetooth.
   */
  private fun bluetoothOn(): Boolean {
    if (runCatching { MockDeviceKit.getInstance(appContext).isEnabled }.getOrDefault(false)) {
      return true
    }
    val adapter =
        appContext.getSystemService(BluetoothManager::class.java)?.adapter ?: return true
    return try {
      adapter.isEnabled
    } catch (e: SecurityException) {
      Log.w("BookReader", "can't read Bluetooth state", e)
      true
    }
  }
}
