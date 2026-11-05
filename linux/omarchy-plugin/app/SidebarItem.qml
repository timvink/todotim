// A row in the sidebar: icon or color dot, name, open-task count.
import QtQuick
import "Icons.js" as Icons

Item {
  id: item
  property var theme
  property string icon: ""
  property color iconColor: theme.dim
  property bool dot: false
  property string label: ""
  property int count: 0
  property bool current: false
  property string shortcut: ""
  signal activated()
  width: parent ? parent.width : 0
  height: theme.space(32)

  Rectangle {
    anchors.fill: parent
    anchors.leftMargin: theme.space(8)
    anchors.rightMargin: theme.space(8)
    radius: theme.radius
    color: item.current ? theme.cursorFill : itemMouse.containsMouse ? theme.hover : "transparent"
  }
  Row {
    x: theme.space(18)
    anchors.verticalCenter: parent.verticalCenter
    spacing: theme.space(10)
    Item {
      width: theme.space(16)
      height: theme.space(16)
      anchors.verticalCenter: parent.verticalCenter
      Rectangle {
        visible: item.dot
        anchors.centerIn: parent
        width: theme.space(9); height: width; radius: width / 2
        color: item.iconColor
      }
      Text {
        visible: !item.dot
        anchors.centerIn: parent
        text: item.icon
        font.family: theme.font
        font.pixelSize: theme.body
        color: item.iconColor
      }
    }
    Text {
      width: item.width - theme.space(100)
      text: item.label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      font.family: theme.font
      font.pixelSize: theme.body
      color: item.current ? theme.text : theme.alpha(theme.text, 0.88)
      anchors.verticalCenter: parent.verticalCenter
    }
  }
  Text {
    anchors.right: parent.right
    anchors.rightMargin: theme.space(20)
    anchors.verticalCenter: parent.verticalCenter
    text: item.count > 0 ? String(item.count) : ""
    font.family: theme.font
    font.pixelSize: theme.small
    color: theme.faint
  }
  MouseArea {
    id: itemMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: item.activated()
  }
}
