# playlist-manager

An mpv Lua plugin that adds a keyboard-driven playlist browser/editor
dialog, plus the logic for getting items *into* the playlist in the first
place: clipboard paste, IPC-driven adds from outside mpv (via the sibling
[mpv-remote](https://github.com/edieguez/mpv-remote) CLI's `add`
subcommand), and automatic YouTube-playlist-URL expansion.

## What it does

- **Playlist dialog** (`select-playlist` key binding). A custom overlay
  listing the live playlist with fuzzy search-as-you-type, reordering,
  deletion, and jump-to-item - arrow/vim navigation (`ctrl+j/k/h/l`),
  `ENTER` to jump, `RIGHT`/arrows/`ESC` to reorder or cancel,
  `ctrl+BS` to delete.
- **Adding items.** `ctrl+v` pastes a clipboard URL/path and appends it to
  the playlist. `mpv-remote add` (see [its README](https://github.com/edieguez/mpv-remote))
  does the same from outside mpv, over IPC, in three modes - bare (play
  now), `next` (insert after current), `last` (append to end) - this
  plugin is the sole handler of the `mpv-add-item`/`mpv-add-item-next`/
  `mpv-add-item-play` messages it sends. All funnel through the same core
  add logic: a plain YouTube watch URL is never accidentally expanded
  into its autoplay "up next" mix, and an actual YouTube *playlist* URL
  is expanded via `yt-dlp` into its individual videos. Duplicate items
  are rejected (with an "Already in playlist" toast for the clipboard/
  manual/`next`/`last` cases) - except for `mpv-remote add`'s bare "play
  now" mode, which instead relocates the existing entry to right after
  the current item (if it's ahead of it) and jumps playback to it,
  rather than silently doing nothing.
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
4. To add videos from outside mpv, install
   [mpv-remote](https://github.com/edieguez/mpv-remote) and see its
   README for setup (`input-ipc-server`, `PATH`) and usage
   (`mpv-remote add <url>`). This plugin is what actually handles the
   add - mpv-remote is just the external dispatcher that reaches it.

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
requires the other, but `mpv-remote add`'s fresh-instance fallback plays
more nicely with perpetual-playlist installed (cold-start items get
spliced into the resumed playlist instead of simply replacing it).

## License

MPL-2.0, see [LICENSE](LICENSE).
