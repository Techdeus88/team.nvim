-- team.nvim's events are `User` autocmds, so your config can hook the same ones:
--
--   vim.api.nvim_create_autocmd('User', { pattern = 'TeamPluginLoad', callback = function(ev)
--     print(ev.data.plugin, ev.data.ms)
--   end })
--
-- An error in a callback is Neovim's to show, as yours; it does not stop team.nvim.

local log = require('team.log')

local M = {}

M.names = {
  -- { plugin, team, reason } before a plugin loads
  PluginLoadPre = 'TeamPluginLoadPre',
  -- { plugin, team, reason, ms } once it loaded and its config ran
  PluginLoad = 'TeamPluginLoad',
  -- { plugin, team, err } when it could not load
  PluginFail = 'TeamPluginFail',
  -- { team } before the first member of a team loads
  LoadPre = 'TeamLoadPre',
  -- { team, ms } once a team's batch loaded and its `post` ran
  Load = 'TeamLoad',
  -- { plugins } plugin names vim.pack installed
  Install = 'TeamInstall',
  -- { plugin?, team?, state } whenever a plugin or team changes state
  State = 'TeamState',
  -- { ms } once setup() is done and the `now` plugins have loaded
  Setup = 'TeamSetup',
  -- { ms } once the `later` queue has drained for the first time
  Later = 'TeamLater',
  -- { msg, level, plugin?, team? } every message team.nvim reports
  Report = 'TeamReport',
}

---@param name string one of M.names
---@param data table
function M.emit(name, data)
  vim.api.nvim_exec_autocmds('User', { pattern = name, data = data, modeline = false })
end

--- Listen to one of team.nvim's events.
---@param name string one of M.names
---@param fn fun(data: table)
---@param group? integer
---@return integer autocmd id
function M.on(name, fn, group)
  return vim.api.nvim_create_autocmd('User', {
    pattern = name,
    group = group,
    callback = function(ev)
      fn(ev.data)
    end,
  })
end

--- Record a message, tell listeners, and show warnings and errors.
---@param msg string
---@param level? integer default INFO
---@param about? { plugin?: string, team?: string }
function M.report(msg, level, about)
  level = level or vim.log.levels.INFO
  local e = log.add(level, msg, about)
  M.emit(M.names.Report, { msg = msg, level = level, plugin = e.plugin, team = e.team })
  if level >= vim.log.levels.WARN then
    vim.notify('team.nvim: ' .. msg, level)
  end
end

return M
