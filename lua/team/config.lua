-- setup() options: the defaults, and a check of what you pass. An option of the wrong
-- type warns and keeps its default; an unknown one warns and is ignored.

local M = {}

---@class team.Opts
---@field teams? table<string, team.TeamFields> teams by name
---@field teams_dir? string|false teams one per file: a module path under lua/ or a folder; false: none
---@field spec? string|(string|table)[] plugin specs: module paths, folders, or specs
---@field confirm? boolean ask before installing; default true
---@field budget? number ms of `later` loading per event-loop tick; default 5

---@class team.Config
---@field teams table<string, team.TeamFields>
---@field teams_dir string|false
---@field spec (string|table)[]
---@field confirm boolean
---@field budget number

---@return team.Config
function M.defaults()
  return { teams = {}, teams_dir = 'teams', spec = { 'plugins' }, confirm = true, budget = 5 }
end

---@type table<string, { [1]: (fun(v: any): boolean), [2]: string }>
local checks = {
  teams = {
    function(v)
      return type(v) == 'table' and (next(v) == nil or not vim.islist(v))
    end,
    'a table of teams by name',
  },
  teams_dir = {
    function(v)
      return v == false or type(v) == 'string'
    end,
    'a module path, a folder or false',
  },
  confirm = {
    function(v)
      return type(v) == 'boolean'
    end,
    'a boolean',
  },
  budget = {
    function(v)
      return type(v) == 'number' and v > 0
    end,
    'a number of ms above 0',
  },
  spec = {
    function(v)
      return type(v) == 'string' or (type(v) == 'table' and vim.islist(v))
    end,
    'a module path, a folder, or a list of them and specs',
  },
}

--- The options to use: yours where they are right, the defaults elsewhere.
---@param opts any what setup() was given
---@param origin team.Origin the file that called setup()
---@param notes team.Notes
---@return team.Config
function M.resolve(opts, origin, notes)
  local res = M.defaults()
  if opts == nil then
    return res
  end
  if type(opts) ~= 'table' then
    notes:warn(origin, ('setup() takes a table, got %s; using the defaults'):format(type(opts)))
    return res
  end
  local unknown = {}
  for k, v in pairs(opts) do
    local check = checks[k]
    if not check then
      unknown[#unknown + 1] = tostring(k)
    elseif check[1](v) then
      res[k] = v
    else
      local msg = 'setup(): `%s` should be %s, got %s; using the default'
      notes:warn(origin, msg:format(k, check[2], type(v)))
    end
  end
  table.sort(unknown)
  for _, k in ipairs(unknown) do
    notes:warn(origin, ('setup(): unknown option `%s`; it is ignored'):format(k))
  end
  local spec = res.spec --[[@as any]]
  if type(spec) == 'string' then
    res.spec = { spec }
  end
  return res
end

return M
