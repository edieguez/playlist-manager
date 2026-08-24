# playlist-manager

An mpv Lua plugin that adds a keyboard-driven playlist browser/editor
dialog, plus the logic for getting items *into* the playlist in the first
place: clipboard paste, drag-free "add from outside mpv" via the bundled
`mpv-add` CLI, and automatic YouTube-playlist-URL expansion.

## What it does

- **Playlist dialog** (`select-playlist` key binding). A custom overlay
  listing the live playlist with fuzzy search-as-you-type, reordering,
  deletion, and jump-to-item - arrow/vim navigation (`ctrl+j/k/h/l`),
  `ENTER` to jump, `RIGHT`/arrows/`ESC` to reorder or cancel,
  `ctrl+BS` to delete.
- **Adding items.** `ctrl+v` pastes a clipboard URL/path and appends it to
  the playlist. The external `mpv-add` CLI (see below) does the same from
  outside mpv, over IPC. Both funnel through the same core add logic:
  duplicate items are rejected (with an "Already in playlist" toast for
  the clipboard/manual case), a plain YouTube watch URL is never
  accidentally expanded into its autoplay "up next" mix, and an actual
  YouTube *playlist* URL is expanded via `yt-dlp` into its individual
  videos.
- **Background title resolution.** URL entries in the dialog show a
  human-readable title (via `yt-dlp`) instead of the raw URL, when
  `resolve_url_titles=yes` (the default).
- **Passive dedup safety net.** Runs a dedup pass any time the playlist
  count rises, regardless of how the item got there (CLI args, external
  IPC, another script), catching anything the pre-add checks above didn't.

## Installation

1. Copy or symlink `scripts/playlist_manager.lua` into mpv's `scripts/`
   directory.
2. (Optional) Copy `script-opts/playlist_manager.conf` to override
   `resolve_url_titles` (see Configuration).
3. Bind a key to open the dialog, e.g. in `input.conf`:
   ```
   p script-binding playlist_manager/select-playlist
   ```
4. To use the `mpv-add` CLI for adding videos from outside mpv, add this
   to `mpv.conf`:
   ```
   # Required for bin/mpv-add (external "add a video" dispatcher).
   # ~~cache/ is mpv's own cross-platform application-cache dir -
   # resolves to ~/.cache/mpv/ on Linux, ~/Library/Caches/io.mpv/ on
   # macOS. bin/mpv-add's own default mirrors this per-OS, so
   # MPV_SOCKET only needs to be set for a nonstandard mpv config dir.
   input-ipc-server=~~cache/mpv.sock
   ```
   Then put `bin/mpv-add` on your `PATH`, or invoke it by full path.

## Adding a video while mpv may or may not be running

- **mpv already open:** `ctrl+v` appends the clipboard URL/path to the end
  of the playlist.
- **Don't know if mpv is open:** run `bin/mpv-add <url> [url ...]`, or
  `bin/mpv-add -n/--next <url> [url ...]` to insert right after whatever's
  currently playing instead of appending to the end. Either way, items are
  added in the order given, to the running instance over mpv's IPC socket
  if one exists, or launched with a fresh `mpv <url> [url ...]` otherwise.
  Requires `input-ipc-server` to be set (see Installation) and a `nc` with
  unix-socket (`-U`) support on `PATH`.

  A YouTube *playlist* URL (not a plain watch URL) added this way expands
  into its individual videos automatically, via `yt-dlp`.

## Configuration

See `script-opts/playlist_manager.conf` for the one option:
`resolve_url_titles` (default `yes`) - set to `no` to skip background
`yt-dlp` title fetches (faster, titles show as raw URLs instead).

## Interop with perpetual-playlist

This plugin operates purely on mpv's live in-memory playlist - it doesn't
persist anything to disk. If installed alongside
[perpetual-playlist](https://github.com/edieguez/perpetual-playlist), that
sibling plugin transparently saves/resumes whatever this plugin (or
anything else) puts into the playlist, across mpv restarts. Neither plugin
requires the other, but `mpv-add`'s fresh-instance fallback plays more
nicely with perpetual-playlist installed (cold-start items get spliced
into the resumed playlist instead of simply replacing it).

## License

MPL-2.0, see [LICENSE](LICENSE).
