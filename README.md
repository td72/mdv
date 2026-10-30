<img src="Resources/icon-tile-1024.png" width="96" align="right" alt="">

# viw — vim-keyed viewer

A small, fast, native viewer for macOS with vim keybindings. It renders GitHub Flavored Markdown, shows source
files with syntax highlighting, CSV / TSV and Excel workbooks as a grid, PDFs and images. It was called `mdv` until
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
| `mise r icon` | build `build/viw.icns` from `Resources/icon-1024.png` (sips + iconutil) |
| `mise r app` | assemble `build/viw.app` |
| `mise r install` | install to `~/Applications` + `~/.local/bin/viw` |
| `mise r run [file]` | build and open a file |
| `mise r snapshot [file] [-o out.png] [--dark] [--width 700]` | render to PNG (debug) |
| `mise r clean` | remove `.build` and `build` |
| `mise r test` | run the logic tests (`swift test` with the toolchain's swift-testing plugin, so the Command Line Tools suffice) |

## Usage

```sh
viw README.md               # open a file (several files → several tabs)
viw main.swift config.toml  # source files open as one highlighted code block
viw data.json log.jsonl     # JSON is pretty-printed (key order kept); JSON Lines → one box per record
viw export.csv data.tsv     # delimited text as a grid (RFC 4180 quoting, delimiter / encoding detected)
viw book.xlsx               # Excel workbooks: the same grid, one sheet at a time (zip + XML read by viw itself)
viw paper.pdf photo.png     # PDF (PDFKit) and images, fitted to the window
viw clip.mp4 talk.m4a       # video and audio (AVKit): whatever macOS decodes plays, with vim keys for transport
cat notes.md | viw          # read from stdin
open -a viw README.md       # or double-click / drag a .md onto the Dock icon
```

To make viw the default app for its file types (Finder double-click, `open`), run `viw --set-default` once after
`mise r install`; it registers every extension viw declares (Markdown, text, source code, JSON, CSV / TSV, xlsx, PDF,
images, but not `.html`, which stays with the browser) and prints what each now opens with. `viw --set-default md csv`
limits it to those extensions. viw ships with
`LSHandlerRank = Alternate`, so installing alone never takes a type away from Preview or TextEdit.

A bare `viw` (or the Dock icon) opens an empty window: drop a file on it, press `o`, or run `viw FILE` and the file
lands there as a tab. Closing the last tab leaves the window empty rather than closing it; what `q` / ⌘W do on that
empty window is `close_empty` in the config: close the window (default), keep it, or quit viw.

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
100k rows × 20 columns parse in about 0.1 s; past 500k rows the rest is cut off with a notice.

`.xlsx` / `.xlsm` open in the same grid with a sheet bar underneath: click a sheet, or `]` / `[` (View › Next /
Previous Sheet, `⌘]` / `⌘[`) to switch; the window subtitle names the sheet. viw reads the OOXML parts itself
(no library): shared strings (rich-text runs joined, furigana `rPh` dropped), inline strings, booleans, errors and the
cached result of formulas. The formula itself shows under the value in the detail pane and in the cell's tooltip. A file
saved without cached values (openpyxl and other libraries write none) gets a small evaluator for the cells that need it:
references (`B3`, `$B$3`, `Sheet2!C4`, `'売上 2026'!C4`, shared formulas), `+ - * / ^ & %`, comparisons and parentheses,
with Excel's errors (`#DIV/0!`, `#REF!` for a circular reference, `#VALUE!`), and the common functions with ranges as
arguments: SUM, PRODUCT, AVERAGE, COUNT, COUNTA, COUNTBLANK, MIN, MAX, ABS, INT, SQRT, MOD, POWER, ROUND / ROUNDUP / ROUNDDOWN, IF,
IFERROR, AND, OR, NOT, LEN, UPPER, LOWER, TRIM, LEFT, RIGHT, MID, CONCAT / CONCATENATE, TEXT, VALUE, ISBLANK / ISNUMBER / ISTEXT /
ISERROR. A formula using anything else (VLOOKUP, defined names, whole-column ranges) stays empty with its formula in the pane. Number formats are applied in a simple form — dates and times
(1900 and 1904 systems, `[h]` elapsed), decimals, thousands grouping, percent; `General` shows up to 10 significant
digits and keeps integers exact; currency symbols and colors are not rendered — so the grid reads like Excel and the
column types still infer (`1,234` and `12.5%` count as numbers). Column widths come from the sheet's `<cols>` when the
author set them, merged cells show their top-left value, hidden sheets are listed (marked in the tooltip), chart
sheets are skipped. Sheets parse on demand with a byte-level XML scanner: 100k rows × 12 columns take about 1 s.

`.pdf` opens with PDFKit, continuous and fitted to the width: the usual keys scroll, `gg` / `G` / `50G` move through
the document, `/` finds (all hits highlighted, `n` / `N` step through them), `+` / `-` / `=` zoom, `r` / `R` rotate,
and a badge in the corner (and the window subtitle) shows the page. `p` (or View › PDF, `⌘⇧P`) switches to a page view, one page at a time:
`j` / `k` scroll the page and flip at its edges, `d` / `u` / `Ctrl-f` / `b` flip pages, `gg` / `G` / `50G` pick a page.
The choice is remembered; `pdf_mode = "page"` in the config makes it the default. `t` (View › PDF: Page Overview,
`⌘⇧T`) replaces the document with a grid of all pages: `h` / `j` / `k` / `l` / `gg` / `G` move the cursor, Enter or `i`
(or a double-click) opens that page, Esc or `t` goes back to where you were. Images (png, jpg, gif, heic, webp, tiff, …) are fitted to the width and
centered; `+` / `-` / `=` zoom, `r` / `R` rotate, `y` copies the image. Animated GIF / WebP / APNG / HEICS play frame by
frame (so rotation and zoom apply to every frame) with the frame number in the badge: Space pauses and resumes, `n` / `N`
step one frame; a hidden tab stops the timer.

`.mp4` / `.mov` / `.m4v` and `.m4a` / `.mp3` / `.wav` / `.aiff` / `.flac` open in an AVKit player: whatever macOS can decode
plays (H.264 / HEVC, AAC / MP3 / …); `.mkv` / `.webm` / `.avi` / `.ogg` are recognised but get a note saying another player is
needed. A file opens paused, like QuickTime Player; Space plays / pauses (at the end: from the top), `j` / `k` seek 5 s, `d` / `u` 30 s, `Ctrl-f` / `Ctrl-b` a minute,
`h` / `l` step a frame (pausing), `0` / `$` / `gg` / `G` / `50G` jump, `+` / `-` / `=` set the volume, `m` mutes, `r` / `R`
rotate the video, `y` copies the file. The badge and the subtitle show `time / length`; a hidden tab pauses. The mouse
gets the usual inline scrubber.

Relative links to other Markdown or source files open in the same tab. `http(s)` / `mailto` links open in the default
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
| `r` | reload (PDF / images: rotate clockwise; `R` counter-clockwise) |
| `o` | open file… (in a new tab) |
| `gt` / `gT`, `Tab` / `Shift-Tab` | next / previous tab |
| `3gt` | go to tab 3 |
| `]` / `[` | next / previous sheet (xlsx; `3]` three ahead) |
| `+` / `-` / `=` | zoom in / out / reset (persisted) |
| `q` | close the tab; the last one leaves an empty window, and `q` there closes the window (the app quits with its last window) |
| `Esc` | clear pending count / selection |
| `?` | key help for the current view as an overlay (Help › Keyboard Shortcuts, `⌘/`); `?` / `Esc` / `q` closes it |
| `Space`, `n` / `N` | animated images: pause / play, step a frame |
| `Space`, `j` / `k`, `d` / `u`, `h` / `l`, `m` | video / audio: play / pause, seek 5 s / 30 s, step a frame, mute (`+` / `-` volume) |

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
pdf_mode = "scroll"           # PDF: "scroll" (continuous) or "page" (one page at a time; `p` switches at runtime)
close_empty = "window"        # `q` / ⌘W on a window with no tabs: "window" (close it), "keep" (leave it open), "quit" (quit viw)
```

Only flat `key = value` lines are parsed (no TOML library is linked). Unknown fonts fall back to the defaults with a warning on stderr.

## Layout

| Path | What |
|------|------|
| `Sources/viw/main.swift` | app delegate, menu bar, CLI parsing |
| `Sources/viw/ViewerWindow.swift` | window, in-window tab bar, tab switching / closing |
| `Sources/viw/Document.swift` | `Source` / `FileKind`, the `DocumentView` protocol, and `DocumentController` (one tab: file, theme, watcher, vim commands) |
| `Sources/viw/TextDocumentView.swift` | `DocumentView` for text: rendering, async highlighting, link handling, scrolling, find, snapshot |
| `Sources/viw/TableDocumentView.swift` | `DocumentView` for tables (CSV / xlsx): NSTableView grid, row cursor, search bar, TSV copy, sheet bar |
| `Sources/viw/PDFDocumentView.swift` | `DocumentView` for PDFs: PDFKit, find, zoom, rotate |
| `Sources/viw/ImageDocumentView.swift` | `DocumentView` for images: fit / zoom / rotate, ImageIO frame playback for animated images |
| `Sources/viw/MediaDocumentView.swift` | `DocumentView` for video / audio: AVPlayerView with vim transport keys |
| `Sources/viw/CSV.swift` | RFC 4180 parser with delimiter and encoding detection |
| `Sources/viw/ZipArchive.swift` | dependency-free zip reader (central directory, stored / deflate via Compression, CRC-32) for xlsx |
| `Sources/viw/XLSX.swift` | `Workbook`: sheets / shared strings / styles from the OOXML parts, number-format spelling, byte-level XML scanner |
| `Sources/viw/VimKeys.swift` | `ViewerCommands` and the vim key map shared by the text and table views |
| `Sources/viw/KeyHelp.swift` | the key bindings as data (`?` overlay, Help menu, `viw -h`) and the overlay view |
| `Sources/viw/Toast.swift` | the short-lived "Copied …" pill |
| `Sources/viw/SingleInstance.swift` | CFMessagePort hand-off from a second `viw` process to the running one |
| `Sources/viw/VimTextView.swift` | read-only text view (centered column) that feeds keys to the vim key map |
| `Sources/viw/Renderer.swift` | swift-markdown AST → `NSAttributedString` (blocks are `NSTextTable` cells) |
| `Sources/viw/Highlighter.swift` | fence language → tree-sitter grammar, `highlights.scm` queries, capture spans |
| `Sources/viw/JSONPretty.swift` | order-preserving JSON re-indenter (JSONSerialization only validates) |
| `Sources/viw/Theme.swift` | fonts, sizes, dynamic colors and the syntax color palette |
| `Sources/viw/Config.swift` | `~/.config/viw/config.toml` reader |
| `Sources/viw/FileWatcher.swift` | kqueue file watcher that survives atomic saves |

Debug helpers: `viw --unzip archive.zip [entry]` lists an archive's entries or writes one to stdout; `viw --xlsx book.xlsx [N | name]`
lists a workbook's sheets or writes one as TSV (`--formulas` appends `{=…}` to cells that have a formula).
Environment variables (wrapped by `mise r snapshot`): `VIW_TIMING=1` prints parse / render / layout /
highlight-query times and scroll offsets to stderr, `VIW_SNAPSHOT=out.png` renders the whole document to a PNG and exits (`VIW_SNAPSHOT_WIDTH=700`,
`VIW_DARK=1` to vary).

## License

MIT
