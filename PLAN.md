# team.nvim - Plan

A plugin manager for Neovim built on `vim.pack`, where the unit you configure, load, update and profile is a **team**: a named group of plugins that share a load strategy, hooks and dependencies.

`vim.pack` owns the disk (install, lockfile, update, delete). team.nvim owns the session (when things load, in what order, what it cost, and showing it).

This replaces `team_nvim_architecture.md` (the blueprint). It also builds on cinch.nvim's `groups` branch (commit `23366c3`), which added groups as a shared load strategy. Section 7 says what changed from each.

## 1. Decisions

| Topic | Decision |
| --- | --- |
| Relation to cinch.nvim | Fresh code, teams-first. Plugin specs use cinch's field names and meanings, so `lua/plugins/*.lua` files from cinch work unchanged. Team rules start from cinch's group rules. No code dependency. |
| Backend | `vim.pack` only. One module (`team.pack`) is the only code that calls it. |
| Lockfile | `vim.pack`'s `nvim-pack-lock.json`. team.nvim writes no lockfile of its own. |
| Events | Neovim `User` autocmds (`User TeamLoad`, ...) with `data` payloads. Users can hook the same events; errors are not swallowed. |
| Bad config | A mistake in config warns, names the file, and falls back. It never stops the other plugins from loading. Same as cinch. |
| Neovim | 0.12 minimum. Nightly-only `vim.pack` features (manifests, `scripts`) used only when present. |
| Tests | `nvim -l tests/run.lua`. Each case is the `init.lua` of its own headless Neovim with isolated XDG dirs and local git repos as plugin sources. No network, no plenary. |

## 2. Teams

A team is a load strategy (`load` and triggers) written once, plus what cinch's groups do not have: dependencies between teams, team hooks, and operations on the team as a whole.

### 2.1 Fields

| Field | Meaning |
| --- | --- |
| `plugins` | List of plugin specs (string or table). Declaration order is kept. |
| `load`, `event`, `ft`, `cmd`, `keys`, `after_team` | The team's load strategy. Members inherit it (2.3). `after_team` names one or more teams: the batch loads right after any of their batches has loaded. It is a trigger only, adding no dependency: another trigger can load the team first. A name nothing defines, or the team itself, warns and is ignored; a disabled one warns. |
| `order` | A number, lower first: the team's place among teams (2.5). Teams without one come after those with one. |
| `deps` | Team names this team needs (one name or a list). Before any member loads, each listed team's batch (2.4) has loaded; loading a member pulls them in. Definitions add to the list. A name that nothing defines, the team itself, or a team with no `load` or trigger of its own (so no batch to wait for) warns and is ignored. A cycle warns and drops the edge that closes it. |
| `enabled`, `cond` | `false` or a function returning `false` turns the whole team off: no install, no load. A function gets the team record; one that raises leaves the team on, with a warning. |
| `init` | `function(team)`. Every startup, during `setup()`, before any member loads. For `vim.g` options and the like. |
| `pre` | `function(team)`. Once, right before the first member loads, whichever member that is. |
| `post` | `function(team)`. Once, after the team's batch has loaded. |

An unknown field, or an unknown `load`, warns and is ignored.

### 2.2 Declaring teams and membership

Three places define a team. One name is one team: definitions merge field by field in read order (`setup()` teams by name first, then team files sorted by path, so `lsp.lua` before `lsp/`), and the later value wins. Team files are read from `teams_dir` (default `'teams'`, a module path under `lua/` on the runtimepath, or a folder; `false` reads none).

```lua
-- 1. setup()
require('team').setup({
  teams = {
    core = { load = 'now', plugins = { 'nvim-lua/plenary.nvim', 'nvim-mini/mini.icons' } },
  },
})

-- 2. lua/teams/git.lua: the file is the team, its name is the file name
return {
  deps = { 'core' },
  event = 'BufReadPre',
  plugins = {
    { 'lewis6991/gitsigns.nvim', opts = {} },
    { 'sindrets/diffview.nvim', cmd = 'DiffviewOpen' },
  },
}

-- 3. lua/teams/lsp/**/*.lua: every file under the folder returns specs for team `lsp`.
--    The folder alone defines the team; lua/teams/lsp.lua (if present) holds its fields.
```

