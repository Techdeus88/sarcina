# sarcina

A Neovim plugin manager built around a task engine. Each plugin expands into an ordered list of tasks (clone, build, runtimepath, config). The task panel shows what the engine is doing as it does it.

## Layout

```
lua/sarcina/
├── init.lua          setup(): load, resolve, queue, run
├── cli.lua           :Sarcina dispatcher (install, panel, help, ...)
├── manifest.lua      loads plugin specs from lua/plugins/**/*.lua
├── resolver.lua      orders plugins so dependencies come first, sets spec.triggers
├── task_factory.lua  turns spec fields (build, config, opts, event, ...) into tasks
├── main_module.lua   finds the module that a plugin's opts belong to
├── tasks.lua         task store and async runner; owns all task state
├── executors.lua     one function per task type (git_clone, rtp, lua, trigger, make)
├── scheduler.lua     lazy-load stubs, deferred loading, trigger replay
├── installer.lua     queues a resolved manifest and runs it
├── paths.lua         install and staging locations
├── schema.lua        manifest and task validation
└── ui.lua            event bus and floating task panel
```

## Usage

```lua
require('sarcina').setup()
```

`setup()` returns immediately. Tasks run in the background; call `require('sarcina.tasks').wait()` if your config needs the plugins loaded before it continues.

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
| `init`, `build`, `after` | Lua string or function run before install, after install, and after load |
| `config` | called as `config(plugin, opts)` with `plugin = { name, dir }` |
| `opts` | handed to `require(module).setup(opts)` when there is no `config` |
| `main` | the module to require; found from the plugin name when missing |
| `event`, `ft`, `cmd`, `keys` | lazy-load triggers |
| `opt` | install under `pack/sarcina/opt` instead of `start` |
| `tasks` | an explicit task list, which skips the generated one |

Without `main`, sarcina matches the plugin name, then the repo name, against the modules in the plugin's `lua/` directory, ignoring case, punctuation and `nvim` affixes. A lone module wins by default. If it cannot tell, the load task fails with the list of modules and asks you to set `main`.

## Lazy loading

A spec with `event`, `ft`, `cmd` or `keys` is lazy. The resolver normalizes those fields into `spec.triggers`, and `triggers = false` forces a plugin to load eagerly.

- At startup a lazy plugin only clones (into `opt/`), builds, and registers stubs for its triggers. The `load_trigger` row reads `waiting for :Telescope`.
- The first trigger to fire removes every stub, then runs the plugin's `rtp`, `load` and `after` tasks through the task runner, so a failed config shows up in the panel like any other failure.
- Lazy dependencies load first. An eager plugin pulls its dependencies in at startup, transitively.
- Afterwards the trigger replays. A command runs again with its args, bang and range. A key is fed again. An event runs only the autocmds the plugin added, so other plugins' handlers do not fire twice.
- `event` takes `'BufRead'` or `'User Foo'`, with an optional pattern after the event name.

Only the plugin's `plugin/` files are sourced on a late load. `ftplugin`, `ftdetect` and `syntax` files take effect from the next buffer.

## Commands

| Command | Does |
| --- | --- |
| `:Sarcina install` | resolve the manifest and run every plugin's tasks |
| `:Sarcina panel` | toggle the task panel |
| `:Sarcina help` | list subcommands |

## How the task engine works

- Tasks for one plugin run in order. Plugins run in parallel, up to `tasks.max_concurrent` (default 4).
- A plugin starts only after the plugins in its `deps` have finished.
- If a task fails, the rest of that plugin's tasks and every plugin that depends on it are marked `skipped`.
- A task with `retries = n` runs up to `n + 1` times before it counts as failed.
- A task with `when = '<lua expression>'` is dropped from the queue when the expression is false.
- Executors are `function(job, done, report)`. They call `done(ok, msg)` once and `report(line)` for live output. The runner owns every status change, so an executor cannot leave a task stuck in `running`.

Job statuses are `pending`, `running`, `done`, `failed` and `skipped`. `tasks.snapshot()` returns the jobs in queue order plus a count per status. Each change fires `ui.emit('task', job)`, and `ui.on('task', fn)` listens for them.

## Task panel

The panel renders `tasks.snapshot()` and keeps no state of its own, so it cannot drift from the engine. It opens when a run lasts longer than `ui.show_delay` (250 ms) or when anything fails, and closes `ui.close_delay` (3 s) after a clean run. Failures keep it open. `q` or closing the window dismisses it until the next run, and `:Sarcina panel` brings it back.

A lazy load is a run of its own. It stays quiet when it succeeds and opens the panel when it fails.

## Development

```sh
nvim --headless -u NONE -c "luafile tests/run.lua"
stylua --check lua plugin tests
luacheck lua plugin tests
```

The tests use a throwaway XDG directory and local git repos, with no network. Set `SARCINA_TEST_FILTER` to a substring to run matching tests only.
