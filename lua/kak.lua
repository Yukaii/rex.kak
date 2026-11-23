-- kak.lua — Kakoune integration for Rex.
--
-- Every picker is a named Rex action (`kak_files`, `kak_grep`, …), so it can
-- be bound with rex.bind, run from the command palette, run with `rex do`, or
-- triggered from Kakoune through rex.kak (`:rex-pick files`).
--
-- Pickers render in Rex's command palette (rex.ui.pick) when the server
-- supports it, and otherwise fall back to the matching kks-* fzf script in a
-- floating layer. Pass ui=palette|fzf to force one, or set `kak.ui`.
--
-- Usage in init.lua (point package.path at this plugin's lua/ directory):
--   package.path = os.getenv("HOME") .. "/.config/kak/bundle/rex-kak/lua/?.lua;" .. package.path
--   local kak = require("kak")
--   kak.ui = "auto"                       -- "auto" | "palette" | "fzf"
--   rex.bind("cmd+p", "kak_git_files")

local M = {}

local HOME = os.getenv("HOME") or ""

M.ui = "auto"
M.state_dir = HOME .. "/.cache/rex-kak"
M.popup_bounds = { 0.05, 0.08, 0.9, 0.84 }
M.max_items = 2000 -- rex.ui.pick's limit

-- Rex's own PATH is the login PATH, but make the usual user bins win so the
-- server finds kak, kks, rg, cymbal… however it was started.
-- Tools resolve with the Kakoune client's PATH (recorded by rex.kak); these
-- come first only when no client PATH is known.
local EXTRA_PATH = table.concat({
  HOME .. "/.bin", HOME .. "/.local/bin", HOME .. "/.local/share/mise/shims",
  HOME .. "/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin",
}, ":")

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function kq(s) -- Kakoune single-quoted string
  return "'" .. (tostring(s):gsub("'", "''")) .. "'"
end

local function lines(s)
  local out = {}
  for l in (s or ""):gmatch("[^\n]+") do out[#out + 1] = l end
  return out
end

local function basename(p) return (p:match("([^/]+)/*$")) or p end
local function dirname(p) return (p:match("^(.*)/[^/]*$")) or "." end

local function abspath(cwd, p)
  if p:sub(1, 1) == "/" then return p end
  cwd = cwd or HOME
  p = p:gsub("^%./", "")
  if p == "" or p == "." then return cwd end
  return cwd .. "/" .. p
end

local function tildify(p)
  if p and HOME ~= "" and p:sub(1, #HOME) == HOME then return "~" .. p:sub(#HOME + 1) end
  return p
end

local function strip_ansi(s) return (s:gsub("\27%[[%d;]*m", "")) end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function as_list(v)
  if type(v) == "table" then return v end
  return { v }
end

local function merge(a, b)
  local t = {}
  for k, v in pairs(a or {}) do t[k] = v end
  for k, v in pairs(b or {}) do t[k] = v end
  return t
end

-- Parse Kakoune's `-quoting shell` output: 'a' 'b'\''c' …
local function parse_shell_words(s)
  local out, cur, intok, i, n = {}, {}, false, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "'" then
      local j = s:find("'", i + 1, true) or (n + 1)
      cur[#cur + 1] = s:sub(i + 1, j - 1)
      intok, i = true, j + 1
    elseif c == "\\" then
      cur[#cur + 1] = s:sub(i + 1, i + 1)
      intok, i = true, i + 2
    elseif c == " " or c == "\n" or c == "\t" then
      if intok then out[#out + 1] = table.concat(cur); cur = {}; intok = false end
      i = i + 1
    else
      cur[#cur + 1] = c
      intok, i = true, i + 1
    end
  end
  if intok then out[#out + 1] = table.concat(cur) end
  return out
end

---------------------------------------------------------------------------
-- Running commands
---------------------------------------------------------------------------

local function env_for(t)
  local client_path = t and t.path ~= "" and t.path or nil
  return {
    PATH = client_path and (client_path .. ":" .. EXTRA_PATH)
      or (EXTRA_PATH .. ":" .. (os.getenv("PATH") or "/usr/bin:/bin")),
    TMPDIR = t and t.tmpdir or nil, -- where kak -p finds the session socket
    KKS_SESSION = t and t.session or nil,
    KKS_CLIENT = t and t.client or nil,
  }
end

-- Run argv and return the result; raise unless it succeeded or allow_fail.
function M.run(t, argv, opts)
  opts = opts or {}
  local r, err = rex.exec(argv, {
    cwd = opts.cwd or (t and t.cwd) or HOME,
    env = env_for(t),
    stdin = opts.stdin,
    timeout = opts.timeout or 20,
  })
  if r == nil then error(argv[1] .. ": " .. tostring(err), 0) end
  if not r.ok and not opts.allow_fail then
    local msg = trim(r.stderr ~= "" and r.stderr or ("exit " .. tostring(r.code)))
    error(argv[1] .. ": " .. msg, 0)
  end
  return r
end

---------------------------------------------------------------------------
-- Talking to Kakoune
---------------------------------------------------------------------------

-- Evaluate `cmd` in the target client.
function M.send(t, cmd)
  M.run(t, { "kak", "-p", t.session }, {
    stdin = "evaluate-commands -client " .. kq(t.client) .. " " .. kq(cmd),
  })
end

-- `body` is Kakoune code that writes shell-quoted words to @FIFO@. A failure
-- in the client is written to the FIFO too, so `cat` never blocks forever.
local QUERY_SH = [[
d=$(mktemp -d "${TMPDIR:-/tmp}/rex-kak.XXXXXX") || exit 1
trap 'rm -rf "$d"' EXIT
mkfifo "$d/f" || exit 1
body=${3//@FIFO@/$d/f}
printf "try %%{ evaluate-commands -client %s %%{ %s } } catch %%{ echo -to-file '%s' -quoting shell -- @@rexerr@@ %%val{error} }" \
  "$2" "$body" "$d/f" | kak -p "$1" || exit 1
cat "$d/f"
]]

local SEP = "@@rexsep@@"

local function query(t, body)
  local r = M.run(t, { "bash", "-c", QUERY_SH, "rex-kak", t.session, t.client, body }, { timeout = 5 })
  local words = parse_shell_words(r.stdout)
  if words[1] == "@@rexerr@@" then
    error("kakoune: " .. (words[2] or "unknown error"), 0)
  end
  return words
end

-- M.get(t, "%val{bufname}", "%val{buflist}") -> { {"a"}, {"b", "c"} }
function M.get(t, ...)
  local exprs = { ... }
  local words = query(t, "echo -to-file @FIFO@ -quoting shell -- " .. table.concat(exprs, " " .. SEP .. " "))
  local res, cur = {}, {}
  for _, w in ipairs(words) do
    if w == SEP then res[#res + 1] = cur; cur = {} else cur[#cur + 1] = w end
  end
  res[#res + 1] = cur
  return res
end

-- First word of a single expansion.
function M.val(t, expr) return (M.get(t, expr)[1] or {})[1] end

-- Whole content of the client's current buffer.
function M.buffer_text(t)
  local words = query(t,
    "evaluate-commands -draft %{ execute-keys '%'; echo -to-file @FIFO@ -quoting shell -- %val{selection} }")
  return words[1] or ""
end

function M.edit(t, path, line, col)
  local cmd = "edit -existing " .. kq(abspath(t.cwd, path))
  if line then cmd = cmd .. " " .. tostring(line) end
  if line and col then cmd = cmd .. " " .. tostring(col) end
  -- -existing fails for new paths; plain edit is fine as a fallback.
  M.send(t, "try %{ " .. cmd .. " } catch %{ " .. cmd:gsub("edit %-existing", "edit") .. " }")
end

-- Open "file:line:col:text" rows in a *qf-<query>* grep buffer, where <ret>
-- jumps to a row (the kks-pipe-to-grep-buffer / fzf ctrl-l equivalent).
-- Paths should be absolute: Kakoune's cwd need not be the picker's.
function M.send_to_list(t, query, rows)
  if #rows == 0 then error("no matches to send", 0) end
  local slug = (query or ""):gsub("[^%w_%-]", "_"):sub(1, 32)
  local name = "*qf-" .. (slug ~= "" and slug or tostring(os.time())) .. "*"
  local tmp = (t.tmpdir or os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
  local path = string.format("%s/rex-kak-qf-%d-%d", tmp, os.time(), math.random(1, 1e9))
  local f, err = io.open(path, "w")
  if not f then error("send to list: " .. tostring(err), 0) end
  f:write(table.concat(rows, "\n"), "\n")
  f:close()
  M.send(t, "edit! -scratch " .. kq(name)
    .. "; execute-keys " .. kq("%|cat " .. path .. "<ret>gg")
    .. "; set-option buffer filetype grep"
    .. "; nop %sh{ rm -f " .. path .. " }")
end

function M.goto_line(t, line, col)
  local keys = "<esc>" .. tostring(line) .. "g"
  if col and tonumber(col) and tonumber(col) > 1 then keys = keys .. tostring(col - 1) .. "l" end
  M.send(t, "execute-keys " .. kq(keys))
end

---------------------------------------------------------------------------
-- Which Kakoune client an action talks to
---------------------------------------------------------------------------

local function state_file(block_id)
  return M.state_dir .. "/" .. (block_id:gsub("[^%w_%-]", "_"))
end

local function read_state(block_id)
  local f = io.open(state_file(block_id), "r")
  if not f then return nil end
  local session, client, cwd, _, path, tmpdir = f:read("*l"), f:read("*l"), f:read("*l"), f:read("*l"), f:read("*l"), f:read("*l")
  f:close()
  if session and session ~= "" and client and client ~= "" then
    return { session = session, client = client, cwd = cwd ~= "" and cwd or nil, block = block_id,
             path = path, tmpdir = tmpdir ~= "" and tmpdir or nil }
  end
end

-- From explicit args (Kakoune side passes them), else from the focused block
-- (a key binding or the palette), using the state file rex.kak records.
function M.target(ctx, args)
  local t
  if args.session and args.client then
    t = { session = args.session, client = args.client, cwd = args.cwd, block = args.block or ctx.block_id }
    local s = t.block and read_state(t.block)
    if s and s.session == t.session and s.client == t.client then t.path, t.tmpdir = s.path, s.tmpdir end
  elseif args.block or ctx.block_id then
    t = read_state(args.block or ctx.block_id)
  end
  if not t then
    error("no Kakoune client in the focused pane (load rex.kak, or pass session= and client=)", 0)
  end
  t.cwd = t.cwd or HOME
  return t
end

---------------------------------------------------------------------------
-- UI: palette picker with narrowing, or a floating fzf popup
---------------------------------------------------------------------------

function M.has_palette()
  return rex.ui ~= nil and rex.ui.pick ~= nil
end

-- Every whitespace-separated term must appear, case-insensitively.
local function narrow(items, q)
  local terms = {}
  for w in q:lower():gmatch("%S+") do terms[#terms + 1] = w end
  local out = {}
  for _, it in ipairs(items) do
    -- A raw string (see spec.to_item) is matched as is. For tables, the id
    -- too: for files it's the full path, so "kak/kakrc" matches.
    local hay = type(it) == "string" and it:lower()
      or (it.id .. " " .. (it.title or "") .. " " .. (it.subtitle or "")):lower()
    local ok = true
    for _, w in ipairs(terms) do
      if not hay:find(w, 1, true) then ok = false; break end
    end
    if ok then out[#out + 1] = it end
  end
  return out
end

-- rex.ui.pick that copes with more than max_items: the palette shows the
-- first slice and accepts typed text, which narrows the full list and asks
-- again. Returns an id, a list of ids (multiple), { text = … } (allow_other),
-- or nil and a reason.
--
-- For big lists, pass plain strings as `items` and `to_item(s)` to turn one
-- into an item table: only the rows actually shown get built, which keeps a
-- 70k-file listing from costing seconds of Lua.
function M.pick(spec)
  local all, filter = spec.items, nil
  while true do
    local items = filter and narrow(all, filter) or all
    local overflow = #items > M.max_items
    local count = overflow and M.max_items or #items
    local shown, title = {}, spec.title
    for i = 1, count do
      shown[i] = spec.to_item and spec.to_item(items[i]) or items[i]
    end
    if overflow then
      title = string.format("%s — %d of %d, type to narrow", spec.title, M.max_items, #items)
    end
    local multiple = spec.multiple and not overflow
    local res, why, detail = rex.ui.pick{
      title = title,
      placeholder = spec.placeholder,
      value = filter or spec.value,
      -- With allow_other, confirm labels the typed-text row.
      confirm = overflow and "Narrow to typed text" or spec.confirm,
      items = shown,
      multiple = multiple or nil,
      allow_other = (not multiple and (overflow or spec.allow_other)) or nil,
      timeout = spec.timeout,
    }
    if res == nil then
      if why ~= "cancelled" then rex.log("warn", "kak picker: " .. tostring(why) .. " " .. (detail or "")) end
      return nil, why
    end
    if type(res) == "table" and res.text ~= nil then
      if not overflow then return res end
      filter = res.text
    else
      if spec.multiple then res = as_list(res) end
      return res
    end
  end
end

-- Strings in `list` matching `q`, best first, the way fzf would rank them
-- (what the fzf pickers' ctrl-l sent). Plain term matching without fzf.
function M.filter(t, list, q)
  local r = rex.exec({ "fzf", "--filter", q }, { stdin = table.concat(list, "\n"), env = env_for(t), timeout = 20 })
  if r and (r.code == 0 or r.code == 1) then return lines(r.stdout) end
  return narrow(list, q)
end

function M.input(spec)
  local res, why, detail = rex.ui.input(spec)
  if res == nil and why ~= "cancelled" then
    rex.log("warn", "kak input: " .. tostring(why) .. " " .. (detail or ""))
  end
  return res, why
end

-- Run argv in a floating layer over the Kakoune client's window. The layer
-- closes itself when argv exits.
function M.popup(t, argv, opts)
  opts = opts or {}
  local window_id
  if t.block then
    local d = rex.session.describe_block{ block_id = t.block }
    window_id = d and d.block and d.block.window_id
  end
  -- The layer inherits the server's environment, whose PATH may lack ~/.bin.
  local command = { "env", "PATH=" .. env_for(t).PATH, "EDITOR=kks edit" }
  if t.session then command[#command + 1] = "KKS_SESSION=" .. t.session end
  if t.client then command[#command + 1] = "KKS_CLIENT=" .. t.client end
  for _, a in ipairs(argv) do command[#command + 1] = a end
  local r, err = rex.session.new_layer{
    window_id = window_id,
    bounds = opts.bounds or M.popup_bounds,
    focus = true,
    layout = rex.layout.block{
      flavor = "com.superlogical.terminal.shell",
      options = { command = command, cwd = opts.cwd or t.cwd },
    },
  }
  if r == nil then error(err, 0) end
  return { layer_id = r.layer_id, block_id = r.block_ids and r.block_ids[1] }
end

---------------------------------------------------------------------------
-- Picker registry
---------------------------------------------------------------------------

local COMMON_ARGS = {
  session = "string?", client = "string?", cwd = "string?", block = "string?", ui = "string?",
}

M.pickers = {}

-- def fields:
--   name, title, description, keywords, args
--   items(t, args)          -> spec for M.pick (title, items, multiple, …)
--   accept(t, args, result) -> act on the chosen id(s)
--   native(t, args)         -> full override instead of items/accept
--   fallback(t, args)       -> argv for the fzf popup (kks-* script)
function M.picker(def)
  M.pickers[def.name] = def
  rex.action{
    name = "kak_" .. def.name,
    title = "Kakoune: " .. def.title,
    description = def.description,
    category = "Kakoune",
    keywords = "kak kakoune kks picker " .. (def.keywords or ""),
    args = merge(COMMON_ARGS, def.args),
    run = function(ctx, args)
      local t = M.target(ctx, args)
      local mode = args.ui or M.ui
      local palette = mode == "palette" or (mode == "auto" and M.has_palette())

      if not palette then
        if not def.fallback then error("kak_" .. def.name .. " needs the Rex palette (rex.ui)", 0) end
        return M.popup(t, def.fallback(t, args))
      end
      if not M.has_palette() then
        error("this Rex server has no rex.ui yet (needs control API 17); use ui=fzf", 0)
      end

      if def.native then return def.native(t, args) end
      local spec = def.items(t, args)
      if not spec then return end
      local res, why = M.pick(spec)
      if res == nil then
        -- An app too old to show prompts: fall back rather than do nothing.
        if why == "unsupported" and def.fallback then return M.popup(t, def.fallback(t, args)) end
        return
      end
      return def.accept(t, args, res, spec)
    end,
  }
end

---------------------------------------------------------------------------
-- Item builders
---------------------------------------------------------------------------

-- A path as a palette row. Used as spec.to_item, so it only runs for the
-- rows on screen.
local function file_item(p)
  local dir = dirname(p)
  return { id = p, title = basename(p), subtitle = dir ~= "." and dir or nil, icon = "document" }
end

local function sorted(list) table.sort(list); return list end

-- File pickers open on Return. multiple=true switches to ticking several
-- (Return ticks, Cmd+Return opens), since the palette can't do both.
local FILE_ARGS = { multiple = "boolean?" }

local function git_root(t)
  local r = M.run(t, { "git", "rev-parse", "--show-toplevel" }, { allow_fail = true })
  if not r.ok then error("not a git repository: " .. tildify(t.cwd), 0) end
  return trim(r.stdout)
end

local function open_all(root)
  return function(t, _, res)
    for _, p in ipairs(as_list(res)) do M.edit(t, abspath(root and root(t) or t.cwd, p)) end
  end
end

-- Accept for path pickers: an item opens; typed text (the "Send matches to
-- list" row) sends every path matching it, not just the shown ones, to a
-- *qf-…* buffer. spec.base is the directory the paths are relative to.
local function open_or_list(t, _, res, spec)
  if type(res) == "table" and res.text then
    local rows = {}
    for _, p in ipairs(M.filter(t, spec.items, res.text)) do rows[#rows + 1] = abspath(spec.base, p) .. ":1:1:" end
    return M.send_to_list(t, res.text, rows)
  end
  for _, p in ipairs(as_list(res)) do M.edit(t, abspath(spec.base, p)) end
end

-- Path picker fields shared by files and git_files.
local function path_spec(args, base, title, paths)
  return {
    title = title, placeholder = "Filter files in " .. tildify(base) .. ", or send matches to a list",
    confirm = args.multiple and "Open" or "Send matches to list",
    multiple = args.multiple, allow_other = true,
    items = sorted(paths), to_item = file_item, base = base,
  }
end

local function selection_query(t)
  local v = M.get(t, "%val{selection_length}", "%val{selection}")
  local len = tonumber((v[1] or {})[1] or "0") or 0
  local sel = (v[2] or {})[1]
  if len > 1 and sel and not sel:find("\n", 1, true) then return sel end
end

---------------------------------------------------------------------------
-- Pickers
---------------------------------------------------------------------------

M.picker{
  name = "files", title = "Files (all)", keywords = "open find",
  description = "Every file under the working directory, ignored files included.",
  args = { dir = "string?", multiple = "boolean?" },
  items = function(t, args)
    local dir = args.dir or t.cwd
    local r = M.run(t, { "rg", "--files", "--hidden", "--no-ignore", "--glob", "!.git" }, { cwd = dir, allow_fail = true })
    return path_spec(args, dir, "Files", lines(r.stdout))
  end,
  accept = open_or_list,
  fallback = function(_, args) return { "kks-files", args.dir } end,
}

M.picker{
  name = "git_files", title = "Git Files", keywords = "open find tracked",
  description = "Tracked and untracked, non-ignored files of the repository.",
  args = FILE_ARGS,
  items = function(t, args)
    local root = git_root(t)
    local r = M.run(t, { "git", "ls-files", "--cached", "--others", "--exclude-standard", "--full-name" }, { cwd = root })
    return path_spec(args, root, "Git Files", lines(r.stdout))
  end,
  accept = open_or_list,
  fallback = function() return { "kks-git-files" } end,
}

M.picker{
  name = "git_changed", title = "Git Changed Files", keywords = "status modified",
  description = "Files with uncommitted changes, untracked files included.",
  args = FILE_ARGS,
  items = function(t, args)
    local root = git_root(t)
    local r = M.run(t, { "git", "status", "--porcelain=v1", "--untracked-files=all" }, { cwd = root })
    local items = {}
    for _, l in ipairs(lines(r.stdout)) do
      local xy, path = l:sub(1, 2), l:sub(4)
      path = path:match(" %-> (.+)$") or path
      path = path:gsub('^"(.*)"$', "%1")
      local dir = dirname(path)
      items[#items + 1] = {
        id = path, title = basename(path), subtitle = dir ~= "." and dir or nil,
        icon = "document", detail = trim(xy),
      }
    end
    return { title = "Git Changes", placeholder = "Filter changed files", confirm = "Open", multiple = args.multiple, items = items }
  end,
  accept = open_all(git_root),
  fallback = function() return { "kks-git-changed-files" } end,
}

M.picker{
  name = "pr_diff_files", title = "Branch Changed Files", keywords = "pr review merge-base",
  description = "Files changed since the merge base with the default (or given) branch.",
  args = { branch = "string?", multiple = "boolean?" },
  items = function(t, args)
    local root = git_root(t)
    local branch = args.branch
    if not branch then
      local r = M.run(t, { "git", "symbolic-ref", "refs/remotes/origin/HEAD" }, { cwd = root, allow_fail = true })
      branch = r.ok and trim(r.stdout):gsub("^refs/remotes/origin/", "") or "main"
    end
    local base = trim(M.run(t, { "git", "merge-base", "HEAD", branch }, { cwd = root }).stdout)
    local r = M.run(t, { "git", "diff", "--name-status", base, "HEAD" }, { cwd = root })
    local items = {}
    for _, l in ipairs(lines(r.stdout)) do
      local status, path = l:match("^(%S+)%s+(.-)$")
      if path then
        path = path:match("\t(.+)$") or path -- renames: old<TAB>new
        local dir = dirname(path)
        items[#items + 1] = {
          id = path, title = basename(path), subtitle = dir ~= "." and dir or nil,
          icon = "document", detail = status,
        }
      end
    end
    return {
      title = "Changed since " .. branch, placeholder = "Filter files", confirm = "Open",
      multiple = args.multiple, items = items,
    }
  end,
  accept = open_all(git_root),
  fallback = function(_, args) return { "kks-pr-diff-files", args.branch } end,
}

M.picker{
  name = "buffers", title = "Buffers", keywords = "switch",
  items = function(t)
    local v = M.get(t, "%val{bufname}", "%val{buflist}")
    local current = (v[1] or {})[1]
    local items = {}
    for _, b in ipairs(v[2] or {}) do
      local scratch = b:sub(1, 1) == "*"
      items[#items + 1] = {
        id = b, title = basename(b), subtitle = (not scratch and dirname(b) ~= ".") and dirname(b) or nil,
        icon = scratch and "terminal" or "document", detail = b == current and "current" or nil,
      }
    end
    return { title = "Buffers", placeholder = "Switch to buffer", confirm = "Switch", items = items }
  end,
  accept = function(t, _, res) M.send(t, "buffer " .. kq(res)) end,
  fallback = function() return { "kks-buffers" } end,
}

M.picker{
  name = "buffers_delete", title = "Delete Buffers", keywords = "close kill",
  items = function(t)
    local items = {}
    for _, b in ipairs(M.get(t, "%val{buflist}")[1] or {}) do
      items[#items + 1] = { id = b, title = basename(b), subtitle = dirname(b) ~= "." and dirname(b) or nil, icon = "document" }
    end
    return { title = "Delete Buffers", placeholder = "Tick buffers to delete", confirm = "Delete", multiple = true, items = items }
  end,
  accept = function(t, _, res)
    for _, b in ipairs(as_list(res)) do M.send(t, "try %{ delete-buffer " .. kq(b) .. " }") end
  end,
  fallback = function() return { "kks-buffers" } end,
}

M.picker{
  name = "mru", title = "Recent Files", keywords = "mru history",
  description = "Files recently shown in this working directory (~/.cache/kak-mru-*, written by a WinDisplay hook).",
  items = function(t)
    local f = io.open(HOME .. "/.cache/kak-mru-" .. t.cwd:gsub("/", "-"), "r")
    local items = {}
    if f then
      for path in f:lines() do
        local e = io.open(path, "r")
        if e then
          e:close()
          local rel = path:sub(1, #t.cwd + 1) == t.cwd .. "/" and path:sub(#t.cwd + 2) or tildify(path)
          items[#items + 1] = { id = path, title = basename(rel), subtitle = dirname(rel) ~= "." and dirname(rel) or nil, icon = "clock" }
        end
      end
      f:close()
    end
    return { title = "Recent Files", placeholder = "Filter recent files", confirm = "Open", items = items }
  end,
  accept = function(t, _, res) M.edit(t, res) end,
  fallback = function() return { "kks-mru" } end,
}

-- Grep: ask for a pattern (seeded with the selection), show matches, and
-- treat typed text that matches nothing as a new pattern.
M.picker{
  name = "grep", title = "Grep", keywords = "search ripgrep rg live",
  args = { query = "string?", all = "boolean?" },
  native = function(t, args)
    local q = args.query
    if not q then
      q = M.input{ title = args.all and "Grep (all files)" or "Grep", placeholder = "ripgrep pattern",
                   value = selection_query(t), confirm = "Search" }
      if q == nil or q == "" then return end
    end
    while true do
      local argv = { "rg", "--vimgrep", "--hidden", "--max-columns", "300", "--max-columns-preview", "--glob", "!.git" }
      if args.all then argv[#argv + 1] = "--no-ignore" end
      argv[#argv + 1] = "--"
      argv[#argv + 1] = q
      local r = M.run(t, argv, { allow_fail = true })
      if r.code > 1 then error("rg: " .. trim(r.stderr), 0) end
      local items, rows, total = {}, {}, 0
      for _, l in ipairs(lines(r.stdout)) do
        local file, ln, col, text = l:match("^(.-):(%d+):(%d+):(.*)$")
        if file then
          total = total + 1
          rows[total] = abspath(t.cwd, file) .. ":" .. ln .. ":" .. col .. ":" .. text
          if #items < M.max_items then
            items[#items + 1] = {
              id = file .. ":" .. ln .. ":" .. col, title = trim(text),
              subtitle = file .. ":" .. ln, icon = "code",
            }
          end
        end
      end
      local title = string.format("Grep %q — %d match%s", q, total, total == 1 and "" or "es")
      if total > #items then title = title .. string.format(" (first %d)", #items) end
      if total > 0 then
        -- First row: the fzf ctrl-l equivalent, sending every match, not just the shown ones.
        if #items == M.max_items then table.remove(items) end
        table.insert(items, 1, { id = "@@list@@", title = string.format("Send all %d matches to list", total),
                                 subtitle = "*qf-" .. q .. "*", icon = "link" })
      end
      local res = M.pick{
        title = title, placeholder = "Filter matches, or type a new pattern", confirm = "Open",
        items = items, allow_other = true,
      }
      if res == nil then return end
      if type(res) == "table" then
        q = res.text
      elseif res == "@@list@@" then
        return M.send_to_list(t, q, rows)
      else
        local file, ln, col = res:match("^(.-):(%d+):(%d+)$")
        return M.edit(t, file, ln, col)
      end
    end
  end,
  fallback = function(_, args) return args.all and { "kks-grep", "--hidden" } or { "kks-grep" } end,
}

-- Send a grep to Kakoune's own *grep* buffer (the fzf ctrl-l equivalent).
M.picker{
  name = "grep_buffer", title = "Grep into *grep* Buffer", keywords = "search quickfix",
  args = { query = "string?" },
  native = function(t, args)
    local q = args.query or M.input{ title = "Grep into *grep*", placeholder = "pattern", value = selection_query(t), confirm = "Grep" }
    if q and q ~= "" then M.send(t, "grep " .. kq(q)) end
  end,
}

local function line_items(text, keep)
  local items, n = {}, 0
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local item = keep(l, n)
    if item then items[#items + 1] = item end
  end
  return items
end

M.picker{
  name = "lines", title = "Buffer Lines", keywords = "jump goto",
  items = function(t)
    local items = line_items(M.buffer_text(t), function(l, n)
      if l:find("%S") then return { id = tostring(n), title = trim(l):sub(1, 240), detail = tostring(n) } end
    end)
    return { title = "Lines", placeholder = "Filter lines", confirm = "Jump", items = items }
  end,
  accept = function(t, _, res) M.goto_line(t, res) end,
  fallback = function() return { "kks-lines" } end,
}

M.picker{
  name = "md_heading", title = "Markdown Headings", keywords = "outline toc",
  items = function(t)
    local items = line_items(M.buffer_text(t), function(l, n)
      local hashes, text = l:match("^(#+)%s+(.*)$")
      if hashes then
        return { id = tostring(n), title = string.rep("  ", #hashes - 1) .. text, detail = "h" .. #hashes, icon = "tag" }
      end
    end)
    return { title = "Headings", placeholder = "Filter headings", confirm = "Jump", items = items }
  end,
  accept = function(t, _, res) M.goto_line(t, res) end,
  fallback = function() return { "kks-md-heading" } end,
}

M.picker{
  name = "diff_files", title = "Diff Files", keywords = "git diff navigate",
  description = "Jump between files in a git diff buffer.",
  items = function(t)
    local items = line_items(M.buffer_text(t), function(l, n)
      local path = l:match("^diff %-%-git a/.- b/(.*)$")
      if path then
        return { id = tostring(n), title = basename(path), subtitle = dirname(path) ~= "." and dirname(path) or nil, detail = tostring(n), icon = "document" }
      end
    end)
    if #items == 0 then error("no 'diff --git' headers in this buffer", 0) end
    return { title = "Diff Files", placeholder = "Filter files in diff", confirm = "Jump", items = items }
  end,
  accept = function(t, _, res) M.send(t, "execute-keys " .. kq("<esc>" .. res .. "gx")) end,
  fallback = function() return { "kks-git-diff-files" } end,
}

-- cymbal: lang, kind, file, line, col, '', name…  (tab separated, ANSI coloured)
local function cymbal_items(out, cwd)
  local items, rows = {}, {}
  for _, l in ipairs(lines(strip_ansi(out))) do
    local f = {}
    for field in (l .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = field end
    if #f >= 5 and tonumber(f[4]) then
      local name = trim(table.concat(f, "", 6)) -- container prefix + name, e.g. "Foo.__init__"
      local kind = trim((f[2] or ""):gsub("[()]", ""))
      items[#items + 1] = {
        id = f[3] .. ":" .. f[4] .. ":" .. f[5] .. ":" .. #items, -- unique even for duplicates
        title = name ~= "" and name or kind, subtitle = kind .. " · " .. f[3]:gsub("^%./", "") .. ":" .. f[4],
        icon = "code",
      }
      if cwd then rows[#rows + 1] = abspath(cwd, f[3]) .. ":" .. f[4] .. ":" .. f[5] .. ":" .. kind .. " " .. name end
    end
  end
  return items, rows
end

M.picker{
  name = "symbols", title = "File Symbols", keywords = "cymbal outline",
  items = function(t)
    local file = M.val(t, "%val{buffile}")
    if not file or file == "" then error("buffer has no file", 0) end
    local r = M.run(t, { "cymbal", "--delimiter", "\t", "--separator", "\n", file })
    return { title = "Symbols in " .. basename(file), placeholder = "Filter symbols", confirm = "Jump",
             value = selection_query(t), items = cymbal_items(r.stdout) }
  end,
  accept = function(t, _, res)
    local _, ln, col = res:match("^(.-):(%d+):(%d+):%d+$")
    M.goto_line(t, ln, tonumber(col))
  end,
  fallback = function() return { "kks-cymbal-file" } end,
}

M.picker{
  name = "workspace_symbols", title = "Workspace Symbols", keywords = "cymbal",
  items = function(t)
    local r = M.run(t, { "cymbal", "--delimiter", "\t", "--separator", "\n", "." }, { timeout = 25 })
    local items, rows = cymbal_items(r.stdout, t.cwd)
    return { title = "Workspace Symbols", placeholder = "Filter symbols, or send matches to a list",
             confirm = "Send matches to list", allow_other = true,
             value = selection_query(t), items = items, rows = rows }
  end,
  accept = function(t, _, res, spec)
    if type(res) == "table" then return M.send_to_list(t, res.text, M.filter(t, spec.rows, res.text)) end
    local file, ln, col = res:match("^(.-):(%d+):(%d+):%d+$")
    M.edit(t, file, ln, col)
  end,
  fallback = function() return { "kks-cymbal-workspace" } end,
}

M.picker{
  name = "filetypes", title = "Set Filetype", keywords = "language syntax",
  items = function(t)
    local v = M.get(t, "%val{runtime}", "%opt{filetype}")
    local runtime, current = (v[1] or {})[1], (v[2] or {})[1]
    local r = M.run(t, { "ls", runtime .. "/rc/filetype" })
    local items = {}
    for _, f in ipairs(lines(r.stdout)) do
      local ft = f:match("^(.+)%.kak$")
      if ft then items[#items + 1] = { id = ft, icon = "code", detail = ft == current and "current" or nil } end
    end
    return { title = "Filetype", placeholder = "Filter filetypes", confirm = "Set", items = items }
  end,
  accept = function(t, _, res) M.send(t, "set-option buffer filetype " .. kq(res)) end,
  fallback = function() return { "kks-filetypes" } end,
}

-- Directory browser: folders drill down, ".." goes up, a file opens.
M.picker{
  name = "files_nav", title = "Browse Files", keywords = "explorer navigate directory",
  args = { dir = "string?" },
  native = function(t, args)
    local dir = abspath(t.cwd, args.dir or ".")
    while true do
      local r = M.run(t, { "ls", "-1Ap", dir }, { allow_fail = true })
      local items = { { id = "..", title = "..", subtitle = tildify(dirname(dir)), icon = "folder" } }
      local files = {}
      for _, e in ipairs(lines(r.stdout)) do
        if e:sub(-1) == "/" then
          items[#items + 1] = { id = e, title = e, icon = "folder" }
        else
          files[#files + 1] = { id = e, title = e, icon = "document" }
        end
      end
      for _, f in ipairs(files) do items[#items + 1] = f end
      local res = M.pick{ title = tildify(dir), placeholder = "Open file or enter folder, or send matches to a list",
                          confirm = "Send matching files to list", allow_other = true, items = items }
      if res == nil then return end
      if type(res) == "table" then
        local names = {}
        for _, f in ipairs(files) do names[#names + 1] = f.id end
        local rows = {}
        for _, n in ipairs(M.filter(t, names, res.text)) do rows[#rows + 1] = dir .. "/" .. n .. ":1:1:" end
        return M.send_to_list(t, res.text, rows)
      elseif res == ".." then
        dir = dirname(dir); if dir == "" then dir = "/" end
      elseif res:sub(-1) == "/" then
        dir = (dir == "/" and "" or dir) .. "/" .. res:sub(1, -2)
      else
        return M.edit(t, dir .. "/" .. res)
      end
    end
  end,
  fallback = function(t, args) return { "kks-files-navigation", args.dir or t.cwd } end,
}

-- Jump to another Kakoune client running in this Rex server.
M.picker{
  name = "clients", title = "Kakoune Clients", keywords = "switch session pane",
  native = function(t)
    local r = M.run(t, { "ls", M.state_dir }, { allow_fail = true })
    local items = {}
    for _, f in ipairs(lines(r.stdout)) do
      local fh = io.open(M.state_dir .. "/" .. f, "r")
      if fh then
        local session, client, cwd, block = fh:read("*l"), fh:read("*l"), fh:read("*l"), fh:read("*l")
        fh:close()
        if block and block ~= "" then
          items[#items + 1] = { id = block, title = client .. "@" .. session, subtitle = tildify(cwd), icon = "terminal",
                                detail = block == t.block and "here" or nil }
        end
      end
    end
    local res = M.pick{ title = "Kakoune Clients", placeholder = "Filter clients", confirm = "Focus", items = items }
    if res then
      local _, err = rex.session.focus_block{ block_id = res }
      if err then error(err, 0) end
    end
  end,
}

---------------------------------------------------------------------------
-- Windowing: used by rex.kak's rex-terminal-popup
---------------------------------------------------------------------------

rex.action{
  name = "kak_popup",
  title = "Kakoune: Popup Terminal",
  category = "Kakoune",
  description = "Run a shell command in a floating layer over the Kakoune pane.",
  args = merge(COMMON_ARGS, { command = "string?", width = "number?", height = "number?" }),
  run = function(ctx, args)
    local t = {
      session = args.session, client = args.client, cwd = args.cwd or HOME,
      block = args.block or ctx.block_id,
    }
    local w, h = args.width or M.popup_bounds[3], args.height or M.popup_bounds[4]
    local argv = { os.getenv("SHELL") or "/bin/sh" }
    if args.command and args.command ~= "" then argv = { "sh", "-c", args.command } end
    return M.popup(t, argv, { bounds = { (1 - w) / 2, (1 - h) / 2, w, h } })
  end,
}

return M
