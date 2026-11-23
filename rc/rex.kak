# rex.kak — Kakoune windowing module and picker bridge for Rex.
#
# - rex-terminal-{window,horizontal,vertical,sidebar,popup}: open programs in
#   Rex tabs, splits, and floating layers (the tmux.kak equivalents).
# - rex-pick <picker> [key=value...]: run a Rex picker action (kak_<picker>,
#   defined by this plugin's lua/kak.lua) against this client.
# - Records which Kakoune client lives in which Rex block, so pickers bound
#   with rex.bind in init.lua know where to send their result.
# - rex-enable-default-aliases: opt in to short names (vsp, sp, focus-*,
#   terminal-*) that point at the Rex commands.

declare-option -docstring 'how Rex pickers render: auto, palette (rex.ui), or fzf (kks-* popup)' \
  str rex_picker_ui auto

# Try rex first in Kakoune's windowing detection (rc/windowing/detection.kak).
set-option global windowing_modules rex %opt{windowing_modules}

provide-module rex %{

# Detection contract: only probe the environment when windowing_modules is
# non-empty. A tmux running inside Rex should get the tmux module instead.
evaluate-commands %sh{
  [ -z "${kak_opt_windowing_modules}" ] && exit 0
  [ -n "${kak_client_env_REX_SESSION:-$REX_SESSION}" ] || echo "fail 'rex: not inside a Rex terminal'"
  [ -z "${kak_client_env_TMUX:-$TMUX}" ] || echo "fail 'rex: inside tmux'"
}

# Runs the rex CLI with this client's Rex environment, in the background.
# REX_BIN_DIR is set by Rex in every terminal it starts. A failure is shown
# in the client's status line rather than lost.
define-command -hidden -params 1.. rex-cli %{
  nop %sh{
    bin="${kak_client_env_REX_BIN_DIR:-$REX_BIN_DIR}"
    rex="rex"
    [ -n "$bin" ] && [ -x "$bin/rex" ] && rex="$bin/rex"
    session="$kak_session" client="$kak_client"
    (
      if ! out=$(REX_SERVER="${kak_client_env_REX_SERVER:-$REX_SERVER}" \
                 REX_SESSION="${kak_client_env_REX_SESSION:-$REX_SESSION}" \
                 "$rex" "$@" < /dev/null 2>&1 > /dev/null); then
        # Braces would be read as markup faces; quote twice (echo, then -client).
        msg=$(printf '%s' "$out" | tr '\n{}' ' ()' | sed "s/'/''/g")
        inner=$(printf "echo -markup '{Error}rex: %s'" "$msg" | sed "s/'/''/g")
        printf "evaluate-commands -client '%s' '%s'\n" "$client" "$inner" | kak -p "$session"
      fi
    ) < /dev/null > /dev/null 2>&1 &
  }
}

define-command -hidden -params 1.. rex-terminal-impl %{
  evaluate-commands %sh{
    split="$1"; ratio="$2"; shift 2
    quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
    printf 'rex-cli run -s %s -c %s' "$(quote "$kak_client_env_REX_SESSION")" "$(quote "${kak_client_env_PWD:-$PWD}")"
    if [ "$split" != tab ]; then
      printf ' -b %s --split=%s --ratio %s' "$(quote "$kak_client_env_REX_BLOCK")" "$split" "$ratio"
    fi
    printf ' --'
    [ $# -eq 0 ] && set -- "${kak_client_env_SHELL:-${SHELL:-sh}}"
    for a do printf ' %s' "$(quote "$a")"; done
    printf '\n'
  }
}

define-command rex-terminal-window -params .. -docstring '
rex-terminal-window [<program> [<arguments>]]: open a new Rex tab' %{
  rex-terminal-impl tab 0 %arg{@}
}
complete-command rex-terminal-window shell

# Rex tabs are windows, so 'tab' and 'window' placements are the same.
define-command rex-terminal-tab -params .. -docstring '
rex-terminal-tab [<program> [<arguments>]]: open a new Rex tab' %{
  rex-terminal-impl tab 0 %arg{@}
}
complete-command rex-terminal-tab shell

define-command rex-terminal-horizontal -params .. -docstring '
rex-terminal-horizontal [<program> [<arguments>]]: split the Kakoune pane, new pane on the right' %{
  rex-terminal-impl right 50 %arg{@}
}
complete-command rex-terminal-horizontal shell

define-command rex-terminal-vertical -params .. -docstring '
rex-terminal-vertical [<program> [<arguments>]]: split the Kakoune pane, new pane below' %{
  rex-terminal-impl below 50 %arg{@}
}
complete-command rex-terminal-vertical shell

define-command rex-terminal-sidebar -params .. -docstring '
rex-terminal-sidebar [<program> [<arguments>]]: narrow pane (23%) on the left' %{
  rex-terminal-impl left 23 %arg{@}
}
complete-command rex-terminal-sidebar shell

