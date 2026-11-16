-- A plugin's `build`, after vim.pack installs or updates it:
--
--   'make'               a shell command, in the background, from the plugin's folder
--   ':TSUpdate'          an Ex command: the plugin loads first
--   function(p)          runs with the plugin on the runtimepath, not loaded
--   function(p, done)    the same, finished when it calls done(ok, msg)
--
-- While a shell or function build runs the plugin cannot load: a load that needs it waits
-- and runs after. Ex commands and functions wait for VimEnter, since during init.lua the
-- startup pass would source a plugin put on the runtimepath. A build that fails, or that
-- quitting cut off, runs again at the next startup.

local events = require('team.events')
local state = require('team.state')

local M = {}

local levels = vim.log.levels

--- Seconds a shell or async function build may take.
M.timeout = 300

---@return string
local function pending_file()
  return vim.fs.joinpath(vim.fn.stdpath('state') --[[@as string]], 'team', 'builds.json')
end

--- Builds that have not finished well yet, by plugin name.
---@return table<string, string>
function M.pending()
  local ok, data = pcall(vim.fn.readfile, pending_file())
  if not ok or #data == 0 then
    return {}
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(data, '\n'))
  return decoded_ok and type(decoded) == 'table' and decoded or {}
end

---@param name string
---@param kind? string nil: done
local function mark(name, kind)
  local list = M.pending()
  list[name] = kind
  local file = pending_file()
  vim.fn.mkdir(vim.fs.dirname(file), 'p')
  vim.fn.writefile({ vim.json.encode(vim.tbl_isempty(list) and vim.empty_dict() or list) }, file)
end

---@param p team.Plugin
---@param what string the build, as messages name it
---@param kind string
---@param t0 number
---@param ok boolean
---@param err? string
---@param output? string
local function finish(p, what, kind, t0, ok, err, output)
  p.building = nil
  local ms = (vim.uv.hrtime() - t0) / 1e6
  if ok then
    mark(p.name, nil)
    p.build_err = nil
    events.report(('`%s`: build `%s` done in %.0f ms'):format(p.name, what, ms), levels.INFO, { plugin = p.name })
  else
    p.build_err = err
    events.report(('`%s`: build `%s` failed: %s'):format(p.name, what, err), levels.ERROR, { plugin = p.name })
  end
  if output and output ~= '' then
    events.report(('`%s`: build output:\n%s'):format(p.name, output), levels.DEBUG, { plugin = p.name })
  end
  events.emit(events.names.Build, { plugin = p.name, kind = kind, ok = ok, ms = ms, err = err })
  state.touch(p)
  require('team.loader').unblock(p)
end

