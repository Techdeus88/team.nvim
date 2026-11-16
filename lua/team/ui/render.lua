-- What the window shows, as lines with highlights and the item on each line. Pure apart
-- from reading state: the window code puts it in a buffer.

local state = require('team.state')

local M = {}

---@class team.ui.Item
---@field kind 'team'|'plugin'|'detail'
---@field name string the team or plugin

---@class team.ui.Screen
---@field lines string[]
---@field hls { line: integer, from: integer, to: integer, group: string }[] 0-based, byte columns
---@field items table<integer, team.ui.Item> 1-based line -> what is on it
---@field width integer

---@class team.ui.View
---@field folded table<string, boolean> team name -> folded
---@field open table<string, boolean> plugin name -> details shown
---@field help boolean

-- The highlight of each state, for both teams and plugins.
M.state_hl = {
  loaded = 'TeamLoaded',
  installed = 'TeamWaiting',
  pending = 'TeamWaiting',
  loading = 'TeamLoading',
  partial = 'TeamLoading',
  failed = 'TeamFailed',
  missing = 'TeamMissing',
  disabled = 'TeamDisabled',
}

--- One line being built from pieces, each with its highlight.
---@class team.ui.Line
---@field text string
---@field width integer display cells so far
---@field hls { from: integer, to: integer, group: string }[]
local Line = {}
Line.__index = Line

---@return team.ui.Line
local function line()
  return setmetatable({ text = '', width = 0, hls = {} }, Line)
end

--- `s` cut to `w` display cells, with an ellipsis when it was longer.
---@param s string
---@param w integer
---@return string
function M.fit(s, w)
  if w <= 0 then
    return ''
  end
  if vim.fn.strdisplaywidth(s) <= w then
    return s
  end
  local out = ''
  for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
    if vim.fn.strdisplaywidth(out .. ch) > w - 1 then
      break
    end
    out = out .. ch
  end
  return out .. '…'
end

