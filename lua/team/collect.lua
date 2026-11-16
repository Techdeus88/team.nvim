-- Read every team definition and plugin spec, in read order: setup() teams by name, then
-- team files sorted by path, then plugin spec roots in the order given. Nothing is merged
-- or checked here beyond shape; graph.lua does that.

local M = {}

---@class team.TeamFields
---@field plugins? (string|table)[]
---@field load? team.Load
---@field event? string|string[]
---@field ft? string|string[]
---@field cmd? string|string[]
---@field keys? string|(string|team.Key)[]
---@field deps? string|string[] teams this one needs
---@field enabled? boolean|fun(t: team.Team): boolean
---@field cond? boolean|fun(t: team.Team): boolean
---@field init? fun(t: team.Team)
---@field pre? fun(t: team.Team)
---@field post? fun(t: team.Team)

---@class team.TeamDef
---@field name string
---@field fields table<string, any> without `plugins`
---@field origin team.Origin

---@class team.Entry
---@field spec any as written
---@field origin team.Origin
---@field team? string the team whose `plugins` list or folder holds it

---@class team.Collected
---@field teams team.TeamDef[] in read order; a name can come more than once
---@field entries team.Entry[] in read order
---@field broken string[] files that failed to load

--- Whether a value is one spec rather than a list of them.
---@param v any
---@return boolean
local function is_single(v)
  return type(v) == 'string' or v.src ~= nil or (type(v[1]) == 'string' and v[2] == nil)
end

--- Add a spec, or each spec of a list, to `out`.
---@param out team.Entry[]
---@param value any
---@param origin team.Origin
---@param team? string
local function push(out, value, origin, team)
  if type(value) ~= 'table' and type(value) ~= 'string' then
    error(('%s: expected a spec or a list of specs, got %s'):format(origin.file, type(value)), 0)
  end
  if is_single(value) then
    out[#out + 1] = { spec = value, origin = origin, team = team }
    return
  end
  for i, s in ipairs(value) do
    out[#out + 1] = { spec = s, origin = { file = origin.file, index = i }, team = team }
  end
end

--- A team table: its fields, and its plugins as entries.
---@param res team.Collected
---@param name string
---@param value any
---@param origin team.Origin
---@param notes team.Notes
local function add_team(res, name, value, origin, notes)
  if type(value) ~= 'table' or value[1] ~= nil then
    local msg = 'team `%s` should be a table like { load = ..., plugins = { ... } }; it is ignored'
    notes:error(origin, msg:format(name))
    return
  end
  local fields = {}
  for k, v in pairs(value) do
    if k ~= 'plugins' then
      fields[k] = v
    end
  end
  res.teams[#res.teams + 1] = { name = name, fields = fields, origin = origin }
  local plugins = value.plugins
  if plugins == nil then
    return
  end
  if type(plugins) ~= 'table' then
    notes:error(origin, ('team `%s`: `plugins` should be a list of specs; it is ignored'):format(name))
    return
  end
  for i, s in ipairs(plugins) do
    res.entries[#res.entries + 1] = { spec = s, origin = { file = origin.file, index = i }, team = name }
  end
end

--- Lua files under a root, sorted, each with its path under the root.
---@param root string a module path like 'plugins', or a folder starting with / ~ or .
---@param top boolean also the module file itself, like lua/plugins.lua
---@return { file: string, rel: string }[]
local function files(root, top)
  local found, under
  if root:find('^[/~.]') then
    local dir = vim.fs.normalize(vim.fs.abspath(vim.fs.normalize(root)))
    found = vim.fn.globpath(dir, '**/*.lua', true, true)
    under = '^' .. vim.pesc(dir) .. '/(.+)$'
  else
    local path = root:gsub('%.', '/')
    found = vim.api.nvim_get_runtime_file(('lua/%s/**/*.lua'):format(path), true)
    if top then
      vim.list_extend(found, vim.api.nvim_get_runtime_file(('lua/%s.lua'):format(path), true))
    end
    under = '^.*/lua/' .. vim.pesc(path) .. '/(.+)$'
  end
  local res = {}
  for _, file in ipairs(found) do
    file = vim.fs.normalize(file)
    res[#res + 1] = { file = file, rel = file:match(under) or vim.fs.basename(file) }
  end
  table.sort(res, function(a, b)
    return a.file < b.file
  end)
  return res
end

--- Run a Lua file and return what it returns.
---@param file string
---@return boolean ok
---@return any value or the error
local function run(file)
  -- loadfile, not require: package.loaded never holds a stale copy when files are read again.
  local chunk, err = loadfile(file)
  if not chunk then
    return false, err
  end
  return pcall(chunk)
end

---@param res team.Collected
---@param file string
---@param err any
---@param notes team.Notes
local function broken(res, file, err, notes)
  res.broken[#res.broken + 1] = file
  notes:error(nil, tostring(err))
end

--- Every team definition and spec entry.
---@param config team.Config
---@param origin team.Origin the file that called setup()
---@param notes team.Notes
---@return team.Collected
function M.collect(config, origin, notes)
  ---@type team.Collected
  local res = { teams = {}, entries = {}, broken = {} }

  local names = vim.tbl_keys(config.teams)
  table.sort(names)
  for _, name in ipairs(names) do
    add_team(res, name, config.teams[name], origin, notes)
  end

  -- lua/teams/git.lua is team `git`; every file under lua/teams/lsp/ holds specs of team
  -- `lsp`, and the folder alone defines the team.
  if config.teams_dir then
    for _, f in ipairs(files(config.teams_dir, false)) do
      local ok, value = run(f.file)
      local folder = f.rel:match('^([^/]+)/')
      local defined = vim.iter(res.teams):any(function(d) ---@param d team.TeamDef
        return d.name == folder
      end)
      if folder and not defined then
        local dir = f.file:sub(1, #f.file - #f.rel + #folder)
        res.teams[#res.teams + 1] = { name = folder, fields = {}, origin = { file = dir } }
      end
      if not ok then
        broken(res, f.file, value, notes)
      elseif folder then
        ok, value = pcall(push, res.entries, value, { file = f.file }, folder)
        if not ok then
          broken(res, f.file, value, notes)
        end
      else
        add_team(res, (f.rel:gsub('%.lua$', '')), value, { file = f.file }, notes)
      end
    end
  end

  for _, root in ipairs(config.spec) do
    if type(root) == 'table' then
      local ok, err = pcall(push, res.entries, root, origin)
      if not ok then
        notes:error(nil, tostring(err))
      end
    elseif type(root) ~= 'string' then
      notes:warn(origin, ('setup(): `spec` holds a %s; it is ignored'):format(type(root)))
    else
      for _, f in ipairs(files(root, true)) do
        local ok, value = run(f.file)
        if ok then
          ok, value = pcall(push, res.entries, value, { file = f.file })
        end
        if not ok then
          broken(res, f.file, value, notes)
        end
      end
    end
  end
  return res
end

return M
