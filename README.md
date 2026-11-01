# sarcina

A Neovim plugin manager built around a task engine. Each plugin expands into an ordered list of tasks (clone, build, runtimepath, config). The task panel shows what the engine is doing as it does it.

## Layout

```
lua/sarcina/
├── init.lua          setup(): load, resolve, start; exports now, later, now_if_args, safely
├── cli.lua           :Sarcina dispatcher (install, panel, help, ...)
├── manifest.lua      loads plugin specs from lua/plugins/**/*.lua
├── resolver.lua      orders plugins so dependencies come first, sets spec.triggers and each plugin's timing
├── task_factory.lua  turns spec fields (build, config, opts, event, ...) into tasks
├── main_module.lua   finds the module that a plugin's opts belong to
├── tasks.lua         task store and async runner; owns all task state
├── executors.lua     one function per task type (git_clone, rtp, lua, cmd, shell, keymaps, trigger, make)
├── scheduler.lua     lazy-load stubs, deferred loading, trigger replay
├── keys.lua          parses `keys` entries into a lhs, an rhs, a mode and options
├── load.lua          when code runs: now, later, now_if_args, event and filetype, all under safely
├── startup.lua       splits a resolved manifest into the now phase and the queued rest
├── installer.lua     queues a resolved manifest and runs it (:Sarcina install)
├── paths.lua         install and staging locations
├── schema.lua        manifest and task validation
└── ui.lua            event bus and floating task panel
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
| `init`, `build`, `after` | `init` runs right after the install, `build` after that, and `after` once the plugin has loaded. A function is called with `plugin = { name, dir }`. A string is a Lua chunk, except that a `build` string is a shell command run in the plugin directory (`build = 'make'`), and any string starting with `:` is an Ex command (`build = ':TSUpdate'`). `build` runs only after a fresh clone or when the plugin's commit changes |
| `config` | called as `config(plugin, opts)` with `plugin = { name, dir }` |
| `opts` | a table, or a `function(plugin, opts)` that returns one or fills in the empty table it is given. Handed to `config(plugin, opts)`, or to `require(module).setup(opts)` when there is no `config` |
| `main` | the module to require; found from the plugin name when missing |
| `event`, `ft`, `cmd`, `keys` | lazy-load triggers. A `keys` entry is `'lhs'` or `{ lhs, rhs, mode = 'n', desc = ..., <keymap options> }`; with an `rhs`, sarcina defines the mapping when the plugin loads |
| `tasks` | an explicit task list, which skips the generated one |

Every plugin, lazy or not, is cloned to `stdpath('data')/sarcina/plugins/<name>`. That directory is outside `'packpath'`, so Neovim never loads a plugin on its own. Sarcina adds it to `runtimepath`, with the plugin's `after/` directory behind it, when the plugin's `rtp` task runs. For a `now` plugin that is inside `setup()`, so Neovim sources its `plugin/` files in its own startup pass.

A `build` that succeeds records the plugin's commit in `.git/sarcina-build` inside the plugin directory, and later runs skip it while `HEAD` still matches (`build` shows `up to date`). A new commit from an update or a manual `git pull` runs it again. A build that fails leaves no record, so it runs again on the next launch. To force a rebuild, delete that file.

A function or Ex command `build` finds the plugin on `runtimepath`, so it can call the plugin's autoload functions and commands. Builds always run after the UI is up, when the plugin's `plugin/` files can be sourced, even for a `now` plugin.

Without `main`, sarcina matches the plugin name, then the repo name, against the modules in the plugin's `lua/` directory, ignoring case, punctuation and `nvim` affixes. A lone module wins by default. If it cannot tell, the load task fails with the list of modules and asks you to set `main`.

## When plugins load

Every plugin has a timing. The resolver sets it, and `entry.timing` carries it.

| Timing | The plugin loads |
| --- | --- |
| `now` | inside `setup()`, before `VimEnter` and `UIEnter`, in the order received |
| `later` | in the background once the UI is up, starting in the order received. This is the default |
| on a trigger | when its `event`, `ft`, `cmd` or `keys` fires (see [Lazy loading](#lazy-loading)) |

- `load = 'now_if_args'` is `now` when Neovim was started with file arguments, and `later` otherwise.
- A plugin with triggers loads on them. `load` only picks the time for a plugin without triggers, except that `load = 'now'` wins and drops the triggers.
- A dependency loads no later than the plugins that need it. It takes the earliest timing among its dependents, so a `now` plugin pulls its dependencies in `now` too.
- There is no `priority`. The order of the manifest is the order of loading, with dependencies first.

`setup()` does this in order:

1. Resolve the manifest.
2. Run the `init` hook of every installed plugin.
3. Load every installed `now` plugin whose dependencies loaded: `rtp`, `config` or `opts`, `keys`, `after`. A failure is recorded, skips the rest of that plugin and its dependents, and is reported once the UI is up.
4. Queue everything else, and start it when the UI is up (when `VimEnter` fires if there is no UI): installs first, then builds, then the `later` plugins and the stubs of the lazy ones.

A `now` plugin that is not installed yet cannot load before the UI, so on the first launch it is installed in the background and loads as soon as the installs are done.

The same timings are available to your own code, with errors reported instead of raised:

```lua
local sarcina = require('sarcina')

