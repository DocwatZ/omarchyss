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
  property bool spotifyPlaybackReady: false
  property bool spotifyDeviceRunning: false
  property var spotifyDevices: []
  property string selectedSpotifyDeviceId: ""
  property bool loadingSpotifyDevices: false
  property bool switchingSpotifyDevice: false
  property string deviceError: ""
  property double lastSpotifyDeviceRefreshAt: 0
  property double lastRemotePlayerRefreshAt: 0
  property double remotePlayerSyncPositionMs: 0
  property double remotePlayerSyncedAt: 0
  property int positionTick: 0
  property double spotifyRateLimitedUntil: 0
  property real pendingSeekFraction: -1
  property real pendingVolume: -1
  property var remotePlayer: ({})
  property var searchResults: []
  property bool searching: false
  property bool connectingSpotify: false
  property bool startingPlayback: false
  property string searchError: ""
  property bool beatReactiveEnabled: String(setting("beatReactive", false)) === "true"
  property string beatSensitivity: String(setting("beatSensitivity", "high"))
  property string screensaverTextMode: String(setting("textMode", "track"))
  property string screensaverCustomText: String(setting("customText", ""))
  property bool savingScreensaverPreferences: false
  property bool screensaverPreferenceSavePending: false
  property string screensaverSettingsError: ""

  function close() { root.popupOpen = false }

  // The MPRIS player list is reactive (Quickshell.Services.Mpris), so this
  // and everything derived from it update live with no polling -- unlike
  // the bash/playerctl status probe below, which only covers whether our
  // own screensaver window is running.
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var spotifyPlayer: findSpotifyPlayer()
  readonly property bool remotePlayerActive: remotePlayer.active === true
  readonly property bool hasPlayer: remotePlayerActive || spotifyPlayer !== null
  readonly property bool playerIsPlaying: remotePlayerActive
    ? remotePlayer.isPlaying === true : (spotifyPlayer ? spotifyPlayer.isPlaying : false)
  readonly property string playerTrackTitle: remotePlayerActive
    ? String(remotePlayer.title || "") : (spotifyPlayer ? String(spotifyPlayer.trackTitle || "") : "")
  readonly property string playerTrackArtist: remotePlayerActive
    ? String(remotePlayer.artists || "") : (spotifyPlayer ? String(spotifyPlayer.trackArtist || "") : "")
  readonly property string playerArtUrl: trustedSpotifyArtUrl(remotePlayerActive
    ? String(remotePlayer.image || "") : (spotifyPlayer ? String(spotifyPlayer.trackArtUrl || "") : ""))
  readonly property real playerPosition: remotePlayerActive
    ? interpolatedRemotePosition() : (spotifyPlayer ? spotifyPlayer.position : 0)
  readonly property real playerLength: remotePlayerActive
    ? Number(remotePlayer.durationMs || 0) / 1000 : (spotifyPlayer ? spotifyPlayer.length : 0)
  readonly property real playerVolume: remotePlayerActive
    ? Number(remotePlayer.volumePercent || 0) / 100 : (spotifyPlayer ? spotifyPlayer.volume : 0)
  readonly property bool playerVolumeSupported: remotePlayerActive
    ? remotePlayer.volumePercent !== null && remotePlayer.volumePercent !== undefined
    : (spotifyPlayer ? spotifyPlayer.volumeSupported : false)
  readonly property bool playerShuffle: remotePlayerActive
    ? remotePlayer.shuffle === true : (spotifyPlayer ? spotifyPlayer.shuffle : false)
  readonly property string playerRepeatState: remotePlayerActive
    ? String(remotePlayer.repeatState || "off")
    : (spotifyPlayer && spotifyPlayer.loopState === 2 ? "track"
       : (spotifyPlayer && spotifyPlayer.loopState === 1 ? "context" : "off"))

  // Only ever binds to Spotify or spotifyd. Falling back to an arbitrary
  // MPRIS player made the widget control whatever else was running (a
  // browser playing YouTube, for example), which is not what this is for.
  function findSpotifyPlayer() {
    var playingPlayer = null
    var spotifydPlayer = null
    var desktopPlayer = null
    for (var i = 0; i < mprisPlayers.length; i++) {
      var p = mprisPlayers[i]
      var id = ((p.identity || "") + " " + (p.desktopEntry || "")).toLowerCase()
      if (id.indexOf("spotifyd") !== -1) {
        if (p.isPlaying) playingPlayer = p
        spotifydPlayer = p
      } else if (id.indexOf("spotify") !== -1) {
        if (p.isPlaying && !playingPlayer) playingPlayer = p
        else if (!desktopPlayer) desktopPlayer = p
      }
    }
    return playingPlayer || spotifydPlayer || desktopPlayer
  }

  // Album art comes from Spotify's documented CDN. Restricting this keeps
  // MPRIS metadata from causing the shell to read arbitrary local paths or
  // request arbitrary remote resources.
  function trustedSpotifyArtUrl(url) {
    return /^https:\/\/i\.scdn\.co\/image\//.test(String(url)) ? String(url) : ""
  }

  function fmtTime(seconds) {
    seconds = Math.max(0, Math.floor(Number(seconds) || 0))
    var m = Math.floor(seconds / 60), s = seconds % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  function screensaverCommand(action) {
    return ["bash", helperPath, action,
            "--effect", String(setting("effect", "random")),
            "--text-mode", screensaverTextMode,
            "--custom-text", screensaverCustomText,
            "--pause-spotify", setting("pauseSpotify", true) ? "true" : "false",
            "--timeout", String(setting("autoCloseSeconds", 0)),
            "--beat-reactive", beatReactiveEnabled ? "true" : "false",
            "--beat-sensitivity", beatSensitivity,
            "--font-size", String(setting("fontSize", 28)),
            "--use-figlet", setting("useFiglet", false) ? "true" : "false",
            "--figlet-font", String(setting("figletFontPath", ""))]
  }

  function startOrStop() {
    Quickshell.execDetached(running
      ? ["bash", helperPath, "stop"]
      : screensaverCommand("start"))
    Qt.callLater(refresh)
  }

  function media(action) {
    Quickshell.execDetached(["bash", helperPath, "media", action])
    Qt.callLater(refresh)
  }

  // Web-API now-playing polling is throttled (to protect Spotify's quota),
  // so remotePlayer.progressMs only refreshes every few seconds. Interpolate
  // locally between polls -- based on wall-clock time elapsed since the
  // last successful fetch -- so the progress bar/time still tick smoothly
  // every second instead of visibly jumping. positionTick is read only to
  // give this binding a reactive dependency on the 1s UI timer below.
  function interpolatedRemotePosition() {
    positionTick
    var positionMs = remotePlayerSyncPositionMs
    if (playerIsPlaying)
      positionMs += Date.now() - remotePlayerSyncedAt
    var lengthMs = Number(remotePlayer.durationMs || 0)
    if (lengthMs > 0) positionMs = Math.min(positionMs, lengthMs)
    return Math.max(0, positionMs) / 1000
  }

  // Direct MPRIS controls for the popup overlay. Reactive and instant --
  // unlike media() above (which shells out to playerctl via bin/omarchyss
  // and is only used for the quick bar-icon gestures), these read/write the
  // Quickshell.Services.Mpris player object directly, so seek/volume/shuffle
  // work without adding new bash subcommands.
  function runSpotifyControl(args) {
    if (spotifyLoggedIn && remotePlayerActive) {
      controlProcess.command = ["python3", root.spotifyHelperPath, "control"].concat(args)
      controlProcess.running = false
      controlProcess.running = true
      return true
    }
    return false
  }

  function playPause() {
    if (!runSpotifyControl(["play-pause"]) && spotifyPlayer && spotifyPlayer.canTogglePlaying)
      spotifyPlayer.togglePlaying()
  }
  function nextTrack() {
    if (!runSpotifyControl(["next"]) && spotifyPlayer && spotifyPlayer.canGoNext)
      spotifyPlayer.next()
  }
  function previousTrack() {
    if (!runSpotifyControl(["previous"]) && spotifyPlayer && spotifyPlayer.canGoPrevious)
      spotifyPlayer.previous()
  }
  function seekToFraction(fraction) {
    if (remotePlayerActive) {
      pendingSeekFraction = fraction
      seekDebounce.restart()
    } else if (spotifyPlayer && spotifyPlayer.canSeek && spotifyPlayer.lengthSupported) {
      var target = fraction * spotifyPlayer.length
      spotifyPlayer.seek(target - spotifyPlayer.position)
    }
  }
  function setVolume(v) {
    if (remotePlayerActive) {
      pendingVolume = v
      volumeDebounce.restart()
    } else if (spotifyPlayer && spotifyPlayer.volumeSupported) {
      spotifyPlayer.volume = v
    }
  }
  function toggleShuffle() {
    if (!runSpotifyControl(["shuffle", playerShuffle ? "false" : "true"])
        && spotifyPlayer && spotifyPlayer.shuffleSupported)
      spotifyPlayer.shuffle = !spotifyPlayer.shuffle
  }
  function toggleLoop() {
    var next = playerRepeatState === "off" ? "track"
      : (playerRepeatState === "track" ? "context" : "off")
    if (!runSpotifyControl(["repeat", next]) && spotifyPlayer && spotifyPlayer.loopSupported)
      spotifyPlayer.loopState = (spotifyPlayer.loopState + 1) % 3
  }

  function refreshSpotifyAuthStatus() {
    spotifyStatusProbe.running = false
    spotifyStatusProbe.running = true
  }

  function scheduleScreensaverPreferenceSave() {
    savingScreensaverPreferences = true
    screensaverPreferenceSavePending = true
    screensaverSettingsError = ""
    preferencesSaveTimer.restart()
  }

  function toggleBeatReactive() {
    beatReactiveEnabled = !beatReactiveEnabled
    scheduleScreensaverPreferenceSave()
  }

  function saveBeatSensitivity(value) {
    beatSensitivity = value
    scheduleScreensaverPreferenceSave()
  }

  function saveCustomText(text) {
    var mode = text.trim() === "" ? "track" : "custom"
    if (text === screensaverCustomText && mode === screensaverTextMode) return
    screensaverCustomText = text
    screensaverTextMode = mode
    scheduleScreensaverPreferenceSave()
  }

  function spotifyDeviceOptions() {
    var options = []
    for (var i = 0; i < spotifyDevices.length; i++) {
      var device = spotifyDevices[i]
      var type = String(device.type || "").toLowerCase()
      var suffix = type ? " · " + type : ""
      options.push({
        value: String(device.id || ""),
        label: (device.is_active ? "● " : "") + String(device.name || "Unknown device") + suffix
      })
    }
    if (options.length === 0) {
      options.push({
        value: "",
        label: loadingSpotifyDevices ? "Loading devices..." : "No devices found"
      })
    }
    return options
  }

  function isSpotifyRateLimited() {
    return Date.now() < spotifyRateLimitedUntil
  }

  function describeSpotifyError(rawText, fallback) {
    var text = String(rawText || "").trim()
    if (text.indexOf("(429)") !== -1) {
      spotifyRateLimitedUntil = Date.now() + 60000
      return "Spotify API quota reached for now. This clears automatically " +
        "\u2014 try again in a minute."
    }
    return text || fallback
  }

  function refreshSpotifyDevices(force) {
    if (!spotifyLoggedIn || devicesProcess.running) return
    if (!force && isSpotifyRateLimited()) return
    var now = Date.now()
    if (!force && now - lastSpotifyDeviceRefreshAt < 15000) return
    lastSpotifyDeviceRefreshAt = now
    loadingSpotifyDevices = true
    deviceError = ""
    devicesProcess.running = false
    devicesProcess.running = true
  }

  function refreshRemotePlayer(force) {
    if (!spotifyLoggedIn || nowPlayingProcess.running) return
    if (!force && isSpotifyRateLimited()) return
    var now = Date.now()
    if (!force && now - lastRemotePlayerRefreshAt < 5000) return
    lastRemotePlayerRefreshAt = now
    nowPlayingProcess.running = true
  }

  function transferSpotifyPlayback(deviceId) {
    if (!deviceId || deviceId === selectedSpotifyDeviceId) return
    switchingSpotifyDevice = true
    deviceError = ""
    transferProcess.command = ["python3", root.spotifyHelperPath, "transfer", deviceId]
    transferProcess.running = false
    transferProcess.running = true
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
    searchError = ""
    startingPlayback = true
    playProcess.command = ["python3", root.spotifyHelperPath, "play", uri]
    if (selectedSpotifyDeviceId)
      playProcess.command.push(selectedSpotifyDeviceId)
    playProcess.running = false
    playProcess.running = true
  }

  function startSpotifySetup() {
    searchError = ""
    connectingSpotify = true
    spotifySetupProcess.command = spotifyLoggedIn
      ? ["python3", root.spotifyHelperPath, "device", "setup"]
      : ["python3", root.spotifyHelperPath, "setup"]
    spotifySetupProcess.running = false
    spotifySetupProcess.running = true
  }

  function saveClientIdAndConnect(clientId) {
    clientId = clientId.trim()
    if (!/^[0-9a-fA-F]{32}$/.test(clientId)) {
      searchError = "Spotify Client ID must be 32 hexadecimal characters."
      return
    }
    if (clientId.toLowerCase() === "0388ab0cbad445a4a67499815dc37891") {
      searchError = "That Client ID is the old shared app and its quota is " +
        "exhausted. Create your own free app at " +
        "developer.spotify.com/dashboard and enter its Client ID instead."
      return
    }
    searchError = ""
    connectingSpotify = true
    spotifySetupProcess.command = ["python3", root.spotifyHelperPath, "setup", clientId]
    spotifySetupProcess.running = false
    spotifySetupProcess.running = true
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

  onPopupOpenChanged: {
    if (popupOpen) {
      refreshSpotifyAuthStatus()
    }
  }

  Component.onCompleted: refreshSpotifyAuthStatus()

  // Slider drags fire onMoved continuously; debounce seek/volume so only
  // one control request goes out per pause instead of one per pixel of
  // drag (which raced controlProcess restarts and burned API quota).
  Timer {
    id: seekDebounce
    interval: 150
    repeat: false
    onTriggered: {
      if (root.pendingSeekFraction >= 0) {
        root.runSpotifyControl(["seek", String(Math.round(root.pendingSeekFraction * root.playerLength * 1000))])
        root.pendingSeekFraction = -1
      }
    }
  }

  Timer {
    id: volumeDebounce
    interval: 150
    repeat: false
    onTriggered: {
      if (root.pendingVolume >= 0) {
        root.runSpotifyControl(["volume", String(Math.round(root.pendingVolume * 100))])
        root.pendingVolume = -1
      }
    }
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

  // Advances the popup's progress bar smoothly between position updates
  // (MPRIS only reports on track/seek changes; the Web API poll below is
  // throttled to protect Spotify's quota). positionTick just needs to
  // change every second to re-evaluate interpolatedRemotePosition()'s
  // binding; the periodic refreshRemotePlayer() call resyncs it against
  // the real server-reported position (and self-throttles internally).
  Timer {
    interval: 1000
    running: root.popupOpen && root.hasPlayer
    repeat: true
    onTriggered: {
      root.positionTick++
      if (root.remotePlayerActive) root.refreshRemotePlayer()
      else if (root.spotifyPlayer) root.spotifyPlayer.positionChanged()
    }
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
          root.spotifyPlaybackReady = s.playbackReady === true
          root.spotifyDeviceRunning = s.deviceRunning === true
          var preferences = s.preferences || {}
          if (!root.savingScreensaverPreferences) {
            if (preferences.beatReactive !== undefined)
              root.beatReactiveEnabled = preferences.beatReactive === true
            if (preferences.beatSensitivity !== undefined)
              root.beatSensitivity = String(preferences.beatSensitivity)
            if (preferences.customText !== undefined)
              root.screensaverCustomText = String(preferences.customText)
            if (preferences.textMode !== undefined)
              root.screensaverTextMode = String(preferences.textMode)
          }
          if (root.spotifyLoggedIn) {
            root.refreshSpotifyDevices()
            root.refreshRemotePlayer()
          }
        } catch (e) {
          root.spotifyConfigured = false
          root.spotifyLoggedIn = false
          root.spotifyPlaybackReady = false
          root.spotifyDeviceRunning = false
        }
      }
    }
  }

  Process {
    id: preferencesProcess
    stderr: StdioCollector {
      id: preferencesStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.screensaverSettingsError = String(preferencesStderr.text || "").trim()
          || "Could not save screensaver settings."
      }
      if (root.screensaverPreferenceSavePending)
        preferencesSaveTimer.restart()
      else {
        root.savingScreensaverPreferences = false
        if (exitCode === 0 && root.running)
          Quickshell.execDetached(root.screensaverCommand("restart"))
      }
    }
  }

  Timer {
    id: preferencesSaveTimer
    interval: 250
    repeat: false
    onTriggered: {
      if (preferencesProcess.running) {
        restart()
        return
      }
      root.screensaverPreferenceSavePending = false
      preferencesProcess.command = [
        "python3", root.spotifyHelperPath, "preferences", "set",
        "beatReactive", root.beatReactiveEnabled ? "true" : "false",
        "beatSensitivity", root.beatSensitivity,
        "customText", root.screensaverCustomText,
        "textMode", root.screensaverTextMode
      ]
      preferencesProcess.running = true
    }
  }

  Timer {
    id: customTextSaveTimer
    interval: 500
    repeat: false
    onTriggered: root.saveCustomText(customScreensaverText.text)
  }

  Process {
    id: nowPlayingProcess
    command: ["python3", root.spotifyHelperPath, "now-playing"]
    stderr: StdioCollector {
      id: nowPlayingStderr
      waitForEnd: true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.remotePlayer = JSON.parse(text)
          root.remotePlayerSyncPositionMs = Number(root.remotePlayer.progressMs || 0)
          root.remotePlayerSyncedAt = Date.now()
        } catch (e) {
          root.remotePlayer = ({})
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.describeSpotifyError(nowPlayingStderr.text, "")
    }
  }

  Process {
    id: controlProcess
    stderr: StdioCollector {
      id: controlStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.deviceError = root.describeSpotifyError(controlStderr.text, "Spotify control failed.")
      }
      root.refreshRemotePlayer(true)
      root.refreshSpotifyDevices()
    }
  }

  Process {
    id: devicesProcess
    command: ["python3", root.spotifyHelperPath, "devices"]
    stderr: StdioCollector {
      id: devicesStderr
      waitForEnd: true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loadingSpotifyDevices = false
        try {
          root.spotifyDevices = JSON.parse(text)
          root.selectedSpotifyDeviceId = ""
          for (var i = 0; i < root.spotifyDevices.length; i++) {
            if (root.spotifyDevices[i].is_active) {
              root.selectedSpotifyDeviceId = String(root.spotifyDevices[i].id || "")
              break
            }
          }
        } catch (e) {
          root.spotifyDevices = []
          root.deviceError = "Could not load Spotify devices."
        }
      }
    }
    onExited: function(exitCode) {
      root.loadingSpotifyDevices = false
      if (exitCode !== 0) {
        root.spotifyDevices = []
        root.deviceError = root.describeSpotifyError(devicesStderr.text, "Could not load Spotify devices.")
      }
    }
  }

  Process {
    id: transferProcess
    stderr: StdioCollector {
      id: transferStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.switchingSpotifyDevice = false
      if (exitCode === 0) {
        root.refreshSpotifyDevices()
        root.refreshRemotePlayer(true)
      } else {
        root.deviceError = String(transferStderr.text || "").trim()
          || "Could not switch Spotify devices."
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

  Process {
    id: playProcess
    stderr: StdioCollector {
      id: playStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.startingPlayback = false
      if (exitCode !== 0) {
        root.searchError = String(playStderr.text || "").trim()
          || "Could not start playback. Open Spotify, start any song once, then try again."
      }
      root.refreshRemotePlayer(true)
      root.refreshSpotifyDevices()
    }
  }

  Process {
    id: spotifySetupProcess
    stderr: StdioCollector {
      id: spotifySetupStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.connectingSpotify = false
      root.refreshSpotifyAuthStatus()
      if (exitCode !== 0) {
        root.searchError = String(spotifySetupStderr.text || "").trim()
          || "Spotify setup failed. Try again."
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Image {
        anchors.fill: parent
        anchors.margins: 3
        source: Qt.resolvedUrl("assets/omarchyss.png")
        fillMode: Image.PreserveAspectFit
        sourceSize.width: 48
        sourceSize.height: 48
        smooth: true
      }
    }
    active: root.running
    activeColor: Color.accent
    horizontalMargin: 5.5
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

  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: popupFocusTarget
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Flickable {
      id: popupScroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: popupScroll.width
        spacing: Style.space(10)

        Item {
          id: popupFocusTarget
          width: 1
          height: 1
          focus: true
          Keys.onEscapePressed: root.close()
        }

      // --- Now playing -------------------------------------------------
      Row {
        spacing: Style.space(10)
        width: parent.width
        visible: root.hasPlayer

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
            source: root.playerArtUrl
            visible: source !== ""
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: root.playerArtUrl === ""
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
            textFormat: Text.PlainText
            text: root.playerTrackTitle || "Nothing playing"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.playerTrackArtist
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
        visible: root.hasPlayer && root.playerLength > 0

        Slider {
          id: seekSlider
          width: parent.width
          from: 0
          to: 1
          value: root.playerLength > 0 ? root.playerPosition / root.playerLength : 0
          enabled: root.remotePlayerActive || (root.spotifyPlayer && root.spotifyPlayer.canSeek)
          onMoved: root.seekToFraction(value)
        }

        Row {
          width: parent.width
          Text {
            textFormat: Text.PlainText
            text: root.fmtTime(root.playerPosition)
            color: Qt.darker(root.bar.foreground, 1.4)
            font.pixelSize: Style.font.caption
          }
          Item { width: parent.width - Style.space(80); height: 1 }
          Text {
            textFormat: Text.PlainText
            text: root.fmtTime(root.playerLength)
            color: Qt.darker(root.bar.foreground, 1.4)
            font.pixelSize: Style.font.caption
          }
        }
      }

      // --- Transport controls --------------------------------------------
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(14)
        visible: root.hasPlayer

        BarIconButton {
          width: Style.space(28); height: Style.space(28)
          bar: root.bar
          text: "󰒞"
          active: root.playerShuffle
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
          text: root.playerIsPlaying ? "󰏤" : "󰐊"
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
          text: root.playerRepeatState === "track" ? "󰑘" : "󰑖"
          active: root.playerRepeatState !== "off"
          activeColor: Color.accent
          tooltipText: "Repeat"
          onPressed: root.toggleLoop()
        }
      }

      // --- Volume ----------------------------------------------------------
      Row {
        width: parent.width
        spacing: Style.space(8)
        visible: root.hasPlayer && root.playerVolumeSupported

        Text {
          textFormat: Text.PlainText
          text: "󰕾"
          color: root.bar.foreground
          font.pixelSize: Style.font.body
        }
        Slider {
          width: parent.width - Style.space(24)
          from: 0
          to: 1
          value: root.playerVolume
          onMoved: root.setVolume(value)
        }
      }

      // --- Spotify Connect device -----------------------------------------
      Row {
        width: parent.width
        spacing: Style.space(6)
        visible: root.spotifyLoggedIn

        Dropdown {
          width: parent.width - Style.space(36)
          label: "Playback device"
          fontFamily: root.bar.fontFamily
          options: root.spotifyDeviceOptions()
          value: root.selectedSpotifyDeviceId
          onChanged: function(value) { root.transferSpotifyPlayback(value) }
        }

        BarIconButton {
          width: Style.space(28); height: Style.space(28)
          anchors.bottom: parent.bottom
          bar: root.bar
          text: root.loadingSpotifyDevices || root.switchingSpotifyDevice ? "󰑓" : "󰑐"
          enabled: !root.loadingSpotifyDevices && !root.switchingSpotifyDevice
          tooltipText: "Refresh Spotify devices"
          onPressed: root.refreshSpotifyDevices(true)
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.deviceError !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.deviceError
        color: Color.accent
        font.pixelSize: Style.font.caption
      }

      // --- Screensaver ----------------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: "Screensaver"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            width: parent.width - beatToggle.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: "Beat-reactive effects"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ToggleSwitch {
            id: beatToggle
            anchors.verticalCenter: parent.verticalCenter
            checked: root.beatReactiveEnabled
            busy: root.savingScreensaverPreferences
            foreground: root.bar.foreground
            accent: Color.accent
            onToggled: root.toggleBeatReactive()
          }
        }

        Dropdown {
          width: parent.width
          label: "Beat sensitivity"
          fontFamily: root.bar.fontFamily
          options: [
            { value: "low", label: "Low" },
            { value: "medium", label: "Medium" },
            { value: "high", label: "High" }
          ]
          value: root.beatSensitivity
          onChanged: function(value) { root.saveBeatSensitivity(value) }
        }

        TextField {
          id: customScreensaverText
          width: parent.width
          text: root.screensaverCustomText
          placeholderText: "Custom text (blank uses artist and track)"
          onTextEdited: customTextSaveTimer.restart()
          onAccepted: root.saveCustomText(text)
          onEditingFinished: root.saveCustomText(text)
          Keys.onEscapePressed: root.close()
        }

        Text {
          textFormat: Text.PlainText
          visible: root.running
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.savingScreensaverPreferences
            ? "Applying changes..."
            : "Changes apply to the running screensaver."
          color: Qt.darker(root.bar.foreground, 1.3)
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          visible: root.screensaverSettingsError !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.screensaverSettingsError
          color: Color.accent
          font.pixelSize: Style.font.caption
        }
      }

      // --- Search ---------------------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
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
            Keys.onEscapePressed: root.close()
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
          textFormat: Text.PlainText
          visible: !root.spotifyLoggedIn || !root.spotifyPlaybackReady
          width: parent.width
          wrapMode: Text.WordWrap
          color: Qt.darker(root.bar.foreground, 1.3)
          font.pixelSize: Style.font.caption
          text: !root.spotifyConfigured
            ? "Create a Spotify app, add http://127.0.0.1:8945/callback as its Redirect URI, then enter its Client ID below."
            : root.spotifyLoggedIn
            ? "Authorize Spotify once to enable OmarchySS's built-in playback device."
            : "Connect Spotify once to enable search and built-in playback."
        }
        BarIconButton {
          visible: root.spotifyConfigured && (!root.spotifyLoggedIn || !root.spotifyPlaybackReady)
          width: Style.space(28); height: Style.space(28)
          bar: root.bar
          text: "󰀄"
          enabled: !root.connectingSpotify
          tooltipText: root.spotifyLoggedIn ? "Authorize playback" : "Connect Spotify"
          onPressed: { root.startSpotifySetup(); Qt.callLater(function() { spotifyRecheck.start() }) }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.spotifyConfigured

          TextField {
            id: clientIdField
            width: parent.width - Style.space(60)
            placeholderText: "Spotify Client ID"
            onAccepted: root.saveClientIdAndConnect(text)
            Keys.onEscapePressed: root.close()
          }
          BarIconButton {
            width: Style.space(28); height: Style.space(28)
            bar: root.bar
            text: "󰄬"
            enabled: !root.connectingSpotify
            tooltipText: "Save Client ID and connect"
            onPressed: root.saveClientIdAndConnect(clientIdField.text)
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.connectingSpotify
          text: "Waiting for Spotify authorization..."
          color: Qt.darker(root.bar.foreground, 1.3)
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          visible: root.searching
          text: "Searching..."
          color: Qt.darker(root.bar.foreground, 1.3)
          font.pixelSize: Style.font.caption
        }
        Text {
          textFormat: Text.PlainText
          visible: root.startingPlayback
          text: "Starting playback..."
          color: Qt.darker(root.bar.foreground, 1.3)
          font.pixelSize: Style.font.caption
        }
        Text {
          textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
              enabled: root.spotifyPlaybackReady && !root.startingPlayback
              tooltipText: "Play"
              onPressed: root.playSearchResult(modelData.uri)
            }
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
      if (ticks >= 90 || (root.spotifyLoggedIn && root.spotifyPlaybackReady)) { ticks = 0; stop() }
    }
  }
}
