-- What you do to teams and plugins after setup(): update them, turn a team on or off for
-- this session, and clean plugins off the disk that no spec names. Each returns ok and,
-- when not, why.

local events = require('team.events')
local state = require('team.state')

local M = {}

local levels = vim.log.levels

---@return boolean ok, string? err
local function ready()
  if not state.config then
    return false, 'setup() has not run'
  end
  return true
end

--- Plugin names for `names`: a team stands for its members that are installed.
---@param names string[]
---@return string[]? plugins
---@return string? err
function M.expand(names)
  local res, unknown = {}, {}
  for _, name in ipairs(names) do
    local t, p = state.teams[name], state.plugins[name]
    if t then
      for _, m in ipairs(t.members) do
        if state.plugins[m].path and not vim.list_contains(res, m) then
          res[#res + 1] = m
        end
      end
    elseif p then
      if not vim.list_contains(res, name) then
        res[#res + 1] = name
      end
    else
      unknown[#unknown + 1] = name
    end
  end
  if #unknown > 0 then
    return nil,
      ('no team or plugin is named %s'):format(table.concat(
        vim.tbl_map(function(n)
          return '`' .. n .. '`'
        end, unknown),
        ', '
      ))
  end
  return res
end

-- Lua modules cannot be unloaded: say so when a plugin that has loaded is updated.
local watching_updates = false
local function watch_updates()
  if watching_updates then
    return
  end
  watching_updates = true
  vim.api.nvim_create_autocmd('PackChanged', {
    desc = 'team.nvim: note updates of loaded plugins',
    callback = function(ev)
      local p = state.plugins[ev.data.spec.name]
      if ev.data.kind == 'update' and p and p.state == 'loaded' then
        local msg = '`%s` was updated while loaded; restart Neovim to run the new code'
        events.report(msg:format(p.name), levels.WARN, { plugin = p.name })
      end
    end,
  })
end

---@param names? string[] teams or plugins; none: every plugin that is installed
---@param force? boolean skip vim.pack's confirmation buffer
---@return boolean ok, string? err
function M.update(names, force)
  local ok, err = ready()
  if not ok then
    return false, err
  end
  local list
  if names and #names > 0 then
    list, err = M.expand(names)
    if not list then
      return false, err
    end
  else
    list = vim.tbl_map(
      function(p)
        return p.name
      end,
      state.list(function(p)
        return p.path ~= nil
      end)
    )
  end
  if #list == 0 then
    return false, 'nothing to update'
  end
  watch_updates()
  local done, why = pcall(vim.pack.update, list, { force = force == true })
  if not done then
    return false, tostring(why)
  end
  return true
end

--- Turn a team off for the session. Members that loaded stay loaded.
---@param name string
---@return boolean ok, string? err
function M.disable(name)
  local ok, err = ready()
  if not ok then
    return false, err
  end
  local t = state.teams[name]
  if not t then
    return false, ('no team is named `%s`'):format(name)
  elseif t.state == 'disabled' then
    return false, ('team `%s` is already off'):format(name)
  end
  local triggers = require('team.triggers')
  local stays = {}
  for _, m in ipairs(t.members) do
    local p = state.plugins[m]
    if p.state == 'loaded' or p.state == 'loading' then
      stays[#stays + 1] = '`' .. m .. '`'
    elseif p.state ~= 'disabled' then
      triggers.disarm(p, false)
      p.disabled_by = ('team `%s`'):format(name)
      state.set(p, 'disabled')
    end
  end
  t.disabled_by = 'session'
  state.set_team(t, 'disabled')
  events.report(('team `%s` is off for this session'):format(name), levels.INFO, { team = name })
  if #stays > 0 then
    local msg = 'team `%s`: %s already loaded and stay until Neovim restarts'
    events.report(msg:format(name, table.concat(stays, ', ')), levels.WARN, { team = name })
  end
  return true
end

--- Turn a team on for the session: what it needs is installed, its `init` and its
--- members' run, its triggers are armed, and the members whose moment has passed load
--- in the `later` queue.
---@param name string
---@return boolean ok, string? err
function M.enable(name)
  local ok, err = ready()
  if not ok then
    return false, err
  end
  local t = state.teams[name]
  if not t then
    return false, ('no team is named `%s`'):format(name)
  elseif t.state ~= 'disabled' then
    return false, ('team `%s` is already on'):format(name)
  end
  -- Its members that it turned off, and the dependencies they need that nothing else did.
  local by_team = ('team `%s`'):format(name)
  local back, seen = {}, {}
  local function bring(p)
    if seen[p.name] then
      return
    end
    seen[p.name] = true
    back[#back + 1] = p
    for _, d in ipairs(p.deps) do
      local dp = state.plugins[d]
      if dp.state == 'disabled' and dp.disabled_by == 'unneeded' then
        bring(dp)
      end
    end
  end
  for _, m in ipairs(t.members) do
    local p = state.plugins[m]
    if p.state == 'disabled' and p.disabled_by == by_team then
      bring(p)
    end
  end
  table.sort(back, function(a, b)
    return vim.fn.index(state.order, a.name) < vim.fn.index(state.order, b.name)
  end)

  t.disabled_by = nil
  state.set_team(t, 'pending')
  local missing = {}
  for _, p in ipairs(back) do
    p.disabled_by = nil
    if p.path then
      state.set(p, 'installed')
    else
      state.set(p, 'pending')
      missing[#missing + 1] = p
    end
  end
  require('team.pack').register(missing, state.config.confirm)

  local loader, schedule, triggers = require('team.loader'), require('team.schedule'), require('team.triggers')
  loader.hook(t, 'init')
  for _, p in ipairs(back) do
    loader.init(p)
  end
  for _, p in ipairs(back) do
    triggers.arm(p)
    local w = loader.when(p)
    if w == 'now' or w == 'later' or p.very_lazy then
      schedule.add(p)
    end
  end
  events.report(('team `%s` is on for this session'):format(name), levels.INFO, { team = name })
  return true
end

--- Plugins vim.pack keeps on disk that no spec names, so this session never added them.
---@return string[]
function M.strays()
  local res = {}
  for _, d in ipairs(vim.pack.get(nil, { info = false })) do
    if not d.active and not state.plugins[d.spec.name] then
      res[#res + 1] = d.spec.name
    end
  end
  table.sort(res)
  return res
end

--- Delete the strays from disk, after asking unless `force`.
---@param force? boolean
---@return boolean ok, string? err
function M.clean(force)
  local ok, err = ready()
  if not ok then
    return false, err
  end
  local strays = M.strays()
  if #strays == 0 then
    events.report('nothing to clean: every plugin on disk is in a spec', levels.INFO)
    vim.api.nvim_echo({ { 'team.nvim: nothing to clean' } }, false, {})
    return true
  end
  if not force then
    local msg = ('Delete these plugins, which no spec names?\n\n%s\n'):format(table.concat(strays, '\n'))
    if vim.fn.confirm(msg, '&Yes\n&No', 2, 'Question') ~= 1 then
      return true
    end
  end
  local done, why = pcall(vim.pack.del, strays)
  if not done then
    return false, tostring(why)
  end
  events.report(('cleaned %s'):format(table.concat(strays, ', ')), levels.INFO)
  return true
end

return M