Plugin specs outside teams come from `spec` (default `{ 'plugins' }`, as in cinch: module paths, folders, or inline specs). A file returns one spec or a list of them. A file that fails to load or returns the wrong shape is reported, and every other file is still read.

A plugin is in exactly one team, decided in this order:

1. The spec's own `team = 'name'` field. `team = false` puts it in no team.
2. The team whose `plugins` list (or folder) holds the spec.
3. Otherwise, team `default`. It has no strategy unless you define one (`teams = { default = { load = 'later' } }`); `team = false` escapes it.

A plugin claimed by two teams stays in the first by read order, and the second warns. A spec nested in another plugin's `deps` is not a member because of where it is nested, and a plugin only ever named as a dependency is in no team (not `default`) unless its spec names one: a library should load with what needs it, not with a strategy. A `team` field naming a team nothing defines warns and is ignored.

Why an explicit `plugins` key, and not cinch's form with specs as list items beside the group's fields: cinch needs a shape rule to tell a group table from a spec that joins a group (`{ 'owner/repo', group = 'git' }`). With `plugins`, a table is a team or a spec by its keys, with no guessing.

Specs with the same plugin `name` merge into one, as in cinch: a later field replaces an earlier one (lists whole, `false` included), `deps` keep every entry, `data` merges deep, and every `opts` is kept as a part. A spec nested in `deps` applies over the plugin's own spec, whichever file is read first; one that only names the plugin (`deps = { 'owner/repo' }`) changes nothing, so a fork's `src` stays. `opts` parts resolve in cinch's order: tables and functions that take no `opts` build the base in read order, then functions that take `opts` extend it in read order.

### 2.3 Inheritance (cinch's group rules)

- **Field by field.** A member takes each team field it does not set itself (`load`, `event`, `ft`, `cmd`, `keys`, `after_team`; not `order`). Its own `event` replaces the team's `event`; its own `cmd` sits beside the team's `event`. `event = false` drops the team's `event` only.
- **A team's `load` is explicit.** A team with `load = 'later'` makes its members load later, and a trigger on a member is ignored with a warning naming the team.
- **A member's own `load`** other than `'trigger'` takes none of the team's triggers, and nothing warns.
- **Default `load`** when nothing sets one: `'trigger'` if the resolved spec has a trigger, `'later'` otherwise. A plugin that is only another's dependency loads with the plugin that needs it.
- **VeryLazy** (lazy.nvim's): alone it means `later`; beside other events it is dropped and kept as a deadline, so the plugin loads on whichever comes first. A team with only `event = 'VeryLazy'` is a `later` team.

### 2.4 The team batch

A team's **batch** is the enabled members whose load moment is the team's: they set no `load` of their own and inherited the team's `load` or at least one of its triggers. A member that drops every team trigger (`event = false` in an `event` team) is not in it. A team with no `load` or trigger of its own has no batch: its members load their own ways, and its `post` runs once every enabled member has loaded. The batch loads together, in declaration order (each member's `deps` first), when the team's moment comes: at startup for `now`, in the queue for `later`, or when any of the team's triggers fires.

- In the git example, both plugins are in the batch: diffview inherits `BufReadPre` and adds `:DiffviewOpen`. `:DiffviewOpen` before any buffer loads only diffview; the rest of the batch loads on `BufReadPre`.
- A member outside the batch (say `load = 'now'` in a `trigger` team) loads on its own schedule. It still runs the team's `pre` first and pulls the team's `deps`.
- `post` waits for the batch only, so it always runs once the team's moment comes, even when a member with its own schedule never loads.
- `deps` waits for the needed team's batch. A team loads no later than the earliest moment of any team that needs it (its batch, or a member with its own `load`), and the pull carries down a chain of deps. Setup warns once per pulled team: ``team `mid` loads at `now`, not `later`, because team `ui` needs it``. A member's own `load` is left as written.

Team states: `pending`, `partial` (some members loaded), `loaded` (batch done), `failed` (a batch member failed), `disabled`.

### 2.5 Order

Loading goes by phase first: `now` during `setup()`, then the `later` queue once the UI is up, then whatever triggers fire. Inside each phase:

