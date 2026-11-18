# team.nvim

A plugin manager for Neovim, built on `vim.pack`, where plugins come in teams.

A team is a named group of plugins that share a way of loading: at startup, once the UI is up, on an event, a filetype, a command or a key, or right after another team. You load, update, turn off and profile a team as one thing. `vim.pack` keeps the disk: installs, the lockfile, updates and deletes. team.nvim decides when each plugin loads, runs builds, times everything, and shows it in one window.

- Teams with their own load strategy, which members inherit field by field, plus hooks that run before the first member loads and after the team has.
- `deps` between teams, and `after_team` to load a team right after another one.
- `order` to sort teams, and plugins inside a team, lower first.
- Triggers that replay what fired: the event's new autocmds, the command as you typed it, the keys with their count and operator.
- Builds that run in the background. A plugin waits for its build and loads after it.
- A first start you can watch. On a new machine nothing installs during `init.lua`. The window opens once the UI is up, and each row turns `installed` as its clone finishes.
- Plugin specs use cinch.nvim's fields, so your `lua/plugins/*.lua` files work as they are.

## Requirements

- Neovim 0.12 or newer, for `vim.pack`.
- `git` on your `PATH`.

## Install

Put this at the top of your `init.lua`:

```lua
vim.pack.add({ 'https://github.com/Techdeus88/team.nvim' })
```

On a new machine that call installs every plugin your lockfile lists while `init.lua` runs, before there is a window to show it in. That is how `vim.pack` works: its first call of a session installs what the lockfile lists. To let team.nvim hold the first start for the window, clone team.nvim with git instead:

```lua
local path = vim.fn.stdpath('data') .. '/site/pack/core/opt/team.nvim'
if not vim.uv.fs_stat(path) then
  vim.fn.system({ 'git', 'clone', '--filter=blob:none', 'https://github.com/Techdeus88/team.nvim', path })
end
vim.cmd.packadd('team.nvim')
```

## Quick start

<!-- example: tests/cases/readme.lua runs this block -->
```lua
require('team').setup({
  teams = {
    core = { load = 'now', order = 1, plugins = { 'nvim-lua/plenary.nvim' } },
    ui = {
      load = 'now',
      order = 2,
      plugins = {
        {
          'folke/tokyonight.nvim',
          config = function()
            vim.cmd.colorscheme('tokyonight')
          end,
        },
      },
    },
    -- Right after ui has loaded.
    help = { after_team = 'ui', plugins = { { 'folke/which-key.nvim', opts = {} } } },
    -- On the first buffer read. diffview also loads alone on its command.
    git = {
      event = 'BufReadPre',
      plugins = {
        { 'lewis6991/gitsigns.nvim', opts = {} },
        { 'sindrets/diffview.nvim', cmd = 'DiffviewOpen' },
      },
    },
    -- On :Telescope or <leader>ff, once core has loaded.
    find = {
      cmd = 'Telescope',
      deps = { 'core' },
      plugins = {
        { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
        {
          'nvim-telescope/telescope.nvim',
          deps = { 'telescope-fzf-native.nvim' },
          keys = { { '<leader>ff', '<Cmd>Telescope find_files<CR>', desc = 'Find files' } },
          config = function()
            require('telescope').setup({})
            require('telescope').load_extension('fzf')
          end,
        },
      },
    },
  },
})
```

Run `:Team` to see every team and plugin, and `:checkhealth team` if something looks off.

## Teams

A team has a strategy and a list of plugins.

