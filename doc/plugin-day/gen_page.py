import html
import pathlib

# Regenerates plugin-day.html next to this script: python3 gen_page.py
OUT = pathlib.Path(__file__).with_name("plugin-day.html")


def md(text):
    """Escape text and turn `code` spans into <code>."""
    parts = text.split("`")
    out = []
    for i, part in enumerate(parts):
        esc = html.escape(part, quote=False)
        out.append(f"<code>{esc}</code>" if i % 2 else esc)
    return "".join(out)


GLYPH = {"done": "✔", "run": "▶", "pend": "…", "fail": "✘", "skip": "⊘"}


def panel(title, rows, caption=None):
    lines = []
    for status, plugin, task, note in rows:
        note_html = f' <span class="note">{html.escape(note, quote=False)}</span>' if note else ""
        lines.append(
            f'<div class="row {status}"><span class="g">{GLYPH[status]}</span> '
            f"{html.escape(plugin, quote=False)} – {html.escape(task, quote=False)}{note_html}</div>"
        )
    cap = f'<figcaption class="cap">{md(caption)}</figcaption>' if caption else ""
    return (
        '<figure class="panel">'
        f'<div class="panel-title">{html.escape(title, quote=False)}</div>'
        f'<div class="panel-body">{"".join(lines)}</div>{cap}</figure>'
    )


def term(lines, caption=None):
    body = "\n".join(lines)
    cap = f'<figcaption class="cap">{md(caption)}</figcaption>' if caption else ""
    return f'<figure class="panel"><pre class="term">{html.escape(body, quote=False)}</pre>{cap}</figure>'


def toast(level, text):
    return (
        f'<div class="toast {level.lower()}"><span class="lvl">{level}</span> '
        f"{html.escape(text, quote=False)}</div>"
    )


def steps(items):
    return "<ol class=\"steps\">" + "".join(f"<li>{md(i)}</li>" for i in items) + "</ol>"


def para(text):
    return f"<p>{md(text)}</p>"


def lens(kind, label, content):
    return (
        f'<div class="lens" data-lens="{kind}"><h3 class="lens-label">{label}</h3>'
        f'<div class="lens-body">{content}</div></div>'
    )


def moment(time, title, story, lenses, mid=False):
    cls = "moment" + (" before" if mid else "")
    when = f'<div class="when">{time}</div>' if time else '<div class="when">before launch</div>'
    return (
        f'<section class="{cls}">{when}<div class="what"><h2>{html.escape(title, quote=False)}</h2>'
        f'<p class="story">{md(story)}</p>{"".join(lenses)}</div></section>'
    )


SPEC = """-- lua/plugins/demo.lua
return {
  {
    '/…/repos/demo.nvim',
    deps = { { '/…/repos/util.nvim' } },       -- an inline spec
    build = 'sleep 0.3 && echo compiled > built.txt',
    cmd = 'Demo',
    keys = { { '<leader>d', '<cmd>Demo<cr>', desc = 'Run the demo' } },
    opts = { greeting = 'hello' },
  },
}"""

sections = []

sections.append(
    moment(
        None,
        "Written into a spec",
        "I am a lazy plugin. I have a command and a key, so I wait to be used. I also carry a dependency, a shell build and some options.",
        [
            lens(
                "code",
                "Code",
                f'<pre class="code">{html.escape(SPEC, quote=False)}</pre>'
                + para(
                    "`manifest.load` reads my spec file once and expands the `{ 'path' }` shorthand into `repo`. The resolver derives my name from the repo path, lifts `util.nvim` out of my `deps` and rewrites `deps` to plain names, sorts dependencies first, sets my triggers from `cmd` and `keys`, and generates my tasks."
                ),
            ),
            lens(
                "lifecycle",
                "Lifecycle",
                para("I have `cmd` and `keys`, so I am lazy. My task list is three entries long.")
                + '<ul class="chips"><li><code>install</code> git_clone</li>'
                '<li><code>build</code> shell, once per commit</li>'
                '<li><code>load_trigger</code> holds <code>rtp</code>, <code>load</code>, <code>keys</code></li></ul>',
            ),
            lens(
                "log",
                "Log",
                para("These four lines go only to `ui.on('debug')` listeners. They never become toasts.")
                + term(
                    [
                        'Derived plugin name "demo.nvim" from repo "…/repos/demo.nvim"',
                        'Derived plugin name "util.nvim" from repo "…/repos/util.nvim"',
                        "Resolved 2 plugins (order respects dependencies)",
                        "Starting bulk install of 2 plugins",
                    ]
                ),
            ),
        ],
        mid=True,
    )
)