---@param s string
---@param group? string
---@param w? integer pad or cut to this many cells
---@return team.ui.Line
function Line:add(s, group, w)
  if w then
    s = M.fit(s, w)
    s = s .. string.rep(' ', w - vim.fn.strdisplaywidth(s))
  end
  if group and s ~= '' then
    self.hls[#self.hls + 1] = { from = #self.text, to = #self.text + #s, group = group }
  end
  self.text = self.text .. s
  self.width = self.width + vim.fn.strdisplaywidth(s)
  return self
end

--- Fill with spaces up to `col` cells.
---@param col integer
---@return team.ui.Line
function Line:to(col)
  if col > self.width then
    self:add(string.rep(' ', col - self.width))
  end
  return self
end

--- Cut the line to `w` cells, with an ellipsis, and its highlights with it.
---@param w integer
function Line:clip(w)
  if self.width <= w then
    return
  end
  local cut = M.fit(self.text, w)
  local keep = #cut - #'…'
  local hls = {}
  for _, h in ipairs(self.hls) do
    if h.from < keep then
      hls[#hls + 1] = { from = h.from, to = math.min(h.to, keep), group = h.group }
    end
  end
  self.text, self.width, self.hls = cut, vim.fn.strdisplaywidth(cut), hls
end

---@param screen team.ui.Screen
---@param l team.ui.Line
---@param item? team.ui.Item
local function push(screen, l, item)
  -- Nothing is ever wider than the window: no row wraps or scrolls sideways.
  l:clip(screen.width)
  screen.lines[#screen.lines + 1] = l.text
  local n = #screen.lines
  for _, h in ipairs(l.hls) do
    screen.hls[#screen.hls + 1] = { line = n - 1, from = h.from, to = h.to, group = h.group }
  end
  screen.items[n] = item
end

---@param n number
---@return string
local function ms(n)
  return ('%.2f ms'):format(n)
end

---@param p team.Plugin
---@return number
local function cost(p)
  local t = p.time or {}
  return (t.packadd or 0) + (t.config or 0)
end

--- What loads it, short: `BufReadPre`, `ft lua`, `:Cmd`, `<leader>g`, `after core`.
---@param triggers table trigger fields: lists, or nil
---@return string
function M.triggers(triggers)
  local parts = {}
  for _, e in ipairs(triggers.event or {}) do
    parts[#parts + 1] = e
  end
  if triggers.ft then
    parts[#parts + 1] = 'ft ' .. table.concat(triggers.ft, ',')
  end
  for _, c in ipairs(triggers.cmd or {}) do
    parts[#parts + 1] = ':' .. c
  end
  for _, k in ipairs(triggers.keys or {}) do
    parts[#parts + 1] = type(k) == 'table' and k[1] or k
  end
  for _, t in ipairs(triggers.after_team or {}) do
    parts[#parts + 1] = 'after ' .. t
  end
  return table.concat(parts, ' ')
end

--- Why a team or plugin is off, in words.
---@param by? string
---@return string
function M.off(by)
  if by == 'enabled' or by == 'cond' then
    return by .. ' = false'
  elseif by == 'session' then
    return 'off this session'
  elseif by == 'unneeded' then
    return 'nothing on needs it'
  end
  return by or 'off'
end

--- When a team loads, in words.
---@param t team.Team
---@return string
local function moment(t)
  if t.state == 'disabled' then
    return M.off(t.disabled_by)
  elseif not t.when then
    return 'each its own way'
  end
  local trig = M.triggers({
    event = t.event or nil,
    ft = t.ft or nil,
    cmd = t.cmd or nil,
    keys = t.keys or nil,
    after_team = t.after_team or nil,
  })
  local s = t.when == 'trigger' and (trig ~= '' and trig or 'on demand') or t.when --[[@as string]]
  if t.when ~= 'trigger' and trig ~= '' then
    s = s .. ', or ' .. trig
  end
  if t.pulled_by then
    s = s .. ' (for ' .. t.pulled_by .. ')'
  end
  return s
end

--- How a plugin loads, short.
---@param p team.Plugin
---@return string
function M.how(p)
  if p.in_batch then
    -- Only what it adds to its team's triggers.
    local own = {}
    for k, v in pairs(p.triggers) do
      if not p.inherited[k] then
        own[k] = v
      end
    end
    local extra = M.triggers(own)
    return extra ~= '' and ('team, ' .. extra) or 'team'
  end
  if p.load == 'trigger' then
    local trig = M.triggers(p.triggers)
    return trig ~= '' and trig or (p.dep_only and 'dependency' or 'on demand')
  end
  return p.load
end

---@param list string[]
---@return integer
local function widest(list, cap, floor)
  local w = floor
  for _, s in ipairs(list) do
    w = math.max(w, vim.fn.strdisplaywidth(s))
  end
  return math.min(w, cap)
end

--- Columns for the width: narrow windows drop `how`, then `why`. A team row's state and
--- moment start where its plugins' state and `how` do: the name column is shared, a team
--- name starting two cells left of a plugin's.
---@param width integer
---@return { name: integer, how: integer?, why: boolean }
local function columns(width)
  local cap = width >= 100 and 32 or 24
  local name = widest(vim.tbl_keys(state.plugins), cap, 10)
  for _, t in ipairs(state.team_order) do
    name = math.min(cap, math.max(name, vim.fn.strdisplaywidth(t) - 2))
  end
  local how
  if width >= 76 then
    how = 8
    for _, p in pairs(state.plugins) do
      how = math.max(how, vim.fn.strdisplaywidth(M.how(p)))
    end
    how = math.min(how, width >= 100 and 28 or 18)
  end
  return { name = name, how = how, why = width >= 58 }
end

---@param screen team.ui.Screen
---@param p team.Plugin
---@param width integer
local function details(screen, p, width)
  local function row(label, value, group)
    if value == nil or value == '' then
      return
    end
    local l = line():add('        '):add(label, 'TeamMuted', 10):add(M.fit(value, width - 19), group)
    push(screen, l, { kind = 'detail', name = p.name })
  end
  local v = p.spec.version
  row('src', p.spec.src)
  row('path', p.path and vim.fn.fnamemodify(p.path, ':~') or 'not on disk')
  row('version', v and tostring(v) or nil)
  row('team', p.team and (p.team .. (p.in_batch and ', in its batch' or '')) or 'none')
  row('load', p.load .. (p.load_from and (' (from team ' .. p.load_from .. ')') or ''))
  row('triggers', M.triggers(p.triggers))
  row('deps', table.concat(p.deps, ', '))
  local needed = {}
  for _, name in ipairs(state.order) do
    if vim.list_contains(state.plugins[name].deps, p.name) then
      needed[#needed + 1] = name
    end
  end
  row('needed by', table.concat(needed, ', '))
  row('reason', p.reason)
  row('error', p.err, 'TeamFailed')
  row('off', p.disabled_by and M.off(p.disabled_by))
  if p.time then
    row('time', ('packadd %s, config %s'):format(ms(p.time.packadd or 0), ms(p.time.config or 0)), 'TeamTime')
  end
  row('spec', vim.fn.fnamemodify(p.origin.file, ':~'))
end

---@param screen team.ui.Screen
---@param p team.Plugin
---@param cols table
---@param width integer
---@param view team.ui.View
local function plugin_row(screen, p, cols, width, view)
  local l = line():add('     '):add(p.name, p.dep_only and 'TeamDep' or 'TeamPlugin', cols.name):add('  ')
  l:add(p.state, M.state_hl[p.state], 9)
  if cols.how then
    l:add('  '):add(M.how(p), 'TeamMuted', cols.how)
  end
  local time = p.time and ms(cost(p)) or ''
  if cols.why then
    local why = p.err or (p.state == 'loaded' and p.reason) or (p.disabled_by and M.off(p.disabled_by)) or ''
    local room = width - l.width - 2 - 11
    l:add('  '):add(why, p.err and 'TeamFailed' or 'TeamMuted', math.max(room, 0))
  end
  l:to(width - #time - 1):add(time, 'TeamTime')
  push(screen, l, { kind = 'plugin', name = p.name })
  if view.open[p.name] then
    details(screen, p, width)
  end
end

---@param screen team.ui.Screen
---@param t team.Team
---@param cols table
---@param width integer
---@param view team.ui.View
local function team_rows(screen, t, cols, width, view)
  local loaded, total = 0, 0
  for _, name in ipairs(t.members) do
    local p = state.plugins[name]
    if p.state == 'loaded' then
      loaded = loaded + 1
    end
    total = total + cost(p)
  end
  for _, h in pairs(t.hooks or {}) do
    total = total + h
  end
  local folded = view.folded[t.name]
  local l = line():add(folded and ' ▸ ' or ' ▾ ', 'TeamFold'):add(t.name, 'TeamTeam', cols.name + 2):add('  ')
  l:add(t.state, M.state_hl[t.state], 9):add('  ')
  -- The time field keeps its width when empty, so every count sits in one column.
  local right = ('%d/%d  %10s'):format(loaded, #t.members, loaded > 0 and ms(total) or '')
  l:add(moment(t), 'TeamMuted', math.max(width - l.width - #right - 3, 0))
  l:to(width - #right - 1):add(right, 'TeamTime')
  push(screen, l, { kind = 'team', name = t.name })
  if not folded then
    for _, name in ipairs(t.members) do
      plugin_row(screen, state.plugins[name], cols, width, view)
    end
  end
end

local help = {
  { '<CR>', 'fold a team, or show a plugin’s details' },
  { 'l', 'load the team or plugin under the cursor' },
  { 'u', 'update it with vim.pack (U: every plugin)' },
  { 'e', 'turn its team on or off for this session' },
  { 'go', 'open the plugin’s folder in a new tab' },
  { 'gf', 'open the file that declares it' },
  { 'zM / zR', 'fold every team / open every team' },
  { ']] / [[', 'next / previous team' },
  { '<Tab> / <S-Tab>', 'next / previous view (1, 2, 3 go straight there)' },
  { 'r', 'redraw' },
  { '?', 'this help' },
  { 'q / <Esc>', 'close' },
}

--- The summary line and the view tabs.
---@param screen team.ui.Screen
---@param current string
---@param width integer
local function header(screen, current, width)
  local count = { loaded = 0, waiting = 0, failed = 0, off = 0 }
  for _, p in pairs(state.plugins) do
    local s = p.state
    if s == 'loaded' then
      count.loaded = count.loaded + 1
    elseif s == 'failed' or s == 'missing' then
      count.failed = count.failed + 1
    elseif s == 'disabled' then
      count.off = count.off + 1
    else
      count.waiting = count.waiting + 1
    end
  end
  -- Narrow windows drop the team count and what is waiting.
  local wide = width >= 64
  local l = line():add(' ')
  if wide then
    l:add(('%d teams · '):format(#state.team_order), 'TeamMuted')
  end
  l:add(('%d plugins: '):format(#state.order), 'TeamMuted')
  l:add(('%d loaded'):format(count.loaded), 'TeamLoaded')
  if wide then
    l:add((' · %d waiting'):format(count.waiting), 'TeamMuted')
  end
  if count.failed > 0 then
    l:add(' · '):add(('%d failed'):format(count.failed), 'TeamFailed')
  end
  if count.off > 0 then
    l:add((' · %d off'):format(count.off), 'TeamMuted')
  end
  local setup = state.times.setup and ('setup ' .. ms(state.times.setup)) or ''
  if l.width + #setup + 2 < width then
    l:to(width - #setup - 1):add(setup, 'TeamTime')
  end
  push(screen, l)
  local tabs = line():add(' ')
  for i, name in ipairs({ 'Teams', 'Profile', 'Log' }) do
    local active = name:lower() == current
    tabs:add((' %d %s '):format(i, name), active and 'TeamTabActive' or 'TeamTab'):add(' ')
  end
  push(screen, tabs)
  push(screen, line():add(string.rep('─', width), 'TeamRule'))
end

--- Plain lines from views.lua: table headings muted, numbers and levels highlighted.
---@param screen team.ui.Screen
---@param lines string[]
local function text_body(screen, lines)
  for _, s in ipairs(lines) do
    local l = line():add(' ')
    local start = #l.text
    local heading = s:find('^  team ') or s:find('^  plugin ')
    l:add(s, heading and 'TeamMuted' or nil)
    for from, to in s:gmatch('()%d+%.%d%d()') do
      if not heading then
        l.hls[#l.hls + 1] = { from = start + from - 1, to = start + to - 1, group = 'TeamTime' }
      end
    end
    for _, lv in ipairs({ { 'ERROR', 'TeamFailed' }, { 'WARN', 'TeamMissing' }, { 'DEBUG', 'TeamMuted' } }) do
      local from, to = s:find('  ' .. lv[1] .. ' ', 1, true)
      if from then
        l.hls[#l.hls + 1] = { from = start + from + 1, to = start + to - 1, group = lv[2] }
      end
    end
    push(screen, l)
  end
end

--- Everything the window shows for a view at a width.
---@param current 'teams'|'profile'|'log'
---@param width integer
---@param view team.ui.View
---@return team.ui.Screen
function M.screen(current, width, view)
  local screen = { lines = {}, hls = {}, items = {}, width = width }
  header(screen, current, width)
  if view.help then
    for _, h in ipairs(help) do
      push(screen, line():add('  '):add(h[1], 'TeamKey', 18):add(h[2]))
    end
    return screen
  end
  if current == 'teams' then
    local cols = columns(width)
    for _, name in ipairs(state.team_order) do
      local t = state.teams[name]
      if #t.members > 0 then
        team_rows(screen, t, cols, width, view)
      end
    end
    local loose = state.list(function(p)
      return p.team == nil
    end)
    if #loose > 0 then
      push(screen, line():add(' ▾ '):add('in no team', 'TeamMuted'))
      for _, p in ipairs(loose) do
        plugin_row(screen, p, cols, width, view)
      end
    end
  else
    local views = require('team.views')
    local body = current == 'profile' and views.profile() or views.log()
    text_body(screen, vim.list_slice(body, 3))
  end
  return screen
end

return M
