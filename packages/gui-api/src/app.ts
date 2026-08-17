import { spawn } from "node:child_process";
import * as readline from "node:readline";
import { type Context, Hono } from "hono";
import { APP_ACTION_ROUTE_MANIFEST, APP_ACTION_STATUS_ROUTE_MANIFEST, BANNED_ROUTE_PATTERNS, createEnvelope, FILE_EXPLORER_ROUTE_MANIFEST, type GuiAppActionId, type GuiAppActionJobSummary, type GuiPulseWorkerActionId, type GuiPulseWorkerActionJobSummary, PULSE_WORKERS_ACTION_ROUTE_MANIFEST, PULSE_WORKERS_ACTION_STATUS_ROUTE_MANIFEST, STATUS_ROUTE_MANIFEST, TAMBO_PROVIDER_CONFIG, TAMBO_PROXY_ROUTE_MANIFEST, VAULT_STATUS_ROUTE_MANIFEST } from "../../gui-shared/src";
import { readFileExplorer } from "./file-adapter";
import { readStatus, readVaultStatus } from "./status-adapter";

const appActionCommands: Record<string, Partial<Record<GuiAppActionId, string[]>>> = {
  aidevops: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update"], reinstall: ["./setup.sh", "--non-interactive"] },
  agents: { install: ["aidevops", "setup", "--scope", "agents"], update: ["aidevops", "setup", "--scope", "agents"], reinstall: ["aidevops", "setup", "--scope", "agents"] },
  "gui-desktop": { install: ["aidevops", "setup", "--scope", "gui-desktop"], update: ["aidevops", "setup", "--scope", "gui-desktop"], reinstall: ["aidevops", "setup", "--scope", "gui-desktop"] },
  hooks: { install: ["aidevops", "setup", "--scope", "hooks"], update: ["aidevops", "setup", "--scope", "hooks"], reinstall: ["aidevops", "setup", "--scope", "hooks"] },
  opencode: { install: ["aidevops", "setup", "--scope", "opencode"], update: ["aidevops", "setup", "--scope", "opencode"], reinstall: ["aidevops", "setup", "--scope", "opencode"] },
  "opencode-cli": { install: ["aidevops", "setup", "--scope", "opencode"], update: ["aidevops", "setup", "--scope", "opencode"], reinstall: ["aidevops", "setup", "--scope", "opencode"] },
  pulse: { install: ["aidevops", "setup", "--scope", "pulse"], update: ["aidevops", "setup", "--scope", "pulse"], reinstall: ["aidevops", "setup", "--scope", "pulse"] },
  tabby: { install: ["aidevops", "setup", "--scope", "tabby"], update: ["aidevops", "setup", "--scope", "tabby"], reinstall: ["aidevops", "setup", "--scope", "tabby"] },
  bun: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  cursor: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  fd: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  gh: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  glab: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  homebrew: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  node: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  ollama: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  orbstack: { install: ["./setup.sh", "--non-interactive"] },
  qlty: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  ripgrep: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  "ripgrep-all": { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  rtk: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  shellcheck: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  shfmt: { install: ["./setup.sh", "--non-interactive"], update: ["aidevops", "update-tools", "--update"] },
  zed: { install: ["./setup.sh", "--non-interactive"] },
};

const appActionJobs = new Map<string, GuiAppActionJobSummary>();

const pulseWorkerActionCommands: Record<GuiPulseWorkerActionId, { command: string[]; audit_ref: string; target_ref: string }> = {
  diagnose: { command: ["aidevops", "pulse", "diagnose", "--gui", "--metadata-only"], audit_ref: "gui:pulse-workers:diagnose", target_ref: "selected event" },
  run_pulse: { command: ["aidevops", "pulse", "run", "--scope", "gui"], audit_ref: "gui:pulse-workers:run-pulse", target_ref: "current filtered scope" },
  open_logs: { command: ["aidevops", "pulse", "logs", "--metadata-only"], audit_ref: "gui:pulse-workers:open-logs", target_ref: "selected event evidence refs" },
  create_systemic_fix: { command: ["aidevops", "task", "create", "--from-pulse", "--worker-ready"], audit_ref: "gui:pulse-workers:create-systemic-fix", target_ref: "selected event systemic-fix context" },
};

const pulseWorkerActionJobs = new Map<string, GuiPulseWorkerActionJobSummary>();

export function createGuiApiApp() {
  const app = new Hono();

  app.get("/api/health", (context) => context.json(createEnvelope({
      operation_id: "capabilities.read",
      source: { surface: "health", authority: "in-process readiness probe", path_refs: [] },
      data: { status: "ok", service: "aidevops-gui-api" },
    })));

  app.get(STATUS_ROUTE_MANIFEST.route, (context) => context.json(readStatus()));

  app.get(VAULT_STATUS_ROUTE_MANIFEST.route, (context) => context.json(readVaultStatus()));

  app.get(TAMBO_PROXY_ROUTE_MANIFEST.route, (context) => context.json(createEnvelope({
      operation_id: TAMBO_PROXY_ROUTE_MANIFEST.operation_id,
      source: { surface: "conversations", authority: "server-side Tambo proxy metadata", path_refs: ["packages/gui-shared/src/tambo.ts"] },
      data: {
        ...TAMBO_PROVIDER_CONFIG,
        thread_key_ref: `${threadScopeRef(context.req.query("tenant_ref") ?? "local")}:${threadScopeRef(context.req.query("workspace_ref") ?? "aidevops")}:${context.req.query("session_ref") ?? "conversation:local"}`,
      },
      warnings: ["Tambo provider secrets stay server-side; this route exposes component metadata and scoped thread keys only."],
    })));

  app.post(APP_ACTION_ROUTE_MANIFEST.route, handleAppAction);
  app.get(APP_ACTION_STATUS_ROUTE_MANIFEST.route, handleAppActionStatus);
	app.post(PULSE_WORKERS_ACTION_ROUTE_MANIFEST.route, handlePulseWorkerAction);
	app.get(PULSE_WORKERS_ACTION_STATUS_ROUTE_MANIFEST.route, handlePulseWorkerActionStatus);

	app.get(FILE_EXPLORER_ROUTE_MANIFEST.route, (context) => context.json(
		...fileExplorerResult(context.req.param("root") ?? "", context.req.query("path") ?? ""),
	));

  for (const route of BANNED_ROUTE_PATTERNS) {
    app.post(route, (context) => context.json(
        {
          ok: false,
          operation_id: "capabilities.read",
          errors: ["write_actions_disabled"],
        },
        405,
      ));
  }

  app.notFound((context) => context.json(
      {
        ok: false,
        operation_id: "capabilities.read",
        errors: ["unknown_route"],
      },
      404,
    ));

  return app;
}

function handleAppAction(context: Context) {
	const appId = context.req.param("appId");
	const actionParam = context.req.param("action");
	if (appId === undefined || actionParam === undefined) {
		return context.json(createEnvelope({
			operation_id: APP_ACTION_ROUTE_MANIFEST.operation_id,
			source: { surface: "apps", authority: "allowlisted local command runner", path_refs: [] },
			data: rejectedJob(appId ?? "unknown", "install", "Missing app action parameters."),
			errors: ["action_not_allowlisted"],
		}), 400);
	}
	const action = actionParam as GuiAppActionId;
	const command = appActionCommands[appId]?.[action];
  if (command === undefined) {
    return context.json(createEnvelope({
      operation_id: APP_ACTION_ROUTE_MANIFEST.operation_id,
      source: { surface: "apps", authority: "allowlisted local command runner", path_refs: [] },
      data: rejectedJob(appId, action, "No allowlisted command for this app action."),
      errors: ["action_not_allowlisted"],
    }), 400);
  }
  const job = startAppActionJob(appId, action, command);
  return context.json(createEnvelope({
    operation_id: APP_ACTION_ROUTE_MANIFEST.operation_id,
    source: { surface: "apps", authority: "allowlisted local command runner", path_refs: ["setup.sh", "aidevops.sh"] },
    data: job,
    warnings: ["Command runs locally in the background. Output is retained in memory for this GUI API process only."],
  }), 202);
}

function handleAppActionStatus(context: Context) {
	const job = appActionJobs.get(context.req.param("jobId") ?? "");
  if (job === undefined) {
    return context.json(createEnvelope({
      operation_id: APP_ACTION_STATUS_ROUTE_MANIFEST.operation_id,
      source: { surface: "apps", authority: "background job store", path_refs: [] },
      data: rejectedJob("unknown", "install", "Unknown job."),
      errors: ["unknown_job"],
    }), 404);
  }
  return context.json(createEnvelope({
    operation_id: APP_ACTION_STATUS_ROUTE_MANIFEST.operation_id,
    source: { surface: "apps", authority: "background job store", path_refs: [] },
    data: job,
  }));
}

function handlePulseWorkerAction(context: Context) {
	const actionParam = context.req.param("action");
	if (actionParam === undefined || !Object.hasOwn(pulseWorkerActionCommands, actionParam)) {
		return context.json(createEnvelope({
			operation_id: PULSE_WORKERS_ACTION_ROUTE_MANIFEST.operation_id,
			source: { surface: "pulse_workers", authority: "allowlisted local command runner", path_refs: [] },
			data: rejectedPulseWorkerJob("diagnose", "No allowlisted command for this Pulse & Workers action."),
			errors: ["action_not_allowlisted"],
		}), 400);
	}
	const action = actionParam as GuiPulseWorkerActionId;
	const actionCommand = pulseWorkerActionCommands[action];
  const job = startPulseWorkerActionJob(action, actionCommand.command, actionCommand.target_ref, actionCommand.audit_ref);
  return context.json(createEnvelope({
    operation_id: PULSE_WORKERS_ACTION_ROUTE_MANIFEST.operation_id,
    source: { surface: "pulse_workers", authority: "allowlisted local command runner", path_refs: [".agents/scripts", "packages/gui-api/src/app.ts"] },
    data: job,
    warnings: ["Command runs locally in the background through an explicit allowlist. Output is redacted and retained in memory for this GUI API process only."],
  }), 202);
}

function handlePulseWorkerActionStatus(context: Context) {
	const job = pulseWorkerActionJobs.get(context.req.param("jobId") ?? "");
  if (job === undefined) {
    return context.json(createEnvelope({
      operation_id: PULSE_WORKERS_ACTION_STATUS_ROUTE_MANIFEST.operation_id,
      source: { surface: "pulse_workers", authority: "background job store", path_refs: [] },
      data: rejectedPulseWorkerJob("diagnose", "Unknown Pulse & Workers job."),
      errors: ["unknown_job"],
    }), 404);
  }
  return context.json(createEnvelope({
    operation_id: PULSE_WORKERS_ACTION_STATUS_ROUTE_MANIFEST.operation_id,
    source: { surface: "pulse_workers", authority: "background job store", path_refs: [] },
    data: job,
  }));
}

function fileExplorerResult(root: string, path: string) {
  const response = readFileExplorer(root, path);
  const status = response.ok ? 200 : response.errors.includes("unknown_file_root") ? 404 : 400;
  return [response, status] as const;
}

function startAppActionJob(appId: string, action: GuiAppActionId, command: string[]): GuiAppActionJobSummary {
  const now = new Date().toISOString();
  const redactLine = createOutputLineRedactor();
  const job: GuiAppActionJobSummary = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2)}`,
    app_id: appId,
    action,
    status: "running",
    command_preview: command.join(" "),
    started_at: now,
    finished_at: null,
    exit_code: null,
    output: [`$ ${command.join(" ")}`],
  };
  appActionJobs.set(job.id, job);

  const child = spawn(command[0], command.slice(1), {
    cwd: process.cwd(),
    env: { ...process.env, AIDEVOPS_NON_INTERACTIVE: "true", CLICOLOR_FORCE: "1", FORCE_COLOR: "1", TERM: process.env.TERM ?? "xterm-256color" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (child.stdout !== null) {
    const stdoutLines = readline.createInterface({ input: child.stdout, terminal: false });
    stdoutLines.on("line", (line) => appendJobLine(job, line, redactLine));
  }
  if (child.stderr !== null) {
    const stderrLines = readline.createInterface({ input: child.stderr, terminal: false });
    stderrLines.on("line", (line) => appendJobLine(job, line, redactLine));
  }
  child.on("error", (error) => {
    appendJobLine(job, error.message);
    job.status = "failed";
    job.finished_at = new Date().toISOString();
    job.exit_code = 127;
  });
  child.on("close", (code) => {
    job.status = code === 0 ? "completed" : "failed";
    job.finished_at = new Date().toISOString();
    job.exit_code = code;
  });

  return job;
}

function appendJobLine(job: GuiAppActionJobSummary, line: string, redactLine: (line: string) => string = redactOutputLine): void {
  if (line.length === 0) {
    return;
  }
  job.output.push(redactLine(line));
  if (job.output.length > 400) {
    job.output.splice(1, job.output.length - 400);
  }
}

function startPulseWorkerActionJob(action: GuiPulseWorkerActionId, command: string[], targetRef: string, auditRef: string): GuiPulseWorkerActionJobSummary {
  const now = new Date().toISOString();
  const redactLine = createOutputLineRedactor();
  const job: GuiPulseWorkerActionJobSummary = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2)}`,
    action,
    target_ref: targetRef,
    status: "running",
    command_preview: command.join(" "),
    started_at: now,
    finished_at: null,
    exit_code: null,
    output: [`$ ${command.join(" ")}`, `audit_ref=${auditRef}`],
    audit_ref: auditRef,
  };
  pulseWorkerActionJobs.set(job.id, job);
  startBackgroundProcess(command, (line) => appendPulseWorkerJobLine(job, line, redactLine), (code) => {
    job.status = code === 0 ? "completed" : "failed";
    job.finished_at = new Date().toISOString();
    job.exit_code = code;
  });

  return job;
}

