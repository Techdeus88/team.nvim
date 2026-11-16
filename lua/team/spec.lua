-- Plugin specs: turn what you write into one shape, and merge specs of the same plugin.
-- The fields and their meanings are cinch.nvim's, plus `team`. Nothing here touches the
-- editor; problems go to the notes it is given, and the spec carries on without them.

local M = {}

---@alias team.Load 'now'|'later'|'now_if_args'|'trigger'

---@class team.Key: vim.keymap.set.Opts
---@field [1] string lhs
---@field [2]? string|function rhs; omitted when the plugin maps lhs itself
---@field mode? string|string[] default 'n'

---A spec after normalize(): one shape, whatever form it was written in.
---@class team.Spec
---@field src string
---@field name string
---@field version? string|vim.VersionRange
---@field data? table your own data, passed to vim.pack
---@field team? string|false the team it is in; false: none
---@field load? team.Load
---@field event? string[]|false
---@field ft? string[]|false
---@field cmd? string[]|false
---@field keys? (string|team.Key)[]|false
---@field after_team? string[]|false teams whose batch loading loads it
---@field order? number its place among its team's members, lower first
---@field deps? (string|table)[] a bare name like 'plenary.nvim' refers to another spec
---@field enabled? boolean|fun(p: team.Plugin): boolean
---@field cond? boolean|fun(p: team.Plugin): boolean
---@field init? fun(p: team.Plugin)
---@field build? string|fun(p: team.Plugin, done?: fun(ok: boolean, msg?: string))
---@field opts_parts? (table|function)[] every `opts` given for the plugin, in read order
---@field main? string
---@field config? true|fun(p: team.Plugin, opts: table)
---@field after? fun(p: team.Plugin)
---@field module? boolean

---@type table<string, true>
M.loads = { now = true, later = true, now_if_args = true, trigger = true }

--- Trigger fields, in the order they are read. `after_team`: load once that team's batch has.
M.triggers = { 'event', 'ft', 'cmd', 'keys', 'after_team' }

---@param v any
---@return boolean
local function callable(v)
  return vim.is_callable(v)
end

--- Each field: whether a value is right, and what it should be, for the warning.
---@type table<string, { [1]: (fun(v: any): boolean), [2]: string }>
local checks = {
  team = {
    function(v)
      return v == false or type(v) == 'string'
    end,
    'a team name or false',
  },
  load = {
    function(v)
      return M.loads[v] ~= nil
    end,
    "'now', 'later', 'now_if_args' or 'trigger'",
  },
  deps = {
    function(v)
      return type(v) == 'table'
    end,
    'a list',
  },
  enabled = {
    function(v)
      return type(v) == 'boolean' or callable(v)
    end,
    'a boolean or a function',
  },
  init = { callable, 'a function' },
  build = {
    function(v)
      return type(v) == 'string' or callable(v)
    end,
    'a string or a function',
  },
  main = {
    function(v)
      return type(v) == 'string'
    end,
    'a string',
  },
  config = {
    function(v)
      return v == true or callable(v)
    end,
    'a function or true',
  },
  after = { callable, 'a function' },
  order = {
    function(v)
      return type(v) == 'number'
    end,
    'a number',
  },
  module = {
    function(v)
      return type(v) == 'boolean'
    end,
    'a boolean',
  },
  opts = {
    function(v)
      return type(v) == 'table' or callable(v)
    end,
    'a table or a function',
  },
}
checks.cond = checks.enabled

local pack_fields = { src = true, name = true, version = true, data = true }
-- Read, then turned into other fields.
local input_fields = { commit = true, tag = true, branch = true, lazy = true, dependencies = true, group = true }

--- Fields a spec may set, besides the triggers.
---@type table<string, true>
M.fields = {}
for k in pairs(checks) do
  M.fields[k] = true
end

-- sarcina's and cinch's order: commit beats tag beats version beats branch.
local pins = { 'commit', 'tag', 'version', 'branch' }

--- `owner/repo` becomes a GitHub URL; anything else is a src as is, a relative path
--- like `./repo` included.
---@param src string
---@return string
function M.expand(src)
  if src:find('^[%w_.-]+/[%w_.-]+$') and not src:find('^%.%.?/') then
    return 'https://github.com/' .. src
  end
  return src
end

--- The plugin name exactly as vim.pack derives it.
---@param src string
---@param name? string
---@return string
function M.name(src, name)
  return (name or src:gsub('%.git$', '')):match('[^/]+$') or ''
