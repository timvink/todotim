import QtQuick
import "Icons.js" as Icons

// The rows of the current view (from the engine's `rows` event): tasks, section headers,
// "Add task" rows, project groups (label and search views) and messages.
ListView {
  id: list
  property var theme
  property var app

  clip: true
  boundsBehavior: Flickable.StopAtBounds
  cacheBuffer: 1200
  keyNavigationEnabled: false
  highlightFollowsCurrentItem: false
  bottomMargin: theme.space(80)
  topMargin: theme.space(4)

  displaced: Transition {
    NumberAnimation { properties: "y"; duration: list.theme.duration(160); easing.type: Easing.OutCubic }
  }
  add: Transition {
    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: list.theme.duration(140) }
  }

  delegate: Item {
    id: d
    required property int index
    required property string key
    required property string type
    required property string json
    readonly property var row: JSON.parse(json)
    width: ListView.view ? ListView.view.width : 0
    height: loader.item ? loader.item.implicitHeight : 0

    Loader {
      id: loader
      width: parent.width
      sourceComponent: d.type === "task" ? taskRow
                     : d.type === "section" ? sectionRow
                     : d.type === "add" ? addRow
                     : d.type === "group" ? groupRow
                     : d.type === "empty" ? emptyRow
                     : messageRow
    }

    Component {
      id: taskRow
      TaskRow { theme: list.theme; app: list.app; row: d.row }
    }

    Component {
      id: sectionRow
      Item {
        implicitHeight: list.theme.space(50)
        MouseArea {
          id: sectionMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: list.app.setSectionCollapsed(d.row.id, !d.row.collapsed)
        }
        Row {
          x: list.theme.space(16)
          anchors.bottom: parent.bottom
          anchors.bottomMargin: list.theme.space(8)
          spacing: list.theme.space(8)
          Text {
            width: list.theme.space(18)
            text: d.row.collapsed ? Icons.chevronRight : Icons.chevronDown
            font.family: list.theme.font
            font.pixelSize: list.theme.small
            color: list.theme.faint
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
          }
          Text {
            text: d.row.name
            textFormat: Text.PlainText
            font.family: list.theme.font
            font.pixelSize: list.theme.body
            font.bold: true
            color: list.theme.text
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: d.row.count > 0 ? String(d.row.count) : ""
            font.family: list.theme.font
            font.pixelSize: list.theme.small
            color: list.theme.faint
            anchors.verticalCenter: parent.verticalCenter
          }
        }
        Row {
          anchors.right: parent.right
          anchors.rightMargin: list.theme.space(16)
          anchors.bottom: parent.bottom
          anchors.bottomMargin: list.theme.space(6)
          spacing: list.theme.space(4)
          visible: sectionMouse.containsMouse || renameMouse.containsMouse || deleteMouse.containsMouse
          Text {
            text: Icons.pencil
            font.family: list.theme.font
            font.pixelSize: list.theme.small
            color: renameMouse.containsMouse ? list.theme.text : list.theme.faint
            padding: list.theme.space(4)
            MouseArea {
              id: renameMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: list.app.renameSection(d.row.id, d.row.name)
            }
          }
          Text {
            text: Icons.trash
            font.family: list.theme.font
            font.pixelSize: list.theme.small
            color: deleteMouse.containsMouse ? list.theme.red : list.theme.faint
            padding: list.theme.space(4)
            MouseArea {
              id: deleteMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: list.app.deleteSection(d.row.id, d.row.name, d.row.count)
            }
          }
        }
        Rectangle {
          x: list.theme.space(16)
          width: parent.width - 2 * list.theme.space(16)
          height: 1
          anchors.bottom: parent.bottom
          color: list.theme.lineStrong
        }
      }
    }

    Component {
      id: addRow
      Item {
        implicitHeight: list.theme.space(38)
        Row {
          x: list.theme.space(38)
          anchors.verticalCenter: parent.verticalCenter
          spacing: list.theme.space(10)
          Text {
            text: Icons.plus
            font.family: list.theme.font
            font.pixelSize: list.theme.small
            color: addMouse.containsMouse ? list.theme.accent : list.theme.faint
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: "Add task"
            font.family: list.theme.font
            font.pixelSize: list.theme.body
            color: addMouse.containsMouse ? list.theme.accent : list.theme.faint
            anchors.verticalCenter: parent.verticalCenter
          }
        }
        MouseArea {
          id: addMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: list.app.openQuickAdd({ projectId: d.row.projectId, sectionId: d.row.sectionId })
        }
      }
    }

    Component {
      id: groupRow
      Item {
        implicitHeight: list.theme.space(48)
        Row {
          x: list.theme.space(18)
          anchors.bottom: parent.bottom
          anchors.bottomMargin: list.theme.space(8)
          spacing: list.theme.space(8)
          Rectangle {
            width: list.theme.space(8); height: width; radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: list.theme.projectColor(d.row.color)
          }
          Text {
            text: d.row.name
            textFormat: Text.PlainText
            font.family: list.theme.font
            font.pixelSize: list.theme.body
            font.bold: true
            color: list.theme.text
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: String(d.row.count)
            font.family: list.theme.font
            font.pixelSize: list.theme.small
            color: list.theme.faint
            anchors.verticalCenter: parent.verticalCenter
          }
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: list.app.goProject(d.row.projectId)
        }
        Rectangle {
          x: list.theme.space(16)
          width: parent.width - 2 * list.theme.space(16)
          height: 1
          anchors.bottom: parent.bottom
          color: list.theme.lineStrong
        }
      }
    }

    Component {
      id: emptyRow
      Item {
        implicitHeight: list.theme.space(150)
        Column {
          anchors.centerIn: parent
          spacing: list.theme.space(8)
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Icons.check
            font.family: list.theme.font
            font.pixelSize: list.theme.title
            color: list.theme.green
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "All clear"
            font.family: list.theme.font
            font.pixelSize: list.theme.heading
            color: list.theme.text
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Press q to add a task"
            font.family: list.theme.font
            font.pixelSize: list.theme.small
            color: list.theme.faint
          }
        }
      }
    }

    Component {
      id: messageRow
      Item {
        implicitHeight: list.theme.space(90)
        Text {
          anchors.centerIn: parent
          width: parent.width - list.theme.space(40)
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: d.row.message || ""
          textFormat: Text.PlainText
          font.family: list.theme.font
          font.pixelSize: list.theme.body
          color: list.theme.dim
        }
      }
    }
  }

  // A thin scroll indicator in the theme's colors.
  Rectangle {
    visible: list.contentHeight > list.height
    anchors.right: parent.right
    anchors.rightMargin: 2
    width: list.theme.space(4)
    radius: width / 2
    color: list.theme.alpha(list.theme.fg, 0.22)
    y: list.visibleArea.yPosition * list.height
    height: Math.max(list.theme.space(24), list.visibleArea.heightRatio * list.height)
  }
}
