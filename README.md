# sarcina

A Neovim plugin manager built around a task engine. Each plugin expands into an ordered list of tasks (clone, build, runtimepath, config). A floating window shows each plugin's progress as the engine works.

## Layout

```
lua/sarcina/
├── init.lua          setup(): load, resolve, start; exports now, later, now_if_args, safely, stats, get
├── cli.lua           :Sarcina dispatcher (install, panel, help, ...)
├── manifest.lua      loads plugin specs from lua/plugins/**/*.lua
├── resolver.lua      orders plugins so dependencies come first, sets spec.triggers and each plugin's timing
├── task_factory.lua  turns spec fields (build, config, opts, event, ...) into tasks
├── main_module.lua   finds the module that a plugin's opts belong to
├── tasks.lua         task store and async runner; owns all task state
├── track.lua         stamps every task's created, started, ended and duration; keeps the session history
├── stats.lua         the public numbers, and one row per plugin: state, task 3 of 8, detail
├── executors.lua     one function per task type (git_clone, rtp, lua, cmd, shell, keymaps, trigger, make)
├── scheduler.lua     stubs and deferred loading for triggered plugins
├── keys.lua          parses `keys` entries into a lhs, an rhs, a mode and options
├── load.lua          when code runs: now, later, now_if_args, event, ft, keys and cmd, all under safely
├── replay.lua        repeats the command, key or event that woke a plugin, after it loads
├── startup.lua       splits a resolved manifest into the now phase and the queued rest
├── installer.lua     queues a resolved manifest and runs it (:Sarcina install)
├── paths.lua         install and staging locations
├── installs.lua      how long each install took, kept in a JSON file for later sessions
├── lock.lua          the lock file: the commit of every plugin, which fresh clones are pinned to
├── updater.lua       :Sarcina check and :Sarcina update
├── schema.lua        manifest and task validation
├── ui.lua            event bus, toasts, and when the window opens
└── window.lua        the floating window: the plugin list and a pane with the details of one
```

## Usage

```lua
require('sarcina').setup()
```

