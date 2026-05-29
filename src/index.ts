import { type Plugin, type Hooks, type ToolResult, tool } from "@opencode-ai/plugin";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const TASKS_DIR = "/tmp/opencode-tasks";
const REGISTRY_FILE = join(TASKS_DIR, "registry.json");

type RegistryEntry = {
  task_id: string;
  title: string;
  status: "pending" | "running" | "completed" | "failed";
  chain_id?: string;
  step?: number;
  timestamp: string;
  file?: string;
};

type Registry = Record<string, RegistryEntry>;

function ensureDir(): void {
  if (!existsSync(TASKS_DIR)) mkdirSync(TASKS_DIR, { recursive: true });
}

function readRegistry(): Registry {
  ensureDir();
  try {
    return JSON.parse(readFileSync(REGISTRY_FILE, "utf-8"));
  } catch {
    return {};
  }
}

function writeRegistry(reg: Registry): void {
  ensureDir();
  writeFileSync(REGISTRY_FILE, JSON.stringify(reg, null, 2) + "\n");
}

function now(): string {
  return new Date().toISOString();
}

const plugin: Plugin = async (): Promise<Hooks> => {
  return {
    tool: {
      task_list: tool({
        description:
          "List tracked background tasks from the task registry. Shows task IDs, titles, statuses, timestamps, and chain/step info for pipeline tasks. Optionally filter by chain_id or status.",
        args: {
          chain_id: tool.schema
            .string()
            .optional()
            .describe(
              "Filter by chain ID to show only tasks belonging to a specific pipeline chain",
            ),
          status: tool
            .schema
            .enum(["pending", "running", "completed", "failed"])
            .optional()
            .describe("Filter by task status"),
        },
        async execute(args, ctx): Promise<ToolResult> {
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
            return "No tasks found" + (args.chain_id ? ` for chain \`${args.chain_id}\`` : "") + (args.status ? ` with status \`${args.status}\`` : "") + ".";
          }

          const lines = entries.map((e) => {
            const meta = e.chain_id ? ` [chain:${e.chain_id} step:${e.step ?? "?"}]` : "";
            return `  • \`${e.task_id}\` — ${e.title} (${e.status})${meta} ${e.timestamp.slice(0, 19).replace("T", " ")}`;
          });

          ctx.metadata({ title: `Task List (${entries.length})` });
          return lines.join("\n");
        },
      }),

      task_save: tool({
        description:
          "Save a background task result to disk. Writes content to `/tmp/opencode-tasks/{task_id}.md` and updates the task registry with metadata. Use after a `task(background=true)` completes to persist the result for later reference.",
        args: {
          task_id: tool.schema.string().describe("Unique identifier for the task (e.g. 'research-001')"),
          content: tool.schema.string().describe("Task result content to persist to disk"),
          title: tool.schema.string().optional().describe("Human-readable title for the task"),
          status: tool
            .schema
            .enum(["completed", "failed"])
            .optional()
            .describe("Task outcome status (default: 'completed')"),
          chain_id: tool.schema.string().optional().describe("Pipeline chain ID if this task belongs to a chain"),
          step: tool.schema.number().optional().describe("Step number within the chain (1-based)"),
        },
        async execute(args, ctx): Promise<ToolResult> {
          ensureDir();
          const status = args.status ?? "completed";
          const filePath = join(TASKS_DIR, `${args.task_id}.md`);

          const header = [
            `# ${args.title ?? args.task_id}`,
            `- **Task ID:** ${args.task_id}`,
            `- **Status:** ${status}`,
            `- **Saved:** ${now()}`,
            args.chain_id ? `- **Chain:** ${args.chain_id} (step ${args.step ?? "?"})` : null,
            "",
            "---",
            "",
          ]
            .filter(Boolean)
            .join("\n");

          const body = args.content;
          writeFileSync(filePath, header + body + "\n");

          const reg = readRegistry();
          reg[args.task_id] = {
            task_id: args.task_id,
            title: args.title ?? args.task_id,
            status: status as RegistryEntry["status"],
            chain_id: args.chain_id,
            step: args.step,
            timestamp: now(),
            file: filePath,
          };
          writeRegistry(reg);

          ctx.metadata({ title: `Saved ${args.task_id}` });
          return `Saved \`${args.task_id}\` to \`${filePath}\` (${body.length} chars, status: ${status})`;
        },
      }),

      task_chain: tool({
        description:
          "Define a sequential multi-step pipeline of background tasks. Creates a chain plan file and returns step-by-step execution instructions. After calling this tool, execute each step with `task(background=true)` using the returned prompt, then save each result with `task_save`. Track progress with `task_list(chain_id=CHAIN_ID)`.",
        args: {
          chain_id: tool.schema.string().describe("Unique identifier for this pipeline chain (e.g. 'my-pipeline')"),
          steps: tool
            .schema
            .array(
              tool.schema.object({
                title: tool.schema.string().describe("Short step title (e.g. 'Research topic')"),
                prompt: tool.schema.string().describe("Full instruction for the background subagent. Use `{previous}` as a placeholder for the previous step's result."),
              }),
            )
            .min(1)
            .describe("Array of step definitions to execute in sequence. Minimum 1 step."),
          initial_input: tool.schema.string().optional().describe("Optional context/input to pass to the first step. Replaces `{previous}` in step 1's prompt."),
        },
        async execute(args, ctx): Promise<ToolResult> {
          ensureDir();
          const chainDir = join(TASKS_DIR, `chain-${args.chain_id}`);
          if (!existsSync(chainDir)) mkdirSync(chainDir, { recursive: true });

          const defs = args.steps.map((s, i) => ({
            step: i + 1,
            title: s.title,
            prompt: s.prompt,
            status: "pending" as const,
          }));

          const chain = {
            chain_id: args.chain_id,
            created: now(),
            steps: defs,
            initial_input: args.initial_input ?? null,
          };

          writeFileSync(join(chainDir, "chain.json"), JSON.stringify(chain, null, 2) + "\n");

          // Build step-by-step instructions for the agent
          const stepsText = args.steps
            .map(
              (s, i) =>
                `**Step ${i + 1}/${args.steps.length}:** ${s.title}\n  → _prompt_: ${s.prompt.slice(0, 120)}${s.prompt.length > 120 ? "…" : ""}`,
            )
            .join("\n\n");

          const instructions = [
            `## Pipeline: ${args.chain_id} (${args.steps.length} steps)`,
            ``,
            stepsText,
            ``,
            `### Execution Plan`,
            ``,
            ...args.steps.flatMap((s, i) => {
              const sid = `${args.chain_id}-step-${i + 1}`;
              const promptNote =
                i === 0 && args.initial_input
                  ? s.prompt.replace("{previous}", args.initial_input)
                  : s.prompt;
              return [
                `${i + 1}. \`task(description="${s.title}", prompt="""${promptNote.slice(0, 200)}""", background=true)\``,
                `   → After completion: \`task_save(task_id="${sid}", content=<result>, chain_id="${args.chain_id}", step=${i + 1}, title="${s.title}")\``,
                ``,
              ];
            }),
            `### Progress Tracking`,
            `Check progress: \`task_list(chain_id="${args.chain_id}")\``,
          ].join("\n");

          ctx.metadata({ title: `Chain: ${args.chain_id} (${args.steps.length} steps)` });
          return instructions;
        },
      }),
    },
  };
};

export default plugin;
