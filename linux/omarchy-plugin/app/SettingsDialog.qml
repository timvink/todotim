import QtQuick
import "Icons.js" as Icons

// CalDAV sync settings and the text size. The password goes to the keyring (Secret Service) through
// the engine. While ~/.todotim.toml has a [sync] table, the sync settings come from there and are
// read-only; likewise the text size while it has `[omarchy] font_size`. A text size change shows at
// once and is saved with Save (Cancel puts the old one back).
Modal {
  id: root
  property var app
  property bool enabledSync: false
  property bool hasPassword: false
  property string managed: ""
  property string status: ""
  property color statusColor: theme.dim
  property bool busy: false
  // Text size in px; 0 is the default (one under the shell's base size).
  property int savedFontSize: 0
  property int pendingFontSize: 0
  property string fontManaged: ""
  readonly property int shownFontSize: pendingFontSize > 0 ? pendingFontSize : theme.defaultFontSize
  cardWidth: 560
  topRatio: 0.12

  readonly property var sync: app.service ? app.service.sync : ({})

  function open() {
    status = ""
    password.text = ""
    var a = app.service ? app.service.appearance : null
    savedFontSize = a && a.fontSize > 0 ? a.fontSize : 0
    pendingFontSize = savedFontSize
    fontManaged = a && a.managed ? a.managed : ""
    app.req("getSyncSettings", {}, function(ok, r) {
      if (!ok) return
      server.text = r.serverURL || ""
      username.text = r.username || ""
      root.enabledSync = r.enabled === true
      root.hasPassword = r.hasPassword === true
      root.managed = r.managed || ""
    })
    server.focusField()
  }

  function values() {
    return { serverURL: server.text.trim(), username: username.text.trim(), password: password.text,
             enabled: enabledSync }
  }

  function test() {
    busy = true
    status = "Connecting…"
    statusColor = theme.dim
    app.req("testConnection", values(), function(ok, r) {
      root.busy = false
      if (!ok) { root.status = r; root.statusColor = root.theme.red; return }
      if (r.error) { root.status = r.error; root.statusColor = root.theme.red }
      else { root.status = "Connected: the calendars are reachable."; root.statusColor = root.theme.green }
    })
  }

  function save() {
    var saveSync = function() {
      root.app.req("configureSync", root.values(), function(ok, r) {
        if (!ok) { root.status = r; root.statusColor = root.theme.red; return }
        root.app.closeOverlay("settings")
      })
    }
    if (fontManaged !== "" || pendingFontSize === savedFontSize) { saveSync(); return }
    app.req("setAppearance", { fontSize: pendingFontSize > 0 ? pendingFontSize : null }, function(ok, r) {
      if (!ok) { root.status = r; root.statusColor = root.theme.red; return }
      if (root.app.service) root.app.service.appearance = r
      root.savedFontSize = root.pendingFontSize
      saveSync()
    })
  }

  function stepFontSize(delta) {
    var next = Math.max(theme.minFontSize, Math.min(theme.maxFontSize, shownFontSize + delta))
    pendingFontSize = next
    app.fontSizePreview = next
  }

  function resetFontSize() {
    pendingFontSize = 0
    app.fontSizePreview = 0
  }

  // Closing (Save, Cancel, Esc, the scrim) ends the preview; after Save the engine's value stays.
  onVisibleChanged: if (!visible) app.fontSizePreview = -1

  Keys.onEscapePressed: function(event) { root.app.closeOverlay("settings"); event.accepted = true }
  onDismissed: app.closeOverlay("settings")

  Text {
    text: "Sync with CalDAV"
    font.family: root.theme.font
    font.pixelSize: root.theme.heading
    font.bold: true
    color: root.theme.text
  }
  Text {
    width: parent.width
    wrapMode: Text.Wrap
    text: root.managed !== ""
      ? "These settings come from " + root.managed + ". Change them there."
      : "Any CalDAV server with task lists works, for example Nextcloud (https://your.cloud/remote.php/dav/ with an app password) or Radicale."
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.theme.dim
  }

  Column {
    width: parent.width
    spacing: root.theme.space(6)
    Text { text: "Server URL"; font.family: root.theme.font; font.pixelSize: root.theme.small; color: root.theme.faint }
    Field {
      id: server
      theme: root.theme
      width: parent.width
      readOnly: root.managed !== ""
      placeholder: "https://your.cloud/remote.php/dav/"
      KeyNavigation.tab: username.input
    }
    Text { text: "Username"; font.family: root.theme.font; font.pixelSize: root.theme.small; color: root.theme.faint }
    Field {
      id: username
      theme: root.theme
      width: parent.width
      readOnly: root.managed !== ""
      KeyNavigation.tab: password.input
    }
    Text { text: "App password"; font.family: root.theme.font; font.pixelSize: root.theme.small; color: root.theme.faint }
    Field {
      id: password
      theme: root.theme
      width: parent.width
      password: true
      placeholder: root.hasPassword ? "Saved in the keyring (type to replace)" : "Stored in the keyring"
      onAccepted: root.save()
    }
  }

  Row {
    spacing: root.theme.space(10)
    Rectangle {
      width: root.theme.space(18)
      height: width
      radius: root.theme.radius
      anchors.verticalCenter: parent.verticalCenter
      color: root.enabledSync ? root.theme.accent : "transparent"
      border.width: 1
      border.color: root.enabledSync ? root.theme.accent : root.theme.lineStrong
      Text {
        anchors.centerIn: parent
        visible: root.enabledSync
        text: Icons.check
        font.family: root.theme.font
        font.pixelSize: root.theme.small
        color: root.theme.bg
      }
      MouseArea {
        anchors.fill: parent
        enabled: root.managed === ""
        cursorShape: Qt.PointingHandCursor
        onClicked: root.enabledSync = !root.enabledSync
      }
    }
    Text {
      text: "Sync this device"
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      color: root.theme.text
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  Text {
    width: parent.width
    visible: text !== ""
    wrapMode: Text.Wrap
    text: root.status !== "" ? root.status
      : root.sync.status === "error" ? (root.sync.message || "Sync failed")
      : root.sync.credentialError ? root.sync.credentialError
      : root.sync.warning ? root.sync.warning
      : root.sync.lastSync ? "Last synced " + new Date(root.sync.lastSync).toLocaleString(Qt.locale(), Locale.ShortFormat) : ""
    textFormat: Text.PlainText
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.status !== "" ? root.statusColor : root.sync.status === "error" ? root.theme.red : root.theme.dim
  }

  Rectangle { width: parent.width; height: 1; color: root.theme.line }

  Item {
    width: parent.width
    height: Math.max(fontLabels.implicitHeight, fontControls.implicitHeight)
    Column {
      id: fontLabels
      anchors.left: parent.left
      anchors.right: fontControls.left
      anchors.rightMargin: root.theme.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: root.theme.space(2)
      Text {
        text: "Text size"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        color: root.theme.text
      }
      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: root.fontManaged !== ""
          ? "Set in " + root.fontManaged + " ([omarchy] font_size). Change it there."
          : root.pendingFontSize > 0 ? "Or set font_size under [omarchy] in ~/.todotim.toml."
          : "Default: one pixel under Omarchy's text size."
        font.family: root.theme.font
        font.pixelSize: root.theme.small
        color: root.theme.dim
      }
    }
    Row {
      id: fontControls
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: root.theme.space(6)
      Btn {
        theme: root.theme
        text: "Default"
        visible: root.fontManaged === "" && root.pendingFontSize > 0
        onClicked: root.resetFontSize()
      }
      Btn {
        theme: root.theme
        text: "\u2212"
        enabledState: root.fontManaged === "" && root.shownFontSize > root.theme.minFontSize
        onClicked: root.stepFontSize(-1)
      }
      Text {
        width: root.theme.space(48)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
        text: root.shownFontSize + " px"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        color: root.fontManaged !== "" ? root.theme.dim : root.theme.text
      }
      Btn {
        theme: root.theme
        text: "+"
        enabledState: root.fontManaged === "" && root.shownFontSize < root.theme.maxFontSize
        onClicked: root.stepFontSize(1)
      }
    }
  }

  Item {
    width: parent.width
    height: saveButton.height
    Btn {
      theme: root.theme
      text: root.busy ? "Testing…" : "Test connection"
      enabledState: !root.busy
      onClicked: root.test()
    }
    Row {
      anchors.right: parent.right
      spacing: root.theme.space(8)
      Btn { theme: root.theme; text: "Cancel"; onClicked: root.app.closeOverlay("settings") }
      Btn { id: saveButton; theme: root.theme; text: "Save"; primary: true; onClicked: root.save() }
    }
  }
}