sections.append(
    moment(
        "09:00",
        "First launch, cold",
        "Nothing of me exists on disk yet.",
        [
            lens(
                "code",
                "Code",
                para(
                    "My build task is `{ type = 'shell', per_commit = true }`. The wrapper in `executors.lua` runs `git rev-parse HEAD` and compares it with `.git/sarcina-build` before it runs anything."
                ),
            ),
            lens(
                "lifecycle",
                "Lifecycle",
                steps(
                    [
                        "`setup()` returns at once. The tasks run in the background.",
                        "I cannot start until `util.nvim` has finished, because I depend on it.",
                        "`git_clone` clones me into a staging directory, then renames it to `stdpath('data')/sarcina/plugins/demo.nvim`.",
                        "The shell build runs in my directory.",
                        "It succeeds, so my commit hash is written to `.git/sarcina-build`.",
                        "`load_trigger` arms two stubs: the `:Demo` command and the `<leader>d` key.",
                        "I am not on the runtimepath yet.",
                    ]
                ),
            ),
            lens(
                "log",
                "Log",
                '<div class="frames">'
                + panel(
                    "Sarcina 0/5",
                    [
                        ("run", "util.nvim", "install", "warning: --depth is ignored in local clones; use file://…"),
                        ("pend", "util.nvim", "rtp", None),
                        ("pend", "demo.nvim", "install", None),
                        ("pend", "demo.nvim", "build", None),
                        ("pend", "demo.nvim", "load_trigger", None),
                    ],
                    "+24 ms. Git's own warning, because the plugin is a local path.",
                )
                + panel(
                    "Sarcina 3/5",
                    [
                        ("done", "util.nvim", "install", None),
                        ("done", "util.nvim", "rtp", None),
                        ("done", "demo.nvim", "install", None),
                        ("run", "demo.nvim", "build", None),
                        ("pend", "demo.nvim", "load_trigger", None),
                    ],
                    "+111 ms. I start only after util.nvim is done.",
                )
                + panel(
                    "Sarcina 5/5",
                    [
                        ("done", "util.nvim", "install", None),
                        ("done", "util.nvim", "rtp", None),
                        ("done", "demo.nvim", "install", None),
                        ("done", "demo.nvim", "build", "0.3s"),
                        ("done", "demo.nvim", "load_trigger", "waiting for :Demo, <leader>d"),
                    ],
                    "The panel when startup is done.",
                )
                + "</div>"
                + para("Toasts: none. A clean `setup()` is silent."),
            ),
        ],
    )
)

sections.append(
    moment(
        "09:05",
        "Someone types :Demo",
        "The stub I left behind gets used.",
        [
            lens(
                "code",
                "Code",
                para(
                    "`scheduler.load` does the claiming. The `keymaps` task defines my real mapping, which is why `<leader>d` survives losing its stub: sarcina owns the `rhs`."
                ),
            ),
            lens(
                "lifecycle",
                "Lifecycle",
                steps(
                    [
                        "The `:Demo` stub fires.",
                        "The scheduler claims me and any dependency still waiting.",
                        "It removes every stub, so my other trigger cannot start a second load.",
                        "It appends `rtp`, `load` and `keys` to the current task list.",
                        "When the load succeeds, it replays the command.",
                    ]
                ),
            ),
            lens(
                "log",
                "Log",
                term(["demo says hello"], "The replayed command. `setup(opts)` has already run.")
                + panel(
                    "Sarcina 8/8",
                    [
                        ("done", "util.nvim", "install", None),
                        ("done", "util.nvim", "rtp", None),
                        ("done", "demo.nvim", "install", None),
                        ("done", "demo.nvim", "build", "0.3s"),
                        ("done", "demo.nvim", "load_trigger", "waiting for :Demo, <leader>d"),
                        ("done", "demo.nvim", "rtp", None),
                        ("done", "demo.nvim", "load", None),
                        ("done", "demo.nvim", "keys", None),
                    ],
                    "Three rows appended to the same list.",
                )
                + para(
                    "Toasts: none. A successful lazy load stays quiet. Afterwards `<leader>d` maps to `<cmd>Demo<cr>` with the description \"Run the demo\"."
                ),
            ),
        ],
    )
)

