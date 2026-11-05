import QtQuick
import "Icons.js" as Icons

// Quick Add: one line in Todoist syntax ("Renew passport next friday p1 @errands #Home /Admin").
// The engine parses every keystroke (TodoCore's QuickAddParser); each recognised token gets a
// fill in the color of what it means, and the line below shows where the task will go.
Modal {
  id: root
  property var app
  cardWidth: 680
  topRatio: 0.14

  property var context: ({})
  property var preview: null
  property string error: ""
  property int parseSeq: 0
  property bool busy: false

  function open(ctx) {
    context = ctx || {}
    error = ""
    preview = null
    description.text = ""
    input.text = context.text || ""
    input.forceActiveFocus()
    input.cursorPosition = input.text.length
    parse()
  }

  function args() {
    return { text: input.text, projectId: context.projectId || null, sectionId: context.sectionId || null,
             parentId: context.parentId || null }
  }

  function parse() {
    var seq = ++parseSeq
    app.req("parseQuickAdd", args(), function(ok, result) {
      if (seq === root.parseSeq && ok) root.preview = result
    })
  }

  function submit() {
    if (busy) return
    if (!preview || !preview.content) { error = "Type a task name"; return }
    busy = true
    var a = args()
    a.description = description.text
    a.atTop = context.atTop === true
    app.req("quickAdd", a, function(ok, result) {
      root.busy = false
      if (!ok) { root.error = result; return }
      root.app.taskAdded(result)
    })
  }

  Keys.onEscapePressed: function(event) { root.app.closeOverlay("quickAdd"); event.accepted = true }
  onDismissed: app.closeOverlay("quickAdd")

  // Where the task goes.
  Row {
    spacing: root.theme.space(8)
    Text {
      text: "Add to"
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      color: root.theme.faint
      anchors.verticalCenter: parent.verticalCenter
    }
    Rectangle {
      width: root.theme.space(8); height: width; radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      color: root.theme.projectColor(root.preview ? root.preview.project.color : null)
    }
    Text {
      text: {
        if (!root.preview) return ""
        var s = root.preview.project.name
        if (root.preview.section) s += "  /  " + root.preview.section.name
        if (root.preview.parent) s += "  /  " + root.preview.parent.content
        return s
      }
      textFormat: Text.PlainText
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      color: root.theme.dim
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // The line, with token fills drawn behind the text.
  Rectangle {
    width: parent.width
    height: Math.round(root.theme.task * 2.6)
    radius: root.theme.radius
    color: root.theme.field
    border.width: 1
    border.color: input.activeFocus ? root.theme.accent : root.theme.line

    Item {
      id: lineBox
      anchors.fill: parent
      anchors.leftMargin: root.theme.space(12)
      anchors.rightMargin: root.theme.space(12)
      clip: true

      Repeater {
        model: root.preview && root.preview.tokens ? root.preview.tokens : []
        Rectangle {
          required property var modelData
          readonly property var a: input.text.length >= 0 && input.cursorPosition >= 0 ? input.positionToRectangle(modelData.start) : Qt.rect(0, 0, 0, 0)
          readonly property var b: input.text.length >= 0 && input.cursorPosition >= 0 ? input.positionToRectangle(modelData.end) : Qt.rect(0, 0, 0, 0)
          readonly property color tone: {
            var p = root.preview
            switch (modelData.kind) {
              case "date": return root.theme.dueColor(p && p.due ? p.due.kind : "later")
              case "priority": return root.theme.priorityColor(p ? p.priority : 4)
              case "label": return modelData.color || root.theme.dim
              default: return modelData.known ? root.theme.projectColor(modelData.color) : root.theme.yellow
            }
          }
          x: input.x + a.x - 2
          width: Math.max(0, b.x - a.x) + 4
          y: input.y + a.y
          height: a.height
          radius: Math.max(2, root.theme.radius)
          color: root.theme.alpha(tone, 0.24)
          border.width: 1
          border.color: root.theme.alpha(tone, 0.5)
        }
      }

      TextInput {
        id: input
        anchors.fill: parent
        verticalAlignment: TextInput.AlignVCenter
        font.family: root.theme.font
        font.pixelSize: root.theme.task
        color: root.theme.text
        selectionColor: root.theme.selection
        selectedTextColor: root.theme.text
        selectByMouse: true
        onTextChanged: { root.error = ""; root.parse() }
        onAccepted: root.submit()
        KeyNavigation.tab: description.input
      }
      Text {
        anchors.fill: input
        verticalAlignment: Text.AlignVCenter
        visible: input.text === ""
        text: "Task name, e.g. Renew passport next friday p1 @errands #Home"
        elide: Text.ElideRight
        font.family: root.theme.font
        font.pixelSize: root.theme.task
        color: root.theme.faint
      }
    }
  }

  // What was recognised.
  Flow {
    width: parent.width
    spacing: root.theme.space(14)
    visible: !!root.preview && (root.preview.due || root.preview.noDate || root.preview.priority || root.preview.labels.length > 0)
    Chip {
      theme: root.theme
      visible: !!(root.preview && (root.preview.due || root.preview.noDate))
      icon: Icons.calendar
      text: root.preview && root.preview.due ? root.preview.due.label : "No date"
      color: root.theme.dueColor(root.preview && root.preview.due ? root.preview.due.kind : "later")
    }
    Chip {
      theme: root.theme
      visible: !!(root.preview && root.preview.priority)
      icon: Icons.flag
      text: root.preview && root.preview.priority ? "P" + root.preview.priority : ""
      color: root.theme.priorityColor(root.preview ? root.preview.priority : 4)
    }
    Repeater {
      model: root.preview ? root.preview.labels : []
      Chip {
        required property var modelData
        theme: root.theme
        icon: Icons.tag
        text: modelData
      }
    }
  }

  Text {
    width: parent.width
    visible: text !== ""
    wrapMode: Text.Wrap
    text: {
      if (root.error) return root.error
      if (!root.preview) return ""
      if (root.preview.unknownProject) return "No project named “" + root.preview.unknownProject + "”: the task goes to " + root.preview.project.name + "."
      if (root.preview.unknownSection) return "No section named “" + root.preview.unknownSection + "” in " + root.preview.project.name + "."
      return ""
    }
    textFormat: Text.PlainText
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.error ? root.theme.red : root.theme.yellow
  }

  Field {
    id: description
    theme: root.theme
    width: parent.width
    placeholder: "Description"
    fontSize: root.theme.body
    onAccepted: root.submit()
    KeyNavigation.backtab: input
  }

  Item {
    width: parent.width
    height: addButton.height
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "#project  /section  @label  p1–p4  dates like “tomorrow” or “next fri”"
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      color: root.theme.faint
      elide: Text.ElideRight
      width: parent.width - addButton.width - cancelButton.width - root.theme.space(24)
    }
    Btn {
      id: cancelButton
      theme: root.theme
      text: "Cancel"
      anchors.right: addButton.left
      anchors.rightMargin: root.theme.space(8)
      onClicked: root.app.closeOverlay("quickAdd")
    }
    Btn {
      id: addButton
      theme: root.theme
      anchors.right: parent.right
      text: "Add task"
      primary: true
      enabledState: !!root.preview && root.preview.content !== ""
      onClicked: root.submit()
    }
  }
}
