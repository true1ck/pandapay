package app.pandapay.pandapay

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Hosts the `app.pandapay/upi` MethodChannel used by
 * `lib/data/upi_payment_service.dart` for scan-to-pay: enumerate the UPI
 * apps actually installed, and hand a `upi://pay` intent to the one the
 * user picked, reading back the NPCI transaction status.
 *
 * Implemented directly on the Activity rather than as a FlutterPlugin
 * because it needs `startActivityForResult` / `onActivityResult` and there
 * is exactly one consumer — a plugin's `ActivityAware` plumbing would be
 * ceremony with no benefit here.
 */
class MainActivity : FlutterFragmentActivity() {

    private companion object {
        const val CHANNEL = "app.pandapay/upi"
        const val REQUEST_CODE = 0x5091 // arbitrary, local to this Activity
        const val MAX_ICON_PX = 96
    }

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledUpiApps" -> result.success(installedUpiApps())
                "pay" -> {
                    val uri = call.argument<String>("uri")
                    val pkg = call.argument<String>("packageName")
                    if (uri == null || pkg == null) {
                        result.error("bad_args", "uri and packageName are required", null)
                    } else {
                        startPayment(uri, pkg, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun upiViewIntent(): Intent = Intent(Intent.ACTION_VIEW, Uri.parse("upi://pay"))

    private fun installedUpiApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val resolved = pm.queryIntentActivities(upiViewIntent(), 0)
        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, Any?>>()
        for (info in resolved) {
            val pkg = info.activityInfo?.packageName ?: continue
            if (!seen.add(pkg)) continue
            apps.add(
                mapOf(
                    "packageName" to pkg,
                    "name" to info.loadLabel(pm).toString(),
                    "icon" to runCatching { drawableToPng(info.loadIcon(pm)) }.getOrNull(),
                ),
            )
        }
        return apps
    }

    private fun startPayment(uri: String, packageName: String, result: MethodChannel.Result) {
        // A leftover pendingResult means the previous attempt's Activity
        // result never arrived (Activity was recreated / user never returned).
        // Close it out as "submitted" rather than refusing this new attempt.
        pendingResult?.let { runCatching { it.success(mapOf("status" to "submitted", "response" to null)) } }
        pendingResult = null
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri)).setPackage(packageName)
        if (intent.resolveActivity(packageManager) == null) {
            result.error("not_installed", "$packageName can't handle this UPI intent", null)
            return
        }
        pendingResult = result
        try {
            startActivityForResult(intent, REQUEST_CODE)
        } catch (e: Exception) {
            pendingResult = null
            result.error("launch_failed", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingResult
        pendingResult = null
        if (result == null) return

        val response = data?.getStringExtra("response") ?: data?.getStringExtra("Response")
        val fields = parseUpiResponse(response)
        val status = when (fields["status"]?.lowercase()) {
            "success" -> "success"
            "failure", "failed" -> "failure"
            "submitted" -> "submitted"
            else -> if (response == null && resultCode == RESULT_CANCELED) "cancelled" else "submitted"
        }
        result.success(
            mapOf(
                "status" to status,
                "response" to response,
                "approvalRefNo" to (fields["approvalrefno"] ?: fields["approvalref"]),
            ),
        )
    }

    private fun parseUpiResponse(response: String?): Map<String, String> {
        if (response.isNullOrBlank()) return emptyMap()
        return response.split('&').mapNotNull {
            val i = it.indexOf('=')
            if (i <= 0) null else it.substring(0, i).trim().lowercase() to it.substring(i + 1).trim()
        }.toMap()
    }

    private fun drawableToPng(drawable: Drawable): ByteArray {
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            drawable.bitmap
        } else {
            val w = drawable.intrinsicWidth.coerceIn(1, MAX_ICON_PX)
            val h = drawable.intrinsicHeight.coerceIn(1, MAX_ICON_PX)
            Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also { bmp ->
                val canvas = Canvas(bmp)
                drawable.setBounds(0, 0, canvas.width, canvas.height)
                drawable.draw(canvas)
            }
        }
        val scaled = if (bitmap.width > MAX_ICON_PX || bitmap.height > MAX_ICON_PX) {
            Bitmap.createScaledBitmap(bitmap, MAX_ICON_PX, MAX_ICON_PX, true)
        } else {
            bitmap
        }
        return ByteArrayOutputStream().use { out ->
            scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        }
    }
}