sarcina.now(function() vim.cmd.colorscheme('poimandres') end)
sarcina.later(function() require('some.heavy.module').setup() end)
sarcina.now_if_args(function() vim.cmd('syntax on') end)
sarcina.safely('event:BufReadPost *.lua', function() ... end)
sarcina.safely('filetype:markdown', function() ... end)
```

`later` callbacks run in the order received, one per tick, after `UIEnter`. Errors raised before the UI is up are held and shown after it.

## Lazy loading

A spec with `event`, `ft`, `cmd` or `keys` is lazy. The resolver normalizes those fields into `spec.triggers`, and `triggers = false` forces a plugin to load eagerly.

- A lazy plugin only clones, builds, and registers stubs for its triggers once the UI is up. The `load_trigger` row reads `waiting for :Telescope`.
- The first trigger to fire removes every stub, then runs the plugin's `rtp`, `load` and `after` tasks through the task runner, so a failed config shows up in the panel like any other failure.
- Lazy dependencies load first. A `now` or `later` plugin pulls its dependencies in at the same time, transitively.
- Afterwards the trigger replays. A command runs again with its args, bang and range. A key is fed again. An event runs only the autocmds the plugin added, so other plugins' handlers do not fire twice.
- `event` takes `'BufRead'` or `'User Foo'`, with an optional pattern after the event name.

Only the plugin's `plugin/` and `after/plugin/` files are sourced on a late load. `ftplugin`, `ftdetect` and `syntax` files take effect from the next buffer.

## Commands

| Command | Does |
| --- | --- |
| `:Sarcina install` | resolve the manifest and run every plugin's tasks |
| `:Sarcina panel` | toggle the task panel |
| `:Sarcina help` | list subcommands |

## How the task engine works

- Tasks for one plugin run in order. Plugins run in parallel, up to `tasks.max_concurrent` (default 4).
- Installs go first. Every `install` task starts at once, whatever its plugin depends on, up to `tasks.max_installs` (default 8). No other task starts until all installs have finished. Then the rest of each plugin's tasks run, dependencies first.
- A plugin starts only after the plugins in its `deps` have finished.
- If a task fails, the rest of that plugin's tasks and every plugin that depends on it are marked `skipped`.
- A task with `retries = n` runs up to `n + 1` times before it counts as failed.
- A task with `when = '<lua expression>'` is dropped from the queue when the expression is false.
- Executors are `function(job, done, report)`. They call `done(ok, msg)` once and `report(line)` for live output. The runner owns every status change, so an executor cannot leave a task stuck in `running`.

`tasks.enqueue(name, spec, { append = true })` and `tasks.run_all(cb, { append = true })` add to the job list instead of starting a new one, and the summary then counts only the jobs added since the last one. The scheduler uses this for lazy loads.

Job statuses are `pending`, `running`, `done`, `failed` and `skipped`. `tasks.snapshot()` returns the jobs in queue order plus a count per status. Each change fires `ui.emit('task', job)`, and `ui.on('task', fn)` listens for them.

## Task panel

The panel renders `tasks.snapshot()` and keeps no state of its own, so it cannot drift from the engine. It opens when a run lasts longer than `ui.show_delay` (250 ms) or when a failure appears, and closes `ui.close_delay` (3 s) after a run once nothing has failed. A failure keeps it open. `q` or closing the window dismisses it, and `:Sarcina panel` brings it back.

- A running row shows git's latest line cut to the window width, so the panel keeps one height while output streams. A finished row wraps its error in full.
- A lazy load appends its rows to the current list instead of replacing it. Failures from earlier in the session stay on screen, and the plugin's `rtp` and `load` rows are added at the end of the list. With nothing running, the cursor sits on the newest failure.
- A dismissed panel stays closed through later runs and reopens only for a failure it has not shown yet.
- Starting a fresh run, such as `:Sarcina install` after a finished one, replaces the list.

## Messages

Only problems become toasts. `setup()` runs quietly, so a clean launch prints nothing and the panel carries the progress. A run with failures ends with one error line such as `2 done, 1 failed, 4 skipped`, counting only that run. `:Sarcina install` also prints a summary when it succeeds. The resolver's chatter, such as derived plugin names, goes out as `debug` events that only `ui.on('debug', fn)` listeners receive.

## Development

```sh
nvim --headless -u NONE -c "luafile tests/run.lua"
stylua --check lua plugin tests
luacheck lua plugin tests
```

The tests use a throwaway XDG directory and local git repos, with no network. Set `SARCINA_TEST_FILTER` to a substring to run matching tests only.
