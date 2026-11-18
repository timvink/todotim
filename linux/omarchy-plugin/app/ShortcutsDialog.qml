import QtQuick

// `?`: every shortcut, vim motions first.
Modal {
  id: root
  property var app
  cardWidth: 760
  topRatio: 0.06

  readonly property var groups: [
    { title: "Move", keys: [
      ["j / k", "Next / previous task"], ["Shift+j / Shift+k", "Select the next / previous task too"],
      ["gg / Shift+g, Home / End", "First / last task of the section"], ["{ / }", "Previous / next section"], ["PgUp / PgDn", "Scroll the list"],
      ["h / l, \u2190 / \u2192", "Hide / show sub-tasks"], ["g i", "Go to Inbox"], ["g p", "Go to a project (type to search)"], ["g s", "Search"],
      ["g (wait)", "Show what can follow g"], ["Ctrl+1 … 9", "Inbox, projects 1–8"],
      ["/", "Search"], ["Esc", "Step back; hides TodoTim at the top"] ] },
    { title: "Add", keys: [
      ["q", "Quick Add"], ["Ctrl+Shift+n", "Add project"], ["a", "Add a sub-task to the selected task, else a task at the bottom"],
      ["Shift+a", "Add task at the top of the section"], ["s", "Add section"],
      ["Enter", "Open task; in it, edit the title (d: notes, a: add sub-task)"] ] },
    { title: "Edit", keys: [
      ["x / e", "Complete or reopen the selected tasks"], ["g x", "Open the task's first link in the browser"], ["1 – 3", "Set priority"], ["0", "Remove priority"], ["t", "Set date"], ["@", "Labels"],
      ["m / v", "Move to a section, project or task"], ["Ctrl+] / Ctrl+[", "Indent / outdent"],
      ["Ctrl+↑ / Ctrl+↓, Ctrl+k / Ctrl+j", "Move up / down"], ["Delete, Ctrl+Backspace", "Delete task"],
      ["Ctrl+a", "Select every task in the list"], ["y, Ctrl+c", "Copy the selected tasks' titles"],
      ["Ctrl+z", "Undo complete, delete or move"], ["u", "Undo, while the toast shows it"] ] },
    { title: "App", keys: [
      ["Ctrl+Shift+c", "Show or hide completed tasks"], ["Ctrl+r", "Sync now"], ["Ctrl+,", "Sync settings"],
      ["?", "This list"], ["Ctrl+w", "Hide TodoTim"] ] }
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