end

--- A trigger field's value as a list, `false`, or nil with what it should be.
---@param k string a trigger field
---@param v any
---@return any value
---@return string? want when `v` is not a value `k` takes
function M.trigger(k, v)
  if v == false then
    return false
  elseif type(v) == 'string' then
    return { v }
  elseif type(v) ~= 'table' then
    local want = k == 'keys' and 'a key, a list of keys or false'
      or k == 'after_team' and 'a team name, a list of them or false'
      or 'a string, a list of strings or false'
    return nil, want
  end
  local list = {}
  for _, item in ipairs(v) do
    local ok = type(item) == 'string' or (k == 'keys' and type(item) == 'table' and type(item[1]) == 'string')
    if not ok then
      return nil, k == 'keys' and "a list of keys: '<lhs>' or { '<lhs>', rhs, ... }" or 'a list of strings'
    end
    list[#list + 1] = item
  end
  return list
end

--- `commit`, `tag` and `branch` become `version`, the one field vim.pack reads. A string
--- with characters no git ref can hold is a version range.
---@param s table
---@param warn fun(msg: string)
local function resolve_version(s, warn)
  -- lazy.nvim's `version = false`: follow the default branch.
  if s.version == false then
    s.version = nil
  end
  local won
  for _, k in ipairs(pins) do
    if s[k] ~= nil then
      if won then
        warn(('sets `%s` and `%s`; using `%s`'):format(won, k, won))
      else
        won = k
      end
    end
  end
  if won then
    s.version = s[won]
  end
  s.commit, s.tag, s.branch = nil, nil, nil
  local v = s.version
  if v ~= nil and type(v) ~= 'string' and getmetatable(v) == nil then
    warn('has a `version` that is not a string or vim.version.range(); it is ignored')
    s.version = nil
    return
  end
  if type(v) ~= 'string' then
    return
  end
  if v:find('[%*%^~%s<>=]') then
    local ok, range = pcall(vim.version.range, v)
    if ok and range then
      s.version = range
      return
    end
  elseif not (won == 'version' and v:find('%d%.[xX]')) then
    return
  end
  -- `1.x` can be a branch too, so it is left as written.
  local msg = 'version `%s` looks like a range, which vim.pack reads as a branch or tag; '
    .. "write vim.version.range('%s')"
  warn(msg:format(v, v))
end

--- A spec in one shape, or nil when it has no usable `src` or name. Your table is not
--- changed.
---@param raw any a string src or a spec table
---@param origin team.Origin
---@param notes team.Notes
---@return team.Spec?
function M.normalize(raw, origin, notes)
  if type(raw) == 'string' then
    raw = { raw }
  end
  if type(raw) ~= 'table' then
    notes:error(origin, ('a spec is a string or a table, got %s'):format(type(raw)))
    return
  end
  local s = {} ---@type table<any, any>
  for k, v in pairs(raw) do
    s[k] = v
  end
  if s.src == nil and type(s[1]) == 'string' then
    s.src = s[1]
  end
  s[1] = nil
  if type(s.src) ~= 'string' or s.src == '' then
    notes:error(
      origin,
      ('a spec without `src`: %s'):format(vim.inspect(raw, { depth = 1, newline = ' ', indent = '' }))
    )
    return
  end
  s.src = M.expand(s.src)
  if s.name ~= nil and type(s.name) ~= 'string' then
    notes:error(origin, ('`%s` has a `name` that is not a string; it is ignored'):format(s.src))
    s.name = nil
  end
  local name = M.name(s.src, s.name)
  if name == '' then
    notes:error(origin, ('no plugin name in `%s`'):format(s.src))
    return
  end
  s.name = name

  ---@param msg string
  local function warn(msg)
    notes:warn(origin, ('`%s` %s'):format(name, msg))
  end

  -- cinch fields can sit inside `data`, the way vim.pack.Spec holds extra fields; there
  -- they win. The rest of `data` is yours and stays.
  if type(s.data) == 'table' then
    local data = {}
    for k, v in pairs(s.data) do
      if M.fields[k] or input_fields[k] or vim.list_contains(M.triggers, k) then
        s[k] = v
      else
        data[k] = v
      end
    end
    s.data = next(data) and data or nil
  elseif s.data ~= nil then
    warn('has a `data` that is not a table; it is ignored')
    s.data = nil
  end

  resolve_version(s, warn)
  if s.group ~= nil then
    notes:info(nil, 'specs name their team with `team`; `group` is read as `team`')
    if s.team == nil then
      s.team = s.group
    end
    s.group = nil
  end
  -- lazy.nvim's `lazy`: false loads at startup, true only when something asks for it.
  if type(s.lazy) == 'boolean' and s.load == nil then
    s.load = s.lazy and 'trigger' or 'now'
  end
  s.lazy = nil
  if s.deps == nil then
    s.deps = s.dependencies
  end
  s.dependencies = nil

  local out = { src = s.src, name = name, version = s.version, data = s.data } ---@type team.Spec
  local unknown = {}
  for k, v in pairs(s) do
    if type(k) ~= 'string' then
      warn(('has an extra list item `%s`; it is ignored'):format(tostring(v)))
    elseif vim.list_contains(M.triggers, k) then
      local value, want = M.trigger(k, v)
      if want then
        warn(('field `%s` should be %s; it is ignored'):format(k, want))
      else
        out[k] = value
      end
    elseif checks[k] then
      if not checks[k][1](v) then
        local msg = k == 'load' and ('has unknown load `%s`; it is ignored'):format(tostring(v))
          or ('field `%s` should be %s, got %s; it is ignored'):format(k, checks[k][2], type(v))
        warn(msg)
      elseif k == 'opts' then
        out.opts_parts = { v }
      else
        out[k] = v
      end
    elseif not pack_fields[k] then
      unknown[#unknown + 1] = k
    end
  end
  table.sort(unknown)
  for _, k in ipairs(unknown) do
    warn(('has unknown field `%s`; it is ignored'):format(k))
  end
  return out
end

--- Whether a dependency is a bare name that refers to another spec, not a spec itself.
---@param d any
---@return boolean
function M.is_ref(d)
  return type(d) == 'string' and not d:find('/') and not d:find(':')
end

--- Whether a spec only names its plugin, like `deps = { 'owner/repo' }`, and sets nothing.
---@param s team.Spec
---@return boolean
function M.only_names(s)
  for k in pairs(s) do
    if k ~= 'src' and k ~= 'name' then
      return false
    end
  end
  return true
end

--- `new` over `old`, field by field: a field `new` sets replaces `old`'s, lists included.
--- `deps` keep every entry, `opts` keep every part, and `data` merges deep.
---@param old team.Spec
---@param new team.Spec
---@return team.Spec
function M.merge(old, new)
  local res = {} ---@type table<string, any>
  for k, v in pairs(old) do
    res[k] = v
  end
  for k, v in pairs(new) do
    if k == 'deps' then
      res.deps = vim.list_extend(vim.list_slice(old.deps or {}), v)
    elseif k == 'opts_parts' then
      res.opts_parts = vim.list_extend(vim.list_slice(old.opts_parts or {}), v)
    elseif k == 'data' and type(old.data) == 'table' then
      res.data = vim.tbl_deep_extend('force', old.data, v)
    else
      res[k] = v
    end
  end
  return res --[[@as team.Spec]]
end

--- Whether an `opts` function takes the opts so far, and so extends them.
---@param f any
---@return boolean
local function extends(f)
  if type(f) ~= 'function' then
    return false
  end
  local info = debug.getinfo(f, 'u')
  return info.isvararg or info.nparams >= 2
end

--- A plugin's `opts`, from every part its specs gave. Tables and functions that take no
--- opts build the base, in read order; then functions that take opts extend it, in read
--- order. A function's result merges in when it is a table; nil, or the opts it was
--- given, keeps what it changed in place.
---@param parts (table|function)[]
---@param p any passed to each function
---@return table
function M.resolve_opts(parts, p)
  local so_far = {}
  for _, pass in ipairs({ false, true }) do
    for _, part in ipairs(parts) do
      if extends(part) == pass then
        if type(part) == 'table' then
          so_far = vim.tbl_deep_extend('force', so_far, vim.deepcopy(part))
        else
          local res = part(p, so_far)
          if type(res) == 'table' and res ~= so_far then
            so_far = vim.tbl_deep_extend('force', so_far, res)
          elseif res ~= nil and res ~= so_far then
            error(('an `opts` function returned a %s, not a table'):format(type(res)), 0)
          end
        end
      end
    end
  end
  return so_far
end

return M
