import QtQuick
import "Icons.js" as Icons
import "Markdown.js" as Markdown

// One task in the list: thread indent, sub-task chevron, checkbox, title (inline Markdown), the
// description's first line, and a line of chips (due date, repeat, sub-tasks, labels).
Item {
  id: root
  property var theme
  property var app
  property var row: ({})
  readonly property bool selected: app && app.selectedId === row.id
  readonly property int indent: theme.space(26)
  readonly property bool hasChips: !!row.due || !!row.repeat || row.subTotal > 0 || (row.labels && row.labels.length > 0)

  implicitHeight: Math.max(theme.space(40), body.implicitHeight + theme.space(18))

  Rectangle {
    anchors.fill: parent
    anchors.leftMargin: theme.space(6)
    anchors.rightMargin: theme.space(6)
    radius: theme.radius
    color: root.selected ? theme.cursorFill : mouse.containsMouse ? theme.hover : "transparent"
    Rectangle {
      visible: root.selected
      width: Math.max(2, theme.space(3))
      height: parent.height
      color: theme.cursorEdge
      radius: theme.radius
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    onClicked: root.app.select(root.row.id)
    onDoubleClicked: root.app.openTask(root.row.id)
  }

  // Sub-task chevron
  Item {
    id: chevronBox
    x: theme.space(14) + root.row.depth * root.indent
    width: theme.space(18)
    height: theme.space(40)
    visible: root.row.hasChildren === true
    Text {
      anchors.centerIn: parent
      text: root.row.expanded ? Icons.chevronDown : Icons.chevronRight
      font.family: theme.font
      font.pixelSize: theme.small
      color: chevronMouse.containsMouse ? theme.text : theme.faint
    }
    MouseArea {
      id: chevronMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.app.setTaskCollapsed(root.row.id, root.row.expanded)
    }
  }

  CheckCircle {
    id: check
    theme: root.theme
    x: chevronBox.x + chevronBox.width + theme.space(4)
    y: theme.space(10)
    priority: root.row.priority || 4
    checked: root.row.completed === true
    onToggled: root.app.toggleComplete(root.row.id)
  }

  Column {
    id: body
    x: check.x + check.width + theme.space(10)
    y: theme.space(9)
    width: root.width - x - theme.space(16) - (projectTag.visible ? projectTag.width + theme.space(12) : 0)
    spacing: theme.space(3)

    Text {
      width: parent.width
      text: Markdown.toStyled(root.row.content, root.theme.cyan)
      textFormat: Text.StyledText
      wrapMode: Text.Wrap
      font.family: root.theme.font
      font.pixelSize: root.theme.task
      font.strikeout: root.row.completed === true
      color: root.row.completed ? root.theme.faint : root.theme.text
      linkColor: root.theme.accent
      onLinkActivated: function(link) { root.app.openLink(link) }
      HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor }
    }
    Text {
      width: parent.width
      visible: !!root.row.note
      text: root.row.note || ""
      textFormat: Text.PlainText
      elide: Text.ElideRight
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      color: root.theme.dim
    }
    Flow {
      width: parent.width
      visible: root.hasChips
      spacing: root.theme.space(12)
      Chip {
        theme: root.theme
        visible: !!root.row.due
        icon: Icons.calendar
        text: root.row.due ? root.row.due.label : ""
        color: root.row.completed ? root.theme.faint : root.theme.dueColor(root.row.due ? root.row.due.kind : "")
      }
      Chip {
        theme: root.theme
        visible: !!root.row.repeat
        icon: Icons.repeat
        text: root.row.repeat || ""
      }
      Chip {
        theme: root.theme
        visible: root.row.subTotal > 0
        icon: Icons.subtasks
        text: root.row.subDone + "/" + root.row.subTotal
      }
      Repeater {
        model: root.row.labels || []
        Chip {
          required property var modelData
          theme: root.theme
          icon: Icons.tag
          text: modelData.name
          color: root.row.completed ? root.theme.faint : modelData.color
        }
      }
    }
  }

  Row {
    id: projectTag
    visible: !!root.row.project
    anchors.right: parent.right
    anchors.rightMargin: theme.space(18)
    y: theme.space(11)
    spacing: theme.space(6)
    Rectangle {
      width: theme.space(7); height: width; radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      color: root.theme.projectColor(root.row.project ? root.row.project.color : null)
    }
    Text {
      text: root.row.project ? root.row.project.name : ""
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      color: root.theme.dim
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  Rectangle {
    x: body.x
    anchors.bottom: parent.bottom
    width: root.width - x - theme.space(16)
    height: 1
    color: root.theme.line
  }
}
