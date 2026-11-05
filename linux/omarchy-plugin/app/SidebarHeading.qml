// "Projects" / "Labels" in the sidebar, optionally with a + button.
import QtQuick
import "Icons.js" as Icons

Item {
  id: heading
  property var theme
  property string text: ""
  property bool canAdd: false
  signal add()
  width: parent ? parent.width : 0
  height: theme.space(36)
  Text {
    x: theme.space(18)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: theme.space(6)
    text: heading.text
    font.family: theme.font
    font.pixelSize: theme.small
    font.bold: true
    color: theme.faint
  }
  Text {
    visible: heading.canAdd
    anchors.right: parent.right
    anchors.rightMargin: theme.space(18)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: theme.space(6)
    text: Icons.plus
    font.family: theme.font
    font.pixelSize: theme.small
    color: addMouse.containsMouse ? theme.accent : theme.faint
    MouseArea {
      id: addMouse
      anchors.fill: parent
      anchors.margins: -theme.space(6)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: heading.add()
    }
  }
}
