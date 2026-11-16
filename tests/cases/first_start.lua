-- phases: 4
-- The first start waits for the UI. Phase 1, headless, installs at once and writes the
-- lockfile. Phase 2 is a new machine with that lockfile: nothing on disk and a UI coming,
-- so nothing installs during init.lua; on UIEnter the window opens and shows the installs,
-- then what waited loads and a trigger that fired meanwhile is replayed. Phase 3 adds a
-- spec: only it waits, the rest start during init.lua. Phase 4 loses one plugin the
-- lockfile lists: vim.pack's first call would install it during init.lua, so every
-- plugin waits, those on disk too.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

local dir = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'site', 'pack', 'core', 'opt')
if H.phase == 2 then
  vim.fs.rm(dir, { recursive = true, force = true })
elseif H.phase == 4 then
  vim.fs.rm(vim.fs.joinpath(dir, 'entery'), { recursive = true, force = true })
end
if H.phase > 1 then
  -- As in a terminal: UIEnter comes after VimEnter. Headless Neovim has none, so the
  -- case fires it.
  ---@diagnostic disable-next-line: duplicate-set-field
  require('team.schedule').ui_coming = function()
    return true
  end
end

---@type string[]
local seen = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'TeamState',
  callback = function(ev)
    if ev.data.plugin and (ev.data.state == 'installing' or ev.data.state == 'installed') then
      seen[#seen + 1] = ev.data.plugin .. ' ' .. ev.data.state
    end
  end,
})

local spec = {
  { H.src('libby'), load = 'now' },
  { H.src('entery'), event = 'User GoX' },
  { H.src('gamma.nvim'), load = 'later' },
}
if H.phase >= 3 then
  spec[#spec + 1] = { H.src('delta'), load = 'now' }
end
require('team').setup({ confirm = false, teams_dir = false, spec = spec })
local on_disk = #vim.fn.glob(dir .. '/*', false, true)
_G.trace = {}

H.after_startup(function()
  local team, ui = require('team'), require('team.ui')
  local function st(name)
    return team.get(name).state
  end
  if H.phase == 1 then
    H.eq(on_disk, 3, 'headless: installed during init.lua')
    H.wait_later()
    return
  end

  if H.phase == 2 then
    H.eq(on_disk, 0, 'nothing installed during init.lua')
    H.eq({ st('libby'), st('entery'), st('gamma.nvim') }, { 'installing', 'installing', 'installing' }, 'all wait')
    -- A trigger fires before the UI is up: it waits for the install too.
    vim.api.nvim_exec_autocmds('User', { pattern = 'GoX', data = { n = 1 } })
    H.eq(st('entery'), 'installing', 'it waits')
  elseif H.phase == 3 then
    H.eq({ on_disk, st('libby'), st('delta') }, { 3, 'loaded', 'installing' }, 'only the new spec waits')
  else
    H.eq(
      { on_disk, st('libby'), st('delta') },
      { 3, 'installing', 'installing' },
      'the lockfile lacks entery: all wait'
    )
  end
  seen = {}

  vim.api.nvim_exec_autocmds('UIEnter', {})
  H.wait(function()
    return ui.is_open() and st(H.phase == 3 and 'delta' or 'libby') == 'loaded'
  end, 'the window, the installs and the load')
  H.wait_later()
  if H.phase == 2 then
    table.sort(seen)
    H.eq(seen, {
      'entery installed',
      'gamma.nvim installed',
      'libby installed',
    }, 'each row turned installed once, as its install ended, in parallel')
    H.eq(team.get('libby').reason, 'startup', 'the now plugin loaded for its own reason')
    H.wait(function()
      return vim.list_contains(_G.trace, 'entery lone 1')
    end, 'the event to be replayed')
    local entery = vim.tbl_filter(function(s)
      return s:find('entery', 1, true) ~= nil
    end, _G.trace)
    H.eq(entery, { 'plugin entery', 'entery lone 1', 'entery group' }, 'once, for the plugin that waited')
    H.eq(st('gamma.nvim'), 'loaded', 'the later plugin after the install')
  elseif H.phase == 3 then
    H.eq(seen, { 'delta installed' }, 'just the new one')
  else
    table.sort(seen)
    local all = { 'delta installed', 'entery installed', 'gamma.nvim installed', 'libby installed' }
    H.eq(seen, all, 'every held row turns installed once vim.pack has run')
    H.ok(H.noted('^installed entery$'), 'and only the lost one was cloned')
    H.eq(team.get('libby').reason, 'startup', 'and libby loads once the batch is in')
  end
  local buf = assert(ui.handles())
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  H.ok(text:find('libby%s+loaded'), 'the window shows them:\n' .. text)
  H.ok(H.noted('^installed '), 'and says what installed')
end)
