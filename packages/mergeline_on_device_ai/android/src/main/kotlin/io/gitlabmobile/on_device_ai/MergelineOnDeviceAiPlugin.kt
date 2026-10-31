package io.gitlabmobile.on_device_ai

import android.content.Context
import android.content.pm.PackageManager
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
import kotlinx.coroutines.CoroutineStart
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

    private class ActiveRequest(
        val token: Any,
        @Volatile var job: Job? = null,
    )

    private var applicationContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pluginScope: CoroutineScope? = null
    private val jobs = ConcurrentHashMap<String, ActiveRequest>()
    private val requestOwners = ConcurrentHashMap<String, Any>()
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

        closeActiveWorkAndModel("Plugin detached from engine")
        pluginScope?.cancel(CancellationException("Plugin detached from engine"))
        pluginScope = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "deviceSupport" -> handleDeviceSupport(result)
            "status" -> handleStatus(result)
            "download" -> handleDownload(call, result)
            "generate" -> handleGenerate(call, result)
            "cancel" -> handleCancel(call, result)
            "close" -> handleClose(result)
            else -> result.notImplemented()
        }
    }

    private fun handleDeviceSupport(result: Result) {
        // Must NOT touch any ML Kit class so pre-consent capability checks
        // never initialize MlKitContext or trigger diagnostics collection.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(
                mapOf(
                    "support" to "unsupported",
                    "reason" to "sdk_too_old",
                ),
            )
            return
        }
        val context = applicationContext
        if (context == null) {
            result.success(
                mapOf(
                    "support" to "unknown",
                    "reason" to "no_context",
                ),
            )
            return
        }
        try {
            val pm = context.packageManager
            val appInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getApplicationInfo(
                    AICORE_PACKAGE_NAME,
                    PackageManager.ApplicationInfoFlags.of(0L),
                )
            } else {
                @Suppress("DEPRECATION")
                pm.getApplicationInfo(AICORE_PACKAGE_NAME, 0)
            }
            if (!appInfo.enabled) {
                result.success(
                    mapOf(
                        "support" to "unsupported",
                        "reason" to "aicore_disabled",
                    ),
                )
                return
            }
            result.success(
                mapOf(
                    "support" to "likely",
                ),
            )
        } catch (_: PackageManager.NameNotFoundException) {
            result.success(
                mapOf(
                    "support" to "unsupported",
                    "reason" to "aicore_missing",
                ),
            )
        } catch (t: Throwable) {
            result.success(
                mapOf(
                    "support" to "unknown",
                    "debugMessage" to t.message,
                ),
            )
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
                val mapped = mapThrowable(t, isDownload = false)
                result.success(
                    mapOf(
                        "status" to "unavailable",
                        "reason" to mapped.code,
                        "debugMessage" to mapped.debugMessage,
                    ),
                )
            }
        }
    }

    private fun handleDownload(call: MethodCall, result: Result) {
        val requestId = call.argument<String>("requestId") ?: DEFAULT_DOWNLOAD_ID
        val existing = jobs[requestId]
        if (existing != null) {
            if (existing.job?.isActive != false) {
                result.error("invalidArgument", "Duplicate active requestId: $requestId", null)
                return
            }
            jobs.remove(requestId, existing)
        }
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

        val token = Any()
        val activeRequest = ActiveRequest(token = token)
        requestOwners[requestId] = token
        jobs[requestId] = activeRequest
        // Start with CoroutineStart.LAZY so the Job is registered in `jobs` before
        // the coroutine body executes on Dispatchers.Main.immediate. An eager launch
        // runs synchronously up to the first suspension point and, if it throws or
        // finishes immediately, would otherwise enter `finally` before `launch` returns
        // (crashing on an uninitialised reference or leaving a dead Job in `jobs`).
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val mlBridge = getOrCreateBridge()
                var terminalEventSent = false
                mlBridge.downloadFlow().collect { status ->
                    when (status) {
                        is DownloadStatus.DownloadStarted -> {
                            emitRequestEvent(
                                requestId,
                                token,
                                mapOf(
                                    "event" to "download",
                                    "requestId" to requestId,
                                    "state" to "started",
                                    "bytesToDownload" to status.bytesToDownload,
                                ),
                            )
                        }
                        is DownloadStatus.DownloadProgress -> {
                            emitRequestEvent(
                                requestId,
                                token,
                                mapOf(
                                    "event" to "download",
                                    "requestId" to requestId,
                                    "state" to "progress",
                                    "bytesDownloaded" to status.totalBytesDownloaded,
                                ),
                            )
                        }
                        is DownloadStatus.DownloadCompleted -> {
                            terminalEventSent = true
                            emitRequestEvent(
                                requestId,
                                token,
                                mapOf(
                                    "event" to "download",
                                    "requestId" to requestId,
                                    "state" to "completed",
                                ),
                            )
                        }
                        is DownloadStatus.DownloadFailed -> {
                            terminalEventSent = true
                            val mapped = mapThrowable(status.e, isDownload = true)
                            emitRequestEvent(
                                requestId,
                                token,
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
                if (!terminalEventSent) {
                    val isNowAvailable = try {
                        mlBridge.isModelAvailable()
                    } catch (_: Throwable) {
                        false
                    }
                    if (isNowAvailable) {
                        emitRequestEvent(
                            requestId,
                            token,
                            mapOf(
                                "event" to "download",
                                "requestId" to requestId,
                                "state" to "completed",
                            ),
                        )
                    } else {
                        emitRequestEvent(
                            requestId,
                            token,
                            mapOf(
                                "event" to "download",
                                "requestId" to requestId,
                                "state" to "failed",
                                "code" to "other",
                                "debugMessage" to "Download flow completed without a terminal event",
                            ),
                        )
                    }
                }
            } catch (e: CancellationException) {
                emitRequestEvent(
                    requestId,
                    token,
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
                emitRequestEvent(
                    requestId,
                    token,
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
                jobs.remove(requestId, activeRequest)
                requestOwners.remove(requestId, token)
            }
        }
        activeRequest.job = job
        job.start()
        result.success(mapOf("requestId" to requestId))
    }

    private fun handleGenerate(call: MethodCall, result: Result) {
        val requestId = call.argument<String>("requestId")
        if (requestId.isNullOrBlank()) {
            result.error("invalidArgument", "Missing requestId", null)
            return
        }
        val maxOutputTokens = call.argument<Int>("maxOutputTokens")
        if (maxOutputTokens != null && maxOutputTokens <= 0) {
            result.error("invalidArgument", "maxOutputTokens must be greater than 0", null)
            return
        }
        val temperature = call.argument<Double>("temperature")
        if (temperature != null && (temperature.isNaN() || temperature < 0.0 || temperature > 1.0)) {
            result.error("invalidArgument", "temperature must be between 0.0 and 1.0", null)
            return
        }
        val existing = jobs[requestId]
        if (existing != null) {
            if (existing.job?.isActive != false) {
                result.error("invalidArgument", "Duplicate active requestId: $requestId", null)
                return
            }
            jobs.remove(requestId, existing)
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

        val token = Any()
        val activeRequest = ActiveRequest(token = token)
        requestOwners[requestId] = token
        jobs[requestId] = activeRequest
        // Start with CoroutineStart.LAZY so the Job is registered in `jobs` before
        // the coroutine body executes on Dispatchers.Main.immediate. An eager launch
        // runs synchronously up to the first suspension point and, if it throws or
        // finishes immediately, would otherwise enter `finally` before `launch` returns
        // (crashing on an uninitialised reference or leaving a dead Job in `jobs`).
        val job = scope.launch(start = CoroutineStart.LAZY) {
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
                        emitRequestEvent(
                            requestId,
                            token,
                            mapOf(
                                "event" to "generate",
                                "requestId" to requestId,
                                "type" to "chunk",
                                "text" to text,
                            ),
                        )
                    }
                }
                emitRequestEvent(
                    requestId,
                    token,
                    mapOf(
                        "event" to "generate",
                        "requestId" to requestId,
                        "type" to "done",
                    ),
                )
            } catch (e: CancellationException) {
                emitRequestEvent(
                    requestId,
                    token,
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
                emitRequestEvent(
                    requestId,
                    token,
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
                jobs.remove(requestId, activeRequest)
                requestOwners.remove(requestId, token)
            }
        }
        activeRequest.job = job
        job.start()
        result.success(mapOf("requestId" to requestId))
    }

    private fun handleCancel(call: MethodCall, result: Result) {
        val requestId = call.argument<String>("requestId")
        if (!requestId.isNullOrBlank()) {
            jobs.remove(requestId)?.job?.cancel(CancellationException("Cancelled request $requestId"))
        } else {
            val activeRequests = jobs.values.toList()
            jobs.clear()
            for (active in activeRequests) {
                active.job?.cancel(CancellationException("Cancelled all requests"))
            }
        }
        result.success(null)
    }

    private fun handleClose(result: Result) {
        closeActiveWorkAndModel("Plugin closed by caller")
        result.success(null)
    }

    @Synchronized
    private fun closeActiveWorkAndModel(reason: String) {
        requestOwners.clear()
        val activeRequests = jobs.values.toList()
        jobs.clear()
        for (active in activeRequests) {
            active.job?.cancel(CancellationException(reason))
        }
        val currentBridge = bridge
        bridge = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            currentBridge?.close()
        }
    }

    private fun emitRequestEvent(requestId: String, token: Any, payload: Map<String, Any?>) {
        if (requestOwners[requestId] !== token) {
            return
        }
        emitEvent(payload)
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
                GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE -> "insufficientStorage"
                GenAiException.ErrorCode.NOT_AVAILABLE -> {
                    if (isDownload) "unsupported" else "notDownloaded"
                }
                else -> "other"
            }
            return MappedError(mappedCode, t.message, errorCode)
        }
        return MappedError("other", t.message, null)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private class MlKitPromptBridge {
        private val model: GenerativeModel = Generation.getClient()

        suspend fun isModelAvailable(): Boolean =
            model.checkStatus() == FeatureStatus.AVAILABLE

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
        private const val AICORE_PACKAGE_NAME = "com.google.android.aicore"

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
                mlKitInitialized = true
            } catch (e: IllegalStateException) {
                // MlKit.initialize throws IllegalStateException("MlKitContext is already initialized")
                // if already initialized in this process. Any other IllegalStateException is rethrown
                // so the caller reports `other` without marking ML Kit initialized.
                val message = e.message.orEmpty()
                if (message.contains("MlKitContext is already initialized")) {
                    mlKitInitialized = true
                } else {
                    throw e
                }
            }
        }
    }
}
