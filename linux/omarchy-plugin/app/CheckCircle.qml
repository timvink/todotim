import QtQuick

// Todoist's round checkbox: ringed in the priority's color, tinted for p1–p3, ticked when done.
Item {
  id: root
  property var theme
  property int priority: 4
  property bool checked: false
  property bool hovered: mouse.containsMouse
  signal toggled()

  readonly property color ring: theme.priorityColor(priority)
  implicitWidth: Math.round(theme.task * 1.3)
  implicitHeight: implicitWidth

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: root.checked ? root.ring
         : root.priority < 4 ? root.theme.alpha(root.ring, root.hovered ? 0.28 : 0.14)
         : root.hovered ? root.theme.alpha(root.theme.fg, 0.08) : "transparent"
    border.width: Math.max(1, Math.round(root.width / 12))
    border.color: root.ring
    Behavior on color { ColorAnimation { duration: root.theme.duration(120) } }
  }
  Text {
    anchors.centerIn: parent
    visible: root.checked || root.hovered
    text: "\uf00c"
    font.family: root.theme.font
    font.pixelSize: Math.round(root.width * 0.55)
    color: root.checked ? root.theme.bg : root.ring
    opacity: root.checked ? 1 : 0.8
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    anchors.margins: -4
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.toggled()
  }
}
