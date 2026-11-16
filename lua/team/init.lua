-- team.nvim: a plugin manager on vim.pack where plugins load, update and profile as teams.
--
--   require('team').setup({ teams = { ... } })
--
-- setup() reads your teams and specs, hands every plugin to vim.pack (which installs what
-- is missing), runs each team's and plugin's `init`, arms every trigger, loads the `now`
-- plugins, and queues the `later` ones for once the UI is up. See PLAN.md.

local M = {}

local levels = vim.log.levels

---@return number ms since `t0`
local function since(t0)
  return (vim.uv.hrtime() - t0) / 1e6
end

--- The file that called setup(), for messages about teams defined there.
---@return team.Origin
local function caller()
  local info = debug.getinfo(3, 'S')
  local source = info and info.source or ''
  return { file = source:sub(1, 1) == '@' and source:sub(2) or 'setup()' }
end

---@param opts? team.Opts
function M.setup(opts)
  local events, log, state = require('team.events'), require('team.log'), require('team.state')
  if state.config then
    events.report('setup() runs once a session; this call is ignored', levels.WARN)
    return
  end
  local start = vim.uv.hrtime()
  log.start = start
  local origin = caller()

  local notes = require('team.notes').new()
  local config = require('team.config').resolve(opts, origin, notes)
  local collected = require('team.collect').collect(config, origin, notes)
  local graph = require('team.graph').build(collected, notes)
  for _, n in ipairs(notes.list) do
    events.report(n.msg, n.level)
  end
  state.init(graph, config)
  state.times.specs = since(start)

  -- A first start waits for the UI, so the window can show the installs: the plugins not
  -- on disk, or every plugin when the lockfile lists some that are not (vim.pack's first
  -- call would install those during init.lua). Headless Neovim installs at once.
  local pack, build, schedule = require('team.pack'), require('team.build'), require('team.schedule')
  build.timeout = config.build_timeout
  local earlier = build.pending()
  build.watch()
  local on = state.list(function(p)
    return p.state ~= 'disabled'
  end)
  local held = {}
  if vim.v.vim_did_enter == 0 and schedule.ui_coming() then
    local missing = vim.tbl_filter(function(p)
      return not vim.uv.fs_stat(vim.fs.joinpath(pack.dir(), p.name))
    end, on)
    if #missing > 0 then
      held = #pack.lock_missing() > 0 and on or missing
    end
  end
  local t0 = vim.uv.hrtime()
  pack.register(
    vim.tbl_filter(function(p)
      return not vim.list_contains(held, p)
    end, on),
    config.confirm
  )
  state.times.pack = since(t0)
  for _, p in ipairs(held) do
    -- Its loads wait for the install.
    state.set(p, 'installing')
  end
  if #held > 0 then
    vim.api.nvim_create_autocmd('UIEnter', {
      once = true,
      callback = vim.schedule_wrap(function()
        require('team.ui').open('teams')
        vim.cmd.redraw()
        pack.register(held, config.confirm)
        require('team.ui').redraw()
      end),
    })
  end
  build.retry(earlier)

  -- Every startup, before anything loads: each team's `init`, then each plugin's.
  t0 = vim.uv.hrtime()
  local loader = require('team.loader')
  for _, name in ipairs(state.team_order) do
    local t = state.teams[name]
    if t.state ~= 'disabled' then
      loader.hook(t, 'init')
    end
  end
  for _, p in ipairs(state.list()) do
    if p.state ~= 'disabled' then
      loader.init(p)
    end
  end
  state.times.init = since(t0)

  -- Triggers first, so `after_team` is watching when the `now` teams load.
  local triggers = require('team.triggers')
  schedule.budget = config.budget
  for _, p in ipairs(on) do
    triggers.arm(p)
  end

  t0 = vim.uv.hrtime()
  for _, p in ipairs(on) do
    if loader.when(p) == 'now' then
      loader.load(p, 'startup')
    end
  end
  state.times.now = since(t0)
  schedule.run_now()

  -- VeryLazy beside other events: the queue loads it if none of them fired first.
  for _, p in ipairs(on) do
    if loader.when(p) == 'later' or p.very_lazy then
      schedule.add(p)
    end
  end
  schedule.start()
  state.times.setup = since(start)
  events.emit(events.names.Setup, { ms = state.times.setup })
end

--- Run `fn` once setup() has loaded the `now` plugins, or at once if it has.
---@param fn function
function M.now(fn)
  require('team.schedule').now(fn)
end

--- Run `fn` in the `later` queue, once the UI is up, in turn with `later` plugins.
---@param fn function
function M.later(fn)
  require('team.schedule').later(fn)
end

--- A plugin's record, or nil.
---@param name string
---@return team.Plugin?
function M.get(name)
  return require('team.state').plugins[name]
end

--- Every team's record, needed teams first.
---@return team.Team[]
function M.teams()
  local state = require('team.state')
  return vim.tbl_map(function(name)
    return state.teams[name]
  end, state.team_order)
end

--- Load a plugin now, with what it needs.
---@param name string
---@return boolean? ok nil: it waits for an install or a build, and loads after
---@return string? err
function M.load(name)
  local p = M.get(name)
  if not p then
    return false, ('no plugin is named `%s`'):format(name)
  end
  return require('team.loader').load(p, 'load()')
end

--- Load every member of a team now: its batch, then the rest.
---@param name string
---@return boolean ok
---@return string? err
function M.load_team(name)
  local t = require('team.state').teams[name]
  if not t then
    return false, ('no team is named `%s`'):format(name)
  end
  return require('team.loader').load_team(t, 'load_team()')
end

--- Open the window on a view: 'teams' (default), 'profile' or 'log'.
---@param view? 'teams'|'profile'|'log'
function M.open(view)
  require('team.ui').open(view)
end

--- Update plugins with vim.pack: teams stand for their members; none means every plugin.
--- `force` applies them at once, without vim.pack's confirmation buffer.
---@param names? string[]
---@param force? boolean
---@return boolean ok
---@return string? err
function M.update(names, force)
  return require('team.ops').update(names, force)
end

--- Turn a team on for this session: install what it needs, run its `init`, arm its
--- triggers and queue the rest.
---@param name string
---@return boolean ok
---@return string? err
function M.enable_team(name)
  return require('team.ops').enable(name)
end

--- Turn a team off for this session: members that have not loaded never will.
---@param name string
---@return boolean ok
---@return string? err
function M.disable_team(name)
  return require('team.ops').disable(name)
end

return M
