/**
 * SimpleX Bot Framework — Type Definitions
 *
 * Types for the SimpleX WebSocket JSON API, bot commands, events,
 * and the channel-agnostic gateway architecture.
 *
 * Reference: https://github.com/simplex-chat/simplex-chat/tree/stable/bots/api
 */

// =============================================================================
// WebSocket API Types
// =============================================================================

/** Command sent to SimpleX CLI via WebSocket */
export interface SimplexCommand {
  corrId: string;
  cmd: string;
}

/** Response from SimpleX CLI via WebSocket */
export interface SimplexResponse {
  corrId?: string;
  resp: SimplexEvent;
}

/** Base event type from SimpleX CLI */
export interface SimplexEvent {
  type: string;
  [key: string]: unknown;
}

// =============================================================================
// Chat Item Types
// =============================================================================

/** Message content types */
export type MessageContentType =
  | "text"
  | "link"
  | "image"
  | "video"
  | "voice"
  | "file";

/** Message content from SimpleX */
export interface MessageContent {
  type: MessageContentType;
  text?: string;
  fileName?: string;
  fileSize?: number;
  filePath?: string;
}

/** Chat item content wrapper */
export interface ChatItemContent {
  type: "rcvMsgContent" | "sndMsgContent";
  msgContent: MessageContent;
}

/** A single chat item (message) */
export interface ChatItem {
  chatItem: {
    content: ChatItemContent;
    chatDir?: {
      type: string;
      contactId?: number;
      groupId?: number;
      /** Contact info attached by SimpleX API (used for display name caching) */
      contact?: { localDisplayName?: string };
      /** Group info attached by SimpleX API (used for display name caching) */
      groupInfo?: { localDisplayName?: string };
    };
    meta?: {
      itemId: number;
      itemTs: string;
      createdAt: string;
    };
  };
}

/** New chat items event */
export interface NewChatItemsEvent extends SimplexEvent {
  type: "newChatItems";
  chatItems: ChatItem[];
}

/** Contact connected event */
export interface ContactConnectedEvent extends SimplexEvent {
  type: "contactConnected";
  contact: ContactInfo;
}

/** Contact request event (when auto-accept is off) */
export interface ContactRequestEvent extends SimplexEvent {
  type: "receivedContactRequest";
  contactRequest: {
    contactRequestId: number;
    localDisplayName: string;
    profile: {
      displayName: string;
      fullName?: string;
    };
  };
}

/** Business address request event (per-customer group chat) */
export interface BusinessRequestEvent extends SimplexEvent {
  type: "acceptingBusinessRequest";
  groupInfo: GroupInfo;
}

/** Group invitation event */
export interface GroupInvitationEvent extends SimplexEvent {
  type: "receivedGroupInvitation";
  groupInfo: GroupInfo;
}

/** Group member event (join, leave, connect) */
export interface GroupMemberEvent extends SimplexEvent {
  type: "joinedGroupMember" | "deletedMemberUser" | "memberConnected";
  groupInfo: GroupInfo;
  member: {
    groupMemberId: number;
    localDisplayName: string;
    memberRole: string;
  };
}

/** File event (ready, complete) */
export interface FileEvent extends SimplexEvent {
  type: "rcvFileDescrReady" | "rcvFileComplete";
  fileId: number;
  fileName?: string;
  fileSize?: number;
  filePath?: string;
}

/** Contact info */
export interface ContactInfo {
  contactId: number;
  localDisplayName: string;
  profile: {
    displayName: string;
    fullName?: string;
    image?: string;
    contactLink?: string;
    preferences?: Record<string, unknown>;
  };
}

/** Group info */
export interface GroupInfo {
  groupId: number;
  localDisplayName: string;
  groupProfile: {
    displayName: string;
    fullName?: string;
    description?: string;
    image?: string;
  };
}

// =============================================================================
// Bot Command Types
// =============================================================================

/** Bot command handler function */
export type CommandHandler = (
  ctx: CommandContext,
) => Promise<string | undefined>;

