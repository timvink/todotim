import QtQuick

// A centered card over a scrim. Clicking the scrim asks to close. Content goes inside `card`.
FocusScope {
  id: root
  property var theme
  property int cardWidth: 560
  property real topRatio: 0.18
  property bool centerVertically: false
  default property alias content: column.data
  property alias card: card
  property alias column: column
  signal dismissed()

  anchors.fill: parent
  visible: false
  z: 50

  Rectangle {
    anchors.fill: parent
    color: root.theme.scrim
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onClicked: root.dismissed()
      onWheel: function(w) { w.accepted = true }
    }
  }

  Rectangle {
    id: card
    width: Math.min(root.cardWidth, root.width - root.theme.space(40))
    height: column.implicitHeight + 2 * root.theme.space(18)
    x: Math.round((root.width - width) / 2)
    y: root.centerVertically ? Math.round((root.height - height) / 2)
                             : Math.max(root.theme.space(20), Math.round(root.height * root.topRatio))
    radius: root.theme.radius
    color: root.theme.raised
    border.width: 1
    border.color: root.theme.popupBorder
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: function(w) { w.accepted = true } }

    Column {
      id: column
      x: root.theme.space(18)
      y: root.theme.space(18)
      width: parent.width - 2 * root.theme.space(18)
      spacing: root.theme.space(12)
    }
  }
}
