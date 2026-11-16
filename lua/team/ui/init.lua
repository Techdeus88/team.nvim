-- The team.nvim window: one float over the editor with three views (Teams, Profile, Log).
-- While it is open it redraws as teams and plugins change, at most once per `throttle`
-- ms; closing it removes every listener. The cursor stays on the same team or plugin
-- across redraws.

local render = require('team.ui.render')
local state = require('team.state')

local api = vim.api

local M = {}

M.views = { 'teams', 'profile', 'log' }
M.throttle = 30

local ns = api.nvim_create_namespace('team.ui')

-- Your colorscheme's colors, through links it can override: `:hi TeamLoaded guifg=...`.
local links = {
  TeamTeam = 'Title',
  TeamPlugin = false,
  TeamDep = 'Comment',
  TeamLoaded = 'DiagnosticOk',
  TeamWaiting = 'Comment',
  TeamLoading = 'DiagnosticInfo',
  TeamFailed = 'DiagnosticError',
  TeamMissing = 'DiagnosticWarn',
  TeamDisabled = 'NonText',
  TeamMuted = 'Comment',
  TeamTime = 'Number',
  TeamFold = 'NonText',
  TeamKey = 'Special',
  TeamTab = 'Comment',
  TeamTabActive = 'TabLineSel',
  TeamRule = 'FloatBorder',
}

function M.highlights()
  for name, link in pairs(links) do
    -- `false`: a group of its own with nothing set, so it takes the window's colors; a
    -- link to Normal would paint Normal's background inside the float.
    api.nvim_set_hl(0, name, link and { link = link, default = true } or { default = true })
  end
end

---@class team.ui.Window
---@field buf integer
---@field win integer
---@field view string
---@field items table<integer, team.ui.Item>
---@field group integer
---@field timer? uv.uv_timer_t

---@type team.ui.Window?
local W

-- What stays the same across opens in a session.
---@type team.ui.View
local view_state = { folded = {}, open = {}, help = false }

--- The window's size and place: `ui.size` of the editor, at least 60 x 12 cells when
--- the editor has room, centred. The border takes a cell on each side.
---@return { width: integer, height: integer, row: integer, col: integer }
local function size()
  local cfg = state.config and state.config.ui or {}
  local share = cfg.size or 0.8
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local max_w, max_h = cols - 2, lines - 2
  local width = math.min(max_w, math.max(math.floor(cols * share), math.min(max_w, 60)))
  local height = math.min(max_h, math.max(math.floor(lines * share), math.min(max_h, 12)))
  local row, col = math.floor((lines - height - 2) / 2), math.floor((cols - width - 2) / 2)
  return { width = width, height = height, row = row, col = col }
end

---@return string|string[]
local function border()
  local cfg = state.config and state.config.ui or {}
  if cfg.border then
    return cfg.border
  end
  local ok, wb = pcall(function()
    return vim.o.winborder
  end)
  return ok and wb ~= '' and wb ~= 'none' and wb or 'rounded'
end

--- The item under the cursor.
---@return team.ui.Item?
function M.item()
  if not W then
    return
  end
  return W.items[api.nvim_win_get_cursor(W.win)[1]]
end

