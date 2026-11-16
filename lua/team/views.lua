-- Plain buffers for :Team, :Team profile and :Team log, until the window of milestone 5.
-- Each is a scratch buffer named team://<view>, opened in a split at the bottom, or
-- refreshed where it already shows. `q` closes it.

local log = require('team.log')
local state = require('team.state')

local M = {}

local level_names = { [0] = 'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR' }

---@param n? number ms
---@return string
local function ms(n)
  return n and ('%.2f ms'):format(n) or '-'
end

--- A plugin's load cost: `:packadd` plus its config.
---@param p team.Plugin
---@return number
function M.cost(p)
  local t = p.time or {}
  return (t.packadd or 0) + (t.config or 0)
end

--- A team's load cost: its members' and its hooks'.
---@param t team.Team
---@return number
function M.team_cost(t)
  local total = 0
  for _, name in ipairs(t.members) do
    total = total + M.cost(state.plugins[name])
  end
  for _, h in pairs(t.hooks or {}) do
    total = total + h
  end
  return total
end

---@return string[]
function M.status()
  local lines = { 'team.nvim', '' }
  for _, name in ipairs(state.team_order) do
    local t = state.teams[name]
    local moment = t.when and (t.when .. (t.pulled_by and (' (pulled by ' .. t.pulled_by .. ')') or '')) or '-'
    lines[#lines + 1] = ('%s  %s  %s  %d members'):format(t.name, t.state, moment, #t.members)
    for _, m in ipairs(t.members) do
      local p = state.plugins[m]
      local why = p.state == 'loaded' and p.reason or p.err or p.disabled_by or ''
      lines[#lines + 1] = ('  %-28s %-9s %-11s %s'):format(p.name, p.state, p.in_batch and 'batch' or p.load, why)
    end
    lines[#lines + 1] = ''
  end
  local loose = state.list(function(p)
    return p.team == nil
  end)
  if #loose > 0 then
    lines[#lines + 1] = 'in no team'
    for _, p in ipairs(loose) do
      lines[#lines + 1] = ('  %-28s %-9s %-11s %s'):format(p.name, p.state, p.load, p.reason or p.err or '')
    end
  end
  return lines
end

---@return string[]
function M.profile()
  local times = state.times
  local lines = {
    'team.nvim profile',
    '',
    ('setup %s: specs %s, vim.pack %s, init %s, now %s'):format(
      ms(times.setup),
      ms(times.specs),
      ms(times.pack),
      ms(times.init),
      ms(times.now)
    ),
    '',
    'teams, slowest first',
  }
  local teams = vim.tbl_map(function(n)
    return state.teams[n]
  end, state.team_order)
  table.sort(teams, function(a, b)
    return M.team_cost(a) > M.team_cost(b)
  end)
  for _, t in ipairs(teams) do
    local hooks = 0
    for _, h in pairs(t.hooks or {}) do
      hooks = hooks + h
    end
    lines[#lines + 1] = ('  %-20s %-9s %12s  hooks %s'):format(t.name, t.state, ms(M.team_cost(t)), ms(hooks))
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'plugins, slowest first'
  local loaded = state.list(function(p)
    return p.time ~= nil
  end)
  table.sort(loaded, function(a, b)
    return M.cost(a) > M.cost(b)
  end)
  for _, p in ipairs(loaded) do
    lines[#lines + 1] = ('  %-28s %-12s %12s  packadd %s  config %s  %s'):format(
      p.name,
      p.team or '-',
      ms(M.cost(p)),
      ms(p.time.packadd),
      ms(p.time.config),
      p.reason or ''
    )
  end
  return lines
end

---@return string[]
function M.log()
  local lines = { 'team.nvim log', '' }
  for _, e in ipairs(log.entries) do
    local msg = e.msg:gsub('\n', ' ')
    lines[#lines + 1] = ('%9.2f  %-5s  %s'):format(e.ms, level_names[e.level] or '?', msg)
  end
  return lines
end

--- Show a view: refresh its buffer if it is open, else open it in a split at the bottom.
---@param name 'status'|'profile'|'log'
---@return integer buf
function M.open(name)
  local lines = M[name]()
  local bufname = 'team://' .. name
  local buf = vim.fn.bufnr(bufname)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, bufname)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype = 'team' .. name
    vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf, desc = 'team.nvim: close' })
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd(('botright %dsplit'):format(math.min(#lines, math.floor(vim.o.lines / 2))))
    vim.api.nvim_win_set_buf(0, buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  return buf
end

return M
