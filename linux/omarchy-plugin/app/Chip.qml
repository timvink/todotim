import QtQuick

// A small inline label: icon + text in one color (due date, repeat, sub-task count, label).
Row {
  id: root
  property var theme
  property string icon: ""
  property string text: ""
  property color color: theme.dim
  property int size: theme.small
  spacing: Math.round(size * 0.35)

  Text {
    visible: root.icon !== ""
    text: root.icon
    font.family: root.theme.font
    font.pixelSize: Math.round(root.size * 0.9)
    color: root.color
    anchors.verticalCenter: parent.verticalCenter
  }
  Text {
    text: root.text
    textFormat: Text.PlainText
    font.family: root.theme.font
    font.pixelSize: root.size
    color: root.color
    anchors.verticalCenter: parent.verticalCenter
  }
}
