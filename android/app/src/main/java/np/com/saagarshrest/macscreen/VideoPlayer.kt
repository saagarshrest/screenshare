package np.com.saagarshrest.macscreen

import android.content.Context
import android.graphics.Color
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout
import android.widget.TextView
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.thread
import kotlin.concurrent.withLock

/**
 * Native low-latency player: raw H.264 over TCP → hardware MediaCodec → SurfaceView.
 * Frames are shown the moment they're decoded (no buffering, no browser).
 * Optional sound (packet type 5, PCM 48 kHz stereo) plays through AudioTrack.
 * Tap the screen to show or hide live stats.
 */
class VideoPlayer(
    context: Context,
    private val host: String,
    private val port: Int,
    private val onDisconnected: () -> Unit,
) : FrameLayout(context), SurfaceHolder.Callback {

    private val surfaceView = SurfaceView(context)
    private val statusView = TextView(context).apply {
        setTextColor(Color.parseColor("#8B9099"))
        textSize = 15f
        gravity = Gravity.CENTER
        text = "Connecting to your computer…"
    }
    private val statsView = TextView(context).apply {
        setTextColor(Color.WHITE)
        textSize = 12f
        typeface = android.graphics.Typeface.MONOSPACE
        setBackgroundColor(Color.parseColor("#99000000"))
        setPadding(18, 12, 18, 12)
        visibility = GONE
    }
    private val main = Handler(Looper.getMainLooper())

    // Stats, counted on the network/render threads and shown once a second.
    @Volatile private var bytesIn = 0L
    @Volatile private var framesShown = 0
    @Volatile private var framesDropped = 0
    @Volatile private var latencySumUs = 0L
    @Volatile private var latencyCount = 0
    @Volatile private var audioActive = false
    private val statsTick = object : Runnable {
        override fun run() {
            val mbps = bytesIn * 8 / 1_000_000.0
            val lat = if (latencyCount > 0) latencySumUs / latencyCount / 1000.0 else 0.0
            statsView.text = String.format(
                "%dx%d  %d fps\n%.1f Mbit/s\ndecode %.1f ms\ndropped %d%s",
                videoWidth, videoHeight, framesShown, mbps, lat, framesDropped,
                if (audioActive) "\nsound on" else "")
            bytesIn = 0; framesShown = 0; latencySumUs = 0; latencyCount = 0
            if (statsView.visibility == VISIBLE) main.postDelayed(this, 1000)
        }
    }

    // Sound: a small queue between the network thread and the AudioTrack writer.
    private val audioQueue = ArrayBlockingQueue<ByteArray>(8) // 8 × 20 ms
    @Volatile private var audioTrack: AudioTrack? = null

    @Volatile private var running = false
    @Volatile private var codec: MediaCodec? = null
    @Volatile private var surfaceReady = false
    private val codecLock = ReentrantLock()
    private val surfaceAvailable = codecLock.newCondition()
    private var socket: Socket? = null
    private var videoWidth = 0
    private var videoHeight = 0
    private var shownFirstFrame = false

    init {
        setBackgroundColor(Color.BLACK)
        addView(surfaceView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER))
        addView(statusView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(statsView, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START)
            .apply { setMargins(24, 24, 0, 0) })
        surfaceView.holder.addCallback(this)
        setOnClickListener {
            if (statsView.visibility == VISIBLE) {
                statsView.visibility = GONE
            } else {
                statsView.visibility = VISIBLE
                statsView.text = "…"
                main.removeCallbacks(statsTick)
                main.postDelayed(statsTick, 1000)
            }
        }
    }

    fun start() {
        if (running) return
        running = true
        thread(name = "video-net", priority = Thread.MAX_PRIORITY) { networkLoop() }
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        releaseCodec()
        releaseAudio()
        main.removeCallbacks(statsTick)
    }

    // region Surface

    override fun surfaceCreated(holder: SurfaceHolder) {
        codecLock.withLock { surfaceReady = true; surfaceAvailable.signalAll() }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        codecLock.withLock { surfaceReady = false }
        releaseCodec() // a new one is made on the next keyframe
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        post { fitVideo() }
    }

    /** Letterbox the video inside the screen, keeping its shape. */
    private fun fitVideo() {
        if (videoWidth == 0 || videoHeight == 0 || width == 0 || height == 0) return
        val scale = minOf(width.toFloat() / videoWidth, height.toFloat() / videoHeight)
        val lp = surfaceView.layoutParams as LayoutParams
        val w = (videoWidth * scale).toInt()
        val h = (videoHeight * scale).toInt()
        if (lp.width != w || lp.height != h) {
            lp.width = w; lp.height = h; lp.gravity = Gravity.CENTER
            surfaceView.layoutParams = lp
        }
    }

    // endregion

    // region Network + decode

    private fun networkLoop() {
        try {
            val s = Socket()
            socket = s
            s.tcpNoDelay = true
            s.receiveBufferSize = 1 shl 20
            s.connect(InetSocketAddress(host, port), 2500)
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 1 shl 16))
            var buffer = ByteArray(1 shl 18)
            while (running) {
                val type = input.readUnsignedByte()
                val length = input.readInt()
                if (length < 0 || length > (32 shl 20)) throw IllegalStateException("bad packet")
                if (buffer.size < length) buffer = ByteArray(length + (length shr 2))
                input.readFully(buffer, 0, length)
                bytesIn += length + 5
                when (type) {
                    1 -> onConfig(buffer, length)
                    2, 3 -> onFrame(buffer, length, isKey = type == 2)
                    4 -> {
                        val text = String(buffer, 0, length, Charsets.UTF_8)
                        main.post { statusView.text = text; statusView.visibility = VISIBLE; shownFirstFrame = false }
                    }
                    5 -> onAudio(buffer, length)
                }
            }
        } catch (_: Exception) {
        } finally {
            try { socket?.close() } catch (_: Exception) {}
            releaseCodec()
            releaseAudio()
            if (running) {
                running = false
                main.post { onDisconnected() }
            }
        }
    }

    private fun onConfig(data: ByteArray, length: Int) {
        val w = ByteBuffer.wrap(data, 0, 4).int
        val h = ByteBuffer.wrap(data, 4, 4).int
        val csd = data.copyOfRange(8, length)
        if (codec != null && w == videoWidth && h == videoHeight) return // same stream, keep decoding

        releaseCodec()
        videoWidth = w; videoHeight = h
        main.post { fitVideo() }

        // Wait for the surface (it may still be coming up after rotation).
        val surface = codecLock.withLock {
            var waited = 0
            while (!surfaceReady && running && waited < 30) { surfaceAvailable.await(100, TimeUnit.MILLISECONDS); waited++ }
            if (!surfaceReady) return
            surfaceView.holder.surface
        }

        val (sps, pps) = splitParameterSets(csd)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(sps))
            if (pps.isNotEmpty()) setByteBuffer("csd-1", ByteBuffer.wrap(pps))
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(w * h, 1 shl 20))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
        }
        val decoder = try {
            MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
                try {
                    configure(format, surface, null, 0)
                } catch (e: Exception) {
                    // Some decoders reject the tuning keys; retry plain.
                    format.removeKey(MediaFormat.KEY_OPERATING_RATE)
                    configure(MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
                        setByteBuffer("csd-0", ByteBuffer.wrap(sps))
                        if (pps.isNotEmpty()) setByteBuffer("csd-1", ByteBuffer.wrap(pps))
                    }, surface, null, 0)
                }
                start()
            }
        } catch (e: Exception) {
            return
        }
        codec = decoder
        thread(name = "video-out", priority = Thread.MAX_PRIORITY) { renderLoop(decoder) }
    }

    private var lastKeyRequest = 0L

    /** Ask the computer for a fresh keyframe (after the decoder was reset). */
    private fun requestKeyframe() {
        val now = System.currentTimeMillis()
        if (now - lastKeyRequest < 500) return
        lastKeyRequest = now
        val s = socket ?: return
        thread { try { s.getOutputStream().apply { write(1); flush() } } catch (_: Exception) {} }
    }

    private fun onFrame(data: ByteArray, length: Int, isKey: Boolean) {
        val c = codec ?: run { requestKeyframe(); return }
        try {
            val index = c.dequeueInputBuffer(20_000)
            if (index < 0) { framesDropped++; return } // decoder busy: drop (the computer sends a fresh keyframe if we fall behind)
            val input = c.getInputBuffer(index) ?: return
            input.clear()
            input.put(data, 0, length)
            c.queueInputBuffer(index, 0, length, System.nanoTime() / 1000,
                if (isKey) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
        } catch (_: Exception) {
            releaseCodec()
        }
    }

    /** Show each decoded frame immediately; if several are ready, skip to the newest. */
    private fun renderLoop(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (running && codec === c) {
            try {
                var index = c.dequeueOutputBuffer(info, 20_000)
                if (index < 0) continue
                while (true) {
                    val next = c.dequeueOutputBuffer(info, 0)
                    if (next < 0) break
                    c.releaseOutputBuffer(index, false)
                    framesDropped++
                    index = next
                }
                c.releaseOutputBuffer(index, true)
                framesShown++
                latencySumUs += System.nanoTime() / 1000 - info.presentationTimeUs
                latencyCount++
                if (!shownFirstFrame) {
                    shownFirstFrame = true
                    main.post { statusView.visibility = GONE }
                }
            } catch (_: Exception) {
                break
            }
        }
    }

    // region Sound

    private fun onAudio(data: ByteArray, length: Int) {
        if (audioTrack == null) startAudio()
        // Keep latency low: if the speaker falls behind, drop the oldest chunk.
        val chunk = data.copyOf(length)
        if (!audioQueue.offer(chunk)) { audioQueue.poll(); audioQueue.offer(chunk) }
    }

    private fun startAudio() {
        val rate = 48_000
        val minBuf = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                .setAudioFormat(AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(minBuf, rate * 4 / 25)) // ~40 ms
                .setTransferMode(AudioTrack.MODE_STREAM)
                .apply { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY) }
                .build()
        } catch (_: Exception) { return }
        audioTrack = track
        audioActive = true
        track.play()
        thread(name = "audio-out", priority = Thread.MAX_PRIORITY) {
            while (running && audioTrack === track) {
                val chunk = try { audioQueue.poll(200, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { null } ?: continue
                try { track.write(chunk, 0, chunk.size) } catch (_: Exception) { break }
            }
        }
    }

    private fun releaseAudio() {
        val t = audioTrack ?: return
        audioTrack = null
        audioActive = false
        audioQueue.clear()
        try { t.stop() } catch (_: Exception) {}
        try { t.release() } catch (_: Exception) {}
    }

    // endregion

    private fun releaseCodec() {
        val c = codec ?: return
        codec = null
        try { c.stop() } catch (_: Exception) {}
        try { c.release() } catch (_: Exception) {}
    }

    /** Annex-B SPS+PPS blob → (SPS, PPS), each keeping its start code. */
    private fun splitParameterSets(blob: ByteArray): Pair<ByteArray, ByteArray> {
        val starts = mutableListOf<Int>()
        var i = 0
        while (i + 3 < blob.size) {
            if (blob[i] == 0.toByte() && blob[i + 1] == 0.toByte() && blob[i + 2] == 0.toByte() && blob[i + 3] == 1.toByte()) {
                starts.add(i); i += 4
            } else i++
        }
        if (starts.size < 2) return blob to ByteArray(0)
        return blob.copyOfRange(starts[0], starts[1]) to blob.copyOfRange(starts[1], blob.size)
    }

    // endregion
}