--- Draw the current view, keeping the cursor on the item it was on.
function M.redraw()
  if not (W and api.nvim_win_is_valid(W.win)) then
    return
  end
  local keep = M.item()
  local width = api.nvim_win_get_width(W.win)
  local screen = render.screen(W.view --[[@as 'teams'|'profile'|'log']], width, view_state)
  vim.bo[W.buf].modifiable = true
  api.nvim_buf_set_lines(W.buf, 0, -1, false, screen.lines)
  vim.bo[W.buf].modifiable = false
  api.nvim_buf_clear_namespace(W.buf, ns, 0, -1)
  for _, h in ipairs(screen.hls) do
    api.nvim_buf_set_extmark(W.buf, ns, h.line, h.from, { end_col = h.to, hl_group = h.group })
  end
  W.items = screen.items
  -- Back on the same team or plugin; else the first item; else past the header.
  local target
  for n, it in pairs(screen.items) do
    if keep and it.kind == keep.kind and it.name == keep.name then
      target = math.min(target or n, n)
    end
  end
  if not target then
    for n = 1, #screen.lines do
      if screen.items[n] then
        target = n
        break
      end
    end
  end
  local row = target or math.min(4, #screen.lines)
  if W.view == 'log' and not keep then
    row = #screen.lines
  end
  api.nvim_win_set_cursor(W.win, { row, 0 })
end

--- Redraw soon, at most once per `throttle` ms, however often things change.
function M.schedule()
  if not W or W.timer then
    return
  end
  W.timer = assert(vim.uv.new_timer())
  W.timer:start(
    M.throttle,
    0,
    vim.schedule_wrap(function()
      if W and W.timer then
        W.timer:close()
        W.timer = nil
        M.redraw()
      end
    end)
  )
end

function M.close()
  if not W then
    return
  end
  local w = W
  W = nil
  if w.timer then
    w.timer:close()
  end
  pcall(api.nvim_del_augroup_by_id, w.group)
  if api.nvim_win_is_valid(w.win) then
    api.nvim_win_close(w.win, true)
  end
end

---@return boolean
function M.is_open()
  return W ~= nil and api.nvim_win_is_valid(W.win)
end

---@return integer? buf, integer? win
function M.handles()
  if W then
    return W.buf, W.win
  end
end

--- Show a view.
---@param name string
function M.show(name)
  if not W then
    return
  end
  W.view = name
  view_state.help = false
  M.redraw()
end

---@param step integer
local function cycle(step)
  if not W then
    return
  end
  local i = vim.fn.index(M.views, W.view)
  M.show(M.views[(i + step) % #M.views + 1])
end

--- Say why an action did not work.
---@param ok boolean
---@param err? string
local function report(ok, err)
  if not ok and err then
    require('team.events').report(err, vim.log.levels.ERROR)
  end
end

---@param it? team.ui.Item
---@return team.Team?, team.Plugin?
local function targets(it)
  if not it then
    return
  end
  if it.kind == 'team' then
    return state.teams[it.name], nil
  end
  local p = state.plugins[it.name]
  return p and p.team and state.teams[p.team] or nil, p
end

---@type table<string, fun()>
M.actions = {
  toggle = function()
    local it = M.item()
    if not it then
      return
    end
    if it.kind == 'team' then
      view_state.folded[it.name] = not view_state.folded[it.name]
    else
      view_state.open[it.name] = not view_state.open[it.name]
    end
    M.redraw()
  end,
  load = function()
    local t, p = targets(M.item())
    local loader = require('team.loader')
    if p then
      report(loader.load(p, 'window'))
    elseif t then
      report(loader.load_team(t, 'window'))
    end
    M.redraw()
  end,
  update = function()
    local it = M.item()
    if it and it.kind ~= 'detail' then
      M.close()
      report(require('team.ops').update({ it.name }))
    end
  end,
  update_all = function()
    M.close()
    report(require('team.ops').update())
  end,
  toggle_team = function()
    local t = targets(M.item())
    if t then
      local ops = require('team.ops')
      report((t.state == 'disabled' and ops.enable or ops.disable)(t.name))
      M.redraw()
    end
  end,
  open_dir = function()
    local _, p = targets(M.item())
    if p and p.path then
      M.close()
      vim.cmd.tabedit(vim.fn.fnameescape(p.path))
      vim.cmd.tcd(vim.fn.fnameescape(p.path))
    end
  end,
  open_spec = function()
    local t, p = targets(M.item())
    local origin = (p or t or {}).origin
    if origin and vim.uv.fs_stat(origin.file) then
      M.close()
      vim.cmd.edit(vim.fn.fnameescape(origin.file))
    end
  end,
  fold_all = function()
    for _, name in ipairs(state.team_order) do
      view_state.folded[name] = true
    end
    M.redraw()
  end,
  open_all = function()
    view_state.folded = {}
    M.redraw()
  end,
  help = function()
    view_state.help = not view_state.help
    M.redraw()
  end,
}

---@param step integer
local function jump_team(step)
  if not W then
    return
  end
  local row = api.nvim_win_get_cursor(W.win)[1]
  local n = #api.nvim_buf_get_lines(W.buf, 0, -1, false)
  local r = row + step
  while r >= 1 and r <= n do
    local it = W.items[r]
    if it and it.kind == 'team' then
      return api.nvim_win_set_cursor(W.win, { r, 0 })
    end
    r = r + step
  end
end

---@param buf integer
local function keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, desc = 'team.nvim: ' .. desc })
  end
  local a = M.actions
  map('<CR>', a.toggle, 'fold, or details')
  map('o', a.toggle, 'fold, or details')
  map('l', a.load, 'load')
  map('u', a.update, 'update')
  map('U', a.update_all, 'update everything')
  map('e', a.toggle_team, 'team on or off')
  map('go', a.open_dir, "the plugin's folder")
  map('gf', a.open_spec, 'the file that declares it')
  map('zM', a.fold_all, 'fold every team')
  map('zR', a.open_all, 'open every team')
  map(']]', function()
    jump_team(1)
  end, 'next team')
  map('[[', function()
    jump_team(-1)
  end, 'previous team')
  map('<Tab>', function()
    cycle(1)
  end, 'next view')
  map('<S-Tab>', function()
    cycle(-1)
  end, 'previous view')
  for i, name in ipairs(M.views) do
    map(tostring(i), function()
      M.show(name)
    end, name)
  end
  map('r', M.redraw, 'redraw')
  map('?', a.help, 'help')
  map('q', M.close, 'close')
  map('<Esc>', M.close, 'close')
end

--- Open the window on a view, or switch an open one to it.
---@param name? 'teams'|'profile'|'log'
function M.open(name)
  name = name or 'teams'
  if W and M.is_open() then
    api.nvim_set_current_win(W.win)
    return M.show(name)
  end
  M.close()
  M.highlights()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'team'
  local s = size()
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = s.width,
    height = s.height,
    row = s.row,
    col = s.col,
    style = 'minimal',
    border = border(),
    title = ' team.nvim ',
    title_pos = 'center',
    footer = ' ? help · q close ',
    footer_pos = 'center',
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  local group = api.nvim_create_augroup('team.ui', { clear = true })
  W = { buf = buf, win = win, view = name, items = {}, group = group }
  keymaps(buf)

  api.nvim_create_autocmd('User', {
    group = group,
    pattern = { 'TeamState', 'TeamLoad', 'TeamReport', 'TeamLater' },
    callback = M.schedule,
  })
  api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if M.is_open() then
        local n = size()
        api.nvim_win_set_config(
          W.win,
          { relative = 'editor', width = n.width, height = n.height, row = n.row, col = n.col }
        )
        M.redraw()
      end
    end,
  })
  -- Leaving the window closes it, so it never stays over your work.
  api.nvim_create_autocmd('WinLeave', {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(M.close)
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(M.close)
    end,
  })
  M.redraw()
end

--- For tests: what the window keeps across opens.
M._view_state = view_state

return M
