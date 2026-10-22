# mdv — markdown viewer (vi/vim)

A small, fast, native GitHub Flavored Markdown viewer for macOS with vim keybindings.

- **Native AppKit** — `NSTextView` + TextKit 1, no WebView, no Electron. Opens in well under a second, a 4,500-line document parses, renders and lays out in ~150 ms.
- **GFM** via [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm): tables, task lists, strikethrough, fenced code, block quotes, images, autolinks, front matter.
- **Vim keys** for navigation, plus normal trackpad / mouse-wheel scrolling.
- **Live reload** — the file is watched with kqueue; saves (including atomic saves) re-render while keeping the scroll position.
- Light / dark mode follows the system. Typography follows GitHub's markdown CSS (San Francisco 16pt, SF Mono at 85%, 1.5 line height, 948pt column, centered), and fonts are configurable.

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
mdv README.md               # open a file (several files → several tabs)
cat notes.md | mdv          # read from stdin
open -a mdv README.md       # or double-click / drag a .md onto the Dock icon
```

mdv is single-instance: while one is running, another `mdv file.md` hands the file over and exits, and the file
opens as a new tab in the existing window. Tabs are drawn by mdv inside one window rather than with native
macOS window tabs, so tiling window managers (AeroSpace, yabai) see a single window; the tab bar appears once
there are two or more tabs. Click a tab to select it, middle-click to close it.

Relative links to other `.md` files open in the same tab. `http(s)` / `mailto` links open in the default
browser; links to other local files are revealed in Finder rather than launched, and other URL schemes are ignored.
Drop files on the window to open them in new tabs.

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
| `o` | open file… (in a new tab) |
| `gt` / `gT`, `Tab` / `Shift-Tab` | next / previous tab |
| `3gt` | go to tab 3 |
| `+` / `-` / `=` | zoom in / out / reset (persisted) |
| `q` | close tab (the window goes with the last one, and the app with the last window) |
| `Esc` | clear pending count / selection |

The usual macOS shortcuts (`⌘C`, `⌘A`, `⌘F`, `⌘W`, `⌘Q`, `⌘+`, `⌘-`, `⌘0`, `⌃⌘F`) are in the menu bar, plus `⌘T` (open a file
in a new tab), `⌘⇧]` / `⌘⇧[` (next / previous tab) and `⌘1`…`⌘8` / `⌘9` (nth / last tab). No shortcut uses the Option key, so
AeroSpace-style `⌥hjkl` bindings are untouched.

## Configuration

Optional, read from `~/.config/mdv/config.toml` (`$XDG_CONFIG_HOME` is honored, `MDV_CONFIG=path` overrides).
Press `r` after editing it to apply. See [`examples/config.toml`](examples/config.toml).

```toml
font = "Hiragino Sans"        # body / heading font family (default: system font, San Francisco)
code_font = "JetBrains Mono"  # code font family (default: SF Mono)
size = 16                     # base font size in points; `=` resets zoom to this
code_scale = 0.85             # code size relative to body
max_width = 948               # readable column width in points
```

Only flat `key = value` lines are parsed (no TOML library is linked). Unknown fonts fall back to the defaults with a warning on stderr.

## Layout

| Path | What |
|------|------|
| `Sources/mdv/main.swift` | app delegate, menu bar, CLI parsing |
| `Sources/mdv/ViewerWindow.swift` | window, in-window tab bar, tab switching / closing |
| `Sources/mdv/Document.swift` | one tab: scroll view, load / reload, scrolling, find, zoom, link handling |
| `Sources/mdv/SingleInstance.swift` | CFMessagePort hand-off from a second `mdv` process to the running one |
| `Sources/mdv/VimTextView.swift` | read-only text view with the vim key handling |
| `Sources/mdv/Renderer.swift` | swift-markdown AST → `NSAttributedString` (blocks are `NSTextTable` cells) |
| `Sources/mdv/Theme.swift` | fonts, sizes and dynamic colors |
| `Sources/mdv/Config.swift` | `~/.config/mdv/config.toml` reader |
| `Sources/mdv/FileWatcher.swift` | kqueue file watcher that survives atomic saves |

Debug helpers (environment variables, wrapped by `mise r snapshot`): `MDV_TIMING=1` prints parse / render / layout times and
scroll offsets to stderr, `MDV_SNAPSHOT=out.png` renders the whole document to a PNG and exits (`MDV_SNAPSHOT_WIDTH=700`,
`MDV_DARK=1` to vary).

## License

MIT
