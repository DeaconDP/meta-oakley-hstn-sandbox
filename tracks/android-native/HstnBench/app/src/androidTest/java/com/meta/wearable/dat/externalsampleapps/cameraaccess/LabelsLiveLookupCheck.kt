// LabelsLiveLookupCheck - one manual check of the real Open Food Facts lookup from the phone
//
// Skipped unless run with `-e live_off true`, so the normal suite never touches the network. Looks
// up Nutella (3017620422003) through the app's own OpenFoodFactsSource (HTTPS, the app's
// User-Agent, only the barcode number sent) into a temporary cache, then again to check the second
// answer comes from the phone's cache.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LookupResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.OpenFoodFactsSource
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LabelsLiveLookupCheck {

  @Test
  fun looksUpNutellaOnOpenFoodFacts() = runBlocking {
    assumeTrue(InstrumentationRegistry.getArguments().getString("live_off") == "true")
    val dir = File(ToolTestKit.context.cacheDir, "off_live_check").apply { deleteRecursively() }
    val source = OpenFoodFactsSource(dir)
    val started = System.currentTimeMillis()
    val first = source.lookup("3017620422003")
    val ms = System.currentTimeMillis() - started
    Log.i("LabelReader", "live_off result=$first ms=$ms")
    assertTrue("$first", first is LookupResult.Found && !first.fromCache)
    Log.i("LabelReader", "live_off summary=${(first as LookupResult.Found).product.summary()} allergens=${first.product.allergens}")
    val second = source.lookup("3017620422003")
    assertTrue("$second", second is LookupResult.Found && second.fromCache)
    dir.deleteRecursively()
    Unit
  }
}