/** Context passed to command handlers */
export interface CommandContext {
  /** The raw command string (e.g., "/status") */
  command: string;
  /** Arguments after the command */
  args: string[];
  /** Full raw text of the message */
  rawText: string;
  /** Contact who sent the message (if DM) */
  contact?: ContactInfo;
  /** Group the message was sent in (if group) */
  group?: GroupInfo;
  /** The chat item that triggered this command */
  chatItem: ChatItem;
  /**
   * Session ID for this chat context (e.g., "direct:42" or "group:7").
   * Sourced directly from SessionStore to avoid duplicating the ID format.
   */
  sessionId?: string;
  /** Send a reply to the sender */
  reply: (text: string) => Promise<void>;
}

/** Registered command definition */
export interface CommandDefinition {
  /** Command name without slash (e.g., "help") */
  name: string;
  /** Short description for help menu */
  description: string;
  /** Handler function */
  handler: CommandHandler;
  /** Whether this command is available in groups */
  groupEnabled: boolean;
  /** Whether this command is available in DMs */
  dmEnabled: boolean;
}

// =============================================================================
// Leak Detection Types
// =============================================================================

/** Named leak pattern identifiers */
export type LeakPatternName =
  | "aws_access_key"
  | "aws_secret_key"
  | "github_token"
  | "github_fine_grained"
  | "gitlab_token"
  | "slack_token"
  | "discord_token"
  | "generic_api_key"
  | "bearer_token"
  | "jwt"
  | "database_url"
  | "private_ip"
  | "file_path"
  | "private_key"
  | "password_in_url"
  | "high_entropy";

/** A single leak match found by the scanner */
export interface LeakMatch {
  /** Which pattern matched */
  patternName: LeakPatternName;
  /** Human-readable description of the pattern */
  description: string;
  /** The actual text that matched (for redaction) */
  matchedText: string;
  /** Character index in the scanned text */
  index: number;
  /** Shannon entropy of the matched text */
  entropy: number;
}

/** Result of scanning text for leaks */
export interface LeakDetectionResult {
  /** Whether any leaks were detected */
  hasLeaks: boolean;
  /** All matches found */
  matches: LeakMatch[];
  /** Length of the scanned text */
  scannedLength: number;
}

/** Leak detection configuration */
export interface LeakDetectionConfig {
  /** Enable outbound leak detection (default: true) */
  enabled: boolean;
  /** Shannon entropy threshold for high-entropy token detection (default: 4.0) */
  entropyThreshold: number;
  /** Minimum token length for entropy analysis (default: 20) */
  minTokenLength: number;
}

/** Default leak detection configuration */
export const DEFAULT_LEAK_DETECTION_CONFIG: LeakDetectionConfig = {
  enabled: true,
  entropyThreshold: 4.0,
  minTokenLength: 20,
};

// =============================================================================
// Exec Approval Types
// =============================================================================

/** Classification for how a command should be handled by the approval system */
export type ExecClassification = "allowed" | "approval-required" | "blocked";

/** Configuration for the exec approval flow */
export interface ExecApprovalConfig {
  /** Commands that execute immediately without approval (e.g., "aidevops status") */
  allowlist: string[];
  /** Commands that are always rejected (e.g., "rm -rf", "shutdown") */
  blocklist: string[];
  /** Timeout in ms before a pending approval is auto-rejected (default: 12 hours) */
  approvalTimeoutMs: number;
  /** Whether to require approval for commands not in allowlist or blocklist (default: true) */
  requireApprovalByDefault: boolean;
}

/** Default exec approval configuration */
export const DEFAULT_EXEC_APPROVAL_CONFIG: ExecApprovalConfig = {
  allowlist: [
    "aidevops status",
    "aidevops repos",
    "aidevops features",
  ],
  blocklist: [
    "rm -rf",
    "shutdown",
    "reboot",
    "mkfs",
    "dd if=",
    "> /dev/",
    ":(){ :|:& };:",
  ],
  approvalTimeoutMs: 12 * 60 * 60 * 1000,
  requireApprovalByDefault: true,
};

/** State of a pending approval request */
export type ApprovalState = "pending" | "approved" | "rejected" | "expired";

