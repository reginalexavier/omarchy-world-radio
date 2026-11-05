"""Run Panel.qml's actual JavaScript methods in the Qt/QML engine.

The installed plugin, existing player, network, and user state are untouched.
The harness stubs shell/process boundaries; integration tests use temporary
FileView storage and a separate mpv with null audio output.
Run: python3 -m unittest discover -s tests -v (requires quickshell and mpv).
"""
import os
import json
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import unittest
import wave

PANEL = Path(__file__).resolve().parents[1] / "Panel.qml"


class RecentCountries(unittest.TestCase):
    def run_qml(self, body, persist_path=None, station_delegate=False):
        source = PANEL.read_text()
        names = ["sanitizeStationRow", "isValidStationRow", "loadHistory",
                 "flushHistory", "recordHistory", "playStation", "stopPlayback",
                 "handleMpvMessage", "selectCountry", "recentCountriesFromHistory", "resortStations"]
        methods = "\n".join(m.group() for name in names
                            if (m := re.search(r"  function " + name + r"\([^\n]*\) \{.*?\n  \}", source, re.S)))
        props = "\n".join(re.findall(r"^  (?:readonly )?property [^\n]+(?:ObserveId|pendingHistoryRow|recentCountries)[^\n]*", source, re.M))
        handler = re.search(r"id: stationsProc.*?onStreamFinished: \{(.*?)\n      \}", source, re.S)
        assert handler is not None
        station_handler = handler.group(1)
        methods += "\nfunction feedStations(text) {" + station_handler + "\n}"
        flow = re.search(r'              Flow \{\n                id: recentCountriesFlow.*?\n              \}', source, re.S)
        recent_ui = flow.group().replace("Button {", "TestButton {").replace("Style.", "testStyle.") if flow else ""
        station_ui = ""
        if station_delegate:
            delegate = re.search(r'            delegate: Rectangle \{\n              id: row\n.*?\n            \}', source, re.S)
            self.assertIsNotNone(delegate, "production station delegate must exist")
            station_ui = ('ListView { id: stationsList; width: 300; height: 100; model: stationsModel\n'
                          + delegate.group().replace("Style.", "testStyle.").replace("Color.", "colors.") + '\n}')
            for name in ["isFavorite", "toggleFavorite", "formatVoteCount"]:
                methods += "\n" + re.search(r"  function " + name + r"\([^\n]*\) \{.*?\n  \}", source, re.S).group()
        qml = '''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
 Item {
  id: root
  width: 300
  property var bar: ({foreground: "white", fontFamily: "sans"})
  QtObject { id: testStyle; property var font: ({bodySmall: 12, body: 14, caption: 10}); property var spacing: ({controlPaddingX: 6}); property int cornerRadius: 4; function space(n) { return n } function hoverFillFor(f, a) { return a } function selectedFillFor(f, a) { return a } }
  QtObject { id: colors; property color accent: "blue" }
  QtObject { id: voteProc; property bool running: false }
  property string voteUuid: ""
  property string voteInFlightUuid: ""
  property bool voteOk: false
  property var favorites: ({})
  property int maxFavorites: 100
  function scheduleFavoritesSave() {}
  function flagFor(code) { return code }
  property var history: []
  property bool historyLoaded: true
  property int maxHistory: 15
  property bool paused: false
  property string nowPlayingTitle: ""
  property string nowPlayingGenre: ""
  property bool buffering: false
  property int bufferingPercent: 0
  property bool switchingStation: false
  property string countryQuery: ""
  property var countryMatches: []
  property int loads: 0
  property bool stationsSwitching: false
  property bool stationsParseOk: false
  ListModel { id: stationsModel }
  function isFavorite(uuid) { return false }
  property var stationUuidPattern: /^[0-9a-fA-F-]{8,64}$/
  function resetPlaybackDisplay() {}
  function cancelSleepTimer() {}
  function scheduleHistorySave() {}
  function resetGeoFilter() {}
  function loadStations() { loads++ }
  QtObject { id: state; property string stationUuid: ""; property string stationName: ""; property string stationUrl: ""; property bool playing: false; property string countryCode: ""; property string countryName: "" }
  QtObject { id: mpvProc; property bool running: false }
  QtObject { id: clickProc; property bool running: false }
  QtObject { id: ipcSocket; property bool connected: false; function write(s) {} function flush() {} }
  QtObject { id: ipcRetryTimer; property int attempts: 0; function restart() {} function stop() {} }
  QtObject { id: historyFile; property string saved: ""; function setText(s) { saved = s } }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function row(code, uuid) { return {uuid: uuid || code, name: "Station", playUrl: "https://example.org/live", countryCode: code, countryName: "Country " + code} }
''' + props + '\n' + methods + '\n' + recent_ui + '\n' + station_ui + '''
  Timer { interval: 10; running: true; onTriggered: root.runTest() }
  function runTest() {
   try {
''' + body + '''
    console.log("PASS recent countries")
    Qt.exit(0)
   } catch (e) { console.error(e); Qt.exit(1) }
  }
 }
}
'''
        if persist_path:
            qml = qml.replace('QtObject { id: historyFile; property string saved: ""; function setText(s) { saved = s } }',
                              'FileView { id: historyFile; atomicWrites: true; printErrors: false; path: ' + json.dumps(str(persist_path)) + ' }')
        if station_delegate:
            qml = qml.replace('  function isFavorite(uuid) { return false }\n', '')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "shell.qml"
            (Path(tmp) / "TestButton.qml").write_text('''import QtQuick
Item {
 property string text: ""
 property color foreground: "white"
 property string fontFamily: ""
 property int fontSize: 12
 property int horizontalPadding: 0
 property int verticalPadding: 0
 property bool bordered: false
 property bool active: false
 signal clicked()
}
''')
            path.write_text(qml)
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="generic")
            env.pop("WAYLAND_DISPLAY", None)
            result = subprocess.run(["quickshell", "-p", str(path)], env=env,
                                    capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS recent countries", result.stdout + result.stderr)
        self.assertNotIn(" WARN", result.stdout + result.stderr)
        self.assertNotIn(" ERROR", result.stdout + result.stderr)

    def test_recent_countries_are_newest_unique_six_from_persisted_history(self):
        self.run_qml('''
check(recentCountries.length === 0, "empty history")
for (var code of ["US", "BR", "GB", "FR", "DE", "JP", "AU"]) recordHistory(row(code))
recordHistory(row("BR", "another-br-station"))
check(recentCountries.map(function(c) { return c.code }).join(",") === "BR,AU,JP,DE,FR,GB", "newest unique six")
flushHistory(); history = []; historyLoaded = false; loadHistory(historyFile.saved)
check(recentCountries[0].code === "BR", "derived after restart")
var legacy = row(""); delete legacy.countryCode; delete legacy.countryName
recordHistory(legacy)
check(recentCountries[0].code === "BR", "legacy entries ignored")
''')

    def test_only_positive_player_position_records_selected_station_once(self):
        self.run_qml('''
playStation(row("BR"))
check(history.length === 0, "a click is not a successful play")
ipcSocket.connected = true
for (var data of [null, 0, -1, "1"]) handleMpvMessage(JSON.stringify({event: "property-change", id: timePosObserveId, data: data}))
check(history.length === 0, "unavailable or zero position is not playback")
handleMpvMessage(JSON.stringify({event: "property-change", id: timePosObserveId, data: 0.2}))
check(history.length === 1 && history[0].countryCode === "BR", "positive playback position records country")
recordHistory(row("US"))
handleMpvMessage(JSON.stringify({event: "property-change", id: timePosObserveId, data: 1}))
check(history[0].countryCode === "US", "later position updates must not re-record")
playStation(row("JP")); stopPlayback()
handleMpvMessage(JSON.stringify({event: "property-change", id: timePosObserveId, data: 1}))
check(history[0].countryCode === "US", "stopped or failed station must not record")
playStation(row("FR")); playStation(row("DE")); ipcSocket.connected = true
handleMpvMessage(JSON.stringify({event: "property-change", id: timePosObserveId, data: 0.1}))
check(history[0].countryCode === "DE", "only latest station snapshot, not browsing country")
''')

    def test_directory_country_survives_sorting_and_playback(self):
        self.run_qml('''
state.countryCode = "US"
feedStations(JSON.stringify([{stationuuid: "abc", name: "Radio Brazil", url: "https://example.org/live", countrycode: "BR", country: "Brazil"}]))
check(stationsModel.count === 1, "directory row loaded")
check(stationsModel.get(0).countryCode === "BR", "directory country survives resort")
playStation(stationsModel.get(0)); stationsModel.clear(); ipcSocket.connected = true
handleMpvMessage(JSON.stringify({event: "property-change", id: timePosObserveId, data: 1}))
check(recentCountries[0].name === "Brazil", "station country, not current filter")
''')

    def test_production_station_delegate_click_preserves_country_for_history_and_favorites(self):
        self.run_qml('''
state.countryCode = "US"
feedStations(JSON.stringify([{stationuuid: "12345678-abcd", name: "Radio Brazil", url: "https://example.org/live", countrycode: "BR", country: "Brazil"}]))
check(stationsModel.get(0).countryCode === "BR", "directory model has country metadata")
stationsList.forceLayout()
var station = stationsList.itemAtIndex(0)
check(!!station, "production station delegate instantiated")
// Invoke the actual production MouseArea click handlers, not playStation(model.get()).
station.children[0].clicked(null)
check(state.stationUuid === "12345678-abcd", "station row click starts playback")
check(history.length === 0, "station click alone must not record history")
ipcSocket.connected = true
handleMpvMessage(JSON.stringify({event: "property-change", id: timePosObserveId, data: 0.2}))
check(history.length === 1 && history[0].countryCode === "BR" && history[0].countryName === "Brazil", "production station click must preserve history country metadata")
check(recentCountries.length === 1 && recentCountries[0].code === "BR" && recentCountries[0].name === "Brazil", "successful delegate playback creates recent country, not browsing country")
var star = station.children[station.children.length - 1]
star.children[0].clicked(null)
check(!!favorites["12345678-abcd"], "production favorite click adds station")
check(favorites["12345678-abcd"].countryCode === "BR" && favorites["12345678-abcd"].countryName === "Brazil", "production favorite click must preserve country metadata")
''', station_delegate=True)

    def test_recent_country_button_loads_country_directly_without_recording(self):
        self.run_qml('''
var flow = root.children.find(function(c) { return c.objectName === "recentCountries" })
check(!!flow, "recent country shortcuts must exist")
check(!flow.visible, "empty recent section hidden")
recordHistory(row("BR"))
check(flow.visible, "recent section visible after play")
var button = flow.children.find(function(c) { return c.objectName === "recentCountry-BR" })
check(!!button, "recent country button")
button.clicked()
check(state.countryCode === "BR" && loads === 1, "click loads country directly")
check(history.length === 1, "browsing never records a play")
''')
        source = PANEL.read_text()
        self.assertLess(source.index("id: recentCountriesFlow"), source.index("model: root.curatedCountries"))

    def test_country_metadata_survives_history_save_and_reload(self):
        self.run_qml('''
var safe = sanitizeStationRow(row("br"))
check(safe.countryCode === "BR", "country code must survive sanitizing, normalized")
check(safe.countryName === "Country br", "country name must survive sanitizing")
recordHistory(row("br"))
flushHistory()
history = []; historyLoaded = false
loadHistory(historyFile.saved)
check(history[0].countryCode === "BR", "country must survive restart")
check(sanitizeStationRow(row("BAD")).countryCode === "", "invalid country code")
var longName = row("BR"); longName.countryName = "x".repeat(500)
check(sanitizeStationRow(longName).countryName.length === 200, "bounded country name")
check(sanitizeStationRow({countryCode: ["BR"]}).countryCode === "BR", "non-string country metadata must not throw")
historyLoaded = false; loadHistory("malformed")
check(history.length === 0 && recentCountries.length === 0, "corrupt history is safe")
''')


    def test_atomic_file_survives_separate_qml_sessions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "history.json"
            path.write_text('{"version": 1, "history": []}')
            self.run_qml('recordHistory(row("BR")); flushHistory()', persist_path=path)
            raw = path.read_text()
            self.assertEqual(json.loads(raw)["history"][0]["countryCode"], "BR")
            self.run_qml('historyLoaded = false; loadHistory(' + json.dumps(raw) + '); check(recentCountries[0].code === "BR", "restored in second process")')

    def test_real_mpv_position_events_record_only_after_playback_progress(self):
        self.assertIn('["observe_property", root.timePosObserveId, "time-pos"]', PANEL.read_text())
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "silence.wav"
            with wave.open(str(audio), "wb") as out:
                out.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
                out.writeframes(bytes(32000))
            ipc = str(Path(tmp) / "mpv.sock")
            proc = subprocess.Popen(["mpv", "--no-config", "--ao=null", "--no-video", "--idle=yes", "--really-quiet", "--input-ipc-server=" + ipc], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                with socket.socket(socket.AF_UNIX) as client:
                    while True:
                        try:
                            client.connect(ipc)
                            break
                        except (FileNotFoundError, ConnectionRefusedError):
                            if time.monotonic() > deadline:
                                self.fail("mpv IPC did not start")
                            time.sleep(0.02)
                    client.settimeout(5)
                    client.sendall(b'{"command":["observe_property",5,"time-pos"]}\n')
                    with client.makefile("r") as stream:
                        messages = []
                        while not messages:
                            msg = json.loads(stream.readline())
                            if msg.get("event") == "property-change":
                                messages.append(msg)
                        self.assertIsNone(messages[0].get("data"))
                        client.sendall((json.dumps({"command": ["loadfile", str(audio)]}) + "\n").encode())
                        while time.monotonic() < deadline:
                            msg = json.loads(stream.readline())
                            if msg.get("event") == "property-change":
                                messages.append(msg)
                                if isinstance(msg.get("data"), (int, float)) and msg["data"] > 0:
                                    break
                        self.assertGreater(messages[-1].get("data", 0), 0)
                self.run_qml('playStation(row("BR")); ipcSocket.connected = true; var events = ' + json.dumps(messages) + '; handleMpvMessage(JSON.stringify(events[0])); check(history.length === 0, "idle is not playback"); for (var e of events) handleMpvMessage(JSON.stringify(e)); check(history[0].countryCode === "BR", "real mpv progress records country")')
            finally:
                proc.terminate()
                proc.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
