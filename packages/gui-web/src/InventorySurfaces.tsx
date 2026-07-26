import type { GuiAppActionJobSummary, GuiManagedAppSummary, GuiResponseEnvelope, GuiStatusData } from "@aidevops/gui-shared";
import { type CSSProperties, type Dispatch, type FocusEvent as ReactFocusEvent, type PointerEvent as ReactPointerEvent, type ReactElement, type SetStateAction, useEffect, useState } from "react";
import { ManagedAppPanel } from "./ManagedAppPanel";
import { text } from "./app-model";
import { RecommendedAppsSurface, nextRecommendedFilterValue, recommendedAppMatchesFilters, recommendedApps, type RecommendedOsId, type RecommendedPlatformFilterId } from "./RecommendedAppsSurface";
import { useRunningJobRefresh } from "./useRunningJobRefresh";

export { EditableInventorySurface, InstallationSurface } from "./InventoryEditorSurfaces";
export { nextRecommendedFilterValue } from "./RecommendedAppsSurface";

export function AppsSurface({ status }: { status: GuiStatusData }): ReactElement {
  const [appCollection, setAppCollection] = useState<AppCollectionId>("aidevops");
  const [managedCategory, setManagedCategory] = useState<ManagedCategoryId>("core");
  const [recommendedPlatform, setRecommendedPlatform] = useState<RecommendedPlatformFilterId>("all");
  const [recommendedOs, setRecommendedOs] = useState<RecommendedOsId>("all");
  const [selectedJobId, setSelectedJobId] = useState<string | null>(null);
  const [expandedAppId, setExpandedAppId] = useState<string | null>(() => sortedManagedApps(status.managed_apps).find((app) => managedCategoryForApp(app) === "core")?.id ?? null);
  const [jobs, setJobs] = useState<Record<string, GuiAppActionJobSummary>>({});
  const [dismissedJobIds, setDismissedJobIds] = useState<Set<string>>(() => new Set());
  const [tooltip, setTooltip] = useState<AppTooltipState | null>(null);
  const [policyJobs, setPolicyJobs] = useState<Record<string, GuiAppActionJobSummary[]>>({});
  const [policyToggles, setPolicyToggles] = useState<ManagedPolicyToggleState>(() => readManagedPolicyToggles());
  const selectedJob = selectedJobId === null ? null : jobs[selectedJobId] ?? null;
  const managedApps = sortedManagedApps(status.managed_apps).map((app) => applyManagedPolicyToggles(app, policyToggles[app.id]));
  const visibleManagedApps = managedApps.filter((app) => managedCategoryForApp(app) === managedCategory);
  const firstVisibleManagedAppId = visibleManagedApps[0]?.id ?? null;
  const visibleRecommendedApps = recommendedApps.filter((app) => recommendedAppMatchesFilters(app, recommendedPlatform, recommendedOs));
  const selectRecommendedPlatform = (value: RecommendedPlatformFilterId) => setRecommendedPlatform((current) => nextRecommendedFilterValue(current, value, "all"));
  const selectRecommendedOs = (value: RecommendedOsId) => setRecommendedOs((current) => nextRecommendedFilterValue(current, value, "all"));

  useEffect(() => {
    setExpandedAppId(firstVisibleManagedAppId);
  }, [firstVisibleManagedAppId]);

  const runningJobIdsKey = Object.values(jobs).filter((job) => job.status === "running").map((job) => job.id).sort().join("|");
  useRunningJobRefresh(runningJobIdsKey, refreshJob, setJobs);

  return (
    <section className="apps-surface" aria-label={text.apps} onBlur={() => setTooltip(null)} onFocus={showFocusedAppTooltip(setTooltip)} onPointerLeave={() => setTooltip(null)} onPointerMove={showPointedAppTooltip(setTooltip)}>
      <div className="section-heading">
        <p className="eyebrow">{text.infrastructure}</p>
        <h2>{text.apps}</h2>
        <p>{text.appsIntro}</p>
      </div>
      <TabNav label="Apps collections" tabs={appCollectionTabs} value={appCollection} onChange={(value) => setAppCollection(value)} />
      {appCollection === "aidevops" ? <>
        <TabNav label="aidevops app groups" tabs={managedCategoryTabs} value={managedCategory} onChange={(value) => setManagedCategory(value)} />
        <div className="managed-app-list">
          {visibleManagedApps.map((app) => (
            <ManagedAppPanel
              app={app}
              expanded={expandedAppId === app.id}
              job={jobForApp(app.id, jobs, selectedJob)}
              key={app.id}
              dismissedJobIds={dismissedJobIds}
              policyJobs={policyJobs[app.id] ?? []}
              onDismissJob={(jobId) => setDismissedJobIds((current) => new Set([...current, jobId]))}
              onJob={(job) => {
                setDismissedJobIds((current) => {
                  const next = new Set(current);
                  next.delete(job.id);
                  return next;
                });
                setJobs((current) => ({ ...current, [job.id]: job }));
                setSelectedJobId(job.id);
                setExpandedAppId(app.id);
              }}
              onPolicyToggle={(policy, value) => {
                setPolicyToggles((current) => {
                  const next = { ...current, [app.id]: { ...current[app.id], [policy]: value } };
                  writeManagedPolicyToggles(next);
                  return next;
                });
                const policyJob = createPolicyJob(app.id, policy, value);
                setPolicyJobs((current) => ({ ...current, [app.id]: [...(current[app.id] ?? []), policyJob] }));
                setSelectedJobId(policyJob.id);
                setExpandedAppId(app.id);
              }}
              onToggle={() => setExpandedAppId((current) => current === app.id ? null : app.id)}
            />
          ))}
        </div>
        <p className="empty-state compact-notice">Install/update actions run as allowlisted background jobs and stream inside each app panel. xterm.js with a node-pty bridge is the right next step for full TUI apps such as OpenCode; this view starts with non-interactive command logs.</p>
      </> : <RecommendedAppsSurface apps={visibleRecommendedApps} os={recommendedOs} platform={recommendedPlatform} setOs={selectRecommendedOs} setPlatform={selectRecommendedPlatform} />}
      {tooltip === null ? null : <AppTooltip tooltip={tooltip} />}
    </section>
  );
}

