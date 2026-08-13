/* jshint esversion: 11 */
import type { GuiMachineSummary, GuiStatusData } from "@aidevops/gui-shared";
import { useEffect, useState, type ReactNode } from "react";
import type { IconType } from "react-icons";
import {
  FiActivity,
  FiBookmark,
  FiBox,
  FiBriefcase,
  FiCalendar,
  FiChevronLeft,
  FiChevronRight,
  FiClock,
  FiDownloadCloud,
  FiFileText,
  FiFolder,
  FiGitBranch,
  FiGlobe,
  FiGrid,
  FiHash,
  FiHardDrive,
  FiHelpCircle,
  FiLink,
  FiLink2,
  FiList,
  FiLock,
  FiMail,
  FiMessageSquare,
  FiMonitor,
  FiPackage,
  FiServer,
  FiSettings,
  FiShield,
  FiTerminal,
  FiUsers,
} from "react-icons/fi";
import type { ContrastPreference, ConversationMode, FontPreference, FontSizePreference, ShellMode, SidebarMode, SurfaceIconName, SurfaceId, SurfaceNavGroup, SurfaceNavItem, ThemePreference } from "./app-model";
import { dashboardNavItem, navGroups, sidebarModeForSurface, surfaceRecordCounts, text } from "./app-model";
import { SidebarFooter, wrappedOptionIndex } from "./AppearanceControls";
import { type VaultDialogIntent, VaultPadlock, vaultCollectionForSurface, vaultCollectionTooltip, vaultDialogIntentForStatus } from "./VaultBadges";

function AidevopsPromptIcon() {
  return (
    <svg className="brand-icon" viewBox="0 0 1024 1024" role="img" aria-label="AI DevOps prompt icon">
      <rect className="brand-icon-bg" x="88" y="88" width="848" height="848" rx="188" />
      <rect className="brand-icon-glow" x="88" y="88" width="848" height="848" rx="188" />
      <rect className="brand-icon-ring" x="116" y="116" width="792" height="792" rx="160" />
      <g transform="translate(512 522) scale(0.94) translate(-288 -256)">
        <path className="brand-icon-glyph" d="M9.4 86.6C-3.1 74.1-3.1 53.9 9.4 41.4s32.8-12.5 45.3 0l192 192c12.5 12.5 12.5 32.8 0 45.3l-192 192c-12.5 12.5-32.8 12.5-45.3 0s-12.5-32.8 0-45.3L178.7 256 9.4 86.6zM256 416H544c17.7 0 32 14.3 32 32s-14.3 32-32 32H256c-17.7 0-32-14.3-32-32s14.3-32 32-32z" />
      </g>
    </svg>
  );
}

export { hueFromInputValue } from "./AppearanceControls";

const surfaceIcons: Record<SurfaceIconName, IconType> = {
  activity: FiActivity,
  apps: FiBox,
  bookmark: FiBookmark,
  brand: FiBriefcase,
  calendar: FiCalendar,
  chain: FiLink2,
  clock: FiClock,
  device: FiMonitor,
  document: FiFileText,
  download: FiDownloadCloud,
  folder: FiFolder,
  git: FiGitBranch,
  globe: FiGlobe,
  grid: FiGrid,
  hardDrive: FiHardDrive,
  hash: FiHash,
  help: FiHelpCircle,
  link: FiLink,
  list: FiList,
  lock: FiLock,
  mail: FiMail,
  message: FiMessageSquare,
  note: FiMessageSquare,
  package: FiPackage,
  server: FiServer,
  settings: FiSettings,
  shield: FiShield,
  terminal: FiTerminal,
  users: FiUsers,
};

export function SurfaceGlyph({ icon }: { icon: SurfaceIconName }) {
  const Icon = surfaceIcons[icon];

  return <Icon aria-hidden="true" focusable="false" />;
}

