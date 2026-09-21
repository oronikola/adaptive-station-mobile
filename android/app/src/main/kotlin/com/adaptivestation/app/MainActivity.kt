package com.adaptivestation.app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.adaptivestation.app.BuildConfig

/**
 * Gateway-sender mode's native SMS send — ported from the standalone
 * dual_sim_sms_Android14 (TextBlast) app this replaces. Ordinary parent-mode
 * usage never touches this channel.
 *
 * Uses divideMessage()/sendMultipartTextMessage() rather than the simpler
 * single-segment sendTextMessage() — a message that doesn't fit in one SMS
 * (over 160 GSM-7 characters, or over just 70 once any non-GSM-7 character —
 * an accented letter, a curly quote — forces UCS-2 encoding) is not
 * guaranteed to fail loudly with sendTextMessage(): behavior is
 * OEM/Android-version dependent and has been observed to silently truncate
 * or drop the message while still reporting RESULT_OK. divideMessage()
 * always splits correctly for the message's actual encoding, so this holds
 * for every current and future SMS template regardless of name/message
 * length, not just the ones a template author remembered to length-cap by
 * hand (contrast the credential-lookup SMS, which is hand-capped to 160
 * chars instead — see ParentCredentialLookupController's
 * formatCredentialsSmsMessage()). Divides identically for a message that
 * only needs one part, so this is a strict superset of the old behavior, not
 * a special multi-part-only path.
 *
 * Two independent signals come back from Android for a send: the immediate
 * sentIntent(s) (radio accepted/rejected the send — this is what the
 * MethodChannel result answers) and, much later and independently of it,
 * deliveredIntent(s) carrying the carrier's delivery report (not every
 * carrier sends one). A multi-part message gets one of each per part, so
 * [PendingMultipartSend] aggregates them back into the single sent/delivered
 * outcome the rest of this app's contract (one MethodChannel result, one
 * delivery event per message) already expects. Delivery can't reuse the
 * request/response MethodChannel.Result pattern sentIntent uses, since it
 * arrives after that call has already returned — it's pushed to Dart via a
 * separate EventChannel instead, tagged with the real sms_outbox message id
 * so Dart never has to maintain its own id-correlation map.
 */
class MainActivity : FlutterActivity() {
    private val CHANNEL = "adaptivestation.sms/channel"
    private val DELIVERY_EVENT_CHANNEL = "adaptivestation.sms/delivery"
    private val ACTION_SMS_SENT = "com.adaptivestation.app.SMS_SENT"
    private val ACTION_SMS_DELIVERED = "com.adaptivestation.app.SMS_DELIVERED"
    private val EXTRA_MESSAGE_ID = "messageId"
    private val EXTRA_PART_INDEX = "partIndex"

    private val resultCallbacks = mutableMapOf<String, MethodChannel.Result>()
    private var deliveryEventSink: EventChannel.EventSink? = null

    /**
     * One multipart message's in-flight bookkeeping, keyed by messageId.
     * `sent` is removed from tracking (via [PendingMultipartSend.sentDone])
     * the moment every part's sentIntent has reported, which resolves the
     * MethodChannel result — that always happens, since Android always fires
     * a sentIntent per part. `delivered` tracking is separate and can
     * legitimately never complete if the carrier never sends a delivery
     * report at all (common) — the entry is still removed once complete, but
     * an entry for a carrier that never reports lives until this Activity is
     * recreated. Bounded in practice: most messages are a single part, and a
     * multi-part one is rare (a long name/message), so this is a small,
     * short-lived amount of state, not an unbounded accumulation.
     */
    private data class PendingMultipartSend(val totalParts: Int) {
        var sentReports = 0
        var sentFailed = false
        var sentFailureResultCode = Activity.RESULT_OK
        var sentFailureIntent: Intent? = null

        var deliveredReports = 0
        var anyNotDelivered = false

        fun sentDone() = sentReports >= totalParts
        fun deliveredDone() = deliveredReports >= totalParts
    }

    private val pendingSends = mutableMapOf<String, PendingMultipartSend>()

    private val smsSentReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val messageId = intent?.getStringExtra(EXTRA_MESSAGE_ID) ?: return
            val state = pendingSends[messageId] ?: return

            state.sentReports++
            if (resultCode != Activity.RESULT_OK && !state.sentFailed) {
                // First failing part wins the reported reason — later parts
                // (whether they succeed or fail differently) don't overwrite
                // it, since the overall send is already a failure either way.
                state.sentFailed = true
                state.sentFailureResultCode = resultCode
                state.sentFailureIntent = intent
            }

            if (!state.sentDone()) return

            val callback = resultCallbacks.remove(messageId) ?: return
            val resultMessage = if (state.sentFailed) {
                smsResultMessage(state.sentFailureResultCode, state.sentFailureIntent)
            } else {
                "sent"
            }
            callback.success(resultMessage)

