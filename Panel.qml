import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// World Radio: pick a country (and optionally a mood/genre), get a live
// internet radio station from there and play it — a lightweight nod to
// radiooooo.com's "spin the globe" idea, built on the open Radio Browser
// directory (api.radio-browser.info) rather than any proprietary catalog.
//
// Playback goes through mpv, driven over its JSON IPC socket (Quickshell's
// native Socket type, so no extra CLI dependency like socat/ncat is needed)
// so volume/pause can be controlled live without restarting the stream.
//
// mpv's system-wide config auto-loads the mpv-mpris script for every
// instance, so this already answers to hardware media keys / MPRIS
// (Play/Pause/Stop) without any extra flag here — confirmed live: pausing
// through the shell's own media IPC toggles mpv's pause property. The
// pause/metadata observers below exist so this panel's own Pause/Resume
// label and now-playing title stay correct the instant playback changes
// that way instead of from here.
Panel {
  id: root
  moduleName: "ronnie.worldradio"
  ipcTarget: "ronnie.worldradio"

  // Unchanged, still used as-is by clickProc/voteProc (out of scope for
  // server discovery/retry — see notes there). The station/country/
  // language fetches below use currentApiHost instead.
  readonly property string apiHost: "https://de1.api.radio-browser.info"
  readonly property string userAgent: "OmarchyWorldRadio/1.0 (+https://omarchy.org)"

  // Server discovery: Radio Browser's own documented usage pattern (fetched
  // directly from https://api.radio-browser.info/) is to resolve
  // all.api.radio-browser.info for the current mirror pool and retry a
  // failed request against another entry, rather than hardcoding one
  // server. GET /json/servers (confirmed live) returns that same pool as
  // plain JSON — the exact shape every other endpoint here already
  // parses, so serverListProc below reuses this file's existing curl+JSON
  // pattern instead of a separate DNS mechanism. apiServers starts as just
  // the original hardcoded host so every call site has a usable value
  // immediately, before discovery completes or if it fails outright.
  property var apiServers: ["de1.api.radio-browser.info"]
  property int apiServerIndex: 0
  readonly property string currentApiHost: "https://" + root.apiServers[root.apiServerIndex % root.apiServers.length]

  // One retry each, against the next resolved server — reset per request
  // (loadStations()/ensureCountriesLoaded()/ensureLanguagesLoaded()), not
  // per session. geo lookup and clickProc/voteProc are out of scope: geo
  // lookup isn't even a Radio Browser call (it hits wttr.in), and
  // clickProc/voteProc's own retry-free, single-attempt shape is
  // unchanged.
  property bool stationsRetried: false
  property bool countriesRetried: false
  property bool languagesRetried: false
  // Set every time stationsProc's stdout finishes (success or failure) —
  // stationsProc, unlike countries/languages, retries on curl's exit code
  // in onExited rather than a content check in onStreamFinished, so this
  // is how onExited also learns about a 200-with-malformed-body response.
  property bool stationsParseOk: false
  readonly property int defaultVolume: setting("defaultVolume", 70)
  // mpv's own out-of-the-box default for volume-max — confirmed live, not
  // a new capability this plugin is introducing. mpv itself doesn't clamp
  // set_property volume to any ceiling (confirmed live: it echoes back
  // whatever's set, past 130 or even a raised volume-max), so this plugin
  // enforces the bound client-side, same as every other externally- or
  // user-influenced number in this file.
  readonly property int volumeCeiling: 130
  // Shared by toggleDeepBass() and ipcSocket's reconnect handler — mpv's
  // `af remove` matches by exact filter string, so the two call sites
  // must always agree on this value; naming it once rules out drift.
  readonly property string deepBassFilter: "lavfi=[bass=g=10]"
  // Shared by playStation() (click-tracking) and voteForStation() — both
  // build a URL from an API-supplied stationuuid and need the same shape
  // check before trusting it.
  readonly property var stationUuidPattern: /^[0-9a-fA-F-]{8,64}$/

  // IDs for mpv's observe_property, referenced in both handleMpvMessage and
  // the IPC connect handler — kept as named constants so a future observed
  // property can't silently collide with one of these.
  readonly property int metadataObserveId: 1
  readonly property int pauseObserveId: 2
  readonly property int pausedForCacheObserveId: 3
  readonly property int cacheBufferingStateObserveId: 4
  readonly property int timePosObserveId: 5
  property var pendingHistoryRow: null

  readonly property var curatedCountries: [
    { code: "US", name: "United States" },
    { code: "BR", name: "Brazil" },
    { code: "GB", name: "United Kingdom" },
    { code: "FR", name: "France" },
    { code: "DE", name: "Germany" },
    { code: "NL", name: "Netherlands" },
    { code: "JP", name: "Japan" },
    { code: "KR", name: "South Korea" },
    { code: "AU", name: "Australia" },
    { code: "MX", name: "Mexico" },
    { code: "AR", name: "Argentina" },
    { code: "ZA", name: "South Africa" },
    { code: "TH", name: "Thailand" },
    { code: "MY", name: "Malaysia" },
    { code: "SG", name: "Singapore" },
    { code: "PL", name: "Poland" }
  ]

  readonly property var curatedTags: ["pop", "rock", "jazz", "classical", "electronic", "reggae", "hiphop", "folk", "news", "talk"]
  readonly property var curatedDecades: ["50s", "60s", "70s", "80s", "90s", "2000s", "2010s", "2020s"]

  PersistentProperties {
    id: state
    reloadableId: "worldradio-state"
    property string countryCode: ""
    property string countryName: ""
    property string tag: ""
    property string decade: ""
    property string languageCode: ""
    property string languageName: ""
    property string sortOrder: ""
    property int volume: root.defaultVolume
    property string stationUuid: ""
    property string stationName: ""
    property string stationUrl: ""
    property bool playing: false
    // Expand (today's full two-pane browser) vs Compact (hero + transport +
    // volume only, panel shrunk to fit). Same persistence tier as every
    // other field above: survives a shell config reload, not a full
    // restart — see docs/expand-compact-view-research.md.
    property bool compactView: false
    // Deep bass (mpv's `bass` audio filter, fixed gain, see CONTEXT.md for
    // why this isn't called "Bass boost") — a listener preference, same
    // persistence tier as compactView above, not reset per stream the way
    // nowPlayingGenre is.
    property bool deepBassEnabled: false
  }

  property bool paused: false
  property string nowPlayingTitle: ""
  // Arrives on the exact same already-registered "metadata" observe_property
  // as nowPlayingTitle (icy-genre, not a separate IPC call) — not every
  // station sends it, so this tolerates being empty the same way
  // nowPlayingTitle already does.
  property string nowPlayingGenre: ""
  property bool buffering: false
  property int bufferingPercent: 0
  property bool pendingSurprise: false

  // True only for the single stationsProc invocation shuffleStations()
  // just triggered. Set exclusively by loadStations() itself (every call
  // sets it, not just a true one) so a fetch killed-for-restart by some
  // other action can never leave this stuck true for the fetch that
  // replaces it. Deliberately not a persistent mode alongside
  // state.sortOrder's Trending/Recently-added toggle: Shuffle reorders the
  // current result once, it doesn't become a standing "always random"
  // ordering.
  property bool shuffleActive: false
  // Confirmed live (docs/v5-feature-research.md): Radio Browser appears to
  // cache identical repeated query strings server-side, so repeating the
  // exact same order=random request returns the exact same order. This is
  // a throwaway, monotonically-increasing param whose only job is to make
  // every Shuffle click's request string different from the last.
  property int shuffleSeed: 0

  // Sleep timer selection: "off" | "15" | "30" | "60". Transient — a shell
  // config reload (rare mid-timer) resetting a pending sleep timer is an
  // acceptable edge case, the same tier as pendingSurprise/loadingGeo.
  property string sleepTimerOption: "off"

  // True for the one mpvProc.exited that fires because playStation() killed
  // the previous station to switch to a new one. Killing an external process
  // is asynchronous, so that exit signal can land after the new station has
  // already started — without this guard, onExited's "really stopped" reset
  // would clobber state.playing (disabling Stop/Pause) and cancel the new
  // station's socket reconnect, even though it's actively playing.
  property bool switchingStation: false

  // Same guard shape as switchingStation above, for stationsProc: set
  // when a running fetch is killed for a restart or an intentional clear,
  // consumed by onExited so a killed fetch's belated result can't clobber
  // state a newer fetch (or the clear) already set.
  property bool stationsSwitching: false

  // "👍 vote" state. Transient (not in `state`) — vote feedback is
  // inherently momentary, not something worth surviving a shell restart.
  // Unlike stationsProc/geoLocationProc, a new vote never kills an
  // in-flight one (voteForStation() below just ignores the click) —
  // votes are cheap, infrequent, and keyed per-station-uuid, so there's
  // no "supersede the old one" case to reconcile, and no possibility of
  // a killed request's stale response racing a fresh one for the same
  // reused Process.
  // Both the uuid voteProc's command is currently built from and the uuid
  // whose row should show the in-flight state — always the same value
  // (voteForStation() is single-flight, never superseded mid-request),
  // so one property covers both rather than two kept manually in sync.
  property string voteInFlightUuid: ""
  // voteUuid/voteOk are a single shared slot, not a per-station map:
  // voting on a second station while the first's feedback is still
  // showing will replace it early once the second vote completes,
  // rather than each row tracking its own independent feedback window.
  // Accepted deliberately — a per-uuid feedback map would be real
  // complexity for a cosmetic-only edge case (two votes within the same
  // few seconds), disproportionate to how small this feature is meant
  // to be; the failure mode is a checkmark clearing a little early, never
  // wrong or stuck data.
  property string voteUuid: ""
  property bool voteOk: false

  property bool loadingCountries: false
  property string countriesError: ""
  property var allCountries: []
  property string countryQuery: ""
  property var countryMatches: []

  property bool loadingLanguages: false
  property string languagesError: ""
  property var allLanguages: []
  property string languageQuery: ""
  property var languageMatches: []

  // "Near me" geo filter. Deliberately transient (not in `state`), unlike
  // a country or language choice: an IP-derived location can go stale
  // (the machine moves, a VPN changes), so it's looked up fresh each time
  // it's requested rather than carried over from a previous session.
  readonly property int geoDistanceMeters: 50000
  property bool geoActive: false
  property real geoLat: 0
  property real geoLong: 0
  property string geoLabel: ""
  property bool loadingGeo: false
  property string geoError: ""
  // Same guard shape as stationsSwitching above, for geoLocationProc,
  // after a deliberate kill-for-restart (a refresh, a clear, or Surprise).
  property bool geoLookupCancelled: false

  // Free-text station-name filter. Transient (not in `state`): cleared on a
  // shell restart, like countryQuery. Passed straight through to the Radio
  // Browser search as its `name` parameter, AND-ed with country/mood/decade.
  property string nameQuery: ""

  property bool loadingStations: false
  property string stationsError: ""

  property string ipcSocketPath: ""

  // Starred stations, keyed by stationuuid: { uuid, name, playUrl, codec,
  // bitrate, tags }. PersistentProperties (see `state` above) only survives
  // in-process QML reloads, not a real shell restart — confirmed by the
  // absence of any on-disk state for it and by the first-party notifications
  // service's own comment to that effect. Favorites need to actually survive
  // a restart to be worth starring, so they get their own on-disk file
  // instead, following that same service's FileView + debounced-save pattern.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/"
  readonly property string favoritesPath: stateDir + "world-radio-favorites.json"
  property var favorites: ({})
  property bool favoritesLoaded: false
  // Set the first time refreshFavorites() runs (on panel open), so it
  // fires at most once per session — not on every subsequent open/close
  // of the same panel instance. Only latched once an actual fetch is
  // sent (see refreshFavorites()) — an empty or oversized favorites list
  // leaves this false so a later open can still try again.
  property bool favoritesRefreshed: false
  property bool favoritesRefreshRetried: false
  // Captured once, when the request is built, rather than re-read live
  // from root.favorites at completion time — root.favorites can change
  // while the up-to-8s request is in flight (the listener starring or
  // unstarring something), and the merge in favoritesRefreshProc's
  // completion handler needs to know exactly which uuids this specific
  // response is actually about.
  property var favoritesRefreshQueriedUuids: []
  // A comfortably safe margin under maxFavorites (500) for a single
  // batch request's URL length — not verified against a real oversized
  // request (this machine's own favorites list never got that large), so
  // this is a conservative guard against an unverified risk rather than
  // a measured limit. Above it, refreshing is skipped for that session
  // rather than guessing at chunking behavior with no primary source to
  // confirm it's needed or how the API would behave.
  readonly property int maxFavoritesRefreshBatch: 200

  // Bounds enforced on the favorites file itself (see favoritesReadProc)
  // and on every entry loaded from or written to it. The path is fixed and
  // predictable, so nothing should ever hand its raw content to JSON.parse
  // or the model without these checked first: a hostile or corrupted
  // replacement (a FIFO swapped in at that path, or just an oversized file)
  // must not be able to block or balloon the shell's memory.
  readonly property int maxFavoritesFileBytes: 1048576
  readonly property int maxFavorites: 500

  // History: the most recently played stations, most-recent-first — see
  // docs/adr/0001-history-separate-file.md for why this isn't just a
  // second key in the favorites file above. Same on-disk safety tier as
  // Favorites (hardenedFileReadScript below is shared by both), but its
  // own file, own bounds, own lifecycle (fully automatic, always trimmed —
  // never user-curated the way Favorites is).
  readonly property string historyPath: stateDir + "world-radio-history.json"
  property var history: []
  property bool historyLoaded: false
  readonly property int maxHistoryFileBytes: 1048576
  readonly property int maxHistory: 15
  // Reuse History's bounded, atomic on-disk persistence; no second country file.
  readonly property var recentCountries: root.recentCountriesFromHistory(root.history)

  function recentCountriesFromHistory(rows) {
    var countries = []
    for (var i = 0; i < rows.length && countries.length < 6; i++) {
      var code = rows[i].countryCode
      if (!code || countries.some(function(c) { return c.code === code })) continue
      countries.push({ code: code, name: rows[i].countryName || code })
    }
    return countries
  }
  // History's own row height cap — independent of maxHistory (how many
  // entries are kept) so the section can never push the filter pickers
  // below it further down the column as it fills toward that cap; past
  // this many rows it scrolls internally instead of growing.
  readonly property int historyVisibleRows: 5

  ListModel { id: stationsModel }

  Process { id: ensureStateDirProc; command: ["mkdir", "-p", root.stateDir]; running: false }

  // Earlier versions of this read went through progressively narrower gaps:
  // a separate stat-by-path then FileView.reload() (two path lookups, so
  // the path could be repointed between them); then a single bash fd
  // (exec 3<> "$path") checked via /proc/self/fd/3 — which closed that
  // race but still transparently followed a symlink at favoritesPath,
  // since plain open()/bash redirection has no way to refuse one.
  //
  // Bash's redirection operators can't express O_NOFOLLOW, so this uses
  // Python's os.open() to get the real flags: O_NOFOLLOW makes the open
  // itself fail if favoritesPath's final component is a symlink (rather
  // than silently reading whatever it points to), and O_NONBLOCK makes
  // opening a FIFO return immediately instead of blocking for a reader.
  // Every check after that — regular-file, size — runs via fstat() on the
  // already-open fd, and the read is capped at maxFavoritesFileBytes, so
  // nothing about the path is ever consulted a second time and nothing
  // past the cap is ever read off disk.
  //
  // Verified locally against all five cases before shipping: missing path,
  // a valid file, an oversized file, a FIFO with no writer, and a symlink
  // to an otherwise-legitimate regular file elsewhere — only the valid
  // file's content comes back; everything else exits non-zero with no
  // stdout, which loadFavorites("")/loadHistory("") already treat as
  // "nothing saved yet". Parameterized by path/max_bytes (argv), so
  // historyReadProc below reuses this exact script for a second file
  // rather than duplicating the hardening.
  readonly property string hardenedFileReadScript: `
import os, sys, stat as statmod
path, max_bytes = sys.argv[1], int(sys.argv[2])
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    sys.exit(1)
try:
    st = os.fstat(fd)
    if not statmod.S_ISREG(st.st_mode) or st.st_size > max_bytes:
        sys.exit(1)
    chunks, remaining = [], max_bytes
    while remaining > 0:
        chunk = os.read(fd, min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    sys.stdout.buffer.write(b"".join(chunks))
except OSError:
    sys.exit(1)
finally:
    os.close(fd)
  `

  Process {
    id: favoritesReadProc
    command: ["python3", "-c", root.hardenedFileReadScript, root.favoritesPath, String(root.maxFavoritesFileBytes)]
    stdout: StdioCollector {
      // Empty on any failure branch above (missing path, symlink, non-
      // regular, oversized) — loadFavorites("") already treats that as
      // "no favorites yet", so no separate exit-code handling is needed.
      onStreamFinished: root.loadFavorites(String(text || ""))
    }
  }

  Process {
    id: historyReadProc
    command: ["python3", "-c", root.hardenedFileReadScript, root.historyPath, String(root.maxHistoryFileBytes)]
    stdout: StdioCollector {
      onStreamFinished: root.loadHistory(String(text || ""))
    }
  }

  // Write-only: setText()/atomicWrites for persisting favorites back out.
  // Reading goes through favoritesReadProc instead, never through this.
  FileView {
    id: favoritesFile
    path: root.favoritesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // Same write-only shape as favoritesFile above, for History's own file.
  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  Timer {
    id: favoritesSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushFavorites()
  }

  // Triggered by refreshFavorites(), which captures the uuid list into
  // favoritesRefreshQueriedUuids once, at request time — this reads that
  // captured snapshot, not a live Object.keys(root.favorites), since
  // root.favorites can change (a star/unstar) while this up-to-8s
  // request is still in flight.
  Process {
    id: favoritesRefreshProc
    command: ["curl", "-sS", "-L", "--max-time", "8", "-A", root.userAgent,
      root.currentApiHost + "/json/stations/byuuid?uuids=" + root.favoritesRefreshQueriedUuids.map(encodeURIComponent).join(",")]
    stdout: StdioCollector {
      onStreamFinished: {
        var responseByUuid = {}
        var parseOk = false
        try {
          var data = JSON.parse(String(text || ""))
          if (Array.isArray(data)) {
            parseOk = true
            for (var i = 0; i < data.length; i++) {
              var s = data[i]
              var uuid = String((s && s.stationuuid) || "")
              if (!uuid) continue
              var safe = root.sanitizeStationRow({
                uuid: uuid,
                name: String((s && s.name) || ""),
                playUrl: String((s && (s.url_resolved || s.url)) || ""),
                codec: String((s && s.codec) || ""),
                bitrate: Number((s && s.bitrate) || 0),
                tags: String((s && s.tags) || ""),
                countryCode: String((s && s.countrycode) || ""),
                countryName: String((s && s.country) || "")
              })
              if (!root.isValidStationRow(safe)) continue
              responseByUuid[uuid] = safe
            }
          }
        } catch (e) { }
        // One retry against the next resolved server, matching every
        // other Radio Browser fetch in this file — a single transient
        // failure shouldn't permanently forfeit the session's one-shot
        // refresh. No error is surfaced either way: this feature has no
        // user-visible loading/error state, so a still-failed retry just
        // leaves favorites untouched, silently.
        if (!parseOk && !root.favoritesRefreshRetried) {
          root.favoritesRefreshRetried = true
          root.apiServerIndex = (root.apiServerIndex + 1) % root.apiServers.length
          Qt.callLater(function() { favoritesRefreshProc.running = true })
          return
        }
        if (!parseOk) return
        // Merged into the CURRENT root.favorites, not a wholesale
        // replacement built only from what was queried — a favorite
        // starred while this request was in flight is not in
        // favoritesRefreshQueriedUuids at all, so it's untouched by the
        // loop below. Within what WAS queried: update only a uuid that's
        // still a current favorite (the listener may have unstarred it
        // mid-request; the response must never resurrect that), and drop
        // only a still-current favorite the response omitted — treated as
        // removed from the directory, silently, per this ticket's scope
        // (Favorites has no dedicated list to flag it in).
        var next = {}
        for (var k in root.favorites) next[k] = root.favorites[k]
        for (var j = 0; j < root.favoritesRefreshQueriedUuids.length; j++) {
          var qUuid = root.favoritesRefreshQueriedUuids[j]
          if (!next[qUuid]) continue
          if (responseByUuid[qUuid]) next[qUuid] = responseByUuid[qUuid]
          else delete next[qUuid]
        }
        root.favorites = next
        root.scheduleFavoritesSave()
        root.resortStations()
      }
    }
  }

  Timer {
    id: historySaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushHistory()
  }

  // Clears a completed vote's row-level feedback (voteUuid) a few seconds
  // after it's shown, so a success/failure icon doesn't linger forever.
  Timer {
    id: voteFeedbackTimer
    interval: 3000
    repeat: false
    onTriggered: root.voteUuid = ""
  }

  // Debounces the name-search field so a request fires ~350ms after the last
  // keystroke rather than on every character. reloadOrClear() handles the
  // "nothing left to search by at all" case by clearing the list instead
  // of pulling the global top stations.
  Timer {
    id: nameSearchTimer
    interval: 350
    repeat: false
    onTriggered: root.reloadOrClear()
  }

  // Shared uuid/name/playUrl/codec/bitrate/tags bounds — applied whether
  // the row just came from the API (toggleFavorite/recordHistory) or from
  // disk (loadFavorites/loadHistory), so a future change to a bound (a new
  // field, a different length cap) has one place to make it instead of
  // four. Callers needing an authoritative uuid other than row.uuid (see
  // loadFavorites, which trusts the favorites file's own map key over
  // whatever a hand-edited entry's embedded uuid might claim) pass it via
  // uuidOverride rather than relying on row.uuid.
  function sanitizeStationRow(row, uuidOverride) {
    return {
      uuid: String(uuidOverride !== undefined ? uuidOverride : (row.uuid || "")).slice(0, 64),
      name: String(row.name || "").slice(0, 200),
      playUrl: String(row.playUrl || "").slice(0, 2000),
      codec: String(row.codec || "").slice(0, 32),
      bitrate: Math.max(0, Math.min(9999999, Number(row.bitrate) || 0)),
      tags: String(row.tags || "").slice(0, 500),
      countryCode: /^[A-Za-z]{2}$/.test(String(row.countryCode || "")) ? String(row.countryCode).toUpperCase() : "",
      countryName: String(row.countryName || "").slice(0, 200)
    }
  }

  // Shared by loadFavorites/loadHistory/favoritesRefreshProc — a hand-
  // edited or corrupted file, or a malformed API response, shouldn't be
  // able to hand mpv a non-http(s) URL or an empty identity.
  function isValidStationRow(safe) {
    return !!(safe.uuid && safe.name && /^https?:\/\//i.test(safe.playUrl))
  }

  function loadFavorites(raw) {
    if (root.favoritesLoaded) return
    var parsed = {}
    var count = 0
    try {
      var data = JSON.parse(raw || "")
      if (data && typeof data === "object" && data.favorites && typeof data.favorites === "object") {
        for (var uuid in data.favorites) {
          if (count >= root.maxFavorites) break
          var f = data.favorites[uuid]
          if (!f || typeof f !== "object") continue
          // Re-validated on load, not just on write — a hand-edited or
          // corrupted file shouldn't be able to hand mpv a non-http(s) URL.
          var safe = root.sanitizeStationRow(f, uuid)
          if (!root.isValidStationRow(safe)) continue
          parsed[safe.uuid] = safe
          count++
        }
      }
    } catch (e) { }
    root.favorites = parsed
    root.favoritesLoaded = true
  }

  function flushFavorites() {
    favoritesFile.setText(JSON.stringify({ version: 1, favorites: root.favorites }, null, 2) + "\n")
  }

  function scheduleFavoritesSave() {
    if (!root.favoritesLoaded) return
    favoritesSaveTimer.restart()
  }

  // Once per session, on panel open: re-fetch every favorited station in
  // one batch request and let favoritesRefreshProc's own completion
  // handler update codec/bitrate/tags (the only fields Favorites actually
  // stores — see sanitizeStationRow) or drop a favorite the directory no
  // longer has. favoritesRefreshed is only set once the fetch actually
  // fires, so if this races the initial disk read (favoritesReadProc)
  // finishing, the next panel open just tries again rather than
  // permanently skipping the session's one refresh.
  function refreshFavorites() {
    if (root.favoritesRefreshed || !root.favoritesLoaded) return
    var uuids = Object.keys(root.favorites)
    // Neither branch below latches favoritesRefreshed — there's nothing
    // to refresh yet (or safely batch) this time, but that can change
    // before the panel is next opened, so leave the one-shot available.
    if (uuids.length === 0 || uuids.length > root.maxFavoritesRefreshBatch) return
    root.favoritesRefreshed = true
    root.favoritesRefreshRetried = false
    root.favoritesRefreshQueriedUuids = uuids
    favoritesRefreshProc.running = false
    Qt.callLater(function() { favoritesRefreshProc.running = true })
  }

  // History is an ordered array (most-recent-first), unlike favorites'
  // uuid-keyed map — order is the whole point here, where favorites has
  // none. Re-validated on load for the same reason as loadFavorites above:
  // a hand-edited or corrupted file shouldn't be able to hand mpv a
  // non-http(s) URL.
  function loadHistory(raw) {
    if (root.historyLoaded) return
    var parsed = []
    try {
      var data = JSON.parse(raw || "")
      if (data && typeof data === "object" && Array.isArray(data.history)) {
        for (var i = 0; i < data.history.length && parsed.length < root.maxHistory; i++) {
          var h = data.history[i]
          if (!h || typeof h !== "object") continue
          var safe = root.sanitizeStationRow(h)
          if (!root.isValidStationRow(safe)) continue
          parsed.push(safe)
        }
      }
    } catch (e) { }
    root.history = parsed
    root.historyLoaded = true
  }

  function flushHistory() {
    historyFile.setText(JSON.stringify({ version: 1, history: root.history }, null, 2) + "\n")
  }

  function scheduleHistorySave() {
    if (!root.historyLoaded) return
    historySaveTimer.restart()
  }

  // Records a play in History: bumps an already-present station back to
  // the top instead of duplicating it (a listener replaying their one
  // favorite station shouldn't push everything else out), then trims to
  // maxHistory. Called once mpv reports a positive playback position.
  //
  // Guarded on historyLoaded, same as scheduleHistorySave() below — not
  // just to skip an unnecessary disk write, but because loadHistory()
  // unconditionally overwrites root.history the first time it runs
  // (guarded only by that same flag). Recording a play before the initial
  // disk read completes would otherwise be silently wiped out the moment
  // that read finishes and calls loadHistory().
  function recordHistory(row) {
    if (!root.historyLoaded || !row || !row.uuid) return
    var next = [root.sanitizeStationRow(row)]
    for (var i = 0; i < root.history.length; i++) {
      if (root.history[i].uuid !== row.uuid) next.push(root.history[i])
    }
    if (next.length > root.maxHistory) next.length = root.maxHistory
    root.history = next
    root.scheduleHistorySave()
  }

  function isFavorite(uuid) {
    return Object.prototype.hasOwnProperty.call(root.favorites, uuid)
  }

  function toggleFavorite(row) {
    if (!row || !row.uuid) return
    var next = {}
    for (var k in root.favorites) next[k] = root.favorites[k]
    if (next[row.uuid]) {
      delete next[row.uuid]
    } else if (Object.keys(next).length < root.maxFavorites) {
      next[row.uuid] = root.sanitizeStationRow(row)
    }
    root.favorites = next
    root.scheduleFavoritesSave()
    root.resortStations()
  }

  // Ignores the click (rather than killing and restarting, as
  // loadStations()/findNearMe() do) whenever any vote is already in
  // flight — votes are cheap and infrequent enough that making the user
  // wait for the previous one to resolve is simpler and fully correct,
  // with no killed-process-vs-fresh-request ambiguity to reconcile.
  function voteForStation(uuid) {
    // Same shape check already applied before clickProc's click-tracking
    // request in playStation() — the station data driving this call comes
    // from the same untrusted API response, so it gets the same guard.
    if (!uuid || !root.stationUuidPattern.test(uuid) || voteProc.running) return
    root.voteInFlightUuid = uuid
    // Only clears voteUuid/stops the timer when re-voting the *same* row
    // that's currently showing feedback — otherwise this would revert to
    // the idle icon mid-request, misleadingly looking like nothing is
    // happening. A *different* row's still-displaying feedback is left
    // alone; voteProc's own completion handler owns setting/timing that.
    if (root.voteUuid === uuid) {
      voteFeedbackTimer.stop()
      root.voteUuid = ""
    }
    voteProc.running = true
  }

  // Stable-partitions the currently loaded list so favorited stations sit
  // above everything else, without disturbing relative order otherwise.
  // Called after a fresh search and whenever a favorite is toggled, so a
  // star applied to a station already on screen jumps it to the top live.
  function resortStations() {
    var rows = []
    for (var i = 0; i < stationsModel.count; i++) {
      var r = stationsModel.get(i)
      rows.push({ uuid: r.uuid, name: r.name, playUrl: r.playUrl, codec: r.codec, bitrate: r.bitrate, tags: r.tags, favicon: r.favicon, homepage: r.homepage, votes: r.votes, countryCode: r.countryCode, countryName: r.countryName })
    }
    rows.sort(function(a, b) {
      var af = root.isFavorite(a.uuid) ? 0 : 1
      var bf = root.isFavorite(b.uuid) ? 0 : 1
      return af - bf
    })
    stationsModel.clear()
    for (var j = 0; j < rows.length; j++) stationsModel.append(rows[j])
  }

  Component.onCompleted: {
    var runtimeDir = Quickshell.env("XDG_RUNTIME_DIR")
    ipcSocketPath = (runtimeDir && runtimeDir.length > 0 ? runtimeDir : "/tmp") + "/omarchy-worldradio-" + Math.floor(Math.random() * 1e9) + ".sock"

    // One-time migration: Recently added's button is gone, but a listener
    // who had it active still has "changetimestamp" persisted in state
    // from before — with no button left to turn it off, they'd otherwise
    // be stuck sorting by recency indefinitely with no visible indicator
    // of why.
    if (state.sortOrder === "changetimestamp") state.sortOrder = ""

    ensureStateDirProc.running = true
    Qt.callLater(function() { favoritesReadProc.running = true })
    Qt.callLater(function() { historyReadProc.running = true })
    Qt.callLater(function() { serverListProc.running = true })
  }

  onOpenedChanged: {
    if (root.opened && root.hasLoadedStations() && stationsModel.count === 0 && !stationsProc.running) {
      root.loadStations()
    }
    if (root.opened) root.refreshFavorites()
  }

  function flagFor(code) {
    if (!code || !/^[A-Za-z]{2}$/.test(code)) return "🌐"
    var cc = code.toUpperCase()
    return String.fromCodePoint(cc.charCodeAt(0) - 65 + 0x1F1E6, cc.charCodeAt(1) - 65 + 0x1F1E6)
  }

  // Abbreviated so a popular station's vote count doesn't dominate the
  // already-tight, already-eliding codec/bitrate/tags caption line.
  function formatVoteCount(n) {
    if (n >= 1000) return (n / 1000).toFixed(1) + "k"
    return String(n)
  }

  function selectCountry(code, name) {
    state.countryCode = code
    state.countryName = name
    root.countryQuery = ""
    root.countryMatches = []
    // A stale "Near me" filter would otherwise AND a brand-new country
    // pick with an unrelated location, almost always yielding zero
    // results with no visible explanation why.
    root.resetGeoFilter()
    root.loadStations()
  }

  // A country pick isn't the only thing that already produces (or should
  // produce) a station list — a worldwide name search or a language-only
  // pick does too. Toggling a filter in any of those states needs to
  // reload, or the UI shows the new filter as active while the visible
  // list silently keeps ignoring it.
  function hasLoadedStations() {
    return state.countryCode !== "" || root.nameQuery.trim() !== "" || state.languageCode !== "" || root.geoActive
  }

  // Killing an already-running stationsProc is asynchronous — its exit
  // can land after the caller has already moved on. Shared by
  // loadStations() and reloadOrClear()'s empty-clear branch.
  function killStationsProc() {
    if (stationsProc.running) root.stationsSwitching = true
    stationsProc.running = false
  }

  // Shared by nameSearchTimer and every "clear a filter" function: reload
  // if any filter is still active, or clear the list directly if not —
  // never fall through to loadStations() with nothing set, which would
  // otherwise pull the unfiltered global top-80.
  function reloadOrClear() {
    if (root.hasLoadedStations()) {
      root.loadStations()
    } else {
      root.killStationsProc()
      stationsModel.clear()
      root.stationsError = ""
      root.loadingStations = false
    }
  }

  function toggleTag(tagName) {
    state.tag = state.tag === tagName ? "" : tagName
    if (root.hasLoadedStations()) root.loadStations()
  }

  function toggleDecade(decadeName) {
    state.decade = state.decade === decadeName ? "" : decadeName
    if (root.hasLoadedStations()) root.loadStations()
  }

  // Mutually exclusive with itself only (not with tag/decade, which stay
  // independent filters): re-picking the active order clears back to the
  // default clickcount ordering — same "one active value" toggle shape as
  // toggleTag/toggleDecade, applied to a single field. Generic (any order
  // string), though "votes" (Trending) is the only one a button reaches
  // today — Recently added ("changetimestamp") was removed.
  function toggleSortOrder(order) {
    state.sortOrder = state.sortOrder === order ? "" : order
    if (root.hasLoadedStations()) root.loadStations()
  }

  // Pure layout/sizing switch — never touches playback, filters, or the
  // loaded station list, so nothing here needs a reload.
  function toggleCompactView() {
    state.compactView = !state.compactView
  }

  function selectLanguage(code, name) {
    state.languageCode = code
    state.languageName = name
    root.languageQuery = ""
    root.languageMatches = []
    if (root.hasLoadedStations()) root.loadStations()
  }

  function clearLanguage() {
    state.languageCode = ""
    state.languageName = ""
    root.reloadOrClear()
  }

  // Killing an already-running geoLocationProc is asynchronous — its
  // completion can land after the caller has already moved on. Shared by
  // findNearMe() and resetGeoFilter() so the kill sequence only needs to
  // be right in one place.
  function killGeoLookup() {
    if (geoLocationProc.running) root.geoLookupCancelled = true
    geoLocationProc.running = false
  }

  // Fetches (or refreshes, if already active) the listener's approximate
  // location via IP geolocation, then applies it as a search filter once
  // resolved — findNearMe()'s own onStreamFinished handler does the actual
  // state update and reload, since the lookup is asynchronous.
  function findNearMe() {
    root.geoError = ""
    root.loadingGeo = true
    root.killGeoLookup()
    Qt.callLater(function() { geoLocationProc.running = true })
  }

  // Stops a lookup that might still be in flight — otherwise it could
  // complete afterward and silently reinstate a filter that was just
  // dropped, or re-filter an unrelated pick by a stale location. Shared by
  // clearGeo() and surpriseMe() so a future fix (like the missing
  // geoError reset this helper replaced) only needs to happen once.
  function resetGeoFilter() {
    root.killGeoLookup()
    root.loadingGeo = false
    root.geoError = ""
    root.geoActive = false
    root.geoLat = 0
    root.geoLong = 0
    root.geoLabel = ""
  }

  function clearGeo() {
    root.resetGeoFilter()
    root.reloadOrClear()
  }

  function surpriseMe() {
    // Drop any name/language filter first, or the random country would be
    // searched through a stale term and almost always come back empty.
    // (selectCountry(), called below, resets the geo filter on its own.)
    nameField.text = ""
    root.nameQuery = ""
    state.languageCode = ""
    state.languageName = ""
    var pick = root.curatedCountries[Math.floor(Math.random() * root.curatedCountries.length)]
    root.pendingSurprise = true
    root.selectCountry(pick.code, pick.name)
  }

  // shuffle defaults to false for every ordinary caller (a tag toggle, a
  // country pick, Near me, ...) and is set unconditionally on every call
  // (not just when true) so this is the single place shuffleActive can
  // change — otherwise a fetch that gets killed-for-restart by some other
  // action (see killStationsProc()) before it finishes would leave
  // shuffleActive stuck true, corrupting whatever fetch replaces it.
  function loadStations(shuffle) {
    root.stationsError = ""
    root.stationsRetried = false
    root.loadingStations = true
    root.shuffleActive = !!shuffle
    stationsModel.clear()
    root.killStationsProc()
    Qt.callLater(function() { stationsProc.running = true })
  }

  // One-shot reorder of the current filtered list via order=random,
  // distinct from Surprise (which ignores filters entirely) and from
  // state.sortOrder's Trending/Recently-added toggle (a standing mode,
  // not a one-time action). Reuses loadStations()'s existing kill+refetch
  // flow; stationsProc's own command builder reads shuffleActive/
  // shuffleSeed to swap in order=random plus a cache-busting param for
  // this one fetch only.
  function shuffleStations() {
    if (stationsModel.count === 0) return
    root.shuffleSeed += 1
    root.loadStations(true)
  }

  // "off" cancels outright; "15"/"30"/"60" (re)starts a fresh countdown,
  // replacing whatever was pending before.
  function setSleepTimer(option) {
    root.sleepTimerOption = option
    sleepTimer.stop()
    if (option !== "off") {
      sleepTimer.interval = Number(option) * 60000
      sleepTimer.start()
    }
  }

  function cancelSleepTimer() {
    if (root.sleepTimerOption === "off") return
    root.sleepTimerOption = "off"
    sleepTimer.stop()
  }

  // Shared by the country and language pickers: case-insensitive substring
  // match against a fetch-once-cached { code, name } list, capped so a
  // broad query (e.g. a single letter) doesn't dump the whole list.
  function matchesFor(items, query) {
    var q = query.trim().toLowerCase()
    if (q.length === 0) return []
    var out = []
    for (var i = 0; i < items.length && out.length < 8; i++) {
      if (items[i].name.toLowerCase().indexOf(q) !== -1) out.push(items[i])
    }
    return out
  }

  function updateCountryMatches() {
    root.countryMatches = root.matchesFor(root.allCountries, root.countryQuery)
  }

  function ensureCountriesLoaded() {
    if (root.allCountries.length > 0 || countriesProc.running) return
    root.countriesError = ""
    root.countriesRetried = false
    root.loadingCountries = true
    countriesProc.running = true
  }

  function updateLanguageMatches() {
    root.languageMatches = root.matchesFor(root.allLanguages, root.languageQuery)
  }

  function ensureLanguagesLoaded() {
    if (root.allLanguages.length > 0 || languagesProc.running) return
    root.languagesError = ""
    root.languagesRetried = false
    root.loadingLanguages = true
    languagesProc.running = true
  }

  // Shared by the bar icon's tooltip and the panel's now-playing caption
  // Text — combining title/genre in one place instead of two keeps both
  // "now playing" surfaces in sync instead of one silently falling behind
  // the other when a new metadata field is added later.
  function nowPlayingCaption() {
    return [root.nowPlayingTitle, root.nowPlayingGenre].filter(function(s) { return s }).join(" · ")
  }

  // Shared by playStation(), stopPlayback(), and mpvProc.onExited's
  // "really stopped" cleanup: every piece of mpv-observed playback display
  // state, reset together so a future observed property can't be added to
  // one reset site and forgotten in another.
  function resetPlaybackDisplay() {
    root.paused = false
    root.nowPlayingTitle = ""
    root.nowPlayingGenre = ""
    root.buffering = false
    root.bufferingPercent = 0
  }

  // Takes the full row (uuid/name/playUrl/codec/bitrate/tags), not just the
  // three fields playback itself needs — every call site already has the
  // full row on hand, and recordHistory() below needs codec/bitrate/tags
  // too, so widening this beats re-deriving them from a bare uuid/name/url.
  function playStation(row) {
    if (!row || !/^https?:\/\//i.test(row.playUrl)) return
    state.stationUuid = row.uuid
    state.stationName = row.name
    state.stationUrl = row.playUrl
    state.playing = true
    root.resetPlaybackDisplay()
    root.cancelSleepTimer()
    // Copy the model row now: later browsing can clear/reorder its ListModel.
    root.pendingHistoryRow = root.sanitizeStationRow(row)

    if (mpvProc.running) root.switchingStation = true
    ipcSocket.connected = false
    mpvProc.running = false
    Qt.callLater(function() {
      mpvProc.running = true
      ipcRetryTimer.attempts = 0
      ipcRetryTimer.restart()
    })

    if (root.stationUuidPattern.test(row.uuid)) {
      clickProc.running = false
      Qt.callLater(function() { clickProc.running = true })
    }
  }

  // Steps to the previous/next station in the currently loaded list, like
  // turning a tuning dial. Starts from the top of the list if nothing (or
  // something no longer in the list) is playing.
  function playRelativeStation(delta) {
    if (stationsModel.count === 0) return
    var idx = -1
    for (var i = 0; i < stationsModel.count; i++) {
      if (stationsModel.get(i).uuid === state.stationUuid) { idx = i; break }
    }
    var nextIdx = idx === -1 ? 0 : (idx + delta + stationsModel.count) % stationsModel.count
    root.playStation(stationsModel.get(nextIdx))
    root.notifyStationChange()
  }

  function togglePause() {
    if (!state.playing || !ipcSocket.connected) return
    root.paused = !root.paused
    ipcSocket.write(JSON.stringify({ command: ["set_property", "pause", root.paused] }) + "\n")
    ipcSocket.flush()
  }

  // Unlike togglePause() above, this always flips the persisted preference
  // even with nothing playing — a listener can set it before ever hitting
  // play. Applied immediately on a live connection too, so toggling mid-
  // stream is heard right away rather than only on the next station.
  // ipcSocket.onConnectionStateChanged re-applies it on every future
  // connection, the same way loudnorm already is, so the preference
  // survives a station change without needing to be reapplied here again.
  function toggleDeepBass() {
    state.deepBassEnabled = !state.deepBassEnabled
    if (ipcSocket.connected) {
      ipcSocket.write(JSON.stringify({ command: ["af", state.deepBassEnabled ? "add" : "remove", root.deepBassFilter] }) + "\n")
      ipcSocket.flush()
    }
  }

  function stopPlayback() {
    root.pendingHistoryRow = null
    if (ipcSocket.connected) {
      ipcSocket.write(JSON.stringify({ command: ["quit"] }) + "\n")
      ipcSocket.flush()
    }
    ipcRetryTimer.stop()
    mpvProc.running = false
    ipcSocket.connected = false
    state.playing = false
    root.resetPlaybackDisplay()
    root.cancelSleepTimer()
  }

  function handleMpvMessage(line) {
    // Guards against a message already in flight when the socket was torn
    // down to switch stations (playStation()/stopPlayback() both flip
    // ipcSocket.connected synchronously before this could fire again) from
    // clobbering the state the panel already reset for the new station.
    if (!ipcSocket.connected) return
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (!msg || msg.event !== "property-change") return
    // Unlike a click or file-loaded, a positive time-pos confirms playback
    // progressed. observe_property also seeds it when IPC connects late.
    if (msg.id === root.timePosObserveId && typeof msg.data === "number" && msg.data > 0 && root.pendingHistoryRow && root.historyLoaded) {
      root.recordHistory(root.pendingHistoryRow)
      root.pendingHistoryRow = null
    }
    if (msg.id === root.metadataObserveId && msg.data && typeof msg.data === "object") {
      // mpv sends this immediately on observe_property registration (with
      // the current value) and again on every future change, so this alone
      // covers both the initial seed and instant live updates — confirmed
      // against mpv's own client.h: "You always get an initial change
      // notification."
      root.nowPlayingTitle = String(msg.data["icy-title"] || "")
      root.nowPlayingGenre = String(msg.data["icy-genre"] || "")
    } else if (msg.id === root.pauseObserveId && typeof msg.data === "boolean") {
      // Keeps the Pause/Resume label correct even when playback was toggled
      // from a hardware media key or another MPRIS controller, not this panel.
      root.paused = msg.data
    } else if (msg.id === root.pausedForCacheObserveId && typeof msg.data === "boolean") {
      root.buffering = msg.data
    } else if (msg.id === root.cacheBufferingStateObserveId && typeof msg.data === "number") {
      // Documented as 0-100, but clamped the same way other externally
      // sourced numbers in this file already are (e.g. bitrate), rather
      // than trusting it unconditionally.
      root.bufferingPercent = Math.max(0, Math.min(100, msg.data))
    }
  }

  // Fetched once at startup (Component.onCompleted). A failure here just
  // leaves apiServers at its single-host default — every call site already
  // tolerates that as a valid (if non-redundant) server list, so no error
  // needs surfacing for this fetch specifically.
  Process {
    id: serverListProc
    command: ["curl", "-sS", "-L", "--max-time", "8", "-A", root.userAgent, "https://all.api.radio-browser.info/json/servers"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = []
        try {
          var data = JSON.parse(String(text || ""))
          if (Array.isArray(data)) {
            for (var i = 0; i < data.length; i++) {
              var name = String((data[i] && data[i].name) || "")
              // Loose but real hostname shape check — this is untrusted
              // network input about to be spliced directly into a URL for
              // every future station/country/language fetch.
              if (/^[A-Za-z0-9.-]+$/.test(name) && name.indexOf("..") === -1 && parsed.indexOf(name) === -1) {
                parsed.push(name)
              }
            }
          }
        } catch (e) { }
        if (parsed.length > 0) root.apiServers = parsed
      }
    }
  }

  Process {
    id: countriesProc
    command: ["curl", "-sS", "-L", "--max-time", "8", "-A", root.userAgent, root.currentApiHost + "/json/countries"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = []
        var ok = false
        try {
          var data = JSON.parse(String(text || ""))
          if (Array.isArray(data)) {
            ok = true
            for (var i = 0; i < data.length; i++) {
              var code = String((data[i] && data[i].iso_3166_1) || "")
              var name = String((data[i] && data[i].name) || "")
              if (/^[A-Za-z]{2}$/.test(code) && name.length > 0) parsed.push({ code: code.toUpperCase(), name: name })
            }
          }
        } catch (e) { }
        // One retry against the next resolved server, matching Radio
        // Browser's own documented usage pattern — see apiServers above.
        if (!ok && !root.countriesRetried) {
          root.countriesRetried = true
          root.apiServerIndex = (root.apiServerIndex + 1) % root.apiServers.length
          Qt.callLater(function() { countriesProc.running = true })
          return
        }
        root.loadingCountries = false
        root.allCountries = parsed
        // Previously silent: a failed/empty fetch (network hiccup, the
        // hardcoded API mirror being briefly down) left the search box
        // showing nothing with zero indication anything went wrong. Now
        // it's surfaced so it reads as "couldn't load" instead of "your
        // country doesn't exist".
        root.countriesError = ok ? "" : "Couldn't load the country list. Check your connection."
        root.updateCountryMatches()
      }
    }
  }

  Process {
    id: languagesProc
    command: ["curl", "-sS", "-L", "--max-time", "8", "-A", root.userAgent,
      root.currentApiHost + "/json/languages?order=stationcount&reverse=true"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = []
        var ok = false
        try {
          var data = JSON.parse(String(text || ""))
          if (Array.isArray(data)) {
            ok = true
            for (var i = 0; i < data.length; i++) {
              var code = String((data[i] && data[i].iso_639) || "")
              var name = String((data[i] && data[i].name) || "")
              if (/^[A-Za-z]{2,3}$/.test(code) && name.length > 0) {
                parsed.push({ code: code.toLowerCase(), name: name.charAt(0).toUpperCase() + name.slice(1) })
              }
            }
          }
        } catch (e) { }
        if (!ok && !root.languagesRetried) {
          root.languagesRetried = true
          root.apiServerIndex = (root.apiServerIndex + 1) % root.apiServers.length
          Qt.callLater(function() { languagesProc.running = true })
          return
        }
        root.loadingLanguages = false
        root.allLanguages = parsed
        root.languagesError = ok ? "" : "Couldn't load the language list. Check your connection."
        root.updateLanguageMatches()
      }
    }
  }

  // IP-based geolocation for the "Near me" filter — the same host and
  // curl-based request shape Omarchy's own bundled weather plugin already
  // trusts and calls (its omarchy-weather-location helper), not a new
  // third-party dependency.
  Process {
    id: geoLocationProc
    command: ["curl", "-sS", "-L", "--max-time", "8", "-A", root.userAgent, "https://wttr.in/?format=j1"]
    stdout: StdioCollector {
      onStreamFinished: {
        // A killed-for-restart lookup's belated result — a fresher
        // refresh (or a clear/Surprise) already superseded it. onExited
        // is the final signal for this same kill, and resets the guard.
        if (root.geoLookupCancelled) return
        root.loadingGeo = false
        var lat = NaN
        var long = NaN
        var label = ""
        var ok = false
        try {
          var data = JSON.parse(String(text || ""))
          var area = data && Array.isArray(data.nearest_area) && data.nearest_area[0]
          if (area) {
            lat = parseFloat(area.latitude)
            long = parseFloat(area.longitude)
            var nameEntry = Array.isArray(area.areaName) && area.areaName[0]
            label = String((nameEntry && nameEntry.value) || "")
            // Radio Browser returns a raw SQL error (HTTP 500) for
            // out-of-range coordinates rather than an empty result set
            // (confirmed live), so a malformed value here must never be
            // forwarded into the station search. A missing place name
            // doesn't invalidate an otherwise-usable coordinate pair —
            // fall back to the coordinates themselves for display.
            ok = isFinite(lat) && lat >= -90 && lat <= 90 &&
                 isFinite(long) && long >= -180 && long <= 180
            if (ok && label.length === 0) label = lat.toFixed(2) + ", " + long.toFixed(2)
          }
        } catch (e) { }
        if (ok) {
          // A stale country selection would otherwise AND with the new
          // location almost certainly nonsensically (e.g. a Singapore
          // filter combined with a US location) — the same silent
          // zero-results failure mode selectCountry() already guards
          // against in the opposite direction.
          state.countryCode = ""
          state.countryName = ""
          root.geoActive = true
          root.geoLat = lat
          root.geoLong = long
          root.geoLabel = label
          root.geoError = ""
          root.loadStations()
        } else {
          // Leaves any previously active geo filter untouched — a failed
          // refresh shouldn't silently drop an already-working filter.
          root.geoError = "Couldn't determine your location. Check your connection."
        }
      }
    }
    onExited: function(code, status) {
      if (root.geoLookupCancelled) { root.geoLookupCancelled = false; return }
      // Backstop for when curl never produces a stdout close at all (e.g.
      // it fails to spawn) — onStreamFinished alone would otherwise leave
      // loadingGeo stuck true with no feedback.
      root.loadingGeo = false
      if (code !== 0) root.geoError = "Couldn't determine your location. Check your connection."
    }
  }

  Process {
    id: stationsProc
    command: {
      var params = []
      if (state.countryCode) params.push("countrycode=" + encodeURIComponent(state.countryCode))
      // Confirmed live: `languagecodes=` does not filter results at all
      // (Radio Browser silently ignores it here); `language=` does a
      // case-sensitive substring match against the station's lowercase
      // `language` field, so the display name is lowercased before sending.
      if (state.languageCode) params.push("language=" + encodeURIComponent(state.languageName.toLowerCase()))
      if (root.geoActive) {
        params.push("geo_lat=" + encodeURIComponent(root.geoLat))
        params.push("geo_long=" + encodeURIComponent(root.geoLong))
        params.push("geo_distance=" + root.geoDistanceMeters)
      }
      if (root.nameQuery.trim() !== "") params.push("name=" + encodeURIComponent(root.nameQuery.trim()))
      var tags = []
      if (state.tag) tags.push(state.tag)
      if (state.decade) tags.push(state.decade)
      if (tags.length === 1) params.push("tag=" + encodeURIComponent(tags[0]))
      else if (tags.length > 1) params.push("tagList=" + encodeURIComponent(tags.join(",")))
      params.push("limit=80")
      // Confirmed live: order=lastchange is not a valid Radio Browser order
      // value and silently falls back to the API's default ordering;
      // order=changetimestamp is the value that actually sorts by recency.
      // shuffleActive overrides state.sortOrder for exactly one fetch (see
      // shuffleStations()) without touching the persisted sort choice —
      // _shuffle is a throwaway cache-busting param (see shuffleSeed above),
      // ignored by the API itself, since repeating the identical
      // order=random query string otherwise returns the identical order.
      params.push("order=" + (root.shuffleActive ? "random" : (state.sortOrder || "clickcount")))
      if (root.shuffleActive) params.push("_shuffle=" + root.shuffleSeed)
      params.push("reverse=true")
      params.push("hidebroken=true")
      return ["curl", "-sS", "-L", "--max-time", "8", "-A", root.userAgent,
        root.currentApiHost + "/json/stations/search?" + params.join("&")]
    }
    stdout: StdioCollector {
      onStreamFinished: {
        // A killed-for-restart stationsProc's belated result — a fresher
        // fetch (or an intentional clear) already superseded it. onExited
        // is the final signal for this same kill, and resets the guard.
        if (root.stationsSwitching) return
        var raw = String(text || "")
        var list = []
        var parseOk = false
        try {
          var data = JSON.parse(raw)
          if (Array.isArray(data)) {
            parseOk = true
            for (var i = 0; i < data.length; i++) {
              var s = data[i]
              var url = String((s && (s.url_resolved || s.url)) || "")
              var uuid = String((s && s.stationuuid) || "")
              var name = String((s && s.name) || "").trim()
              if (!uuid || !name || !/^https?:\/\//i.test(url)) continue
              // Same scheme check already applied to the play URL above —
              // an Image element can resolve non-http(s) schemes (e.g.
              // file://), so an untrusted directory response shouldn't get
              // to hand one straight to it.
              var favicon = String((s && s.favicon) || "")
              if (!/^https?:\/\//i.test(favicon)) favicon = ""
              // Same scheme check as favicon above — this gets handed to
              // Qt.openUrlExternally(), not just displayed, so an untrusted
              // non-http(s) scheme (e.g. a local file:// or a custom
              // handler) must never reach it.
              var homepage = String((s && s.homepage) || "")
              if (!/^https?:\/\//i.test(homepage)) homepage = ""
              list.push({
                uuid: uuid,
                name: name,
                playUrl: url,
                codec: String((s && s.codec) || ""),
                bitrate: Number((s && s.bitrate) || 0),
                tags: String((s && s.tags) || ""),
                favicon: favicon,
                countryCode: /^[A-Za-z]{2}$/.test(String((s && s.countrycode) || "")) ? String(s.countrycode).toUpperCase() : "",
                countryName: String((s && s.country) || "").slice(0, 200),
                homepage: homepage,
                votes: Number((s && s.votes) || 0)
              })
            }
          }
        } catch (e) { }
        // Read by onExited below to decide whether a 200-with-garbage-body
        // response (curl itself succeeds, so exit code alone misses this)
        // also deserves a retry, not just a nonzero exit code.
        root.stationsParseOk = parseOk
        for (var j = 0; j < list.length; j++) stationsModel.append(list[j])
        root.resortStations()
      }
    }
    onExited: function(code, status) {
      if (root.stationsSwitching) { root.stationsSwitching = false; return }
      // One retry against the next resolved server, matching Radio
      // Browser's own documented usage pattern — see apiServers above.
      // Covers both a transport failure (nonzero exit) and a degraded
      // mirror that returns HTTP 200 with a malformed body (parseOk
      // false despite curl succeeding) — either way, this run produced
      // nothing usable.
      if ((code !== 0 || !root.stationsParseOk) && !root.stationsRetried) {
        root.stationsRetried = true
        root.apiServerIndex = (root.apiServerIndex + 1) % root.apiServers.length
        root.loadingStations = true
        Qt.callLater(function() { stationsProc.running = true })
        return
      }
      root.loadingStations = false
      if (code !== 0 || !root.stationsParseOk) {
        root.stationsError = "Couldn't reach the radio directory. Check your connection."
      }
      // Deferred to here (the true final outcome, after any retry) rather
      // than onStreamFinished — consuming this on a failed attempt that's
      // about to be retried would silently drop the Surprise pick the
      // moment a retry succeeds afterward, since the flag would already
      // be cleared by the time a usable list exists.
      if (root.pendingSurprise) {
        root.pendingSurprise = false
        if (stationsModel.count > 0) {
          root.playStation(stationsModel.get(Math.floor(Math.random() * stationsModel.count)))
          root.notifyStationChange()
        }
      }
    }
  }

  Process { id: clickProc; command: ["curl", "-sS", "--max-time", "6", "-A", root.userAgent, root.apiHost + "/json/url/" + state.stationUuid] }

  // Station name only — no genre (nowPlayingGenre arrives asynchronously
  // over mpv's IPC after playback starts, later than this fires) and a
  // generic stock icon rather than the station's favicon (no download-
  // and-cache mechanism exists in this codebase for that).
  Process {
    id: notifyProc
    // "--" ends option parsing (confirmed live against this machine's
    // notify-send) — state.stationName is untrusted, API-sourced text;
    // without it, a station name starting with "-" could be parsed as a
    // notify-send flag instead of displayed as the notification body.
    command: ["notify-send", "-a", "World Radio", "-i", "audio-x-generic", "-t", "3000", "--", "Now playing", state.stationName]
  }

  // Fired only for station changes the listener didn't directly click
  // (Prev/Next, Surprise) — a direct row click already shows them exactly
  // what they picked, so notifying there would be redundant. Not called
  // for Shuffle: shuffleStations() only reorders the visible list, it
  // never changes what's actually playing.
  function notifyStationChange() {
    notifyProc.running = false
    Qt.callLater(function() { notifyProc.running = true })
  }

  Process {
    id: voteProc
    command: ["curl", "-sS", "--max-time", "6", "-A", root.userAgent, root.apiHost + "/json/vote/" + root.voteInFlightUuid]
    stdout: StdioCollector {
      onStreamFinished: {
        // If onExited's backstop below has already run, it was for a
        // genuine process failure (it only acts on a non-zero exit code)
        // and already recorded that; this must not overwrite it — either
        // with a real-but-oddly-delayed result for the same request, or
        // (if a new vote had already started) an empty/misattributed uuid.
        if (root.voteInFlightUuid === "") return
        var votedUuid = root.voteInFlightUuid
        root.voteInFlightUuid = ""
        var ok = false
        try {
          // Confirmed live: the vote endpoint always returns HTTP 200 —
          // success or failure (rate-limited, invalid station id, etc.)
          // is only distinguishable via this "ok" field, never the HTTP
          // status or curl's own exit code.
          var data = JSON.parse(String(text || ""))
          ok = !!(data && data.ok === true)
        } catch (e) { }
        root.voteUuid = votedUuid
        root.voteOk = ok
        voteFeedbackTimer.restart()
      }
    }
    onExited: function(code, status) {
      // Only acts on a genuine process failure (curl crashed or never
      // spawned) — a normal exit (code 0) is left entirely to
      // onStreamFinished, even if it fires fractionally after this,
      // rather than guessing based on which of the two fires first. A
      // successful curl has already written its full response into the
      // pipe by the time it exits, so onStreamFinished still reliably
      // follows; unconditionally treating "onExited got here first" as
      // failure (an earlier version of this code did) could otherwise
      // show a false ✕ for a vote that actually succeeded.
      if (code === 0 || root.voteInFlightUuid === "") return
      // Without this, voteInFlightUuid (and thus every future vote) would
      // be stuck forever, and the button would silently revert to "👍"
      // with no indication anything went wrong — matching the error
      // feedback the stationsProc/geoLocationProc backstops already give.
      var votedUuid = root.voteInFlightUuid
      root.voteInFlightUuid = ""
      root.voteUuid = votedUuid
      root.voteOk = false
      voteFeedbackTimer.restart()
    }
  }

  Process {
    id: mpvProc
    command: ["mpv", "--no-video", "--idle=yes", "--really-quiet",
      "--input-ipc-server=" + root.ipcSocketPath,
      "--volume=" + Math.max(0, Math.min(root.volumeCeiling, state.volume)), state.stationUrl]
    onExited: function(code, status) {
      if (root.switchingStation) {
        // Expected: playStation() killed this instance to start the next
        // station, which is already (re)starting on its own. Nothing here
        // belongs to that new station's lifecycle, so touch nothing else.
        root.switchingStation = false
        return
      }
      ipcRetryTimer.stop()
      ipcSocket.connected = false
      state.playing = false
      root.pendingHistoryRow = null
      root.resetPlaybackDisplay()
      root.cancelSleepTimer()
    }
  }

  Timer {
    id: ipcRetryTimer
    interval: 400
    repeat: true
    property int attempts: 0
    onTriggered: {
      attempts += 1
      if (ipcSocket.connected || attempts > 20) { stop(); return }
      ipcSocket.path = root.ipcSocketPath
      ipcSocket.connected = true
    }
  }

  // interval is set right before start() in setSleepTimer() below — there's
  // no fixed value here since it depends on which duration was picked.
  Timer {
    id: sleepTimer
    repeat: false
    onTriggered: {
      root.sleepTimerOption = "off"
      root.stopPlayback()
    }
  }

  Socket {
    id: ipcSocket
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.handleMpvMessage(data) }
    }
    onConnectionStateChanged: {
      if (connected) {
        ipcRetryTimer.stop()
        write(JSON.stringify({ command: ["set_property", "pause", false] }) + "\n")
        // Internet radio streams vary wildly in loudness station-to-station;
        // mpv's bundled loudnorm filter evens that out. Fire-and-forget,
        // same as the pause reset above — no reply is awaited or checked,
        // and a failed af here must never block playback from starting.
        // Confirmed against mpv's own input.rst: the runtime command is
        // `af <operation> <value>` ("add" to append to the filter chain) —
        // there is no separate "af-add" command in the JSON IPC protocol.
        write(JSON.stringify({ command: ["af", "add", "lavfi=[loudnorm]"] }) + "\n")
        // Each station change spawns a fresh mpv instance (see
        // playStation()) with no filters carried over, so a standing Deep
        // bass preference needs re-applying on every new connection too —
        // unlike loudnorm above, only when the listener actually has it on.
        if (state.deepBassEnabled) {
          write(JSON.stringify({ command: ["af", "add", root.deepBassFilter] }) + "\n")
        }
        // Registered once per connection. mpv sends an immediate
        // property-change event with the current value on registration
        // (per its own client.h docs), then another on every future
        // change — so this alone seeds state on connect *and* keeps it
        // instantly in sync, with no separate get_property call needed.
        write(JSON.stringify({ command: ["observe_property", root.metadataObserveId, "metadata"] }) + "\n")
        write(JSON.stringify({ command: ["observe_property", root.pauseObserveId, "pause"] }) + "\n")
        // Surfaces real "Buffering…" feedback during the connection gap
        // (or a later rebuffer) instead of leaving that window blank —
        // confirmed live against a real mpv instance and stream.
        write(JSON.stringify({ command: ["observe_property", root.pausedForCacheObserveId, "paused-for-cache"] }) + "\n")
        write(JSON.stringify({ command: ["observe_property", root.cacheBufferingStateObserveId, "cache-buffering-state"] }) + "\n")
        write(JSON.stringify({ command: ["observe_property", root.timePosObserveId, "time-pos"] }) + "\n")
        flush()
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐹"
    active: state.playing
    tooltipText: state.playing
      ? ("Playing: " + state.stationName + (root.buffering
          ? (" — Buffering… " + root.bufferingPercent + "%")
          : (root.nowPlayingCaption() ? " — " + root.nowPlayingCaption() : "")))
      : "World Radio"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.stopPlayback()
      else if (b === Qt.MiddleButton) root.togglePause()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Two panes side by side: a fixed-width left column for the pickers,
    // and a right pane that gets whatever's left for the station list — so
    // the list isn't squeezed into whatever's left below a tall stack of
    // controls. Compact drops the right pane and most of the left column,
    // so it gets its own, much narrower width instead: the fixed 320px
    // column plus the card's real horizontal insets on both sides (border
    // + popup padding, ~16px each at default theme settings — confirmed
    // against KeyboardPanel/BorderSurface's own contentLeftInset/
    // contentRightInset, not guessed), so the column doesn't crowd the
    // card's border. See docs/expand-compact-view-research.md.
    contentWidth: panel.fittedContentWidth(state.compactView ? Style.space(352) : Style.space(780))
    // Expand: a deliberately oversized desired height clamps to
    // availableCardHeight inside fittedContentHeight — i.e. the panel
    // always grows to fill the screen down to the bar/margins, so the
    // station list below gets all the leftover room instead of a small
    // fixed-height peephole.
    // Compact: no station list to fill room for, so — like every other
    // Omarchy shell panel — the real content column's own implicitHeight
    // is passed instead, and the panel shrinks to fit it.
    contentHeight: panel.fittedContentHeight(state.compactView ? leftColumnContent.implicitHeight : Style.space(4000))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Item {
        anchors.fill: parent

        // Scrolls independently of the station list on the right (which
        // already scrolls via its own ListView) — the column has grown
        // past what fits on screen as pickers were added over time, and
        // without this, content past the visible edge (e.g. the language
        // filter) is simply unreachable rather than clipped or scrollable.
        // Matches the shell's own audio panel's shape (a PanelSlider inside
        // a scrollable settings column): ScrollView with a Binding gating
        // interactivity by actual overflow, plus a scrollbar that only
        // appears when there's something to scroll, rather than an ad hoc
        // Flickable.
        ScrollView {
          id: leftColumn
          width: Style.space(320)
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
          ScrollBar.vertical.policy: leftColumnContent.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

          // The audio panel's own PanelSliders don't guard against this,
          // but its consequence turned out worse than a cut-short drag:
          // PanelSlider's `dragging` flag has no onCanceled, only
          // onReleased, so a grab stolen mid-drag by this ScrollView's
          // Flickable leaves `dragging` stuck true permanently — its knob
          // then never reflects `state.volume` again (onValueChanged only
          // updates the visible position `if (!dragging)`), not just a
          // one-off interrupted gesture. Unlike PanelSlider.qml itself
          // (a shared qs.Ui component, not this plugin's to change),
          // suppressing this container's interactivity for the duration
          // of a drag is entirely within this file, so there's no reason
          // to accept the same latent risk here once it's understood.
          Binding {
            target: leftColumn.contentItem
            property: "interactive"
            value: leftColumnContent.implicitHeight > leftColumn.height && !volumeSlider.dragging
          }

          Column {
            id: leftColumnContent
            width: leftColumn.availableWidth
            spacing: Style.space(12)

            // ---------- Now playing hero ----------
            Item {
              width: parent.width
              implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

              Text {
                id: heroIcon
                text: "󰐹"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Always reachable in both modes, unlike every other control
              // in this column — it's the only way back to Expand once
              // Compact has hidden everything else.
              Text {
                id: modeToggle
                text: state.compactView ? "Expand" : "Compact"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleCompactView()
                }
              }

              Column {
                id: heroLabels
                anchors.left: heroIcon.right
                anchors.leftMargin: Style.space(14)
                anchors.right: modeToggle.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: "World Radio"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: state.playing ? state.stationName : "Not playing"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  visible: root.buffering || root.nowPlayingCaption() !== ""
                  text: root.buffering
                    ? ("Buffering… " + root.bufferingPercent + "%")
                    : root.nowPlayingCaption()
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }
            }

            // ---------- Tuning dial: previous / pause / next / stop / surprise ----------
            // Icon-only, content-sized, borderless-at-rest — matches
            // Omarchy's own media-transport widget
            // (plugins/services/media/BarWidget.qml), reusing the identical
            // prev/next glyphs plus its play/pause glyphs (unused elsewhere
            // in this file until now) and its "primary action is slightly
            // larger" treatment for Pause/Resume. Once grew to ten buttons
            // (Sleep timer, Shuffle, and Recently added all landed here
            // over time) and silently overflowed this column's width —
            // Recently added's removal brought it back down to nine,
            // fitting comfortably in one Row again. See
            // docs/compact-transport-buttons-research.md for the original
            // shape, and git history on this comment for the overflow
            // detour if a similar growth spurt happens again.
            //
            // Left-anchored, not centered: leftColumn's vertical ScrollBar
            // is an overlay pinned to this column's true right edge
            // (confirmed by reading the installed Qt Quick Controls Basic
            // style's ScrollView.qml/ScrollBar.qml — never subtracted from
            // available width on its own), so the row's rightmost button
            // could still end up under it when scrolling is active. For a
            // *centered* row, reserving margin by narrowing the container
            // only helps the right edge by giving up an equal amount on
            // the left — a real risk given this row's own left-most
            // buttons (Previous, Play/Pause) have never had much slack to
            // spare either. Left-anchoring sidesteps that trade-off
            // entirely: the left edge stays exactly where it already
            // safely was, and every bit of the row's natural slack shifts
            // to the right edge instead of being split, directly
            // improving clearance on the side that actually needs it.
            Row {
              anchors.left: parent.left
              spacing: Style.space(6)

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰒮"
                tooltipText: "Previous station"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: stationsModel.count > 0
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.playRelativeStation(-1)
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.paused ? "󰐊" : "󰏤"
                tooltipText: root.paused ? "Resume playback" : "Pause playback"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: state.playing
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.togglePause()
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰒭"
                tooltipText: "Next station"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: stationsModel.count > 0
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.playRelativeStation(1)
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰓛"
                tooltipText: "Stop"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: state.playing
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.stopPlayback()
              }

              // A playback control like Stop, not a browsing feature, so —
              // unlike Shuffle/Trending/Near me below — it
              // stays visible in Compact mode too.
              Button {
                id: sleepTimerButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: "💤"
                tooltipText: root.sleepTimerOption === "off"
                  ? "Sleep timer"
                  : "Sleep timer: " + root.sleepTimerOption + " min"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                active: root.sleepTimerOption !== "off"
                onClicked: sleepTimerPopup.opened ? sleepTimerPopup.close() : sleepTimerPopup.open()

                Popup {
                  id: sleepTimerPopup
                  parent: sleepTimerButton
                  x: 0
                  y: sleepTimerButton.height + Style.spacing.xxs
                  width: Style.space(110)
                  padding: Style.spacing.hairline
                  focus: true
                  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                  background: BorderSurface {
                    color: Color.popups.background
                    borderSpec: Border.flat(Color.popups.border, Style.normalBorderWidth)
                    radius: Style.cornerRadius
                  }

                  contentItem: Column {
                    id: sleepTimerColumn
                    width: sleepTimerPopup.width - Style.spacing.hairline * 2
                    spacing: Style.spacing.labelGap

                    Repeater {
                      model: [
                        { value: "off", label: "Off" },
                        { value: "15", label: "15 min" },
                        { value: "30", label: "30 min" },
                        { value: "60", label: "60 min" }
                      ]
                      delegate: Rectangle {
                        required property var modelData
                        width: sleepTimerColumn.width
                        height: Style.spacing.popupRowHeight
                        color: modelData.value === root.sleepTimerOption
                          ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                          : "transparent"

                        Text {
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.spacing.controlPaddingX
                          anchors.rightMargin: Style.spacing.controlPaddingX
                          text: modelData.label
                          color: modelData.value === root.sleepTimerOption
                            ? Style.hoverStateColor(root.bar.foreground, Color.accent)
                            : root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.body
                        }

                        MouseArea {
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.setSleepTimer(modelData.value)
                            sleepTimerPopup.close()
                          }
                        }
                      }
                    }
                  }
                }
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "🎲"
                tooltipText: "Surprise me"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.surpriseMe()
              }

              // Hidden individually (not as a group) — safe here because
              // this Row always has the always-visible buttons above as
              // siblings, so it's never entirely empty in Compact mode
              // the way the old, since-removed second Row could be (that
              // Row needed visible:false on itself instead, once Recently
              // added's removal left it holding fewer buttons — simplest
              // to fold these back into the one Row above rather than
              // keep two).
              Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: !state.compactView
                iconText: "🔀"
                tooltipText: "Shuffle"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: stationsModel.count > 0
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.shuffleStations()
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: !state.compactView
                iconText: "🔥"
                tooltipText: "Trending"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                active: state.sortOrder === "votes"
                onClicked: root.toggleSortOrder("votes")
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: !state.compactView
                iconText: "📍"
                tooltipText: "Near me"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                active: root.geoActive
                onClicked: root.findNearMe()
              }
            }

            // ---------- Expand-only: geo detail ----------
            // Compact hides this whole group (visible: false, not just
            // opacity/height, so it also drops out of tab order — see
            // docs/expand-compact-view-research.md and issue #11). Nothing
            // inside is reset: switching back to Expand shows exactly what
            // was here before switching away.
            Column {
              width: parent.width
              spacing: Style.space(12)
              visible: !state.compactView

              Row {
                width: parent.width
                spacing: Style.space(6)
                visible: root.geoActive

                Text {
                  width: parent.width - geoClearButton.width - parent.spacing
                  text: root.geoLabel
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  id: geoClearButton
                  text: "✕"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.clearGeo()
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.loadingGeo
                text: "Finding your location…"
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                visible: root.geoError !== ""
                text: root.geoError
                color: root.bar.foreground
                wrapMode: Text.WordWrap
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Deep bass sits alongside the volume slider (not the Surprise/
            // Shuffle/Trending row above) since it's an audio control, not
            // a browsing action — same reasoning as the sleep timer, and
            // likewise visible in both Compact and Expand.
            Row {
              id: volumeRow
              width: parent.width
              spacing: Style.space(8)

              PanelSlider {
                id: volumeSlider
                width: parent.width - deepBassButton.width - volumeRow.spacing
                bar: root.bar
                minimum: 0
                maximum: root.volumeCeiling
                step: 1
                integer: true
                value: state.volume
                // PanelSlider only exposes a single solid fillColor (no
                // built-in two-tone/split fill), so a boosted-past-100%
                // state is signaled by switching the whole fill to
                // Color.urgent rather than forking the shared component to
                // paint just the boosted portion differently.
                fillColor: state.volume > 100 ? Color.urgent : (root.bar ? root.bar.foreground : Color.foreground)
                onMoved: function(v) {
                  state.volume = v
                  if (ipcSocket.connected) {
                    ipcSocket.write(JSON.stringify({ command: ["set_property", "volume", v] }) + "\n")
                    ipcSocket.flush()
                  }
                }
              }

              Button {
                id: deepBassButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: "🎧"
                tooltipText: state.deepBassEnabled ? "Deep bass: on" : "Deep bass"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                active: state.deepBassEnabled
                onClicked: root.toggleDeepBass()
              }
            }

            // ---------- Expand-only: search, country, mood, decade, language ----------
            // Same visible:false hide as the sort/geo group above.
            Column {
              width: parent.width
              spacing: Style.space(12)
              visible: !state.compactView

              // Own section, Expand-only, collapses entirely (separator
              // included) until the first play — a listener who's never
              // played anything has nothing to show here yet.
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.history.length > 0

                PanelSeparator { foreground: root.bar.foreground }
                PanelSectionHeader { text: "HISTORY"; foreground: root.bar.foreground }

                // Fixed height, capped at historyVisibleRows — scrolls
                // internally past that (same clip-and-flick shape as the
                // main station list, no explicit scrollbar there either)
                // instead of growing the whole left column as History
                // fills up toward maxHistory.
                ListView {
                  id: historyList
                  width: parent.width
                  height: Math.min(count, root.historyVisibleRows) * (Style.space(28) + spacing) - spacing
                  clip: true
                  spacing: Style.space(2)
                  boundsBehavior: Flickable.StopAtBounds
                  model: root.history

                  delegate: Rectangle {
                    id: historyRow
                    required property var modelData
                    width: historyList.width
                    height: Style.space(28)
                    radius: Style.cornerRadius
                    color: historyMouse.containsMouse
                      ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                      : "transparent"

                    Text {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(6)
                      anchors.rightMargin: Style.space(6)
                      text: historyRow.modelData.name
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    MouseArea {
                      id: historyMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.playStation(historyRow.modelData)
                    }
                  }
                }
              }

              PanelSeparator { foreground: root.bar.foreground }
              PanelSectionHeader { text: "SEARCH BY NAME"; foreground: root.bar.foreground }

              TextField {
                id: nameField
                width: parent.width
                placeholderText: "Station name…"
                foreground: root.bar.foreground
                onTextChanged: {
                  root.nameQuery = text
                  nameSearchTimer.restart()
                }
              }

              Text {
                width: parent.width
                visible: root.nameQuery.trim() !== ""
                text: state.countryCode !== ""
                  ? "Matching “" + root.nameQuery.trim() + "” in " + state.countryName
                  : "Matching “" + root.nameQuery.trim() + "” worldwide"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              PanelSeparator { foreground: root.bar.foreground }
              PanelSectionHeader { text: "COUNTRY"; foreground: root.bar.foreground }

              PanelSectionHeader {
                visible: root.recentCountries.length > 0
                text: "RECENT COUNTRIES"
                foreground: root.bar.foreground
              }
              Flow {
                id: recentCountriesFlow
                objectName: "recentCountries"
                width: parent.width
                visible: root.recentCountries.length > 0
                spacing: Style.space(6)
                Repeater {
                  model: root.recentCountries
                  delegate: Button {
                    required property var modelData
                    objectName: "recentCountry-" + modelData.code
                    text: root.flagFor(modelData.code) + " " + modelData.name
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    fontSize: Style.font.bodySmall
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.space(4)
                    bordered: true
                    active: state.countryCode === modelData.code
                    onClicked: root.selectCountry(modelData.code, modelData.name)
                  }
                }
              }

              Flow {
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.curatedCountries
                  delegate: Button {
                    required property var modelData
                    text: root.flagFor(modelData.code) + " " + modelData.name
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    fontSize: Style.font.bodySmall
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.space(4)
                    bordered: true
                    active: state.countryCode === modelData.code
                    onClicked: root.selectCountry(modelData.code, modelData.name)
                  }
                }
              }

              TextField {
                id: countryField
                width: parent.width
                placeholderText: "Search any country…"
                foreground: root.bar.foreground
                onTextChanged: {
                  root.countryQuery = text
                  root.ensureCountriesLoaded()
                  root.updateCountryMatches()
                }
              }

              Text {
                width: parent.width
                visible: root.countryQuery.trim() !== "" && root.loadingCountries
                text: "Searching countries…"
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                visible: root.countriesError !== ""
                text: root.countriesError
                color: root.bar.foreground
                wrapMode: Text.WordWrap
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                visible: !root.loadingCountries && root.countriesError === "" && root.countryQuery.trim() !== "" && root.allCountries.length > 0 && root.countryMatches.length === 0
                text: "No countries match “" + root.countryQuery.trim() + "”."
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Column {
                width: parent.width
                spacing: Style.space(2)
                visible: root.countryMatches.length > 0
                Repeater {
                  model: root.countryMatches
                  delegate: Button {
                    required property var modelData
                    width: parent.width
                    leftAlign: true
                    text: root.flagFor(modelData.code) + "  " + modelData.name
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.space(4)
                    onClicked: {
                      // Deferred: selectCountry() clears root.countryMatches,
                      // which is this Repeater's own model — doing that
                      // synchronously from inside this delegate's own click
                      // handler destroys the Button mid-handler (the first-
                      // party notifications service hits the same class of
                      // bug and documents it as Qt.callLater avoiding a
                      // QV4::Object::insertMember crash when a Repeater is
                      // mid-incubation while its model is mutated). Without
                      // this, the handler aborted after clearing the search
                      // text and never reached selectCountry() at all, so
                      // picking a search result silently failed to load its
                      // stations — confirmed via a live "ReferenceError: root
                      // is not defined" at this exact line in journalctl.
                      var pickedCode = modelData.code
                      var pickedName = modelData.name
                      Qt.callLater(function() {
                        countryField.text = ""
                        root.selectCountry(pickedCode, pickedName)
                      })
                    }
                  }
                }
              }

              PanelSeparator { foreground: root.bar.foreground }
              PanelSectionHeader { text: "MOOD (OPTIONAL)"; foreground: root.bar.foreground }

              Flow {
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.curatedTags
                  delegate: Button {
                    required property var modelData
                    text: modelData
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    fontSize: Style.font.bodySmall
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.space(4)
                    bordered: true
                    active: state.tag === modelData
                    onClicked: root.toggleTag(modelData)
                  }
                }
              }

              PanelSeparator { foreground: root.bar.foreground }
              PanelSectionHeader { text: "DECADE (OPTIONAL)"; foreground: root.bar.foreground }

              Flow {
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.curatedDecades
                  delegate: Button {
                    required property var modelData
                    text: modelData
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    fontSize: Style.font.bodySmall
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.space(4)
                    bordered: true
                    active: state.decade === modelData
                    onClicked: root.toggleDecade(modelData)
                  }
                }
              }

              PanelSeparator { foreground: root.bar.foreground }
              PanelSectionHeader { text: "LANGUAGE (OPTIONAL)"; foreground: root.bar.foreground }

              Row {
                width: parent.width
                spacing: Style.space(6)
                visible: state.languageCode !== ""

                Text {
                  width: parent.width - languageClearButton.width - parent.spacing
                  text: state.languageName
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  id: languageClearButton
                  text: "✕"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.clearLanguage()
                  }
                }
              }

              TextField {
                id: languageField
                width: parent.width
                placeholderText: "Search any language…"
                foreground: root.bar.foreground
                onTextChanged: {
                  root.languageQuery = text
                  root.ensureLanguagesLoaded()
                  root.updateLanguageMatches()
                }
              }

              Text {
                width: parent.width
                visible: root.languageQuery.trim() !== "" && root.loadingLanguages
                text: "Searching languages…"
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                visible: root.languagesError !== ""
                text: root.languagesError
                color: root.bar.foreground
                wrapMode: Text.WordWrap
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                visible: !root.loadingLanguages && root.languagesError === "" && root.languageQuery.trim() !== "" && root.allLanguages.length > 0 && root.languageMatches.length === 0
                text: "No languages match “" + root.languageQuery.trim() + "”."
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Column {
                width: parent.width
                spacing: Style.space(2)
                visible: root.languageMatches.length > 0
                Repeater {
                  model: root.languageMatches
                  delegate: Button {
                    required property var modelData
                    width: parent.width
                    leftAlign: true
                    text: modelData.name
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.space(4)
                    onClicked: {
                      // Same deferred-selection pattern as the country search
                      // results above (selectLanguage() clears this Repeater's
                      // own model mid-click-handler otherwise).
                      var pickedCode = modelData.code
                      var pickedName = modelData.name
                      Qt.callLater(function() {
                        languageField.text = ""
                        root.selectLanguage(pickedCode, pickedName)
                      })
                    }
                  }
                }
              }
            }
          }
        }

        Rectangle {
          id: columnDivider
          visible: !state.compactView
          width: 1
          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          anchors.left: leftColumn.right
          anchors.leftMargin: Style.space(8)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
        }

        // ---------- Right pane: stations get the whole rest of the panel ----------
        // Hidden entirely in Compact — see docs/expand-compact-view-research.md.
        Item {
          id: rightPane
          visible: !state.compactView
          anchors.left: columnDivider.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom

          PanelSectionHeader {
            id: stationsHeader
            text: "STATIONS"
            foreground: root.bar.foreground
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
          }

          Text {
            anchors.top: stationsHeader.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            visible: root.loadingStations
            text: "Loading stations…"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            anchors.top: stationsHeader.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            visible: !root.loadingStations && root.stationsError !== ""
            text: root.stationsError
            color: root.bar.foreground
            wrapMode: Text.WordWrap
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            anchors.top: stationsHeader.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            visible: !root.loadingStations && root.stationsError === "" && !root.hasLoadedStations()
            text: "Pick a country, search by name, pick a language, or find stations near you, to tune in."
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            anchors.top: stationsHeader.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            visible: !root.loadingStations && root.stationsError === "" && root.hasLoadedStations() && stationsModel.count === 0
            text: "No stations found — try a different name, mood, country, language, or location."
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Fills every remaining pixel down to the bottom of the panel.
          ListView {
            id: stationsList
            anchors.top: stationsHeader.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: stationsModel.count > 0
            clip: true
            spacing: Style.space(2)
            model: stationsModel

            delegate: Rectangle {
              id: row
              required property string uuid
              required property string name
              required property string playUrl
              required property string countryCode
              required property string countryName
              required property string codec
              required property int bitrate
              required property string tags
              required property string favicon
              required property string homepage
              required property int votes

              width: stationsList.width
              height: Style.space(44)
              radius: Style.cornerRadius
              color: rowMouse.containsMouse
                ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                : (state.stationUuid === row.uuid ? Style.selectedFillFor(root.bar.foreground, Color.accent) : "transparent")

              // Row-wide click target underneath everything else, so the
              // star button (declared last, on top) can claim clicks in its
              // own smaller area first.
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.playStation(row)
              }

              // Only the API's own favicon field, already present in every
              // stationsProc response — no new fetch. Left unshown entirely
              // when empty, and allowed to fail silently (blank) on a dead
              // or invalid URL, same as any other third-party image source.
              Image {
                id: faviconImage
                visible: row.favicon !== ""
                width: Style.space(24)
                height: Style.space(24)
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                source: row.favicon
                fillMode: Image.PreserveAspectFit
                // Decode at (roughly) display resolution instead of full
                // size — up to 80 rows can each carry a favicon, and some
                // directory entries are large PNGs/ICOs.
                sourceSize: Qt.size(48, 48)
                asynchronous: true
                smooth: true
              }

              Column {
                anchors.left: faviconImage.visible ? faviconImage.right : parent.left
                anchors.right: homepageButton.visible ? homepageButton.left : voteButton.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: faviconImage.visible ? Style.space(6) : Style.space(10)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: row.name
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: [row.codec, row.bitrate ? row.bitrate + "kbps" : "", row.tags, row.votes > 0 ? root.formatVoteCount(row.votes) + " votes" : ""].filter(function(s) { return s }).join(" · ")
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              // Absent for a station with no homepage (row.homepage is
              // already "" for anything that wasn't a valid http(s) URL —
              // see stationsProc's own scheme check). The name/caption
              // Column and voteButton's own hit-area both branch on this
              // visibility to reflow into the freed space, the same way
              // faviconImage's absence already does above.
              Text {
                id: homepageButton
                visible: row.homepage !== ""
                text: "🔗"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                width: Style.space(20)
                horizontalAlignment: Text.AlignHCenter
                anchors.right: voteButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter

                // Same split-the-gap shape as voteButton/starButton below:
                // expands less toward voteButton (its only neighbor) than
                // on every other side.
                MouseArea {
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.topMargin: -Style.space(6)
                  anchors.bottomMargin: -Style.space(6)
                  anchors.leftMargin: -Style.space(6)
                  anchors.rightMargin: -Style.space(3)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: Qt.openUrlExternally(row.homepage)
                }
              }

              Text {
                id: voteButton
                text: root.voteUuid === row.uuid ? (root.voteOk ? "✓" : "✕") : "👍"
                // Success gets the same accent already used for an active
                // filter/favorite; failure isn't a color this app uses
                // anywhere (no error-red exists in this file), so it gets
                // the undarkened foreground instead of the same muted tone
                // as the idle icon, rather than blending in as "just 👍".
                color: root.voteUuid === row.uuid
                  ? (root.voteOk ? Color.accent : root.bar.foreground)
                  : Qt.darker(root.bar.foreground, 1.4)
                // Dims fully for the row actually voting, and slightly for
                // every other row while any vote is in flight — a click on
                // another row is silently ignored (voteForStation()'s
                // single-flight guard), so this at least signals "busy"
                // instead of looking fully idle and interactive.
                opacity: root.voteInFlightUuid === row.uuid ? 0.4 : (voteProc.running ? 0.7 : 1.0)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                // Fixed width + centered text, unlike starButton (whose
                // two Nerd Font glyphs already share the same intrinsic
                // width): "👍" and "✓"/"✕" don't, so anchoring by
                // right-edge alone would shift this icon (and the text
                // Column anchored to its left) sideways on every vote.
                width: Style.space(20)
                horizontalAlignment: Text.AlignHCenter
                anchors.right: starButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter

                // Expands outward on every side except toward its two
                // neighbors (homepageButton on the left, starButton on the
                // right) — a uniform -Style.space(6) on either of those
                // sides would reach exactly Style.space(6) past this icon,
                // meeting (and overlapping) the neighbor's own -Style.space(6)
                // expansion, since icons only sit Style.space(6) apart to
                // begin with. Splitting each shared gap in half instead of
                // doubling it into an overlap keeps a click nearest each
                // icon going to that icon. When homepageButton is invisible
                // (no homepage for this station), nothing claims its half
                // of that gap — an invisible item's own MouseArea gets no
                // input at all — so the full -6 is reclaimed here instead
                // of leaving a dead unclickable strip.
                MouseArea {
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.topMargin: -Style.space(6)
                  anchors.bottomMargin: -Style.space(6)
                  anchors.leftMargin: homepageButton.visible ? -Style.space(3) : -Style.space(6)
                  anchors.rightMargin: -Style.space(3)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.voteForStation(row.uuid)
                }
              }

              Text {
                id: starButton
                text: root.isFavorite(row.uuid) ? "󰓎" : "󰓒"
                color: root.isFavorite(row.uuid) ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter

                // Mirrors voteButton's MouseArea above: expands less
                // toward voteButton (its only neighbor) than on every
                // other side, so the two hit-areas meet rather than
                // overlap.
                MouseArea {
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.topMargin: -Style.space(6)
                  anchors.bottomMargin: -Style.space(6)
                  anchors.leftMargin: -Style.space(3)
                  anchors.rightMargin: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleFavorite(row)
                }
              }
            }
          }
        }
      }
    }
  }
}