export function MachineRail({ machine }: { machine?: GuiMachineSummary }) {
  const localIp = machine?.local_ips?.[0] ?? "127.0.0.1";
  const publicIp = machine?.public_ip ?? "public IP not configured";
  const username = machine?.username ?? "local";
  const initials = machine?.initials ?? "LM";
  const title = `${username}\n${localIp}\n${publicIp}`;

  return (
    <aside className="machine-rail" aria-label="aidevops machines and clients">
      <button className="machine-orb active" title={title} type="button">
        <span>{initials}</span>
      </button>
      <button className="client-folder-orb" title="Client groups planned" type="button">⌁</button>
    </aside>
  );
}

export function Sidebar({ activeSurface, accentHue, contrastPreference, conversationMode, fontPreference, fontSizePreference, onVaultRequest, selectedLocalRepoIndex, selectedSessionId, setAccentHue, setActiveSurface, setContrastPreference, setConversationMode, setFontPreference, setFontSizePreference, setSelectedLocalRepoIndex, setSelectedSessionId, setShellMode, setShowBorders, setShowNavCounts, setThemePreference, shellMode, showBorders, showNavCounts, status, themePreference }: {
  activeSurface: SurfaceId;
  accentHue: number;
  contrastPreference: ContrastPreference;
  conversationMode: ConversationMode;
  fontPreference: FontPreference;
  fontSizePreference: FontSizePreference;
  onVaultRequest: (intent: VaultDialogIntent) => void;
  selectedLocalRepoIndex: number;
  selectedSessionId: string | undefined;
  setAccentHue: (hue: number) => void;
  setActiveSurface: (surface: SurfaceId) => void;
  setContrastPreference: (contrast: ContrastPreference) => void;
  setConversationMode: (mode: ConversationMode) => void;
  setFontPreference: (font: FontPreference) => void;
  setFontSizePreference: (size: FontSizePreference) => void;
  setSelectedLocalRepoIndex: (index: number) => void;
  setSelectedSessionId: (id: string | undefined) => void;
  setShellMode: (mode: ShellMode) => void;
  setShowBorders: (show: boolean) => void;
  setShowNavCounts: (show: boolean) => void;
  setThemePreference: (theme: ThemePreference) => void;
  shellMode: ShellMode;
  showBorders: boolean;
  showNavCounts: boolean;
  status: GuiStatusData;
  themePreference: ThemePreference;
}) {
  const [sidebarMode, setSidebarMode] = useState<SidebarMode>(() => sidebarModeForSurface(activeSurface));
  const visibleGroups = navGroups.filter((group) => group.mode === sidebarMode);
  const recordCounts = surfaceRecordCounts(status);

  useEffect(() => {
    setSidebarMode(sidebarModeForSurface(activeSurface));
  }, [activeSurface]);

  return (
    <aside className="app-sidebar" aria-label={text.navigationLabel}>
      <SidebarHeader setActiveSurface={setActiveSurface} setShellMode={setShellMode} shellMode={shellMode} />
      <nav className="sidebar-content">
        {shellMode === "devices" ? <>
          <SidebarModeTabs mode={sidebarMode} setMode={(mode) => setSidebarMode(mode as SidebarMode)} />
          <ul className="sidebar-top-link">
            <SidebarItem activeSurface={activeSurface} item={dashboardNavItem} onVaultRequest={onVaultRequest} setActiveSurface={setActiveSurface} showCount={false} status={status} />
          </ul>
          {visibleGroups.map((group) => <SidebarGroup activeSurface={activeSurface} group={group} key={group.label} onVaultRequest={onVaultRequest} recordCounts={recordCounts} setActiveSurface={setActiveSurface} showNavCounts={showNavCounts} status={status} />)}
        </> : <ConversationSidebar
          conversationMode={conversationMode}
          selectedLocalRepoIndex={selectedLocalRepoIndex}
          selectedSessionId={selectedSessionId}
          setConversationMode={setConversationMode}
          setSelectedLocalRepoIndex={setSelectedLocalRepoIndex}
          setSelectedSessionId={setSelectedSessionId}
          status={status}
        />}
      </nav>
      <SidebarFooter
        accentHue={accentHue}
        contrastPreference={contrastPreference}
        fontPreference={fontPreference}
        fontSizePreference={fontSizePreference}
        setAccentHue={setAccentHue}
        setContrastPreference={setContrastPreference}
        setFontPreference={setFontPreference}
        setFontSizePreference={setFontSizePreference}
        setShowBorders={setShowBorders}
        setShowNavCounts={setShowNavCounts}
        setThemePreference={setThemePreference}
        showBorders={showBorders}
        showNavCounts={showNavCounts}
        themePreference={themePreference}
      />
    </aside>
  );
}

