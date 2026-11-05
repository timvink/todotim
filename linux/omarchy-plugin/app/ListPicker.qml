import QtQuick
import "Icons.js" as Icons

// A keyboard picker: an optional filter field over a list. ↑/↓ (or Ctrl+J/K) move, Enter picks,
// Esc closes. Used for dates, labels, moving a task, priorities and menus.
Modal {
  id: root
  property var app
  property string name: ""
  property string title: ""
  property string placeholder: "Filter"
  property bool showField: true
  property bool filterItems: true
  // Enter with text in the field submits the text (the date picker), not the current item.
  property bool preferText: false
  // [{ key, text, icon, color, dot, indent, checked, hint, danger }]
  property var items: []
  property string note: ""
  property color noteColor: theme.dim
  property int current: 0
  readonly property alias text: field.text
  readonly property var shown: {
    if (!filterItems || field.text.trim() === "") return items
    var q = field.text.trim().toLowerCase()
    return items.filter(function(it) { return it.always || String(it.text).toLowerCase().indexOf(q) >= 0 })
  }
  signal picked(var item)
  signal submitted(string text)

  cardWidth: 460
  topRatio: 0.2

  function open(initialText) {
    field.text = initialText || ""
    current = 0
    if (showField) field.input.forceActiveFocus()
    else root.forceActiveFocus()
  }

  function moveCurrent(delta) {
    if (shown.length === 0) return
    current = Math.max(0, Math.min(shown.length - 1, current + delta))
    listView.positionViewAtIndex(current, ListView.Contain)
  }

  function clearText() { field.text = "" }

  function accept() {
    if (preferText && field.text.trim() !== "") { submitted(field.text); return }
    if (shown.length > 0 && current < shown.length) picked(shown[current])
    else submitted(field.text)
  }

  onShownChanged: if (current >= shown.length) current = Math.max(0, shown.length - 1)
  onDismissed: app.closeOverlay(name)

  Keys.onPressed: function(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Escape) { app.closeOverlay(name); event.accepted = true }
    else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J) || (!showField && event.text === "j")) { moveCurrent(1); event.accepted = true }
    else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K) || (!showField && event.text === "k")) { moveCurrent(-1); event.accepted = true }
    else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !field.fieldFocused) { accept(); event.accepted = true }
    else if (!showField && event.key === Qt.Key_Space) { accept(); event.accepted = true }
  }

  Text {
    visible: root.title !== ""
    text: root.title
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    font.bold: true
    color: root.theme.faint
  }

  Field {
    id: field
    theme: root.theme
    visible: root.showField
    width: parent.width
    placeholder: root.placeholder
    onTextChanged: root.current = 0
    onAccepted: root.accept()
  }

  Text {
    width: parent.width
    visible: root.note !== ""
    text: root.note
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.noteColor
  }

  ListView {
    id: listView
    width: parent.width
    height: Math.min(contentHeight, root.theme.space(34) * 9)
    clip: true
    interactive: contentHeight > height
    boundsBehavior: Flickable.StopAtBounds
    model: root.shown
    delegate: Rectangle {
      id: option
      required property var modelData
      required property int index
      width: listView.width
      height: root.theme.space(34)
      radius: root.theme.radius
      color: index === root.current ? root.theme.cursorFill : optionMouse.containsMouse ? root.theme.hover : "transparent"
      Row {
        x: root.theme.space(10) + (option.modelData.indent || 0) * root.theme.space(20)
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.theme.space(10)
        Item {
          width: root.theme.space(16)
          height: root.theme.space(16)
          anchors.verticalCenter: parent.verticalCenter
          Rectangle {
            visible: option.modelData.dot === true
            anchors.centerIn: parent
            width: root.theme.space(9); height: width; radius: width / 2
            color: option.modelData.color || root.theme.accent
          }
          Text {
            visible: option.modelData.dot !== true
            anchors.centerIn: parent
            text: option.modelData.checked === true ? Icons.check : (option.modelData.icon || "")
            font.family: root.theme.font
            font.pixelSize: root.theme.body
            color: option.modelData.checked === true ? root.theme.accent : (option.modelData.color || root.theme.dim)
          }
        }
        Text {
          text: option.modelData.text
          textFormat: Text.PlainText
          font.family: root.theme.font
          font.pixelSize: root.theme.body
          color: option.modelData.danger ? root.theme.red : root.theme.text
          anchors.verticalCenter: parent.verticalCenter
        }
      }
      Text {
        anchors.right: parent.right
        anchors.rightMargin: root.theme.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: option.modelData.hint || ""
        textFormat: Text.PlainText
        font.family: root.theme.font
        font.pixelSize: root.theme.small
        color: option.modelData.hintColor || root.theme.faint
      }
      MouseArea {
        id: optionMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.current = option.index; root.accept() }
      }
    }
  }

  Text {
    visible: root.shown.length === 0 && root.items.length > 0
    text: "No matches"
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.theme.faint
  }
}