| Field | What it does |
| --- | --- |
| `plugins` | The team's plugin specs, in order |
| `load` | `'now'`, `'later'`, `'now_if_args'` or `'trigger'`. See [When things load](#when-things-load) |
| `event`, `ft`, `cmd`, `keys` | Triggers, as on a plugin |
| `after_team` | A team or a list of them. The team loads right after any of them has. It is a trigger and nothing more: another trigger can load the team first |
| `deps` | Teams this one needs. Before any member loads, each of them has loaded. A team that needs a later one pulls it earlier, and says so |
| `order` | A number. Teams sort by it, lower first, and teams without one come after |
| `enabled`, `cond` | `false`, or a function that returns `false`, turns the whole team off. Nothing in it installs or loads |
| `init` | `function(team)` that runs at every startup, before anything loads |
| `pre` | `function(team)` that runs once, right before the team's first member loads |
| `post` | `function(team)` that runs once, after the team's batch has loaded |

A team comes from one of three places, and one name is one team. Definitions merge field by field. `setup()` comes first, then files sorted by path, and the later value wins.

In `setup()`:

```lua
require('team').setup({ teams = { core = { load = 'now', plugins = { 'nvim-lua/plenary.nvim' } } } })
```

In a file of its own, named after the team. This is `lua/teams/git.lua`:

```lua
return {
  event = 'BufReadPre',
  plugins = { { 'lewis6991/gitsigns.nvim', opts = {} } },
}
```

In a folder named after the team, where each file returns specs. This is `lua/teams/lsp/servers.lua`, and `lua/teams/lsp.lua` holds the team's own fields when there is one:

```lua
return { 'neovim/nvim-lspconfig' }
```

Plugins outside any team come from `lua/plugins/`, as in cinch, and join the team `default`. A spec's own `team = 'git'` puts it in that team wherever it is written, and `team = false` keeps it out of every team. A plugin that two teams list stays in the first one read, with a warning.

### What members inherit

A member takes each of `load`, `event`, `ft`, `cmd`, `keys` and `after_team` from its team when it does not set that field itself. Its own `event` replaces the team's `event`. Its own `cmd` sits beside the team's `event`, so diffview above loads with git on `BufReadPre` and also alone on `:DiffviewOpen`. `event = false` drops the team's event and keeps the rest.

A team's `load` is explicit. In a team with `load = 'later'`, a member's trigger is ignored, with a warning. A member with its own `load` other than `'trigger'` takes none of the team's triggers.

### The batch

A team's batch is the members that load at the team's moment: those that set no `load` of their own and took the team's `load` or one of its triggers. The batch loads together, in order, each member after its own deps. `post` runs once the batch has loaded, so a member with a schedule of its own never holds it back. A team with no `load` and no trigger has no batch. Its members load their own way, and its `post` runs once every member has.

## Plugin specs

The fields are cinch.nvim's, with the same meanings. The one exception is `module`, which is accepted and does nothing, since `require()` does not load plugins here.

| Field | What it does |
| --- | --- |
| `[1]` or `src` | Where the plugin comes from. `owner/repo` is a GitHub repo |
| `name` | Its name. The last part of `src` by default, as `vim.pack` names it |
| `version` | A branch, tag, commit or `vim.version.range()`. A string like `'^1.2'` becomes a range |
| `commit`, `tag`, `branch` | Become `version`. `commit` beats `tag`, which beats `version`, which beats `branch` |
| `team` | The team it is in, or `false` for none. cinch's `group` reads as `team` |
| `load`, `lazy` | When it loads. `lazy = false` is `'now'` and `lazy = true` is `'trigger'` |
| `event`, `ft`, `cmd`, `keys` | Triggers. An event can carry a pattern: `'User MyEvent'`. A key is `'lhs'` or `{ 'lhs', rhs, mode = 'n', desc = '...' }` |
| `after_team` | Load right after a team's batch |
| `order` | Its place among its team's members, lower first |
| `deps`, `dependencies` | Plugins that load first. `'owner/repo'` or a table is a spec, and a bare name like `'plenary.nvim'` names a spec written elsewhere |
| `enabled`, `cond` | `false`, or a function that returns `false`, turns it off |
| `init` | `function(plugin)` that runs at every startup, before it loads |
| `opts` | A table, or `function(plugin, opts)` that returns one or fills in the one it gets |
| `main` | The module whose `setup()` gets `opts`. team.nvim guesses it from the name, or takes the plugin's only module |
| `config` | `function(plugin, opts)` that runs in place of `setup(opts)`. `config = true` calls `setup()` with nothing |
| `after` | `function(plugin)` that runs after `config` |
| `build` | Runs after an install or an update. See [Builds](#builds) |

Specs of one plugin merge in the order they are read. A later field replaces an earlier one, `deps` keep every entry, and every `opts` is kept. Tables and functions that take no `opts` build the base, then functions that take `opts` extend it. A spec nested in `deps` applies over the plugin's own spec, wherever each is written.

A mistake in a spec warns with the file it is in, and the spec goes on without it. Nothing in your config stops your other plugins from loading.

## When things load

Loading goes by phase, then by order.

- `now` loads while `init.lua` runs. `now_if_args` is `now` when Neovim starts with a file and `later` when it does not.
- `later` loads once the UI is up, a few plugins at a time. The queue gives the event loop back after each tick that has used `budget` ms, so drawing and typing go on.
- `trigger` loads when a trigger fires. With no trigger, it loads when something asks for it: a plugin that depends on it, `:Team load`, or `require('team').load()`.

When nothing sets `load`, a plugin with a trigger is `trigger` and the rest are `later`. lazy.nvim's `VeryLazy` means `later`, and beside other events it is a deadline: whichever comes first loads the plugin.

Inside a phase, teams go after the teams they need, then by `order`, then in the order they were read. Members go by their own `order`, then in the order they were written, each after its deps.

While `init.lua` runs, team.nvim loads with `:packadd!`, as `vim.pack` does. Neovim's startup then sources each plugin's `plugin/` files once. A `now` plugin's `config` therefore runs before its own `plugin/` files.

### Triggers

One watch serves every plugin behind the same event, filetype, command or key. When it fires, those plugins load in order, then team.nvim replays what fired so the plugin sees it.

- **Events.** Only the autocmds the plugin just added run. Yours do not run twice, and a Vimscript autocmd keeps its `s:` functions.
- **Filetypes.** The same, and the plugin's ftplugin, indent and syntax files apply to every buffer of that filetype.
- **Commands.** The stub takes any range, bang and arguments, then runs the command as you typed it. Completing the command loads the plugin and asks the real one.
- **Keys.** They are fed again with their register and count, and in operator-pending mode with the operator, so `dL` deletes to wherever `L` goes. A key the spec maps is mapped once the plugin has loaded. A mapping of yours that a stub replaced comes back.

## Builds

`build` runs after `vim.pack` installs or updates the plugin.

| `build` | How it runs |
| --- | --- |
| `'make'` | A shell command, in the background, from the plugin's folder |
| `':TSUpdate'` | An Ex command. The plugin loads first |
| `function(plugin)` | With the plugin on the runtimepath but not loaded, so `require()` works |
| `function(plugin, done)` | The same, finished when it calls `done(ok, msg)` |
| `vim.fn['mkdp#util#install']` | The same, a Vimscript function called with no arguments |

A function is async only when it names a second parameter. A `function(...)` gets the plugin alone and ends when it returns.

A load that needs a plugin whose shell or function build is running waits, and runs when the build ends. A trigger that fired meanwhile is replayed then. A build that fails, or that quitting cut off, runs again at the next startup. Shell and async builds time out after `build_timeout` seconds.

## The first start

With plugins missing and a UI coming, nothing installs during `init.lua`.

- If your lockfile lists plugins that are not on disk, as on a new machine with your dotfiles, every plugin waits. `vim.pack`'s first call would install those during `init.lua` anyway.
- Otherwise only the missing plugins wait, and the rest start as usual.
- Headless Neovim installs during `init.lua`.

Plugins that wait show as `installing`, and their loads and triggers wait for them. Once the UI is up, the window opens and `vim.pack` installs them. Each row turns `installed` as its clone finishes, then everything that waited loads.

## Commands

| Command | What it does |
| --- | --- |
| `:Team` | Open the window |
| `:Team load {team or plugin}...` | Load now, with what it needs |
| `:Team update[!] [{team or plugin}...]` | `vim.pack.update()`. A team stands for its members, and no name means every plugin. With `!` the updates apply at once; without it `vim.pack` shows what will change and `:write` applies it |
| `:Team enable {team}` | Turn a team on for this session. What it needs installs, and its members load |
| `:Team disable {team}` | Turn a team off for this session. Members that have not loaded never will |
| `:Team clean[!]` | Delete plugins on disk that no spec names, after asking. `!` does not ask |
| `:Team profile` | The window on load costs |
| `:Team log` | The window on everything team.nvim did |

`:Team! update` works as well as `:Team update!`. Every subcommand completes, and so do its arguments.

A plugin updated after it has loaded warns you to restart. Lua modules cannot be unloaded.

## The window

`:Team` opens a float with three views. Switch with `<Tab>`, or `1`, `2` and `3`.

- **Teams** has a row per team: its state, when it loads, how many members have loaded, and their time. Under it is a row per plugin: its state, how it loads, why it loaded or what went wrong, and its time. `<CR>` on a plugin shows its details.
- **Profile** has `setup()`'s steps, then teams and plugins by load time, slowest first.
- **Log** has every step team.nvim took, newest at the cursor.

| Key | Does |
| --- | --- |
| `<CR>`, `o` | Fold a team, or show a plugin's details |
| `l` | Load the team or plugin under the cursor |
| `u`, `U` | Update it, or every plugin |
| `e` | Turn its team on or off for this session |
| `go` | Open the plugin's folder in a tab of its own |
| `gf` | Open the file that declares it |
| `zM`, `zR` | Fold every team, open every team |
| `]]`, `[[` | Next and previous team |
| `<Tab>`, `<S-Tab>` | Next and previous view |
| `?` | Every key |
| `q`, `<Esc>` | Close |

The window redraws as things change, and leaving it closes it. Its colors come from your colorscheme through highlight groups you can set yourself: `TeamLoaded`, `TeamFailed`, `TeamWaiting` and the rest, listed in `:h team-highlights`.

Warnings and errors show one short line at a time, so nothing stops you at "Press ENTER". The whole text is in `:Team log` and `:checkhealth team`.

## Setup

```lua
require('team').setup({
  teams = {},                   -- teams by name
  teams_dir = 'teams',          -- team files: lua/teams/ on the runtimepath, a folder, or false
  spec = { 'plugins' },         -- plugin specs: module paths, folders, or specs
  confirm = true,               -- vim.pack asks before installing
  budget = 5,                   -- ms of `later` loading per event-loop tick
  build_timeout = 300,          -- seconds a shell or async build may take
  ui = { size = 0.8, border = nil }, -- the window: share of the editor, and border
})
```

`setup()` runs once a session. A second call warns and changes nothing.

## Events

Each event is a `User` autocmd with its details in `data`:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'TeamPluginLoad',
  callback = function(ev)
    print(ev.data.plugin, ev.data.ms)
  end,
})
```

| Event | When | `data` |
| --- | --- | --- |
| `TeamInstall` | `vim.pack` installed plugins | `plugins` |
| `TeamLoadPre` | Before a team's first member loads | `team` |
| `TeamPluginLoadPre` | Before a plugin loads | `plugin`, `team`, `reason` |
| `TeamPluginLoad` | A plugin loaded and its config ran | `plugin`, `team`, `reason`, `ms` |
| `TeamPluginFail` | A plugin could not load | `plugin`, `team`, `err` |
| `TeamLoad` | A team's batch loaded and its `post` ran | `team`, `ms` |
| `TeamBuild` | A build finished | `plugin`, `kind`, `ok`, `ms`, `err` |
| `TeamState` | A team or plugin changed state | `plugin` or `team`, `state` |
| `TeamSetup` | `setup()` loaded the `now` plugins | `ms` |
| `TeamLater` | The `later` queue drained for the first time | `ms` |
| `TeamReport` | team.nvim reported something | `msg`, `level` |

## Lua

```lua
local team = require('team')
team.get('telescope.nvim')    -- a plugin's record: state, path, reason, time, ...
team.teams()                  -- every team, in load order
team.load('diffview.nvim')    -- load a plugin now; nil while it waits for an install or a build
team.load_team('git')         -- load a team now
team.update({ 'git' }, true)  -- update; true applies at once
team.enable_team('git')       -- for this session
team.disable_team('git')
team.open('profile')          -- the window on a view
team.now(function() end)      -- right after the `now` plugins
team.later(function() end)    -- in the `later` queue
```

## Coming from cinch.nvim

Plugin specs work unchanged. These change:

| cinch | team.nvim |
| --- | --- |
| `group = 'git'` on a spec | `team = 'git'`. `group` still works and says so once |
| `setup({ groups = { git = { event = 'BufReadPre' } } })` | `setup({ teams = { git = { event = 'BufReadPre' } } })` |
| A group's `plugins = { 'gitsigns.nvim' }`, names of specs written elsewhere | A team's `plugins` holds specs. To put a spec written elsewhere in a team, give it `team = 'git'` |
| A group's `dir = 'lsp'` | The folder `lua/teams/lsp/` |
| A file returning `{ group = 'git', event = ..., { spec }, { spec } }` | `lua/teams/git.lua` returning `{ event = ..., plugins = { { spec }, { spec } } }` |
| `cinch.now(fn)`, `cinch.later(fn)` | `require('team').now(fn)`, `require('team').later(fn)` |
| `:Cinch` | `:Team` |
| `priority` from lazy.nvim, not read | `order`, lower first |

cinch's `defer`, `disable_runtime`, `module`, `cmd_prefix`, `self`, `features`, `cinch.time` and the `messages`, `stats` and `updates` options have no counterpart. A `module` field in a spec is accepted and does nothing: `require()` does not load plugins. Groups gain what teams add: `deps` between teams, `after_team`, `order`, the `init`, `pre` and `post` hooks, and loading, updating and turning off a team as one.

## Development

```sh
make check                # lint, typecheck, test
make test CASE=triggers   # cases whose names contain `triggers`
```

Each case in `tests/cases/` is the `init.lua` of its own headless Neovim, with its own data, state and config folders. Plugins install from local git repos built from `tests/fixtures/`, so the suite needs no network. A header line `-- phases: N` runs a case N times over the same folders, to test what carries from one session to the next.
