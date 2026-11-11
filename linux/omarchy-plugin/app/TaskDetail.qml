import QtQuick
import "Icons.js" as Icons
import "Markdown.js" as Markdown

// The task view: title, description, due date, priority, labels, project and sub-tasks.
// Outside the text fields the list's keys work on this task (e, 1–4, t, @, m, j/k for the
// next or previous task, Delete); Enter edits the title; Esc saves and closes.
Modal {
  id: root
  property var app
  cardWidth: 720
  topRatio: 0.08

  property string taskId: ""
  property var task: null

  function open(id) {
    taskId = id
    task = null
    title.text = ""
    notes.text = ""
    load()
    root.forceActiveFocus()
  }

  function load() {
    var id = taskId
    app.req("getTask", { id: id }, function(ok, result) {
      if (id !== root.taskId) return
      if (!ok) { root.app.closeOverlay("detail"); return }
      root.task = result
      if (!title.activeFocus) title.text = result.content
      if (!notes.activeFocus) notes.text = result.description
    })
  }

  // Sends title and description edits; returns whether anything was sent.
  function save() {
    if (!task) return false
    var args = { id: taskId }
    var changed = false
    var t = title.text.trim()
    if (t !== "" && t !== task.content) { args.content = t; changed = true }
    if (notes.text !== task.description) { args.description = notes.text; changed = true }
    if (changed) app.req("updateTask", args, function(ok, result) { if (ok && result.id === root.taskId) root.task = result })
    return changed
  }

  function close() {
    save()
    app.closeOverlay("detail")
  }

  function addSubtask() {
    save()
    app.openQuickAdd({ parentId: taskId, projectId: task ? task.projectId : null })
  }

  function stopEditing() {
    save()
    root.forceActiveFocus()
  }

  Connections {
    target: root.app.service
    function onRowsUpdated() { if (root.visible && root.taskId) root.load() }
  }

  onDismissed: close()

  Keys.onPressed: function(event) {
    if (title.activeFocus || notes.activeFocus) return
    var ctrl = event.modifiers & Qt.ControlModifier
    var t = event.text
    if (event.key === Qt.Key_Escape) close()
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { title.forceActiveFocus(); title.cursorPosition = title.text.length }
    else if (t === "j" || event.key === Qt.Key_Down) { save(); app.moveDetail(1) }
    else if (t === "k" || event.key === Qt.Key_Up) { save(); app.moveDetail(-1) }
    else if (t === "e" || t === "x" || (ctrl && (event.key === Qt.Key_Return))) app.toggleComplete(taskId)
    else if (t >= "1" && t <= "4" && !ctrl) app.setPriority(taskId, Number(t))
    else if (t === "t") app.openDatePicker(taskId)
    else if (t === "@") app.openLabelPicker(taskId)
    else if (t === "m" || t === "v") app.openMoveDialog([taskId])
    else if (t === "d") notes.forceActiveFocus()
    else if (t === "a") addSubtask()
    else if (t === "u" && !ctrl) app.undoFromToast()
    else if (event.key === Qt.Key_Delete || (ctrl && event.key === Qt.Key_Backspace)) app.confirmDelete(taskId)
    else return
    event.accepted = true
  }

  // Breadcrumb and close button
  Item {
    width: parent.width
    height: closeText.height
    Row {
      spacing: root.theme.space(8)
      anchors.verticalCenter: parent.verticalCenter
      Rectangle {
        width: root.theme.space(8); height: width; radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.theme.projectColor(root.task && root.task.project ? root.task.project.color : null)
      }
      Text {
        text: {
          if (!root.task) return ""
          var s = root.task.project ? root.task.project.name : ""
          if (root.task.section) s += "  /  " + root.task.section
          if (root.task.parent) s += "  /  " + root.task.parent.content
          return s
        }
        textFormat: Text.PlainText
        font.family: root.theme.font
        font.pixelSize: root.theme.small
        color: root.theme.dim
        anchors.verticalCenter: parent.verticalCenter
        MouseArea {
          anchors.fill: parent
          enabled: !!(root.task && root.task.parent)
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: { root.save(); root.open(root.task.parent.id) }
        }
      }
    }
    Text {
      id: closeText
      anchors.right: parent.right
      text: Icons.close
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      color: closeMouse.containsMouse ? root.theme.text : root.theme.faint
      MouseArea { id: closeMouse; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; onClicked: root.close() }
    }
  }

  // Checkbox and title
  Item {
    width: parent.width
    height: Math.max(check.height, title.contentHeight) + root.theme.space(4)
    CheckCircle {
      id: check
      theme: root.theme
      y: root.theme.space(3)
      priority: root.task ? root.task.priority : 4
      checked: !!(root.task && root.task.completed)
      onToggled: root.app.toggleComplete(root.taskId)
    }
    TextEdit {
      id: title
      x: check.width + root.theme.space(12)
      width: parent.width - x
      wrapMode: TextEdit.Wrap
      font.family: root.theme.font
      font.pixelSize: root.theme.heading
      font.bold: true
      color: root.theme.text
      selectionColor: root.theme.selection
      selectedTextColor: root.theme.text
      selectByMouse: true
      Keys.onReturnPressed: function(event) { root.stopEditing(); event.accepted = true }
      Keys.onEnterPressed: function(event) { root.stopEditing(); event.accepted = true }
      Keys.onEscapePressed: function(event) { root.stopEditing(); event.accepted = true }
      Keys.onTabPressed: function(event) { root.save(); notes.forceActiveFocus(); event.accepted = true }
      onActiveFocusChanged: if (!activeFocus) root.save()
    }
  }

  // Description: rendered Markdown, edited as plain text.
  Rectangle {
    width: parent.width
    height: Math.min(root.theme.space(220), Math.max(root.theme.space(64), notesFlick.contentHeight + root.theme.space(16)))
    radius: root.theme.radius
    color: notes.activeFocus ? root.theme.field : "transparent"
    border.width: 1
    border.color: notes.activeFocus ? root.theme.accent : root.theme.line

    Flickable {
      id: notesFlick
      anchors.fill: parent
      anchors.margins: root.theme.space(8)
      contentHeight: Math.max(notes.contentHeight, rendered.contentHeight)
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      TextEdit {
        id: notes
        width: notesFlick.width
        wrapMode: TextEdit.Wrap
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        color: root.theme.text
        selectionColor: root.theme.selection
        selectedTextColor: root.theme.text
        selectByMouse: true
        opacity: activeFocus ? 1 : 0
        Keys.onEscapePressed: function(event) { root.stopEditing(); event.accepted = true }
        Keys.onBacktabPressed: function(event) { root.save(); title.forceActiveFocus(); event.accepted = true }
        onActiveFocusChanged: if (!activeFocus) root.save()
        onCursorRectangleChanged: {
          if (cursorRectangle.y < notesFlick.contentY) notesFlick.contentY = cursorRectangle.y
          else if (cursorRectangle.y + cursorRectangle.height > notesFlick.contentY + notesFlick.height)
            notesFlick.contentY = cursorRectangle.y + cursorRectangle.height - notesFlick.height
        }
      }
      Text {
        id: rendered
        width: notesFlick.width
        visible: !notes.activeFocus
        wrapMode: Text.Wrap
        textFormat: Text.StyledText
        text: notes.text === "" ? "" : Markdown.toStyled(notes.text, root.theme.cyan)
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        color: root.theme.text
        linkColor: root.theme.accent
        onLinkActivated: function(link) { root.app.openLink(link) }
      }
      Text {
        visible: notes.text === "" && !notes.activeFocus
        text: Icons.note + "  Description   d"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        color: root.theme.faint
      }
      MouseArea {
        anchors.fill: parent
        visible: !notes.activeFocus
        cursorShape: rendered.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor
        onClicked: function(mouse) {
          var link = rendered.linkAt(mouse.x, mouse.y)
          if (link) root.app.openLink(link)
          else notes.forceActiveFocus()
        }
      }
    }
  }

  // Properties
  Flow {
    width: parent.width
    spacing: root.theme.space(8)

    PropButton {
      theme: root.theme
      icon: Icons.calendar
      text: root.task && root.task.due ? root.task.due.label : "No date"
      tone: root.task && root.task.due ? root.theme.dueColor(root.task.due.kind) : root.theme.dim
      key: "t"
      onClicked: root.app.openDatePicker(root.taskId)
    }
    PropButton {
      theme: root.theme
      icon: Icons.flag
      text: root.task ? (root.task.priority < 4 ? "Priority " + root.task.priority : "No priority") : ""
      tone: root.task && root.task.priority < 4 ? root.theme.priorityColor(root.task.priority) : root.theme.dim
      key: "1–4"
      onClicked: root.app.openPriorityPicker(root.taskId)
    }
    PropButton {
      theme: root.theme
      icon: Icons.tag
      text: root.task && root.task.labels.length > 0 ? root.task.labels.map(function(l) { return l.name }).join(", ") : "Labels"
      key: "@"
      onClicked: root.app.openLabelPicker(root.taskId)
    }
    PropButton {
      theme: root.theme
      icon: Icons.folder
      text: root.task && root.task.project ? root.task.project.name + (root.task.section ? " / " + root.task.section : "") : ""
      key: "m"
      onClicked: root.app.openMoveDialog([root.taskId])
    }
    PropButton {
      theme: root.theme
      visible: !!(root.task && root.task.repeat)
      icon: Icons.repeat
      text: root.task && root.task.repeat ? root.task.repeat : ""
    }
  }

  // Sub-tasks
  Column {
    width: parent.width
    spacing: 0
    Text {
      text: {
        if (!root.task || root.task.subtasks.length === 0) return "Sub-tasks"
        var done = root.task.subtasks.filter(function(s) { return s.completed }).length
        return "Sub-tasks  " + done + "/" + root.task.subtasks.length
      }
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      font.bold: true
      color: root.theme.faint
      bottomPadding: root.theme.space(4)
    }
    Repeater {
      model: root.task ? root.task.subtasks : []
      Item {
        id: sub
        required property var modelData
        width: parent.width
        height: root.theme.space(34)
        Rectangle {
          anchors.fill: parent
          radius: root.theme.radius
          color: subMouse.containsMouse ? root.theme.hover : "transparent"
        }
        MouseArea {
          id: subMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.save(); root.open(sub.modelData.id) }
        }
        CheckCircle {
          id: subCheck
          theme: root.theme
          x: root.theme.space(6)
          anchors.verticalCenter: parent.verticalCenter
          width: Math.round(root.theme.task * 1.1)
          height: width
          priority: sub.modelData.priority
          checked: sub.modelData.completed
          onToggled: root.app.toggleComplete(sub.modelData.id, true)
        }
        Text {
          x: subCheck.x + subCheck.width + root.theme.space(10)
          width: parent.width - x - root.theme.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: Markdown.toStyled(sub.modelData.content, root.theme.cyan)
          textFormat: Text.StyledText
          elide: Text.ElideRight
          font.family: root.theme.font
          font.pixelSize: root.theme.body
          font.strikeout: sub.modelData.completed
          color: sub.modelData.completed ? root.theme.faint : root.theme.text
        }
      }
    }
    Item {
      width: parent.width
      height: root.theme.space(34)
      Row {
        x: root.theme.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.theme.space(10)
        Text { text: Icons.plus; font.family: root.theme.font; font.pixelSize: root.theme.small; color: addSubMouse.containsMouse ? root.theme.accent : root.theme.faint; anchors.verticalCenter: parent.verticalCenter }
        Text { text: "Add sub-task"; font.family: root.theme.font; font.pixelSize: root.theme.body; color: addSubMouse.containsMouse ? root.theme.accent : root.theme.faint; anchors.verticalCenter: parent.verticalCenter }
      }
      MouseArea {
        id: addSubMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.addSubtask()
      }
    }
  }

  Item {
    width: parent.width
    height: deleteButton.height
    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - deleteButton.width - doneButton.width - root.theme.space(24)
      elide: Text.ElideRight
      text: "Enter edit · a sub-task · e complete · j/k next/previous · Esc close"
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      color: root.theme.faint
    }
    Btn {
      id: deleteButton
      theme: root.theme
      text: "Delete"
      icon: Icons.trash
      danger: true
      anchors.right: doneButton.left
      anchors.rightMargin: root.theme.space(8)
      onClicked: root.app.confirmDelete(root.taskId)
    }
    Btn {
      id: doneButton
      theme: root.theme
      anchors.right: parent.right
      text: "Close"
      onClicked: root.close()
    }
  }
}
