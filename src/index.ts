import { type Plugin, type Hooks, type ToolResult, tool } from "@opencode-ai/plugin";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

const TASKS_DIR = "/tmp/opencode-tasks";
const REGISTRY_FILE = join(TASKS_DIR, "registry.json");
const SAFE_ID_RE = /^[a-zA-Z0-9][a-zA-Z0-9_-]*$/;

type TaskStatus = "pending" | "running" | "completed" | "failed";

type RegistryEntry = {
  task_id: string;
  title: string;
  status: TaskStatus;
  chain_id?: string;
  step?: number;
  timestamp: string;
  file?: string;
};

type ChainStepDef = {
  step: number;
  title: string;
  prompt: string;
  status: TaskStatus;
};

type ChainPlan = {
  chain_id: string;
  created: string;
  steps: ChainStepDef[];
  initial_input: string | null;
  // completed_step tracks the highest step whose result has been submitted
  completed_step: number;
};

type Registry = Record<string, RegistryEntry>;

// ─── Helpers ───

function sanitizeId(id: string): string | null {
  return SAFE_ID_RE.test(id) ? id : null;
}

function safeRead<T>(path: string, fallback: T): T {
  try {
    const raw = readFileSync(path, "utf-8");
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function atomicWrite(path: string, data: string): void {
  const tmp = path + ".tmp." + process.pid;
  writeFileSync(tmp, data, "utf-8");
  renameSync(tmp, path);
}

function ensureDir(): void {
  if (!existsSync(TASKS_DIR)) {
    try {
      mkdirSync(TASKS_DIR, { recursive: true });
    } catch (err) {
      throw new Error(
        `Cannot create tasks directory ${TASKS_DIR}: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }
}

function readRegistry(): Registry {
  ensureDir();
  if (!existsSync(REGISTRY_FILE)) return {};
  return safeRead<Registry>(REGISTRY_FILE, {});
}

function writeRegistry(reg: Registry): void {
  ensureDir();
  atomicWrite(REGISTRY_FILE, JSON.stringify(reg, null, 2) + "\n");
}

function now(): string {
  return new Date().toISOString();
}

function readChain(chainId: string): ChainPlan | null {
  const path = join(TASKS_DIR, `chain-${chainId}`, "chain.json");
  if (!existsSync(path)) return null;
  return safeRead<ChainPlan>(path, null);
}

function writeChain(plan: ChainPlan): void {
  const dir = join(TASKS_DIR, `chain-${plan.chain_id}`);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  atomicWrite(join(dir, "chain.json"), JSON.stringify(plan, null, 2) + "\n");
}

function errMsg(e: unknown, fallback: string): string {
  return e instanceof Error ? e.message : String(e);
}

// ─── Plugin ───

const plugin: Plugin = async (): Promise<Hooks> => {
  return {
    tool: {
      task_list: tool({
        description:
          "List all tracked background tasks (both standalone and chain tasks). "
          + "Optionally filter by chain_id to see pipeline steps or by status to find in-flight/failed tasks. "
          + "Each entry shows: task_id, title, status, and for chain tasks: chain name + step number. "
          + "Output is sorted newest-first.",
        args: {
          chain_id: tool.schema
            .string()
            .optional()
            .describe("Filter: only show tasks belonging to this pipeline chain"),
          status: tool
            .schema
            .enum(["pending", "running", "completed", "failed"])
            .optional()
            .describe("Filter: only show tasks with this status"),
        },
        async execute(args, ctx): Promise<ToolResult> {
          try {
            const reg = readRegistry();
            let entries = Object.values(reg);

            if (args.chain_id) {
              entries = entries.filter((e) => e.chain_id === args.chain_id);
            }
            if (args.status) {
              entries = entries.filter((e) => e.status === args.status);
            }

            entries.sort(
              (a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime(),
            );

            if (entries.length === 0) {
              let msg = "No tasks found";
              if (args.chain_id) msg += ` for chain \`${args.chain_id}\``;
              if (args.status) msg += ` with status \`${args.status}\``;
              return msg + ".";
            }

            const lines = entries.map((e) => {
              const meta = e.chain_id
                ? ` [chain:\`${e.chain_id}\` step:${e.step ?? "?"}]`
                : "";
              return `  • \`${e.task_id}\` — ${e.title} (${e.status})${meta} ${e.timestamp.slice(0, 19).replace("T", " ")}`;
            });

            ctx.metadata({ title: `Task List (${entries.length})` });
            return lines.join("\n");
          } catch (err) {
            return `Error listing tasks: ${errMsg(err, "unknown error")}`;
          }
        },
      }),

      task_save: tool({
        description:
          "Persist a task result to disk for later reference. "
          + "Writes content as a markdown file at /tmp/opencode-tasks/{task_id}.md and registers it in the task tracker. "
          + "UPSERTS: if task_id already exists, updates the existing entry (useful for status progression). "
          + "After a background task completes, call this to save its output. "
          + "To mark a task as in-flight before the background job finishes: call with status='running' and minimal content, then call again with status='completed' and the full result.",
        args: {
          task_id: tool.schema
            .string()
            .describe(
              "Unique identifier — alphanumeric, hyphens and underscores allowed (e.g. 'research-001', 'my-chain-step-3'). "
              + "Must start with a letter or digit.",
            ),
          content: tool.schema
            .string()
            .describe("The content to persist. Pass the full task output or result text."),
          title: tool.schema
            .string()
            .optional()
            .describe("Human-readable title (defaults to task_id if omitted)"),
          status: tool
            .schema
            .enum(["pending", "running", "completed", "failed"])
            .optional()
            .describe(
              "Task status. Use 'running' to mark in-flight before a background job completes, "
              + "then call again with 'completed' or 'failed' when it finishes (default: 'completed').",
            ),
          chain_id: tool.schema
            .string()
            .optional()
            .describe("If this task is part of a pipeline chain, the chain_id"),
          step: tool.schema
            .number()
            .int()
            .optional()
            .describe("Step number within the chain (1-based). Only relevant when chain_id is set."),
        },
        async execute(args, ctx): Promise<ToolResult> {
          const safeId = sanitizeId(args.task_id);
          if (!safeId) {
            return (
              `Error: invalid task_id '${args.task_id}'. `
              + "Use only letters, digits, hyphens, and underscores. Must start with a letter or digit."
            );
          }

          const safeChainId = args.chain_id ? sanitizeId(args.chain_id) : null;
          if (args.chain_id && !safeChainId) {
            return (
              `Error: invalid chain_id '${args.chain_id}'. `
              + "Use only letters, digits, hyphens, and underscores."
            );
          }

          try {
            ensureDir();
            const status: TaskStatus = args.status ?? "completed";
            const filePath = join(TASKS_DIR, `${safeId}.md`);

            // Write content file (overwrite if exists — it's an upsert)
            const header = [
              `# ${args.title ?? safeId}`,
              `- **Task ID:** ${safeId}`,
              `- **Status:** ${status}`,
              `- **Saved:** ${now()}`,
              safeChainId ? `- **Chain:** ${safeChainId} (step ${args.step ?? "?"})` : null,
              "",
              "---",
              "",
            ]
              .filter(Boolean)
              .join("\n");

            atomicWrite(filePath, header + args.content + "\n");

            // Update registry (upsert)
            const reg = readRegistry();
            const existing = reg[safeId];
            reg[safeId] = {
              task_id: safeId,
              title: args.title ?? existing?.title ?? safeId,
              status,
              chain_id: safeChainId ?? existing?.chain_id,
              step: args.step ?? existing?.step,
              timestamp: now(),
              file: filePath,
            };
            writeRegistry(reg);

            ctx.metadata({ title: `Saved ${safeId}` });
            return (
              `Saved \`${safeId}\` to \`${filePath}\` (${args.content.length} chars, status: ${status})`
            );
          } catch (err) {
            return `Error saving task \`${args.task_id}\`: ${errMsg(err, "unknown error")}`;
          }
        },
      }),

      task_chain: tool({
        description:
          "Define a sequential pipeline of background tasks. "
          + "Creates a chain plan with N steps, saves it to /tmp/opencode-tasks/chain-{chain_id}/, "
          + "and returns a structured execution plan. "
          + "Each step's prompt may contain '{previous}' which gets replaced with the prior step's result at execution time. "
          + "After defining the chain, follow the execution plan: for each step, execute with task(background=true), "
          + "save results with task_save(..., chain_id=CHAIN_ID, step=N), and track progress with task_list(chain_id=CHAIN_ID). "
          + "Use task_step(chain_id, step, result) to auto-resolve '{previous}' and advance to the next step.",
        args: {
          chain_id: tool.schema
            .string()
            .describe(
              "Unique identifier — alphanumeric, hyphens and underscores (e.g. 'research-pipeline'). "
              + "Must start with a letter or digit.",
            ),
          steps: tool
            .schema
            .array(
              tool.schema.object({
                title: tool.schema
                  .string()
                  .describe("Short step label (e.g. 'Research topic'). Shows in logs and listings."),
                prompt: tool.schema
                  .string()
                  .describe(
                    "Full instruction for the background subagent. "
                    + "Use the literal placeholder '{previous}' (with braces) where the previous step's result should be injected. "
                    + "For step 1, this placeholder is replaced with the initial_input if provided.",
                  ),
              }),
            )
            .min(1)
            .describe("At least 1 step definition. Each step has a title and a prompt."),
          initial_input: tool.schema
            .string()
            .optional()
            .describe(
              "Context or data for step 1. Replaces '{previous}' in step 1's prompt. "
              + "Omit if step 1's prompt doesn't reference a prior result.",
            ),
        },
        async execute(args, ctx): Promise<ToolResult> {
          const safeId = sanitizeId(args.chain_id);
          if (!safeId) {
            return (
              `Error: invalid chain_id '${args.chain_id}'. `
              + "Use only letters, digits, hyphens, and underscores. Must start with a letter or digit."
            );
          }

          try {
            const defs: ChainStepDef[] = args.steps.map((s, i) => ({
              step: i + 1,
              title: s.title,
              prompt: s.prompt,
              status: "pending" as TaskStatus,
            }));

            const plan: ChainPlan = {
              chain_id: safeId,
              created: now(),
              steps: defs,
              initial_input: args.initial_input ?? null,
              completed_step: 0,
            };

            // Check if chain already exists
            const existing = readChain(safeId);
            if (existing) {
              return (
                `Chain \`${safeId}\` already exists with ${existing.steps.length} steps. `
                + "Use a different chain_id or delete /tmp/opencode-tasks/chain-{chain_id}/chain.json."
              );
            }

            writeChain(plan);

            // Register the chain itself in the task registry
            const reg = readRegistry();
            reg[`chain-${safeId}`] = {
              task_id: `chain-${safeId}`,
              title: `Pipeline: ${safeId}`,
              status: "running",
              chain_id: safeId,
              timestamp: now(),
            };
            writeRegistry(reg);

            // Build the return message — a complete execution plan the LLM follows
            const stepLines = args.steps.map(
              (s, i) =>
                `Step ${i + 1}/${args.steps.length}: "${s.title}"\n`
                + `  Execute: \`task(description="${s.title}", background=true, prompt="""<see prompt below>""")\`\n`
                + `  Save: \`task_save(task_id="${safeId}-step-${i + 1}", content=<result>, chain_id="${safeId}", step=${i + 1}, title="${s.title}")\``,
            );

            const promptLines = args.steps.map((s, i) => {
              const resolved =
                i === 0 && args.initial_input
                  ? s.prompt.replace("{previous}", args.initial_input)
                  : s.prompt;
              return `Step ${i + 1} prompt: """${resolved}"""`;
            });

            const msg = [
              `## Pipeline: ${safeId} (${args.steps.length} steps, created ${plan.created.slice(0, 19).replace("T", " ")})`,
              "",
              "### Steps",
              ...stepLines,
              "",
              "### Prompts (with {previous} resolved for step 1)",
              ...promptLines,
              "",
              "### Execution workflow",
              "1. Call `task(background=true)` with step 1's prompt",
              "2. On completion, call `task_save()` with the result",
              "3. Call `task_step(chain_id=\"" + safeId + "\", step=1, result=<result>)` to advance to step 2",
              "4. Repeat for remaining steps",
              "5. View progress: `task_list(chain_id=\"" + safeId + "\")`",
            ].join("\n");

            ctx.metadata({ title: `Chain: ${safeId} (${args.steps.length} steps)` });
            return msg;
          } catch (err) {
            return `Error creating chain \`${args.chain_id}\`: ${errMsg(err, "unknown error")}`;
          }
        },
      }),

      task_step: tool({
        description:
          "Advance a pipeline chain to the next step. "
          + "Marks the specified step as completed using the provided result, then returns the next step's prompt "
          + "with '{previous}' resolved to the result you pass. "
          + "Call this after each task_save() to continue the chain. "
          + "When no more steps remain, returns a completion message.",
        args: {
          chain_id: tool.schema
            .string()
            .describe("The pipeline chain_id to advance"),
          step: tool.schema
            .number()
            .int()
            .min(1)
            .describe("The step number that just completed (1-based)"),
          result: tool.schema
            .string()
            .describe(
              "The content/result from the completed step. "
              + "This value replaces the '{previous}' placeholder in the next step's prompt.",
            ),
        },
        async execute(args, ctx): Promise<ToolResult> {
          const safeId = sanitizeId(args.chain_id);
          if (!safeId) {
            return (
              `Error: invalid chain_id '${args.chain_id}'. `
              + "Use only letters, digits, hyphens, and underscores."
            );
          }

          try {
            const plan = readChain(safeId);
            if (!plan) {
              return `Chain \`${safeId}\` not found. Create it first with task_chain().`;
            }

            if (args.step < 1 || args.step > plan.steps.length) {
              return (
                `Invalid step ${args.step}. Chain \`${safeId}\` has ${plan.steps.length} steps (1-${plan.steps.length}).`
              );
            }

            // Mark the completed step
            const stepIdx = args.step - 1;
            plan.steps[stepIdx].status = "completed";
            plan.completed_step = Math.max(plan.completed_step, args.step);

            // Find next pending step
            const nextStep = plan.steps.find((s) => s.status === "pending");
            writeChain(plan);

            // Update the registry entry for the completed step
            const reg = readRegistry();
            const stepTaskId = `${safeId}-step-${args.step}`;
            if (reg[stepTaskId]) {
              reg[stepTaskId].status = "completed";
              reg[stepTaskId].timestamp = now();
            }
            writeRegistry(reg);

            if (!nextStep) {
              // All steps done
              reg[`chain-${safeId}`]!.status = "completed";
              reg[`chain-${safeId}`]!.timestamp = now();
              writeRegistry(reg);

              ctx.metadata({ title: `Chain ${safeId}: complete` });
              return (
                `## Chain \`${safeId}\`: All ${plan.steps.length} steps completed!\n`
                + `\nView results: \`task_list(chain_id="${safeId}")\``
              );
            }

            // Resolve {previous} in the next step's prompt
            const resolvedPrompt = nextStep.prompt.replace(/\{previous\}/g, args.result);

            ctx.metadata({
              title: `Step ${nextStep.step}/${plan.steps.length}: ${nextStep.title}`,
            });

            return [
              `**Chain:** \`${safeId}\``,
              `**Current step:** ${nextStep.step}/${plan.steps.length} — "${nextStep.title}"`,
              `**Previous step ${args.step}** completed.`,
              "",
              `**Prompt for step ${nextStep.step}:**`,
              resolvedPrompt,
            ].join("\n");
          } catch (err) {
            return (
              `Error advancing chain \`${args.chain_id}\` step ${args.step}: `
              + `${errMsg(err, "unknown error")}`
            );
          }
        },
      }),
    },
  };
};

export default plugin;
