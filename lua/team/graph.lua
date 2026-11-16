-- From collected teams and specs to the plan of the session: one record per team and per
-- plugin, who is in which team, what each plugin inherits, each team's batch, and the
-- order everything loads in. Pure: problems go to the notes, with a fallback.

local spec = require('team.spec')

local M = {}

-- graph.lua sets `pending` or `disabled`; pack.lua and loader.lua move them on from there.
---@alias team.TeamState 'pending'|'partial'|'loaded'|'failed'|'disabled'
---@alias team.PluginState 'pending'|'missing'|'installed'|'loading'|'loaded'|'failed'|'disabled'

---@class team.Times
---@field packadd? number ms
---@field config? number ms: opts, config or setup(), and after

---@class team.Team
---@field name string
---@field origin team.Origin where it was first defined
---@field index integer read order
---@field load? team.Load
---@field event? string[]|false
---@field ft? string[]|false
---@field cmd? string[]|false
---@field keys? (string|team.Key)[]|false
---@field after_team? string[]|false teams whose batch loading loads this team's batch
---@field order? number its place among teams, lower first; teams without one come after
---@field deps string[] teams this one needs, every one defined and with a strategy
---@field enabled? boolean|fun(t: team.Team): boolean
---@field cond? boolean|fun(t: team.Team): boolean
---@field init? fun(t: team.Team)
---@field pre? fun(t: team.Team)
---@field post? fun(t: team.Team)
---@field strategy boolean it sets `load` or a trigger, so it has a moment of its own
---@field when? team.Load its batch's moment: its own, or earlier when a team that needs it pulls it
---@field pulled_by? string the team whose need moved `when` earlier
---@field members string[] in declaration order
---@field batch string[] the members that load at the team's moment, in declaration order
---@field state team.TeamState
---@field disabled_by? string
---@field ready? true its deps' batches have loaded and `pre` has run
---@field hooks? table<string, number> ms each team hook took
---@field err? string why it failed

---@class team.Plugin
---@field name string
---@field spec team.Spec every spec of the plugin, merged
---@field origin team.Origin where it was first declared
---@field index integer declaration order
---@field container? string the team whose list or folder holds it
---@field team? string the team it is in
---@field dep_only? true only ever named as a dependency
---@field deps string[] plugins that load before it
---@field load team.Load
---@field load_from? string the team its `load` came from
---@field inherited table<string, true> fields it took from its team
---@field triggers table<string, any[]> the triggers that load it, only non-empty ones
---@field very_lazy? true lazy.nvim's VeryLazy beside other events: loads with `later` at the latest
---@field in_batch? true
---@field state team.PluginState
---@field disabled_by? string
---@field path? string set once vim.pack reports it on disk
---@field reason? string what loaded it, like `startup` or `dependency of telescope.nvim`
---@field seq? integer its place in the order plugins loaded this session
---@field time? team.Times
---@field err? string why it failed or is missing
---@field did_init? true its `init` has run this session

---@class team.Graph
---@field teams table<string, team.Team>
---@field team_order string[] needed teams first, ties in read order
---@field plugins table<string, team.Plugin>
---@field order string[] every plugin: teams in order, members in declaration order, deps first

---@type table<string, integer>
M.rank = { now = 1, now_if_args = 2, later = 3, trigger = 4 }
local by_rank = { 'now', 'now_if_args', 'later', 'trigger' }

-- The load strategy a team gives its members, in the order it is applied.
local strategy = { 'load', 'event', 'ft', 'cmd', 'keys', 'after_team' }

---@param v any
---@return boolean
local function hook(v)
  return vim.is_callable(v)
end

---@type table<string, { [1]: (fun(v: any): boolean), [2]: string }>
local team_checks = {
  enabled = {
    function(v)
      return type(v) == 'boolean' or vim.is_callable(v)
    end,
    'a boolean or a function',
  },
  init = { hook, 'a function' },
  pre = { hook, 'a function' },
  post = { hook, 'a function' },
  order = {
    function(v)
      return type(v) == 'number'
    end,
    'a number',
  },
}
team_checks.cond = team_checks.enabled

---@param name string
---@param msg string
---@return string
local function about(name, msg)
  return ('`%s` %s'):format(name, msg)
end

--- Whether a set of trigger fields holds any trigger.
---@param t table
---@return boolean
local function triggered(t)
  for _, k in ipairs(spec.triggers) do
    local v = t[k]
    if type(v) == 'table' and #v > 0 then
      return true
    end
  end
  return false
