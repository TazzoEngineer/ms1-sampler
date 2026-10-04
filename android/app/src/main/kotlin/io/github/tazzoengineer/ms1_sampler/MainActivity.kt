package io.github.tazzoengineer.ms1_sampler

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    companion object {
        private const val REQ_PROJECTION = 1001
        private const val REQ_PERMISSIONS = 1002
    }

    private var pendingConnect: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "ms1/audio").setMethodCallHandler { call, result ->
            when (call.method) {
                // 端末の出力のサンプリングレート。これに合わせないと低遅延の経路を使えない
                "outputSampleRate" -> result.success(
                    getSystemService(AudioManager::class.java)
                        .getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull(),
                )
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "ms1/capture").setMethodCallHandler { call, result ->
            val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            val service = if (supported) CaptureService.instance else null
            when (call.method) {
                "isSupported" -> result.success(supported)
                "capturesDir" -> result.success(
                    if (supported) CaptureService.capturesDir(this).path else null,
                )
                "isConnected" -> result.success(service != null)
                "isRecording" -> result.success(service?.isRecording == true)
                "connect" -> if (supported) connect(result) else result.success(false)
                "disconnect" -> {
                    service?.shutdown()
                    result.success(null)
                }
                "setSnapshotSeconds" -> {
                    if (supported) CaptureService.snapshotSeconds = call.arguments as Int
                    result.success(null)
                }
                "snapshot" -> thread {
                    val f = service?.snapshot(call.arguments as Int)
                    runOnUiThread { result.success(f?.path) }
                }
                "startTake" -> result.success(service?.startTake() == true)
                "stopTake" -> thread {
                    val f = service?.stopTake()
                    runOnUiThread { result.success(f?.path) }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "ms1/capture/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        CaptureService.listener = { sink.success(it) }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        CaptureService.listener = null
                    }
                }
            },
        )
    }

    /** 権限（録音・通知）→ 画面キャプチャの許可ダイアログ → サービス開始 の順に進める。 */
    private fun connect(result: MethodChannel.Result) {
        if (CaptureService.instance != null) {
            result.success(true)
            return
        }
        pendingConnect?.success(false)
        pendingConnect = result
        val needed = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (needed.isEmpty()) {
            requestProjection()
        } else {
            requestPermissions(needed.toTypedArray(), REQ_PERMISSIONS)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERMISSIONS) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            pendingConnect?.error("permission", "録音の権限がありません", null)
            pendingConnect = null
            return
        }
        // 通知を拒否されても取り込み自体はできる（通知のボタンが使えないだけ）
        requestProjection()
    }

    private fun requestProjection() {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // 「1つのアプリ / 画面全体」の選択を出さず、画面全体（＝全アプリの音）にする
            mpm.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            mpm.createScreenCaptureIntent()
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQ_PROJECTION)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PROJECTION) return
        val result = pendingConnect ?: return
        pendingConnect = null
        if (resultCode != RESULT_OK || data == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(false)
            return
        }
        CaptureService.onStartResult = { error ->
            runOnUiThread {
                if (error == null) result.success(true) else result.error("start", error, null)
            }
        }
        startForegroundService(
            Intent(this, CaptureService::class.java)
                .setAction(CaptureService.ACTION_START)
                .putExtra(CaptureService.EXTRA_RESULT_CODE, resultCode)
                .putExtra(CaptureService.EXTRA_DATA, data),
        )
    }
}
