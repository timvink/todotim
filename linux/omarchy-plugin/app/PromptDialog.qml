import QtQuick

// Asks for one name (new section, rename section or label). Enter confirms, Esc cancels.
Modal {
  id: root
  property var app
  property string title: ""
  property string confirmText: "Save"
  property var onConfirm: null
  property string error: ""
  cardWidth: 440
  topRatio: 0.24

  function open(options) {
    title = options.title || ""
    confirmText = options.confirmText || "Save"
    onConfirm = options.onConfirm || null
    error = ""
    field.text = options.text || ""
    field.placeholder = options.placeholder || "Name"
    field.focusField()
  }

  function confirm() {
    var text = field.text.trim()
    if (text === "") { error = "Enter a name"; return }
    var cb = onConfirm
    app.closeOverlay("prompt")
    if (cb) cb(text)
  }

  Keys.onEscapePressed: function(event) { root.app.closeOverlay("prompt"); event.accepted = true }
  onDismissed: app.closeOverlay("prompt")

  Text {
    text: root.title
    font.family: root.theme.font
    font.pixelSize: root.theme.body
    font.bold: true
    color: root.theme.text
  }
  Field {
    id: field
    theme: root.theme
    width: parent.width
    onAccepted: root.confirm()
  }
  Text {
    visible: root.error !== ""
    text: root.error
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.theme.red
  }
  Row {
    anchors.right: parent.right
    spacing: root.theme.space(8)
    Btn { theme: root.theme; text: "Cancel"; onClicked: root.app.closeOverlay("prompt") }
    Btn { theme: root.theme; text: root.confirmText; primary: true; onClicked: root.confirm() }
  }
}
