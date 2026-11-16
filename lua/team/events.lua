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
  -- { plugin, kind, ok, ms, err? } once a build has finished; kind: install, update, retry
  Build = 'TeamBuild',
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

---@type { msg: string, level: integer }[] warnings and errors of this tick, not shown yet
local pending = {}

--- Show this tick's warnings and errors as one short message: one line, so it never
--- stops you at "Press ENTER". The whole text is in the log, :Team log.
local function flush()
  local list = pending
  pending = {}
  if #list == 0 then
    return
  end
  local level, firsts = vim.log.levels.WARN, {}
  for _, m in ipairs(list) do
    level = math.max(level, m.level)
    firsts[#firsts + 1] = m.msg:match('^[^\n]*')
  end
  local msg = #list == 1 and firsts[1] or ('%d problems: %s'):format(#list, table.concat(firsts, '; '))
  -- Clear of the ruler and showcmd, which a float without a statusline puts on this line.
  local room = math.min(vim.v.echospace > 0 and vim.v.echospace or vim.o.columns, vim.o.columns - 30)
  msg = 'team.nvim: ' .. msg
  if #list > 1 or vim.fn.strdisplaywidth(msg) > room or list[1].msg:find('\n') then
    local hint = ' (:Team log)'
    msg = vim.fn.strdisplaywidth(msg) + #hint > room and vim.fn.strcharpart(msg, 0, room - #hint - 1) .. '…' .. hint
      or msg .. hint
  end
  vim.notify(msg, level)
end

--- Record a message, tell listeners, and show warnings and errors, once a tick.
---@param msg string
---@param level? integer default INFO
---@param about? team.About
function M.report(msg, level, about)
  level = level or vim.log.levels.INFO
  local e = log.add(level, msg, about)
  M.emit(M.names.Report, { msg = msg, level = level, plugin = e.plugin, team = e.team })
  if level >= vim.log.levels.WARN then
    pending[#pending + 1] = { msg = msg, level = level }
    if #pending == 1 then
      vim.schedule(flush)
    end
  end
end

return M