function IconSwitch<TValue extends string>({ ariaLabel, options, value }: {
  ariaLabel: string;
  options: Array<{ icon: ReactNode; label: string; onSelect: () => void; value: TValue }>;
  value: TValue;
}) {
  return (
    <div className="icon-switch" role="tablist" aria-label={ariaLabel}>
      {options.map((option) => (
        <button
          aria-label={option.label}
          aria-selected={value === option.value}
          className={value === option.value ? "active" : ""}
          key={option.value}
          onClick={option.onSelect}
          role="tab"
          title={option.label}
          type="button"
        >
          {option.icon}
          <span>{option.label}</span>
        </button>
      ))}
    </div>
  );
}

function LocalRepoSelector({ repos, selectedLocalRepoIndex, selectRepoByIndex, setSelectedLocalRepoIndex, setSelectedSessionId }: {
  repos: GuiStatusData["local_repos"]["repos"];
  selectedLocalRepoIndex: number;
  selectRepoByIndex: (index: number) => void;
  setSelectedLocalRepoIndex: (index: number) => void;
  setSelectedSessionId: (id: string | undefined) => void;
}) {
  return (
    <section className="repo-session-selector" aria-label={text.localRepoSelector}>
      <span className="repo-selector-heading" id="local-repo-selector-label">{text.localRepos}</span>
      <div className="selector-with-stepper repo-selector-row">
        <button aria-label="Previous local repo" className="selector-step-button" disabled={repos.length === 0} onClick={() => selectRepoByIndex(wrappedOptionIndex(selectedLocalRepoIndex, repos.length, -1))} type="button"><FiChevronLeft aria-hidden="true" /></button>
        <select aria-labelledby="local-repo-selector-label" onChange={(event) => { setSelectedLocalRepoIndex(Number.parseInt(event.currentTarget.value, 10)); setSelectedSessionId(undefined); }} value={Math.min(selectedLocalRepoIndex, Math.max(0, repos.length - 1))}>
          {repos.length === 0 ? <option value={0}>No local repos</option> : repos.map((repo, index) => <option key={repo.path_ref} value={index}>{repo.name}</option>)}
        </select>
        <button aria-label="Next local repo" className="selector-step-button" disabled={repos.length === 0} onClick={() => selectRepoByIndex(wrappedOptionIndex(selectedLocalRepoIndex, repos.length, 1))} type="button"><FiChevronRight aria-hidden="true" /></button>
      </div>
    </section>
  );
}

function SessionHistoryList({ activeSessionId, selectedRepo, sessions, setSelectedSessionId }: {
  activeSessionId: string | undefined;
  selectedRepo: GuiStatusData["local_repos"]["repos"][number] | undefined;
  sessions: GuiStatusData["opencode_sessions"]["sessions"];
  setSelectedSessionId: (id: string | undefined) => void;
}) {
  return (
    <section className="sidebar-group session-history-list">
      {selectedRepo ? <ul>
        {sessions.length === 0
          ? <li><button className="surface-link active" type="button"><span className="surface-icon" aria-hidden="true"><FiHash /></span><span className="surface-copy"><strong>{selectedRepo.name}</strong><small>No OpenCode sessions found for this repo yet.</small></span><em>{text.planned}</em></button></li>
          : sessions.map((session) => <li key={session.id_ref}><button className={activeSessionId === session.id_ref ? "surface-link active" : "surface-link"} onClick={() => setSelectedSessionId(session.id_ref)} type="button"><span className="surface-icon" aria-hidden="true"><FiHash /></span><span className="surface-copy"><strong>{session.title}</strong><small>{session.updated_at}</small></span></button></li>)}
      </ul> : <p className="empty-sidebar-state">No local repos discovered.</p>}
    </section>
  );
}