async function refreshJob(jobId: string, setJobs: Dispatch<SetStateAction<Record<string, GuiAppActionJobSummary>>>): Promise<void> {
  const response = await fetch(`/api/apps/jobs/${encodeURIComponent(jobId)}`);
  if (!response.ok) {
    return;
  }
  const envelope = await response.json() as GuiResponseEnvelope<GuiAppActionJobSummary>;
  setJobs((current) => ({ ...current, [envelope.data.id]: envelope.data }));
}

function jobForApp(appId: string, jobs: Record<string, GuiAppActionJobSummary>, selectedJob: GuiAppActionJobSummary | null): GuiAppActionJobSummary | null {
  if (selectedJob?.app_id === appId) {
    return selectedJob;
  }

  let latestJob: GuiAppActionJobSummary | null = null;
  for (const job of Object.values(jobs)) {
    if (job.app_id === appId && (latestJob === null || job.started_at > latestJob.started_at)) {
      latestJob = job;
    }
  }

  return latestJob;
}

function sortedManagedApps(apps: GuiManagedAppSummary[]): GuiManagedAppSummary[] {
  return [...apps].sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: "base" }));
}

function managedCategoryForApp(app: GuiManagedAppSummary): ManagedCategoryId {
  const exactCategory = managedCategoryByExactName[app.category];
  return exactCategory ?? managedCategoryByKeyword(app);
}

function managedCategoryByKeyword(app: GuiManagedAppSummary): ManagedCategoryId {
  const loweredName = app.name.toLowerCase();
  const categoryRules: Array<{ matches: boolean; category: ManagedCategoryId }> = [
    { matches: app.category.includes("cli"), category: "cli" },
    { matches: app.category.includes("ai"), category: "ai" },
    { matches: loweredName.includes("terminal"), category: "terminal" },
  ];

  return categoryRules.find((rule) => rule.matches)?.category ?? "cli";
}

type AppCollectionId = "aidevops" | "recommended";
type ManagedCategoryId = "core" | "ai" | "cli" | "desktop" | "terminal";
type ManagedPolicyId = "setup" | "update";
type ManagedPolicyToggleState = Record<string, Partial<Record<ManagedPolicyId, boolean>>>;

interface TabOption<T extends string> {
  id: T;
  label: string;
}

const appCollectionTabs: TabOption<AppCollectionId>[] = [
  { id: "aidevops", label: "AIDevOps" },
  { id: "recommended", label: "Recommended" },
];

const managedCategoryByExactName: Record<string, ManagedCategoryId> = {
  automation: "core",
  core: "core",
  desktop: "desktop",
  editor: "desktop",
  safety: "core",
  terminal: "terminal",
};

