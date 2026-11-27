# lvim-picker

The fuzzy finders of the **lvim-tech** set — a unified picker (files / grep / buffers / git / LSP locations /
diagnostics / marks / …) on the shared fuzzy engine (lvim-fuzzy-core). Every finder shares one look and one
set of keys, and docks as a centred float, a bottom dock, or the message-zone area.

> **Breaking:** the fzf-TUI backend is gone — every finder is the Lua list, which searches with fzf's query
> syntax on lvim-fuzzy-core (faster, see [Speed](#speed)). `fzf_tui`, `grep_multiline` and the keys
> `swap_backend`, `park`, `nav`, `abort`, `accept`, `preview_down` / `preview_up` are no longer read. For a
> finder in the terminal there is [lvim-fuzzy-cli](https://github.com/lvim-tech/lvim-fuzzy-cli).

## Requirements

Requires **Neovim >= 0.12.x**, [lvim-utils](https://github.com/lvim-tech/lvim-utils),
[lvim-ui](https://github.com/lvim-tech/lvim-ui) and [lvim-fuzzy](https://github.com/lvim-tech/lvim-fuzzy-nvim)
(the shared matching engine — lvim-fuzzy-core, the same as the terminal finder; its native library is
required). `fd` (or `rg` / `find`) lists files, `rg` greps. Optional:
[lvim-hud](https://github.com/lvim-tech/lvim-hud) (statusline title overlay) and
[lvim-msgarea](https://github.com/lvim-tech/lvim-msgarea) (the `area` dock in the message zone).

## Installation

### lvim-installer (recommended)

```vim
:LvimInstaller plugins
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-fuzzy-nvim" },
    { src = "https://github.com/lvim-tech/lvim-fuzzy-picker" },
})
require("lvim-picker").setup({})
```

### Helpers for pictures, archives and the lfz modes (optional)

The previews of pictures / PDFs / archives / tables and opening with the system's program come from the shared plugin host `lvim-plugin` and its
preview and open plugins; the lfz modes (git log, processes, docker, systemd, ssh, …) come from `lvim-fuzzy-cli`. Nothing has to be installed first
— **not the terminal programs, not other lvim checkouts**: `sh scripts/install.sh` fetches them from GitHub and builds them (git and cargo are
needed: https://rustup.rs). With lvim-pack: `build = "sh scripts/install.sh"`. They are found in `~/.local/bin` even when that is not in
Neovim's PATH; `:checkhealth lvim-picker` says what is there. Without them the native finders and text previews work as before.

## Usage

`setup()` registers `:LvimPicker <finder> [area|float|bottom]`; each finder is also a Lua function:

```vim
:LvimPicker files
:LvimPicker grep float
```

```lua
local pick = require("lvim-picker")
pick.files()
pick.grep()
pick.buffers()
pick.oldfiles()
pick.git_files()
pick.help_tags()
pick.marks()
pick.quickfix()
pick.directories()
pick.keymaps()
pick.commands()
pick.colorschemes()
```

### Keymap cheatsheet

Press **`<Esc>`** (off the query, onto the list) and then **`g?`** — or click the **`help` chip** on the
footer bar — for the keymap CHEATSHEET: every finder key, built from the live `keys` config below (rebind
one and the cheatsheet follows); the fixed keys of the list are listed with them. `q` / `<Esc>` /
`g?` close it. The key is normal-mode only on purpose: while you type, the query owns the keyboard.

## The query

The query is **fzf's extended syntax**, searched by lvim-fuzzy-core — the same engine as the terminal finder,
so a query ranks the same in both:

- a **space separates TERMS**: `conf ui` means "matches `conf` **and** matches `ui`", in any order; a trailing
  space changes nothing;
- `'exact` an exact substring, `^src` a prefix, `.lua$` a suffix, `!test` a negation, `lua | rs` either;
- **smart case**: lower case folds, an upper-case letter (in any script) is kept;
- Latin letters match their accented forms (`cafe` finds `café`).

Every occurrence of every term is highlighted.

This holds for both matching paths: the in-memory finders and the streamed (blob) ones. A **live grep** is a
different thing — there the query is handed to ripgrep, which has its own syntax.

## Grep

The grep holds **all** ripgrep matches in the native matcher — like fzf keeps them in its own process — so there is **no browse cap** and the counter
climbs to the **real total** as rg streams (e.g. `403127/403127`, never an under-reported `10000`). It has
two modes, toggled with `<C-g>` (config `keys.grep_filter`) exactly like fzf's `Regex ⇄ fuzzy` switch:

- **Grep mode** (default for `grep()` live grep) — the typed query **drives ripgrep**: each keystroke re-runs
  rg, matches stream in progressively, and the counter is the true rg match total (`N/N`, since rg *is* the
  search and nothing filters on top). The title reads `Grep`.
- **Filter mode** (`<C-g>`) — ripgrep is **frozen** at the current result set and the typed query now
  **fuzzy-filters** the loaded matches (no re-grep). The counter becomes `matched/loaded` and the matched
  number **shrinks** as you narrow. The title reads `Grep 󰅂 filter`.

The fixed-query greps (`grep_cword` / `grep_cWORD` / `grep_visual` / `grep_word` / `grep_curbuf`) grep **once**
for their word and open straight in filter mode, so you fuzzy-narrow their matches as you type.

**Filter scope.** In filter mode the typed query reads one part of each `path:line:col:text` result, cycled
with `<C-s>` (config `keys.grep_scope`; default `grep_scope = "line"`) and shown in the title
(`Grep 󰅂 Filter · line`) and as a footer chip:

- **line** — the line's text only: every row left holds the query on its own line, so the preview's focused
  line shows it;
- **path** — the file path only;
- **file** — the whole file: a row stays when its file contains every query term (exact, smart-case).

Memory stays bounded and the main thread ~0%-blocked at any scale: `grep_max` is the native STORE ceiling (a
broader query is still fully *counted*, its overflow bytes discarded — never buffered, no `E41: out of
memory`), and `grep_max_columns` caps each result line so a minified / cache / log file's megabyte-long line
can't blow the blob up. `<CR>` opens the focused match at its exact `line:col`.

## Dock stack

When **lvim-utils** provides the shared dock-stack manager, every opened finder KIND is an entry in the
dock stack — `files`, `grep`, `buffers` … each with the base identity `lvim-picker:<kind>`, so `:LvimPicker files`
and `:LvimPicker grep` are two distinct instances. Only one is visible per
layout at a time: opening a second finder there PARKS the first (its finder spec is remembered — it stays
restorable on the stack), and re-opening a live kind rebuilds it fresh in place (no duplicate).

The dock keys every entry by **(kind, layout)**, so the same finder can be docked in more than one layout at
once — `files` in the `float` stack **and** the `bottom` stack **and** the `area` stack are three independent
entries, each with its own surface (present in multiple stacks simultaneously). Re-opening the same `(kind, layout)`
re-shows that one entry (never a duplicate in that stack); opening the same kind in a different layout is a
separate entry there.

Closing a finder the ordinary way — confirming, cancelling, `q` / `<Esc>` / `:q`, or opening another finder
over it — **parks and remembers** it: focus returns to the editor and the layout collapses, but the entry
stays on the stack (still cyclable and listed in the menu), so you can bring it back later. Only `<Leader>x`
actually kills an entry.

The dock keys (from lvim-utils.dock) apply while a finder is focused:

- `<Leader>n` / `<Leader>p` — cycle the visible finder forward / back through the current layout's stack;
- `<Leader>x` — kill the visible finder and reveal the next one on the stack;
- `<Leader>m` — a menu of every live (parked or visible) dock consumer (finders, terminal, …) across all layouts.

Without the dock manager (an older lvim-utils) the picker falls back to the classic "one finder open at a
time" behaviour — opening a finder replaces the previous one in place.

### Per-call docking (programmatic callers)

`config.dock.dock_stack` / `config.dock.force` are the picker's OWN defaults for the direct `:LvimPicker`
finders. A plugin opening a finder **through** the picker (e.g. `lvim-lsp`, `lvim-qf-loc`) can override them
**per call** on the `opts` passed to `require("lvim-picker").open(opts)` (and the built-in `files` / `grep` /
… helpers):

- `opts.dock_stack` (boolean) — override `config.dock.dock_stack` for THIS open only. `true` = managed stack
  consumer, `false` = geometry-only standalone; `nil` = inherit the config. So a caller can dock its finder
  into the stack (or keep it standalone) regardless of the picker's own default.
- `opts.force` (`{ float = {…}, area = {…}, bottom = {…} }`) — per-call anchored geometry override, same shape
  as `config.dock.force`, deep-merged over the central geometry (and winning over `config.dock.force`) for
  THIS open. `opts.height` (explicit rows) still wins over a forced height. area/bottom stay full-width
  (width ignored).

```lua
require("lvim-picker").open({
    title = "References",
    items = locations,
    on_confirm = jump,
    dock_stack = true, -- dock this finder into the shared stack for this call
    force = { area = { height = 0.4 } }, -- and force its area height to 40%
})
```

## Speed

lvim-picker against fzf-lua, tv.nvim, snacks.picker, mini.pick and telescope — each as a whole plugin,
not just its matcher. Every plugin runs in its own headless Neovim with its **default settings** and
opens its picker on the same command (`cat <corpus>`, the way a files / grep picker runs one). **Load** is
from opening the picker to the whole list loaded; a **query** is typed as keys over the loaded list and
timed until that plugin's result for it is ready. Milliseconds, lower is better; AMD Ryzen 9 3900XT
(24 threads).

**files** — 1 000 000 paths under `$HOME`

| plugin | load | `hel` | `lvim` | `config` | `initlua` | mean |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **lvim-picker** | **249** | **20.9** | **14.2** | **9.8** | **10.7** | **13.9** |
| fzf-lua | 321 | 160.0 | 104.7 | 66.0 | 53.0 | 96.0 |
| tv.nvim | 329 | 303.6 | 323.2 | 162.5 | 202.1 | 247.9 |
| mini.pick | 2 871 | 612.7 | 422.0 | 238.7 | 250.9 | 381.1 |
| snacks.picker | 940 | 1 886 | 1 086 | 1 088 | 1 190 | 1 313 |
| telescope | 4 614 | 34 351 | 22 388 | 10 784 | 9 873 | 19 349 |

**grep** — 300 000 ripgrep lines

| plugin | load | `err` | `function` | `return` | mean |
| --- | ---: | ---: | ---: | ---: | ---: |
| **lvim-picker** | **110** | **16.8** | **13.3** | **17.1** | **15.7** |
| fzf-lua | 140 | 74.8 | 22.6 | 65.7 | 54.4 |
| mini.pick | 837 | 292.2 | 117.2 | 194.2 | 201.2 |
| tv.nvim | 289 | 402.4 | 184.5 | 323.0 | 303.3 |
| snacks.picker | 296 | 639.2 | 237.1 | 333.6 | 403.3 |
| telescope | 1 235 | 10 727 | 2 503 | 9 251 | 7 494 |

A query is 6.9× faster than fzf-lua on the paths and 3.5× on the grep lines, 18× / 19× than tv.nvim,
27× / 13× than mini.pick, 94× / 26× than snacks.picker and over 400× than telescope (its default
sorter).

- lvim-picker, fzf-lua, tv.nvim and telescope find the same matches; snacks and mini.pick find slightly
  fewer (stricter rules). television reads 299 994 of the 300 000 grep lines.
- The time is to the result being ready (headless, nothing is drawn). lvim-picker and fzf-lua build
  only the rows they can show; the others sort the whole result — that is their real work, not a
  shortcut of the test.
- tv.nvim has no "result ready" hook: its time is when television first shows the final count with its
  busy marker gone, so it carries one of its frames (it draws at up to 60 fps and checks its matcher
  50 times a second).
- One measurement per query; the noise is a few milliseconds.
- Versions: fzf-lua 82ddfe6 (fzf 0.75), tv.nvim 4b156a2 (television 0.15.9), snacks.nvim 882c996,
  mini.pick 406d413, telescope.nvim 1e1bab7.

Run it on your machine (needs `fd`, `rg`, `fzf`, `git`, `cargo`; clones the other plugins and builds
television into a cache dir):

```sh
bench/run.sh [SOURCE_TREE]
```

## Configuration

`setup()` merges your options into the live config in place (a nested `fuzzy` subtable merges into the fuzzy
engine's config); it is optional (the defaults below work as-is). The full default config:

```lua
require("lvim-picker").setup({
    -- Default layout for every finder: "area" (message zone) | "float" (centred) | "bottom" (dock).
    layout = "area",
    -- The finder's max visible rows (a secondary cap under the dock geometry height).
    -- nil = follow the ONE central authority (lvim-utils `dock.geometry.<layout>.height`), like every other
    -- panel; set a number only to cap THIS plugin's lists shorter than the dock allows.
    max_rows = nil,
    -- This plugin's OWN docking defaults, namespaced under `dock` (per-call opts.dock_stack / opts.force
    -- still override these for a single open).
    dock = {
        -- true = full dock-STACK consumer (managed: cyclable <Leader>n/p/x/m, :LvimDock, one-visible-per-layout);
        -- false = geometry-only (central size/backdrop, opens standalone, NOT in the stack). A per-call
        -- opts.dock_stack overrides this (see below).
        dock_stack = true,
        -- Per-layout ANCHORED geometry overrides, deep-merged per field OVER the global
        -- lvim-utils.config.dock.geometry.<layout>; empty {} = inherit unchanged. Each layout may carry:
        -- height, height_auto, backdrop = { enabled, mode, dim = { amount }, darken = { amount } }, auto_hide,
        -- keep_focus. float ALSO: width, width_auto. area/bottom are always full-width (width ignored). A
        -- per-call opts.force overrides this (see below).
        force = { float = {}, area = {}, bottom = {} },
    },
    -- debounce of the query match, in ms (0 = a fresh non-blocking match on every keystroke).
    debounce_ms = 0,
    -- (streamed finders) how often, in ms, the growing pool re-renders (live counter + rows) while streaming.
    stream_refresh_ms = 50,
    -- (streamed finders) main-thread time budget, in ms, of one paced stream-ingest slice; the queued listing
    -- drains in slices of this size with a yield to the event loop in between, so a huge tree loads smoothly.
    stream_slice_ms = 4,
    -- how many candidates to marshal into the native matcher per background slice.
    marshal_cap = 32768,
    -- (grep — live AND fixed-query) the NATIVE-BLOB STORE CEILING: the grep holds EVERY rg match in
    -- the native matcher (Variant B — like fzf keeps them in its own process), so there is NO browse cap and the
    -- counter climbs to the REAL total. Up to this many matches are STORED + browsable; a broader query is still
    -- fully COUNTED (the count keeps climbing) but the overflow bytes are DISCARDED in the read callback — never
    -- buffered → no OOM, ~0% main-thread block. A HIGH pathological-query safety ceiling, not a normal limit.
    grep_max = 500000,
    -- (grep) cap on each ripgrep result line's length (rg's `--max-columns` + `--max-columns-preview`, so
    -- an over-long line is truncated, not omitted). A broad search hits minified / cache / log files whose one
    -- line is MEGABYTES; without this even a few hundred k matches buffer gigabytes into the blob. 0 disables.
    grep_max_columns = 512,
    -- (in-memory previews: buffers / lsp / diagnostics / help / keymaps / editable) the preview follows the
    -- cursor at once; > 0 caps it to one update per this many ms while scrolling. The file and directory previews
    -- (files / grep / git_files / oldfiles / directories) are read ASYNC and follow every move regardless.
    preview_debounce_ms = 0,
    -- (file previews) recently previewed files kept in the async LRU cache (instant re-visits).
    preview_cache = 32,
    -- (file previews) hard cap on lines materialised per preview (bounds a deep match in a huge file).
    preview_max_lines = 2000,
    -- The keys you can rebind (a value is a single key or a list; "" / {} disables it). Fixed: <CR> open,
    -- j/k (list) or C-j/C-k (prompt) move, C-d/C-u preview, / or C-f back to typing, q/<Esc> close.
    -- Extra row actions: `{ key, name?, mode?, run(item, close) }`. `name` adds a footer hint. `mode`
    -- restricts the binding to ONE context — "n" = the LIST only, "i" = the PROMPT only, absent = both.
    -- A key that also EDITS the query (<BS>, a bare letter) must be declared `mode = "n"`, or it would be
    -- bound in insert too and steal the keystroke from typing.
    keys = {
        -- (NORMAL mode only — while you type, the query owns the keyboard) the keymap CHEATSHEET, built
        -- from this table; also a `help` chip on the finder's footer bar in normal mode.
        help = "g?",
        mark = "<Tab>", -- toggle the focused row's mark (multi-select)
        quickfix = "<C-q>", -- send marked (or focused) rows to the quickfix list, then close
        grep_filter = "<C-g>", -- (live grep) toggle GREP ⇄ FILTER mode: drive rg vs fuzzy-filter the loaded set
        grep_scope = "<C-s>", -- (grep, FILTER mode) cycle the filter scope: line → path → file
        -- open in a split of the window the finder came from: a NORMAL key (n, the list) and an INSERT key
        -- (i, while typing) per method.
        open_methods = {
            vsplit = { n = "v", i = "<C-v>" }, -- a vertical split
            hsplit = { n = "x", i = "<C-x>" }, -- a horizontal split
        },
    },
    -- Mark indicator drawn before a marked row (multi-select).
    marker = "󰅂",
    -- Show file/directory icons in the finder lists; false = plain text rows.
    show_icons = true,
    -- Which icon plugin supplies file glyphs: "auto" (lvim-icons → nvim-web-devicons → mini.icons) or one of
    -- "lvim" | "devicons" | "mini".
    icon_provider = "auto",
    -- lvim-icons colour mode for file icons ("theme" | "brand" | "theme_brand"); nil = the lvim-icons default.
    icon_color_mode = nil,
    -- Shared glyphs used by the source helpers.
    icons = { directory = "󰉋" },
    -- Glyph dividing footer button groups.
    footer_separator = "󰧞",
    -- Footer button list per mode (insert while typing · normal after <Esc>); groups of action ids.
    footer = {
        insert = {
            { "open", "vsplit", "hsplit" },
            { "move", "mark", "qf", "close", "preview", "buffer" },
        },
        normal = {
            { "open", "vsplit", "hsplit" },
            { "move", "mark", "qf", "close", "preview" },
            { "help" }, -- the cheatsheet chip (normal only — in insert the key would type into the query)
            { "sectors" },
        },
    },
    grep_scope = "line", -- what a grep FILTER reads: "line" (the text) | "path" | "file" (the whole file)
    -- where every finder's preview sits unless the finder passes its own: "right" | "left" | "dynamic" (a float
    -- above a docked list) | "hide". <C-n>/<C-p> move it and <C-e> hides it for the open finder.
    preview_side = "right",
    -- Finder-title alignment: "left" | "center" | "right" — the same in every layout (float/area/bottom).
    -- The title text itself stays dynamic per finder; a per-call `opts.title_pos` overrides this.
    title_pos = "center",
    -- Publish the finder title + counter + query to the statusline (via lvim-hud) for docked finders.
    statusline = true,
    -- How `files` / `directories` list entries + what they ignore.
    source = {
        engine = "auto", -- "auto" (fd → fdfind → rg → find) | "fd" | "fdfind" | "rg" | "find"
        exclude = { ".git", ".jj" }, -- dir/file names to exclude entirely
        hidden = true, -- include dotfiles
        follow = false, -- follow symlinks
        respect_gitignore = true, -- honour .gitignore/.ignore (false = list ignored too)
        file_types = { "f", "l" }, -- entry types the files finder lists (fd --type)
    },
    -- Prompt badge before the query (either of icon/label may be "").
    prompt = {
        icon = "󰅂",
        label = "",
        -- (live grep) the badge while <C-g> FILTER mode is on (rg frozen, the query fuzzy-filters the results)
        filter_icon = "󰈲",
        filter_label = "Filter",
        pad_left = 1,
        icon_gap = 1,
        pad_right = 1,
        input_gap = 1,
    },
    -- Input caret: hl group (its fg = the bar colour) + a guicursor shape.
    caret = { hl = "LvimUiPickerCursor", shape = "ver25" },
    -- Highlight groups for every element (all overridable).
    hl = {
        prompt = "LvimUiPickerPrompt",
        input = "LvimUiPickerInput",
        marker = "LvimUiPickerMarker",
        row_odd = "LvimUiMsgAreaRowOdd",
        row_even = "LvimUiMsgAreaRowEven",
        sel_odd = "LvimUiMsgAreaSelOdd",
        sel_even = "LvimUiMsgAreaSelEven",
        match = "LvimUiMsgAreaMatch",
        preview_match = "LvimUiMsgAreaMatch", -- every match of the pattern inside the PREVIEW
        preview_match_focus = "LvimUiPeekTitle", -- the one the focused result points at (line:col)
        list_title = "LvimUiPeekTitle",
        list_count = "LvimUiPeekCount",
        preview_file = "LvimUiPeekFile",
        preview_dir = "LvimUiPickerPreviewDir",
        bar = "LvimUiPeekFileBar",
    },
    -- Preview winbar (the file title bar on the preview panel).
    preview = {
        show_icon = true,
        dir_pad_left = 1,
        dir_pad_right = 1,
        -- mark every match of the live pattern in the preview; the one the focused result
        -- points at (its own line:col) is marked harder
        match = true,
    },
    -- Shown when there are no results (list body + preview winbar).
    -- A grep row is `path:lnum:col:text`; when the match sits past the list's right edge the row
    -- is SCROLLED so it comes into view (fzf-style), with this mark for what was dropped off the
    -- left. The locator is never cut. `false` disables it; `list_wrap = true` wins over both.
    list_clip = "…",
    empty_text = "[no matches]",
    -- The preview placeholder when nothing is focused.
    empty_preview = "Nothing to preview",
    -- Soft-wrap the list rows instead of truncating long matches.
    list_wrap = false,

    -- Result ordering + cap around the shared lvim-fuzzy engine (merged into lvim-picker.fuzzy.config).
    fuzzy = {
        sort = "score", -- ordering: "score" | a list of sort keys | a function
        max_results = 1000, -- cap on ranked results (lvim-fuzzy's own max_results also applies)
        -- FILENAME BIAS. Fuzzy matching runs against the WHOLE path, so
        -- `vgit.lua` also matches every `.lua` file under a `…-git/` dir (`git` from the dir, `.lua` from the
        -- extension). This biases toward the file NAME:
        --   "boost"  — (default) rows whose NAME matches rank above path-only matches (which still show below);
        --              a name match = the query matches the basename on its own; its highlight is drawn
        --              on the name, not a dir+extension scatter. (Contiguity still wins WITHIN a bucket.)
        --   "strict" — only name matches are kept; the directory path is a tiebreak only.
        --   "off"    — no bias: whole-path fuzzy (exact fzf parity).
        filename_match = "boost",
    },
})
```

## Icons

Every icon this plugin draws is a Nerd Font glyph. When [lvim-icons](https://github.com/lvim-tech/lvim-icons)
runs in `mode = "material"` and the terminal shows kitty unicode placeholders, the plugin's own UI glyphs are
drawn as images of those same glyphs, in their own colours and with their columns kept; in `nerd` and `mix`
they stay text. There is nothing to set here: the mode is lvim-icons' (`lvim-utils.icons.ui_text` does the
work).

## License

BSD-3-Clause.

## Previews of pictures and binary files

A picture, a video, a PDF, a font, a document or a sound is previewed as a table of facts about it (and the
picture itself under it where the terminal takes graphics: lvim-image places it); a binary file as a note, never
its bytes. The picker asks the same preview plugin lvim-fuzzy-commander and lvim-fuzzy-cli use (`lvim-fuzzy-cli preview
--plugin`, from the lvim-fuzzy-cli program, see "Preview plugins" below) — so all three agree. Without that program
the picker previews text as it always did.

## Opening a file in its program

Enter on a file that is not text — a picture, a PDF, a video … — starts the program the open plugin
(`lvim-fuzzy-plugin-open`) says, as lvim-fuzzy-commander and lvim-fuzzy-cli do (`lvim-fuzzy-cli open --resolve PATH`;
which program opens which type is the plugin's configuration — your own layer is `plugins = { ["lvim-fuzzy-plugin-open"] =
{ … } }` in `setup`; the default is `xdg-open`), and the finder stays open. A program that is not installed is said and
nothing is opened. Text and directories open in this
editor as before. Without the `lvim-fuzzy` program nothing changes.

## Preview plugins (`plugins`)

Which engine shows a file type — a directory, a table, an archive, a binary file, text through `bat` — is the
configuration of the preview plugins (`lvim-fuzzy-plugin-preview`), the same ones lvc and lfz use; the picker only draws the
answer as lines of its preview buffer (a plugin that says "Neovim" leaves the file to the picker's own buffer). It asks
through `lvim-fuzzy-cli preview --plugin`, so it needs the `lvim-fuzzy` program. The picker's own settings:

```lua
require("lvim-picker").setup({
    plugins = {
        ["lvim-fuzzy-plugin-preview"] = { types = { rust = { ext = { "rs" }, engine = "bat" } } },
    },
})
```

Without the program or the plugin a directory has no preview of its own.