end

--- Take lazy.nvim's VeryLazy out of `event`: alone it means `later`, beside other events it
--- is a deadline.
---@param t table trigger fields, changed in place
---@return boolean very_lazy
local function strip_very_lazy(t)
  if type(t.event) ~= 'table' then
    return false
  end
  local kept = vim.tbl_filter(function(e)
    return e ~= 'VeryLazy'
  end, t.event)
  local found = #kept < #t.event
  t.event = kept
  return found
end

--- Add a definition's fields to its team. Later definitions win field by field; `deps`
--- keep every entry.
---@param t team.Team
---@param def team.TeamDef
---@param notes team.Notes
local function define(t, def, notes)
  local unknown = {}
  for k, v in pairs(def.fields) do
    local check = team_checks[k]
    if type(k) ~= 'string' then
      unknown[#unknown + 1] = tostring(k)
    elseif k == 'load' then
      if spec.loads[v] then
        t.load = v
      else
        notes:warn(def.origin, ('team `%s` has unknown load `%s`; it is ignored'):format(def.name, tostring(v)))
      end
    elseif vim.list_contains(spec.triggers, k) then
      local value, want = spec.trigger(k, v)
      if want then
        notes:warn(def.origin, ('team `%s`: `%s` should be %s; it is ignored'):format(def.name, k, want))
      else
        t[k] = value
      end
    elseif k == 'deps' then
      local list = type(v) == 'string' and { v } or v
      local ok = type(list) == 'table'
      for _, d in ipairs(ok and list or {}) do
        ok = ok and type(d) == 'string'
      end
      if not ok then
        notes:warn(def.origin, ('team `%s`: `deps` should be a list of team names; it is ignored'):format(def.name))
      else
        for _, d in ipairs(list) do
          if not vim.list_contains(t.deps, d) then
            t.deps[#t.deps + 1] = d
          end
        end
      end
    elseif check then
      if check[1](v) then
        t[k] = v
      else
        local msg = 'team `%s`: `%s` should be %s, got %s; it is ignored'
        notes:warn(def.origin, msg:format(def.name, k, check[2], type(v)))
      end
    else
      unknown[#unknown + 1] = k
    end
  end
  table.sort(unknown)
  for _, k in ipairs(unknown) do
    notes:warn(def.origin, ('team `%s` has unknown field `%s`; it is ignored'):format(def.name, k))
  end
end

--- Whether `enabled` and `cond` leave something on. A function that raises leaves it on.
---@param r team.Team|team.Plugin
---@param what string how a message names it
---@param notes team.Notes
---@return boolean on
---@return string? by the field that turned it off
local function enabled(r, what, notes)
  local fields = r.spec or r
  for _, k in ipairs({ 'enabled', 'cond' }) do
    local v = fields[k]
    if vim.is_callable(v) then
      local ok, res = pcall(v, r)
      if not ok then
        notes:warn(r.origin, ('%s: `%s` raised an error, so it stays on: %s'):format(what, k, tostring(res)))
        v = true
      else
        v = res
      end
    end
    if v == false then
      return false, k
    end
  end
  return true
end

--- Sort records by `order`, lower first, those without one last; ties by `index`.
---@generic T: team.Team|team.Plugin
---@param list T[]
---@param order_of fun(r: T): number?
---@return T[] the same list
local function by_order(list, order_of)
  table.sort(list, function(a, b)
    local oa, ob = order_of(a) or math.huge, order_of(b) or math.huge
    if oa ~= ob then
      return oa < ob
    end
    return a.index < b.index
  end)
  return list
end

--- Visit nodes deps first, in the order given. An edge that closes a cycle is dropped,
--- with a warning.
---@param names string[] in tie-break order
---@param deps_of fun(name: string): string[] the node's deps, which the visit may shorten
---@param cycle fun(path: string[], from: string, to: string)
---@return string[]
local function deps_first(names, deps_of, cycle)
  local mark, path, out = {}, {}, {}
  local function visit(name)
    mark[name] = 'open'
    path[#path + 1] = name
    local deps = deps_of(name)
    local i = 1
    while i <= #deps do
      local d = deps[i]
      if mark[d] == 'open' then
        local from = 1
        while path[from] ~= d do
          from = from + 1
        end
        local loop = vim.list_slice(path, from)
        loop[#loop + 1] = d
        cycle(loop, name, d)
        table.remove(deps, i)
      else
        if not mark[d] then
          visit(d)
        end
        i = i + 1
      end
    end
    path[#path] = nil
    mark[name] = 'done'
    out[#out + 1] = name
  end
  for _, name in ipairs(names) do
    if not mark[name] then
      visit(name)
    end
  end
  return out
end

--- Build the graph.
---@param collected team.Collected
---@param notes team.Notes
---@return team.Graph
function M.build(collected, notes)
  ---@type team.Graph
  local g = { teams = {}, team_order = {}, plugins = {}, order = {} }

  -- Teams: one name is one team, its definitions merged in read order.
  local team_list = {} ---@type team.Team[]
  local function new_team(name, origin)
    local t = { name = name, origin = origin, index = #team_list + 1, deps = {}, members = {}, batch = {} }
    g.teams[name], team_list[#team_list + 1] = t, t
    return t
  end
  for _, def in ipairs(collected.teams) do
    define(g.teams[def.name] or new_team(def.name, def.origin), def, notes)
  end
  if not g.teams.default then
    new_team('default', { file = 'team.nvim' })
  end

  -- Plugins: top-level specs first, in read order, then the specs nested in `deps`, which
  -- apply over a plugin's own spec whichever file holds it.
  local plugin_list = {} ---@type team.Plugin[]
  local nested = {} ---@type { spec: team.Spec, origin: team.Origin }[]

  ---@param s team.Spec
  ---@param origin team.Origin
  ---@param container? string
  ---@param is_dep boolean
  local function add(s, origin, container, is_dep)
    local deps = {}
    for _, d in ipairs(s.deps or {}) do
      if spec.is_ref(d) then
        deps[#deps + 1] = d
      else
        local ds = spec.normalize(d, origin, notes)
        if ds then
          deps[#deps + 1] = ds.name
          nested[#nested + 1] = { spec = ds, origin = origin }
        end
      end
    end
    s.deps = nil
    local p = g.plugins[s.name]
    if not p then
      ---@diagnostic disable-next-line: missing-fields
      p = { name = s.name, spec = s, origin = origin, index = #plugin_list + 1, deps = {}, container = container }
      p.dep_only = is_dep or nil
      g.plugins[s.name], plugin_list[#plugin_list + 1] = p, p
    else
      if not (is_dep and spec.only_names(s)) then
        p.spec = spec.merge(p.spec, s)
      end
      if not is_dep then
        p.dep_only = nil
      end
      if container and p.container and p.container ~= container then
        local msg = 'is already in team `%s`; team `%s` is ignored'
        notes:warn(origin, about(p.name, msg:format(p.container, container)))
      end
      p.container = p.container or container
    end
    for _, d in ipairs(deps) do
      if not vim.list_contains(p.deps, d) then
        p.deps[#p.deps + 1] = d
      end
    end
  end

  for _, e in ipairs(collected.entries) do
    local s = spec.normalize(e.spec, e.origin, notes)
    if s then
      add(s, e.origin, e.team, false)
    end
  end
  local i = 1
  while nested[i] do
    add(nested[i].spec, nested[i].origin, nil, true)
    i = i + 1
  end

  -- Bare-name deps can point at a spec declared later, so they are checked once all are in.
  for _, p in ipairs(plugin_list) do
    for j = #p.deps, 1, -1 do
      local d = p.deps[j]
      if d == p.name then
        notes:warn(p.origin, about(p.name, 'depends on itself; it is ignored'))
        table.remove(p.deps, j)
      elseif not g.plugins[d] then
        notes:warn(p.origin, about(p.name, ('depends on `%s`, which no spec declares'):format(d)))
        table.remove(p.deps, j)
      end
    end
  end

  -- Membership: the spec's own `team`, else the team that lists it, else `default`.
  -- A plugin only ever named as a dependency is in no team unless its spec says so.
  for _, p in ipairs(plugin_list) do
    local own = p.spec.team
    if type(own) == 'string' and not g.teams[own] then
      notes:warn(p.origin, about(p.name, ('names team `%s`, which nothing defines; it is ignored'):format(own)))
      own = nil
    end
    if own == false then
      p.team = nil
    elseif own then
      p.team = own
    elseif p.container then
      p.team = p.container
    elseif not p.dep_only then
      p.team = 'default'
    end
  end
  -- Each team's members by `order`, then declaration order.
  local sorted = by_order(vim.list_slice(plugin_list), function(p)
    return p.spec.order
  end)
  for _, p in ipairs(sorted) do
    if p.team then
      local t = g.teams[p.team]
      t.members[#t.members + 1] = p.name
    end
  end

  -- On or off: a team that is off turns off its members.
  for _, t in ipairs(team_list) do
    local on, by = enabled(t, ('team `%s`'):format(t.name), notes)
    t.state, t.disabled_by = on and 'pending' or 'disabled', by
  end
  for _, p in ipairs(plugin_list) do
    local t = p.team and g.teams[p.team]
    local on, by = enabled(p, ('`%s`'):format(p.name), notes)
    if t and t.state == 'disabled' then
      on, by = false, ('team `%s`'):format(t.name)
    end
    p.state, p.disabled_by = on and 'pending' or 'disabled', by
  end
  -- A plugin only ever named as a dependency is off once nothing that is on needs it.
  local changed = true
  while changed do
    changed = false
    local needed = {}
    for _, p in ipairs(plugin_list) do
      if p.state ~= 'disabled' then
        for _, d in ipairs(p.deps) do
          needed[d] = true
        end
      end
    end
    for _, p in ipairs(plugin_list) do
      if p.dep_only and p.state ~= 'disabled' and not needed[p.name] then
        p.state, p.disabled_by, changed = 'disabled', 'unneeded', true
      end
    end
  end
  for _, p in ipairs(plugin_list) do
    for _, d in ipairs(p.state ~= 'disabled' and p.deps or {}) do
      local dp = g.plugins[d]
      if dp.state == 'disabled' and not dp.dep_only then
        notes:warn(p.origin, about(p.name, ('depends on `%s`, which is disabled'):format(d)))
      end
    end
  end

  -- `after_team` names a team that is defined and, on a team, not itself.
  ---@param list string[]|false|nil
  ---@param self? string a team's own name
  ---@param origin team.Origin
  ---@param who string
  ---@return string[]|false|nil
  local function check_after(list, self, origin, who)
    if type(list) ~= 'table' then
      return list
    end
    local kept = {}
    for _, name in ipairs(list) do
      local why = name == self and 'itself'
        or not g.teams[name] and ('team `%s`, which nothing defines'):format(name)
        or nil
      if why then
        notes:warn(origin, ('%s loads after %s; it is ignored'):format(who, why))
      else
        if g.teams[name].state == 'disabled' then
          notes:warn(origin, ('%s loads after team `%s`, which is disabled'):format(who, name))
        end
        kept[#kept + 1] = name
      end
    end
    return kept
  end
  for _, t in ipairs(team_list) do
    t.after_team = check_after(t.after_team, t.name, t.origin, ('team `%s`'):format(t.name))
  end
  for _, p in ipairs(plugin_list) do
    p.spec.after_team = check_after(p.spec.after_team, nil, p.origin, ('`%s`'):format(p.name))
  end

  -- Each team's own moment, from its strategy.
  for _, t in ipairs(team_list) do
    local fields = { event = t.event, ft = t.ft, cmd = t.cmd, keys = t.keys, after_team = t.after_team }
    local very_lazy = strip_very_lazy(fields)
    t.strategy = t.load ~= nil or triggered(fields) or very_lazy
    t.when = t.load or (triggered(fields) and 'trigger') or (very_lazy and 'later') or nil
  end

  -- Inheritance, field by field, and each plugin's `load`.
  for _, p in ipairs(plugin_list) do
    local t = p.team and g.teams[p.team]
    local own = p.spec.load
    local s = p.spec
    local r = { load = own, event = s.event, ft = s.ft, cmd = s.cmd, keys = s.keys, after_team = s.after_team }
    p.inherited = {}
    if t and t.strategy then
      -- A member's own `load` other than 'trigger' takes none of the team's triggers.
      for _, k in ipairs(strategy) do
        local v = t[k]
        if v ~= nil and r[k] == nil and (k == 'load' or own == nil or own == 'trigger') then
          r[k] = type(v) == 'table' and vim.deepcopy(v) or v
          p.inherited[k] = true
        end
      end
    end
    local very_lazy = strip_very_lazy(r)
    local has_trigger = triggered(r)
    local load = r.load
    p.load_from = p.inherited.load and t and t.name or nil
    if load == nil then
      load = (has_trigger or p.dep_only) and 'trigger' or 'later'
    elseif load ~= 'trigger' and has_trigger then
      local msg = p.load_from
          and ('is in team `%s` with load = `%s`, so its triggers are ignored'):format(p.load_from, load)
        or ('sets load = `%s`, so its triggers are ignored'):format(load)
      notes:warn(p.origin, about(p.name, msg))
      has_trigger = false
    end
    p.load = load
    p.triggers = {}
    for _, k in ipairs(has_trigger and spec.triggers or {}) do
      if type(r[k]) == 'table' and #r[k] > 0 then
        p.triggers[k] = r[k] --[[@as any[] ]]
      end
    end
    p.very_lazy = (very_lazy and load == 'trigger') or nil
    -- In the batch: it takes the team's moment, because it set no `load` and took the
    -- team's `load` or one of its triggers.
    local took = false
    for _, k in ipairs(strategy) do
      took = took or p.inherited[k] == true
    end
    if t and t.strategy and own == nil and took and p.state ~= 'disabled' then
      p.in_batch = true
    end
  end
  for _, t in ipairs(team_list) do
    t.batch = vim.tbl_filter(function(name)
      return g.plugins[name].in_batch == true
    end, t.members)
  end

  -- Team deps: each one defined, not itself, with a moment of its own; then the order.
  for _, t in ipairs(team_list) do
    for j = #t.deps, 1, -1 do
      local d = t.deps[j]
      local dt = g.teams[d]
      local why = d == t.name and 'itself'
        or not dt and ('team `%s`, which nothing defines'):format(d)
        or not dt.strategy and ('team `%s`, which has no load or trigger of its own'):format(d)
      if why then
        notes:warn(t.origin, ('team `%s` needs %s; it is ignored'):format(t.name, why))
        table.remove(t.deps, j)
      elseif dt.state == 'disabled' and t.state ~= 'disabled' then
        notes:warn(t.origin, ('team `%s` needs team `%s`, which is disabled'):format(t.name, d))
      end
    end
  end
  local names = vim.tbl_map(
    function(t)
      return t.name
    end,
    by_order(vim.list_slice(team_list), function(t)
      return t.order
    end)
  )
  g.team_order = deps_first(names, function(name)
    return g.teams[name].deps
  end, function(loop, from, to)
    local msg = 'teams form a cycle: %s; `%s` no longer needs `%s`'
    notes:warn(g.teams[from].origin, msg:format(table.concat(loop, ' -> '), from, to))
  end)

  -- A team loads no later than the earliest member of a team that needs it. Dependents
  -- come first, so a pull carries on down the chain.
  ---@param t team.Team
  ---@return integer?
  local function earliest(t)
    local best = #t.batch > 0 and t.when and M.rank[t.when] or nil
    for _, name in ipairs(t.members) do
      local p = g.plugins[name]
      if p.state ~= 'disabled' and not p.in_batch then
        best = math.min(best or math.huge, M.rank[p.load])
      end
    end
    return best
  end
  local own_when = {} ---@type table<string, team.Load?>
  for _, t in ipairs(team_list) do
    own_when[t.name] = t.when
  end
  for j = #g.team_order, 1, -1 do
    local t = g.teams[g.team_order[j]]
    local need = t.state ~= 'disabled' and earliest(t)
    for _, d in ipairs(need and t.deps or {}) do
      local dt = g.teams[d]
      if M.rank[dt.when] > need then
        dt.when, dt.pulled_by = by_rank[need], t.name
      end
    end
  end
  for _, name in ipairs(g.team_order) do
    local t = g.teams[name]
    if t.pulled_by then
      local msg = 'team `%s` loads at `%s`, not `%s`, because team `%s` needs it'
      notes:warn(t.origin, msg:format(t.name, t.when, own_when[name], t.pulled_by))
    end
  end

  -- Plugins: teams in order, members by `order` then declaration, deps first; then the rest.
  local plugin_names = {}
  for _, name in ipairs(g.team_order) do
    vim.list_extend(plugin_names, g.teams[name].members)
  end
  for _, p in ipairs(sorted) do
    plugin_names[#plugin_names + 1] = p.name
  end
  g.order = deps_first(plugin_names, function(name)
    return g.plugins[name].deps
  end, function(loop, from, to)
    local msg = 'plugins form a cycle: %s; `%s` no longer depends on `%s`'
    notes:warn(g.plugins[from].origin, msg:format(table.concat(loop, ' -> '), from, to))
  end)
  return g
end

return M
