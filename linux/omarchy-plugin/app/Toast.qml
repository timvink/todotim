import QtQuick
import "Icons.js" as Icons

// "1 task completed  Undo  or press U  ×" at the bottom, for six seconds.
Rectangle {
  id: root
  property var theme
  property var app
  property string message: ""
  property bool canUndo: false
  // Whether `u` undoes now: the toast is up and offers Undo.
  readonly property bool offersUndo: visible && canUndo

  function show(text, undo) {
    message = text
    canUndo = undo === true
    visible = true
    hideTimer.restart()
  }
  function hide() { visible = false }

  visible: false
  z: 40
  width: row.implicitWidth + theme.space(32)
  height: theme.space(42)
  radius: theme.radius
  color: theme.raised
  border.width: 1
  border.color: theme.popupBorder
  opacity: visible ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: root.theme.duration(160) } }

  Timer { id: hideTimer; interval: 6000; onTriggered: root.visible = false }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: root.theme.space(16)
    Text {
      text: root.message
      textFormat: Text.PlainText
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      color: root.theme.raisedText
      anchors.verticalCenter: parent.verticalCenter
    }
    Row {
      visible: root.canUndo
      spacing: root.theme.space(8)
      anchors.verticalCenter: parent.verticalCenter
      Text {
        id: undoText
        text: "Undo"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        font.bold: true
        color: undoMouse.containsMouse ? Qt.lighter(root.theme.accent, 1.15) : root.theme.accent
        anchors.verticalCenter: parent.verticalCenter
        MouseArea {
          id: undoMouse
          anchors.fill: parent
          anchors.margins: -6
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.app.undo()
        }
      }
      Text {
        text: "or press U"
        font.family: root.theme.font
        font.pixelSize: root.theme.small
        color: root.theme.faint
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    Text {
      text: Icons.close
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      color: closeMouse.containsMouse ? root.theme.raisedText : root.theme.faint
      anchors.verticalCenter: parent.verticalCenter
      MouseArea {
        id: closeMouse
        anchors.fill: parent
        anchors.margins: -6
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.hide()
      }
    }
  }

  // The Undo button's tooltip.
  Rectangle {
    visible: tipTimer.shown && undoMouse.containsMouse
    x: row.x + undoText.parent.x + undoText.x + (undoText.width - width) / 2
    y: -height - root.theme.space(6)
    width: tip.implicitWidth + root.theme.space(14)
    height: tip.implicitHeight + root.theme.space(8)
    radius: root.theme.radius
    color: root.theme.raised
    border.width: 1
    border.color: root.theme.popupBorder
    Text {
      id: tip
      anchors.centerIn: parent
      text: "Undo (U)"
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      color: root.theme.raisedText
    }
  }
  Timer {
    id: tipTimer
    property bool shown: false
    interval: 600
    running: undoMouse.containsMouse
    onRunningChanged: if (!running) shown = false
    onTriggered: shown = true
  }
}
