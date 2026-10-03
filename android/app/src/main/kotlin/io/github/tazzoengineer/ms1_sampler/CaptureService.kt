package io.github.tazzoengineer.ms1_sampler

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.widget.Toast
import androidx.annotation.RequiresApi
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * 他のアプリの再生音を AudioPlaybackCapture で聴き続け、直近 [RING_SECONDS] 秒をリングバッファに保持する。
 *
 * - 「直前を取り込む」: リングバッファの末尾 N 秒を WAV にして captures/ に保存（通知のボタンからも可）
 * - 「録音」: 開始から停止までを WAV に書き出す（長さの上限なし）
 *
 * 録音を拒否しているアプリ（多くのストリーミングサービス）の音は無音になる。
 */
@RequiresApi(Build.VERSION_CODES.Q)
class CaptureService : Service() {
    companion object {
        const val ACTION_START = "start"
        const val ACTION_SNAPSHOT = "snapshot"
        const val ACTION_STOP = "stop"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"

        /** 試す録音形式（サンプリングレート, ステレオか）。端末の再生側に合わせて 48kHz を優先する。 */
        private val FORMATS = listOf(48000 to true, 44100 to true, 48000 to false, 44100 to false)
        const val RING_SECONDS = 60
        private const val CHANNEL_ID = "capture"
        private const val NOTIFICATION_ID = 1

        /** 動作中のサービス。止まっていれば null。 */
        @Volatile var instance: CaptureService? = null

        /** Flutter への通知（メインスレッドで呼ばれる）。 */
        var listener: ((Map<String, Any?>) -> Unit)? = null

        /** 開始処理の結果（null なら成功、それ以外はエラーメッセージ）。 */
        var onStartResult: ((String?) -> Unit)? = null

        /** 通知のボタンで取り込む秒数。 */
        @Volatile var snapshotSeconds = 20

        fun capturesDir(ctx: Context) = File(ctx.filesDir, "captures").apply { mkdirs() }
    }

    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    private var reader: Thread? = null
    @Volatile private var running = false

    private val lock = Any()
    private var sampleRate = 48000
    private var ring = ShortArray(0) // モノラル
    private var written = 0L // これまでに受け取った総フレーム数

    private var takeFile: File? = null
    private var takeOut: FileOutputStream? = null

