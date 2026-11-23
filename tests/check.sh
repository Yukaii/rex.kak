#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

command -v kak >/dev/null 2>&1 || {
  printf 'kak is required\n' >&2
  exit 1
}

# Parse the script, load the module as the windowing detection would inside
# Rex, and install the aliases. Errors land in *debug*; dump it and fail.
out=$(REX_SESSION=check REX_BLOCK=check TMUX='' kak -n -ui dummy -e "
  try %{
    source \"%val{runtime}/rc/windowing/detection.kak\"
    source '$project_root/rc/rex.kak'
    require-module rex
    rex-enable-default-aliases
    evaluate-commands %sh{ [ \"\$kak_opt_rex_picker_ui\" = auto ] || echo fail bad-default }
  } catch %{
    echo -to-file /dev/stdout \"FAIL: %val{error}\"
  }
  quit!
" </dev/null 2>&1)

if [ -n "$out" ]; then
  printf '%s\n' "$out" >&2
  exit 1
fi
printf 'rc/rex.kak: ok\n'

lua_checker=$(command -v luac || command -v luac5.1 || true)
if [ -n "$lua_checker" ]; then
  "$lua_checker" -p "$project_root/lua/kak.lua"
  printf 'lua/kak.lua: ok\n'
else
  printf 'luac not found; skipping lua/kak.lua syntax check\n'
fi
