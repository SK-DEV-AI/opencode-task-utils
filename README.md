# opencode-task-utils

Task persistence, listing, pipeline chaining, and step management for opencode background subagents.

## Tools

**`task_list`** — List tracked background tasks. Filter by `chain_id` or `status`.

**`task_save`** — Persist a subagent result to `/tmp/opencode-tasks/{task_id}.md` with metadata. Supports upsert (update existing entry) and all statuses: `pending`, `running`, `completed`, `failed`.

**`task_chain`** — Define a multi-step pipeline. Creates a chain plan and returns a structured execution guide. Use with `task_step` for automatic `{previous}` resolution between steps.

**`task_step`** — Advance a pipeline chain. Marks a step completed with your result, then returns the next step's prompt with `{previous}` resolved. When the last step completes, marks the chain done. Validates step ordering (no skipping, no re-advancing completed steps).

**`task_rm`** — Delete a task or entire chain from the registry. Provide exactly one of `task_id` (single task) or `chain_id` (entire pipeline). Optionally `delete_file=true` to remove the associated content file and chain directory. Idempotent — safe to call on already-deleted entries.

## How It Works

```
task_chain(chain_id="pipeline", steps=[...])
  → Plan created with N steps

For each step:
  1. task(background=true, prompt=step_prompt)
  2. task_save(task_id, content=result, chain_id, step)
  3. task_step(chain_id, step=N, result=result)
     → Returns next step's prompt with {previous} resolved

task_list(chain_id="pipeline") → shows progress
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
→ Saved `research-001` to `/tmp/opencode-tasks/research-001.md` (4500 chars, status: completed)
```

Upsert — mark in-flight, then update:
```
task_save(task_id="long-job", content="started at ...", status="running")
→ Saved `long-job` ... (status: running)

# later:
task_save(task_id="long-job", content="...full result...", status="completed")
→ Saved `long-job` ... (status: completed)
```

### List tracked tasks
```
task_list()
→ • `research-001` — Research findings (completed) 2026-05-29 12:00:00
  • `long-job` — long-job (running) 2026-05-29 12:05:00
```

### Pipeline with task_step
```
task_chain(
  chain_id="report",
  steps=[
    {title: "Research topic", prompt: "Research {previous}"},
    {title: "Summarize", prompt: "Summarize in 3 bullets: {previous}"},
    {title: "Write report", prompt: "Write a report from: {previous}"}
  ],
  initial_input="Context about X"
)
→ Creates plan, returns step 1 prompt

# Execute step 1
task(background=true, prompt="Research Context about X")
task_save(task_id="report-step-1", content=<result>, chain_id="report", step=1)

# Advance chain — task_step resolves {previous} in step 2's prompt
task_step(chain_id="report", step=1, result=<result>)
→ Returns step 2 prompt with {previous} replaced by actual result

# Execute step 2 with the resolved prompt
task(background=true, prompt=<step 2 prompt>)
task_save(task_id="report-step-2", content=<result>, chain_id="report", step=2)
task_step(chain_id="report", step=2, result=<result>)
→ Returns step 3 prompt, or "All steps completed!" if done
```

### Path validation
All IDs (`task_id`, `chain_id`) are validated: alphanumeric, hyphens, underscores only. Invalid IDs are rejected with a clear error message.

### Concurrency
Registry writes use atomic file operations (write to `.tmp`, then `rename`) — safe against concurrent tool calls. Orphaned `.tmp.*` files from crashed sessions are cleaned up automatically on plugin init.

### Content size limit
Warns if saved content exceeds 1MB. No hard limit — but large files impact tool response times.

### Delete tasks or chains
```bash
# Single task
task_rm(task_id="research-001")
→ Deleted `research-001` from registry.

# Delete task + its content file
task_rm(task_id="research-001", delete_file=true)
→ Deleted `research-001` from registry and removed file.

# Delete entire chain + all its tasks
task_rm(chain_id="report")
→ Deleted chain `report` (3 tasks removed).

# Delete chain + content files + chain directory
task_rm(chain_id="report", delete_file=true)
→ Deleted chain `report` (3 tasks removed) with content files.

# Idempotent — safe to call again:
task_rm(task_id="research-001")
→ Task `research-001` not found in registry. Nothing to delete.
```

## Testing

```bash
git clone https://github.com/SK-DEV-AI/opencode-task-utils
cd opencode-task-utils
./test.sh
```

52 integration tests covering: sanitizeId validation, atomicWrite concurrency, registry CRUD, chain plan management, task_rm deletion, corrupt/missing file resilience, and stale .tmp cleanup.
