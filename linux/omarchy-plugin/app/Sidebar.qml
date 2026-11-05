import QtQuick
import "Icons.js" as Icons

// Search, the Inbox, projects and labels with their open-task counts, and the sync status.
Rectangle {
  id: root
  property var theme
  property var app
  readonly property var sidebar: app.service ? app.service.sidebar : ({ projects: [], labels: [] })
  readonly property var view: app.view || ({})
  property alias searchField: search

  color: theme.sidebar

  function focusSearch() {
    search.input.forceActiveFocus()
    search.input.selectAll()
  }

  Field {
    id: search
    theme: root.theme
    x: root.theme.space(12)
    y: root.theme.space(14)
    width: parent.width - 2 * root.theme.space(12)
    placeholder: Icons.search + "  Search   /"
    onTextChanged: if (input.activeFocus || root.view.kind === "search") root.app.searchFor(text)
    onFieldFocusedChanged: if (fieldFocused) root.app.enterSearch()
    Keys.onEscapePressed: function(event) {
      root.app.focusList()
      event.accepted = true
    }
    Keys.onDownPressed: root.app.focusList()
    onAccepted: root.app.focusList()
  }

  Flickable {
    id: flick
    anchors.top: search.bottom
    anchors.topMargin: root.theme.space(10)
    anchors.bottom: footer.top
    width: parent.width
    contentHeight: column.implicitHeight + root.theme.space(12)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      width: flick.width

      SidebarItem {
        theme: root.theme
        icon: Icons.inbox
        iconColor: root.theme.accent
        label: root.sidebar.inbox ? root.sidebar.inbox.name : "Inbox"
        count: root.sidebar.inbox ? root.sidebar.inbox.count : 0
        current: root.view.kind === "project" && root.view.isInbox === true
        onActivated: root.app.goProject("inbox")
      }

      SidebarHeading {
        theme: root.theme
        text: "Projects"
        canAdd: true
        onAdd: root.app.newProject()
      }
      Repeater {
        model: root.sidebar.projects || []
        SidebarItem {
          theme: root.theme
          required property var modelData
          dot: true
          iconColor: root.theme.projectColor(modelData.color)
          label: modelData.name
          count: modelData.count
          current: root.view.kind === "project" && root.view.id === modelData.id
          onActivated: root.app.goProject(modelData.id)
        }
      }

      SidebarHeading {
        theme: root.theme
        text: "Labels"
        visible: (root.sidebar.labels || []).length > 0
        height: visible ? root.theme.space(36) : 0
      }
      Repeater {
        model: root.sidebar.labels || []
        SidebarItem {
          theme: root.theme
          required property var modelData
          icon: Icons.tag
          iconColor: modelData.color
          label: modelData.name
          count: modelData.count
          current: root.view.kind === "label" && root.view.name === modelData.name
          onActivated: root.app.goLabel(modelData.name)
        }
      }
    }
  }

  // Sync status, settings and shortcuts.
  Item {
    id: footer
    anchors.bottom: parent.bottom
    width: parent.width
    height: root.theme.space(46)
    readonly property var sync: root.app.service ? root.app.service.sync : ({ status: "disabled" })
    readonly property bool engineDown: !root.app.service || !root.app.service.connected
    readonly property string status: engineDown ? "Engine starting…"
      : sync.status === "syncing" ? "Syncing…"
      : sync.status === "error" ? "Sync failed"
      : sync.status === "disabled" ? "Sync off"
      : sync.pending ? "Sync pending" : "Synced"
    readonly property color statusColor: engineDown ? root.theme.faint
      : sync.status === "error" ? root.theme.red
      : sync.status === "disabled" ? root.theme.faint
      : sync.pending || sync.status === "syncing" ? root.theme.orange : root.theme.green

    Rectangle { width: parent.width; height: 1; color: root.theme.line }

    Row {
      x: root.theme.space(18)
      anchors.verticalCenter: parent.verticalCenter
      spacing: root.theme.space(8)
      Text {
        text: Icons.cloud
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        color: footer.statusColor
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: footer.status
        font.family: root.theme.font
        font.pixelSize: root.theme.small
        color: footer.sync.status === "error" ? root.theme.red : root.theme.dim
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    MouseArea {
      anchors.fill: parent
      anchors.rightMargin: root.theme.space(70)
      cursorShape: Qt.PointingHandCursor
      onClicked: footer.sync.status === "disabled" || footer.sync.status === "error" ? root.app.openSettings() : root.app.syncNow()
    }
    Row {
      anchors.right: parent.right
      anchors.rightMargin: root.theme.space(14)
      anchors.verticalCenter: parent.verticalCenter
      spacing: root.theme.space(6)
      Text {
        text: Icons.keyboard
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        color: helpMouse.containsMouse ? root.theme.text : root.theme.faint
        padding: root.theme.space(4)
        MouseArea {
          id: helpMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.app.openOverlay("shortcuts")
        }
      }
      Text {
        text: Icons.cog
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        color: settingsMouse.containsMouse ? root.theme.text : root.theme.faint
        padding: root.theme.space(4)
        MouseArea {
          id: settingsMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.app.openSettings()
        }
      }
    }
  }

  Rectangle {
    anchors.right: parent.right
    width: 1
    height: parent.height
    color: root.theme.line
  }
}
