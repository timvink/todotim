import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// TodoTim's colors, type and spacing, all derived from the active Omarchy theme. The core palette
// and the type/spacing scale come from the shell's `Commons.Color` and `Style` (so a theme switch
// or `omarchy font`/`display text size` retints the app live); the named colors that the shell
// does not expose (green, yellow, orange, magenta for due dates and priorities) are read from the
// theme's colors.toml whenever the shell applies a theme.
QtObject {
  id: theme

  readonly property color bg: Commons.Color.background
  readonly property color fg: Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property color muted: Commons.Color.muted

  // Named colors from colors.toml (with the legacy colorN names as fallbacks).
  property var named: ({})
  function pick(keys, fallback) {
    for (var i = 0; i < keys.length; i++) {
      var v = named[keys[i]]
      if (v) return v
    }
    return fallback
  }
  readonly property bool light: named.mode === "light" || (named.mode === undefined && luminance(bg) > 0.5)
  readonly property color red: pick(["red", "color1"], urgent)
  readonly property color green: pick(["green", "color2"], "#7fb069")
  readonly property color yellow: pick(["yellow", "color3"], "#d9a441")
  readonly property color orange: pick(["orange", "bright_yellow", "yellow", "color3"], "#e08a3c")
  readonly property color blue: pick(["blue", "color4"], accent)
  readonly property color magenta: pick(["magenta", "color5"], "#b07cd8")
  readonly property color cyan: pick(["cyan", "color6"], accent)
  readonly property color selection: pick(["selection"], mix(bg, accent, 0.25))

  // Surfaces and text, mixed from the palette so light and dark themes both work.
  readonly property color sidebar: mix(bg, fg, light ? 0.035 : 0.04)
  readonly property color raised: Commons.Color.popups.background
  readonly property color raisedText: Commons.Color.popups.text
  readonly property color popupBorder: Commons.Color.popups.border
  readonly property color scrim: Qt.rgba(0, 0, 0, light ? 0.18 : 0.45)
  readonly property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.10)
  readonly property color lineStrong: Qt.rgba(fg.r, fg.g, fg.b, 0.22)
  readonly property color text: fg
  readonly property color dim: mix(fg, bg, 0.38)
  readonly property color faint: mix(fg, bg, 0.6)
  readonly property color hover: Style.hoverFill
  readonly property color cursorFill: Qt.rgba(accent.r, accent.g, accent.b, light ? 0.14 : 0.16)
  readonly property color cursorEdge: accent
  readonly property color field: mix(bg, fg, light ? 0.05 : 0.07)

  // Type: the shell's monospace family and its scale (Omarchy's `[font] base-size`).
  readonly property string font: Style.font.family
  readonly property int small: Style.font.bodySmall
  readonly property int body: Style.font.subtitle
  readonly property int task: Style.font.title
  readonly property int heading: Style.font.heading
  readonly property int title: Style.font.display
  readonly property int icon: Style.font.icon
  readonly property int radius: Style.cornerRadius

  function space(px) { return Style.space(px) }
  function duration(ms) { return Style.duration(ms) }
  readonly property var easeOut: Style.easeOut

  function luminance(c) { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
  function mix(a, b, t) {
    a = Qt.color(a); b = Qt.color(b)
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }
  function alpha(c, a) { c = Qt.color(c); return Qt.rgba(c.r, c.g, c.b, a) }

  // Todoist's meanings in the theme's own colors.
  function priorityColor(p) {
    return p === 1 ? red : p === 2 ? orange : p === 3 ? blue : faint
  }
  function dueColor(kind) {
    switch (kind) {
      case "overdue": return red
      case "today": return green
      case "tomorrow": return orange
      case "week": return magenta
      default: return dim
    }
  }
  // Project/label palette colors (Todoist's) are kept as stored; the inbox uses the accent.
  function projectColor(hex) { return hex ? hex : accent }

  // ---- colors.toml
  readonly property string themeDir: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme"

  function parseColors(raw) {
    var out = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?([^"'#\s]+)/)
      if (!m) continue
      var value = m[2]
      if (m[1] === "mode") out.mode = value
      else if (/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/.test(value)) out[m[1]] = value
    }
    return out
  }

  property FileView colorsFile: FileView {
    path: theme.themeDir + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: theme.named = theme.parseColors(text())
    onFileChanged: reload()
    onLoadFailed: theme.named = ({})
  }

  // A theme switch replaces the whole theme folder and pushes the new palette to the shell over
  // IPC; follow the shell's palette, re-reading colors.toml whenever it changes.
  property Connections shellTheme: Connections {
    target: Commons.Color
    function onShellValuesChanged() { theme.colorsFile.reload() }
    function onBackgroundChanged() { theme.colorsFile.reload() }
    function onForegroundChanged() { theme.colorsFile.reload() }
    function onAccentChanged() { theme.colorsFile.reload() }
  }
}