---@param s string
---@return string
local function last_line(s)
  local lines = vim.split(vim.trim(s or ''), '\n')
  return lines[#lines] or ''
end

---@param p team.Plugin
---@param cmd string
---@param kind string
local function shell(p, cmd, kind)
  local t0 = vim.uv.hrtime()
  p.building = cmd
  state.touch(p)
  -- `sh -c` whatever your 'shell' is: a build command is written for a POSIX shell.
  local ok, err = pcall(
    vim.system,
    { 'sh', '-c', cmd },
    {
      cwd = p.path,
      text = true,
      timeout = M.timeout * 1000,
    },
    vim.schedule_wrap(function(r)
      local output = vim.trim((r.stdout or '') .. '\n' .. (r.stderr or ''))
      if r.code == 0 then
        finish(p, cmd, kind, t0, true, nil, output)
      elseif r.code == 124 then
        finish(p, cmd, kind, t0, false, ('timed out after %d s'):format(M.timeout), output)
      else
        local why = last_line(r.stderr ~= '' and r.stderr or r.stdout)
        finish(p, cmd, kind, t0, false, ('exit %d%s'):format(r.code, why ~= '' and (': ' .. why) or ''), output)
      end
    end)
  )
  if not ok then
    finish(p, cmd, kind, t0, false, ('cannot start: %s'):format(tostring(err)))
  end
end

---@param p team.Plugin
---@param fn function
---@param kind string
local function func(p, fn, kind)
  local t0 = vim.uv.hrtime()
  p.building = 'function'
  state.touch(p)
  -- On the runtimepath for require(), without sourcing plugin/: it is not loaded yet.
  if p.state ~= 'loaded' then
    pcall(vim.cmd.packadd, { vim.fn.escape(p.name, ' '), bang = true, magic = { file = false } })
  end
  local info = debug.getinfo(fn, 'u')
  if not (info.isvararg or info.nparams >= 2) then
    local ok, err = pcall(fn, p)
    return finish(p, 'function', kind, t0, ok, not ok and tostring(err) or nil)
  end
  local finished = false
  local timer = assert(vim.uv.new_timer())
  local function done(ok, msg)
    if finished then
      return
    end
    finished = true
    timer:close()
    finish(p, 'function', kind, t0, ok ~= false, ok == false and (msg or 'failed') or nil)
  end
  timer:start(
    M.timeout * 1000,
    0,
    vim.schedule_wrap(function()
      done(false, ('timed out after %d s'):format(M.timeout))
    end)
  )
  local ok, err = pcall(fn, p, vim.schedule_wrap(done))
  if not ok then
    done(false, tostring(err))
  end
end

---@param p team.Plugin
---@param cmd string ':Cmd'
---@param kind string
local function excmd(p, cmd, kind)
  local t0 = vim.uv.hrtime()
  local loader = require('team.loader')
  local ok, err = loader.load(p, 'build')
  if ok == nil then
    -- It waits for something else's install or build: run when it has loaded.
    local id
    id = vim.api.nvim_create_autocmd('User', {
      pattern = { 'TeamPluginLoad', 'TeamPluginFail' },
      callback = function(ev)
        if ev.data.plugin == p.name then
          vim.api.nvim_del_autocmd(id)
          excmd(p, cmd, kind)
        end
      end,
    })
    return
  end
  if not ok then
    return finish(p, cmd, kind, t0, false, ('it did not load: %s'):format(err))
  end
  local done, why = pcall(vim.cmd --[[@as function]], cmd:sub(2))
  local msg = not done and (tostring(why):gsub('^.-Vim%b():', ''):gsub('^.-Vim:', '')) or nil
  finish(p, cmd, kind, t0, done, msg)
end

--- Run a plugin's build. `kind`: what came before it, 'install', 'update' or 'retry'.
---@param p team.Plugin
---@param kind string
function M.run(p, kind)
  local b = p.spec.build
  if not b or not p.path or p.building or p.build_queued then
    return
  end
  mark(p.name, kind)
  if type(b) == 'string' and not b:find('^:') then
    return shell(p, b, kind)
  end
  if vim.v.vim_did_enter == 0 then
    -- Ex commands and functions after startup. A function build keeps the plugin from
    -- loading until then; an Ex command build loads it anyway.
    if type(b) ~= 'string' then
      p.building = 'function'
    end
    p.build_queued = true
    vim.api.nvim_create_autocmd('VimEnter', {
      once = true,
      callback = function()
        p.building, p.build_queued = nil, nil
        M.run(p, kind)
      end,
    })
    return
  end
  if type(b) == 'string' then
    excmd(p, b, kind)
  else
    func(p, b, kind)
  end
end

--- Builds after vim.pack installs or updates one of your plugins, and the builds that did
--- not finish well last time.
function M.watch()
  vim.api.nvim_create_autocmd('PackChanged', {
    desc = 'team.nvim: builds',
    callback = function(ev)
      local p = state.plugins[ev.data.spec.name]
      if p and (ev.data.kind == 'install' or ev.data.kind == 'update') then
        p.path = p.path or ev.data.path
        M.run(p, ev.data.kind)
      end
    end,
  })
end

--- Run again the builds that failed or were cut off in an earlier session.
---@param earlier table<string, string> M.pending() before this session's installs
function M.retry(earlier)
  for name in pairs(earlier) do
    local p = state.plugins[name]
    if p and p.path and p.state ~= 'disabled' then
      M.run(p, 'retry')
    elseif not p or not p.spec.build then
      mark(name, nil)
    end
  end
end

return M
