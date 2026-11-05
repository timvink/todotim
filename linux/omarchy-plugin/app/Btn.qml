import QtQuick

// A flat text button in the shell's control style; `primary` fills it with the accent.
Rectangle {
  id: root
  property var theme
  property string text: ""
  property string icon: ""
  property bool primary: false
  property bool danger: false
  property bool enabledState: true
  property string hint: ""
  signal clicked()

  readonly property color tone: danger ? theme.red : primary ? theme.accent : theme.fg
  implicitHeight: Math.round(theme.body * 2.3)
  implicitWidth: row.implicitWidth + theme.space(24)
  radius: theme.radius
  opacity: enabledState ? 1 : 0.45
  color: primary ? (mouse.containsMouse ? Qt.lighter(theme.accent, 1.08) : theme.accent)
       : mouse.containsMouse || activeFocus ? theme.alpha(tone, 0.14) : theme.alpha(tone, 0.06)
  border.width: activeFocus ? 1 : 0
  border.color: theme.accent
  activeFocusOnTab: true

  Keys.onReturnPressed: if (enabledState) clicked()
  Keys.onSpacePressed: if (enabledState) clicked()

  Row {
    id: row
    anchors.centerIn: parent
    spacing: root.theme.space(6)
    Text {
      visible: root.icon !== ""
      text: root.icon
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      color: root.primary ? root.theme.bg : root.tone
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      text: root.text
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      font.bold: root.primary
      color: root.primary ? root.theme.bg : root.tone
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      visible: root.hint !== ""
      text: root.hint
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      color: root.primary ? root.theme.alpha(root.theme.bg, 0.7) : root.theme.faint
      anchors.verticalCenter: parent.verticalCenter
    }
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (root.enabledState) root.clicked()
  }
}
