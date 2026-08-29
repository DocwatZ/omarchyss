import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.docwatz.omarchyss"

  readonly property string helperPath: Qt.resolvedUrl("bin/omarchyss").toString().replace(/^file:\/\//, "")
  readonly property string spotifyHelperPath: Qt.resolvedUrl("bin/omarchyss-spotify").toString().replace(/^file:\/\//, "")
  property bool running: false
  property string track: ""
  property string playback: ""
  property bool popupOpen: false

  // Web-API auth state (search/play-by-name), refreshed each time the
  // popup opens. MPRIS controls below work regardless of this.
  property bool spotifyConfigured: false
  property bool spotifyLoggedIn: false
  property var searchResults: []
  property bool searching: false
  property string searchError: ""

  function close() { root.popupOpen = false }

  // The MPRIS player list is reactive (Quickshell.Services.Mpris), so this
  // and everything derived from it update live with no polling -- unlike
  // the bash/playerctl status probe below, which only covers whether our
  // own screensaver window is running.
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var spotifyPlayer: findSpotifyPlayer()

  function findSpotifyPlayer() {
    for (var i = 0; i < mprisPlayers.length; i++) {
      var p = mprisPlayers[i]
      var id = ((p.identity || "") + " " + (p.desktopEntry || "")).toLowerCase()
      if (id.indexOf("spotify") !== -1) return p
    }
    return mprisPlayers.length > 0 ? mprisPlayers[0] : null
  }

  function fmtTime(seconds) {
    seconds = Math.max(0, Math.floor(Number(seconds) || 0))
    var m = Math.floor(seconds / 60), s = seconds % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  function startOrStop() {
    var args = ["bash", helperPath, running ? "stop" : "start",
                "--effect", String(setting("effect", "random")),
                "--text-mode", String(setting("textMode", "track")),
                "--custom-text", String(setting("customText", "")),
                "--pause-spotify", setting("pauseSpotify", true) ? "true" : "false",
                "--timeout", String(setting("autoCloseSeconds", 0)),
                "--beat-reactive", setting("beatReactive", false) ? "true" : "false",
                "--font-size", String(setting("fontSize", 28)),
                "--use-figlet", setting("useFiglet", false) ? "true" : "false",
                "--figlet-font", String(setting("figletFontPath", ""))]
    Quickshell.execDetached(args)
    Qt.callLater(refresh)
  }

  function media(action) {
    Quickshell.execDetached(["bash", helperPath, "media", action])
    Qt.callLater(refresh)
  }

  // Direct MPRIS controls for the popup overlay. Reactive and instant --
  // unlike media() above (which shells out to playerctl via bin/omarchyss
  // and is only used for the quick bar-icon gestures), these read/write the
  // Quickshell.Services.Mpris player object directly, so seek/volume/shuffle
  // work without adding new bash subcommands.
  function playPause() { if (spotifyPlayer && spotifyPlayer.canTogglePlaying) spotifyPlayer.togglePlaying() }
  function nextTrack() { if (spotifyPlayer && spotifyPlayer.canGoNext) spotifyPlayer.next() }
  function previousTrack() { if (spotifyPlayer && spotifyPlayer.canGoPrevious) spotifyPlayer.previous() }
  function seekToFraction(fraction) {
    if (!spotifyPlayer || !spotifyPlayer.canSeek || !spotifyPlayer.lengthSupported) return
    var target = fraction * spotifyPlayer.length
    spotifyPlayer.seek(target - spotifyPlayer.position)
  }
  function setVolume(v) { if (spotifyPlayer && spotifyPlayer.volumeSupported) spotifyPlayer.volume = v }
  function toggleShuffle() { if (spotifyPlayer && spotifyPlayer.shuffleSupported) spotifyPlayer.shuffle = !spotifyPlayer.shuffle }
  function toggleLoop() {
    if (!spotifyPlayer || !spotifyPlayer.loopSupported) return
    // Cycle None -> Track -> Playlist -> None.
    spotifyPlayer.loopState = (spotifyPlayer.loopState + 1) % 3
  }

  function refreshSpotifyAuthStatus() {
    spotifyStatusProbe.running = false
    spotifyStatusProbe.running = true
  }

  function runSearch(query) {
    if (!query) { searchResults = []; searchError = ""; return }
    searching = true
    searchError = ""
    searchProcess.command = ["python3", root.spotifyHelperPath, "search", query, "8"]
    searchProcess.running = false
    searchProcess.running = true
  }

  function playSearchResult(uri) {
    Quickshell.execDetached(["python3", root.spotifyHelperPath, "play", uri])
  }

  function startSpotifyLogin() {
    Quickshell.execDetached(["python3", root.spotifyHelperPath, "auth"])
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

  onPopupOpenChanged: if (popupOpen) refreshSpotifyAuthStatus()

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

  // Advances the popup's progress bar smoothly between MPRIS position
  // updates (which only arrive on track/seek changes, not every second).
  Timer {
    interval: 1000
    running: root.popupOpen && root.spotifyPlayer && root.spotifyPlayer.isPlaying
    repeat: true
    onTriggered: if (root.spotifyPlayer) root.spotifyPlayer.positionChanged()
  }

  Process {
    id: spotifyStatusProbe
    command: ["python3", root.spotifyHelperPath, "status"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          root.spotifyConfigured = s.configured === true
          root.spotifyLoggedIn = s.loggedIn === true
        } catch (e) {
          root.spotifyConfigured = false
          root.spotifyLoggedIn = false
        }
      }
    }
  }

  Process {
    id: searchProcess
    stdout: StdioCollector {
      onStreamFinished: {
        root.searching = false
        try {
          root.searchResults = JSON.parse(text)
          root.searchError = ""
        } catch (e) {
          root.searchResults = []
          root.searchError = "Search failed. Are you logged in to Spotify? (right-click \u2192 Connect Spotify)"
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰈈"
    active: root.running
    activeColor: Color.accent
    tooltipText: root.running
      ? "OmarchySS active — Left: stop · Right: Spotify · Middle: next" +
        (root.track ? "\n" + root.track : "")
      : "OmarchySS — Left: start · Right: Spotify · Middle: next" +
        (root.track ? "\n" + root.track : "")
    onPressed: function(button) {
      if (button === Qt.LeftButton) root.startOrStop()
      else if (button === Qt.RightButton) root.popupOpen = !root.popupOpen
      else if (button === Qt.MiddleButton) root.nextTrack()
    }
    onWheelMoved: function(delta) { if (delta > 0) root.previousTrack(); else root.nextTrack() }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      // --- Now playing -------------------------------------------------
      Row {
        spacing: Style.space(10)
        width: parent.width
        visible: root.spotifyPlayer !== null

        BorderSurface {
          width: Style.space(64)
          height: Style.space(64)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.spotifyPlayer && root.spotifyPlayer.trackArtUrl ? root.spotifyPlayer.trackArtUrl : ""
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: !root.spotifyPlayer || !root.spotifyPlayer.trackArtUrl
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(4)
          width: parent.width - Style.space(74)

          Text {
            text: root.spotifyPlayer ? (root.spotifyPlayer.trackTitle || "Nothing playing") : "No player found"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: root.spotifyPlayer ? (root.spotifyPlayer.trackArtist || "") : ""
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      // --- Progress / seek ----------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.spotifyPlayer !== null && root.spotifyPlayer.lengthSupported

        Slider {
          id: seekSlider
          width: parent.width
          from: 0
          to: 1
          value: root.spotifyPlayer && root.spotifyPlayer.length > 0
            ? root.spotifyPlayer.position / root.spotifyPlayer.length : 0
          enabled: root.spotifyPlayer && root.spotifyPlayer.canSeek
          onMoved: root.seekToFraction(value)
        }

        Row {
          width: parent.width
          Text {
            text: root.spotifyPlayer ? root.fmtTime(root.spotifyPlayer.position) : "0:00"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.pixelSize: Style.font.caption
          }
          Item { width: parent.width - Style.space(80); height: 1 }
          Text {
            text: root.spotifyPlayer ? root.fmtTime(root.spotifyPlayer.length) : "0:00"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.pixelSize: Style.font.caption
          }
        }
      }

      // --- Transport controls --------------------------------------------
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(14)
        visible: root.spotifyPlayer !== null

        BarIconButton {
          width: Style.space(28); height: Style.space(28)
          bar: root.bar
          text: "󰒞"
          active: root.spotifyPlayer && root.spotifyPlayer.shuffle
          activeColor: Color.accent
          tooltipText: "Shuffle"
          onPressed: root.toggleShuffle()
        }
        BarIconButton {
          width: Style.space(28); height: Style.space(28)
          bar: root.bar
          text: "󰒮"
          tooltipText: "Previous"
          onPressed: root.previousTrack()
        }
        BarIconButton {
          width: Style.space(36); height: Style.space(36)
          bar: root.bar
          text: root.spotifyPlayer && root.spotifyPlayer.isPlaying ? "󰏤" : "󰐊"
          activeColor: Color.accent
          tooltipText: "Play/Pause"
          onPressed: root.playPause()
        }
        BarIconButton {
          width: Style.space(28); height: Style.space(28)
          bar: root.bar
          text: "󰒭"
          tooltipText: "Next"
          onPressed: root.nextTrack()
        }
        BarIconButton {
          width: Style.space(28); height: Style.space(28)
          bar: root.bar
          text: root.spotifyPlayer && root.spotifyPlayer.loopState === 2 ? "󰑘" : "󰑖"
          active: root.spotifyPlayer && root.spotifyPlayer.loopState !== 0
          activeColor: Color.accent
          tooltipText: "Repeat"
          onPressed: root.toggleLoop()
        }
      }

      // --- Volume ----------------------------------------------------------
      Row {
        width: parent.width
        spacing: Style.space(8)
        visible: root.spotifyPlayer !== null && root.spotifyPlayer.volumeSupported

        Text {
          text: "󰕾"
          color: root.bar.foreground
          font.pixelSize: Style.font.body
        }
        Slider {
          width: parent.width - Style.space(24)
          from: 0
          to: 1
          value: root.spotifyPlayer ? root.spotifyPlayer.volume : 0
          onMoved: root.setVolume(value)
        }
      }

      // --- Search ---------------------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: "Search Spotify"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.spotifyLoggedIn

          TextField {
            id: searchField
            width: parent.width - Style.space(60)
            placeholderText: "Song, artist..."
            onAccepted: root.runSearch(text)
          }
          BarIconButton {
            width: Style.space(28); height: Style.space(28)
            bar: root.bar
            text: "󰍉"
            tooltipText: "Search"
            onPressed: root.runSearch(searchField.text)
          }
        }

        Text {
          visible: !root.spotifyLoggedIn
          width: parent.width
          wrapMode: Text.WordWrap
          color: Qt.darker(root.bar.foreground, 1.3)
          font.pixelSize: Style.font.caption
          text: root.spotifyConfigured
            ? "Not connected. Click to log in to Spotify."
            : "Spotify search needs a one-time setup. See the OmarchySS README, then click to log in."
        }
        BarIconButton {
          visible: !root.spotifyLoggedIn
          width: Style.space(28); height: Style.space(28)
          bar: root.bar
          text: "󰀄"
          tooltipText: "Connect Spotify"
          onPressed: { root.startSpotifyLogin(); Qt.callLater(function() { spotifyRecheck.start() }) }
        }

        Text {
          visible: root.searching
          text: "Searching..."
          color: Qt.darker(root.bar.foreground, 1.3)
          font.pixelSize: Style.font.caption
        }
        Text {
          visible: root.searchError !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.searchError
          color: Color.accent
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.searchResults
          delegate: Row {
            width: column.width
            spacing: Style.space(8)

            Text {
              width: parent.width - Style.space(34)
              elide: Text.ElideRight
              text: modelData.name + "  ·  " + modelData.artists
              color: root.bar.foreground
              font.pixelSize: Style.font.bodySmall
            }
            BarIconButton {
              width: Style.space(24); height: Style.space(24)
              bar: root.bar
              text: "󰐊"
              tooltipText: "Play"
              onPressed: root.playSearchResult(modelData.uri)
            }
          }
        }
      }
    }
  }

  // Spotify's OAuth login runs in a background helper (auth opens the
  // user's browser); poll auth status for a few seconds after clicking
  // "Connect Spotify" so the popup updates once login completes.
  Timer {
    id: spotifyRecheck
    interval: 4000
    repeat: true
    property int ticks: 0
    onTriggered: {
      ticks += 1
      root.refreshSpotifyAuthStatus()
      if (ticks >= 15 || root.spotifyLoggedIn) { ticks = 0; stop() }
    }
  }
}
