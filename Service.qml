import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Process orchestration and state for the Ferries widget.
//
// One provider process produces one normalized JSON document per refresh;
// this file runs it, keeps the last good document, and owns the timers. The
// panel only ever reads `doc`. Which ferry system is behind it is decided by
// the `provider` setting and bin/ferries-fetch, never here.
//
// Refresh runs whether or not the panel is open, because the bar label is a
// countdown to a boat and a countdown built on stale data is wrong in a way
// that looks right. It runs faster while the panel is open, since that is
// when vessel positions are actually being watched.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  // --- Document --------------------------------------------------------------
  // The last document the provider produced, good or bad, after Model.parseDoc.
  // Null until the first one lands. A parse failure keeps the previous one.
  property var doc: null
  property bool loading: true
  property string lastError: ""
  property real lastFetchAt: 0
  readonly property bool fetching: fetchProc.running

  // Ticks so countdowns move between fetches.
  property real now: Date.now() / 1000

  // --- Settings --------------------------------------------------------------
  readonly property string provider: String(setting("provider", "wsdot"))
  readonly property string route: String(setting("route", "Bainbridge Island - Seattle"))
  readonly property string apiKey: String(setting("apiKey", ""))
  readonly property string barLabelMode: String(setting("barLabel", "countdown"))
  readonly property int departuresShown: intSetting("departuresShown", 4, 1, 12)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 20, 600)
  readonly property int panelRefreshIntervalSec: intSetting("panelRefreshIntervalSec", 20, 10, 300)
  readonly property int cameraIntervalSec: intSetting("cameraIntervalSec", 60, 15, 600)
  readonly property bool showCamera: boolSetting("showCamera", true)

  // --- Camera ----------------------------------------------------------------
  property int cameraIndex: 0
  property string cameraFile: ""
  property int cameraStamp: 0
  property string cameraTitle: ""
  property bool cameraWanted: false    // the panel sets this while its camera section is on screen
  readonly property bool cameraBusy: cameraProc.running
  readonly property int cameraCount: doc && Array.isArray(doc.cameras) ? doc.cameras.length : 0

  // --- Paths -----------------------------------------------------------------
  readonly property string runPath: String(Qt.resolvedUrl("bin/ferries-run")).replace(/^file:\/\//, "")
  readonly property string fetchPath: String(Qt.resolvedUrl("bin/ferries-fetch")).replace(/^file:\/\//, "")
  readonly property string cameraPath: String(Qt.resolvedUrl("bin/ferries-camera")).replace(/^file:\/\//, "")
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || ("/tmp/" + Quickshell.env("USER"))) + "/omarchy-ferries"

  // Every process this file starts goes through bin/ferries-run, which caps
  // stdout and stderr in a separate process before QML's StdioCollector,
  // which has no cap of its own, ever sees a byte. The provider caps itself
  // too; this is the backstop that does not depend on it.
  function capped(argv) { return ["bash", runPath].concat(argv) }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function boolSetting(name, fallback) {
    var v = setting(name, fallback)
    if (typeof v === "boolean") return v
    var s = String(v).toLowerCase()
    if (s === "true" || s === "1" || s === "yes" || s === "on") return true
    if (s === "false" || s === "0" || s === "no" || s === "off") return false
    return fallback
  }

  // --- Refresh ---------------------------------------------------------------

  function refresh() {
    if (fetchProc.running) return
    var argv = ["bash", fetchPath, "--provider", provider, "--route", route]
    if (apiKey !== "") argv.push("--key", apiKey)
    fetchProc.command = capped(argv)
    fetchProc.running = true
    fetchWatchdog.restart()
  }

  // A route change is a different document entirely. Drop the old one so the
  // hero says "loading" rather than showing yesterday's boat under a new name.
  onRouteChanged: { doc = null; loading = true; cameraIndex = 0; cameraFile = ""; Qt.callLater(refresh) }
  onProviderChanged: { doc = null; loading = true; Qt.callLater(refresh) }
  onApiKeyChanged: Qt.callLater(refresh)

  function applyDocument(raw) {
    var parsed = Model.parseDoc(raw)
    if (!parsed) {
      lastError = "Provider returned something that is not a document"
      return
    }
    lastError = ""
    doc = parsed
    loading = false
    lastFetchAt = Date.now() / 1000
    now = lastFetchAt
    if (cameraIndex >= cameraCount) cameraIndex = 0
    if (cameraWanted && cameraFile === "") refreshCamera()
  }

  // --- Camera ----------------------------------------------------------------

  function currentCamera() {
    if (!doc || !Array.isArray(doc.cameras) || doc.cameras.length === 0) return null
    return doc.cameras[cameraIndex % doc.cameras.length] || null
  }

  function refreshCamera() {
    if (!showCamera || !cameraWanted || cameraProc.running) return
    var cam = currentCamera()
    if (!cam || typeof cam.url !== "string" || cam.url.indexOf("https://") !== 0) return
    var dest = runtimeDir + "/cam-" + String(parseInt(cam.id, 10) || 0) + ".jpg"
    cameraTitle = cam.title || ""
    cameraProc.command = capped(["bash", cameraPath, cam.url, dest])
    cameraProc.running = true
    cameraWatchdog.restart()
  }

  function stepCamera(step) {
    if (cameraCount === 0) return
    cameraIndex = (cameraIndex + step + cameraCount) % cameraCount
    cameraFile = ""
    refreshCamera()
  }

  onCameraWantedChanged: if (cameraWanted) refreshCamera()

  // --- Route persistence -----------------------------------------------------

  // Written back through the same command a user would type, so the change
  // lands in shell.json and survives a restart. The bar re-injects settings,
  // which flips `route` above and triggers the refresh.
  function persistRoute(value) {
    var text = String(value || "").trim()
    if (text === "" || text.length > 120) return
    Quickshell.execDetached(["omarchy", "bar", "set", "jampick.ferries", "route", text])
  }

  function swapDirection() {
    if (!doc || !doc.route) return
    persistRoute(Model.swappedRouteSetting(doc.route))
  }

  // Only the operator's own https links, and only the ones the document
  // named. A provider that wanted to open something else has no path to it.
  function openLink(url) {
    var text = String(url || "")
    if (text.indexOf("https://") !== 0 || text.length > 400) return
    Quickshell.execDetached(["omarchy-launch-browser", text])
  }

  function link(name) {
    if (!doc) return ""
    var routeLinks = doc.route && doc.route.links ? doc.route.links : {}
    var value = routeLinks[name] || (doc.links ? doc.links[name] : "")
    return typeof value === "string" ? value : ""
  }

  // --- Timers ----------------------------------------------------------------

  Timer {
    id: pollTimer
    interval: (root.panelOpen ? root.panelRefreshIntervalSec : root.refreshIntervalSec) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Moves the countdowns. Fifteen seconds is invisible in "12 min" and
    // keeps "now" honest.
    interval: 15000
    repeat: true
    running: true
    onTriggered: root.now = Date.now() / 1000
  }

  Timer {
    id: cameraTimer
    interval: root.cameraIntervalSec * 1000
    repeat: true
    running: root.cameraWanted && root.showCamera
    onTriggered: root.refreshCamera()
  }

  Timer {
    // A poll is skipped while its own process is still running, so one that
    // never exits would stop the panel refreshing at all, permanently.
    id: fetchWatchdog
    interval: 45000
    repeat: false
    onTriggered: {
      if (fetchProc.running) {
        fetchProc.running = false
        root.lastError = "Provider did not respond"
        root.loading = false
      }
    }
  }

  Timer {
    id: cameraWatchdog
    interval: 20000
    repeat: false
    onTriggered: if (cameraProc.running) cameraProc.running = false
  }

  onPanelOpenChanged: {
    if (panelOpen) {
      // Opening the panel re-polls unless the last document is seconds old.
      if (Date.now() / 1000 - lastFetchAt > 8) refresh()
      now = Date.now() / 1000
    }
  }

  // --- Processes -------------------------------------------------------------

  Process {
    id: fetchProc
    running: false
    command: []
    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    stderr: StdioCollector { id: fetchErr; waitForEnd: true }
    onExited: function(exitCode) {
      fetchWatchdog.stop()
      var out = String(fetchOut.text || "")
      // The provider exits 1 for "ran, but the route has no data" and still
      // prints a document that says why. Only an empty stdout is a failure of
      // the process itself.
      if (out.trim() === "") {
        root.loading = false
        root.lastError = exitCode === 127
          ? "python3 or bash is missing"
          : Model.elide(String(fetchErr.text || "").trim() || ("Provider exited " + exitCode), 160)
        return
      }
      root.applyDocument(out)
    }
  }

  Process {
    id: cameraProc
    running: false
    command: []
    stdout: StdioCollector { id: cameraOut; waitForEnd: true }
    onExited: function(exitCode) {
      cameraWatchdog.stop()
      if (exitCode !== 0) return
      var file = String(cameraOut.text || "").trim()
      if (file === "" || file.indexOf(root.runtimeDir) !== 0) return
      root.cameraFile = file
      root.cameraStamp = Date.now()
    }
  }
}
