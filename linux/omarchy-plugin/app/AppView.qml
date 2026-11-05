import QtQuick
import Quickshell
import "Icons.js" as Icons

// The whole app: sidebar, the list of the current view, and the dialogs over it. Holds the UI
// state (selection, open dialogs) and routes keys; every data change is a request to the engine
// through `service`, whose `rows` event then redraws the list.
FocusScope {
  id: app
  property var service: null
  property Theme theme: Theme {}
  signal closeRequested()

  readonly property var view: service ? service.view : ({ kind: "project", id: "inbox", name: "Inbox", isInbox: true })
  readonly property var rows: service ? service.rowList : []
  readonly property bool narrow: width < theme.space(720)

  property string selectedId: ""
  // Tasks selected with J/K (Shift+↓/↑): the range from `selectionAnchor` to `selectedId` in row
  // order, both included. Empty while one task (or none) is selected. Like the Mac's `multiSelection`.
  property var multiIds: []
  property string selectionAnchor: ""
  property bool extendingSelection: false
  // Any other way of selecting a task ends a J/K selection.
  onSelectedIdChanged: if (!extendingSelection) clearMultiSelection()
  property string pendingSelect: ""
  property string neighborId: ""
  property var overlays: []
  property string pickerTaskId: ""
  property var pickerLabels: []
  property var moveTargets: []
  property var menuActions: []
  property var beforeSearch: null
  property bool leavingSearch: false
  property string chord: ""
  property bool startupErrorDismissed: false

  function req(cmd, args, cb) {
    if (service) service.request(cmd, args, cb)
    else if (cb) cb(false, "TodoTim is not running")
  }

  // ---- Lifecycle (from the panel)

  function activate(payload) {
    if (overlays.length > 0) overlayItem(overlays[overlays.length - 1]).forceActiveFocus()
    else focusList()
    if (payload && payload.action === "quickAdd") openQuickAdd(defaultContext())
  }

  // ---- Overlays

  function overlayItem(name) {
    switch (name) {
      case "quickAdd": return quickAdd
      case "detail": return detail
      case "date": return datePicker
      case "labels": return labelPicker
      case "move": return movePicker
      case "priority": return priorityPicker
      case "menu": return menuPicker
      case "prompt": return prompt
      case "confirm": return confirm
      case "project": return projectDialog
      case "settings": return settings
      case "shortcuts": return shortcuts
    }
    return null
  }

  function isOpen(name) { return overlays.indexOf(name) >= 0 }

  function openOverlay(name, arg) {
    var next = overlays.filter(function(n) { return n !== name })
    next.push(name)
    overlays = next
    var item = overlayItem(name)
    item.z = 50 + next.length
    item.visible = true
    item.open(arg)
  }

  function closeOverlay(name) {
    var item = overlayItem(name)
    if (item) item.visible = false
    overlays = overlays.filter(function(n) { return n !== name })
    if (overlays.length > 0) overlayItem(overlays[overlays.length - 1]).forceActiveFocus()
    else focusList()
  }

  function focusList() { list.forceActiveFocus() }

  // ---- Navigation

  function currentSpec() {
    if (view.kind === "label") return { kind: "label", name: view.name }
    if (view.kind === "search") return { kind: "search", query: view.query }
    return { kind: "project", id: view.id }
  }

  function goTo(spec) {
    selectedId = ""
    pendingSelect = ""
    if (spec.kind !== "search" && sidebar.searchField.text !== "") {
      leavingSearch = true
      sidebar.searchField.text = ""
      leavingSearch = false
      beforeSearch = null
    }
    if (service) service.setView(spec)
    list.positionViewAtBeginning()
  }

  function goProject(id) { goTo({ kind: "project", id: id }); focusList() }
  function goLabel(name) { goTo({ kind: "label", name: name }); focusList() }

  function goProjectNumber(n) {
    var projects = service ? service.sidebar.projects : []
    if (n === 1) goProject("inbox")
    else if (n - 2 < projects.length) goProject(projects[n - 2].id)
  }

  function enterSearch() {
    if (view.kind === "search") return
    beforeSearch = { spec: currentSpec(), selected: selectedId }
    selectedId = ""
    if (service) service.setView({ kind: "search", query: sidebar.searchField.text })
  }

  function searchFor(text) {
    if (leavingSearch || !service) return
    selectedId = ""
    service.setView({ kind: "search", query: text })
  }

  function leaveSearch() {
    var back = beforeSearch
    goTo(back ? back.spec : { kind: "project", id: "inbox" })
    if (back && back.selected) pendingSelect = back.selected
    focusList()
  }

  function focusSearch() { sidebar.focusSearch() }

  // ---- Selection

  function indexOfId(id) {
    if (!id) return -1
    for (var i = 0; i < rows.length; i++) if (rows[i].type === "task" && rows[i].id === id) return i
    return -1
  }

  function rowOf(id) {
    var i = indexOfId(id)
    return i >= 0 ? rows[i] : null
  }

  function clearMultiSelection() {
    selectionAnchor = ""
    if (multiIds.length > 0) multiIds = []
  }

  function isInSelection(id) { return id === selectedId || multiIds.indexOf(id) >= 0 }

  // Sets the selection without `onSelectedIdChanged` ending the multi-selection.
  function setSelection(cursor, anchor, ids) {
    extendingSelection = true
    selectedId = cursor
    extendingSelection = false
    selectionAnchor = ids.length > 0 ? anchor : ""
    multiIds = ids
  }

  // J/K, Shift+↓/↑: moves the selection and selects every task between it and where it started.
  function extendSelection(delta) {
    var i = indexOfId(selectedId)
    if (i < 0) return move(delta)
    var anchor = selectionAnchor && indexOfId(selectionAnchor) >= 0 ? selectionAnchor : selectedId
    var a = indexOfId(anchor)
    var j = i
    for (var k = i + delta; k >= 0 && k < rows.length; k += delta) if (rows[k].type === "task") { j = k; break }
    var ids = []
    if (j !== a) for (k = Math.min(a, j); k <= Math.max(a, j); k++) if (rows[k].type === "task") ids.push(rows[k].id)
    setSelection(rows[j].id, anchor, ids)
    Qt.callLater(ensureVisible)
  }

  // What `undo` hands back to select again (the engine keeps it with the undo step).
  function selectionState() {
    return { view: JSON.stringify(currentSpec()), cursor: selectedId, anchor: selectionAnchor, ids: multiIds }
  }

  function restoreSelection(s) {
    if (!s || !s.view || s.view !== JSON.stringify(currentSpec())) return
    if (s.cursor && indexOfId(s.cursor) < 0) { pendingSelect = s.cursor; return }
    setSelection(s.cursor || "", s.anchor || "", s.ids || [])
    Qt.callLater(ensureVisible)
  }

  function select(id) {
    clearMultiSelection()
    selectedId = id
    focusList()
    Qt.callLater(ensureVisible)
  }

  function ensureVisible() {
    var i = indexOfId(selectedId)
    if (i >= 0) list.positionViewAtIndex(i, ListView.Contain)
  }

  function visibleIndex(bottom) {
    var y = bottom ? list.contentY + list.height - 4 : list.contentY + 4
    var i = list.indexAt(list.width / 2, y)
    return i < 0 ? (bottom ? rows.length - 1 : 0) : i
  }

  // j/k: without a selection, the first (last) task on screen.
  function move(delta) {
    clearMultiSelection()
    var i = indexOfId(selectedId)
    var j
    if (i < 0) {
      j = visibleIndex(delta < 0)
      for (; j >= 0 && j < rows.length; j += delta) if (rows[j].type === "task") return select(rows[j].id)
      for (j = delta > 0 ? 0 : rows.length - 1; j >= 0 && j < rows.length; j += delta) if (rows[j].type === "task") return select(rows[j].id)
      return
    }
    for (j = i + delta; j >= 0 && j < rows.length; j += delta) if (rows[j].type === "task") return select(rows[j].id)
  }

  // gg / G: the first or last task of the section (a run of task rows).
  function jumpEdge(last) {
    var i = indexOfId(selectedId)
    if (i < 0) {
      for (i = visibleIndex(false); i < rows.length && rows[i].type !== "task"; i++) {}
      if (i >= rows.length) return
    }
    var a = i, b = i
    while (a > 0 && rows[a - 1].type === "task") a--
    while (b < rows.length - 1 && rows[b + 1].type === "task") b++
    select(rows[last ? b : a].id)
  }

  // The task to select after `id` disappears: the next one outside its sub-tasks, else the previous.
  function neighborOf(id) { return neighborOfAll([id]) }

  // The task to select after `ids` and their sub-tasks disappear: the first one below the last of
  // them, else the last one above the first.
  function neighborOfAll(ids) {
    var gone = {}, lo = rows.length, hi = -1
    for (var n = 0; n < ids.length; n++) {
      var i = indexOfId(ids[n])
      if (i < 0) continue
      lo = Math.min(lo, i); hi = Math.max(hi, i); gone[ids[n]] = true
      for (var d = i + 1; d < rows.length && rows[d].type === "task" && rows[d].depth > rows[i].depth; d++) gone[rows[d].id] = true
    }
    if (hi < 0) return ""
    for (var j = hi + 1; j < rows.length; j++) if (rows[j].type === "task" && !gone[rows[j].id]) return rows[j].id
    for (j = lo - 1; j >= 0; j--) if (rows[j].type === "task" && !gone[rows[j].id]) return rows[j].id
    return ""
  }

  function isDescendant(id, ancestor) {
    var i = indexOfId(ancestor)
    if (i < 0) return false
    var depth = rows[i].depth
    for (var j = i + 1; j < rows.length && rows[j].type === "task" && rows[j].depth > depth; j++)
      if (rows[j].id === id) return true
    return false
  }

  function reconcileSelection() {
    if (pendingSelect && indexOfId(pendingSelect) >= 0) {
      selectedId = pendingSelect
      pendingSelect = ""
      neighborId = ""
      Qt.callLater(ensureVisible)
      return
    }
    if (selectedId && indexOfId(selectedId) < 0) {
      selectedId = neighborId && indexOfId(neighborId) >= 0 ? neighborId : ""
      Qt.callLater(ensureVisible)
    }
    neighborId = ""
  }

  Connections {
    target: app.service
    function onRowsUpdated() { app.reconcileSelection() }
  }

  // ---- Task actions

  function showResult(ok, result) {
    if (!ok) { toast.show(result, false); return }
    if (result && result.toast) toast.show(result.toast.message, result.toast.undo)
  }

  function taskTitle(id) {
    var r = rowOf(id)
    if (r) return r.content
    if (detail.task && detail.task.id === id) return detail.task.content
    return ""
  }

  function toggleComplete(id, fromDetailList) {
    if (!id) return
    var r = rowOf(id)
    var completing = r ? !r.completed : !(detail.task && detail.task.id === id && detail.task.completed)
    if (completing && id === selectedId && !view.showCompleted) neighborId = neighborOf(id)
    if (completing && !fromDetailList && isOpen("detail") && detail.taskId === id) closeOverlay("detail")
    req("toggleComplete", { id: id, selection: selectionState() }, showResult)
  }

  // x, e, Ctrl+Enter in the list: completes the selected task, or every task of a J/K selection
  // in one undo step. When all of them are completed already (shown completed tasks), reopens them.
  function completeSelected() {
    if (multiIds.length === 0) { toggleComplete(selectedId); return }
    var ids = multiIds.slice()
    var completing = ids.some(function(id) { var r = rowOf(id); return r && !r.completed })
    if (completing && !view.showCompleted) neighborId = neighborOfAll(ids)
    req("completeTasks", { ids: ids, selection: selectionState() }, showResult)
  }

  function setPriority(id, p) { if (id) req("updateTask", { id: id, priority: p }) }

  function setTaskCollapsed(id, collapsed) {
    if (collapsed && selectedId && isDescendant(selectedId, id)) select(id)
    req("setTaskCollapsed", { id: id, collapsed: collapsed })
  }

  function setSectionCollapsed(id, collapsed) {
    var r = rowOf(selectedId)
    if (collapsed && r && r.sectionId === id) selectedId = ""
    req("setSectionCollapsed", { id: id, collapsed: collapsed })
  }

  function collapseSelected() {
    var r = rowOf(selectedId)
    if (!r || view.kind !== "project") return
    if (r.hasChildren && r.expanded) setTaskCollapsed(r.id, true)
    else if (r.parentId) { select(r.parentId); setTaskCollapsed(r.parentId, true) }
  }

  function expandSelected() {
    var r = rowOf(selectedId)
    if (r && r.hasChildren && !r.expanded) setTaskCollapsed(r.id, false)
  }

  function confirmDelete(id) {
    if (!id) return
    var r = rowOf(id)
    var subtasks = r ? r.subTotal : (detail.task && detail.task.id === id ? detail.task.subtasks.length : 0)
    openOverlay("confirm", {
      title: "Delete “" + taskTitle(id) + "”?",
      message: subtasks > 0 ? "Its sub-tasks are deleted too. Ctrl+Z brings them back." : "Ctrl+Z brings it back.",
      onConfirm: function() { app.deleteTask(id) }
    })
  }

  function deleteTask(id) {
    if (id === selectedId) neighborId = neighborOf(id)
    if (isOpen("detail") && detail.taskId === id) closeOverlay("detail")
    req("deleteTask", { id: id }, showResult)
  }

  function undo() {
    req("undo", {}, function(ok, r) {
      toast.show(ok ? "Undone: " + r.message : r, false)
      if (ok) restoreSelection(r.selection)
    })
  }
  // `u`: the toast's Undo, only while the toast offers it.
  function undoFromToast() { if (toast.offersUndo) undo() }

  function indent() { if (selectedId) req("indentTask", { id: selectedId }) }
  function outdent() { if (selectedId) req("outdentTask", { id: selectedId }) }
  function shift(delta) { if (selectedId) req("shiftTask", { id: selectedId, delta: delta }, function() { Qt.callLater(app.ensureVisible) }) }

  function openTask(id) {
    selectedId = id
    openOverlay("detail", id)
  }

  function moveDetail(delta) {
    var i = indexOfId(detail.taskId)
    if (i < 0) return
    for (var j = i + delta; j >= 0 && j < rows.length; j += delta) {
      if (rows[j].type === "task") {
        selectedId = rows[j].id
        detail.open(rows[j].id)
        Qt.callLater(ensureVisible)
        return
      }
    }
  }

  function openLink(url) {
    if (/^(https?:\/\/|mailto:)/i.test(url)) Qt.openUrlExternally(url)
  }

  // ---- Adding

  function defaultContext() {
    return view.kind === "project" ? { projectId: view.id } : {}
  }

  function openQuickAdd(ctx) { openOverlay("quickAdd", ctx || defaultContext()) }

  // a / A: Quick Add in the selected task's section.
  function addInSection(atTop) {
    if (view.kind !== "project") return openQuickAdd({})
    var r = rowOf(selectedId)
    openQuickAdd({ projectId: view.id, sectionId: r && r.projectId === view.id ? r.sectionId : null, atTop: atTop })
  }

  function taskAdded(result) {
    closeOverlay("quickAdd")
    var here = view.kind === "project" && view.id === result.projectId
    toast.show(here ? "Task added" : "Task added to " + result.projectName, false)
    if (here) {
      pendingSelect = result.taskId
      reconcileSelection()
    }
  }

  function addSection() {
    if (view.kind !== "project") return
    var pid = view.id
    openOverlay("prompt", {
      title: "New section in " + view.name, confirmText: "Add section", placeholder: "Section name",
      onConfirm: function(name) { app.req("addSection", { projectId: pid, name: name }, app.showResult) }
    })
  }

  function renameSection(id, name) {
    openOverlay("prompt", {
      title: "Rename section", text: name, confirmText: "Rename",
      onConfirm: function(newName) { app.req("renameSection", { id: id, name: newName }, app.showResult) }
    })
  }

  function deleteSection(id, name, count) {
    openOverlay("confirm", {
      title: "Delete section “" + name + "”?",
      message: count > 0 ? "Its " + count + (count === 1 ? " task is" : " tasks are") + " deleted too." : "",
      onConfirm: function() { app.req("deleteSection", { id: id }, app.showResult) }
    })
  }

  function newProject() { openOverlay("project", {}) }

  function toggleCompleted() {
    if (view.kind !== "project") return
    req("setShowCompleted", { projectId: view.id, show: !view.showCompleted })
  }

  // ---- Pickers

  function openDatePicker(id) {
    if (!id) return
    pickerTaskId = id
    datePicker.note = ""
    openOverlay("date")
  }

  function previewDate(text) {
    if (text.trim() === "") { datePicker.note = ""; return }
    var asked = text
    req("parseDate", { text: text }, function(ok, r) {
      if (datePicker.text !== asked) return
      if (!ok || !r) { datePicker.note = "Not a date"; datePicker.noteColor = theme.faint }
      else if (r.noDate) { datePicker.note = "No date"; datePicker.noteColor = theme.dim }
      else { datePicker.note = r.due.label + "  ·  " + r.due.date; datePicker.noteColor = theme.dueColor(r.due.kind) }
    })
  }

  function setDue(phrase) {
    var id = pickerTaskId
    req("updateTask", { id: id, dueText: phrase }, function(ok, r) {
      if (!ok) { datePicker.note = r; datePicker.noteColor = theme.red; return }
      app.closeOverlay("date")
    })
  }

  function openLabelPicker(id) {
    if (!id) return
    pickerTaskId = id
    pickerLabels = []
    req("getTask", { id: id }, function(ok, r) {
      if (ok) app.pickerLabels = r.labels.map(function(l) { return l.name })
    })
    openOverlay("labels")
  }

  function labelItems(filter, chosen) {
    var labels = service ? service.sidebar.labels : []
    var items = []
    var known = {}
    for (var i = 0; i < labels.length; i++) {
      known[labels[i].name.toLowerCase()] = true
      items.push({ key: labels[i].name, text: labels[i].name, icon: Icons.tag, color: labels[i].color,
                   checked: chosen.indexOf(labels[i].name) >= 0 })
    }
    for (i = 0; i < chosen.length; i++) {
      if (!known[chosen[i].toLowerCase()]) items.push({ key: chosen[i], text: chosen[i], icon: Icons.tag, checked: true })
    }
    var typed = filter.trim().replace(/^@/, "")
    if (typed !== "" && !known[typed.toLowerCase()] && chosen.indexOf(typed) < 0)
      items.push({ key: typed, text: "Create “" + typed + "”", icon: Icons.plus, always: true })
    return items
  }

  function toggleLabel(name) {
    var next = pickerLabels.slice()
    var i = next.indexOf(name)
    if (i >= 0) next.splice(i, 1)
    else next.push(name)
    pickerLabels = next
    req("updateTask", { id: pickerTaskId, labels: next }, function(ok, r) {
      if (ok) app.pickerLabels = r.labels.map(function(l) { return l.name })
      else toast.show(r, false)
    })
  }

  function openMovePicker(id) {
    if (!id) return
    pickerTaskId = id
    req("targets", {}, function(ok, r) {
      if (!ok) return
      var items = []
      for (var i = 0; i < r.length; i++) {
        var p = r[i]
        items.push({ key: "p", projectId: p.id, sectionId: null, text: p.name, dot: true, color: app.theme.projectColor(p.color) })
        for (var j = 0; j < p.sections.length; j++)
          items.push({ key: "s", projectId: p.id, sectionId: p.sections[j].id, text: p.sections[j].name, indent: 1,
                       icon: Icons.chevronRight, project: p.name })
      }
      app.moveTargets = items
    })
    openOverlay("move")
  }

  function moveTo(item) {
    var id = pickerTaskId
    if (id === selectedId && !(view.kind === "project" && view.id === item.projectId)) neighborId = neighborOf(id)
    req("moveTask", { id: id, projectId: item.projectId, sectionId: item.sectionId }, function(ok, r) {
      if (!ok) { toast.show(r, false); return }
      app.closeOverlay("move")
      toast.show("Moved to " + r.projectName + (item.sectionId ? " / " + item.text : ""), false)
    })
  }

  function openPriorityPicker(id) {
    if (!id) return
    pickerTaskId = id
    openOverlay("priority")
  }

  // ---- Project and label menu

  function openViewMenu() {
    var items = []
    if (view.kind === "project") {
      items.push({ key: "section", text: "Add section", icon: Icons.plus, hint: "s" })
      items.push({ key: "completed", text: view.showCompleted ? "Hide completed tasks" : "Show completed tasks",
                   icon: view.showCompleted ? Icons.eyeSlash : Icons.eye, hint: "Ctrl+Shift+C" })
      if (!view.isInbox) {
        items.push({ key: "editProject", text: "Rename or recolor project", icon: Icons.pencil })
        items.push({ key: "deleteProject", text: "Delete project", icon: Icons.trash, danger: true })
      }
    } else if (view.kind === "label") {
      items.push({ key: "renameLabel", text: "Rename label", icon: Icons.pencil })
      items.push({ key: "deleteLabel", text: "Delete label", icon: Icons.trash, danger: true })
    }
    if (items.length === 0) return
    menuActions = items
    openOverlay("menu")
  }

  function runMenu(key) {
    closeOverlay("menu")
    var v = view
    switch (key) {
      case "section": addSection(); break
      case "completed": toggleCompleted(); break
      case "editProject":
        var projects = service.sidebar.projects
        for (var i = 0; i < projects.length; i++) if (projects[i].id === v.id)
          openOverlay("project", { id: v.id, name: projects[i].name, colorKey: projects[i].colorKey })
        break
      case "deleteProject":
        openOverlay("confirm", {
          title: "Delete project “" + v.name + "”?",
          message: "Its sections and tasks are deleted too, here and on the server.",
          onConfirm: function() { app.req("deleteProject", { id: v.id }, app.showResult); app.goProject("inbox") }
        })
        break
      case "renameLabel":
        openOverlay("prompt", {
          title: "Rename label", text: v.name, confirmText: "Rename",
          onConfirm: function(name) {
            app.req("updateLabel", { id: v.id, name: name }, app.showResult)
          }
        })
        break
      case "deleteLabel":
        openOverlay("confirm", {
          title: "Delete label “" + v.name + "”?",
          message: "It is removed from every task.",
          onConfirm: function() { app.req("deleteLabel", { id: v.id }, app.showResult); app.goProject("inbox") }
        })
        break
    }
  }

  // ---- Sync

  function openSettings() { openOverlay("settings") }

  function syncNow() {
    req("syncNow", {}, function(ok, r) {
      if (!ok) toast.show(r, false)
      else if (r.status === "error") toast.show(r.message || "Sync failed", false)
      else if (r.status === "disabled") app.openSettings()
    })
  }

  // ---- Keys

  // Keys that work everywhere (they reach here when the focused field does not use them).
  Keys.onPressed: function(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var shiftKey = event.modifiers & Qt.ShiftModifier
    if (!ctrl) return
    if (event.key === Qt.Key_Z) undo()
    else if (event.key === Qt.Key_R) syncNow()
    else if (event.key === Qt.Key_N) openQuickAdd(defaultContext())
    else if (event.key === Qt.Key_F) focusSearch()
    else if (event.key === Qt.Key_Comma) openSettings()
    else if (event.key === Qt.Key_W || event.key === Qt.Key_Q) closeRequested()
    else if (shiftKey && event.key === Qt.Key_C) toggleCompleted()
    else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) goProjectNumber(event.key - Qt.Key_0)
    else return
    event.accepted = true
  }

  function handleListKey(event) {
    var t = event.text
    var ctrl = event.modifiers & Qt.ControlModifier
    if (chord === "g") {
      chord = ""
      if (t === "g") { jumpEdge(false); event.accepted = true; return }
      if (t === "i") { goProject("inbox"); event.accepted = true; return }
    }
    if (ctrl) {
      if (event.key === Qt.Key_BracketRight) indent()
      else if (event.key === Qt.Key_BracketLeft) outdent()
      else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) shift(-1)
      else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) shift(1)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) completeSelected()
      else if (event.key === Qt.Key_Backspace) confirmDelete(selectedId)
      else return
      event.accepted = true
      return
    }
    var shiftKey = event.modifiers & Qt.ShiftModifier
    switch (event.key) {
      case Qt.Key_Down: if (shiftKey) extendSelection(1); else move(1); break
      case Qt.Key_Up: if (shiftKey) extendSelection(-1); else move(-1); break
      case Qt.Key_Left: collapseSelected(); break
      case Qt.Key_Right: expandSelected(); break
      case Qt.Key_Return:
      case Qt.Key_Enter: if (selectedId) openTask(selectedId); break
      case Qt.Key_Delete: confirmDelete(selectedId); break
      case Qt.Key_Escape:
        if (multiIds.length > 0) clearMultiSelection()
        else if (view.kind === "search") leaveSearch()
        else if (selectedId) selectedId = ""
        else closeRequested()
        break
      case Qt.Key_PageDown: list.contentY = Math.min(list.contentY + list.height * 0.8, Math.max(0, list.contentHeight - list.height)); break
      case Qt.Key_PageUp: list.contentY = Math.max(0, list.contentY - list.height * 0.8); break
      case Qt.Key_Home: jumpEdge(false); break
      case Qt.Key_End: jumpEdge(true); break
      default:
        switch (t) {
          case "j": move(1); break
          case "k": move(-1); break
          case "J": extendSelection(1); break
          case "K": extendSelection(-1); break
          case "g": chord = "g"; break
          case "G": jumpEdge(true); break
          case "h": collapseSelected(); break
          case "l": expandSelected(); break
          case "e": case "x": completeSelected(); break
          case "1": case "2": case "3": case "4": setPriority(selectedId, Number(t)); break
          case "t": openDatePicker(selectedId); break
          case "@": openLabelPicker(selectedId); break
          case "v": openMovePicker(selectedId); break
          case "a": addInSection(false); break
          case "A": addInSection(true); break
          case "q": openQuickAdd(defaultContext()); break
          case "s": addSection(); break
          case "/": focusSearch(); break
          case "?": openOverlay("shortcuts"); break
          case "u": undoFromToast(); break
          default: return
        }
    }
    event.accepted = true
  }

  // ---- Layout

  Rectangle {
    anchors.fill: parent
    color: app.theme.bg
  }

  Sidebar {
    id: sidebar
    theme: app.theme
    app: app
    visible: !app.narrow
    width: visible ? app.theme.space(250) : 0
    height: parent.height
  }

  Item {
    id: main
    anchors.left: sidebar.right
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom

    Item {
      id: header
      width: parent.width
      height: app.theme.space(78)

      Row {
        x: app.theme.space(22)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: app.theme.space(12)
        spacing: app.theme.space(12)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: app.view.kind === "label" ? Icons.tag : app.view.kind === "search" ? Icons.search
              : app.view.isInbox ? Icons.inbox : Icons.circle
          font.family: app.theme.font
          font.pixelSize: app.view.kind === "project" && !app.view.isInbox ? app.theme.body : app.theme.heading
          color: app.view.kind === "search" ? app.theme.dim : app.theme.projectColor(app.view.color)
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: app.view.kind === "search" ? (app.view.query ? "“" + app.view.query + "”" : "Search") : (app.view.name || "")
          textFormat: Text.PlainText
          font.family: app.theme.font
          font.pixelSize: app.theme.title
          font.bold: true
          color: app.theme.text
          elide: Text.ElideRight
          width: Math.min(implicitWidth, main.width - app.theme.space(260))
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: app.view.kind !== "search" && app.view.count > 0
          text: String(app.view.count || "")
          font.family: app.theme.font
          font.pixelSize: app.theme.body
          color: app.theme.faint
        }
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: app.theme.space(18)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: app.theme.space(12)
        spacing: app.theme.space(4)

        Text {
          visible: app.view.kind === "project"
          text: app.view.showCompleted ? Icons.eye : Icons.eyeSlash
          font.family: app.theme.font
          font.pixelSize: app.theme.body
          color: completedMouse.containsMouse ? app.theme.text : app.view.showCompleted ? app.theme.accent : app.theme.faint
          padding: app.theme.space(6)
          MouseArea {
            id: completedMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: app.toggleCompleted()
          }
        }
        Text {
          visible: app.view.kind !== "search"
          text: Icons.ellipsis
          font.family: app.theme.font
          font.pixelSize: app.theme.body
          color: menuMouse.containsMouse ? app.theme.text : app.theme.faint
          padding: app.theme.space(6)
          MouseArea {
            id: menuMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: app.openViewMenu()
          }
        }
        Text {
          text: Icons.plus
          font.family: app.theme.font
          font.pixelSize: app.theme.body
          color: addMouse.containsMouse ? app.theme.accent : app.theme.faint
          padding: app.theme.space(6)
          MouseArea {
            id: addMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: app.openQuickAdd(app.defaultContext())
          }
        }
      }
    }

    // Problems the engine reported at startup (an unreadable database, an untrusted config).
    Rectangle {
      id: banner
      readonly property string message: !app.service ? "The TodoTim service is not loaded. Enable the plugin with: omarchy plugin enable timvink.todotim"
        : app.service.fatalError !== "" ? app.service.fatalError
        : !app.startupErrorDismissed && app.service.startupError !== "" ? app.service.startupError : ""
      visible: message !== ""
      anchors.top: header.bottom
      x: app.theme.space(18)
      width: parent.width - 2 * app.theme.space(18)
      height: visible ? bannerText.implicitHeight + app.theme.space(20) : 0
      radius: app.theme.radius
      color: app.theme.alpha(app.theme.red, 0.12)
      border.width: 1
      border.color: app.theme.alpha(app.theme.red, 0.4)
      Text {
        id: bannerText
        x: app.theme.space(12)
        y: app.theme.space(10)
        width: parent.width - app.theme.space(48)
        wrapMode: Text.Wrap
        text: banner.message
        textFormat: Text.PlainText
        font.family: app.theme.font
        font.pixelSize: app.theme.small
        color: app.theme.text
      }
      Text {
        anchors.right: parent.right
        anchors.rightMargin: app.theme.space(12)
        y: app.theme.space(10)
        text: Icons.close
        font.family: app.theme.font
        font.pixelSize: app.theme.small
        color: app.theme.faint
        MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: app.startupErrorDismissed = true }
      }
    }

    TaskList {
      id: list
      theme: app.theme
      app: app
      focus: true
      anchors.top: banner.bottom
      anchors.topMargin: banner.visible ? app.theme.space(8) : 0
      anchors.bottom: parent.bottom
      width: parent.width
      model: app.service ? app.service.rows : null
      Keys.onPressed: function(event) { app.handleListKey(event) }

      Text {
        anchors.centerIn: parent
        visible: !!app.service && !app.service.connected && app.service.fatalError === ""
        text: "Starting TodoTim…"
        font.family: app.theme.font
        font.pixelSize: app.theme.body
        color: app.theme.faint
      }
    }

    Toast {
      id: toast
      theme: app.theme
      app: app
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: app.theme.space(22)
    }
  }

  // ---- Dialogs

  QuickAdd { id: quickAdd; theme: app.theme; app: app }
  TaskDetail { id: detail; theme: app.theme; app: app }

  ListPicker {
    id: datePicker
    name: "date"
    theme: app.theme
    app: app
    title: "Due date"
    placeholder: "Type a date: next friday, jan 5, in 3 days"
    filterItems: false
    preferText: true
    items: [
      { key: "today", text: "Today", icon: Icons.calendar, color: app.theme.green },
      { key: "tomorrow", text: "Tomorrow", icon: Icons.calendar, color: app.theme.orange },
      { key: "this weekend", text: "This weekend", icon: Icons.calendar, color: app.theme.magenta },
      { key: "next week", text: "Next week", icon: Icons.calendar, color: app.theme.blue },
      { key: "no date", text: "No date", icon: Icons.close, color: app.theme.dim }
    ]
    onTextChanged: app.previewDate(text)
    onPicked: function(item) { app.setDue(item.key) }
    onSubmitted: function(text) { app.setDue(text) }
  }

  ListPicker {
    id: labelPicker
    name: "labels"
    theme: app.theme
    app: app
    title: "Labels"
    placeholder: "Filter or create a label"
    items: app.labelItems(labelPicker.text, app.pickerLabels)
    onPicked: function(item) { app.toggleLabel(item.key); labelPicker.clearText() }
  }

  ListPicker {
    id: movePicker
    name: "move"
    theme: app.theme
    app: app
    title: "Move to"
    placeholder: "Project or section"
    items: app.moveTargets
    onPicked: function(item) { app.moveTo(item) }
  }

  ListPicker {
    id: priorityPicker
    name: "priority"
    theme: app.theme
    app: app
    title: "Priority"
    showField: false
    cardWidth: 320
    items: [
      { key: 1, text: "Priority 1", icon: Icons.flag, color: app.theme.priorityColor(1), hint: "1" },
      { key: 2, text: "Priority 2", icon: Icons.flag, color: app.theme.priorityColor(2), hint: "2" },
      { key: 3, text: "Priority 3", icon: Icons.flag, color: app.theme.priorityColor(3), hint: "3" },
      { key: 4, text: "Priority 4", icon: Icons.flag, color: app.theme.priorityColor(4), hint: "4" }
    ]
    onPicked: function(item) { app.setPriority(app.pickerTaskId, item.key); app.closeOverlay("priority") }
  }

  ListPicker {
    id: menuPicker
    name: "menu"
    theme: app.theme
    app: app
    title: app.view.name || ""
    showField: false
    cardWidth: 380
    items: app.menuActions
    onPicked: function(item) { app.runMenu(item.key) }
  }

  PromptDialog { id: prompt; theme: app.theme; app: app }
  ConfirmDialog { id: confirm; theme: app.theme; app: app }
  ProjectDialog { id: projectDialog; theme: app.theme; app: app }
  SettingsDialog { id: settings; theme: app.theme; app: app }
  ShortcutsDialog { id: shortcuts; theme: app.theme; app: app }
}
