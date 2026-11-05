import QtQuick

// Adds or edits a project: name and one of Todoist's 20 colors (arrow keys pick a color).
Modal {
  id: root
  property var app
  property string projectId: ""
  property string colorKey: "charcoal"
  property string error: ""
  readonly property var palette: app.service ? app.service.palette : []
  cardWidth: 480
  topRatio: 0.2

  function open(options) {
    projectId = options.id || ""
    colorKey = options.colorKey || "charcoal"
    name.text = options.name || ""
    error = ""
    name.focusField()
  }

  function moveColor(delta) {
    var keys = palette.map(function(p) { return p.key })
    var i = keys.indexOf(colorKey)
    if (i < 0) i = 0
    i = (i + delta + keys.length) % keys.length
    colorKey = keys[i]
  }

  function save() {
    var text = name.text.trim()
    if (text === "") { error = "Enter a name"; return }
    if (projectId) {
      app.req("updateProject", { id: projectId, name: text, color: colorKey }, function(ok, r) {
        if (!ok) { root.error = r; return }
        root.app.closeOverlay("project")
      })
    } else {
      app.req("addProject", { name: text, color: colorKey }, function(ok, r) {
        if (!ok) { root.error = r; return }
        root.app.closeOverlay("project")
        root.app.goProject(r.id)
      })
    }
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) { app.closeOverlay("project"); event.accepted = true }
    else if (event.key === Qt.Key_Down || (event.key === Qt.Key_Right && !name.fieldFocused)) { moveColor(1); event.accepted = true }
    else if (event.key === Qt.Key_Up || (event.key === Qt.Key_Left && !name.fieldFocused)) { moveColor(-1); event.accepted = true }
  }
  onDismissed: app.closeOverlay("project")

  Text {
    text: root.projectId ? "Edit project" : "New project"
    font.family: root.theme.font
    font.pixelSize: root.theme.body
    font.bold: true
    color: root.theme.text
  }
  Field {
    id: name
    theme: root.theme
    width: parent.width
    placeholder: "Project name"
    onAccepted: root.save()
  }
  Text {
    text: "Color  ↑/↓"
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.theme.faint
  }
  Grid {
    columns: 10
    spacing: root.theme.space(8)
    Repeater {
      model: root.palette
      Rectangle {
        required property var modelData
        width: root.theme.space(26)
        height: width
        radius: width / 2
        color: modelData.hex
        border.width: root.colorKey === modelData.key ? 3 : 0
        border.color: root.theme.text
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.colorKey = parent.modelData.key
        }
      }
    }
  }
  Text {
    text: {
      for (var i = 0; i < root.palette.length; i++) if (root.palette[i].key === root.colorKey) return root.palette[i].name
      return ""
    }
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.theme.dim
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
    Btn { theme: root.theme; text: "Cancel"; onClicked: root.app.closeOverlay("project") }
    Btn { theme: root.theme; text: root.projectId ? "Save" : "Add project"; primary: true; onClicked: root.save() }
  }
}
