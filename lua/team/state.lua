-- The session: the graph's team and plugin records, and what happens to them. Only
-- pack.lua and loader.lua change a state, through set() and set_team().

local events = require('team.events')

local M = {}

---@type table<string, team.Team>
M.teams = {}
---@type table<string, team.Plugin>
M.plugins = {}
---@type string[]
M.team_order = {}
---@type string[]
M.order = {}
---@type team.Config?
M.config = nil
--- ms each step of setup() took
---@type table<string, number>
M.times = {}
--- Plugins loaded so far, for each one's `seq`.
M.loaded = 0

---@param g team.Graph
---@param config team.Config
function M.init(g, config)
  M.teams, M.plugins, M.team_order, M.order = g.teams, g.plugins, g.team_order, g.order
  M.config = config
end

---@param p team.Plugin
---@param s team.PluginState
---@param err? string
function M.set(p, s, err)
  if p.state == s and (err == nil or err == p.err) then
    return
  end
  p.state, p.err = s, err or p.err
  if s == 'loaded' then
    M.loaded = M.loaded + 1
    p.seq = M.loaded
  end
  events.emit(events.names.State, { plugin = p.name, team = p.team, state = s })
end

--- Tell listeners a plugin changed without a new state: its build started or ended.
---@param p team.Plugin
function M.touch(p)
  events.emit(events.names.State, { plugin = p.name, team = p.team, state = p.state })
end

---@param t team.Team
---@param s team.TeamState
---@param err? string
function M.set_team(t, s, err)
  if t.state == s then
    return
  end
  t.state, t.err = s, err or t.err
  events.emit(events.names.State, { team = t.name, state = s })
end

--- Plugins in load order, with `fn` true.
---@param fn? fun(p: team.Plugin): boolean
---@return team.Plugin[]
function M.list(fn)
  local res = {}
  for _, name in ipairs(M.order) do
    local p = M.plugins[name]
    if not fn or fn(p) then
      res[#res + 1] = p
    end
  end
  return res
end

return M
