package com.vdc.video_downloader_converter

import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    @Volatile private var engineReady = false
    private var engineError: String? = null
    private var storageResult: MethodChannel.Result? = null
    private val storageReqCode = 4512
    private var initThread: Thread? = null
    private val pendingInitResults = mutableListOf<MethodChannel.Result>()
    private var lastVersion = "yt-dlp"
    private var dirResult: MethodChannel.Result? = null
    private val pickDirCode = 4513

    private companion object {
        const val TAG = "VDC"
    }

    private fun flushInit(res: Map<String, Any?>) {
        val results = synchronized(pendingInitResults) {
            val copy = ArrayList(pendingInitResults)
            pendingInitResults.clear()
            copy
        }
        results.forEach { it.success(res) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "vdc/progress")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vdc/engine")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "init" -> {
                        if (engineReady) {
                            result.success(mapOf("ok" to true, "version" to lastVersion))
                            return@setMethodCallHandler
                        }
                        synchronized(pendingInitResults) {
                            pendingInitResults.add(result)
                        }
                        if (initThread?.isAlive == true) {
                            return@setMethodCallHandler
                        }
                        initThread = thread {
                            try {
                                Log.i(TAG, "Inicializando yt-dlp...")
                                YoutubeDL.getInstance().init(applicationContext)
                                Log.i(TAG, "yt-dlp OK. Inicializando FFmpeg...")
                                FFmpeg.getInstance().init(applicationContext)
                                Log.i(TAG, "FFmpeg OK.")
                                engineReady = true
                                lastVersion = try {
                                    val exec = Executors.newSingleThreadExecutor()
                                    val future = exec.submit<String> {
                                        YoutubeDL.getInstance().versionName(applicationContext)
                                    }
                                    val v = try {
                                        future.get(8, TimeUnit.SECONDS)
                                    } catch (t: Throwable) {
                                        null
                                    } finally {
                                        exec.shutdownNow()
                                    }
                                    if (v.isNullOrBlank()) "yt-dlp" else "yt-dlp $v"
                                } catch (t: Throwable) {
                                    "yt-dlp"
                                }
                                Log.i(TAG, "Motor listo: $lastVersion")
                                val res: Map<String, Any?> =
                                    mapOf("ok" to true, "version" to lastVersion)
                                mainHandler.post { flushInit(res) }
                            } catch (t: Throwable) {
                                Log.e(TAG, "Fallo al iniciar el motor", t)
                                engineReady = false
                                engineError = t.message ?: t.toString()
                                val res: Map<String, Any?> =
                                    mapOf("ok" to false, "error" to (engineError ?: "Error"))
                                mainHandler.post { flushInit(res) }
                            }
                        }
                    }

                    "download" -> {
                        val id = call.argument<String>("id")
                        val url = call.argument<String>("url")
                        val audioOnly = call.argument<Boolean>("audioOnly") ?: false
                        val maxHeight = call.argument<Int>("maxHeight") ?: -1
                        val folder = call.argument<String>("folder")
                        if (id.isNullOrBlank() || url.isNullOrBlank()) {
                            result.error("ARGS", "Faltan parámetros", null)
                            return@setMethodCallHandler
                        }
                        if (!engineReady) {
                            result.error("NOT_INIT", engineError ?: "Motor no inicializado", null)
                            return@setMethodCallHandler
                        }
                        thread { runDownload(id, url, audioOnly, maxHeight, folder) }
                        result.success(true)
                    }

                    "pickDirectory" -> {
                        if (dirResult != null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        dirResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                        intent.addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        )
                        try {
                            startActivityForResult(intent, pickDirCode)
                        } catch (t: Throwable) {
                            Log.e(TAG, "No se pudo abrir el selector de carpetas", t)
                            dirResult = null
                            result.success(null)
                        }
                    }

                    "cancel" -> {
                        val id = call.argument<String>("id")
                        if (id != null) {
                            thread {
                                try {
                                    YoutubeDL.getInstance().destroyProcessById(id)
                                } catch (_: Throwable) {
                                }
                            }
                        }
                        result.success(true)
                    }

                    "updateEngine" -> {
                        thread {
                            try {
                                YoutubeDL.getInstance().updateYoutubeDL(this, YoutubeDL.UpdateChannel._STABLE)
                                mainHandler.post { result.success(true) }
                            } catch (t: Throwable) {
                                mainHandler.post { result.error("UPDATE", t.message, null) }
                            }
                        }
                    }

                    "ensureStorage" -> ensureStorage(result)

                    "downloadDir" -> {
                        result.success(downloadDir().absolutePath)
                    }

                    "openFile" -> {
                        val path = call.argument<String>("path")
                        if (path != null) {
                            try {
                                openFile(path)
                                result.success(true)
                            } catch (t: Throwable) {
                                result.error("OPEN", t.message, null)
                            }
                        } else {
                            result.error("ARGS", "Ruta vacía", null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // -------------------------------------------------------------------------

    private fun downloadDir(folder: String? = null): File {
        val dir = if (!folder.isNullOrBlank()) {
            File(folder)
        } else {
            File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "VideoDownloader"
            )
        }
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    /// Convierte una URI de ACTION_OPEN_DOCUMENT_TREE a ruta real.
    private fun treeToRealPath(uri: Uri): String? {
        return try {
            val docId = uri.lastPathSegment ?: return null
            when {
                docId.startsWith("primary:") -> {
                    val rel = docId.removePrefix("primary:")
                    val base = Environment.getExternalStorageDirectory().absolutePath
                    if (rel.isEmpty()) base else "$base/$rel"
                }
                docId.contains(":") -> {
                    val parts = docId.split(":", limit = 2)
                    val base = "/storage/${parts[0]}"
                    if (parts[1].isEmpty()) base else "$base/${parts[1]}"
                }
                else -> null
            }
        } catch (t: Throwable) {
            null
        }
    }

    private fun runDownload(
        id: String,
        url: String,
        audioOnly: Boolean,
        maxHeight: Int,
        folder: String? = null
    ) {
        try {
            val request = YoutubeDLRequest(url)
            request.addOption("--no-mtime")
            request.addOption("--newline")
            request.addOption("--no-playlist")
            request.addOption("--concurrent-fragments", "4")
            request.addOption("-o", downloadDir(folder).absolutePath + "/%(title)s.%(ext)s")
            if (audioOnly) {
                request.addOption("-x")
                request.addOption("--audio-format", "mp3")
                request.addOption("--audio-quality", "0")
            } else {
                val h = if (maxHeight > 0) "[height<=$maxHeight]" else ""
                request.addOption(
                    "-f",
                    "bv*${h}[ext=mp4]+ba[ext=m4a]/b${h}[ext=mp4]/bv*${h}+ba/${h}/b"
                )
                request.addOption("--merge-output-format", "mp4")
            }

            emit(id, "start", 0.0, 0, null, null)
            val response = YoutubeDL.getInstance().execute(request, id) { progress, eta, line ->
                emit(id, "progress", progress.toDouble(), eta.toInt(), line, null)
            }
            val path = extractPath(response.out, audioOnly)
            if (path != null) {
                MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
            }
            emit(id, "done", 100.0, 0, null, path)
        } catch (t: Throwable) {
            val canceled = t.javaClass.simpleName.contains("Canceled", ignoreCase = true)
            emit(
                id,
                "error",
                0.0,
                0,
                if (canceled) "Cancelado" else (t.message ?: t.toString()),
                null
            )
        }
    }

    private fun extractPath(out: String?, audioOnly: Boolean): String? {
        if (out.isNullOrEmpty()) return null
        try {
            if (audioOnly) {
                Regex("ExtractAudio\\] Destination: (.+)").find(out)
                    ?.let { return it.groupValues[1].trim() }
            }
            Regex("Merging formats into \"(.+)\"").find(out)
                ?.let { return it.groupValues[1].trim() }
            Regex("has already been downloaded").find(out)?.let {
                Regex("^(.+?) has already been downloaded").find(out.trim())
                    ?.let { m -> return m.groupValues[1].trim() }
            }
            Regex("Destination: (.+)").findAll(out).lastOrNull()
                ?.let { return it.groupValues[1].trim() }
        } catch (_: Throwable) {
        }
        return null
    }

    private fun emit(
        id: String,
        type: String,
        progress: Double,
        eta: Int,
        message: String?,
        path: String?
    ) {
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "id" to id,
                    "type" to type,
                    "progress" to progress,
                    "eta" to eta,
                    "message" to message,
                    "path" to path
                )
            )
        }
    }

    // -------------------------------------------------------------------------

    private fun ensureStorage(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (Environment.isExternalStorageManager()) {
                Log.i(TAG, "Permiso de archivos ya concedido")
                result.success(true)
                return
            }
            Log.i(TAG, "Solicitando acceso total a archivos (Android 11+)")
            storageResult = result
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName")
            )
            try {
                startActivityForResult(intent, storageReqCode)
            } catch (t: Throwable) {
                Log.e(TAG, "No se pudo abrir la pantalla de permisos", t)
                storageResult = null
                result.success(false)
            }
        } else {
            val perm = android.Manifest.permission.WRITE_EXTERNAL_STORAGE
            if (ContextCompat.checkSelfPermission(this, perm) == PackageManager.PERMISSION_GRANTED) {
                result.success(true)
                return
            }
            storageResult = result
            ActivityCompat.requestPermissions(this, arrayOf(perm), storageReqCode)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == storageReqCode) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            storageResult?.success(granted)
            storageResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == storageReqCode) {
            val granted = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                    Environment.isExternalStorageManager()
            storageResult?.success(granted)
            storageResult = null
        } else if (requestCode == pickDirCode) {
            val tree = data?.data
            val path = if (resultCode == RESULT_OK && tree != null) {
                treeToRealPath(tree)
            } else {
                null
            }
            Log.i(TAG, "Carpeta elegida: $path")
            dirResult?.success(path)
            dirResult = null
        }
    }

    private fun openFile(path: String) {
        val file = File(path)
        if (!file.exists()) return
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val mime = when (file.extension.lowercase()) {
            "mp4", "m4v", "mov" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "avi" -> "video/x-msvideo"
            "mp3" -> "audio/mpeg"
            "m4a" -> "audio/mp4"
            else -> "*/*"
        }
        val intent = Intent(Intent.ACTION_VIEW)
        intent.setDataAndType(uri, mime)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(Intent.createChooser(intent, "Abrir con"))
    }
}