sections.append(
    moment(
        "13:00",
        "Second launch, warm",
        "Nothing needs doing, and the log says so.",
        [
            lens(
                "code",
                "Code",
                para(
                    "No new code runs. The install task sees my directory and reports `already installed`. The per-commit gate sees that `HEAD` equals the recorded hash and reports `up to date`."
                ),
            ),
            lens(
                "lifecycle",
                "Lifecycle",
                steps(
                    [
                        "`install` finds my directory and clones nothing.",
                        "`build` finds that `HEAD` matches `.git/sarcina-build` and is skipped.",
                        "`load_trigger` arms the stubs again.",
                        "I stay off the runtimepath until someone uses `:Demo` or `<leader>d`.",
                    ]
                ),
            ),
            lens(
                "log",
                "Log",
                panel(
                    "Sarcina 5/5",
                    [
                        ("done", "util.nvim", "install", "already installed"),
                        ("done", "util.nvim", "rtp", None),
                        ("done", "demo.nvim", "install", "already installed"),
                        ("done", "demo.nvim", "build", "up to date"),
                        ("done", "demo.nvim", "load_trigger", "waiting for :Demo, <leader>d"),
                    ]
                )
                + para("Toasts: none. The run is too fast for the panel to open on its own."),
            ),
        ],
    )
)

sections.append(
    moment(
        "18:00",
        "A bad evening",
        "Someone pulls a new commit, and my build breaks.",
        [
            lens(
                "code",
                "Code",
                para(
                    "The same per-commit wrapper runs, but this time the comparison fails, so the build executes. When a task fails, the runner in `tasks.lua` marks the rest of that plugin's tasks as skipped."
                ),
            ),
            lens(
                "lifecycle",
                "Lifecycle",
                steps(
                    [
                        "`HEAD` no longer matches the recorded hash, so the build runs again.",
                        "It fails.",
                        "My remaining task is skipped with the note `build failed`.",
                        "`load_trigger` never runs, so I arm no stubs. `:Demo` and `<leader>d` do not exist this session, and I am not on the runtimepath.",
                        "The run ends with one error toast. The panel opens and stays open.",
                    ]
                ),
            ),
            lens(
                "log",
                "Log",
                toast("ERROR", "[Sarcina] 3 done, 1 failed, 1 skipped")
                + panel(
                    "Sarcina 5/5 · 1 failed",
                    [
                        ("done", "util.nvim", "install", "already installed"),
                        ("done", "util.nvim", "rtp", None),
                        ("done", "demo.nvim", "install", "already installed"),
                        ("fail", "demo.nvim", "build", "error: ld: library not found for -ltiktoken"),
                        ("skip", "demo.nvim", "load_trigger", "build failed"),
                    ]
                )
                + para(
                    "On the next launch the build ran again and failed with the same panel. The record still held `d4b8d94…` while `HEAD` was `5495c54…`, so a failed build is retried until it succeeds."
                ),
            ),
        ],
    )
)

