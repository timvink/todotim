import QtQuick

// Confirms a destructive action. Enter confirms, Esc cancels.
Modal {
  id: root
  property var app
  property string title: ""
  property string message: ""
  property string confirmText: "Delete"
  property var onConfirm: null
  cardWidth: 460
  topRatio: 0.26

  function open(options) {
    title = options.title || ""
    message = options.message || ""
    confirmText = options.confirmText || "Delete"
    onConfirm = options.onConfirm || null
    root.forceActiveFocus()
  }

  function confirm() {
    var cb = onConfirm
    app.closeOverlay("confirm")
    if (cb) cb()
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape || event.text === "n") { app.closeOverlay("confirm"); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.text === "y") { confirm(); event.accepted = true }
  }
  onDismissed: app.closeOverlay("confirm")

  Text {
    width: parent.width
    text: root.title
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    font.family: root.theme.font
    font.pixelSize: root.theme.body
    font.bold: true
    color: root.theme.text
  }
  Text {
    width: parent.width
    visible: root.message !== ""
    text: root.message
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.theme.dim
  }
  Row {
    anchors.right: parent.right
    spacing: root.theme.space(8)
    Btn { theme: root.theme; text: "Cancel"; hint: "Esc"; onClicked: root.app.closeOverlay("confirm") }
    Btn { theme: root.theme; text: root.confirmText; hint: "Enter"; danger: true; onClicked: root.confirm() }
  }
}