Teams in topological order of `deps`, ties broken by `order` (lower first, teams without one after) and then read order; `default` comes last unless you give it an `order` or define it earlier. Inside a team, members by their own `order` (same rule), then declaration order. A plugin's `deps` can only move another plugin earlier. Plugins in no team come last, by `order` then declaration order. A plugin's `order` sorts it only among its team's members. A plugin depending on itself, on a name no spec declares, or in a cycle warns and the edge is dropped; one depending on a disabled plugin warns. A plugin only ever named as a dependency is turned off once nothing that is on needs it, however deep.

## 3. Plugin specs

The same fields as cinch, so specs port unchanged: `[1]`/`src`, `name`, `version`/`commit`/`tag`/`branch`, `load` (`now`, `later`, `now_if_args`, `trigger`), `lazy`, `event`, `ft`, `cmd`, `keys`, `deps`/`dependencies`, `enabled`/`cond`, `init`, `build`, `opts`, `main`, `config`, `after`, `module`. New: `team` (2.2), `after_team` (a trigger, as on teams) and `order` (its place among its team's members). lazy.nvim's `priority` is not read; use `order`. cinch's `group` is read as `team` with a one-time note.

Note: a plugin's `after` is a hook (runs after `config`), as in cinch. That is why team dependencies are `deps`, not `after`.

Plugin states: `disabled`, `missing`, `installing`, `installed`, `queued`, `loading`, `loaded`, `failed`.

## 4. Architecture

Data flows one way. Only `state` is shared, and only `loader` and `pack` write plugin/team status.

```
setup(opts)
  -> config     validate options, apply defaults
  -> collect    read setup teams, lua/teams/**, merge teams and same-name specs
  -> spec       normalize plugin specs (src, name, version, triggers)
  -> graph      membership, inheritance, batches, team + plugin deps, topo order
  -> pack       vim.pack.add(all enabled specs, { load = noop }) - install + register, no packadd
  -> schedule   now: load in order | later: queue | trigger: arm stubs
       -> loader   team deps -> team pre -> plugin deps -> packadd -> after/plugin -> opts/config/after -> team post
       -> state    status + timings
       -> events   User TeamPluginLoad / TeamLoad / TeamInstall / ...
            -> ui  re-render (throttled)
```

| Module | Job |
| --- | --- |
| `team/init.lua` | `setup()`, public Lua API (`get`, `load`, `teams`, `now`/`later` for user functions). |
| `team/config.lua` | Defaults, option validation with typed warnings. |
| `team/collect.lua` | Read team definitions and spec entries from `setup()`, `teams_dir` and `spec`, in read order, with each origin (file, index). Checks shape only. |
| `team/notes.lua` | Problems found while reading config, each with a level and recorded once. Pure modules return them; `setup()` reports them. |
| `team/spec.lua` | Plugin spec normalization. Pure. |
| `team/graph.lua` | Membership, inheritance, batches, ordering, cycle warnings. Pure. |
| `team/pack.lua` | The only caller of `vim.pack`. Passes `data = { team = name }` so `PackChanged` handlers see the team. |
| `team/loader.lua` | Load one plugin, one batch, or a whole team, with timing (packadd, config and team hooks measured separately). |
| `team/schedule.lua` | `now` list, `later` queue drained after `UIEnter` within a per-tick time budget. |
| `team/triggers.lua` | `event`/`ft` autocmds, `cmd` and `keys` stubs, replay of the key or command that fired. One stub per trigger value, shared by every plugin and team batch behind it. |
| `team/state.lua` | Records for teams and plugins. Single source of truth. |
| `team/events.lua` | `User` autocmd emit helpers, event name constants, warning reporter that names the origin file. |
| `team/log.lua` | In-memory log ring, read by UI and `:Team log`. |
| `team/command.lua` | `:Team` with subcommands and completion. |
| `team/health.lua` | `:checkhealth team`. |
| `team/ui/` | Window, render, actions (milestone 5). |
| `plugin/team.lua` | Defines `:Team` only. Nothing else runs before `setup()`. |

Why `vim.pack.add` with a no-op `load`: it installs missing plugins and registers every spec in one call (so `vim.pack.get()`, `:packupdate` and the lockfile see all of them) without putting anything on the runtimepath. team.nvim then runs `:packadd` itself when each plugin's time comes, and sources `after/plugin` when loading after `VimEnter`, as `vim.pack` does. The `load` callback is also how team.nvim learns each plugin's path; a plugin it is never called for is `missing`, with the reason taken from `vim.pack`'s error.

### 4.1 Loading

- **setup()** runs once a session (a second call warns and is ignored). In order: read config, report every note, register and install with `vim.pack`, run each enabled team's `init` (team order) then each plugin's `init` (load order), then load the `now` phase in load order: a batch member when its team's moment (after pulls) is `now`, any other plugin when its own `load` is `now`; `now_if_args` counts as `now` when Neovim started with a file. Every trigger is armed before the `now` phase, so `after_team` is watching when `now` teams load; your `now()` functions run right after the `now` plugins; then the `later` plugins are queued and the queue starts.
- **While `init.lua` runs, loading is `:packadd!`**, as in `vim.pack` and cinch: the plugin joins the runtimepath and Neovim's startup pass sources its `plugin/` and `after/plugin/` files once. So a `now` plugin's `config` runs before its own `plugin/` files. A plain `:packadd` there would source `plugin/` twice. Each `:packadd` puts its plugin first on the runtimepath, so the startup pass sources the last loaded first. After startup, a load sources `plugin/` then `after/plugin/` before `config`.
- **One plugin**: its team is made ready first (the batches of the teams it needs, then `TeamLoadPre` and `pre`, once), then its own deps, then `TeamPluginLoadPre`, `:packadd`, `opts`, `config` (or `require(main).setup(opts)`; `config = true` calls `setup()` with nothing), `after`, `TeamPluginLoad`. `packadd` and the config steps are timed separately. `main` is the spec's, else a module named like the plugin (`nvim-foo`, `foo.nvim`, `foo-nvim` give `foo`), else the plugin's only module; otherwise the plugin fails asking for `main`.
- **Failures**: an error in `opts`, `config`, `setup()` or `after`, a missing plugin, a failed dependency, or a needed team that did not load fails the plugin, reported once with the reason (`TeamPluginFail`). A failed batch member fails its team (reported once) and its `post` does not run. An error in a team hook or a plugin's `init` is reported and loading carries on.
- **Team done**: once its batch (or, with no batch, every enabled member) has loaded, the team is `loaded`, then `post` runs, then `TeamLoad` fires with the team's total ms. A team is `loaded` before `post` runs so a `post` that loads another member does not run twice.
- **Events** (`User` autocmds, see `lua/team/events.lua` for each one's data): `TeamInstall`, `TeamLoadPre`, `TeamPluginLoadPre`, `TeamPluginLoad`, `TeamPluginFail`, `TeamLoad`, `TeamState`, `TeamSetup`, `TeamLater`, `TeamReport`.
- **Messages**: everything goes to the log; warnings and errors also go to `vim.notify`, prefixed `team.nvim:`. The window (milestone 5) can take that over.
- **Lua API**: `setup(opts)`, `get(name)`, `teams()`, `load(name)`, `load_team(name)`, `now(fn)`, `later(fn)`.
- **Options** `confirm` (default `true`): passed to `vim.pack.add`, which asks before installing. `budget` (default `5`): ms of `later` loading per event-loop tick.

### 4.2 The `later` queue and triggers

- **`later`**: a batch member whose team's moment is `later`, a plugin whose own `load` is `later`, `now_if_args` without a file, and a VeryLazy deadline. The queue starts on `UIEnter` (`VimEnter` when no UI is coming, as in headless Neovim), loads in load order, and yields to the event loop once a tick has used `budget` ms, so drawing and typing go on between plugins. Anything that loaded meanwhile (a dependency, a trigger) is skipped. `later(fn)` joins the queue in the order you call it; an error in one is reported with where you wrote it. `TeamLater` fires when the queue first drains.
- **One watch per trigger value**, shared by every plugin behind it, kept in load order. When it fires, those plugins load in that order (a team's batch together, since its members share the team's values), then the trigger is replayed once, only if something loaded.
- **`event`** (`'BufReadPre'`, `'User Foo'`, `'BufRead *.lua'`): the replay runs only the autocmds of that event the load added: a group the plugin made runs whole through Neovim, so a Vimscript autocmd keeps its `s:` functions; a lone callback is called with the event's args; yours do not run again. **`ft`** is `FileType <ft>` plus: filetype detection again if the plugin brought `ftdetect/`, then the runtime's ftplugin, indent and syntax groups for every buffer of that filetype.
- **`cmd`**: a stub command taking any range, bang and arguments. It goes before the plugin loads, even when another plugin is behind it too, so a Vimscript `command Foo` without `!` does not hit E174; if the plugin did not define the command and another plugin still waits on it, the stub comes back. The replay runs the command as typed. Completing the command loads the plugins and asks the real command. A command something else defined before the plugin loaded is left alone, with a warning.
- **`keys`**: `'lhs'` or `{ 'lhs', rhs, mode = ..., desc = ... }`. The replay feeds the keys again with their register and count, and in operator-pending mode the operator, so `dL` deletes to wherever `L` goes. A key with an rhs is mapped once the plugin has loaded. A mapping of yours the stub replaced comes back when the stub goes; a stub something else replaced is left alone, with a warning.
- **`after_team`**: when a team's batch has loaded (after its `post` and `TeamLoad`), what waits for it loads, in load order. Several teams after one team load by `order`; chains carry on.

## 5. Commands

| Command | Effect |
| --- | --- |
| `:Team` | Open the window. |
| `:Team load {team\|plugin}` | Load now. For a team: its `deps`, then its batch, then members not yet loaded. |
| `:Team update [{team\|plugin}...]` | `vim.pack.update()` for those plugins (all when empty). |
| `:Team enable\|disable {team}` | For this session only. Persistent disabling stays in config. |
| `:Team clean` | List plugins on disk that no spec names, `vim.pack.del()` them after confirmation. |
| `:Team profile` | Teams and plugins sorted by load cost. |
| `:Team log` | The log. |

## 6. Example config

```lua
require('team').setup({
  teams = {
    core = { load = 'now', plugins = { 'nvim-lua/plenary.nvim', 'nvim-mini/mini.icons' } },
    ui = {
      deps = { 'core' },
      load = 'now',
      plugins = {
        { 'folke/tokyonight.nvim', config = function() vim.cmd.colorscheme('tokyonight') end },
        { 'nvim-telescope/telescope.nvim', load = 'trigger', cmd = 'Telescope', opts = {} },
      },
    },
    lang = {
      ft = { 'lua', 'python' },
      init = function() vim.g.lang_ready = false end,
      post = function() vim.g.lang_ready = true end,
      plugins = { { 'nvim-treesitter/nvim-treesitter', load = 'now', build = ':TSUpdate' } },
    },
  },
})
-- plus lua/teams/git.lua from 2.2
```

## 7. What changed

### From the blueprint

| Blueprint | Problem | Plan |
| --- | --- | --- |
| `vim_pack.lua` runs `git clone` into `pack/team/start` | Not `vim.pack` at all. `start/` plugins are all sourced at startup, so no lazy loading is possible. No lockfile, no `PackChanged`, sequential and UI-blocking `systemlist`. | `vim.pack.add` installs (in parallel) into `vim.pack`'s `opt` dir; team.nvim decides when to `packadd`. |
| Swappable backend + lazy.nvim shim | lazy.nvim does its own loading and would fight the core. | Dropped. |
| Membership via `team = "ui"` *and* a `plugins` map, plus undefined "inferred" teams | Two unordered sources of truth. | One precedence order (2.2), lists keep declaration order. |
| `name = "owner/repo"` | `packadd` needs the directory name. | `src` and `name` separate, `vim.pack`'s naming rule. |
| `order` on teams; sort compares `a.team.order < b.team.order` | Crashes when `order` is nil. | Order from team `deps`, ties by read order. |
| `later` = `vim.defer_fn(..., 0)` per plugin | All fire in one tick: the stall moves, it is not removed. | One queue, per-tick time budget. |
| Trigger phase as a stub | No design for cmd/keys stubs or replay. | `triggers.lua`. |
| Missing deps, `opts`/`config`, `init`, `build`, `enabled`/`cond` | Cannot replace the current setup. | cinch's spec fields (section 3). |
| Custom `dispatch` with `pcall` per listener | Errors vanish; UI re-subscribes on each open. | `User` autocmds; UI clears one augroup. |
| `team.state` and `core.session` | Two copies of runtime state. | One `team.state`. |
| Profiling times `packadd` only | Most cost is `require` + `setup()`. | `packadd`, config and hooks timed separately, summed per team. |
| UI parses plugin names from rendered lines; deprecated `nvim_buf_set_option` | Fragile. | Line-to-record map; `vim.bo`. |
| `plugin/team.nvim`; "Antigravity Marketplace" | Not sourced by Neovim; not a plugin channel. | `plugin/team.lua`; GitHub + rockspec later. |

### From cinch's groups

| cinch groups | team.nvim | Why |
| --- | --- | --- |
| A group is a load strategy only | Adds team `deps`, `init`/`pre`/`post` hooks, batch loading, `:Team load/update/enable/disable`, per-team status and timing | The four team powers chosen for this project. |
| Field-by-field inheritance, `false` drops a field, group `load` is explicit, own non-trigger `load` takes no triggers | Kept as is | Already tested in `tests/cases/groups.lua`; it lets diffview keep `BufReadPre` and add a command. |
| Same name merges, later wins; unknown fields and undefined groups warn | Kept | Bad config never breaks startup. |
| Nested `deps` specs are not members | Kept | |
| Four ways in, by precedence: spec `group`, wrapping table, setup `plugins` list, setup `dir` | Two: spec `team`, the team's `plugins` list or folder | Fewer cases to warn about (cinch's test has three "listed twice" style warnings). |
| Group table = specs as list items beside the fields, told apart by a shape rule | Explicit `plugins` key | No shape guessing. |
| `dir = 'lsp'` option | Convention: `lua/teams/lsp/` | One less option; folder name is the team name. |
| Plugin `after` hook | Kept on plugins; team dependencies are `deps` | Avoids one field name meaning two things. |

## 8. Milestones

Each milestone ends with stylua, luacheck, lua-language-server and the tests green.

| # | Scope | Done when |
| --- | --- | --- |
| 0 | Scaffold: layout, `.stylua.toml`, `.luacheckrc`, `.luarc.json`, `Makefile` (`check`, `lint`, `typecheck`, `test`), `tests/run.lua` harness (parallel cases, fixture repos from `tests/fixtures/<name>/`, isolated XDG and git config, `phases`/`args` headers) and helpers (`eq`, `ok`, `noted`, `wait`, `write`, `after_startup`), CI on v0.12.0, stable and nightly (Linux + macOS). | The harness case and the runner self-test (`tests/runner_cases/`) pass locally on 0.12 and nightly, and in CI. |
| 1 | `config`, `collect`, `spec`, `graph`, `notes`: membership, merging, inheritance, batches, deps ordering, every warning. Pure Lua; problems are returned as notes for `setup()` to report in milestone 2. | Cases `spec`, `config`, `collect`, `teams` (ported from cinch's `groups.lua`), `batches`, `order`. |
| 2 | `pack`, `loader`, `state`, `events`, `log`, `setup()`: register + install via `vim.pack.add`, `now` loading, `opts`/`config`/`after`/`init`, team hooks, timing, events, failures (4.1). | Cases `startup` (two sessions over the same dirs), `failures`, `api`, `args`: a real headless start loads `now` teams from local repos in order, hooks run once, events fire. |
| 3 | `schedule` + `triggers`: `later` queue with `budget`, `now()`/`later()`, `event`, `ft`, `cmd`, `keys` with replay, `after_team` on teams and plugins, `order` on teams and plugins, batches on triggers, team `deps` pulling across phases (4.2). | Cases `triggers`, `later`, `after_team`, `pull`, and `order` extended. |
| 4 | `:Team` commands, `health`, `:Team profile`, `:Team log`. | Each subcommand has a case; `:checkhealth team` clean. |
| 5 | UI: teams as collapsible sections with status and summed time, plugin rows, actions (load, update, enable/disable, open dir), help, throttled live render. | Visual check at narrow and wide sizes, light and dark. |
| 6 | `build` hooks on `PackChanged`, `:Team clean`, first start deferred to `UIEnter` with the window showing installs (cinch's behavior, no `defer` option). | Fresh-machine case: lockfile present, nothing on disk, window shows installs. |
| 7 | README, `doc/team.txt`, migration notes from cinch (`group` to `team`, `groups` setup to `teams`). | `:h team` works; README example runs as is. |

## 9. Not now

- `require()`-triggered loading (cinch's `module`; the field is accepted but inert until revisited after milestone 3).
- Importing lazy.nvim spec files.
- Persistent session enable/disable.
- Update review UI beyond what `vim.pack.update()` already shows.
