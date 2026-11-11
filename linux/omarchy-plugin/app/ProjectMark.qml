import QtQuick
import "Icons.js" as Icons

// A project's mark: its color dot, or the inbox tray (in the accent) for the Inbox.
Item {
  id: root
  property var theme
  property color color: "transparent"
  property bool isInbox: false
  // The dot's diameter; the tray glyph is drawn at about the same visual size.
  property real size: theme.space(9)
  property real glyphSize: theme.small
  implicitWidth: isInbox ? tray.implicitWidth : size
  implicitHeight: Math.max(size, isInbox ? tray.implicitHeight : 0)

  Rectangle {
    visible: !root.isInbox
    anchors.centerIn: parent
    width: root.size; height: width; radius: width / 2
    color: root.color
  }
  Text {
    id: tray
    visible: root.isInbox
    anchors.centerIn: parent
    text: Icons.inbox
    textFormat: Text.PlainText
    font.family: root.theme.font
    font.pixelSize: root.glyphSize
    color: root.theme.accent
  }
}
