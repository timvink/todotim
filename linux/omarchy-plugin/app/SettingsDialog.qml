import QtQuick
import "Icons.js" as Icons

// CalDAV sync settings. The password goes to the keyring (Secret Service) through the engine.
// While ~/.todotim.toml has a [sync] table, the settings come from there and are read-only.
Modal {
  id: root
  property var app
  property bool enabledSync: false
  property bool hasPassword: false
  property string managed: ""
  property string status: ""
  property color statusColor: theme.dim
  property bool busy: false
  cardWidth: 560
  topRatio: 0.12

  readonly property var sync: app.service ? app.service.sync : ({})

  function open() {
    status = ""
    password.text = ""
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
    app.req("configureSync", values(), function(ok, r) {
      if (!ok) { root.status = r; root.statusColor = root.theme.red; return }
      root.app.closeOverlay("settings")
    })
  }

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
