-- What loads a plugin on demand: an event, a filetype, a command, a key, or another
-- team's batch loading. One watch per trigger value, shared by every plugin behind it.
-- When it fires, those plugins load in load order (a team's batch together, since its
-- members share the team's values), then the trigger is replayed once so the plugin
-- sees it: the event's new autocmds, the command as typed, the keys as pressed.

local events = require('team.events')
local state = require('team.state')

local api = vim.api
local levels = vim.log.levels

local M = {}

---@class team.Watch
---@field plugins string[] plugin names behind it, in load order
---@field id? integer the event autocmd
---@field fn? function the key stub's callback
---@field prev? table the mapping the key stub replaced
---@field mode? string
---@field lhs? string

---@type table<string, table<string, team.Watch>>
local watches = { event = {}, cmd = {}, keys = {}, after_team = {} }

---@param list string[]
---@param name string
local function add(list, name)
  if not vim.list_contains(list, name) then
    list[#list + 1] = name
  end
end

---@param list string[]
---@param name string
local function remove(list, name)
  for i = #list, 1, -1 do
    if list[i] == name then
      table.remove(list, i)
    end
  end
end

--- Keep a watch's plugins in load order, whatever order they were armed in.
---@param w team.Watch
local function sort(w)
  local pos = {}
  for i, name in ipairs(state.order) do
    pos[name] = i
  end
  table.sort(w.plugins, function(a, b)
    return (pos[a] or math.huge) < (pos[b] or math.huge)
  end)
end

---@type table<string, true> triggers whose replay waits for an install or a build
local replay_pending = {}

--- Load the plugins behind a trigger, then replay it once, when any of them loaded. When
--- some wait for an install or a build, the replay waits for them too.
---@param names string[]
---@param reason string
---@param replay? fun()
local function fire(names, reason, replay)
  local loader = require('team.loader')
  local any, waiting = false, {}
  for _, name in ipairs(vim.list_slice(names)) do
    local p = state.plugins[name]
    if p.state ~= 'loaded' then
      local ok = loader.load(p, reason)
      if ok then
        any = true
      elseif ok == nil then
        waiting[#waiting + 1] = name
      end
    end
  end
  if not replay then
    return
  end
  if #waiting == 0 then
    if any then
      replay()
    end
    return
  end
  -- Once, however often the trigger fires while it waits.
  if replay_pending[reason] then
    return
  end
  replay_pending[reason] = true
  local id
  id = api.nvim_create_autocmd('User', {
    pattern = { 'TeamPluginLoad', 'TeamPluginFail' },
    desc = 'team.nvim: replay ' .. reason .. ' once its plugins are in',
    callback = function()
      local loaded = any
      for _, n in ipairs(waiting) do
        local s = state.plugins[n].state
        if s ~= 'loaded' and s ~= 'failed' then
          return
        end
        loaded = loaded or s == 'loaded'
      end
      api.nvim_del_autocmd(id)
      replay_pending[reason] = nil
      if loaded then
        vim.schedule(replay)
      end
    end,
  })
end

-- event / ft ------------------------------------------------------------------

-- The runtime applies a filetype's ftplugin, indent and syntax files from these groups.
local filetype_groups = { 'filetypeplugin', 'filetypeindent', 'syntaxset' }

--- An autocmd told apart from the others; Vimscript ones have no id.
---@param au table an item of nvim_get_autocmds()
---@return integer|string
local function au_key(au)
  return au.id or table.concat({ tostring(au.group), au.pattern or '', tostring(au.command) }, '\0')
end

---@class team.Seen
---@field keys table<integer|string, true>
---@field groups table<integer, true>

---@param event string
---@return team.Seen
local function snapshot(event)
  local seen = { keys = {}, groups = {} }
  for _, au in ipairs(api.nvim_get_autocmds({ event = event })) do
    seen.keys[au_key(au)] = true
    if au.group then
      seen.groups[au.group] = true
    end
  end
  return seen
end

--- Whether an autocmd's pattern matches what the event fired for. A pattern with no
--- slash matches the file's tail, as Neovim does.
---@param pattern string
---@param match string
---@return boolean
local function matches(pattern, match)
  local re = vim.fn.glob2regpat(pattern)
  return vim.fn.match(match, re) >= 0 or (not pattern:find('/') and vim.fn.match(vim.fs.basename(match), re) >= 0)
end

---@param buf integer
---@param fn fun()
local function in_buf(buf, fn)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_call(buf, fn)
  else
    fn()
  end
end

--- Run the autocmds of `event` that the load added, and only those: a group the plugin
--- made runs whole through Neovim (so a Vimscript autocmd keeps its s: functions); a lone
--- callback is called with the event's args; a lone command is run in the buffer.
---@param event string
---@param args vim.api.keyset.create_autocmd.callback_args
---@param seen team.Seen
local function replay_event(event, args, seen)
  if not api.nvim_buf_is_valid(args.buf) then
    args = vim.tbl_extend('force', args, { buf = api.nvim_get_current_buf() })
  end
  local ran = {}
  for _, au in ipairs(api.nvim_get_autocmds({ event = event })) do
    ---@cast au table<string, any>
    local applies = au.buflocal and au.buffer == args.buf or (not au.buflocal and matches(au.pattern, args.match or ''))
    if applies and not seen.keys[au_key(au)] then
      local ok, err = true, nil
      if au.group and not au.buflocal and not seen.groups[au.group] then
        if not ran[au.group] then
          ran[au.group] = true
          ok, err = pcall(in_buf, args.buf, function()
            api.nvim_exec_autocmds(event, {
              group = au.group,
              pattern = args.match ~= '' and args.match or nil,
              modeline = false,
              data = args.data,
            })
          end)
        end
      elseif type(au.callback) == 'function' then
        local res
        ok, res = pcall(au.callback, vim.tbl_extend('force', args, { id = au.id, group = au.group }))
        err = res
        if au.id and (au.once or (ok and res == true)) then
          pcall(api.nvim_del_autocmd, au.id)
        end
      elseif au.command and au.command ~= '' then
        ok, err = pcall(in_buf, args.buf, function()
          vim.cmd(au.command)
        end)
        if au.id and au.once then
          pcall(api.nvim_del_autocmd, au.id)
        end
      end
      if not ok then
        events.report(('replaying %s: %s'):format(event, tostring(err)), levels.ERROR)
      end
    end
  end
end

--- After a load on FileType: detect filetypes again if the plugin brought ftdetect
--- scripts, then apply ftplugin, indent and syntax files to every buffer of that filetype.
---@param ft string
---@param ftdetect_before integer
local function refresh_filetype(ft, ftdetect_before)
  local detect = #api.nvim_get_runtime_file('ftdetect/*.{vim,lua}', true) ~= ftdetect_before
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      api.nvim_buf_call(buf, function()
        if detect and vim.bo.buftype == '' then
          vim.cmd('filetype detect')
        end
        if vim.bo.filetype == ft then
          for _, g in ipairs(filetype_groups) do
            pcall(api.nvim_exec_autocmds, 'FileType', { group = g, buffer = buf, modeline = false })
          end
        end
      end)
    end
  end
end

---@param key string "Event" or "Event pattern"
---@param args vim.api.keyset.create_autocmd.callback_args
local function on_event(key, args)
  local w = watches.event[key]
  if not w then
    return
  end
  local event = args.event
  local seen = snapshot(event)
  local ftdetect = event == 'FileType' and #api.nvim_get_runtime_file('ftdetect/*.{vim,lua}', true)
  fire(w.plugins, (event == 'FileType' and 'ft ' or 'event ') .. (event == 'FileType' and args.match or key), function()
    replay_event(event, args, seen)
    if ftdetect then
      refresh_filetype(args.match, ftdetect)
    end
  end)
end

---@param key string
---@param p team.Plugin
local function arm_event(key, p)
  local w = watches.event[key]
  if not w then
    local event, pattern = key:match('^(%S+)%s*(.*)$')
    local ok, id = pcall(api.nvim_create_autocmd, event, {
      pattern = pattern ~= '' and pattern or nil,
      desc = 'team.nvim: load on ' .. key,
      -- So what a config does fires its own autocmds: a colorscheme, a filetype.
      nested = true,
      callback = function(args)
        on_event(key, args)
      end,
    })
    if not ok then
      local msg = ('`%s`: cannot load on `%s`: %s'):format(p.name, key, tostring(id):match('^[^\n]*'))
      events.report(msg, levels.ERROR, { plugin = p.name })
      return
    end
    w = { plugins = {}, id = id }
    watches.event[key] = w
  end
  add(w.plugins, p.name)
  sort(w)
end

---@param key string
---@param p team.Plugin
local function disarm_event(key, p)
  local w = watches.event[key]
  if w then
    remove(w.plugins, p.name)
    if #w.plugins == 0 then
      pcall(api.nvim_del_autocmd, w.id)
      watches.event[key] = nil
    end
  end
end

-- cmd -------------------------------------------------------------------------

local cmd_desc = 'team.nvim: load on :'

--- Whether `:name` is still our stub. Neovim 0.12 keeps a Lua command's desc in `definition`.
---@param name string
---@return boolean exists, boolean ours
local function cmd_state(name)
  local def = api.nvim_get_commands({})[name]
  if not def then
    return false, false
  end
  return true, (def.desc or def.definition) == cmd_desc .. name
end

---@param name string
---@param args vim.api.keyset.create_user_command.command_args
local function on_cmd(name, args)
  local w = watches.cmd[name]
  fire(w and w.plugins or {}, 'cmd ' .. name, function()
    local range = args.range == 2 and (args.line1 .. ',' .. args.line2)
      or args.range == 1 and tostring(args.line1)
      or ''
    -- As text, the way it was typed: fargs would lose escaped spaces.
    local line = ('%s%s%s%s%s'):format(
      args.mods ~= '' and (args.mods .. ' ') or '',
      range,
      name,
      args.bang and '!' or '',
      args.args ~= '' and (' ' .. args.args) or ''
    )
    local ok, err = pcall(vim.cmd --[[@as function]], line)
    if not ok then
      -- The command's own error, as Neovim words one you typed.
      local msg = tostring(err):match('Vim%b():(.*)$') or tostring(err):match('Vim:(.*)$') or tostring(err)
      api.nvim_echo({ { msg } }, true, { err = true })
    end
  end)
end

---@param name string
local function make_cmd_stub(name)
  api.nvim_create_user_command(name, function(args)
    on_cmd(name, args)
  end, {
    nargs = '*',
    bang = true,
    range = true,
    -- Completing loads the plugins, then asks the real command.
    complete = function(_, line)
      local w = watches.cmd[name]
      fire(w and w.plugins or {}, 'cmd ' .. name)
      local _, ours = cmd_state(name)
      if ours then
        return {}
      end
      return vim.fn.getcompletion(line, 'cmdline')
    end,
    desc = cmd_desc .. name,
  })
end

---@param name string
---@param p team.Plugin
local function arm_cmd(name, p)
  local w = watches.cmd[name]
  if not w then
    w = { plugins = {} }
    watches.cmd[name] = w
    local ok, err = pcall(make_cmd_stub, name)
    if not ok then
      watches.cmd[name] = nil
      local msg = ('`%s`: cannot load on `:%s`: %s'):format(p.name, name, tostring(err):match('^[^\n]*'))
      events.report(msg, levels.ERROR, { plugin = p.name })
      return
    end
  end
  add(w.plugins, p.name)
  sort(w)
end

--- Take the stub away before the plugin loads, so the plugin can define the command.
---@param name string
---@param p team.Plugin
---@param loading boolean
local function disarm_cmd(name, p, loading)
  local w = watches.cmd[name]
  if not w then
    return
  end
  remove(w.plugins, p.name)
  local exists, ours = cmd_state(name)
  if loading and exists and not ours then
    local msg = '`%s`: its command `:%s` was defined by something else before it loaded'
    events.report(msg:format(p.name, name), levels.WARN, { plugin = p.name })
  end
  if ours and (loading or #w.plugins == 0) then
    api.nvim_del_user_command(name)
  end
  if #w.plugins == 0 then
    watches.cmd[name] = nil
  end
end

-- keys ------------------------------------------------------------------------

-- Passed to vim.keymap.set for a key the spec maps itself.
local map_options = { 'desc', 'silent', 'noremap', 'remap', 'nowait', 'expr', 'unique', 'script', 'buffer' }

---@class team.ParsedKey
---@field lhs string
---@field rhs? string|function
---@field modes string[]
---@field opts vim.keymap.set.Opts

---@param k string|team.Key
---@return team.ParsedKey
function M.parse_key(k)
  if type(k) == 'string' then
    return { lhs = k, modes = { 'n' }, opts = {} }
  end
  local opts = {}
  for _, o in ipairs(map_options) do
    opts[o] = k[o]
  end
  local mode = k.mode or 'n'
  return { lhs = k[1], rhs = k[2], modes = type(mode) == 'table' and mode or { mode }, opts = opts }
end

-- Modes where a register and a count can come before a key.
local counted = { n = true, x = true, v = true, o = true }

---@param id string "mode lhs"
local function on_key(id)
  local w = watches.keys[id]
  if not w then
    return
  end
  local mode, lhs = assert(w.mode), assert(w.lhs)
  -- What came before the key: a register, a count, and in operator-pending mode the
  -- operator, which ends when this stub returns without a motion.
  local prefix = ''
  if counted[mode] then
    prefix = '"' .. vim.v.register .. (vim.v.count > 0 and tostring(vim.v.count) or '')
    if mode == 'o' then
      prefix = prefix .. vim.v.operator
    end
  end
  fire(w.plugins, 'keys ' .. lhs, function()
    -- With remapping, so the mapping the plugin or its spec just made runs.
    api.nvim_feedkeys(prefix .. vim.keycode(lhs), 'mit', false)
  end)
end

--- Whether the key's stub is still mapped: you or a plugin may have mapped it since.
---@param w team.Watch
---@return boolean
local function key_is_ours(w)
  local ok, maps = pcall(api.nvim_get_keymap, assert(w.mode))
  return ok and vim.iter(maps):any(function(m) ---@param m table<string, any>
    return m.callback == w.fn
  end)
end

---@param id string
---@param w team.Watch
---@param desc string
local function make_key_stub(id, w, desc)
  local prev = vim.fn.maparg(w.lhs, w.mode, false, true) --[[@as table<string, any>]]
  -- A mapping of yours the stub replaces comes back when the stub goes.
  w.prev = next(prev) and prev.buffer == 0 and prev or nil
  w.fn = function()
    on_key(id)
  end
  vim.keymap.set(w.mode, w.lhs, w.fn, { desc = desc })
end

---@param k team.ParsedKey
---@param p team.Plugin
local function arm_key(k, p)
  for _, mode in ipairs(k.modes) do
    local id = mode .. ' ' .. k.lhs
    local w = watches.keys[id]
    if not w then
      w = { plugins = {}, mode = mode, lhs = k.lhs }
      watches.keys[id] = w
      make_key_stub(id, w, k.opts.desc or ('team.nvim: load ' .. p.name))
    end
    add(w.plugins, p.name)
    sort(w)
  end
end

---@param w team.Watch
local function del_key_stub(w)
  pcall(vim.keymap.del, w.mode, w.lhs)
  if w.prev then
    pcall(vim.fn.mapset, w.mode, false, w.prev)
  end
  w.fn = nil
end

---@param k team.ParsedKey
---@param p team.Plugin
---@param loading boolean
local function disarm_key(k, p, loading)
  for _, mode in ipairs(k.modes) do
    local id = mode .. ' ' .. k.lhs
    local w = watches.keys[id]
    if w then
      remove(w.plugins, p.name)
      local ours = w.fn ~= nil and key_is_ours(w)
      if loading and w.fn and not ours then
        local msg = '`%s`: its key `%s` was mapped by something else before it loaded'
        events.report(msg:format(p.name, k.lhs), levels.WARN, { plugin = p.name })
      end
      if ours and (loading or #w.plugins == 0) then
        del_key_stub(w)
      end
      if #w.plugins == 0 then
        watches.keys[id] = nil
      end
    end
  end
end

-- after_team ------------------------------------------------------------------

---@param team string
---@param p team.Plugin
local function arm_after(team, p)
  local w = watches.after_team[team] or { plugins = {} }
  watches.after_team[team] = w
  add(w.plugins, p.name)
  sort(w)
  if state.teams[team].state == 'loaded' then
    vim.schedule(function()
      M.team_loaded(team)
    end)
  end
end

--- A team's batch has loaded: load what waits for it.
---@param team string
function M.team_loaded(team)
  local w = watches.after_team[team]
  if w then
    fire(w.plugins, 'after team ' .. team)
  end
end

-- arm / disarm ----------------------------------------------------------------

---@type table<string, true> plugins with watches set up
local armed = {}

--- Set up every trigger of a plugin.
---@param p team.Plugin
function M.arm(p)
  if armed[p.name] or not next(p.triggers) then
    return
  end
  armed[p.name] = true
  local t = p.triggers
  for _, e in ipairs(t.event or {}) do
    arm_event(e, p)
  end
  for _, ft in ipairs(t.ft or {}) do
    arm_event('FileType ' .. ft, p)
  end
  for _, name in ipairs(t.cmd or {}) do
    arm_cmd(name, p)
  end
  for _, k in ipairs(t.keys or {}) do
    arm_key(M.parse_key(k), p)
  end
  for _, team in ipairs(t.after_team or {}) do
    arm_after(team, p)
  end
end

--- Take a plugin's triggers away: right before it loads (`loading`), or once it failed.
---@param p team.Plugin
---@param loading boolean
function M.disarm(p, loading)
  if not armed[p.name] then
    return
  end
  armed[p.name] = nil
  local t = p.triggers
  for _, e in ipairs(t.event or {}) do
    disarm_event(e, p)
  end
  for _, ft in ipairs(t.ft or {}) do
    disarm_event('FileType ' .. ft, p)
  end
  for _, name in ipairs(t.cmd or {}) do
    disarm_cmd(name, p, loading)
  end
  for _, k in ipairs(t.keys or {}) do
    disarm_key(M.parse_key(k), p, loading)
  end
  for _, team in ipairs(t.after_team or {}) do
    local w = watches.after_team[team]
    if w then
      remove(w.plugins, p.name)
    end
  end
end

--- After a plugin loaded: map the keys its spec maps, and put back a command or key stub
--- that other plugins behind it still need, when the plugin did not take the name.
---@param p team.Plugin
function M.loaded(p)
  local t = p.triggers
  for _, k in ipairs(t.keys or {}) do
    local key = M.parse_key(k)
    if key.rhs ~= nil then
      vim.keymap.set(key.modes, key.lhs, key.rhs, key.opts)
    end
    for _, mode in ipairs(key.modes) do
      local id = mode .. ' ' .. key.lhs
      local w = watches.keys[id]
      if w and not w.fn and #w.plugins > 0 and vim.fn.maparg(key.lhs, mode) == '' then
        make_key_stub(id, w, 'team.nvim: load ' .. w.plugins[1])
      end
    end
  end
  for _, name in ipairs(t.cmd or {}) do
    local w = watches.cmd[name]
    if w and #w.plugins > 0 and not cmd_state(name) then
      make_cmd_stub(name)
    end
  end
end

return M
