# viw — vim-keyed viewer

A small, fast, native viewer for macOS with vim keybindings. It renders GitHub Flavored Markdown, shows source
files with syntax highlighting and CSV / TSV as a grid; xlsx and PDF are planned ([#4](https://github.com/td72/viw/issues/4)). It was called `mdv` until
v0.2; the old `~/.config/mdv/config.toml` is still read until you move it.

- **Native AppKit** — `NSTextView` + TextKit 1, no WebView, no Electron. Opens in well under a second, a 4,500-line document parses, renders and lays out in ~150 ms.
- **GFM** via [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm): tables, task lists, strikethrough, fenced code, block quotes, images, autolinks, front matter.
- **Syntax highlighting** in fenced code blocks with [tree-sitter](https://tree-sitter.github.io) grammars from
  [CodeEditLanguages](https://github.com/CodeEditApp/CodeEditLanguages) (JSON / JSONL, YAML, TOML, shell, Swift, Python, JS / TS, Go, Rust, C / C++, SQL, HTML, CSS, … 30+ languages), in GitHub's light / dark colors. Highlighting runs off the main thread, so opening stays instant.
- **Vim keys** for navigation, plus normal trackpad / mouse-wheel scrolling.
- **Live reload** — the file is watched with kqueue; saves (including atomic saves) re-render while keeping the scroll position.
- Light / dark mode follows the system. Typography follows GitHub's markdown CSS (San Francisco 16pt, SF Mono at 85%, 1.5 line height, 948pt column, centered), and fonts are configurable.

## Install

Requires macOS 14+, Xcode Command Line Tools (Swift 5.9+) and [mise](https://mise.jdx.dev).

```sh
mise trust
mise r install        # builds build/viw.app, copies it to ~/Applications, symlinks ~/.local/bin/viw
```

Or just `mise r app` and drag `build/viw.app` wherever you like. `swift build -c release` also works on its own: the bare binary at `.build/release/viw` is a complete GUI app.

| Task | What |
|------|------|
| `mise r build` | release build |
| `mise r app` | assemble `build/viw.app` |
| `mise r install` | install to `~/Applications` + `~/.local/bin/viw` |
| `mise r run [file]` | build and open a file |
| `mise r snapshot [file] [-o out.png] [--dark] [--width 700]` | render to PNG (debug) |
| `mise r clean` | remove `.build` and `build` |

## Usage

```sh
viw README.md               # open a file (several files → several tabs)
viw main.swift config.toml  # source files open as one highlighted code block
viw data.json log.jsonl     # JSON is pretty-printed (key order kept); JSON Lines → one box per record
viw export.csv data.tsv     # delimited text as a grid (RFC 4180 quoting, delimiter / encoding detected)
cat notes.md | viw          # read from stdin
open -a viw README.md       # or double-click / drag a .md onto the Dock icon
```

viw is single-instance: while one is running, another `viw file.md` hands the file over and exits, and the file
opens as a new tab in the existing window. Tabs are drawn by viw inside one window rather than with native
macOS window tabs, so tiling window managers (AeroSpace, yabai) see a single window; the tab bar appears once
there are two or more tabs. Click a tab to select it, middle-click to close it.

What a file is depends on its name: `.md` / `.markdown` / `.txt` and most extension-less files render as Markdown,
anything with a known source extension (or a name like `Dockerfile`) as a single highlighted code block, and unknown
extensions as plain monospace text. `.json` is re-indented (invalid JSON, or `.jsonc` with comments, is shown as
written); `.jsonl` / `.ndjson` shows each record in its own box, broken lines verbatim. Very large files are cut
off at 1 MB of displayed text with a notice, so a 100 MB dump still opens in a few seconds.

`.csv` / `.tsv` open as a table: the first row is the header, columns are sized from the data, and each column
gets a type inferred from its cells (integer, number, boolean, date or text, shown in the header and the detail
pane): numeric columns are right-aligned and sorting compares by type (numbers as numbers, dates by date, booleans
false < true, text case-insensitively) while the cell text stays exactly as written. Quoted fields (commas, `""`, line breaks inside) follow RFC 4180; the delimiter (`,` `\t` `;`) is
guessed from the first lines and the encoding is UTF-8 with a Shift_JIS fallback for CSVs that Excel writes.
100k rows × 20 columns parse in about 0.1 s; past 500k rows the rest is cut off with a notice. Relative links to other Markdown or source files open in the same tab. `http(s)` / `mailto` links open in the default
browser; links to other local files are revealed in Finder rather than launched, and other URL schemes are ignored.
Drop files on the window to open them in new tabs.

## Keys

| Key | Action |
|-----|--------|
| `j` / `k`, `Ctrl-e` / `Ctrl-y`, ↓ / ↑ | scroll down / up |
| `d` / `u`, `Ctrl-d` / `Ctrl-u` | half page down / up |
| `Ctrl-f` / `Ctrl-b`, `Space` / `Shift-Space`, PgDn / PgUp, `b` | page down / up |
| `gg` / `G`, Home / End | top / bottom |
| `50G` | go to 50% |
| `5j`, `3d`, … | counts work with every motion |
| `h` / `l`, `0` / `$` | horizontal scroll (when content is wider than the window) |
| `/` | find (incremental find bar); `Esc` returns to the document |
| `f` | filter rows (tables); in a text document the same as `/` |
| `n` / `N` | next / previous match |
| `y` | copy the selection |
| `r` | reload |
| `o` | open file… (in a new tab) |
| `gt` / `gT`, `Tab` / `Shift-Tab` | next / previous tab |
| `3gt` | go to tab 3 |
| `+` / `-` / `=` | zoom in / out / reset (persisted) |
| `q` | close tab (the window goes with the last one, and the app with the last window) |
| `Esc` | clear pending count / selection |

In a table, the same keys move a cell cursor: `j` / `k` rows, `h` / `l` columns (`0` / `$` first / last column),
`d` / `u` / `b` by (half) pages of rows, `gg` / `G` / `50G`, `/` opens an incremental search over all cells (Enter keeps the hit,
Esc goes back to where you were), `n` / `N` jump to the next / previous matching row. `f` opens a filter instead:
only rows with a cell containing the text stay (incrementally, row numbers unchanged, the footer counts the
matches); Enter keeps the filter while you navigate, search and copy, Esc shows all rows again. Click a column
header to sort by it (again for descending; by the column's type, empty cells last); `s` sorts by the cursor
column (again to flip), `s` in the detail pane sorts by the highlighted field, `S` restores the file order. Selecting a row opens a
detail pane on the right with every column in full, long and multi-line cells included; drag its divider to
resize it, `.` hides / shows it, `I` (or View › Detail Pane, `⌘⇧D`) moves it between the right side and the
bottom (remembered; `detail_pane = "bottom"` in the config sets the default). Enter or `i` moves the keyboard
into the pane (`⌃W W` / `⌃W L` work too; its title turns blue): there `j` / `k` / `gg` / `G` move a cursor over the
record's fields, `y` / `⌘C` copy the highlighted field's value, `h` / `l` go to the previous / next record,
`d` / `u` / `f` / `b` scroll the pane's text, and Esc returns to the grid. Esc in the grid deselects and closes
the pane. In the grid, `y` or `⌘C` copies the cell under the cursor and `Y` the whole row as tab-separated text; entering the
pane puts its field cursor on the grid's column, and leaving it brings the column back.

The usual macOS shortcuts (`⌘C`, `⌘A`, `⌘F`, `⌘W`, `⌘Q`, `⌘+`, `⌘-`, `⌘0`, `⌃⌘F`) are in the menu bar, plus `⌘T` (open a file
in a new tab), `⌘⇧]` / `⌘⇧[` (next / previous tab) and `⌘1`…`⌘8` / `⌘9` (nth / last tab). No shortcut uses the Option key, so
AeroSpace-style `⌥hjkl` bindings are untouched.

## Configuration

Optional, read from `~/.config/viw/config.toml` (`$XDG_CONFIG_HOME` is honored, `VIW_CONFIG=path` overrides).
Press `r` after editing it to apply. See [`examples/config.toml`](examples/config.toml).

```toml
font = "Hiragino Sans"        # body / heading font family (default: system font, San Francisco)
code_font = "JetBrains Mono"  # code font family (default: SF Mono)
size = 16                     # base font size in points; `=` resets zoom to this
code_scale = 0.85             # code size relative to body
max_width = 948               # readable column width in points
detail_pane = "right"         # default side for the CSV detail pane: "right" or "bottom" (`I` switches at runtime)
```

Only flat `key = value` lines are parsed (no TOML library is linked). Unknown fonts fall back to the defaults with a warning on stderr.

## Layout

| Path | What |
|------|------|
| `Sources/viw/main.swift` | app delegate, menu bar, CLI parsing |
| `Sources/viw/ViewerWindow.swift` | window, in-window tab bar, tab switching / closing |
| `Sources/viw/Document.swift` | `Source` / `FileKind`, the `DocumentView` protocol, and `DocumentController` (one tab: file, theme, watcher, vim commands) |
| `Sources/viw/TextDocumentView.swift` | `DocumentView` for text: rendering, async highlighting, link handling, scrolling, find, snapshot |
| `Sources/viw/TableDocumentView.swift` | `DocumentView` for delimited data: NSTableView grid, row cursor, search bar, TSV copy |
| `Sources/viw/CSV.swift` | RFC 4180 parser with delimiter and encoding detection |
| `Sources/viw/VimKeys.swift` | `ViewerCommands` and the vim key map shared by the text and table views |
| `Sources/viw/Toast.swift` | the short-lived "Copied …" pill |
| `Sources/viw/SingleInstance.swift` | CFMessagePort hand-off from a second `viw` process to the running one |
| `Sources/viw/VimTextView.swift` | read-only text view (centered column) that feeds keys to the vim key map |
| `Sources/viw/Renderer.swift` | swift-markdown AST → `NSAttributedString` (blocks are `NSTextTable` cells) |
| `Sources/viw/Highlighter.swift` | fence language → tree-sitter grammar, `highlights.scm` queries, capture spans |
| `Sources/viw/JSONPretty.swift` | order-preserving JSON re-indenter (JSONSerialization only validates) |
| `Sources/viw/Theme.swift` | fonts, sizes, dynamic colors and the syntax color palette |
| `Sources/viw/Config.swift` | `~/.config/viw/config.toml` reader |
| `Sources/viw/FileWatcher.swift` | kqueue file watcher that survives atomic saves |

Debug helpers (environment variables, wrapped by `mise r snapshot`): `VIW_TIMING=1` prints parse / render / layout /
highlight-query times and scroll offsets to stderr, `VIW_SNAPSHOT=out.png` renders the whole document to a PNG and exits (`VIW_SNAPSHOT_WIDTH=700`,
`VIW_DARK=1` to vary).

## License

MIT
