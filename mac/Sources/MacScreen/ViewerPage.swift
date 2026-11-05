/// The page the phone opens. Works in any browser and inside the Android app's WebView.
/// It always draws only the newest frame, so it never falls behind.
enum ViewerPage {
    static let html = #"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="theme-color" content="#000000">
<meta name="mobile-web-app-capable" content="yes">
<title>ShareScreen</title>
<style>
  html, body { margin: 0; height: 100%; background: #000; overflow: hidden; touch-action: none; }
  canvas { position: fixed; inset: 0; width: 100%; height: 100%; object-fit: contain; display: block; }
  #status { position: fixed; inset: 0; display: flex; flex-direction: column; gap: 10px;
            align-items: center; justify-content: center; padding: 24px; text-align: center;
            color: #8b9099; font: 15px/1.4 -apple-system, system-ui, Roboto, sans-serif; }
  #status b { color: #e8eaed; font-weight: 600; font-size: 17px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #5b8def; animation: p 1.2s ease-in-out infinite; }
  @keyframes p { 50% { opacity: .25; } }
</style>
</head>
<body>
<canvas id="c"></canvas>
<div id="status"><div class="dot"></div><b>ShareScreen</b><span id="msg">Connecting to your Mac…</span></div>
<script>
  const canvas = document.getElementById('c');
  const ctx = canvas.getContext('2d', { alpha: false });
  const statusBox = document.getElementById('status');
  const msg = document.getElementById('msg');
  let latest = null, drawing = false;

  function showStatus(text) { msg.textContent = text; statusBox.style.display = 'flex'; }

  function draw() {
    if (drawing || !latest) return;
    const blob = latest; latest = null; drawing = true;
    createImageBitmap(blob).then(img => {
      if (canvas.width !== img.width || canvas.height !== img.height) {
        canvas.width = img.width; canvas.height = img.height;
      }
      ctx.drawImage(img, 0, 0);
      if (img.close) img.close();
      statusBox.style.display = 'none';
    }).catch(() => {}).finally(() => {
      drawing = false;
      if (latest) requestAnimationFrame(draw);
    });
  }

  function connect() {
    const ws = new WebSocket('ws://' + location.hostname + ':8781/');
    ws.binaryType = 'blob';
    ws.onmessage = e => {
      if (typeof e.data === 'string') { showStatus(e.data); return; }
      latest = e.data;
      requestAnimationFrame(draw);
    };
    ws.onclose = () => { showStatus('Waiting for your Mac…'); setTimeout(connect, 1000); };
  }
  connect();

  // Tap once for full screen + landscape (browser only; the app is already full screen).
  document.addEventListener('click', () => {
    const el = document.documentElement;
    if (!document.fullscreenElement && el.requestFullscreen) el.requestFullscreen().catch(() => {});
  });

  // Keep the screen awake where the browser allows it (USB/localhost).
  async function keepAwake() { try { if ('wakeLock' in navigator) await navigator.wakeLock.request('screen'); } catch (e) {} }
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') keepAwake(); });
  keepAwake();
</script>
</body>
</html>
"""#
}