define-command rex-terminal-popup -params .. -docstring '
rex-terminal-popup [<program> [<arguments>]]: run a program in a floating Rex layer.
Needs the kak_popup action from this plugin''s lua/kak.lua.' %{
  evaluate-commands %sh{
    quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
    shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
    cmd=""
    for a do cmd="$cmd $(shq "$a")"; done
    # Quote whole key=value words: Kakoune only honours a quote at word start.
    printf 'rex-cli do -s %s -b %s kak_popup %s %s %s %s %s\n' \
      "$(quote "$kak_client_env_REX_SESSION")" "$(quote "$kak_client_env_REX_BLOCK")" \
      "$(quote "session=$kak_session")" "$(quote "client=$kak_client")" \
      "$(quote "block=$kak_client_env_REX_BLOCK")" "$(quote "cwd=${kak_client_env_PWD:-$PWD}")" \
      "$(quote "command=${cmd# }")"
  }
}
complete-command rex-terminal-popup shell

define-command rex-pick -params 1.. -docstring '
rex-pick <picker> [<key>=<value>...]: run the Rex action kak_<picker> for this client.
Pickers: files git-files git-changed pr-diff-files buffers buffers-delete mru grep
grep-buffer lines md-heading diff-files symbols workspace-symbols filetypes files-nav clients' \
-shell-script-candidates %{
  printf '%s\n' files git-files git-changed pr-diff-files buffers buffers-delete mru grep \
    grep-buffer lines md-heading diff-files symbols workspace-symbols filetypes files-nav clients
} %{
  evaluate-commands %sh{
    quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
    name=$(printf '%s' "$1" | tr '-' '_'); shift
    # rex do waits for the answer, so give it longer than the default 10s.
    # Quote whole key=value words: Kakoune only honours a quote at word start.
    printf 'rex-cli --timeout 1h do -s %s -b %s %s %s %s %s %s %s' \
      "$(quote "$kak_client_env_REX_SESSION")" "$(quote "$kak_client_env_REX_BLOCK")" \
      "$(quote "kak_$name")" "$(quote "session=$kak_session")" "$(quote "client=$kak_client")" \
      "$(quote "block=$kak_client_env_REX_BLOCK")" "$(quote "cwd=${kak_client_env_PWD:-$PWD}")" \
      "$(quote "ui=$kak_opt_rex_picker_ui")"
    for a do printf ' %s' "$(quote "$a")"; done
    printf '\n'
  }
}

define-command rex-focus -params 1 -hidden -docstring 'rex-focus <left|right|up|down>' %{
  rex-cli focus -s %val{client_env_REX_SESSION} %arg{1}
}

define-command rex-focus-left  -docstring 'focus the Rex pane to the left'  %{ rex-focus left }
define-command rex-focus-right -docstring 'focus the Rex pane to the right' %{ rex-focus right }
define-command rex-focus-up    -docstring 'focus the Rex pane above'        %{ rex-focus up }
define-command rex-focus-down  -docstring 'focus the Rex pane below'        %{ rex-focus down }

# rex-focus-client [<client>]: bring a client's Rex pane to the front. When a
# picker opens a file in another client, a WinDisplay hook calling this (or
# the `focus` alias) moves Rex focus to that client.
define-command rex-focus-client -params ..1 -docstring '
rex-focus-client [<client>]: focus the Rex pane of a client (default: current)' \
-client-completion %{
  evaluate-commands %sh{
    if [ $# -eq 1 ] && [ "$1" != "$kak_client" ]; then
      printf "evaluate-commands -client '%s' rex-focus-client\n" "$(printf '%s' "$1" | sed "s/'/''/g")"
    else
      echo 'rex-cli focus -s %val{client_env_REX_SESSION} %val{client_env_REX_BLOCK}'
    fi
  }
}
define-command rex-vsp -docstring 'open another client of this session in a split on the right' %{
  rex-terminal-horizontal kak -c %val{session}
}
define-command rex-sp -docstring 'open another client of this session in a split below' %{
  rex-terminal-vertical kak -c %val{session}
}

define-command rex-enable-default-aliases -docstring '
Install short window-management aliases for the Rex commands.' %{
  alias global vsp rex-vsp
  alias global sp rex-sp
  alias global focus rex-focus-client
  alias global focus-left rex-focus-left
  alias global focus-right rex-focus-right
  alias global focus-up rex-focus-up
  alias global focus-down rex-focus-down
  alias global terminal-window rex-terminal-window
  alias global terminal-tab rex-terminal-tab
  alias global terminal-horizontal rex-terminal-horizontal
  alias global terminal-vertical rex-terminal-vertical
  alias global terminal-sidebar rex-terminal-sidebar
  alias global terminal-popup rex-terminal-popup
}

# block -> session, client, cwd, block. Read by kak.lua for key-bound pickers.
define-command -hidden rex-record-client %{
  nop %sh{
    block="$kak_client_env_REX_BLOCK"
    [ -n "$block" ] || exit 0
    dir="$HOME/.cache/rex-kak"
    mkdir -p "$dir"
    file="$dir/$(printf '%s' "$block" | tr -c 'A-Za-z0-9_-' '_')"
    # PATH lets Rex actions find tools (rg, cymbal…) exactly as this shell does;
    # TMPDIR is where this Kakoune server keeps its socket, for kak -p.
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$kak_session" "$kak_client" "${kak_client_env_PWD:-$PWD}" "$block" \
      "${kak_client_env_PATH:-$PATH}" "${TMPDIR:-}" > "$file"
  }
}

hook -group rex global ClientCreate .* rex-record-client
hook -group rex global FocusIn .* rex-record-client
hook -group rex global ClientRenamed .* rex-record-client

}
