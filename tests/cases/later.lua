-- The `later` queue: after the `now` phase, once the UI is up, in team order then member
-- order, `order` lower first; within `budget` ms per tick; your later() functions in turn
-- with the plugins, now() functions right after the `now` plugins; VeryLazy as a deadline.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

_G.trace = {}
local function mark(s)
  return function()
    table.insert(_G.trace, s)
  end
end
local team = require('team')
team.later(mark('later fn before setup'))
team.now(function()
  -- Right after the `now` plugins, so it can require them.
  table.insert(_G.trace, 'now fn sees ' .. require('team').get('libby').state)
end)
team.later(function()
  error('later boom')
end)
-- The first later plugin to load schedules a marker: with a tiny budget, it runs
-- before the next plugin does.
local marked = false
vim.api.nvim_create_autocmd('User', {
  pattern = 'TeamPluginLoad',
  callback = function(ev)
    if ev.data.reason == 'later' and not marked then
      marked = true
      vim.schedule(mark('next tick'))
    end
  end,
})
local later_events = 0
vim.api.nvim_create_autocmd('User', {
  pattern = 'TeamLater',
  callback = function()
    later_events = later_events + 1
  end,
})

team.setup({
  confirm = false,
  teams_dir = false,
  budget = 0.0001,
  spec = {
    { H.src('eps'), event = { 'VeryLazy', 'User Never' } },
    { H.src('plainy'), load = 'later', order = 1 },
  },
  teams = {
    now = { load = 'now', plugins = { H.src('libby') } },
    second = { load = 'later', order = 2, plugins = { H.src('delta'), { H.src('gamma.nvim'), order = 1 } } },
    first = { load = 'later', order = 1, plugins = { H.src('beta.nvim') } },
    unordered = { load = 'later', plugins = { H.src('entery') } },
  },
})
team.later(mark('later fn after setup'))
local at_setup = vim.deepcopy(_G.trace)

H.after_startup(function()
  H.wait_later()
  H.eq(at_setup, { 'now fn sees loaded' }, 'nothing later during init.lua; now() ran after the now plugins')
  H.eq(_G.trace, {
    'now fn sees loaded',
    'plugin libby',
    'later fn before setup',
    'plugin beta',
    'after beta',
    'next tick',
    'plugin gamma',
    'plugin delta',
    'after delta',
    'plugin entery',
    'plugin plainy',
    'plugin eps',
    'later fn after setup',
  }, 'teams by order (unordered last, default after), members by order, one plugin per tick')
  H.ok(H.noted('later function at later%.lua:%d+ failed: .*later boom'), 'a later function that raises')
  H.eq(team.get('eps').reason, 'later', 'VeryLazy beside an event that never fired: the queue loaded it')
  H.eq(later_events, 1, 'TeamLater once')
  team.later(mark('later fn after the queue'))
  H.wait(function()
    return vim.list_contains(_G.trace, 'later fn after the queue')
  end, 'a later() after the queue drained')
  _G.trace = {}
  team.now(mark('now fn after setup'))
  H.eq(_G.trace, { 'now fn after setup' }, 'now() after setup runs at once')
end)
