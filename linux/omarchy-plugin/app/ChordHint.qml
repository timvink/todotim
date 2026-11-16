import QtQuick

// The keys that can follow `g`, like Neovim's which-key, while a chord waits (`app.chordHint`).
// Not a Modal: it never takes focus, so the second key still reaches the list or the task view.
Rectangle {
  id: root
  property var theme
  property var app
  // In the task view only `g x` and `g p` exist.
  property bool inDetail: false

  readonly property var items: {
    var x = { key: "x", text: "Open link", enabled: app.chordHasLink }
    var p = { key: "p", text: "Go to project", enabled: true }
    if (inDetail) return [x, p]
    return [{ key: "g", text: "First task in section", enabled: true }, { key: "i", text: "Inbox", enabled: true },
            p, { key: "s", text: "Search", enabled: true }, x]
  }

  visible: app.chordHint
  z: 1000
  width: column.implicitWidth + theme.space(28)
  height: column.implicitHeight + theme.space(20)
  radius: theme.radius
  color: theme.raised
  border.width: 1
  border.color: theme.popupBorder

  Column {
    id: column
    anchors.centerIn: parent
    spacing: root.theme.space(6)
    Text {
      text: "g"
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      font.bold: true
      color: root.theme.accent
    }
    Repeater {
      model: root.items
      Row {
        id: item
        required property var modelData
        spacing: root.theme.space(12)
        Text {
          width: root.theme.space(12)
          text: item.modelData.key
          font.family: root.theme.font
          font.pixelSize: root.theme.body
          font.bold: true
          color: item.modelData.enabled ? root.theme.raisedText : root.theme.faint
        }
        Text {
          text: item.modelData.text
          font.family: root.theme.font
          font.pixelSize: root.theme.body
          color: item.modelData.enabled ? root.theme.raisedText : root.theme.faint
        }
      }
    }
  }
}