page = f"""<title>A Day as demo.nvim</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Instrument+Sans:wght@500;600&family=JetBrains+Mono:wght@400;500&family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,600;1,6..72,400&display=swap">
<style>
/* Layout concept: a timeline of one plugin's day. Each moment stacks code, lifecycle and log lenses; the log is a terminal panel that mirrors sarcina's own. */
:root {{
  --bg: #f2f5f8;
  --fg: #1b2330;
  --muted: #566272;
  --rule: #d3dae3;
  --accent: #2456cc;
  --code-bg: #e6ebf1;
  --term-bg: #0d131c;
  --term-fg: #d7dfea;
  --term-dim: #8493a5;
  --term-rule: #243041;
  --ok: #4cc38a;
  --run: #6db3ff;
  --fail: #ff7a7a;
  --skip: #8493a5;
  --font-body: 'Newsreader', Georgia, 'Times New Roman', serif;
  --font-mono: 'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, Consolas, monospace;
  --font-label: 'Instrument Sans', system-ui, -apple-system, 'Segoe UI', sans-serif;
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    --bg: #0c1118;
    --fg: #e1e7ef;
    --muted: #93a0b1;
    --rule: #243040;
    --accent: #84aaff;
    --code-bg: #151d28;
    --term-bg: #070b11;
    --term-fg: #d7dfea;
    --term-dim: #7f8ea1;
    --term-rule: #1d2836;
    color-scheme: dark;
  }}
}}
:root[data-theme="dark"] {{
  --bg: #0c1118;
  --fg: #e1e7ef;
  --muted: #93a0b1;
  --rule: #243040;
  --accent: #84aaff;
  --code-bg: #151d28;
  --term-bg: #070b11;
  --term-fg: #d7dfea;
  --term-dim: #7f8ea1;
  --term-rule: #1d2836;
  color-scheme: dark;
}}
body {{
  background: var(--bg);
  color: var(--fg);
  font-family: var(--font-body);
  font-size: 18px;
  line-height: 1.6;
  padding-block: 40px 72px;
  padding-left: max(16px, env(safe-area-inset-left, 0px));
  padding-right: max(16px, env(safe-area-inset-right, 0px));
}}
.wrap {{ max-width: 920px; margin-inline: auto; }}
code {{ font-family: var(--font-mono); font-size: 0.82em; background: var(--code-bg); padding: 0.1em 0.35em; border-radius: 3px; overflow-wrap: anywhere; }}
header {{ display: grid; gap: 14px; margin-bottom: 36px; }}
.eyebrow {{ font-family: var(--font-label); font-size: 12px; font-weight: 600; letter-spacing: 0.12em; text-transform: uppercase; color: var(--accent); }}
h1 {{ font-size: clamp(34px, 6vw, 54px); line-height: 1.08; font-weight: 600; letter-spacing: -0.01em; text-wrap: balance; }}
.lede {{ max-width: 62ch; font-size: 20px; color: var(--fg); }}
.provenance {{ max-width: 62ch; font-size: 15px; color: var(--muted); }}
.filter {{ display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 6px; font-family: var(--font-label); font-size: 13px; }}
.filter span {{ color: var(--muted); margin-right: 4px; }}
.filter button {{ font: inherit; font-weight: 500; color: var(--fg); background: transparent; border: 1px solid var(--rule); border-radius: 999px; padding: 5px 14px; cursor: pointer; }}
.filter button[aria-pressed="true"] {{ background: var(--accent); border-color: var(--accent); color: var(--bg); }}
.filter button:focus-visible, a:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
.timeline {{ display: grid; gap: 0; }}
.moment {{ display: grid; grid-template-columns: 112px minmax(0, 1fr); gap: 0 28px; padding-block: 34px; border-top: 1px solid var(--rule); }}
.when {{ font-family: var(--font-mono); font-size: 15px; font-weight: 500; color: var(--accent); padding-top: 6px; }}
.moment.before .when {{ font-family: var(--font-label); font-size: 12px; letter-spacing: 0.1em; text-transform: uppercase; padding-top: 10px; }}
.what {{ min-width: 0; display: grid; gap: 22px; border-left: 1px solid var(--rule); padding-left: 28px; }}
h2 {{ font-size: 28px; line-height: 1.2; font-weight: 600; text-wrap: balance; }}
.story {{ margin-top: -14px; color: var(--muted); font-style: italic; max-width: 62ch; }}
.lens {{ display: grid; gap: 8px; min-width: 0; }}
.lens-label {{ font-family: var(--font-label); font-size: 11px; font-weight: 600; letter-spacing: 0.14em; text-transform: uppercase; color: var(--muted); }}
.lens-body {{ display: grid; gap: 14px; min-width: 0; }}
.lens-body p {{ max-width: 64ch; }}
.steps {{ max-width: 64ch; padding-left: 1.4em; display: grid; gap: 6px; }}
.steps li::marker {{ font-family: var(--font-mono); font-size: 0.85em; color: var(--accent); }}
.chips {{ list-style: none; display: flex; flex-wrap: wrap; gap: 8px; }}
.chips li {{ font-size: 15px; border: 1px solid var(--rule); border-radius: 6px; padding: 6px 12px; }}
.code {{ font-family: var(--font-mono); font-size: 13.5px; line-height: 1.6; background: var(--code-bg); border-radius: 6px; padding: 16px 18px; overflow-x: auto; max-width: 640px; }}
.frames {{ display: grid; gap: 14px; }}
.panel {{ margin: 0; max-width: 640px; min-width: 0; background: var(--term-bg); color: var(--term-fg); border: 1px solid var(--term-rule); border-radius: 8px; overflow: hidden; font-family: var(--font-mono); font-size: 13px; line-height: 1.55; }}
.panel-title {{ text-align: center; padding: 7px 12px; border-bottom: 1px solid var(--term-rule); color: var(--term-dim); font-size: 12px; }}
.panel-body {{ padding: 10px 16px 12px; overflow-x: auto; }}
.row {{ white-space: pre; }}
.row .g {{ display: inline-block; width: 1.4em; }}
.row.done .g {{ color: var(--ok); }}
.row.run .g {{ color: var(--run); }}
.row.pend .g {{ color: var(--skip); }}
.row.fail .g {{ color: var(--fail); }}
.row.skip .g {{ color: var(--skip); }}
.row.pend, .row.skip {{ color: var(--term-dim); }}
.row .note {{ color: var(--term-dim); margin-left: 0.9em; }}
.row.fail .note {{ color: var(--fail); }}
.term {{ margin: 0; padding: 12px 16px; overflow-x: auto; white-space: pre; font: inherit; }}
.cap {{ font-family: var(--font-label); font-size: 12px; color: var(--term-dim); padding: 8px 16px 10px; border-top: 1px solid var(--term-rule); }}
.toast {{ max-width: 640px; font-family: var(--font-mono); font-size: 13px; padding: 10px 16px; border-radius: 8px; background: var(--term-bg); color: var(--term-fg); border: 1px solid var(--term-rule); overflow-x: auto; white-space: pre; }}
.toast .lvl {{ color: var(--fail); font-weight: 500; margin-right: 0.8em; }}
.note-box {{ border-top: 1px solid var(--rule); padding-block: 34px 0; display: grid; gap: 12px; max-width: 64ch; margin-left: calc(112px + 28px); }}
.note-box h2 {{ font-size: 24px; }}
@media (max-width: 720px) {{
  body {{ font-size: 17px; padding-block: 28px 56px; }}
  .moment {{ grid-template-columns: minmax(0, 1fr); gap: 10px; }}
  .what {{ border-left: 0; padding-left: 0; }}
  .when {{ padding-top: 0; }}
  .moment.before .when {{ padding-top: 0; }}
  .note-box {{ margin-left: 0; }}
}}
</style>
<div class="wrap">
  <header>
    <div class="eyebrow">sarcina · one plugin, one day</div>
    <h1>A Day as demo.nvim</h1>
    <p class="lede">I am a plugin loaded by sarcina. This is what happens to me over four launches, seen from three sides: the code that acts on me, the stages I move through, and the text sarcina prints about it.</p>
    <p class="provenance">Every log block is copied from a real headless run against two local git repos in a throwaway directory. Durations and hashes are from that run. The panel text was read from the panel buffer; in a live session it opens after 250 ms or when something fails.</p>
    <div class="filter" role="group" aria-label="Show one lens">
      <span>Show</span>
      <button type="button" data-filter="all" aria-pressed="true">All</button>
      <button type="button" data-filter="code" aria-pressed="false">Code</button>
      <button type="button" data-filter="lifecycle" aria-pressed="false">Lifecycle</button>
      <button type="button" data-filter="log" aria-pressed="false">Log</button>
    </div>
  </header>
  <main class="timeline">
    {"".join(sections)}
  </main>
  <aside class="note-box">
    <h2>What running it showed</h2>
    <p>{md("A failed build takes the whole plugin out of the session. `build` comes before `load_trigger` in my task list, so when it fails I arm no stubs, and the key and the command vanish instead of printing an error when used. That follows from the rule that a failure skips the rest of a plugin's tasks. Arming the stubs first and reporting the failure on first use would be a small change to the task order.")}</p>
  </aside>
</div>
<script>
(function () {{
  var buttons = Array.prototype.slice.call(document.querySelectorAll('[data-filter]'));
  buttons.forEach(function (button) {{
    button.addEventListener('click', function () {{
      var wanted = button.getAttribute('data-filter');
      document.querySelectorAll('.lens').forEach(function (lens) {{
        lens.hidden = wanted !== 'all' && lens.getAttribute('data-lens') !== wanted;
      }});
      buttons.forEach(function (other) {{
        other.setAttribute('aria-pressed', String(other === button));
      }});
    }});
  }});
}})();
</script>
"""

OUT.write_text(page)
print(len(page), "bytes")