function appendPulseWorkerJobLine(job: GuiPulseWorkerActionJobSummary, line: string, redactLine: (line: string) => string = redactOutputLine): void {
  if (line.length === 0) {
    return;
  }
  job.output.push(redactLine(line));
  if (job.output.length > 400) {
    job.output.splice(1, job.output.length - 400);
  }
}

function startBackgroundProcess(command: string[], appendLine: (line: string) => void, finish: (code: number) => void): void {
  let finished = false;
  const safeFinish = (code: number): void => {
    if (finished) {
      return;
    }
    finished = true;
    finish(code);
  };

  const child = spawn(command[0], command.slice(1), {
    cwd: process.cwd(),
    env: { ...process.env, AIDEVOPS_NON_INTERACTIVE: "true", CLICOLOR_FORCE: "1", FORCE_COLOR: "1", TERM: process.env.TERM ?? "xterm-256color" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (child.stdout !== null) {
    readline.createInterface({ input: child.stdout, terminal: false }).on("line", appendLine);
  }
  if (child.stderr !== null) {
    readline.createInterface({ input: child.stderr, terminal: false }).on("line", appendLine);
  }
  child.on("error", (error) => {
    appendLine(error.message);
    safeFinish(127);
  });
  child.on("close", (code) => safeFinish(code ?? 1));
}

export function createOutputLineRedactor(): (line: string) => string {
  let inPrivateKeyBlock = false;

  return (line: string): string => {
    if (/-----BEGIN [A-Z ]+ PRIVATE KEY-----/.test(line)) {
      inPrivateKeyBlock = !/-----END [A-Z ]+ PRIVATE KEY-----/.test(line);
      return "[redacted private key]";
    }

    if (inPrivateKeyBlock) {
      if (/-----END [A-Z ]+ PRIVATE KEY-----/.test(line)) {
        inPrivateKeyBlock = false;
      }
      return "[redacted private key]";
    }

    return redactOutputLine(line);
  };
}

function redactOutputLine(line: string): string {
  return line
    .replace(/(token|secret|password|authorization|api[_-]?key|sessionid)=\S+/gi, "$1=[redacted]")
    .replace(/Bearer\s+\S+/gi, "Bearer [redacted]")
    .replace(/-----BEGIN [A-Z ]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+ PRIVATE KEY-----/g, "[redacted private key]");
}

function rejectedJob(appId: string, action: GuiAppActionId, message: string): GuiAppActionJobSummary {
  const now = new Date().toISOString();
  return { id: "rejected", app_id: appId, action, status: "rejected", command_preview: "not run", started_at: now, finished_at: now, exit_code: null, output: [message] };
}

function rejectedPulseWorkerJob(action: GuiPulseWorkerActionId, message: string): GuiPulseWorkerActionJobSummary {
  const now = new Date().toISOString();
  return { id: "rejected", action, target_ref: "none", status: "rejected", command_preview: "not run", started_at: now, finished_at: now, exit_code: null, output: [message], audit_ref: "gui:pulse-workers:rejected" };
}

export const app = createGuiApiApp();

function threadScopeRef(value: string): string {
  return value.replace(/:/g, "");
}
