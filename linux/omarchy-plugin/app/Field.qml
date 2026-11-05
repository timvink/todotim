import QtQuick

// A single-line text field: the input plus a placeholder, in the shell's field style.
Rectangle {
  id: root
  property var theme
  property alias text: input.text
  property alias input: input
  property string placeholder: ""
  property bool password: false
  property bool readOnly: false
  property int fontSize: theme.body
  readonly property bool fieldFocused: input.activeFocus
  signal accepted()

  implicitHeight: Math.round(fontSize * 2.4)
  implicitWidth: 240
  radius: theme.radius
  color: theme.field
  border.width: 1
  border.color: input.activeFocus ? theme.accent : theme.line
  opacity: readOnly ? 0.7 : 1

  function focusField() { input.forceActiveFocus(); input.selectAll() }

  TextInput {
    id: input
    anchors.fill: parent
    anchors.leftMargin: root.theme.space(10)
    anchors.rightMargin: root.theme.space(10)
    verticalAlignment: TextInput.AlignVCenter
    font.family: root.theme.font
    font.pixelSize: root.fontSize
    color: root.theme.text
    selectionColor: root.theme.selection
    selectedTextColor: root.theme.text
    selectByMouse: true
    clip: true
    readOnly: root.readOnly
    echoMode: root.password ? TextInput.Password : TextInput.Normal
    onAccepted: root.accepted()
  }
  Text {
    anchors.fill: input
    verticalAlignment: Text.AlignVCenter
    visible: input.text === "" && !input.inputMethodComposing
    text: root.placeholder
    font.family: root.theme.font
    font.pixelSize: root.fontSize
    color: root.theme.faint
    elide: Text.ElideRight
  }
}
