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

/**
 * Gateway-sender mode's native SMS send — ported from the standalone
 * dual_sim_sms_Android14 (TextBlast) app this replaces. Ordinary parent-mode
 * usage never touches this channel.
 *
 * Two independent signals come back from Android for one sendTextMessage()
 * call: the immediate sentIntent (radio accepted/rejected the send — this is
 * what the MethodChannel result answers) and, much later and independently
 * of it, a deliveredIntent carrying the carrier's delivery report (not every
 * carrier sends one). Delivery can't reuse the request/response
 * MethodChannel.Result pattern sentIntent uses, since it arrives after that
 * call has already returned — it's pushed to Dart via a separate
 * EventChannel instead, tagged with the real sms_outbox message id so Dart
 * never has to maintain its own id-correlation map.
 */
class MainActivity : FlutterActivity() {
    private val CHANNEL = "adaptivestation.sms/channel"
    private val DELIVERY_EVENT_CHANNEL = "adaptivestation.sms/delivery"
    private val ACTION_SMS_SENT = "com.adaptivestation.app.SMS_SENT"
    private val ACTION_SMS_DELIVERED = "com.adaptivestation.app.SMS_DELIVERED"

    private val resultCallbacks = mutableMapOf<String, MethodChannel.Result>()
    private var deliveryEventSink: EventChannel.EventSink? = null

    private val smsSentReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val messageId = intent?.getStringExtra("messageId")
            val callback = resultCallbacks.remove(messageId) ?: return

            val resultMessage = when (resultCode) {
                Activity.RESULT_OK -> "sent"
                SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "error: generic failure"
                SmsManager.RESULT_ERROR_NO_SERVICE -> "error: no service"
                SmsManager.RESULT_ERROR_NULL_PDU -> "error: null pdu"
                SmsManager.RESULT_ERROR_RADIO_OFF -> "error: radio off"
                else -> "error: unknown"
            }

            callback.success(resultMessage)
        }
    }

    private val smsDeliveredReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val messageId = intent?.getStringExtra("messageId") ?: return
            val delivered = resultCode == Activity.RESULT_OK

            deliveryEventSink?.success(
                mapOf("messageId" to messageId, "delivered" to delivered),
            )
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

    private fun sendSms(phoneNumber: String, message: String, subscriptionId: Int, messageId: String) {
        try {
            val smsManager = SmsManager.getSmsManagerForSubscriptionId(subscriptionId)

            val sentIntent = PendingIntent.getBroadcast(
                this,
                messageId.hashCode(),
                Intent(ACTION_SMS_SENT).apply {
                    putExtra("messageId", messageId)
                    setPackage(packageName)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // Distinct request code from sentIntent above (same messageId
            // would otherwise collide) — the two actions already differ too,
            // but PendingIntent identity also keys on requestCode.
            val deliveredIntent = PendingIntent.getBroadcast(
                this,
                messageId.hashCode() xor 1,
                Intent(ACTION_SMS_DELIVERED).apply {
                    putExtra("messageId", messageId)
                    setPackage(packageName)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            smsManager.sendTextMessage(phoneNumber, null, message, sentIntent, deliveredIntent)
        } catch (e: Exception) {
            resultCallbacks.remove(messageId)?.success("error: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiver(smsSentReceiver)
        unregisterReceiver(smsDeliveredReceiver)
    }
}
