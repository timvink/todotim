import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "app/Icons.js" as Icons

// A check mark and the Inbox's open-task count in the bar; click toggles TodoTim, right-click
// opens Quick Add. The count comes from the TodoTim service when the bar can reach it.
BarWidget {
  id: root
  moduleName: "timvink.todotim"

  readonly property var service: {
    var s = bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("timvink.todotim") : null
    return s || null
  }
  readonly property int count: service && service.sidebar && service.sidebar.inbox ? service.sidebar.inbox.count : 0
  readonly property bool syncError: !!(service && service.sync && service.sync.status === "error")
  readonly property color foreground: bar ? bar.barForeground || bar.foreground : Commons.Color.foreground

  implicitWidth: vertical ? barSize : row.implicitWidth + Style.space(14)
  implicitHeight: vertical ? row.implicitHeight + Style.space(10) : barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(5)
    Text {
      text: Icons.check
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      color: root.syncError ? Commons.Color.urgent : root.foreground
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      visible: root.count > 0 && !root.vertical
      text: String(root.count)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      color: root.foreground
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      if (!root.bar || typeof root.bar.run !== "function") return
      if (mouse.button === Qt.RightButton)
        root.bar.run("omarchy-shell shell summon timvink.todotim '{\"action\":\"quickAdd\"}'")
      else
        root.bar.run("omarchy-shell shell toggle timvink.todotim")
    }
  }
}
