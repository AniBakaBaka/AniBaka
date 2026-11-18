package ani.baka

import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: AudioServiceActivity() {
    companion object {
        private const val CHANNEL = "baka/platform"
        private const val FEATURE_FIRE_TV = "amazon.hardware.fire_tv"
        private const val FEATURE_LEANBACK_ONLY = "android.software.leanback_only"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isTV" -> result.success(isTelevisionDevice())
                else -> result.notImplemented()
            }
        }
    }

    private fun isTelevisionDevice(): Boolean {
        val packageManager = packageManager
        val configurationMode =
            resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK
        val managerMode = (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)
            ?.currentModeType

        if (
            configurationMode == Configuration.UI_MODE_TYPE_TELEVISION ||
            managerMode == Configuration.UI_MODE_TYPE_TELEVISION
        ) {
            return true
        }

        if (
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION) ||
            packageManager.hasSystemFeature(FEATURE_LEANBACK_ONLY) ||
            packageManager.hasSystemFeature(FEATURE_FIRE_TV)
        ) {
            return true
        }

        // Some uncertified TV boxes omit the standard TV feature flags, but still
        // expose a Leanback launcher and have no touchscreen.
        return !packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) &&
            hasLeanbackLauncher(packageManager)
    }

    @Suppress("DEPRECATION")
    private fun hasLeanbackLauncher(packageManager: PackageManager): Boolean {
        val leanbackIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER)
        }
        return packageManager.resolveActivity(
            leanbackIntent,
            PackageManager.MATCH_DEFAULT_ONLY
        ) != null
    }
}
