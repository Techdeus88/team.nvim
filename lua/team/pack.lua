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

--- Install what is missing and register every plugin with vim.pack. A plugin on disk
--- afterwards is `installed` with its `path`; one that is not is `missing`.
---@param plugins team.Plugin[]
---@param confirm boolean ask before installing
function M.register(plugins, confirm)
  if #plugins == 0 then
    return
  end
  local was = {} ---@type table<string, boolean>
  for _, p in ipairs(plugins) do
    was[p.name] = vim.uv.fs_stat(vim.fs.joinpath(M.dir(), p.name)) ~= nil
  end
  local paths = {} ---@type table<string, string>
  local ok, err = pcall(vim.pack.add, vim.tbl_map(to_pack, plugins), {
    confirm = confirm,
    load = function(d)
      paths[d.spec.name] = d.path
    end,
  })
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
end

return M
