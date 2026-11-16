-- The window: its size and place, team rows that fold, plugin rows with details, the keys,
-- the cursor kept on its item across redraws, live redraws at most once per throttle, the
-- layout at narrow and wide sizes, highlights from the colorscheme, and nothing left
-- behind once it closes.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.write('lua/plugins/loose.lua', { ('return { %q, load = "trigger" }'):format(H.src('eps')) })
require('team').setup({
  confirm = false,
  teams_dir = false,
  teams = {
    core = { load = 'now', plugins = { H.src('libby') } },
    git = { event = 'User GitGo', plugins = { H.src('gamma.nvim'), { H.src('delta'), cmd = 'DeltaCmd' } } },
    lazy = { load = 'trigger', plugins = { H.src('beta.nvim') } },
    bad = { load = 'now', plugins = { { H.src('broken.nvim'), opts = {} } } },
  },
})

H.after_startup(function()
  H.wait_later()
  vim.v.errmsg = ''
  local ui, api = require('team.ui'), vim.api
  local team = require('team')

  ---@return string[]
  local function lines()
    local buf = assert(ui.handles())
    return api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  ---@param pattern string
  ---@return integer? row
  local function row_of(pattern)
    for i, l in ipairs(lines()) do
      if l:find(pattern) then
        return i
      end
    end
  end
  ---@param pattern string
  local function goto_row(pattern)
    api.nvim_win_set_cursor(select(2, ui.handles()), { assert(row_of(pattern), pattern), 0 })
  end
  ---@return team.ui.Item?
  local function at()
    return ui.item()
  end

  -- Size and place, at the headless 80 x 24.
  vim.cmd('Team')
  local buf, win = ui.handles()
  ---@cast buf integer
  ---@cast win integer
  local cfg = api.nvim_win_get_config(win)
  H.eq({ cfg.relative, cfg.width, cfg.height }, { 'editor', 64, 18 }, '80% of 80 x 23')
  H.eq({ cfg.row, cfg.col }, { 1, 7 }, 'centred, border included')
  H.eq(cfg.title, { { ' team.nvim ' } }, 'titled')
  H.eq(vim.bo[buf].modifiable, false, 'read-only')

  -- Header, tabs and rows, teams in order.
  local l = lines()
  H.ok(l[1]:find('5 teams · 6 plugins: 1 loaded · 4 waiting · 1 failed', 1, true), 'summary: ' .. l[1])
  H.ok(l[2]:find(' 1 Teams   2 Profile   3 Log ', 1, true), 'tabs: ' .. l[2])
  H.eq(l[3], string.rep('─', cfg.width), 'a rule')
  H.ok(
    row_of('▾ core%s+loaded%s+now%s+1/1') < row_of('▾ git') and row_of('▾ git') < row_of('▾ lazy'),
    'in order'
  )
  H.ok(row_of('libby%s+loaded') == row_of('▾ core') + 1, 'members under their team')
  local count_col = {}
  for _, name in ipairs({ 'core', 'git', 'lazy' }) do
    count_col[#count_col + 1] = lines()[row_of('▾ ' .. name)]:find('%d+/%d+')
  end
  H.eq({ count_col[2], count_col[3] }, { count_col[1], count_col[1] }, 'counts in one column, loaded or not')
  H.ok(row_of('broken.nvim%s+failed%s+`broken.setup%(%)`'), 'a failure and why')
  H.ok(row_of('▾ default') and row_of('eps%s+installed') == row_of('▾ default') + 1, 'team default last')
  H.eq(at(), { kind = 'team', name = 'bad' }, 'the cursor starts on the first team, bad by name')
  for _, s in ipairs(l) do
    H.ok(vim.fn.strdisplaywidth(s) <= cfg.width, 'no row wider than the window: ' .. s)
  end

  -- Highlights: from links your colorscheme can override, kept across a colorscheme change.
  local marks = api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  local groups = {}
  for _, m in ipairs(marks) do
    groups[m[4].hl_group] = true
  end
  for _, g in ipairs({ 'TeamTeam', 'TeamLoaded', 'TeamFailed', 'TeamWaiting', 'TeamTime', 'TeamTabActive' }) do
    H.ok(groups[g], 'uses ' .. g)
  end
  H.eq(api.nvim_get_hl(0, { name = 'TeamLoaded' }).link, 'DiagnosticOk', 'a default link')
  vim.cmd('colorscheme default')
  H.eq(api.nvim_get_hl(0, { name = 'TeamLoaded' }).link, 'DiagnosticOk', 'back after :colorscheme')
  api.nvim_set_hl(0, 'TeamLoaded', { fg = '#00ff00' })
  ui.highlights()
  H.eq(api.nvim_get_hl(0, { name = 'TeamLoaded' }).fg, 0x00ff00, 'yours stays yours')

  -- Fold a team and open it again; the cursor stays on it.
  goto_row('▾ git')
  H.press('<CR>')
  H.ok(row_of('▸ git') and not row_of('gamma.nvim'), 'git folded')
  H.eq(at(), { kind = 'team', name = 'git' }, 'still on git')
  H.press('<CR>')
  H.ok(row_of('▾ git') and row_of('gamma.nvim'), 'open again')

  -- A plugin's details.
  goto_row('delta%s+installed')
  H.press('<CR>')
  H.ok(
    row_of('^%s+src%s+file://') and row_of('^%s+triggers%s+User GitGo :DeltaCmd'),
    'details:\n' .. table.concat(lines(), '\n')
  )
  H.ok(row_of('^%s+team%s+git, in its batch'), 'its team')
  H.press('<CR>')
  H.eq(row_of('^%s+src%s+'), nil, 'and closed')

  -- Live: a load from elsewhere shows within the throttle, and the cursor keeps its item.
  local redraws = 0
  local redraw = ui.redraw
  ---@diagnostic disable-next-line: duplicate-set-field
  ui.redraw = function()
    redraws = redraws + 1
    redraw()
  end
  goto_row('delta%s+installed')
  api.nvim_exec_autocmds('User', { pattern = 'GitGo' })
  H.wait(function()
    return row_of('delta%s+loaded') ~= nil
  end, 'the window to show delta loaded')
  H.eq(at(), { kind = 'plugin', name = 'delta' }, 'still on delta')
  H.eq(redraws, 1, 'one redraw for every change of that load')
  redraws = 0
  local timers, new_timer = 0, vim.uv.new_timer
  vim.uv.new_timer = function()
    -- Only the window's own; vim.wait makes one too.
    if debug.traceback():find('/team/ui/', 1, true) then
      timers = timers + 1
    end
    return new_timer()
  end
  for _ = 1, 20 do
    api.nvim_exec_autocmds('User', { pattern = 'TeamState', data = {} })
  end
  vim.wait(100)
  vim.uv.new_timer = new_timer
  H.eq({ redraws, timers }, { 1, 1 }, '20 changes at once: one timer, one redraw')
  ui.redraw = redraw

  -- Keys.
  goto_row('beta.nvim%s+installed')
  H.press('l')
  H.eq(team.get('beta.nvim').state, 'loaded', 'l loads the plugin under the cursor')
  H.eq(team.get('beta.nvim').reason, 'window', 'from the window')
  goto_row('▾ lazy')
  H.press('e')
  H.eq(require('team.state').teams.lazy.state, 'disabled', 'e turns its team off')
  H.press('e')
  H.ok(require('team.state').teams.lazy.state ~= 'disabled', 'and on')
  goto_row('▾ core')
  H.press(']]')
  H.eq(at(), { kind = 'team', name = 'git' }, ']] next team')
  H.press('[[')
  H.eq(at(), { kind = 'team', name = 'core' }, '[[ previous team')
  H.press('zM')
  H.eq(row_of('libby'), nil, 'zM folds every team')
  H.press('zR')
  H.ok(row_of('libby'), 'zR opens them')
  H.press('<Tab>')
  H.ok(lines()[2]:find('2 Profile', 1, true) and row_of('team%s+state%s+ms%s+hooks'), '<Tab>: profile')
  H.press('<Tab>')
  H.ok(row_of('DEBUG  loaded `libby`'), 'then the log')
  H.eq(api.nvim_win_get_cursor(win)[1], #lines(), 'at its newest entry')
  H.press('1')
  H.ok(row_of('▾ core'), '1: teams')
  H.press('?')
  H.ok(row_of('fold a team, or show a plugin’s details'), '? help')
  H.press('?')
  H.ok(row_of('▾ core'), '? again: back')

  -- Narrow and wide.
  for _, size in ipairs({ { 50, 20 }, { 200, 50 } }) do
    vim.o.columns, vim.o.lines = size[1], size[2]
    api.nvim_exec_autocmds('VimResized', {})
    local c = api.nvim_win_get_config(win)
    H.ok(c.width + 2 <= size[1] and c.col >= 0, ('fits %d columns: width %d'):format(size[1], c.width))
    for _, key in ipairs({ '2', '3', '1' }) do
      H.press(key)
      for _, s in ipairs(lines()) do
        H.ok(vim.fn.strdisplaywidth(s) <= c.width, ('view %s: no row wider than %d: %s'):format(key, c.width, s))
      end
    end
    local beta = lines()[row_of('beta.nvim')]
    if size[1] == 50 then
      H.ok(not beta:find('window', 1, true), 'narrow: no reason column: ' .. beta)
    else
      H.ok(beta:find('team%s+window'), 'wide: how and why: ' .. beta)
      local delta = lines()[row_of('delta%s+loaded')]
      H.ok(delta:find('team, :DeltaCmd', 1, true), 'its team, and what it adds: ' .. delta)
    end
  end
  vim.o.columns, vim.o.lines = 80, 24
  api.nvim_exec_autocmds('VimResized', {})

  -- gf and go leave the window for the file or folder; leaving closes it, with its listeners.
  goto_row('eps%s+installed')
  H.press('gf')
  H.eq({ ui.is_open(), vim.fn.expand('%:t') }, { false, 'loose.lua' }, 'gf: the spec file')
  H.eq(pcall(api.nvim_get_autocmds, { group = 'team.ui' }), false, 'its listeners are gone')
  vim.cmd('Team')
  goto_row('libby%s+loaded')
  H.press('go')
  -- Neovim 0.12's netrw, opening the folder, leaves E31 in v:errmsg from a silenced unmap.
  vim.v.errmsg = ''
  local real = vim.uv.fs_realpath
  H.eq(real(vim.fn.getcwd(0)), real(assert(team.get('libby').path)), "go: the plugin's folder, in a tab of its own")
  H.eq(#api.nvim_list_tabpages(), 2, 'a new tab')
  vim.cmd('tabclose')
  vim.cmd('Team')
  vim.cmd('wincmd p')
  H.wait(function()
    return not ui.is_open()
  end, 'leaving to close it')
end)