function ConversationSidebar({ conversationMode, selectedLocalRepoIndex, selectedSessionId, setConversationMode, setSelectedLocalRepoIndex, setSelectedSessionId, status }: {
  conversationMode: ConversationMode;
  selectedLocalRepoIndex: number;
  selectedSessionId: string | undefined;
  setConversationMode: (mode: ConversationMode) => void;
  setSelectedLocalRepoIndex: (index: number) => void;
  setSelectedSessionId: (id: string | undefined) => void;
  status: GuiStatusData;
}) {
  const repos = status.local_repos.repos;
  const selectedRepo = repos[selectedLocalRepoIndex] ?? repos[0];
  const sessions = selectedRepo === undefined
    ? []
    : status.opencode_sessions.sessions.filter((session) => session.repo_path_ref === selectedRepo.path_ref);
  const activeSessionId = sessions.some((session) => session.id_ref === selectedSessionId) ? selectedSessionId : sessions[0]?.id_ref;
  useEffect(() => {
    if (activeSessionId !== selectedSessionId) {
      setSelectedSessionId(activeSessionId);
    }
  }, [activeSessionId, selectedSessionId, setSelectedSessionId]);
  const selectRepoByIndex = (index: number) => {
    if (repos.length === 0) {
      return;
    }

    setSelectedLocalRepoIndex(index);
    setSelectedSessionId(undefined);
  };

  return (
    <section className="conversation-panel" aria-label={text.opencodeSessions}>
      <SidebarModeTabs mode={conversationMode} setMode={setConversationMode} />
      {conversationMode === "people" ? <PeopleChannelList /> : <>
      <button className="new-session-button" disabled title="Creating sessions needs an audited OpenCode write route." type="button">{text.newSession}</button>
      <LocalRepoSelector repos={repos} selectedLocalRepoIndex={selectedLocalRepoIndex} selectRepoByIndex={selectRepoByIndex} setSelectedLocalRepoIndex={setSelectedLocalRepoIndex} setSelectedSessionId={setSelectedSessionId} />
      <SessionHistoryList activeSessionId={activeSessionId} selectedRepo={selectedRepo} sessions={sessions} setSelectedSessionId={setSelectedSessionId} />
      </>}
    </section>
  );
}

function PeopleChannelList() {
  return (
    <section aria-label="People channels">
      <div className="notice compact-notice">{text.simplexReady}</div>
      <section className="sidebar-group session-history-list">
        <ul>
          {["aidevops", "clients", "ops"].map((team) => <li key={team}><button className="surface-link" type="button"><span className="surface-icon" aria-hidden="true"><FiHash /></span><span className="surface-copy"><strong>{team}</strong><small>SimpleX team channel placeholder</small></span></button></li>)}
        </ul>
      </section>
      <section className="sidebar-group session-history-list">
        <ul>
          {["Marcus", "AI DevOps"].map((person) => <li key={person}><button className="surface-link" type="button"><span className="surface-icon" aria-hidden="true"><FiMessageSquare /></span><span className="surface-copy"><strong>{person}</strong><small>encrypted DM placeholder</small></span></button></li>)}
        </ul>
      </section>
    </section>
  );
}

function SidebarModeTabs<TMode extends SidebarMode | ConversationMode>({ mode, setMode }: {
  mode: TMode;
  setMode: (mode: TMode) => void;
}) {
  const modes = (mode === "ai" || mode === "people"
    ? [{ label: text.ai, value: "ai" }, { label: text.people, value: "people" }]
    : [{ label: text.devops, value: "devops" }, { label: text.comms, value: "comms" }]) as Array<{ label: string; value: TMode }>;

  return (
    <div className="sidebar-mode-tabs" role="tablist" aria-label="Sidebar sections">
      {modes.map((entry) => (
        <button
          aria-selected={mode === entry.value}
          className={mode === entry.value ? "active" : ""}
          key={entry.value}
          onClick={() => setMode(entry.value)}
          role="tab"
          type="button"
        >
          {entry.label}
        </button>
      ))}
    </div>
  );
}

