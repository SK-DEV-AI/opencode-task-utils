# opencode-task-utils

Task persistence, listing, and pipeline chaining for opencode background subagents.

## Tools

**`task_list`** — List tracked background tasks. Filter by `chain_id` or `status`.

**`task_save`** — Persist a subagent result to `/tmp/opencode-tasks/{task_id}.md` with metadata.

**`task_chain`** — Define a sequential pipeline. Returns an execution plan the agent follows step-by-step, with `task_save` for intermediate results and `task_list` for progress tracking.

## How It Works

```
┌──────────────────────────────────────────────────────────────┐
│ Agent calls task_chain({chain_id, steps, initial_input})     │
│  → Writes chain plan to /tmp/opencode-tasks/chain-{id}/     │
│  → Returns step-by-step execution instructions               │
├──────────────────────────────────────────────────────────────┤
│ For each step, agent:                                        │
│  1. task(description="Step N", prompt="...", background=true)│
│  2. task_save(task_id="chain-step-N", content=result, ...)   │
├──────────────────────────────────────────────────────────────┤
│ task_list(chain_id="...") → shows progress                   │
└──────────────────────────────────────────────────────────────┘
```

## Installation

```bash
npm install -g opencode-task-utils
```

Add to `~/.config/opencode/opencode.jsonc`:

```jsonc
"plugin": [
  "opencode-task-utils",
  // ... other plugins
]
```

## Usage

### Save a task result
```
task_save(task_id="research-001", content="...results...", title="Research findings")
→ Saved `research-001` to `/tmp/opencode-tasks/research-001.md`
```

### List tracked tasks
```
task_list()
→ • `research-001` — Research findings (completed) 2026-05-29 12:00:00
```

### Define a pipeline
```
task_chain(
  chain_id="report",
  steps=[
    {title: "Research topic", prompt: "Research X in depth. {previous}"},
    {title: "Summarize", prompt: "Summarize these findings in 3 bullet points: {previous}"},
    {title: "Write report", prompt: "Write a report based on: {previous}"}
  ],
  initial_input="Context about X"
)
```

Then execute each step with `task(background=true)` + `task_save`.
