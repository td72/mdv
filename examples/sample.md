---
title: mdv sample
tags: [markdown, viewer]
---

# mdv — markdown viewer (vi/vim)

A **fast**, _native_ GFM viewer for macOS. Press `?`… no, press `q` to quit. ~~Electron~~ Nope.

## Headings & inline

Text with **bold**, *italic*, ***both***, `inline code`, ~~strike~~, a [link](https://github.com/td72/mdv),
an autolink https://example.com and a <kbd>raw html</kbd> span.
Hard break at the end of this line  
continues here.

### Level 3
#### Level 4
##### Level 5
###### Level 6

## Lists

- Unordered item one
- Item two with a nested list
  - Nested **bold** child
  - Another child
    1. Deep ordered
    2. Deep ordered two
- Item three

1. First
2. Second
   continued paragraph inside the item.
3. Third

- [x] Task done
- [ ] Task pending
- [ ] Another pending task with `code`

## Block quote

> The quick brown fox jumps over the lazy dog.
> Multiple lines in **one** paragraph.
>
> Second paragraph in the quote.
> > Nested quote.

## Code

```swift
import AppKit

let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
window.title = "mdv"   // native, no WebView
```

    indented code block
    second line

## Table

| Key | Description | Default |
|:----|:------------|--------:|
| `j` / `k` | scroll one step | 2 lines |
| `d` / `u` | half page | — |
| `gg` / `G` | top / bottom | — |
| `/` | find (NSTextFinder) | — |

---

## Images

![missing local](./nope.png) and a remote one ![remote](https://example.com/x.png).

Final paragraph. The end.
