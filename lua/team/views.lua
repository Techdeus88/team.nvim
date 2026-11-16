-- The text of the window's Profile and Log views, and load costs.

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

--- Load costs as tables: setup's steps, then teams and plugins, slowest first. Columns
--- are as wide as what is in them, numbers in ms, so a narrow window keeps the numbers.
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
  }
  local tw = 4
  for _, name in ipairs(state.team_order) do
    tw = math.max(tw, #name)
  end
  tw = math.min(tw, 20)
  local teams = vim.tbl_map(function(n)
    return state.teams[n]
  end, state.team_order)
  table.sort(teams, function(a, b)
    return M.team_cost(a) > M.team_cost(b)
  end)
  local team_row = '  %-' .. tw .. 's  %-9s %8s %8s'
  lines[#lines + 1] = team_row:format('team', 'state', 'ms', 'hooks')
  for _, t in ipairs(teams) do
    local hooks = 0
    for _, h in pairs(t.hooks or {}) do
      hooks = hooks + h
    end
    lines[#lines + 1] = team_row:format(t.name, t.state, ('%.2f'):format(M.team_cost(t)), ('%.2f'):format(hooks))
  end
  lines[#lines + 1] = ''
  local loaded = state.list(function(p)
    return p.time ~= nil
  end)
  table.sort(loaded, function(a, b)
    return M.cost(a) > M.cost(b)
  end)
  local pw = 6
  for _, p in ipairs(loaded) do
    pw = math.max(pw, #p.name)
  end
  pw = math.min(pw, 28)
  local plugin_row = '  %-' .. pw .. 's  %-' .. tw .. 's %8s %8s %8s  %s'
  lines[#lines + 1] = plugin_row:format('plugin', 'team', 'ms', 'packadd', 'config', 'why')
  for _, p in ipairs(loaded) do
    lines[#lines + 1] = plugin_row:format(
      p.name,
      p.team or '-',
      ('%.2f'):format(M.cost(p)),
      ('%.2f'):format(p.time.packadd or 0),
      ('%.2f'):format(p.time.config or 0),
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

return M
