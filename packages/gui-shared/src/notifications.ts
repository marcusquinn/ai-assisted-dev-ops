import type { GuiAiAppSummary, GuiNotificationAction, GuiNotificationCategory, GuiNotificationSeverity, GuiNotificationSummary, GuiOAuthPoolSummary, GuiSetupTargetSummary } from "./contracts";

interface BuildNotificationInput {
  aiApps: GuiAiAppSummary[];
  greetingOutput: string;
  oauthPool: GuiOAuthPoolSummary;
  restartRequired: boolean;
  setupTargets: GuiSetupTargetSummary[];
}

const toastSeverityRank: Record<GuiNotificationSeverity, number> = {
  success: 0,
  info: 1,
  warning: 2,
  error: 3,
};

const warningLineMatchers: Array<(line: string) => boolean> = [
  (line) => line.startsWith("Pulse stalled"),
  (line) => /contribution(\(s\)|s)?\s+needs?/i.test(line),
  (line) => line.startsWith("[OPENCODE MAINTENANCE]"),
  (line) => line.startsWith("[WARNING]"),
  (line) => line.startsWith("[WARN]"),
];

const toastTitleRules: Array<{ matches: (line: string) => boolean; title: string }> = [
  { matches: (line) => line.startsWith("[SECURITY ADVISORY]"), title: "Security advisory" },
  { matches: (line) => line.startsWith("[ERROR]"), title: "Startup error" },
  { matches: (line) => line.startsWith("[OPENCODE MAINTENANCE]"), title: "OpenCode maintenance" },
  { matches: (line) => line.startsWith("Pulse stalled"), title: "Pulse stalled" },
  { matches: (line) => /contribution(\(s\)|s)?\s+needs?/i.test(line), title: "External contribution review" },
  { matches: (line) => line.startsWith("[WARNING]") || line.startsWith("[WARN]"), title: "Startup warning" },
  { matches: (line) => line.startsWith("Security: all protections active"), title: "Security protections active" },
];

export function classifyToastLine(line: string): GuiNotificationSeverity | null {
  const normalized = line.trim();
  if (normalized.length === 0 || normalized.startsWith("UPDATE_AVAILABLE|") || normalized === "AUTO_UPDATE_ENABLED") {
    return null;
  }

  if (normalized.startsWith("[SECURITY ADVISORY]") || normalized.startsWith("[ERROR]")) {
    return "error";
  }

  if (warningLineMatchers.some((matches) => matches(normalized))) {
    return "warning";
  }

  if (normalized.startsWith("Security: all protections active")) {
    return "success";
  }

  return "info";
}

export function buildStatusNotifications(input: BuildNotificationInput): GuiNotificationSummary[] {
  const notifications = [
    ...buildToastNotifications(input.greetingOutput),
    ...buildGuiStateNotifications(input),
  ];

  return dedupeNotifications(notifications).sort((left, right) => {
    const severityDelta = toastSeverityRank[right.severity] - toastSeverityRank[left.severity];
    return severityDelta === 0 ? left.title.localeCompare(right.title) : severityDelta;
  });
}

function buildToastNotifications(greetingOutput: string): GuiNotificationSummary[] {
  return greetingOutput
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .flatMap((line) => {
      const severity = classifyToastLine(line);
      if (severity === null) {
        return [];
      }

      const category = categoryForToastLine(line, severity);
      return [notification({
        id: `toast-${stableId(line)}`,
        title: titleForToastLine(line, severity),
        message: line,
        severity,
        category,
        source: "opencode-toast",
        source_ref: "~/.aidevops/cache/session-greeting.txt",
        status: severity === "success" || severity === "info" ? "resolved" : "active",
        actions: actionsForToastLine(line, category, severity),
      })];
    });
}

