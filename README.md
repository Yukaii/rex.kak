# rex.kak

Kakoune integration for Rex: a windowing module for Rex
tabs, splits, and floating layers, plus fuzzy pickers that render in Rex's
command palette.

The plugin has two halves that ship together:

- `rc/rex.kak` — the Kakoune side. A `rex` windowing module with
  `rex-terminal-*` commands, `rex-pick`, and pane focus helpers.
- `lua/kak.lua` — the Rex side. Registers one Rex action per picker
  (`kak_files`, `kak_grep`, …) and the `kak_popup` action used by
  `rex-terminal-popup`.

## Features

- Open programs in a new Rex tab, a right or bottom split, a left sidebar, or
  a floating layer.
- Take part in Kakoune's windowing detection, so `terminal`, `new` and friends
  use Rex automatically inside a Rex terminal (and step aside inside tmux).
- Pickers for files, git files, changed files, PR diff files, buffers, recent
  files, grep, buffer lines, Markdown headings, file and workspace symbols
  (cymbal), filetypes, directory navigation, and clients.
- Every picker is a named Rex action: run it from Kakoune (`:rex-pick files`),
  bind it in Rex (`rex.bind("cmd+p", "kak_git_files")`), call it with
  `rex do`, or find it in the command palette under "Kakoune:".
- Falls back to `kks-*` fzf scripts in a floating layer when the palette UI is
  not available.
- Short aliases (`vsp`, `sp`, `focus-*`, `terminal-*`) are opt-in.

## Requirements

- Kakoune
- Rex, with the `rex` CLI (Rex sets `REX_BIN_DIR` in its terminals)
- Per picker: `git` (git and diff pickers), `rg` (grep),
  [`cymbal`](https://github.com/Yukaii/cymbal) (symbols)
- Optional: `fzf`, used to rank typed text the way the fzf pickers did
  (plain term matching otherwise)
- Optional, for the fzf fallback UI: [`kks`](https://github.com/Yukaii/kks)
  and `kks-*` scripts on `PATH` (`kks-files`, `kks-grep`, …)

## Install

### kak-bundle

```kak
bundle rex-kak 'https://github.com/Yukaii/rex.kak' %{
  hook global ModuleLoaded rex %{
    rex-enable-default-aliases   # optional
  }
}
```

The `rex` module is required by Kakoune's windowing detection, not by hand:
loading `rc/rex.kak` puts `rex` first in `windowing_modules`, and the module
only loads when the client runs in a Rex terminal outside tmux.

### Manual

Clone the repository into an autoload directory:

```sh
git clone https://github.com/Yukaii/rex.kak \
  "${XDG_CONFIG_HOME:-$HOME/.config}/kak/autoload/rex.kak"
```

### Rex side

Add the plugin's `lua/` directory to Rex's module path in
`~/.config/rex/init.lua` and load it:

```lua
local HOME = os.getenv("HOME")
package.path = HOME .. "/.config/kak/bundle/rex-kak/lua/?.lua;" .. package.path

local kak = require("kak")
kak.ui = "auto" -- "auto" (palette when available), "palette", or "fzf"

rex.bind("cmd+p", "kak_git_files")
rex.bind("shift+cmd+f", "kak_grep")
rex.bind("shift+cmd+f", "kak_grep", { all = true })
```

Use the path you cloned to when not installing with kak-bundle. Then run
`rex config reload`.

## Commands

| Command | Description |
| --- | --- |
| `rex-terminal-window [cmd...]` / `rex-terminal-tab` | Open a new Rex tab. |
| `rex-terminal-horizontal [cmd...]` | Split the Kakoune pane, new pane on the right. |
| `rex-terminal-vertical [cmd...]` | Split the Kakoune pane, new pane below. |
| `rex-terminal-sidebar [cmd...]` | Narrow (23%) pane on the left. |
| `rex-terminal-popup [cmd...]` | Run a program in a floating Rex layer. |
| `rex-pick <picker> [key=value...]` | Run the Rex action `kak_<picker>` for this client. |
| `rex-focus-{left,right,up,down}` | Focus an adjacent Rex pane. |
| `rex-focus-client [client]` | Focus the Rex pane of a client. |
| `rex-vsp` / `rex-sp` | Open another client of this session in a split. |
| `rex-enable-default-aliases` | Install the short aliases below. |

`rex-enable-default-aliases` installs `vsp`, `sp`, `focus`,
`focus-{left,right,up,down}`, `terminal-window`, `terminal-tab`,
`terminal-horizontal`, `terminal-vertical`, `terminal-sidebar` and
`terminal-popup`.

### Pickers

`files` `git-files` `git-changed` `pr-diff-files` `buffers` `buffers-delete`
`mru` `grep` `grep-buffer` `lines` `md-heading` `diff-files` `symbols`
`workspace-symbols` `filetypes` `files-nav` `clients`

Arguments: `grep all=true`, `files dir=<path>`, `files-nav dir=<path>`,
`pr-diff-files branch=<name>`, and `multiple=true` on the file pickers to tick
several entries. `ui=palette|fzf` forces a renderer for one call.

### Options

| Option | Default | Description |
| --- | --- | --- |
| `rex_picker_ui` | `auto` | How pickers render: `auto`, `palette`, or `fzf`. |

On the Rex side, `kak.ui`, `kak.state_dir`, `kak.popup_bounds` and
`kak.max_items` can be set after `require("kak")`.

## How it works

Key-bound pickers run inside Rex, which has to know which Kakoune session and
client live in the focused pane. On `ClientCreate`, `FocusIn` and
`ClientRenamed`, `rc/rex.kak` writes the client's session, name, cwd, Rex
block, `PATH` and `TMPDIR` to `~/.cache/rex-kak/<block>`; `lua/kak.lua` reads
that file and talks back to the client through `kak -p`.

The `mru` picker reads `~/.cache/kak-mru-<cwd with / replaced by ->`, newest
first, one absolute path per line. Record it with a hook such as:

```kak
hook global WinDisplay [^*].* %{ nop %sh{
  [ -n "$kak_client_env_PWD" ] || exit 0
  mru=~/.cache/kak-mru-$(printf '%s' "$kak_client_env_PWD" | sed 's|/|-|g')
  touch "$mru"
  { echo "$kak_buffile"; cat "$mru"; } | awk '!seen[$0]++' > "$mru.tmp" && mv "$mru.tmp" "$mru"
}}
```

When a picker opens a file in another client, call `rex-focus-client` (or the
`focus` alias) from a `WinDisplay` hook to move Rex focus along with it.

## Development

Parse and load the module in a clean Kakoune process, and syntax-check the Lua
module:

```sh
./tests/check.sh
```

## License

MIT
