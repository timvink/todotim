import QtQuick

// A property of the task view (date, priority, labels, project): icon, value, shortcut.
Rectangle {
  id: prop
  property var theme
  property string icon: ""
  property string text: ""
  property string key: ""
  property color tone: theme.dim
  signal clicked()
  height: theme.space(30)
  width: propRow.implicitWidth + theme.space(20)
  radius: theme.radius
  color: propMouse.containsMouse ? theme.hover : theme.alpha(theme.fg, 0.04)
  border.width: 1
  border.color: theme.line
  Row {
    id: propRow
    anchors.centerIn: parent
    spacing: theme.space(7)
    Text { text: prop.icon; font.family: theme.font; font.pixelSize: theme.small; color: prop.tone; anchors.verticalCenter: parent.verticalCenter }
    Text { text: prop.text; textFormat: Text.PlainText; font.family: theme.font; font.pixelSize: theme.small; color: prop.tone === theme.dim ? theme.text : prop.tone; anchors.verticalCenter: parent.verticalCenter }
    Text { text: prop.key; font.family: theme.font; font.pixelSize: theme.small; color: theme.faint; anchors.verticalCenter: parent.verticalCenter }
  }
  MouseArea { id: propMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: prop.clicked() }
}