const managedCategoryTabs: TabOption<ManagedCategoryId>[] = [
  { id: "core", label: "Core" },
  { id: "ai", label: "AI" },
  { id: "cli", label: "CLI" },
  { id: "desktop", label: "Desktop" },
  { id: "terminal", label: "Terminal" },
];

function TabNav<T extends string>({ label, onChange, tabs, value }: { label: string; onChange: (value: T) => void; tabs: TabOption<T>[]; value: T }): ReactElement {
  return <div aria-label={label} className="pill-tabs app-subnav" role="tablist">{tabs.map((tab) => <button aria-selected={value === tab.id} className={value === tab.id ? "active" : ""} key={tab.id} onClick={() => onChange(tab.id)} role="tab" type="button">{tab.label}</button>)}</div>;
}

function applyManagedPolicyToggles(app: GuiManagedAppSummary, policy: Partial<Record<ManagedPolicyId, boolean>> | undefined): GuiManagedAppSummary {
  if (policy === undefined) {
    return app;
  }

  return {
    ...app,
    aidevops_install: policy.setup ?? app.aidevops_install,
    aidevops_update: policy.update ?? app.aidevops_update,
  };
}

function createPolicyJob(appId: string, policy: ManagedPolicyId, value: boolean): GuiAppActionJobSummary {
  const mode = value ? "on" : "off";
  const command = `aidevops app policy set ${appId} --${policy === "setup" ? "setup-installs" : "update-maintains"} ${mode}`;
  const now = new Date().toISOString();

  return {
    id: `policy-${appId}-${policy}-${Date.now()}`,
    app_id: appId,
    action: "update",
    status: "completed",
    command_preview: command,
    started_at: now,
    finished_at: now,
    exit_code: 0,
    output: [
      `$ ${command}`,
      `Saved local aidevops.app policy override for ${appId}: ${policy}=${mode}.`,
      "Persistence: browser localStorage key aidevops-gui-managed-app-policy.",
    ],
  };
}

function readManagedPolicyToggles(): ManagedPolicyToggleState {
  if (typeof window === "undefined") {
    return {};
  }

  try {
    const raw = window.localStorage.getItem("aidevops-gui-managed-app-policy");
    return raw === null ? {} : JSON.parse(raw) as ManagedPolicyToggleState;
  } catch {
    return {};
  }
}

function writeManagedPolicyToggles(policy: ManagedPolicyToggleState): void {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.setItem("aidevops-gui-managed-app-policy", JSON.stringify(policy));
}

interface AppTooltipState {
  align: "start" | "center" | "end";
  text: string;
  x: number;
  y: number;
}

function showPointedAppTooltip(setTooltip: Dispatch<SetStateAction<AppTooltipState | null>>) {
  return (event: ReactPointerEvent<HTMLElement>) => {
    const target = tooltipTarget(event.target);
    setTooltip(target === null ? null : tooltipForElement(target));
  };
}

function showFocusedAppTooltip(setTooltip: Dispatch<SetStateAction<AppTooltipState | null>>) {
  return (event: ReactFocusEvent<HTMLElement>) => {
    const target = tooltipTarget(event.target);
    if (target !== null) {
      setTooltip(tooltipForElement(target));
    }
  };
}

function tooltipTarget(target: EventTarget): HTMLElement | null {
  return target instanceof HTMLElement ? target.closest<HTMLElement>("[data-tooltip]") : null;
}

function tooltipForElement(element: HTMLElement): AppTooltipState | null {
  const textValue = element.dataset.tooltip;
  if (textValue === undefined || textValue.length === 0) {
    return null;
  }

  const rect = element.getBoundingClientRect();
  const viewportWidth = document.documentElement.clientWidth || window.innerWidth;
  const edgeSafeWidth = 240;
  if (rect.left < edgeSafeWidth) {
    return { align: "start", text: textValue, x: rect.left, y: rect.top };
  }
  if (viewportWidth - rect.right < edgeSafeWidth) {
    return { align: "end", text: textValue, x: rect.right, y: rect.top };
  }

  return { align: "center", text: textValue, x: rect.left + (rect.width / 2), y: rect.top };
}

function AppTooltip({ tooltip }: { tooltip: AppTooltipState }): ReactElement {
  const style = {
    "--tooltip-x": `${tooltip.x}px`,
    "--tooltip-y": `${tooltip.y}px`,
  } as CSSProperties;

  return <div className={`app-global-tooltip ${tooltip.align}`} role="tooltip" style={style}>{tooltip.text}</div>;
}
