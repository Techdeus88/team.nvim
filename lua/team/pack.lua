-- The only code that calls vim.pack. vim.pack owns the disk: it installs, keeps the
-- lockfile, updates and deletes. Here every plugin is handed to it once, in one call,
-- without putting any on the runtimepath; loader.lua does that when each one's time comes.

local events = require('team.events')
local state = require('team.state')

local M = {}

--- Where vim.pack keeps plugins.
---@return string
function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'site', 'pack', 'core', 'opt')
end

---@param p team.Plugin
---@return vim.pack.Spec
local function to_pack(p)
  -- Your `data`, and the team, so vim.pack.get() and PackChanged handlers can see it.
  local data = vim.tbl_extend('force', p.spec.data or {}, { team = p.team })
  return { src = p.spec.src, name = p.name, version = p.spec.version, data = data }
end

--- vim.pack's error is a block per plugin that failed: "`name`:\n" then why. Split it
--- by the names of the plugins that did not make it.
---@param err string
---@param names string[]
---@return table<string, string>
local function per_plugin(err, names)
  local starts = {} ---@type { at: integer, from: integer, name: string }[]
  for _, name in ipairs(names) do
    local head = ('`%s`:\n'):format(name)
    local at = err:find(head, 1, true)
    if at then
      starts[#starts + 1] = { at = at, from = at + #head, name = name }
    end
  end
  table.sort(starts, function(a, b)
    return a.at < b.at
  end)
  local res = {}
  for i, s in ipairs(starts) do
    local to = starts[i + 1] and starts[i + 1].at - 1 or #err
    -- Without the location inside vim.pack that raised it: that is not yours to read.
    res[s.name] = vim.trim(err:sub(s.from, to)):gsub('^.-pack%.lua:%d+: ', '')
  end
  return res
end

--- Plugins your lockfile lists that are not on disk, as on a new machine with your
--- dotfiles. vim.pack's first call of a session installs every one of them.
---@return string[]
function M.lock_missing()
  local file = vim.fs.joinpath(vim.fn.stdpath('config') --[[@as string]], 'nvim-pack-lock.json')
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok then
    return {}
  end
  local decoded_ok, lock = pcall(vim.json.decode, table.concat(lines, '\n'))
  local res = {}
  for name in pairs(decoded_ok and type(lock) == 'table' and lock.plugins or {}) do
    if not vim.uv.fs_stat(vim.fs.joinpath(M.dir(), name)) then
      res[#res + 1] = name
    end
  end
  table.sort(res)
  return res
end

--- Install what is missing and register every plugin with vim.pack. A plugin not on disk
--- is `installing` until vim.pack says it is in; a plugin on disk afterwards is
--- `installed` with its `path`, one that is not is `missing`. Loads that waited for an
--- install go on once it is done.
---@param plugins team.Plugin[]
---@param confirm boolean ask before installing
function M.register(plugins, confirm)
  if #plugins == 0 then
    return
  end
  local was = {} ---@type table<string, boolean>
  -- Held for the UI, on disk or not: loads wait for each of these.
  local waited = {} ---@type table<string, boolean>
  for _, p in ipairs(plugins) do
    waited[p.name] = p.state == 'installing'
    was[p.name] = vim.uv.fs_stat(vim.fs.joinpath(M.dir(), p.name)) ~= nil
    if not was[p.name] then
      state.set(p, 'installing')
    end
  end
  -- Each plugin's row turns installed as its install ends, not once all have.
  local live = vim.api.nvim_create_autocmd('PackChanged', {
    callback = function(ev)
      local p = state.plugins[ev.data.spec.name]
      if p and ev.data.kind == 'install' and p.state == 'installing' then
        p.path = ev.data.path
        state.set(p, 'installed')
      end
    end,
  })
  local paths = {} ---@type table<string, string>
  local ok, err = pcall(vim.pack.add, vim.tbl_map(to_pack, plugins), {
    confirm = confirm,
    load = function(d)
      paths[d.spec.name] = d.path
    end,
  })
  vim.api.nvim_del_autocmd(live)
  local missing = vim.tbl_map(
    function(p)
      return p.name
    end,
    vim.tbl_filter(function(p)
      return paths[p.name] == nil
    end, plugins)
  )
  local why = not ok and per_plugin(tostring(err), missing) or {}
  local installed = {}
  for _, p in ipairs(plugins) do
    p.path = paths[p.name]
    if p.path then
      if not was[p.name] then
        installed[#installed + 1] = p.name
      end
      state.set(p, 'installed')
    else
      local msg = why[p.name] or 'not installed'
      state.set(p, 'missing', msg)
      events.report(('`%s` is not installed: %s'):format(p.name, msg), vim.log.levels.ERROR, { plugin = p.name })
    end
  end
  if not ok and next(why) == nil then
    events.report(tostring(err), vim.log.levels.ERROR)
  end
  if #installed > 0 then
    events.report(('installed %s'):format(table.concat(installed, ', ')))
    events.emit(events.names.Install, { plugins = installed })
  end
  local loader = require('team.loader')
  for _, p in ipairs(plugins) do
    if waited[p.name] or not was[p.name] then
      loader.unblock(p)
    end
  end
end

return M
