//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// Development harness: loads the TodoTim plugin the way the Omarchy shell does (service, then the
// panel with `service`, `manifest` and a `shell` stub injected), without the rest of Omarchy.
// `Commons/` (and `Ui/`) next to this file must be Omarchy's `shell/Commons` and `shell/Ui`
// (linux/dev/run.sh links them). IPC: `qs -p … ipc call todotim toggle | quickAdd | theme <name>`.
ShellRoot {
  id: root
  readonly property string pluginDir: Quickshell.env("TODOTIM_PLUGIN_DIR")
  readonly property string themesDir: Quickshell.env("OMARCHY_THEMES")
  readonly property var manifest: ({ id: "timvink.todotim", __sourceDir: pluginDir })

  Loader {
    id: serviceLoader
    source: "file://" + root.pluginDir + "/Service.qml"
    onLoaded: item.manifest = root.manifest
  }

  QtObject {
    id: shellStub
    function hide(id) { if (panelLoader.item) panelLoader.item.close(); return true }
  }

  Loader {
    id: panelLoader
    active: serviceLoader.status === Loader.Ready
    source: "file://" + root.pluginDir + "/Panel.qml"
    onLoaded: {
      item.manifest = root.manifest
      item.shell = shellStub
      item.service = serviceLoader.item
      item.open("{}")
    }
  }

  // Applies a theme like `omarchy-theme-set`: the palette goes to Commons.Color (as the shell's
  // applyTheme IPC does) and colors.toml lands in the current-theme folder that plugins read.
  property string pendingTheme: ""
  FileView {
    id: themeColors
    path: root.pendingTheme ? root.themesDir + "/" + root.pendingTheme + "/colors.toml" : ""
    printErrors: true
    onLoaded: {
      Commons.Color.loadColors(text())
      Commons.Color.loadShell("")
      Style.scheduleRefresh()
    }
  }

  IpcHandler {
    target: "todotim"
    function toggle(): void {
      var p = panelLoader.item
      if (!p) return
      if (p.opened) p.close()
      else p.open("{}")
    }
    function quickAdd(): void { if (panelLoader.item) panelLoader.item.open("{\"action\":\"quickAdd\"}") }
    function theme(name: string): string {
      root.pendingTheme = name
      themeColors.reload()
      return "ok"
    }
  }
}