/** A pending command execution awaiting approval */
export interface PendingApproval {
  /** Short unique ID for the approval (e.g., "a3f7") */
  id: string;
  /** The command string to execute */
  command: string;
  /** Contact ID of the requester */
  contactId: number;
  /** Display name of the requester */
  contactName: string;
  /** When the request was created */
  createdAt: number;
  /** Current state */
  state: ApprovalState;
  /** Reply function bound to the original chat context */
  reply: (text: string) => Promise<void>;
}

// =============================================================================
// Bot Configuration
// =============================================================================

/** Bot configuration */
export interface BotConfig {
  /** WebSocket port for SimpleX CLI (default: 5225) */
  port: number;
  /** WebSocket host (default: 127.0.0.1) */
  host: string;
  /** Bot display name */
  displayName: string;
  /** Auto-accept contact requests */
  autoAcceptContacts: boolean;
  /** Welcome message for new contacts */
  welcomeMessage?: string;
  /** Log level */
  logLevel: "debug" | "info" | "warn" | "error";
  /** Reconnect interval in ms (default: 5000) */
  reconnectInterval: number;
  /** Maximum reconnect attempts (default: 10, 0 = infinite) */
  maxReconnectAttempts: number;
  /** Enable TLS for WebSocket connection (default: false — local CLI uses plain WebSocket) */
  useTls: boolean;
  /** Outbound leak detection configuration */
  leakDetection: LeakDetectionConfig;
  /** Exec approval flow configuration */
  execApproval: ExecApprovalConfig;
  /** Enable business address mode (per-customer group chats) */
  businessAddress: boolean;
  /** Auto-accept incoming files */
  autoAcceptFiles: boolean;
  /** Maximum file size to auto-accept in bytes (default: 50MB) */
  maxFileSize: number;
  /** Auto-join group invitations */
  autoJoinGroups: boolean;
  /** Session idle timeout in seconds (default: 300, used as fallback when AI judgment unavailable) */
  sessionIdleTimeout: number;
  /**
   * Enable AI-judged thresholds (t1363.6).
   * When true, replaces fixed sessionIdleTimeout with AI judgment via
   * conversation-helper.sh idle-check, and uses entity-preference-aware
   * response sizing instead of fixed maxPromptLength.
   * Falls back to deterministic thresholds when AI is unavailable.
   * Default: auto-detected (true if ai-research-helper.sh exists)
   */
  useIntelligentThresholds?: boolean;
  /** Data directory for bot state (default: ~/.aidevops/.agent-workspace/simplex-bot) */
  dataDir?: string;
}

/** Default bot configuration */
export const DEFAULT_BOT_CONFIG: BotConfig = {
  port: 5225,
  host: "127.0.0.1",
  displayName: "AIBot",
  autoAcceptContacts: false,
  welcomeMessage: "Hello! I'm an aidevops bot. Type /help for available commands.",
  logLevel: "info",
  reconnectInterval: 5000,
  maxReconnectAttempts: 10,
  useTls: false,
  leakDetection: DEFAULT_LEAK_DETECTION_CONFIG,
  execApproval: DEFAULT_EXEC_APPROVAL_CONFIG,
  businessAddress: false,
  autoAcceptFiles: false,
  maxFileSize: 50 * 1024 * 1024,
  autoJoinGroups: false,
  sessionIdleTimeout: 300,
};

// =============================================================================
// Channel-Agnostic Gateway Types
// =============================================================================

/** Channel adapter interface — SimpleX is the first adapter */
export interface ChannelAdapter {
  /** Unique name for this channel */
  name: string;
  /** Connect to the channel */
  connect(): Promise<void>;
  /** Disconnect from the channel */
  disconnect(): Promise<void>;
  /** Send a message to a target */
  send(target: string, message: string): Promise<void>;
  /** Whether the adapter is connected */
  isConnected(): boolean;
}

/** Gateway event types */
export type GatewayEventType =
  | "message"
  | "command"
  | "connect"
  | "disconnect"
  | "error";

/** Gateway event */
export interface GatewayEvent {
  type: GatewayEventType;
  channel: string;
  timestamp: Date;
  data: unknown;
}