function buildGuiStateNotifications(input: BuildNotificationInput): GuiNotificationSummary[] {
  const setupNeedsUpdate = (input.setupTargets ?? []).filter((target) => target.needs_update);
  const appNeedsUpdate = (input.aiApps ?? []).filter((app) => app.needs_update);
  const authErrors = (input.oauthPool?.providers ?? []).filter((provider) => provider.auth_errors > 0);
  const rateLimited = (input.oauthPool?.providers ?? []).filter((provider) => provider.rate_limited > 0);
	const oauthPoolSourceRef = input.oauthPool?.path_ref || "oauth_pool";
  const notifications: GuiNotificationSummary[] = [];

  if (input.restartRequired) {
    notifications.push(notification({
      id: "gui-restart-required",
      title: "Restart required",
      message: "aidevops has updated in the background. Restart the GUI app to use the latest installed version.",
      severity: "warning",
      category: "release",
      source: "gui-status",
      source_ref: "VERSION and ~/.aidevops/agents/VERSION",
      status: "active",
      actions: [surfaceAction("open-installation", "Open installation", "installation"), commandAction("restart-gui", "Restart GUI app", "Quit and reopen the aidevops GUI app")],
    }));
  }

  if (setupNeedsUpdate.length > 0 || appNeedsUpdate.length > 0) {
    notifications.push(notification({
      id: "gui-targets-need-update",
      title: "Installed targets need update",
      message: `${setupNeedsUpdate.length} setup target(s) and ${appNeedsUpdate.length} AI app target(s) need the current aidevops files.`,
      severity: "warning",
      category: "setup",
      source: "gui-status",
      source_ref: "setup_targets and ai_apps",
      status: "active",
      actions: [surfaceAction("open-installation", "Open installation", "installation"), commandAction("run-update", "Run update", "aidevops update")],
    }));
  }

  for (const provider of authErrors) {
    notifications.push(notification({
      id: `gui-provider-auth-${provider.provider}`,
      title: `${provider.provider} auth attention`,
      message: `${provider.auth_errors} ${provider.provider} account(s) report auth errors. Token values remain hidden from the GUI payload.`,
      severity: "error",
      category: "runtime",
      source: "gui-status",
      source_ref: oauthPoolSourceRef,
      status: "active",
      actions: [surfaceAction("open-ai-providers", "Open AI providers", "aiProviders"), commandAction("check-oauth-pool", "Check provider pool", `aidevops oauth-pool check ${provider.provider}`)],
    }));
  }

  for (const provider of rateLimited) {
    notifications.push(notification({
      id: `gui-provider-rate-limit-${provider.provider}`,
      title: `${provider.provider} rate limit`,
      message: `${provider.rate_limited} ${provider.provider} account(s) are cooling down. The pool should recover automatically when cooldowns expire.`,
      severity: "warning",
      category: "runtime",
      source: "gui-status",
      source_ref: oauthPoolSourceRef,
      status: "active",
      actions: [surfaceAction("open-ai-providers", "Open AI providers", "aiProviders")],
    }));
  }

  return notifications;
}

function notification(input: GuiNotificationSummary): GuiNotificationSummary {
  return input;
}

function titleForToastLine(line: string, severity: GuiNotificationSeverity): string {
  const rule = toastTitleRules.find((candidate) => candidate.matches(line));
  return rule?.title ?? (severity === "info" ? "Runtime status" : "aidevops status");
}

function categoryForToastLine(line: string, severity: GuiNotificationSeverity): GuiNotificationCategory {
  if (line.startsWith("[SECURITY ADVISORY]") || line.startsWith("Security:")) return "security";
  if (line.startsWith("[OPENCODE MAINTENANCE]") || line.startsWith("Pulse stalled")) return "maintenance";
  if (/update|version|running in/i.test(line)) return "release";
  if (severity === "warning") return "setup";
  return "runtime";
}

function actionsForToastLine(line: string, category: GuiNotificationCategory, severity: GuiNotificationSeverity): GuiNotificationAction[] {
  if (category === "security") {
    return [surfaceAction("open-security", "Open security", "security"), surfaceAction("open-vault", "Open Vault", "vault")];
  }

  if (line.startsWith("[OPENCODE MAINTENANCE]")) {
    return [surfaceAction("open-local-setup", "Open local setup", "localSetup"), commandAction("run-maintenance", "Run maintenance", "opencode-db-maintenance-helper.sh run")];
  }

  if (line.startsWith("Pulse stalled")) {
    return [surfaceAction("open-maintenance", "Open maintenance", "maintenance")];
  }

  if (severity === "warning") {
    return [surfaceAction("open-installation", "Open installation", "installation"), commandAction("run-update", "Run update", "aidevops update")];
  }

  return [surfaceAction("open-overview", "Open overview", "overview")];
}

function surfaceAction(id: string, label: string, surfaceId: string): GuiNotificationAction {
  return { id, label, kind: "surface", surface_id: surfaceId, enabled: true };
}

function commandAction(id: string, label: string, commandPreview: string): GuiNotificationAction {
  return { id, label, kind: "command", command_preview: commandPreview, enabled: false };
}

function stableId(value: string): string {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = ((hash << 5) - hash + value.charCodeAt(index)) | 0;
  }
  return Math.abs(hash).toString(36);
}

function dedupeNotifications(notifications: GuiNotificationSummary[]): GuiNotificationSummary[] {
  const byId = new Map<string, GuiNotificationSummary>();
  for (const item of notifications) {
    byId.set(item.id, item);
  }
  return [...byId.values()];
}
