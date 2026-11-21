package dev.reel.reel

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: String? = null
    private var autoPip = false
    private var aspect = Rational(16, 9)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pending = viewUri(intent)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "reel/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "initial" -> {
                    result.success(pending)
                    pending = null
                }
                "resolve" -> {
                    val uri = Uri.parse(call.arguments as String)
                    result.success(mapOf("path" to resolvePath(uri), "name" to displayName(uri)))
                }
                "autoPip" -> {
                    autoPip = call.argument<Boolean>("on") ?: false
                    aspect = toRational(call.argument<Double>("aspect") ?: (16.0 / 9.0))
                    updatePipParams()
                    result.success(null)
                }
                "pip" -> result.success(enterPip())
                else -> result.notImplemented()
            }
        }
    }

    private fun viewUri(i: Intent?): String? =
        if (i?.action == Intent.ACTION_VIEW) i.data?.toString() else null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        viewUri(intent)?.let { channel?.invokeMethod("open", it) }
    }

    private fun toRational(a: Double): Rational {
        val c = a.coerceIn(0.42, 2.39)
        return Rational((c * 1000).toInt(), 1000)
    }

    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                setPictureInPictureParams(
                    PictureInPictureParams.Builder()
                        .setAspectRatio(aspect)
                        .setAutoEnterEnabled(autoPip)
                        .build()
                )
            } catch (e: Exception) {
            }
        }
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return try {
                enterPictureInPictureMode(
                    PictureInPictureParams.Builder().setAspectRatio(aspect).build()
                )
            } catch (e: Exception) {
                false
            }
        }
        return false
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPip && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S
        ) {
            enterPip()
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pip", isInPictureInPictureMode)
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun resolvePath(uri: Uri): String? {
        try {
            if (uri.scheme == "file") return uri.path
            if (uri.scheme != "content") return null
            if (uri.authority == "com.android.externalstorage.documents" &&
                DocumentsContract.isDocumentUri(this, uri)
            ) {
                val parts = DocumentsContract.getDocumentId(uri).split(":", limit = 2)
                if (parts.size == 2) {
                    val base = if (parts[0].equals("primary", true))
                        Environment.getExternalStorageDirectory().path
                    else "/storage/${parts[0]}"
                    val f = File(base, parts[1])
                    if (f.exists()) return f.path
                }
            }
            try {
                contentResolver.query(uri, arrayOf("_data"), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val i = c.getColumnIndex("_data")
                        if (i >= 0) {
                            val p = c.getString(i)
                            if (p != null && File(p).exists()) return p
                        }
                    }
                }
            } catch (e: Exception) {
            }
            val p = uri.path
            if (p != null) {
                val idx = p.indexOf("/storage/")
                if (idx >= 0) {
                    val f = File(p.substring(idx))
                    if (f.exists()) return f.path
                }
            }
        } catch (e: Exception) {
        }
        return null
    }
}