            // Only the sent-side bookkeeping is done — deliveredReports on
            // this same entry keeps accumulating independently below.
            if (state.deliveredDone()) pendingSends.remove(messageId)
        }
    }

    /**
     * Turns Android's SMS result into an operator-actionable failure reason.
     * `errorCode` is carrier/modem specific, so the fleet log keeps it as a
     * diagnostic rather than pretending it always means a particular issue
     * such as insufficient load. Android only adds `noDefault` to a generic
     * failure when it could not select a SIM subscription.
     */
    private fun smsResultMessage(resultCode: Int, intent: Intent?): String {
        if (resultCode == Activity.RESULT_OK) {
            return "sent"
        }

        return when (resultCode) {
            SmsManager.RESULT_ERROR_GENERIC_FAILURE -> {
                val hasNoDefaultSim = intent?.getBooleanExtra("noDefault", false) == true
                val carrierErrorCode = intent?.getIntExtra("errorCode", 0) ?: 0

                when {
                    hasNoDefaultSim -> "error: no default SIM selected"
                    carrierErrorCode != 0 -> "error: carrier rejected SMS (code $carrierErrorCode)"
                    else -> "error: carrier rejected SMS (no carrier detail)"
                }
            }
            SmsManager.RESULT_ERROR_NO_SERVICE -> "error: no mobile service"
            SmsManager.RESULT_ERROR_NULL_PDU -> "error: SMS message data is missing"
            SmsManager.RESULT_ERROR_RADIO_OFF -> "error: SIM radio is turned off"
            SmsManager.RESULT_ERROR_LIMIT_EXCEEDED -> "error: SMS sending limit reached"
            SmsManager.RESULT_ERROR_FDN_CHECK_FAILURE -> "error: SIM fixed-dialing restriction"
            else -> "error: SMS send failed (Android code $resultCode)"
        }
    }

    private val smsDeliveredReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val messageId = intent?.getStringExtra(EXTRA_MESSAGE_ID) ?: return
            val state = pendingSends[messageId] ?: return

            state.deliveredReports++
            if (resultCode != Activity.RESULT_OK) {
                state.anyNotDelivered = true
            }

            if (!state.deliveredDone()) return

            deliveryEventSink?.success(
                mapOf("messageId" to messageId, "delivered" to !state.anyNotDelivered),
            )

            if (state.sentDone()) pendingSends.remove(messageId)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "sendSMS") {
                    val phoneNumber = call.argument<String>("phoneNumber")
                    val message = call.argument<String>("message")
                    val subscriptionId = call.argument<Int>("subscriptionId")
                    val messageId = call.argument<String>("messageId")

                    if (phoneNumber != null && message != null && subscriptionId != null && messageId != null) {
                        resultCallbacks[messageId] = result
                        sendSms(phoneNumber, message, subscriptionId, messageId)
                    } else {
                        result.error("INVALID_PARAMETERS", "Missing parameters", null)
                    }
                } else if (call.method == "getFlavor") {
                    // Read straight from Gradle's own BuildConfig rather than a
                    // --dart-define — a flag passed separately from --flavor
                    // could be forgotten or mismatched; this can't drift.
                    result.success(BuildConfig.FLAVOR)
                } else {
                    result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DELIVERY_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    deliveryEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    deliveryEventSink = null
                }
            })

        // Same-process custom actions only, never sent by another app —
        // NOT_EXPORTED is correct here (the reference project used
        // EXPORTED, which isn't needed for a purely internal broadcast).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(smsSentReceiver, IntentFilter(ACTION_SMS_SENT), Context.RECEIVER_NOT_EXPORTED)
            registerReceiver(smsDeliveredReceiver, IntentFilter(ACTION_SMS_DELIVERED), Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(smsSentReceiver, IntentFilter(ACTION_SMS_SENT))
            registerReceiver(smsDeliveredReceiver, IntentFilter(ACTION_SMS_DELIVERED))
        }
    }

    /**
     * divideMessage() correctly splits for the message's actual encoding
     * (GSM-7 vs UCS-2) — see the class docblock for why this replaces the
     * old single-segment sendTextMessage() call. Returns a 1-element list
     * for anything that already fits in one segment, so this is the only
     * send path now; there is no separate single-part case to maintain.
     *
     * A negative [subscriptionId] means "send the way the phone's own
     * Messages app does" — through whichever subscription the OS has set as
     * the default for SMS, rather than one this app picked itself. That
     * distinction turned out to matter in the field: a message handed to a
     * specific non-default subscription can be accepted by the radio
     * (RESULT_OK, so the app reports "sent") and still never leave the
     * network, while the identical text typed by hand in the Messages app —
     * which always uses the default subscription — arrives every time. See
     * GatewaySenderShell's SIM-mode setting.
     */
    private fun sendSms(phoneNumber: String, message: String, subscriptionId: Int, messageId: String) {
        try {
            val smsManager = if (subscriptionId < 0) {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            } else {
                SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
            }
            val parts = smsManager.divideMessage(message)

            pendingSends[messageId] = PendingMultipartSend(totalParts = parts.size)

            val sentIntents = ArrayList<PendingIntent>(parts.size)
            val deliveredIntents = ArrayList<PendingIntent>(parts.size)

            for (partIndex in parts.indices) {
                sentIntents.add(
                    PendingIntent.getBroadcast(
                        this,
                        // Distinct request code per message AND per part AND
                        // per action — reusing one across any of those would
                        // make Android treat them as the same PendingIntent
                        // (FLAG_UPDATE_CURRENT then just overwrites its
                        // extras), silently losing the ability to tell parts
                        // or the two actions apart.
                        "$messageId:sent:$partIndex".hashCode(),
                        Intent(ACTION_SMS_SENT).apply {
                            putExtra(EXTRA_MESSAGE_ID, messageId)
                            putExtra(EXTRA_PART_INDEX, partIndex)
                            setPackage(packageName)
                        },
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
                deliveredIntents.add(
                    PendingIntent.getBroadcast(
                        this,
                        "$messageId:delivered:$partIndex".hashCode(),
                        Intent(ACTION_SMS_DELIVERED).apply {
                            putExtra(EXTRA_MESSAGE_ID, messageId)
                            putExtra(EXTRA_PART_INDEX, partIndex)
                            setPackage(packageName)
                        },
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }

            smsManager.sendMultipartTextMessage(phoneNumber, null, parts, sentIntents, deliveredIntents)
        } catch (e: Exception) {
            pendingSends.remove(messageId)
            resultCallbacks.remove(messageId)?.success("error: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiver(smsSentReceiver)
        unregisterReceiver(smsDeliveredReceiver)
    }
}
