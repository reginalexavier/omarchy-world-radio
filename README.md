# World Radio

[![CI](https://github.com/Macs9319/omarchy-world-radio/actions/workflows/ci.yml/badge.svg)](https://github.com/Macs9319/omarchy-world-radio/actions/workflows/ci.yml)

Spin the globe, land somewhere you've never been, and hear what's actually playing there
right now.

World Radio is an [Omarchy](https://omarchy.org/) shell plugin built around that one
idea. Pick a country, a language, or just search for something nearby, narrow it down by
mood or decade if you feel like it, and tune in. It's a small nod to
[radiooooo.com](https://app.radiooooo.com/)'s "spin the globe" trick — but built entirely
on the open [Radio Browser](https://www.radio-browser.info/) directory instead of a
closed catalog, so there's no proprietary anything behind it.

![World Radio panel](preview.png)

## Features

- **Country picker** — flags for popular countries, plus a search box covering every
  country in the directory.
- **Search by name** — type a station name to filter the list, on its own or combined
  with any other filter you've picked.
- **Mood and decade** — tap a tag like pop, jazz, or 90s to narrow things down; use both
  together if you like.
- **Language filter** — search by language, and combine it with whatever else you've set.
- **Near me** — finds stations within 50km of roughly where you are, using your
  connection's location. No typing an address.
- **Trending** — sort the list by what's popular right now, instead of all-time
  popularity.
- **Shuffle** — mixes up the order of your current list without touching any filter.
  (Surprise, below, is different — it ignores your filters entirely.)
- **Tuning dial** — Previous/Next step through your list one station at a time; 🎲
  Surprise picks a totally random country and station.
- **Favorites** — star a station to keep it at the top of the list. Saved to disk, so
  it's still there next time you open the panel. Refreshed against the live directory
  once per session (the first time you open the panel), so stale details don't linger
  and a station pulled from the directory quietly drops off your list.
- **History** — the last 15 stations you played, newest first. Play one again and it
  just moves back to the top instead of showing up twice.
- **Vote** — give a station a thumbs up in the public directory, separate from starring
  it as your own favorite. Its vote count shows in the row too, when it has one.
- **Station favicon** — each station shows its own logo, when the directory has one.
- **Homepage link** — a 🔗 next to vote/star opens the station's own website, when it has
  one listed.
- **Playback controls** — Play/Pause, Stop, and a volume slider that goes past 100% for
  extra-loud stations (it changes color past 100% as a heads-up that things might
  distort).
- **Sleep timer** — set it to stop playing after 15, 30, or 60 minutes. Picking a new
  station or hitting Stop cancels it.
- **Auto volume leveling** — quiet stations and loud ones come out at roughly the same
  volume, so you're not riding the slider every time you switch.
- **Deep bass** — a one-tap toggle (🎧, next to the volume slider) for a bit more low
  end. Stays on across stations until you turn it back off.
- **Now playing** — shows the song or show title and genre when a station sends them,
  plus a real buffering percentage while it connects.
- **Desktop notification** — switching stations with Previous, Next, or Surprise pops up
  a notification with the new station's name, so you always know what just started.
- **More reliable** — if the station directory's server has a brief hiccup, this plugin
  automatically tries again instead of just giving up.
- **Media keys** — your keyboard's play/pause/stop buttons work automatically, and so
  does any other app that can control media playback.
- **Compact mode** — shrink the panel down to just what's playing and the basic
  controls, or expand it back out to browse. It remembers which one you had open.
- In Expand mode, filters live on the left and the station list gets the whole right
  side, each scrolling on its own.

## Requirements

- [Omarchy](https://omarchy.org/), with its shell (Quickshell) plugin system — this
  comes standard.
- `mpv`, the actual player doing the playback. Grab `mpv-mpris` too
  (`omarchy pkg add mpv-mpris`) if you want your media keys to work.
- `curl`, for talking to the station directory.
- `python3` (already on Omarchy) — used to read your saved favorites and history safely.
- `notify-send` (already on Omarchy) — for the station-change notification.

## Install

```sh
omarchy plugin add https://github.com/Macs9319/omarchy-world-radio --enable
```

Or manually:

```sh
git clone https://github.com/Macs9319/omarchy-world-radio ~/.config/omarchy/plugins/ronnie.worldradio
omarchy plugin enable ronnie.worldradio --section right
```

## Uninstall

```sh
omarchy plugin remove ronnie.worldradio
```

This disables the plugin and deletes `~/.config/omarchy/plugins/ronnie.worldradio`. It
doesn't touch anything outside that folder — no other config files are modified. If you
added the optional keybinding from Usage below, remove that line yourself from
`~/.config/hypr/bindings.lua`.

## Usage

Click the radio icon in the bar (or bind a key, e.g. in
`~/.config/hypr/bindings.lua`):

```lua
o.bind("SUPER + R", "World Radio", "omarchy-shell shell toggle ronnie.worldradio")
```

Pick a country, search by name, pick a language, or hit Near me — optionally add a mood
and/or decade, reorder the list by Trending, or hit Shuffle to mix it up — then click a
station to play it. Right-click the bar icon to stop, middle-click to
pause/resume. Click "💤 Sleep timer" to schedule an automatic stop.

Click **Compact** in the top-right of the panel to shrink it down to just playback
controls once you've found a station; click **Expand** to bring the full browser back.

## Settings

One setting is exposed in the plugin's settings form:

- **Default volume** (0–130, default 70)

## Your data

Favorites and History are saved as plain files on your machine —
`~/.local/state/omarchy/world-radio-favorites.json` and
`.../world-radio-history.json`. Reading them back is done carefully, so a corrupted or
tampered file can't cause problems: worst case, it's just treated as if you had no
favorites yet. (Wondering why History gets its own file instead of sharing one with
Favorites? There's a short note in
[docs/adr/0001-history-separate-file.md](docs/adr/0001-history-separate-file.md).)

<details>
<summary>The technical version</summary>

Reading either file goes through a small Python helper (bundled in `Panel.qml`, not a
separate file) that opens it with `O_NOFOLLOW | O_NONBLOCK` and validates the result on
the same file descriptor before reading a single byte:

- **`O_NOFOLLOW`** refuses to open if the path is a symlink, instead of transparently
  reading whatever it points to.
- **`O_NONBLOCK`** makes opening a FIFO return immediately instead of blocking forever
  waiting for a writer.
- Only a plain regular file, checked via `fstat()` on the already-open descriptor (never
  a second lookup of the path), is read — and only up to a 1 MiB cap, enforced by the
  read itself rather than trimmed afterward.

This closes both a TOCTOU window (checking and reading must be the same open, not two
lookups of a path that could change in between) and a symlink-following gap, so a
hostile or corrupted replacement at that path — a FIFO, an oversized file, or a symlink
elsewhere — can't hang or bloat the shell process. Favorite count (500), History count
(15), and per-field string lengths are also capped on both load and write.

</details>

## Notes

Every station here comes from the community-run [Radio Browser](https://www.radio-browser.info/)
directory — thousands of people around the world keeping their local stream listed so
strangers can find it. This plugin has no affiliation with radiooooo.com; it just liked
the spin-the-globe idea and built its own version of it.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history.

## Development checks

Run the country-selection regression test with Python 3 and Quickshell installed:

```sh
python3 -m unittest discover -s tests -v
```

The test runs offscreen and reproduces a search result being destroyed when the
country field is cleared. After changing an installed plugin, restart the shell
with `omarchy restart shell` if automatic reload keeps the previous QML in memory.

## License

MIT