    val isRecording get() = synchronized(lock) { takeOut != null }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START && !running) {
            // プロセスが落ちた後に通知のボタンが押された場合など
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            ACTION_START -> start(intent)
            ACTION_SNAPSHOT -> thread {
                val f = snapshot(snapshotSeconds)
                main.post {
                    if (f != null) {
                        emit(mapOf("type" to "capture", "path" to f.path))
                        Toast.makeText(this, "直前 ${snapshotSeconds} 秒を取り込みました", Toast.LENGTH_SHORT).show()
                    }
                }
            }
            ACTION_STOP -> shutdown()
        }
        return START_NOT_STICKY
    }

    @SuppressLint("MissingPermission") // RECORD_AUDIO は MainActivity で確認済み
    private fun start(intent: Intent) {
        val report = onStartResult
        onStartResult = null
        if (running) {
            report?.invoke(null)
            return
        }
        try {
            // Android 14 以降は getMediaProjection より前にフォアグラウンドにする必要がある
            startForeground(
                NOTIFICATION_ID, buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
            val code = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
            val data = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
            } else {
                @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_DATA)
            } ?: throw IllegalStateException("許可の情報がありません")

            val mpm = getSystemService(MediaProjectionManager::class.java)
            val mp = mpm.getMediaProjection(code, data)
                ?: throw IllegalStateException("MediaProjection を取得できません")
            mp.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    main.post { shutdown() }
                }
            }, main)
            projection = mp

            val config = AudioPlaybackCaptureConfiguration.Builder(mp)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .excludeUid(Process.myUid()) // パッドの音は録らない
                .build()
            val (rec, rate, stereo) = FORMATS.firstNotNullOfOrNull { (rate, stereo) ->
                openRecord(config, rate, stereo)?.let { Triple(it, rate, stereo) }
            } ?: throw IllegalStateException("AudioRecord を初期化できません")
            sampleRate = rate
            ring = ShortArray(rate * RING_SECONDS)
            written = 0
            record = rec
            running = true
            instance = this
            rec.startRecording()
            reader = thread(name = "capture-reader") { readLoop(rec, stereo) }
            emit(mapOf("type" to "state", "connected" to true))
            report?.invoke(null)
        } catch (e: Exception) {
            shutdown()
            report?.invoke(e.message ?: e.toString())
        }
    }

    @SuppressLint("MissingPermission")
    private fun openRecord(config: AudioPlaybackCaptureConfiguration, rate: Int, stereo: Boolean): AudioRecord? {
        val mask = if (stereo) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(rate)
            .setChannelMask(mask)
            .build()
        val minBuf = AudioRecord.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        return try {
            val rec = AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(max(minBuf * 4, rate * 2))
                .setAudioPlaybackCaptureConfig(config)
                .build()
            if (rec.state == AudioRecord.STATE_INITIALIZED) rec else null.also { rec.release() }
        } catch (e: Exception) {
            null
        }
    }

    private fun readLoop(rec: AudioRecord, stereo: Boolean) {
        val raw = ShortArray(4096)
        val buf = ShortArray(raw.size) // モノラルに変換したもの
        val bytes = ByteBuffer.allocate(buf.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        var peak = 0
        var lastLevel = 0L
        while (running) {
            val read = rec.read(raw, 0, raw.size)
            if (read <= 0) continue
            val n = if (stereo) read / 2 else read
            if (stereo) {
                for (i in 0 until n) buf[i] = ((raw[i * 2] + raw[i * 2 + 1]) / 2).toShort()
            } else {
                raw.copyInto(buf, 0, 0, n)
            }
            synchronized(lock) {
                for (i in 0 until n) {
                    ring[((written + i) % ring.size).toInt()] = buf[i]
                }
                written += n
                takeOut?.let { out ->
                    bytes.clear()
                    for (i in 0 until n) bytes.putShort(buf[i])
                    out.write(bytes.array(), 0, n * 2)
                }
            }
            for (i in 0 until n) peak = max(peak, abs(buf[i].toInt()))
            val now = SystemClock.elapsedRealtime()
            if (now - lastLevel >= 50) {
                val level = peak / 32768.0
                main.post { emit(mapOf("type" to "level", "value" to level)) }
                peak = 0
                lastLevel = now
            }
        }
    }

    /** 直近 [seconds] 秒を WAV に保存する。まだ何も受け取っていなければ null。 */
    fun snapshot(seconds: Int): File? {
        val pcm = synchronized(lock) {
            val frames = min(min(seconds.toLong() * sampleRate, written), ring.size.toLong()).toInt()
            if (frames == 0) return null
            val out = ShortArray(frames)
            val start = written - frames
            for (i in 0 until frames) out[i] = ring[((start + i) % ring.size).toInt()]
            out
        }
        val file = newCaptureFile("直前${seconds}秒")
        FileOutputStream(file).use { out ->
            out.write(wavHeader(pcm.size * 2))
            val b = ByteBuffer.allocate(pcm.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            for (v in pcm) b.putShort(v)
            out.write(b.array())
        }
        return file
    }

    fun startTake(): Boolean = synchronized(lock) {
        if (!running || takeOut != null) return false
        val f = newCaptureFile("録音")
        val out = FileOutputStream(f)
        out.write(wavHeader(0)) // 長さは停止時に書き直す
        takeFile = f
        takeOut = out
        true
    }

    fun stopTake(): File? {
        val (f, out) = synchronized(lock) {
            val pair = takeFile to takeOut
            takeFile = null
            takeOut = null
            pair
        }
        if (f == null || out == null) return null
        out.close()
        val dataLen = (f.length() - 44).toInt()
        if (dataLen <= 0) {
            f.delete()
            return null
        }
        RandomAccessFile(f, "rw").use { it.write(wavHeader(dataLen)) }
        return f
    }

    fun shutdown() {
        if (instance === this) instance = null
        running = false
        reader?.join(500)
        reader = null
        stopTake()
        record?.run {
            try { stop() } catch (_: IllegalStateException) {}
            release()
        }
        record = null
        projection?.stop()
        projection = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        emit(mapOf("type" to "state", "connected" to false))
    }

    override fun onDestroy() {
        if (running) shutdown()
        super.onDestroy()
    }

    private fun emit(event: Map<String, Any?>) {
        listener?.invoke(event)
    }

    private fun newCaptureFile(label: String): File {
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        return File(capturesDir(this), "$stamp-$label.wav")
    }

    private fun wavHeader(dataLen: Int): ByteArray {
        val b = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36 + dataLen).put("WAVE".toByteArray())
        b.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
        b.putInt(sampleRate).putInt(sampleRate * 2).putShort(2).putShort(16)
        b.put("data".toByteArray()).putInt(dataLen)
        return b.array()
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "再生音の取り込み", NotificationManager.IMPORTANCE_LOW),
        )
        fun service(action: String, req: Int) = PendingIntent.getService(
            this, req, Intent(this, CaptureService::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("再生音を聴いています")
            .setContentText("「直前を取り込む」で直近の音を保存します")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "直前を取り込む", service(ACTION_SNAPSHOT, 1)).build())
            .addAction(Notification.Action.Builder(null, "終了", service(ACTION_STOP, 2)).build())
            .build()
    }
}
