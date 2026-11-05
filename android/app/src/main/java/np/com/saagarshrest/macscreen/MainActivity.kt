package np.com.saagarshrest.macscreen

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.net.URL
import kotlin.concurrent.thread

/**
 * One tap: finds the Mac (USB → last address → local network broadcast)
 * and shows its extra display full screen.
 */
class MainActivity : Activity() {

    private companion object {
        const val HTTP_PORT = 8780
        const val DISCOVERY_PORT = 8782
        const val PREFS = "macscreen"
        const val KEY_LAST = "last_host"
    }

    private var webView: WebView? = null
    private var player: VideoPlayer? = null
    private val viewing get() = webView != null || player != null
    private lateinit var statusView: TextView
    private lateinit var actions: LinearLayout
    @Volatile private var searching = false
    private val prefs by lazy { getSharedPreferences(PREFS, Context.MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        showStatusScreen()
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        if (!viewing) startSearch()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (viewing) {
            closeViewer()
            setStatus("Disconnected.", showActions = true)
        } else {
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }

    override fun onDestroy() {
        player?.stop()
        webView?.destroy()
        super.onDestroy()
    }

    // region Finding the Mac

    private fun startSearch() {
        if (searching) return
        searching = true
        setStatus("Looking for your Mac…", showActions = false)
        thread(name = "find-mac") {
            val host = findMac()
            searching = false
            runOnUiThread {
                if (isFinishing) return@runOnUiThread
                if (host != null) openViewer(host)
                else setStatus(
                    "Couldn't find your Mac.\n\nMake sure ShareScreen is running on the Mac and both are on the same Wi‑Fi or hotspot.",
                    showActions = true
                )
            }
        }
    }

    private fun findMac(): String? {
        // 1. USB via `adb reverse`, 2. the address that worked last time.
        val quick = listOfNotNull("127.0.0.1", prefs.getString(KEY_LAST, null)).distinct()
        quick.firstOrNull { ping(it) }?.let { return it }

        // 3. Ask the local network.
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifi.createMulticastLock("macscreen").apply { setReferenceCounted(false) }
        return try {
            lock.acquire()
            discover(timeoutMs = 5000)
        } catch (e: Exception) {
            null
        } finally {
            if (lock.isHeld) lock.release()
        }
    }

    /** Video port the Mac offers for the native player (0 = only the browser stream). */
    @Volatile private var videoPort = 0

    private fun ping(host: String): Boolean = try {
        val conn = URL("http://$host:$HTTP_PORT/ping").openConnection() as HttpURLConnection
        conn.connectTimeout = 700
        conn.readTimeout = 700
        val reply = conn.inputStream.bufferedReader().use { it.readText() }
        conn.disconnect()
        if (reply.startsWith("macscreen")) {
            videoPort = Regex("h264:(\\d+)").find(reply)?.groupValues?.get(1)?.toIntOrNull() ?: 0
            true
        } else false
    } catch (e: Exception) {
        false
    }

    private fun discover(timeoutMs: Long): String? {
        val socket = DatagramSocket(null).apply {
            reuseAddress = true
            broadcast = true
            soTimeout = 400
        }
        try {
            try { socket.bind(InetSocketAddress(DISCOVERY_PORT)) }
            catch (e: Exception) { socket.bind(InetSocketAddress(0)) } // still gets direct replies

            val query = "MACSCREEN?".toByteArray()
            val buffer = ByteArray(512)
            val deadline = System.currentTimeMillis() + timeoutMs
            var lastQuery = 0L
            while (System.currentTimeMillis() < deadline && !isFinishing) {
                val now = System.currentTimeMillis()
                if (now - lastQuery > 800) {
                    lastQuery = now
                    for (target in broadcastTargets()) {
                        try { socket.send(DatagramPacket(query, query.size, target, DISCOVERY_PORT)) } catch (_: Exception) {}
                    }
                }
                val packet = DatagramPacket(buffer, buffer.size)
                try { socket.receive(packet) } catch (_: SocketTimeoutException) { continue }
                val text = String(packet.data, 0, packet.length)
                if (!text.startsWith("MACSCREEN ")) continue // ignores our own query
                val ip = packet.address?.hostAddress ?: continue
                if (ping(ip)) return ip
            }
            return null
        } finally {
            socket.close()
        }
    }

    /** Broadcast address of every active network, incl. the phone's own hotspot. */
    private fun broadcastTargets(): List<InetAddress> {
        val targets = mutableListOf<InetAddress>()
        try {
            for (iface in NetworkInterface.getNetworkInterfaces()) {
                if (!iface.isUp || iface.isLoopback) continue
                iface.interfaceAddresses.mapNotNullTo(targets) { it.broadcast }
            }
        } catch (_: Exception) {}
        targets.add(InetAddress.getByName("255.255.255.255"))
        return targets.distinct()
    }

    // endregion

    // region Viewer

    private fun openViewer(host: String) {
        prefs.edit().putString(KEY_LAST, host).apply()
        if (videoPort == 0) { openWebViewer(host); return }
        val p = VideoPlayer(this, host, videoPort) {
            // Connection dropped: go back and look for the Mac again.
            closeViewer()
            startSearch()
        }
        player = p
        setContentView(p)
        hideSystemBars()
        p.start()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun openWebViewer(host: String) {
        val web = WebView(this).apply {
            setBackgroundColor(Color.BLACK)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.loadWithOverviewMode = true
            settings.useWideViewPort = true
            settings.setSupportZoom(false)
            overScrollMode = View.OVER_SCROLL_NEVER
            isVerticalScrollBarEnabled = false
            isHorizontalScrollBarEnabled = false
            webViewClient = object : WebViewClient() {
                @Deprecated("Deprecated in Java")
                override fun onReceivedError(view: WebView, code: Int, description: String?, url: String?) {
                    // Mac went away before the page loaded: search again.
                    closeViewer()
                    startSearch()
                }
            }
            loadUrl("http://$host:$HTTP_PORT/")
        }
        webView = web
        setContentView(web)
        hideSystemBars()
    }

    private fun closeViewer() {
        player?.stop()
        player = null
        webView?.let {
            it.stopLoading()
            it.destroy()
        }
        webView = null
        showStatusScreen()
    }

    // endregion

    // region Status screen

    private fun showStatusScreen() {
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#0B0C0F"))
            setPadding(dp(32), dp(24), dp(32), dp(24))
        }
        val title = TextView(this).apply {
            text = "ShareScreen"
            setTextColor(Color.parseColor("#E8EAED"))
            textSize = 22f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
        }
        statusView = TextView(this).apply {
            setTextColor(Color.parseColor("#8B9099"))
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, dp(20))
            maxWidth = dp(460)
        }
        actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            addView(pillButton("Try again", primary = true) { startSearch() })
            addView(View(context), LinearLayout.LayoutParams(dp(12), 1))
            addView(pillButton("Enter address", primary = false) { askForAddress() })
        }
        root.addView(title)
        root.addView(statusView)
        root.addView(actions)
        setContentView(root, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun pillButton(label: String, primary: Boolean, onClick: () -> Unit): Button {
        val density = resources.displayMetrics.density
        return Button(this).apply {
            text = label
            isAllCaps = false
            textSize = 15f
            stateListAnimator = null
            setTextColor(if (primary) Color.WHITE else Color.parseColor("#C9CDD4"))
            background = GradientDrawable().apply {
                cornerRadius = 24 * density
                if (primary) setColor(Color.parseColor("#5B8DEF"))
                else { setColor(Color.TRANSPARENT); setStroke((1 * density).toInt(), Color.parseColor("#3A3F47")) }
            }
            setPadding((20 * density).toInt(), 0, (20 * density).toInt(), 0)
            minHeight = (44 * density).toInt()
            setOnClickListener { onClick() }
        }
    }

    private fun setStatus(text: String, showActions: Boolean) {
        if (viewing) return
        statusView.text = text
        actions.visibility = if (showActions) View.VISIBLE else View.INVISIBLE
    }

    private fun askForAddress() {
        val input = EditText(this).apply {
            hint = "192.168.1.5"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setText(prefs.getString(KEY_LAST, "") ?: "")
        }
        AlertDialog.Builder(this)
            .setTitle("Mac's address")
            .setMessage("Shown in the ShareScreen menu on your Mac.")
            .setView(input)
            .setPositiveButton("Connect") { _, _ ->
                val host = input.text.toString().trim()
                    .removePrefix("http://").substringBefore("/").substringBefore(":")
                if (host.isNotEmpty()) thread {
                    ping(host) // learns whether the fast video stream is available
                    runOnUiThread { openViewer(host) }
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // endregion

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
    }
}
