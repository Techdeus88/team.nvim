-- Load one plugin, a team's batch, or a whole team. A plugin loads after the batches of
-- the teams its team needs, after its team's `pre`, and after its own deps: then
-- `:packadd`, then `opts` and `config` (or `setup(opts)`), then `after`. Each step is
-- timed. Once a team's batch has loaded, its `post` runs.

local events = require('team.events')
local spec = require('team.spec')
local state = require('team.state')

local M = {}

local levels = vim.log.levels

---@return number ms since `t0`
local function since(t0)
  return (vim.uv.hrtime() - t0) / 1e6
end

--- Run your function; when it raises, the error's first line.
---@param fn function
---@param ... any arguments
---@return boolean ok
---@return string? err
local function call(fn, ...)
  local ok, err = xpcall(fn, debug.traceback, ...)
  if not ok then
    return false, tostring(err):match('^[^\n]*')
  end
  return true
end

--- Run a team hook once, and time it.
---@param t team.Team
---@param name 'init'|'pre'|'post'
function M.hook(t, name)
  t.hooks = t.hooks or {}
  if t.hooks[name] or not t[name] then
    return
  end
  -- Marked before it runs: a hook that loads a member of its own team comes back here.
  t.hooks[name] = 0
  local t0 = vim.uv.hrtime()
  local ok, err = call(t[name], t)
  t.hooks[name] = since(t0)
  if not ok then
    events.report(('team `%s`: `%s` failed: %s'):format(t.name, name, err), levels.ERROR, { team = t.name })
  end
end

--- When a plugin loads this session: its batch's moment if it is in one, else its own
--- `load`; `now_if_args` is `now` when Neovim was started with a file, else `later`.
---@param p team.Plugin
---@return team.Load
function M.when(p)
  local w = p.in_batch and state.teams[p.team].when or p.load
  if w == 'now_if_args' then
    return vim.fn.argc(-1) > 0 and 'now' or 'later'
  end
  return w
end

--- Run a plugin's `init`, once a session.
---@param p team.Plugin
function M.init(p)
  if p.did_init or not p.spec.init then
    return
  end
  p.did_init = true
  local ok, err = call(p.spec.init, p)
  if not ok then
    events.report(('`%s`: `init` failed: %s'):format(p.name, err), levels.ERROR, { plugin = p.name })
  end
end

