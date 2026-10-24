package app.pandapay.pandapay

import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import com.shounakmulay.telephony.sms.IncomingSmsReceiver
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
        const val ASSISTANT_CHANNEL = "app.pandapay/assistant"
        const val PHONE_NUMBER_HINT_CHANNEL = "app.pandapay/phone_number_hint"
        const val DEVICE_INFO_CHANNEL = "app.pandapay/device_info"
        const val INSTALL_REFERRER_CHANNEL = "app.pandapay/install_referrer"
        const val LOCATION_NOTIFICATION_CHANNEL = "app.pandapay/location_notification"
        // Pinned geolocator_android 4.6.2 posts its foreground service here.
        const val GEOLOCATOR_NOTIFICATION_ID = 75415
        const val GEOLOCATOR_CHANNEL_ID = "geolocator_channel_01"
        const val INSTALL_REFERRER_PREFS = "pandapay_install_referrer"
        const val INSTALL_REFERRER_CHECKED = "checked"
        const val INVITATION_CODE_KEY = "invitation_code"
        const val REQUEST_CODE = 0x5091 // arbitrary, local to this Activity
        const val PHONE_NUMBER_HINT_REQUEST_CODE = 0x5092
        const val MAX_ICON_PX = 96
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingPhoneHintResult: MethodChannel.Result? = null
    private var assistantChannel: MethodChannel? = null
    private var pendingInstallReferrerResult: MethodChannel.Result? = null
    private var installReferrerClient: InstallReferrerClient? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The initial URI is read by Flutter after the engine is ready. Keep
        // the Android intent as the source of truth so a cold launch and a
        // warm singleTop launch behave consistently.
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.dataString?.let { assistantChannel?.invokeMethod("assistantUri", it) }
    }

    override fun onResume() {
        super.onResume()
        IncomingSmsReceiver.isHostActivityVisible = true
    }

    override fun onPause() {
        IncomingSmsReceiver.isHostActivityVisible = false
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        assistantChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ASSISTANT_CHANNEL)
        assistantChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialAssistantUri" -> result.success(intent?.dataString)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PHONE_NUMBER_HINT_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> requestPhoneNumberHint(result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceInfo" -> result.success(
                        mapOf(
                            "platform" to "android",
                            "model" to listOf(Build.MANUFACTURER, Build.MODEL)
                                .distinct()
                                .joinToString(" ")
                                .trim(),
                            "os_version" to "Android ${Build.VERSION.RELEASE}",
                        ),
                    )
                    else -> result.notImplemented()
                }
            }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INSTALL_REFERRER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "readInvitationCode" -> readInstallReferrerInvitation(result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LOCATION_NOTIFICATION_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "applyBrandIcons" -> brandLocationNotification(result)
                else -> result.notImplemented()
            }
        }
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

    private fun brandLocationNotification(result: MethodChannel.Result) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val handler = Handler(Looper.getMainLooper())

        fun update(attempt: Int) {
            val active = try {
                manager.activeNotifications.firstOrNull {
                    it.id == GEOLOCATOR_NOTIFICATION_ID &&
                        (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            it.notification.channelId == GEOLOCATOR_CHANNEL_ID)
                }
            } catch (error: RuntimeException) {
                android.util.Log.w("PandaPay", "Could not read location notification", error)
                result.success(null)
                return
            }
            if (active == null) {
                if (attempt < 100) {
                    handler.postDelayed({ update(attempt + 1) }, 100)
                } else {
                    result.success(null)
                }
                return
            }

            try {
                // Keep Geolocator's foreground service notification, channel,
                // content intent, and ongoing flags; change only its icons.
                val notification = Notification.Builder.recoverBuilder(this, active.notification)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setLargeIcon(Icon.createWithResource(this, R.drawable.ic_notification_large))
                    .build()
                manager.notify(active.tag, active.id, notification)
            } catch (error: RuntimeException) {
                android.util.Log.w("PandaPay", "Could not brand location notification", error)
            }
            result.success(null)
        }

        update(0)
    }

    /**
     * Reads only PandaPay's invite_code parameter from Google Play. The raw
     * referrer may contain unrelated campaign metadata, so only the validated
     * code is persisted. The Play API is queried once after a successful
     * response; transient service failures remain retryable on next launch.
     */
    private fun readInstallReferrerInvitation(result: MethodChannel.Result) {
        val preferences = getSharedPreferences(INSTALL_REFERRER_PREFS, MODE_PRIVATE)
        if (preferences.getBoolean(INSTALL_REFERRER_CHECKED, false)) {
            result.success(preferences.getString(INVITATION_CODE_KEY, null))
            return
        }
        if (pendingInstallReferrerResult != null) {
            result.error("busy", "Install Referrer lookup is already running", null)
            return
        }

        val client = InstallReferrerClient.newBuilder(this).build()
        installReferrerClient = client
        pendingInstallReferrerResult = result
        try {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    when (responseCode) {
                        InstallReferrerResponse.OK -> {
                            val code = runCatching {
                                invitationCodeFromReferrer(client.installReferrer.installReferrer)
                            }.getOrNull()
                            preferences.edit()
                                .putBoolean(INSTALL_REFERRER_CHECKED, true)
                                .apply {
                                    if (code != null) putString(INVITATION_CODE_KEY, code)
                                }
                                .apply()
                            finishInstallReferrer(code)
                        }
                        InstallReferrerResponse.FEATURE_NOT_SUPPORTED -> {
                            preferences.edit()
                                .putBoolean(INSTALL_REFERRER_CHECKED, true)
                                .apply()
                            finishInstallReferrer(null)
                        }
                        else -> finishInstallReferrer(null)
                    }
                    runCatching { client.endConnection() }
                    installReferrerClient = null
                }

                override fun onInstallReferrerServiceDisconnected() {
                    finishInstallReferrer(null)
                    runCatching { client.endConnection() }
                    installReferrerClient = null
                }
            })
        } catch (_: Exception) {
            finishInstallReferrer(null)
            runCatching { client.endConnection() }
            installReferrerClient = null
        }
    }

    private fun finishInstallReferrer(code: String?) {
        val result = pendingInstallReferrerResult
        pendingInstallReferrerResult = null
        result?.success(code)
    }

    private fun invitationCodeFromReferrer(raw: String): String? {
        val candidates = listOf(raw, Uri.decode(raw)).distinct()
        for (candidate in candidates) {
            val query = if (candidate.startsWith("http://", true) ||
                candidate.startsWith("https://", true)
            ) {
                Uri.parse(candidate).getQueryParameter("invite_code")
            } else {
                Uri.parse("https://play.google.com/?$candidate")
                    .getQueryParameter("invite_code")
            }
            val normalized = query?.trim()?.uppercase() ?: continue
            if (normalized.length in 6..32 &&
                Regex("^[A-Z0-9]+(?:-[A-Z0-9]+)*$").matches(normalized)
            ) return normalized
        }
        return null
    }

    private fun requestPhoneNumberHint(result: MethodChannel.Result) {
        if (pendingPhoneHintResult != null) {
            result.error("busy", "A phone-number chooser is already open", null)
            return
        }

        pendingPhoneHintResult = result
        val request = GetPhoneNumberHintIntentRequest.builder().build()
        Identity.getSignInClient(this)
            .getPhoneNumberHintIntent(request)
            .addOnSuccessListener { pendingIntent ->
                try {
                    startIntentSenderForResult(
                        pendingIntent.intentSender,
                        PHONE_NUMBER_HINT_REQUEST_CODE,
                        null,
                        0,
                        0,
                        0,
                    )
                } catch (_: Exception) {
                    finishPhoneNumberHint(null)
                }
            }
            .addOnFailureListener {
                // No saved number or compatible Play services: the Dart
                // field remains available for normal manual entry.
                finishPhoneNumberHint(null)
            }
    }

    private fun finishPhoneNumberHint(phoneNumber: String?) {
        val result = pendingPhoneHintResult
        pendingPhoneHintResult = null
        result?.success(phoneNumber)
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
        if (requestCode == PHONE_NUMBER_HINT_REQUEST_CODE) {
            if (resultCode != RESULT_OK || data == null) {
                finishPhoneNumberHint(null)
                return
            }
            val phoneNumber = runCatching {
                Identity.getSignInClient(this).getPhoneNumberFromIntent(data)
            }.getOrNull()
            finishPhoneNumberHint(phoneNumber)
            return
        }
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
