package io.gitlabmobile.on_device_ai

import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import com.google.mlkit.common.MlKit
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Content
import com.google.mlkit.genai.prompt.GenerateContentRequest
import com.google.mlkit.genai.prompt.GenerateContentResponse
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

class MergelineOnDeviceAiPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {

    private var applicationContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pluginScope: CoroutineScope? = null
    private val jobs = ConcurrentHashMap<String, Job>()
    private var bridge: MlKitPromptBridge? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL_NAME).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        applicationContext = null

        val activeJobs = jobs.values.toList()
        jobs.clear()
        for (job in activeJobs) {
            job.cancel(CancellationException("Plugin detached from engine"))
        }
        pluginScope?.cancel(CancellationException("Plugin detached from engine"))
        pluginScope = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            bridge?.close()
        }
        bridge = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "status" -> handleStatus(result)
            "download" -> handleDownload(call, result)
            "generate" -> handleGenerate(call, result)
            "cancel" -> handleCancel(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleStatus(result: Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(
                mapOf(
                    "status" to "unavailable",
                    "reason" to "sdk_too_old",
                ),
            )
            return
        }
        val scope = getOrCreateScope()
        if (scope == null) {
            result.success(
                mapOf(
                    "status" to "unavailable",
                    "reason" to "unsupported",
                ),
            )
            return
        }
        scope.launch {
            try {
                val payload = getOrCreateBridge().checkStatusPayload()
                result.success(payload)
            } catch (t: Throwable) {
                result.success(
                    mapOf(
                        "status" to "unavailable",
                        "reason" to "unsupported",
                        "debugMessage" to t.message,
                    ),
                )
            }
        }
    }

    private fun handleDownload(call: MethodCall, result: Result) {
        val requestId = call.argument<String>("requestId") ?: DEFAULT_DOWNLOAD_ID
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            emitEvent(
                mapOf(
                    "event" to "download",
                    "requestId" to requestId,
                    "state" to "failed",
                    "code" to "unsupported",
                    "debugMessage" to "sdk_too_old",
                ),
            )
            result.success(mapOf("requestId" to requestId))
            return
        }
        val scope = getOrCreateScope()
        if (scope == null) {
            result.error("other", "Plugin scope is not active", null)
            return
        }
        jobs.remove(requestId)?.cancel(CancellationException("Superseded download request"))
        lateinit var launchedJob: Job
        launchedJob = scope.launch {
            try {
                getOrCreateBridge().downloadFlow().collect { status ->
                    when (status) {
                        is DownloadStatus.DownloadStarted -> {
                            emitEvent(
                                mapOf(
                                    "event" to "download",
                                    "requestId" to requestId,
                                    "state" to "started",
                                    "bytesToDownload" to status.bytesToDownload,
                                ),
                            )
                        }
                        is DownloadStatus.DownloadProgress -> {
                            emitEvent(
                                mapOf(
                                    "event" to "download",
                                    "requestId" to requestId,
                                    "state" to "progress",
                                    "bytesDownloaded" to status.totalBytesDownloaded,
                                ),
                            )
                        }
                        is DownloadStatus.DownloadCompleted -> {
                            emitEvent(
                                mapOf(
                                    "event" to "download",
                                    "requestId" to requestId,
                                    "state" to "completed",
                                ),
                            )
                        }
                        is DownloadStatus.DownloadFailed -> {
                            val mapped = mapThrowable(status.e, isDownload = true)
                            emitEvent(
                                mapOf(
                                    "event" to "download",
                                    "requestId" to requestId,
                                    "state" to "failed",
                                    "code" to mapped.code,
                                    "debugMessage" to mapped.debugMessage,
                                    "nativeErrorCode" to mapped.nativeErrorCode,
                                ),
                            )
                        }
                    }
                }
            } catch (e: CancellationException) {
                emitEvent(
                    mapOf(
                        "event" to "download",
                        "requestId" to requestId,
                        "state" to "failed",
                        "code" to "cancelled",
                        "debugMessage" to e.message,
                    ),
                )
            } catch (t: Throwable) {
                val mapped = mapThrowable(t, isDownload = true)
                emitEvent(
                    mapOf(
                        "event" to "download",
                        "requestId" to requestId,
                        "state" to "failed",
                        "code" to mapped.code,
                        "debugMessage" to mapped.debugMessage,
                        "nativeErrorCode" to mapped.nativeErrorCode,
                    ),
                )
            } finally {
                jobs.remove(requestId, launchedJob)
            }
        }
        jobs[requestId] = launchedJob
        result.success(mapOf("requestId" to requestId))
    }

    private fun handleGenerate(call: MethodCall, result: Result) {
        val requestId = call.argument<String>("requestId")
        if (requestId.isNullOrBlank()) {
            result.error("other", "Missing requestId", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("unsupported", "sdk_too_old", null)
            return
        }
        val scope = getOrCreateScope()
        if (scope == null) {
            result.error("other", "Plugin scope is not active", null)
            return
        }
        val system = call.argument<String>("system") ?: ""
        val rawTurns = call.argument<List<*>>("turns") ?: emptyList<Any?>()
        val maxOutputTokens = call.argument<Int>("maxOutputTokens")
        val temperature = call.argument<Double>("temperature")

        jobs.remove(requestId)?.cancel(CancellationException("Replaced request $requestId"))
        lateinit var launchedJob: Job
        launchedJob = scope.launch {
            try {
                val mlBridge = getOrCreateBridge()
                val request = mlBridge.buildRequest(
                    system = system,
                    rawTurns = rawTurns,
                    maxOutputTokens = maxOutputTokens,
                    temperature = temperature,
                )
                mlBridge.generateStream(request).collect { response ->
                    val text = response.candidates.firstOrNull()?.text.orEmpty()
                    if (text.isNotEmpty()) {
                        emitEvent(
                            mapOf(
                                "event" to "generate",
                                "requestId" to requestId,
                                "type" to "chunk",
                                "text" to text,
                            ),
                        )
                    }
                }
                emitEvent(
                    mapOf(
                        "event" to "generate",
                        "requestId" to requestId,
                        "type" to "done",
                    ),
                )
            } catch (e: CancellationException) {
                emitEvent(
                    mapOf(
                        "event" to "generate",
                        "requestId" to requestId,
                        "type" to "error",
                        "code" to "cancelled",
                        "debugMessage" to e.message,
                    ),
                )
            } catch (t: Throwable) {
                val mapped = mapThrowable(t, isDownload = false)
                emitEvent(
                    mapOf(
                        "event" to "generate",
                        "requestId" to requestId,
                        "type" to "error",
                        "code" to mapped.code,
                        "debugMessage" to mapped.debugMessage,
                        "nativeErrorCode" to mapped.nativeErrorCode,
                    ),
                )
            } finally {
                jobs.remove(requestId, launchedJob)
            }
        }
        jobs[requestId] = launchedJob
        result.success(mapOf("requestId" to requestId))
    }

    private fun handleCancel(call: MethodCall, result: Result) {
        val requestId = call.argument<String>("requestId")
        if (!requestId.isNullOrBlank()) {
            jobs.remove(requestId)?.cancel(CancellationException("Cancelled request $requestId"))
        } else {
            val activeJobs = jobs.values.toList()
            jobs.clear()
            for (job in activeJobs) {
                job.cancel(CancellationException("Cancelled all requests"))
            }
        }
        result.success(null)
    }

    private fun emitEvent(payload: Map<String, Any?>) {
        eventSink?.success(payload)
    }

    @Synchronized
    private fun getOrCreateScope(): CoroutineScope? {
        if (applicationContext == null) {
            return null
        }
        val existing = pluginScope
        if (existing != null) {
            return existing
        }
        return CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also {
            pluginScope = it
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    @Synchronized
    private fun getOrCreateBridge(): MlKitPromptBridge {
        val existing = bridge
        if (existing != null) {
            return existing
        }
        val context = checkNotNull(applicationContext) {
            "Plugin is not attached to an Android application context"
        }
        ensureMlKitInitialized(context)
        return MlKitPromptBridge().also {
            bridge = it
        }
    }

    private data class MappedError(
        val code: String,
        val debugMessage: String?,
        val nativeErrorCode: Int?,
    )

    private fun mapThrowable(t: Throwable, isDownload: Boolean): MappedError {
        if (t is CancellationException) {
            return MappedError("cancelled", t.message, null)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && t is GenAiException) {
            val errorCode = t.errorCode
            val mappedCode = when (errorCode) {
                GenAiException.ErrorCode.CANCELLED -> "cancelled"
                GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED -> "backgroundBlocked"
                GenAiException.ErrorCode.BUSY -> "busy"
                GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED -> "quotaExceeded"
                GenAiException.ErrorCode.REQUEST_TOO_LARGE,
                GenAiException.ErrorCode.MAX_TURNS_EXCEEDED,
                -> "inputTooLong"
                GenAiException.ErrorCode.NOT_SUPPORTED,
                GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
                GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
                -> "unsupported"
                GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE -> "notDownloaded"
                GenAiException.ErrorCode.NOT_AVAILABLE -> {
                    if (isDownload) "unsupported" else "notDownloaded"
                }
                else -> if (isDownload) "notDownloaded" else "other"
            }
            return MappedError(mappedCode, t.message, errorCode)
        }
        return MappedError(if (isDownload) "notDownloaded" else "other", t.message, null)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private class MlKitPromptBridge {
        private val model: GenerativeModel = Generation.getClient()

        suspend fun checkStatusPayload(): Map<String, Any?> {
            return when (model.checkStatus()) {
                FeatureStatus.AVAILABLE -> {
                    val modelName = try {
                        model.getBaseModelName()
                    } catch (_: Throwable) {
                        null
                    }
                    mapOf(
                        "status" to "available",
                        "modelName" to modelName,
                    )
                }
                FeatureStatus.DOWNLOADABLE -> mapOf("status" to "downloadable")
                FeatureStatus.DOWNLOADING -> mapOf("status" to "downloading")
                FeatureStatus.UNAVAILABLE -> mapOf(
                    "status" to "unavailable",
                    "reason" to "unsupported",
                )
                else -> mapOf(
                    "status" to "unavailable",
                    "reason" to "unsupported",
                )
            }
        }

        fun downloadFlow(): Flow<DownloadStatus> = model.download()

        fun buildRequest(
            system: String,
            rawTurns: List<*>,
            maxOutputTokens: Int?,
            temperature: Double?,
        ): GenerateContentRequest {
            val contents = ArrayList<Content>(maxOf(rawTurns.size, 1))
            for (item in rawTurns) {
                val map = item as? Map<*, *> ?: continue
                val roleName = (map["role"] as? String)?.lowercase() ?: "user"
                val text = (map["text"] as? String) ?: ""
                val role = if (roleName == "model" || roleName == "assistant") {
                    Content.Role.MODEL
                } else {
                    Content.Role.USER
                }
                contents.add(
                    Content.Builder()
                        .setRole(role)
                        .addPart(TextPart(text))
                        .build(),
                )
            }
            if (contents.isEmpty()) {
                contents.add(
                    Content.Builder()
                        .setRole(Content.Role.USER)
                        .addPart(TextPart(""))
                        .build(),
                )
            }
            val builder = GenerateContentRequest.Builder(contents)
            if (system.isNotEmpty()) {
                builder.systemInstruction = SystemInstruction(system)
            }
            if (maxOutputTokens != null) {
                builder.maxOutputTokens = maxOutputTokens
            }
            if (temperature != null) {
                builder.temperature = temperature.toFloat()
            }
            return builder.build()
        }

        fun generateStream(request: GenerateContentRequest): Flow<GenerateContentResponse> =
            model.generateContentStream(request)

        fun close() {
            model.close()
        }
    }

    companion object {
        const val METHOD_CHANNEL_NAME = "io.gitlabmobile/on_device_ai"
        const val EVENT_CHANNEL_NAME = "io.gitlabmobile/on_device_ai/events"
        private const val DEFAULT_DOWNLOAD_ID = "download"

        @Volatile
        private var mlKitInitialized = false

        @Synchronized
        private fun ensureMlKitInitialized(context: Context) {
            if (mlKitInitialized) {
                return
            }
            val appContext = context.applicationContext ?: context
            try {
                MlKit.initialize(appContext)
            } catch (_: IllegalStateException) {
                // MlKit.initialize throws IllegalStateException("MlKitContext is already initialized")
                // if already initialized in this process.
            }
            mlKitInitialized = true
        }
    }
}
