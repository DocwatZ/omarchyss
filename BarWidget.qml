import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.docwatz.omarchyss"

  readonly property string helperPath: Qt.resolvedUrl("bin/omarchyss").toString().replace(/^file:\/\//, "")
  property bool running: false
  property string track: ""
  property string playback: ""

  function startOrStop() {
    var args = ["bash", helperPath, running ? "stop" : "start",
                "--effect", String(setting("effect", "random")),
                "--text-mode", String(setting("textMode", "track")),
                "--custom-text", String(setting("customText", "")),
                "--pause-spotify", setting("pauseSpotify", true) ? "true" : "false",
                "--timeout", String(setting("autoCloseSeconds", 0)),
                "--beat-reactive", setting("beatReactive", false) ? "true" : "false",
                "--font-size", String(setting("fontSize", 28))]
    Quickshell.execDetached(args)
    Qt.callLater(refresh)
  }

  function media(action) {
    Quickshell.execDetached(["bash", helperPath, "media", action])
    Qt.callLater(refresh)
  }

  function ingest(line) {
    try {
      var status = JSON.parse(String(line))
      running = status.running === true
      track = String(status.track || "")
      playback = String(status.playback || "")
    } catch (error) {
      console.warn("OmarchySS status could not be read:", error)
    }
  }

  function refresh() {
    probe.running = false
    probe.running = true
  }

  GlobalShortcut {
    appid: "io.github.docwatz.omarchyss"
    name: "toggle"
    description: "Start or stop OmarchySS"
    onPressed: root.startOrStop()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: probe
    command: ["bash", root.helperPath, "status"]
    running: true
    stdout: SplitParser { onRead: line => root.ingest(line) }
  }

  Timer {
    interval: 3000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰈈"
    active: root.running
    activeColor: Color.accent
    tooltipText: root.running
      ? "OmarchySS active — Left: stop · Right: play/pause · Middle: next" +
        (root.track ? "\n" + root.track : "")
      : "OmarchySS — Left: start · Right: play/pause · Middle: next" +
        (root.track ? "\n" + root.track : "")
    onPressed: function(button) {
      if (button === Qt.LeftButton) root.startOrStop()
      else if (button === Qt.RightButton) root.media("play-pause")
      else if (button === Qt.MiddleButton) root.media("next")
    }
    onWheel: wheel => root.media(wheel.angleDelta.y > 0 ? "previous" : "next")
  }
}
