import QtQuick
import Quickshell
import Quickshell.Io
import "app/ModelSync.js" as ModelSync

// TodoTim's headless half: runs `todotim-engine` (the Swift TodoCore engine that owns the
// database and CalDAV sync) and mirrors what it pushes. The panel and the bar widget read from
// here; every change goes back to the engine as a request. The protocol is JSON lines; see
// docs/linux.md in the TodoTim repository.
Item {
  id: root
  visible: false

  // Injected by the Omarchy shell.
  property var manifest: null
  property var shell: null
  property string omarchyPath: ""

  readonly property string pluginDir: {
    var dir = manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
    if (dir) return dir.replace(/^file:\/\//, "").replace(/\/$/, "")
    return Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  }

  // ---- state mirrored from the engine
  property bool connected: false
  property string engineVersion: ""
  property string fatalError: ""
  property string startupError: ""
  property var palette: []
  property var sidebar: ({ inbox: { id: "inbox", name: "Inbox", count: 0 }, projects: [], labels: [] })
  property var view: ({ kind: "project", id: "inbox", name: "Inbox", isInbox: true, count: 0 })
  property var rowList: []
  property ListModel rows: ListModel {}
  property var sync: ({ status: "disabled" })
  // Text size: {fontSize (px, or null for the default), managed (the config file that sets it, or
  // null)}, from `hello` and `setAppearance`.
  property var appearance: ({ fontSize: null, managed: null })
  // The view the UI asked for, sent again when the engine restarts.
  property var requestedView: ({ kind: "project", id: "inbox" })

  signal rowsUpdated()
  signal engineMessage(string message)

  // ---- requests
  property int nextId: 1
  property var callbacks: ({})

  // Sends a request; `callback(ok, resultOrError)` runs when the reply arrives.
  function request(cmd, args, callback) {
    if (!engine.running) {
      if (callback) callback(false, "TodoTim engine is not running")
      return
    }
    var id = nextId++
    var message = { req: id, cmd: cmd }
    if (args) for (var k in args) message[k] = args[k]
    if (callback) callbacks[id] = callback
    engine.write(JSON.stringify(message) + "\n")
  }

  function setView(view) {
    requestedView = view
    request("setView", { view: view })
  }

  function handleLine(line) {
    if (!line) return
    var message
    try { message = JSON.parse(line) } catch (e) {
      console.warn("todotim: unreadable engine output:", line.slice(0, 200))
      return
    }
    if (message.event !== undefined) {
      switch (message.event) {
        case "sidebar": root.sidebar = message.sidebar; break
        case "rows":
          root.view = message.view
          root.rowList = message.rows
          ModelSync.sync(root.rows, message.rows)
          root.rowsUpdated()
          break
        case "sync": root.sync = message.sync; break
        case "fatal": root.fatalError = message.error || "TodoTim engine failed"; break
        case "error": console.warn("todotim engine:", message.error); break
      }
      return
    }
    if (message.re !== undefined) {
      var cb = callbacks[message.re]
      if (cb) {
        delete callbacks[message.re]
        cb(message.ok === true, message.ok === true ? message.result : message.error)
      }
    }
  }

  function hello() {
    fatalError = ""
    request("hello", {}, function(ok, result) {
      if (!ok) return
      root.connected = true
      root.engineVersion = result.version || ""
      root.palette = result.palette || []
      root.startupError = result.startupError || ""
      if (result.appearance) root.appearance = result.appearance
      root.request("setView", { view: root.requestedView })
    })
  }

  // The bundled engine (bin/ in the plugin folder, put there by install.sh), else one on PATH
  // (a package), else $TODOTIM_ENGINE.
  Process {
    id: engine
    command: ["sh", "-c",
      "e=\"${TODOTIM_ENGINE:-}\"; [ -n \"$e\" ] || e=\"$0/bin/todotim-engine\"; [ -x \"$e\" ] || e=todotim-engine; exec \"$e\"",
      root.pluginDir]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(data) { root.handleLine(data) }
    }
    stderr: SplitParser {
      onRead: function(data) { console.warn("todotim-engine:", data) }
    }
    onStarted: root.hello()
    onExited: function(exitCode, exitStatus) {
      root.connected = false
      var cbs = root.callbacks
      root.callbacks = ({})
      for (var id in cbs) cbs[id](false, "TodoTim engine stopped")
      if (exitCode === 127) root.fatalError = "todotim-engine was not found. Run install.sh from the TodoTim release."
      if (!root.stopping) restartTimer.restart()
    }
  }

  property bool stopping: false
  property int restarts: 0

  Timer {
    id: restartTimer
    interval: Math.min(30000, 1000 * Math.pow(2, Math.min(root.restarts, 5)))
    onTriggered: {
      root.restarts++
      engine.running = true
    }
  }

  // A long-lived engine resets its backoff.
  Timer {
    interval: 60000
    running: root.connected
    onTriggered: root.restarts = 0
  }

  Component.onCompleted: engine.running = true
  Component.onDestruction: {
    stopping = true
    engine.running = false
  }
}