Installed plugins with `load = 'now'` load inside `setup()`, in the order received, dependencies first. Everything else runs in the background once the UI is up, and `require('sarcina.tasks').wait()` blocks until it is done. See [When plugins load](#when-plugins-load).

A spec is a table in any file under `lua/plugins/`. `owner/repo` as the first entry expands to a GitHub URL.

```lua
return {
    { 'nvim-lua/plenary.nvim' },
    {
        'nvim-telescope/telescope.nvim',
        deps = { 'plenary.nvim' },
        cmd = 'Telescope',
        opts = { defaults = {} },
    },
}
```

| Field | Does |
| --- | --- |
| `repo`, or the first entry | what to clone |
| `name` | plugin name; derived from the repo when missing |
| `deps` | plugins that must finish first |
| `load` | when the plugin loads: `'now'`, `'now_if_args'` or `'later'` (the default). `lazy = false` means `'now'` |
| `init`, `build`, `after` | `init` runs right after the install, `build` after that, and `after` once the plugin has loaded. A function is called with `plugin = { name, dir }`; a `build` function may take a second parameter, `done`, to run async (see below). A string is a Lua chunk, except that a `build` string is a shell command run in the plugin directory (`build = 'make'`), and any string starting with `:` is an Ex command (`build = ':TSUpdate'`). `build` runs only after a fresh clone or when the plugin's commit changes |
| `config` | called as `config(plugin, opts)` with `plugin = { name, dir }` |
| `opts` | a table, or a `function(plugin, opts)` that returns one or fills in the empty table it is given. Handed to `config(plugin, opts)`, or to `require(module).setup(opts)` when there is no `config` |
| `main` | the module to require; found from the plugin name when missing |
| `event`, `ft`, `cmd`, `keys` | triggers: the plugin loads when one fires. A `keys` entry is `'lhs'` or `{ lhs, rhs, mode = 'n', desc = ..., <keymap options> }`; with an `rhs`, sarcina defines the mapping when the plugin loads |
| `tasks` | an explicit task list, which skips the generated one |

Every plugin is cloned to `stdpath('data')/sarcina/plugins/<name>`. That directory is outside `'packpath'`, so Neovim never loads a plugin on its own. Sarcina adds it to `runtimepath`, with the plugin's `after/` directory behind it, when the plugin's `rtp` task runs. For a `now` plugin that is inside `setup()`, so Neovim sources its `plugin/` files in its own startup pass.

A `build` that succeeds records the plugin's commit in `.git/sarcina-build` inside the plugin directory, and later runs skip it while `HEAD` still matches (`build` shows `up to date`). A new commit from an update or a manual `git pull` runs it again. A build that fails leaves no record, so it runs again on the next launch. To force a rebuild, delete that file.

A function `build` that declares a second parameter is async: `build = function(plugin, done) ... end`. It gets `done(ok, msg)`, and the build stays `building` until it calls it, so the plugin's `rtp` and config wait and the commit is recorded only then. Use it for a build that runs in the background, such as a process or a task that finishes later:

```lua
build = function(_, done)
    require('blink.cmp'):build()
        :map(function() done(true) end)
        :catch(function(err) done(false, tostring(err)) end)
end,
```

`done` may be called from a callback, and `done(false, msg)` fails the build with `msg`. An error raised before `done` is called also fails it. A build that never calls `done` keeps the plugin, and anything that depends on it, waiting, because there is no timeout. A build with no second parameter finishes when it returns.

A function `build` finds the plugin on `runtimepath`, so it can `require` the plugin's modules and call its autoload functions, but the plugin's `plugin/` files are not sourced until the `rtp` task, after the build. A plugin whose `plugin/` files load a native binary, such as `fff.nvim` or `blink.cmp`, therefore does not run before its build has made the binary. An Ex command `build` (`build = ':TSUpdate'`) does source them first, because the command comes from there. Builds always run after the UI is up, even for a `now` plugin.

Without `main`, sarcina matches the plugin name, then the repo name, against the modules in the plugin's `lua/` directory, ignoring case, punctuation and `nvim` affixes. A lone module wins by default. If it cannot tell, the load task fails with the list of modules and asks you to set `main`.

## When plugins load

Every plugin has a timing. The resolver sets it, and `entry.timing` carries it.

| Timing | The plugin loads |
| --- | --- |
| `now` (eager) | inside `setup()`, before `VimEnter` and `UIEnter`, in the order received |
| `later` (lazy) | in the background once the UI is up, starting in the order received. This is the default |
| triggered | when its `event`, `ft`, `cmd` or `keys` fires (see [Triggers](#triggers)) |

- `load = 'now_if_args'` is `now` when Neovim was started with file arguments, and `later` otherwise.
- A plugin with triggers loads on them. `load` only picks the time for a plugin without triggers, except that `load = 'now'` wins and drops the triggers.
- A dependency loads no later than the plugins that need it. It takes the earliest timing among its dependents, so a `now` plugin pulls its dependencies in `now` too.
- There is no `priority`. The order of the manifest is the order of loading, with dependencies first.

`setup()` does this in order:

1. Resolve the manifest.
2. Run the `init` hook of every installed plugin.
3. Load every installed `now` plugin whose dependencies loaded: `rtp`, `config` or `opts`, `keys`, `after`. A failure is recorded, skips the rest of that plugin and its dependents, and is reported once the UI is up.
4. Arm the stubs of every installed triggered plugin, so the first buffer that Neovim reads after `init.lua` can wake it.
5. Queue everything else, and start it when the UI is up (when `VimEnter` fires if there is no UI): installs first, then builds, then the `later` plugins and, for triggered plugins that were not installed yet, their stubs, which catch up with what already happened.

A `now` plugin that is not installed yet cannot load before the UI, so on the first launch it is installed in the background and loads as soon as the installs are done.

The same timings are available to your own code, with errors reported instead of raised:

```lua
local sarcina = require('sarcina')

sarcina.now(function() vim.cmd.colorscheme('poimandres') end)
sarcina.later(function() require('some.heavy.module').setup() end)
sarcina.now_if_args(function() vim.cmd('syntax on') end)
sarcina.safely('event:BufReadPost *.lua', function() ... end)
sarcina.safely('ft:markdown', function() ... end)
sarcina.safely('cmd:Telescope', function() ... end)
sarcina.safely('keys:<leader>ff', function() ... end)
sarcina.safely('keys:nv <leader>y', function() ... end)
```

The four trigger loaders run the callback once, when they fire, and then repeat what fired them, after the callback has succeeded:

| Loader | Fires on | Repeats |
| --- | --- | --- |
| `event:<Event[,Event]> [pattern]` | the first of the events, which may be several, comma separated | the autocmds the callback added, and only those |
| `ft:<filetype[,filetype]>` | `FileType` | the same, and the `ftplugin`, `indent` and syntax files the callback brought are applied to the buffers of that filetype, plus `filetype detect` when it added `ftdetect` scripts |
| `cmd:<Command>` | the command | the command, with its args, bang, range and modifiers |
| `keys:[modes ]<lhs>` | the mapping, in normal mode unless modes come first | the key, fed again |

The loaders are named like the spec fields. The stub is removed before the callback runs, so the callback can define the real command or mapping, and an event loader is nested, so the events the callback causes run their handlers. If the callback fails, the error is reported and nothing is repeated.

`later` callbacks run in the order received, after `UIEnter`, one per 1 ms timer tick, so the editor handles input and redraws between them. This is how MiniMisc and MiniDeps pace it. Errors are reported with the place the callback was queued from. Errors raised before the UI is up are held and shown after it.

## Triggers

A spec with `event`, `ft`, `cmd` or `keys` is triggered: it loads when one fires. The resolver normalizes those fields into `spec.triggers`, and `triggers = false` forces a plugin to load eagerly.

- A triggered plugin only registers stubs for its triggers. When it is installed they exist as soon as `setup()` returns, so `nvim file.lua` wakes an `event` or `ft` trigger for its first buffer. The `load_trigger` row reads `waiting for :Telescope`.
- A plugin that is not installed yet registers its stubs once it is cloned, after the first buffer was read. It then catches up and loads at once if a trigger already happened: a loaded buffer whose filetype matches an `ft` trigger, a file buffer whose name matches a `BufRead`, `BufReadPre`, `BufReadPost`, `BufEnter`, `BufWinEnter`, `BufAdd` or `BufNew` trigger, or a `VimEnter` or `UIEnter` that already fired. The plugin's own handlers replay for the first such buffer. Commands, keys and other events, such as `User` ones, can only be started by the user.
- A plugin that is loading or loaded keeps no stubs, so registering it again, as `:Sarcina install` does, does not re-arm it.
- The first trigger to fire removes every stub, then runs the plugin's `rtp`, `load` and `after` tasks through the task runner, so a failed config shows up in the window like any other failure.
- Triggered dependencies load first. A `now` or `later` plugin pulls its dependencies in at the same time, transitively.
- Afterwards the trigger replays. A command runs again with its args, bang and range. A key is fed again. An event runs only the autocmds the plugin added, so other plugins' handlers do not fire twice.
- `event` takes `'BufRead'` or `'User Foo'`, with an optional pattern after the event name.

Only the plugin's `plugin/` and `after/plugin/` files are sourced on a late load. `ftplugin`, `ftdetect` and `syntax` files take effect from the next buffer.

## Stats

```lua
require('sarcina').stats()
-- { count = 42, loaded = 40, not_loaded = 2, now = 5, later = 30, triggered = 7, startup_ms = 83.4 }
```

| Field | Is |
| --- | --- |
| `count` | plugins in the manifest |
| `now`, `later`, `triggered` | plugins by configured timing, after dependency promotion, so they add up to `count`. `now` plugins are eager and load before the UI, `later` plugins load after it, and `triggered` plugins load when their `event`, `ft`, `cmd` or `keys` fires |
| `loaded` | plugins whose `rtp` task is done and none of whose tasks failed at their latest run |
| `not_loaded` | `count - loaded`, which includes `later` plugins still waiting and `triggered` plugins that have not fired yet |
| `startup_ms` | milliseconds from the start of `setup()` to `UIEnter` (`VimEnter` when no UI attaches). Absent until then. It leaves out Neovim's own startup and your config before `setup()`; `nvim --startuptime` covers that |

A plugin whose `load` fails after its `rtp`, or whose queued build fails, counts as not loaded. A plugin with explicit `tasks` counts as loaded only if one of them has `type = 'rtp'`.

The `later` plugins load right after `UIEnter`, so a reading taken at `UIEnter` is early and shows them as not loaded. For final numbers, such as a dashboard row, read the stats when the startup run is done: sarcina fires `User SarcinaReady` once then, with the final stats in `args.data`.

```lua
vim.api.nvim_create_autocmd('User', {
    pattern = 'SarcinaReady',
    once = true,
    callback = function(args) print(vim.inspect(args.data)) end,
})
```

### Rows

`require('sarcina.stats').plugins()` returns one row per plugin in the order they loaded, with the ones that have not loaded after them, and `plugin(name)` returns one row. A row is read from the tracked tasks, so it is always current.

```lua
{ name = 'telescope.nvim', timing = 'trigger', state = 'waiting', task = 2, tasks = 6,
  detail = 'waiting for :Telescope', duration = 112.4 }
```

| Field | Is |
| --- | --- |
| `timing` | `now`, `later` or `trigger` |
| `state` | `pending`, `installing`, `building`, `updating`, `checking`, `loading`, `waiting` (for its trigger), `loaded`, `blocked` or `failed` |
| `task`, `tasks` | the plugin is at task `task` of `tasks`: its whole plan, with the tasks a trigger holds back counted. A task that never ran because it had nothing to do, such as the install of a plugin that is on disk, counts as done, and a loaded plugin reads `tasks` of `tasks` |
| `detail` | the line that says more: git's or the build's latest output, the first line of an error, why a plugin is blocked, or what it waits for |
| `duration` | milliseconds its tasks took in all, when they took any |

An install of a plugin that is on disk, and a build whose commit did not change, never show as `installing` or `building`.

`require('sarcina.stats').steps(name)` lists the tasks of one plugin's plan in order, each with `id`, `status` (`pending`, `running`, `done`, `failed` or `skipped`), `duration`, `note`, `output` and the first line of its `error`. The install of a plugin that is on disk was not run this session, so it is `done` with the note `installed` and, when one was kept, the time the install took (see below). Another task that was skipped over is `done` with the note `not run`, and a task that is still to come is `pending`, as the tasks a trigger holds back are. `require('sarcina.stats').spec(name)` returns the live `{ name, timing, spec }` of a plugin; `require('sarcina').get` hands out copies.

To look at every tracked time, run `:lua vim.print(require('sarcina.stats').tasks())`.

An install that really cloned a plugin is recorded in `stdpath('data')/sarcina/installs.json`, next to the `plugins` directory: `{ "telescope.nvim": { "ms": 2314.5, "at": 1730451225 } }`, with the milliseconds it took and the unix time it finished. A plugin installed before this file existed has no record and shows `installed` without a time until it is installed again. The file is written through a temporary file and read again before each write, so a second Neovim's records survive; one that cannot be read counts as no records.

`require('sarcina.stats').tasks()` lists every task of the session with `plugin`, `id`, `type`, `status`, `attempts`, `note`, `error` and its `meta`, and with times in milliseconds since `setup()` began: `created`, `started`, `ended`, `duration` (end minus start) and `waited` (start minus creation, the time spent behind the install barrier or a dependency). A task that never ran has only `created`.

## Specs

```lua
require('sarcina').get()        -- every plugin: { { name = 'plenary.nvim', timing = 'later', spec = { ... } }, ... }
require('sarcina').get('mini.nvim')
```

`get()` lists the plugins in the resolver's order, dependencies first, which is a stable order. For the order they actually loaded in, read `stats.plugins()`. `timing` is `now`, `later` or `trigger`, after dependency promotion. Each `spec` is the complete one the engine runs from: the name is derived from `repo` when missing, `deps` are plain names, `triggers` are normalized, and `tasks` are generated. `origin` is the spec file the plugin was loaded from, unless the spec sets its own. A name sarcina does not know gives `nil`, and before `setup()` has run the list is empty.

The results are copies, so changing one changes nothing the engine runs. A spec holds your functions, such as `config`, so it does not survive `vim.json.encode`.

## Commands

| Command | Does |
| --- | --- |
| `:Sarcina install` | resolve the manifest and run every plugin's tasks |
| `:Sarcina check [plugins]` | fetch what each plugin's remote has and say which have an update. Nothing is changed |
| `:Sarcina update [plugins]` | fetch, move each plugin to what its remote has, rebuild what moved, and write the lock file |
| `:Sarcina clean` | list the plugin directories that are not in your specs |
| `:Sarcina clean!` | delete them (`:Sarcina! clean` does the same) |
| `:Sarcina panel` | toggle the window, and go into it |
| `:Sarcina stats` | print the stats on one line |
| `:Sarcina help` | list subcommands |

`check` and `update` take plugin names, completed with Tab, and do every plugin of the manifest without any. They read your specs from disk, like `install`, and show up in the window as `checking` and `updating`.

**`update`** fetches the default branch of each plugin (`git fetch --depth 1`), and moves the plugin there with `git reset --hard`, because a depth-1 clone cannot fast-forward. A plugin with changes of its own to tracked files is left as it is and named in the summary. The plugin's `build` follows in the same run: it is gated on the commit, as always, so only the plugins that moved are rebuilt. Fetches start together like installs do (up to `tasks.max_installs`), and builds wait for all of them. A plugin that is already loaded keeps running its old code until you restart Neovim. A plugin that is not installed is named and skipped; `:Sarcina install` installs it. A fetch that fails, such as offline, fails that plugin and the others carry on.

**`clean`** compares the directories in `stdpath('data')/sarcina/plugins` with the plugins of your specs, dependencies included. It refuses when the manifest is empty or does not resolve, so a spec that failed to load cannot make every plugin look removable. `clean!` also takes the plugin off `runtimepath` and out of the install times and the lock file. A plugin whose spec sets `dest` lives elsewhere and is never touched.

### Lock file

`stdpath('config')/sarcina-lock.json`, next to your specs so you can commit it, holds the commit of every plugin sarcina installed or updated:

```json
{
  "telescope.nvim": { "commit": "9b5f7c1e0f6a2d4c8b1e3a7f5d2c9e4b6a8f0d13" }
}
```

It is rewritten after any run that cloned or updated a plugin, and only the plugins of that run change: the other entries stay, so a plugin that failed to install keeps its pin. It also **pins fresh installs**: a clone checks out the commit the lock names, fetching it with `git fetch --depth 1 origin <commit>` when the shallow clone does not have it, and the branch still tracks its remote, so a later `update` moves on from the pin. If the locked commit cannot be fetched, that plugin's install fails with `locked commit 9b5f7c1 is not available`; delete its entry to install the latest. Run `:Sarcina update` to move the pins forward. There is no `restore` command yet.

## How the task engine works

- Tasks for one plugin run in order. Plugins run in parallel, up to `tasks.max_concurrent` (default 4).
- Installs go first. Every `install` task starts at once, whatever its plugin depends on, up to `tasks.max_installs` (default 8). No other task starts until all installs have finished. Then the rest of each plugin's tasks run, dependencies first, and the `now` plugins are queued ahead of the others, so they start first.
- A plugin starts only after the plugins in its `deps` have finished.
- If a task fails, the rest of that plugin's tasks and every plugin that depends on it are marked `skipped`.
- A task with `retries = n` runs up to `n + 1` times before it counts as failed.
- A task with `when = '<lua expression>'` is dropped from the queue when the expression is false.
- Executors are `function(job, done, report)`. They call `done(ok, msg)` once and `report(line)` for live output. A task that does real work, such as a clone or a build that is not up to date, sets `job.working = true` and calls `report()` with no line, which is how the window knows to open. The runner owns every status change, so an executor cannot leave a task stuck in `running`.

`tasks.enqueue(name, spec, { append = true })` and `tasks.run_all(cb, { append = true })` add to the job list instead of starting a new one, and the summary then counts only the jobs added since the last one. The scheduler uses this for the loads that triggers start.

`track.finished_jobs()` lists the jobs in the order they ended, which is the record of what really happened first.

Every job is stamped by `track` when it is created, started and finished: `created`, `started` and `ended` (hrtime, ns) and `duration` (ms, from the first start, retries included). A fresh run replaces `snapshot()` but not `track.history()`, which keeps every job of the session.

Job statuses are `pending`, `running`, `done`, `failed` and `skipped`. `tasks.snapshot()` returns the jobs in queue order plus a count per status. Each change fires `ui.emit('task', job)`, and `ui.on('task', fn)` listens for them.

## Window

Four windows make one block, 80% of the editor wide and 80% tall, centered: a header across the top, a footer across the bottom, and between them the list of plugins on the left and the details of the one under the cursor on the right. The list and the details scroll; the header and the footer have windows of their own, so they stay in view.

```
╭──────────────────────────────────────────────────────────────╮
│ Total: 55 plugins                                            │
│                        127/210 tasks                         │
╰──────────────────────────────────────────────────────────────╯
╭──────────────────────────────────╮╭ avante.nvim ──────────────╮
│ ✔ plenary.nvim later   loaded  3 ││ state     ✘ failed        │
│ ▶ telescope    trigger installing││ tasks     2 of 3 tasks    │
│ ○ blink.cmp    trigger waiting 2 ││ timing    later           │
│ ✘ avante.nvim  later   failed  2 ││ src       yetone/avante   │
│ ⊘ smart-splits later   blocked 1 ││ path      ~/.local/share… │
╰──────────────────────────────────╯│ rev       5e4e310         │
╭──────────────────────────────────╮│                           │
│ Now 7, Later 18, Triggered 30    ││ Tasks                     │
╰──────── q close · ^d ^u ─────────╯│ ✔ install 104ms installed │
                                    │ ✘ build 12ms make: comm…  │
                                    ╰───────────────────────────╯
```

**The header** says how many plugins there are, `Total: 55 plugins`, and below it, centered, how far all their tasks have got together, `127/210 tasks`. That is the left numbers of the rows (`3 of 8 tasks`) added up over their right numbers, so it counts up in real time as the rows do, and it only reaches the total when every task of every plugin is done, the ones a trigger holds back included. **The footer** says how many load now, later and on a trigger, on the left, and the startup time on the right: `Now 7, Later 18, Triggered 30` and `Startup: 83ms`. Both come from `stats.get()`.

**The list** has one row per plugin, in the order the plugins load. The order is recorded, not sorted: `track` keeps the jobs in the order they ended, and a plugin takes its place where its `rtp` task ended. Plugins that have not loaded yet wait below in manifest order, and a row moves up when its plugin loads. So installed `now` plugins come first, since they load before the UI, then the `later` ones as they finish, then triggered ones as they fire.

A row has a glyph, the name, when it loads, its state, the tasks widget and the time. The glyph and the state word are coloured by state, and a plugin that waits for its trigger is yellow (`○`; `…` is a plugin that has not started, `▶` one at work, `✔` a loaded one, `✘` a failed one, `⊘` a blocked one).

The tasks widget is a button with rounded ends and two tones. The count (`3 of 8`) is on the colour of the state, in dark bold text, and the label (`tasks`) is a light tint of it in a darker shade, with a check (`tasks ✔`) once every task of the plugin is done. The colours come from your colorscheme's `DiagnosticOk` (loaded), `DiagnosticInfo` (at work), `DiagnosticWarn` (waiting), `DiagnosticError` (failed) and `Comment` (not started, or blocked), so the widget follows the theme. Each kind has four groups you can override, such as `SarcinaPillDoneLeft`, `SarcinaPillDoneCount`, `SarcinaPillDone` and `SarcinaPillDoneRight`; the same goes for `Running`, `Waiting`, `Failed` and `Idle`. The ends are Powerline glyphs, so they need a patched font (a Nerd Font); with `setup({ ui = { rounded = false } })` the widget has flat ends. The ends set only a foreground, so the cell behind them stays the window's, or the cursor line's, and they look round either way. When the list is too narrow, the state word goes before the widget does.

The time is the run time of all that plugin's tasks added up, not the load alone. A task counts when it ends, and time spent waiting behind the install barrier or a dependency does not.

**The details** show the plugin under the cursor and follow it. While you are not in the window the cursor follows the plugin that is at work, or the last one that failed. `<C-d>` and `<C-u>` in the list scroll the details, and a different plugin starts at the top. Each key shows only when there is something to say:

| Key | Is |
| --- | --- |
| `state`, `tasks`, `timing` | what the row says, with the plugin's total time |
| `src`, `path` | the `repo` as written, and the directory it is cloned to (`dest`, or the default) |
| `rev` | the short commit in that directory, read in the background |
| `deps`, `triggers`, `armed` | what it needs, what loads it, and whether that is still `waiting`, `loading`, `loaded` or `failed` |
| `origin` | the spec file it came from |
| `detail` | live output, the first line of an error, why it is blocked, or what it waits for |

Under a `Tasks` title is one line per task of the plugin's plan: a glyph for its status, the task, its own time right after it in bold, and a note. Each task has a colour of its own (`install`, `before`, `build`, `load_trigger`, `rtp`, `load`, `keys`, `after`, and one for any other id), set by the groups `SarcinaStepInstall`, `SarcinaStepBefore`, `SarcinaStepBuild`, `SarcinaStepTrigger`, `SarcinaStepRtp`, `SarcinaStepLoad`, `SarcinaStepKeys`, `SarcinaStepAfter` and `SarcinaStepOther`, which link to groups a colorscheme colours differently. The time is `SarcinaStepTime`. The install of a plugin that was cloned in an earlier session reads `installed`, with the time it took when that was kept.

With less room than about 105 columns the list takes the whole width and the details pane goes, and the rows keep their detail text. The columns of a row give way to the width in the same order: the detail text, then the state word (the glyph still says it), then the name is cut with `…`. All four windows follow a resize.

The window reads the stats and keeps no task state, so it cannot drift from the engine. An event redraws the row of its plugin, the header and the footer, and the details when they show that plugin. The size is fixed when the window opens, so streaming output never moves it.

It opens by itself on a first install (a clone), on a build that runs because the plugin's commit changed, and on a failure. A warm startup, where everything is installed and built, never opens it. `setup({ ui = { show = ... } })` changes that:

| `show` | Opens by itself |
| --- | --- |
| `'auto'` (default) | on real work and on a failure |
| `'always'` | at every startup |
| `'never'` | never. Failures still toast |

A window that opened by itself closes `ui.close_delay` (3 s) after a clean run. A failure keeps it open. `q` or closing the list dismisses all four windows until a failure it has not shown yet, and `:Sarcina panel` brings it back, goes into the list, and keeps it open until you close it.

A load that a trigger starts updates the plugin's row in place, and `ui.on('task', fn)` still hears every job change.

## Messages

Only problems become toasts. `setup()` runs quietly, so a clean launch prints nothing and the window carries the progress. A run with failures ends with one error line such as `2 done, 1 failed, 4 skipped`, counting only that run. `:Sarcina install` also prints a summary when it succeeds. The resolver's chatter, such as derived plugin names, goes out as `debug` events that only `ui.on('debug', fn)` listeners receive.

## Development

```sh
nvim --headless -u NONE -c "luafile tests/run.lua"
stylua --check lua plugin tests
luacheck lua plugin tests
```

The tests use a throwaway XDG directory and local git repos, with no network. Set `SARCINA_TEST_FILTER` to a substring to run matching tests only.
