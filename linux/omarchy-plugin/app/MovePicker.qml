import QtQuick
import "Icons.js" as Icons

// The move dialog (m, v): a search over sections, projects and tasks, ranked by the engine
// (TodoCore's `moveTargets`) on every keystroke. ↑/↓ or Ctrl+J/K choose, Enter moves, Esc closes.
// Moves the J/K selection, else the selected or open task; the toast offers undo.
Modal {
  id: root
  property var app
  cardWidth: 600
  topRatio: 0.16

  // What is moved, in list order, and what the header calls it.
  property var ids: []
  property string subject: ""
  // The engine's targets for the latest query; `entries` adds a header before each group.
  property var targets: []
  property int current: 0
  property string query: ""
  property int seq: 0
  property int loadedSeq: -1
  property bool acceptWhenLoaded: false
  property bool moving: false
  property string error: ""
  property point lastMouse: Qt.point(-1, -1)

  readonly property bool loading: loadedSeq !== seq
  readonly property int rowHeight: theme.space(34)
  readonly property int headerHeight: theme.space(30)
  readonly property int firstHeaderHeight: theme.space(22)
  // In the empty-query list the project's sections sit under it.
  readonly property bool nested: targets.length > 0 && targets[0].kind === "project" && targets[0].group === "currentProject"

  readonly property var entries: {
    var out = [], group = ""
    for (var i = 0; i < targets.length; i++) {
      var t = targets[i]
      if (t.group !== group) {
        group = t.group
        out.push({ header: true, first: out.length === 0, text: groupTitle(t) })
      }
      out.push({ header: false, index: i, target: t })
    }
    return out
  }
  readonly property var entryOf: {
    var map = []
    for (var e = 0; e < entries.length; e++) if (!entries[e].header) map.push(e)
    return map
  }
  readonly property int headerCount: entries.length - targets.length

  function groupTitle(t) {
    switch (t.group) {
      case "currentProject": return "In " + t.projectName
      case "sections": return "Sections"
      case "projects": return "Projects"
      default: return "Tasks"
    }
  }

  function open(arg) {
    ids = arg && arg.ids ? arg.ids : []
    subject = arg && arg.subject ? arg.subject : ""
    targets = []
    current = 0
    error = ""
    moving = false
    acceptWhenLoaded = false
    lastMouse = Qt.point(-1, -1)
    field.text = ""
    field.input.forceActiveFocus()
    load()
  }

  // Asks for the targets of the current text; only the reply to the latest request is applied.
  function load() {
    var mine = ++seq
    query = field.text
    app.req("moveTargets", { ids: ids, query: field.text }, function(ok, result) {
      if (mine !== root.seq || !root.visible) return
      root.loadedSeq = mine
      root.targets = ok ? result : []
      root.error = ok ? "" : result
      var first = 0
      while (first < root.targets.length && root.targets[first].isCurrent) first++
      root.current = first < root.targets.length ? first : 0
      list.positionViewAtBeginning()
      if (root.acceptWhenLoaded) { root.acceptWhenLoaded = false; root.accept() }
    })
  }

  function step(delta) {
    if (targets.length === 0) return
    current = Math.max(0, Math.min(targets.length - 1, current + delta))
    reveal()
  }

  // Keeps the highlighted row in view; a group's first row brings its header along.
  function reveal() {
    var e = entryOf[current]
    if (e === undefined) return
    if (e <= 1) { list.positionViewAtBeginning(); return }
    if (entries[e - 1].header) list.positionViewAtIndex(e - 1, ListView.Contain)
    list.positionViewAtIndex(e, ListView.Contain)
  }

  // The pointer moved over row `i` (rows sliding under a still pointer do not count).
  function hoverAt(i, globalPoint) {
    if (globalPoint.x === lastMouse.x && globalPoint.y === lastMouse.y) return
    lastMouse = globalPoint
    current = i
  }

  function accept() {
    if (moving) return
    if (loading) { acceptWhenLoaded = true; return }
    var t = targets[current]
    if (!t) return
    if (t.isCurrent) { app.closeOverlay("move"); return }
    moving = true
    app.moveTasksTo(ids, t, function(ok, message) {
      root.moving = false
      if (!ok) root.error = message
    })
  }

  // `title` as StyledText with the engine's UTF-16 match ranges in bold accent; every slice is escaped.
  function marked(title, matches) {
    function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;") }
    var out = "", at = 0
    var tone = String(theme.accent)
    for (var m = 0; matches && m < matches.length; m++) {
      var a = Math.max(at, matches[m][0]), b = Math.min(title.length, matches[m][1])
      if (b <= a) continue
      out += esc(title.slice(at, a)) + "<font color=\"" + tone + "\"><b>" + esc(title.slice(a, b)) + "</b></font>"
      at = b
    }
    return out + esc(title.slice(at))
  }

  onDismissed: app.closeOverlay("move")

  Keys.onPressed: function(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Escape) app.closeOverlay("move")
    else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) step(1)
    else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) step(-1)
    else if (event.key === Qt.Key_PageDown) step(8)
    else if (event.key === Qt.Key_PageUp) step(-8)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) accept()
    else return
    event.accepted = true
  }

  // What is moved: Move “Title” or Move 3 tasks.
  Row {
    width: parent.width
    spacing: root.theme.space(6)
    Text {
      id: moveWord
      text: "Move"
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      font.bold: true
      color: root.theme.faint
    }
    Text {
      width: Math.min(implicitWidth, parent.width - moveWord.width - parent.spacing)
      text: root.subject
      textFormat: Text.PlainText
      elide: Text.ElideMiddle
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      font.bold: true
      color: root.theme.dim
    }
  }

  Field {
    id: field
    theme: root.theme
    width: parent.width
    placeholder: "Move to a section, project or task…"
    onTextChanged: { root.error = ""; if (root.visible) root.load() }
    onAccepted: root.accept()
  }

  Text {
    width: parent.width
    visible: root.error !== ""
    text: root.error
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    color: root.theme.red
  }

  ListView {
    id: list
    width: parent.width
    visible: root.targets.length > 0
    height: Math.min(root.targets.length * root.rowHeight + root.headerCount * root.headerHeight
                     - (root.headerCount > 0 ? root.headerHeight - root.firstHeaderHeight : 0),
                     root.rowHeight * 10)
    clip: true
    interactive: contentHeight > height
    boundsBehavior: Flickable.StopAtBounds
    model: root.entries
    delegate: Item {
      id: entry
      required property var modelData
      required property int index
      readonly property var target: modelData.header ? null : modelData.target
      readonly property bool highlighted: !modelData.header && modelData.index === root.current
      readonly property bool indented: !!target && root.nested && target.group === "currentProject" && target.kind === "section"
      // The current project's header names it; other rows say where they are.
      readonly property bool showsContext: !!target && target.group !== "currentProject" && target.kind !== "project"
      width: list.width
      height: modelData.header ? (modelData.first ? root.firstHeaderHeight : root.headerHeight) : root.rowHeight

      // Group header
      Text {
        visible: entry.modelData.header
        x: root.theme.space(10)
        width: parent.width - 2 * x
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.theme.space(6)
        text: entry.modelData.header ? entry.modelData.text : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        font.family: root.theme.font
        font.pixelSize: root.theme.small
        font.bold: true
        color: root.theme.faint
      }

      // Target row
      Rectangle {
        visible: !entry.modelData.header
        anchors.fill: parent
        radius: root.theme.radius
        color: entry.highlighted ? root.theme.cursorFill : "transparent"

        Item {
          id: iconBox
          x: root.theme.space(10) + (entry.indented ? root.theme.space(26) : 0)
          width: root.theme.space(16)
          height: parent.height
          ProjectMark {
            visible: !!entry.target && entry.target.kind === "project"
            anchors.centerIn: parent
            theme: root.theme
            color: root.theme.projectColor(entry.target ? entry.target.projectColor : null)
            isInbox: !!entry.target && entry.target.projectIsInbox
            glyphSize: root.theme.body
          }
          Text {
            visible: !!entry.target && entry.target.kind === "section"
            anchors.centerIn: parent
            text: Icons.section
            textFormat: Text.PlainText
            font.family: root.theme.font
            font.pixelSize: root.theme.small
            color: root.theme.faint
          }
          Rectangle {
            visible: !!entry.target && entry.target.kind === "task"
            anchors.centerIn: parent
            width: root.theme.space(11); height: width; radius: width / 2
            color: "transparent"
            border.width: Math.max(1, Math.round(width / 9))
            border.color: root.theme.faint
          }
        }

        Text {
          id: titleText
          x: iconBox.x + iconBox.width + root.theme.space(10)
          width: parent.width - x - root.theme.space(10) - (trailing.visible ? trailing.width + root.theme.space(12) : 0)
          anchors.verticalCenter: parent.verticalCenter
          text: entry.target ? root.marked(entry.target.title, entry.target.matches) : ""
          textFormat: Text.StyledText
          elide: Text.ElideRight
          maximumLineCount: 1
          font.family: root.theme.font
          font.pixelSize: root.theme.body
          color: entry.target && entry.target.isCurrent ? root.theme.dim : root.theme.text
        }

        // Where the target is ("in ● Work", "● Work / Planning"), or ✓ Current.
        Row {
          id: trailing
          readonly property real maxWidth: Math.round(parent.width * 0.45)
          visible: !!entry.target && (entry.target.isCurrent || entry.showsContext)
          anchors.right: parent.right
          anchors.rightMargin: root.theme.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.theme.space(6)
          Text {
            visible: !!entry.target && entry.target.isCurrent
            anchors.verticalCenter: parent.verticalCenter
            text: Icons.check + "  Current"
            textFormat: Text.PlainText
            font.family: root.theme.font
            font.pixelSize: root.theme.small
            color: root.theme.accent
          }
          Text {
            id: inWord
            visible: !!entry.target && !entry.target.isCurrent && entry.target.kind === "section"
            anchors.verticalCenter: parent.verticalCenter
            text: "in"
            font.family: root.theme.font
            font.pixelSize: root.theme.small
            color: root.theme.faint
          }
          ProjectMark {
            id: contextMark
            visible: !!entry.target && !entry.target.isCurrent
            anchors.verticalCenter: parent.verticalCenter
            theme: root.theme
            size: root.theme.space(7)
            glyphSize: root.theme.small
            color: root.theme.projectColor(entry.target ? entry.target.projectColor : null)
            isInbox: !!entry.target && entry.target.projectIsInbox
          }
          Text {
            visible: contextMark.visible
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, trailing.maxWidth - contextMark.width - trailing.spacing
                            - (inWord.visible ? inWord.width + trailing.spacing : 0))
            text: {
              var t = entry.target
              if (!t) return ""
              return t.kind === "task" && t.sectionName ? t.projectName + " / " + t.sectionName : t.projectName
            }
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.family: root.theme.font
            font.pixelSize: root.theme.small
            color: root.theme.dim
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPositionChanged: function(mouse) { root.hoverAt(entry.modelData.index, mapToGlobal(mouse.x, mouse.y)) }
          onClicked: { root.current = entry.modelData.index; root.accept() }
        }
      }
    }
  }

  // Nothing matches.
  Item {
    width: parent.width
    height: root.rowHeight
    visible: root.targets.length === 0 && !root.loading && root.error === ""
    Text {
      id: noIcon
      x: root.theme.space(10)
      width: root.theme.space(16)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignHCenter
      text: Icons.search
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      color: root.theme.faint
    }
    Text {
      x: noIcon.x + noIcon.width + root.theme.space(10)
      width: parent.width - x - root.theme.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: "No matches for “" + root.query.trim() + "”"
      textFormat: Text.PlainText
      elide: Text.ElideMiddle
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      color: root.theme.dim
    }
  }

  // Keys
  Row {
    spacing: root.theme.space(16)
    Repeater {
      model: [["↑ ↓", "Choose"], ["Enter", "Move"], ["Esc", "Close"]]
      Row {
        id: hint
        required property var modelData
        spacing: root.theme.space(6)
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: keyText.implicitWidth + root.theme.space(10)
          height: keyText.implicitHeight + root.theme.space(2)
          radius: root.theme.radius
          color: root.theme.field
          Text {
            id: keyText
            anchors.centerIn: parent
            text: hint.modelData[0]
            font.family: root.theme.font
            font.pixelSize: root.theme.small
            color: root.theme.dim
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: hint.modelData[1]
          font.family: root.theme.font
          font.pixelSize: root.theme.small
          color: root.theme.faint
        }
      }
    }
  }
}
