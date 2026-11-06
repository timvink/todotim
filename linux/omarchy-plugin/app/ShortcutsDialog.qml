import QtQuick

// `?`: every shortcut, vim motions first.
Modal {
  id: root
  property var app
  cardWidth: 760
  topRatio: 0.06

  readonly property var groups: [
    { title: "Move", keys: [
      ["j / k", "Next / previous task"], ["J / K", "Select the next / previous task too"], ["gg / G, Home / End", "First / last task of the section"], ["PgUp / PgDn", "Scroll the list"],
      ["h / l, \u2190 / \u2192", "Hide / show sub-tasks"], ["g i", "Go to Inbox"], ["g s", "Search"], ["Ctrl+1 … 9", "Inbox, projects 1–8"],
      ["/", "Search"], ["Esc", "Step back; hides TodoTim at the top"] ] },
    { title: "Add", keys: [
      ["q", "Quick Add"], ["Ctrl+Shift+N", "Add project"], ["a / A", "Add task at the bottom / top of the section"], ["s", "Add section"],
      ["Enter", "Open task; in it, edit the title (d: notes)"] ] },
    { title: "Edit", keys: [
      ["x / e", "Complete or reopen the selected tasks"], ["1 – 4", "Set priority"], ["t", "Set date"], ["@", "Labels"],
      ["v", "Move to project or section"], ["Ctrl+] / Ctrl+[", "Indent / outdent"],
      ["Ctrl+↑ / Ctrl+↓, Ctrl+K / Ctrl+J", "Move up / down"], ["Delete, Ctrl+Backspace", "Delete task"], ["Ctrl+Z", "Undo complete or delete"],
      ["u", "Undo, while the toast shows it"] ] },
    { title: "App", keys: [
      ["Ctrl+Shift+C", "Show or hide completed tasks"], ["Ctrl+R", "Sync now"], ["Ctrl+,", "Sync settings"],
      ["?", "This list"], ["Ctrl+W", "Hide TodoTim"] ] }
  ]

  function open() { root.forceActiveFocus() }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape || event.text === "?" || event.text === "q") {
      app.closeOverlay("shortcuts")
      event.accepted = true
    }
  }
  onDismissed: app.closeOverlay("shortcuts")

  Text {
    text: "Keyboard shortcuts"
    font.family: root.theme.font
    font.pixelSize: root.theme.heading
    font.bold: true
    color: root.theme.text
  }

  Grid {
    width: parent.width
    columns: 2
    columnSpacing: root.theme.space(28)
    rowSpacing: root.theme.space(16)
    Repeater {
      model: root.groups
      Column {
        id: group
        required property var modelData
        width: (root.column.width - root.theme.space(28)) / 2
        spacing: root.theme.space(5)
        Text {
          text: group.modelData.title
          font.family: root.theme.font
          font.pixelSize: root.theme.small
          font.bold: true
          color: root.theme.accent
        }
        Repeater {
          model: group.modelData.keys
          Row {
            id: shortcutRow
            required property var modelData
            width: parent.width
            spacing: root.theme.space(10)
            Text {
              id: keyText
              width: root.theme.space(120)
              wrapMode: Text.Wrap
              text: shortcutRow.modelData[0]
              font.family: root.theme.font
              font.pixelSize: root.theme.small
              font.bold: true
              color: root.theme.text
            }
            Text {
              width: shortcutRow.width - keyText.width - shortcutRow.spacing
              wrapMode: Text.Wrap
              text: shortcutRow.modelData[1]
              font.family: root.theme.font
              font.pixelSize: root.theme.small
              color: root.theme.dim
            }
          }
        }
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.Wrap
    text: "Quick Add understands #Project, /Section, @label, p1–p4 and dates such as today, tomorrow, friday, next week, in 3 days, jan 5 and no date."
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.theme.faint
  }
}
