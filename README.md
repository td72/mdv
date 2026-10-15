# mdv — markdown viewer (vi/vim)

A small, fast, native GitHub Flavored Markdown viewer for macOS with vim keybindings.

- **Native AppKit** — `NSTextView` + TextKit 1, no WebView, no Electron. Opens in well under a second, a 4,500-line document parses, renders and lays out in ~150 ms.
- **GFM** via [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm): tables, task lists, strikethrough, fenced code, block quotes, images, autolinks, front matter.
- **Vim keys** for navigation, plus normal trackpad / mouse-wheel scrolling.
- **Live reload** — the file is watched with kqueue; saves (including atomic saves) re-render while keeping the scroll position.
- Light / dark mode follows the system. Readable column width is capped and centered on wide windows.

## Install

Requires macOS 14+, Xcode Command Line Tools (Swift 5.9+) and [mise](https://mise.jdx.dev).

```sh
mise trust
mise r install        # builds build/mdv.app, copies it to ~/Applications, symlinks ~/.local/bin/mdv
```

Or just `mise r app` and drag `build/mdv.app` wherever you like. `swift build -c release` also works on its own: the bare binary at `.build/release/mdv` is a complete GUI app.

| Task | What |
|------|------|
| `mise r build` | release build |
| `mise r app` | assemble `build/mdv.app` |
| `mise r install` | install to `~/Applications` + `~/.local/bin/mdv` |
| `mise r run [file]` | build and open a file |
| `mise r snapshot [file] [-o out.png] [--dark] [--width 700]` | render to PNG (debug) |
| `mise r clean` | remove `.build` and `build` |

## Usage

```sh
mdv README.md               # open a file (several files → several windows / tabs)
cat notes.md | mdv          # read from stdin
open -a mdv README.md       # or double-click / drag a .md onto the Dock icon
```

Relative links to other `.md` files open in the same window. `http(s)` / `mailto` links open in the default
browser; links to other local files are revealed in Finder rather than launched, and other URL schemes are ignored.
Drop a file on the window to open it.

## Keys

| Key | Action |
|-----|--------|
| `j` / `k`, `Ctrl-e` / `Ctrl-y`, ↓ / ↑ | scroll down / up |
| `d` / `u`, `Ctrl-d` / `Ctrl-u` | half page down / up |
| `f` / `b`, `Ctrl-f` / `Ctrl-b`, `Space` / `Shift-Space`, PgDn / PgUp | page down / up |
| `gg` / `G`, Home / End | top / bottom |
| `50G` | go to 50% |
| `5j`, `3d`, … | counts work with every motion |
| `h` / `l`, `0` / `$` | horizontal scroll (when content is wider than the window) |
| `/` | find (incremental find bar); `Esc` returns to the document |
| `n` / `N` | next / previous match |
| `y` | copy the selection |
| `r` | reload |
| `o` | open file… |
| `+` / `-` / `=` | zoom in / out / reset (persisted) |
| `q` | close window (quits with the last one) |
| `Esc` | clear pending count / selection |

The usual macOS shortcuts (`⌘C`, `⌘A`, `⌘F`, `⌘W`, `⌘Q`, `⌘+`, `⌘-`, `⌘0`, `⌃⌘F`) are in the menu bar.

## Layout

| Path | What |
|------|------|
| `Sources/mdv/main.swift` | app delegate, menu bar, CLI parsing |
| `Sources/mdv/ViewerWindow.swift` | window, scroll view, load / reload, scrolling, find, zoom |
| `Sources/mdv/VimTextView.swift` | read-only text view with the vim key handling |
| `Sources/mdv/Renderer.swift` | swift-markdown AST → `NSAttributedString` (blocks are `NSTextTable` cells) |
| `Sources/mdv/Theme.swift` | fonts and dynamic colors |
| `Sources/mdv/FileWatcher.swift` | kqueue file watcher that survives atomic saves |

Debug helpers (environment variables, wrapped by `mise r snapshot`): `MDV_TIMING=1` prints parse / render / layout times and
scroll offsets to stderr, `MDV_SNAPSHOT=out.png` renders the whole document to a PNG and exits (`MDV_SNAPSHOT_WIDTH=700`,
`MDV_DARK=1` to vary).

## License

MIT