function SidebarGroup({ activeSurface, group, onVaultRequest, recordCounts, setActiveSurface, showNavCounts, status }: {
  activeSurface: SurfaceId;
  group: SurfaceNavGroup;
  onVaultRequest: (intent: VaultDialogIntent) => void;
  recordCounts: Partial<Record<SurfaceId, number>>;
  setActiveSurface: (surface: SurfaceId) => void;
  showNavCounts: boolean;
  status: GuiStatusData;
}) {
  return (
    <section className="sidebar-group">
      <h2>{group.label}</h2>
      <ul>
        {group.items.map((item) => <SidebarItem activeSurface={activeSurface} item={item} key={item.id} onVaultRequest={onVaultRequest} recordCount={recordCounts[item.id]} setActiveSurface={setActiveSurface} showCount={showNavCounts} status={status} />)}
      </ul>
    </section>
  );
}

function SidebarItem({ activeSurface, item, onVaultRequest, recordCount, setActiveSurface, showCount, status }: {
  activeSurface: SurfaceId;
  item: SurfaceNavItem;
  onVaultRequest: (intent: VaultDialogIntent) => void;
  recordCount?: number;
  setActiveSurface: (surface: SurfaceId) => void;
  showCount: boolean;
  status: GuiStatusData;
}) {
  const isActive = activeSurface === item.id;
  const vaultCollection = vaultCollectionForSurface(status.vault, item.id);
  const vaultTooltip = vaultCollection ? ` ${vaultCollectionTooltip(vaultCollection)}` : "";
  const tooltip = `${item.label}: ${item.description}${vaultTooltip}`;
  const shouldShowCount = showCount && recordCount !== undefined && recordCount > 0;

  return (
    <li>
      <button
        aria-label={tooltip}
        aria-current={isActive ? "page" : undefined}
        className={isActive ? "surface-link active" : "surface-link"}
        onClick={(event) => {
          if (vaultCollection && event.target instanceof HTMLElement && event.target.closest(".vault-padlock")) {
            onVaultRequest(vaultDialogIntentForStatus(status.vault));
            return;
          }

          setActiveSurface(item.id);
        }}
        title={tooltip}
        type="button"
      >
        <span className="surface-icon" aria-hidden="true"><SurfaceGlyph icon={item.icon} /></span>
        <span className="surface-copy">
          <span className="surface-title-row">
            <strong>{item.label}</strong>
            {shouldShowCount ? <span className="surface-count">({recordCount})</span> : null}
          </span>
        </span>
        {item.badge ? <em>{item.badge}</em> : null}
        {vaultCollection ? <VaultPadlock collection={vaultCollection} compact vault={status.vault} /> : null}
      </button>
    </li>
  );
}

function SidebarHeader({ setActiveSurface, setShellMode, shellMode }: {
  setActiveSurface: (surface: SurfaceId) => void;
  setShellMode: (mode: ShellMode) => void;
  shellMode: ShellMode;
}) {
  return (
    <header className="sidebar-header">
      <div className="sidebar-titlebar">
        <button className="brand-lockup" onClick={() => { setShellMode("devices"); setActiveSurface(dashboardNavItem.id); }} title="Return to dashboard" type="button">
          <AidevopsPromptIcon />
          <strong>{text.aidevops}</strong>
        </button>
        <IconSwitch
          ariaLabel="Navigation scope"
          options={[
            { icon: <FiMonitor aria-hidden="true" />, label: text.devices, onSelect: () => setShellMode("devices"), value: "devices" },
            { icon: <FiHash aria-hidden="true" />, label: text.opencodeSessions, onSelect: () => setShellMode("sessions"), value: "sessions" },
          ]}
          value={shellMode}
        />
      </div>
    </header>
  );
}