--- The module whose setup() gets `opts`: `main`, else one named like the plugin, else the
--- only module the plugin has.
---@param p team.Plugin
---@return string? main
---@return string? err
function M.main(p)
  if p.spec.main then
    return p.spec.main
  end
  local lua = vim.fs.joinpath(assert(p.path), 'lua')
  local function exists(mod)
    return vim.uv.fs_stat(vim.fs.joinpath(lua, mod .. '.lua')) ~= nil
      or vim.uv.fs_stat(vim.fs.joinpath(lua, mod, 'init.lua')) ~= nil
  end
  local base = p.name:lower():gsub('%.git$', ''):gsub('%.n?vim$', ''):gsub('%.lua$', '')
  base = base:gsub('^n?vim%-', ''):gsub('%-n?vim$', '')
  for _, mod in ipairs({ base, (base:gsub('%-', '_')), (base:gsub('%-', '')) }) do
    if exists(mod) then
      return mod
    end
  end
  local mods = {}
  for name, kind in vim.fs.dir(lua) do
    local mod = kind == 'directory' and name or name:match('^(.+)%.lua$')
    if mod then
      mods[#mods + 1] = mod
    end
  end
  if #mods == 1 then
    return mods[1]
  end
  return nil,
    ('cannot tell which module gets `opts`; set `main` (found %s)'):format(
      #mods == 0 and 'no module' or table.concat(mods, ', ')
    )
end

--- Whether every plugin in `names` has loaded, and whether any of them failed.
---@param names string[]
---@return boolean all, boolean failed
local function progress(names)
  local all, failed = true, false
  for _, name in ipairs(names) do
    local s = state.plugins[name].state
    all = all and s == 'loaded'
    failed = failed or s == 'failed'
  end
  return all, failed
end

--- The members a team waits for: its batch, or every member that is on when it has none.
---@param t team.Team
---@return string[]
local function awaited(t)
  if #t.batch > 0 then
    return t.batch
  end
  return vim.tbl_filter(function(name)
    return state.plugins[name].state ~= 'disabled'
  end, t.members)
end

--- After a member loaded or failed: the team is partial, loaded (then `post`), or failed.
---@param t team.Team
function M.settle(t)
  if t.state == 'loaded' or t.state == 'failed' or t.state == 'disabled' then
    return
  end
  local list = awaited(t)
  local all, failed = progress(list)
  if failed then
    local name = vim.iter(list):find(function(n)
      return state.plugins[n].state == 'failed'
    end)
    local err = ('`%s` did not load'):format(name)
    state.set_team(t, 'failed', err)
    -- Its member's failure was the error; this only records what it did to the team.
    events.report(('team `%s` failed: %s'):format(t.name, err), levels.INFO, { team = t.name })
  elseif all and #list > 0 then
    -- Loaded before `post` runs, so a `post` that loads another member finds it settled.
    state.set_team(t, 'loaded')
    M.hook(t, 'post')
    local ms = 0
    for _, name in ipairs(t.members) do
      local time = state.plugins[name].time or {}
      ms = ms + (time.packadd or 0) + (time.config or 0)
    end
    for _, hook_ms in pairs(t.hooks or {}) do
      ms = ms + hook_ms
    end
    events.emit(events.names.Load, { team = t.name, ms = ms })
    -- Then what loads after this team.
    require('team.triggers').team_loaded(t.name)
  else
    local any = vim.iter(t.members):any(function(n)
      return state.plugins[n].state == 'loaded'
    end)
    if any then
      state.set_team(t, 'partial')
    end
  end
end

---@param p team.Plugin
---@param err string
---@return false, string
local function fail(p, err)
  require('team.triggers').disarm(p, false)
  state.set(p, 'failed', err)
  events.report(('`%s` did not load: %s'):format(p.name, err), levels.ERROR, { plugin = p.name, team = p.team })
  events.emit(events.names.PluginFail, { plugin = p.name, team = p.team, err = err })
  if p.team then
    M.settle(state.teams[p.team])
  end
  return false, err
end

--- Make a team ready for its members: the teams it needs have loaded their batches, and
--- its `pre` has run.
---@param t team.Team
---@return boolean ok
---@return string? err
local function ready(t)
  if t.ready then
    return true
  end
  for _, d in ipairs(t.deps) do
    local ok = M.load_batch(state.teams[d], ('team `%s` needs it'):format(t.name))
    if not ok then
      return false, ('team `%s`, which team `%s` needs, did not load'):format(d, t.name)
    end
  end
  t.ready = true
  events.emit(events.names.LoadPre, { team = t.name })
  M.hook(t, 'pre')
  return true
end

--- `:packadd` the plugin, as vim.pack does. While init.lua runs, `:packadd!`: it only
--- joins the runtimepath, and startup sources its plugin/ and after/plugin/ files in its
--- own pass. A plain `:packadd` then would source plugin/ twice. After startup, also its
--- after/plugin/ files, which nothing else would source.
---@param p team.Plugin
local function packadd(p)
  vim.cmd.packadd({ vim.fn.escape(p.name, ' '), bang = vim.v.vim_did_init == 0, magic = { file = false } })
  if vim.v.vim_did_enter == 1 then
    for _, file in ipairs(vim.fn.glob(vim.fs.joinpath(assert(p.path), 'after/plugin/**/*.{vim,lua}'), false, true)) do
      vim.cmd.source({ file, magic = { file = false } })
    end
  end
end

--- `opts`, then `config(p, opts)`, or `require(main).setup(opts)`, then `after`.
---@param p team.Plugin
---@return boolean ok
---@return string? err
local function configure(p)
  local s = p.spec
  local opts = {}
  if s.opts_parts then
    local ok, res = pcall(spec.resolve_opts, s.opts_parts, p)
    if not ok then
      return false, ('`opts`: %s'):format(tostring(res))
    end
    opts = res
  end
  -- spec.lua let through only true or something callable.
  local config = s.config
  if config ~= nil and config ~= true then
    local ok, err = call(config --[[@as function]], p, opts)
    if not ok then
      return false, ('`config`: %s'):format(err)
    end
  elseif config == true or s.opts_parts then
    local main, why = M.main(p)
    if not main then
      return false, why
    end
    local ok, err = call(function()
      local mod = require(main)
      if type(mod) ~= 'table' or not vim.is_callable(mod.setup) then
        error(('module `%s` has no setup()'):format(main), 0)
      end
      -- `config = true` with no `opts` calls setup() with nothing, as cinch does.
      if s.opts_parts then
        mod.setup(opts)
      else
        mod.setup()
      end
    end)
    if not ok then
      return false, ('`%s.setup()`: %s'):format(main, err)
    end
  end
  if s.after then
    local ok, err = call(s.after, p)
    if not ok then
      return false, ('`after`: %s'):format(err)
    end
  end
  return true
end

-- Installs and builds ---------------------------------------------------------

---@type table<string, fun()[]> plugin name -> what runs once it can load
local waiters = {}

--- Whether a plugin cannot load yet: vim.pack is installing it, or its build runs.
---@param p team.Plugin
---@return boolean
function M.blocked(p)
  return p.state == 'installing' or p.building ~= nil
end

--- The first plugin a load of `p` needs that cannot load yet: `p`, its deps, and the
--- batches of the teams its team needs, however deep.
---@param p team.Plugin
---@param seen? table<string, true>
---@return team.Plugin?
local function find_blocked(p, seen)
  seen = seen or {}
  if seen[p.name] then
    return
  end
  seen[p.name] = true
  if M.blocked(p) then
    return p
  end
  for _, d in ipairs(p.deps) do
    local b = find_blocked(state.plugins[d], seen)
    if b then
      return b
    end
  end
  local t = p.team and state.teams[p.team]
  for _, needed in ipairs(t and not t.ready and t.deps or {}) do
    local nt = state.teams[needed]
    for _, m in ipairs(nt.state ~= 'loaded' and nt.batch or {}) do
      local b = find_blocked(state.plugins[m], seen)
      if b then
        return b
      end
    end
  end
end

--- A plugin can load again: run what waited for it, in the order it started waiting.
---@param p team.Plugin
function M.unblock(p)
  local fns = waiters[p.name] or {}
  waiters[p.name] = nil
  for _, fn in ipairs(fns) do
    fn()
  end
end

--- Load a plugin and everything it needs first. While something it needs is installing
--- or building, it waits: the load runs once that is done, and this returns nil.
---@param p team.Plugin
---@param reason string
---@return boolean? ok nil: waiting
---@return string? err or what it waits for
function M.load(p, reason)
  if p.state == 'loaded' or p.state == 'loading' then
    return true
  elseif p.state == 'failed' then
    return false, p.err
  elseif p.state == 'disabled' then
    return false, ('`%s` is disabled'):format(p.name)
  end
  local b = find_blocked(p)
  if b then
    if not p.waiting then
      p.waiting = b.name
      waiters[b.name] = waiters[b.name] or {}
      table.insert(waiters[b.name], function()
        p.waiting = nil
        M.load(p, reason)
      end)
    end
    local what = b.state == 'installing' and 'install' or 'build'
    return nil, ('waiting for `%s` to %s'):format(b.name, what == 'install' and 'install' or 'finish its build')
  end
  if p.state == 'missing' or not p.path then
    return fail(p, p.err or 'not installed')
  end
  local t = p.team and state.teams[p.team]
  if t then
    local ok, err = ready(t)
    if not ok then
      return fail(p, err --[[@as string]])
    end
  end
  for _, d in ipairs(p.deps) do
    local dp = state.plugins[d]
    local ok = M.load(dp, ('dependency of %s'):format(p.name))
    if not ok then
      return fail(p, ('its dependency `%s` did not load'):format(d))
    end
  end

  p.reason = reason
  events.emit(events.names.PluginLoadPre, { plugin = p.name, team = p.team, reason = reason })
  state.set(p, 'loading')
  -- Its stubs go first, so the plugin can define the commands and keys they stood for.
  local triggers = require('team.triggers')
  triggers.disarm(p, true)
  local t0 = vim.uv.hrtime()
  local ok, err = pcall(packadd, p)
  local t1 = vim.uv.hrtime()
  p.time = { packadd = (t1 - t0) / 1e6 }
  if not ok then
    return fail(p, ('`:packadd` failed: %s'):format(tostring(err)))
  end
  ok, err = configure(p)
  p.time.config = since(t1)
  if not ok then
    return fail(p, err --[[@as string]])
  end
  triggers.loaded(p)
  state.set(p, 'loaded')
  local ms = p.time.packadd + p.time.config
  events.report(('loaded `%s` (%s) in %.2f ms'):format(p.name, reason, ms), levels.DEBUG, { plugin = p.name })
  events.emit(events.names.PluginLoad, { plugin = p.name, team = p.team, reason = reason, ms = ms })
  if t then
    M.settle(t)
  end
  return true
end

--- Load a team's batch, members in load order.
---@param t team.Team
---@param reason string
---@return boolean ok
---@return string? err
function M.load_batch(t, reason)
  if t.state == 'loaded' then
    return true
  elseif t.state == 'disabled' then
    return false, ('team `%s` is disabled'):format(t.name)
  end
  -- A member that waits for an install or a build loads once it can: not a failure.
  local ok = true
  for _, name in ipairs(state.order) do
    local p = state.plugins[name]
    if p.team == t.name and p.in_batch and M.load(p, reason) == false then
      ok = false
    end
  end
  return ok, not ok and ('team `%s` did not load'):format(t.name) or nil
end

--- Load every member of a team that is on: its batch, then the rest.
---@param t team.Team
---@param reason string
---@return boolean ok
---@return string? err
function M.load_team(t, reason)
  local ok = M.load_batch(t, reason)
  for _, name in ipairs(state.order) do
    local p = state.plugins[name]
    if p.team == t.name and p.state ~= 'disabled' and M.load(p, reason) == false then
      ok = false
    end
  end
  return ok, not ok and ('team `%s` did not load'):format(t.name) or nil
end

return M
