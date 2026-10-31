# sarcina

A Neovim plugin manager built around a task engine. Each plugin expands into an ordered list of tasks (clone, build, runtimepath, lazy-load triggers, config). The task panel shows what the engine is doing as it does it.

## Layout

```
lua/sarcina/
├── init.lua          – setup(): load, resolve, queue, run
├── cli.lua           – :Sarcina dispatcher (install, panel, help, ...)
├── manifest.lua      – loads plugin specs from lua/plugins/**/*.lua
├── resolver.lua      – orders plugins so dependencies come first
├── task_factory.lua  – turns spec fields (build, config, opts, event, ...) into tasks
├── tasks.lua         – task store and async runner; owns all task state
├── executors.lua     – one function per task type (git_clone, rtp, lua, trigger, make)
├── installer.lua     – queues a resolved manifest and runs it
├── scheduler.lua     – lazy-load trigger registration
├── paths.lua         – install and staging locations
├── schema.lua        – manifest and task validation
└── ui.lua            – event bus and floating task panel
```

## Usage

```lua
require('sarcina').setup()
```

`setup()` returns immediately. Tasks run in the background; call `require('sarcina.tasks').wait()` if your config needs the plugins loaded before it continues.

A spec can be a bare repo or a table. `owner/repo` expands to a GitHub URL.

```lua
return {
	{ 'nvim-lua/plenary.nvim' },
	{
		'nvim-telescope/telescope.nvim',
		deps = { 'plenary.nvim' },
		config = function(_, opts) require('telescope').setup(opts) end,
		opts = { defaults = {} },
	},
}
```

`config` receives `opts` as its second argument. With `main` set and no `config`, sarcina calls `require(main).setup(opts)`. `opts` without either is ignored.

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

## Tests

```sh
nvim --headless -u NONE -c "luafile tests/run.lua"
```

The suite runs against a throwaway XDG directory and local git repos, with no network. Set `SARCINA_TEST_FILTER` to a substring to run matching tests only.
