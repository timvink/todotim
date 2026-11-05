import QtQuick
import Quickshell
import "app"

// TodoTim's window. The Omarchy shell summons and hides it (`omarchy-shell shell toggle
// timvink.todotim`, or a key bound to `{ panel = "timvink.todotim" }`); the plugin keeps it loaded
// so it reopens instantly with the same selection. A payload of {"action":"quickAdd"} opens
// Quick Add on top.
Item {
  id: root

  // Injected by the shell.
  property var shell: null
  property var manifest: null
  property var service: null
  property string omarchyPath: ""

  readonly property bool opened: window.visible
  property bool closingFromHost: false

  function open(payloadJson) {
    var payload = {}
    try { payload = payloadJson ? JSON.parse(String(payloadJson)) : {} } catch (e) { payload = {} }
    window.visible = true
    Qt.callLater(function() { view.activate(payload) })
  }

  // Host-initiated close (`shell hide`): the host already knows.
  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  // Esc at the top, Ctrl+W, or the compositor closing the window: tell the shell, so `toggle` opens
  // it again next time.
  function requestClose() {
    var id = manifest && manifest.id ? manifest.id : "timvink.todotim"
    if (shell && typeof shell.hide === "function") shell.hide(id)
    else window.visible = false
  }

  FloatingWindow {
    id: window
    visible: false
    title: "TodoTim"
    color: view.theme.bg
    implicitWidth: 1100
    implicitHeight: 760
    minimumSize: Qt.size(480, 420)

    onVisibleChanged: if (!visible && !root.closingFromHost) root.requestClose()

    AppView {
      id: view
      anchors.fill: parent
      focus: true
      service: root.service
      onCloseRequested: root.requestClose()
    }
  }
}
