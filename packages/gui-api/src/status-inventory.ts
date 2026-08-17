import { spawnSync } from "node:child_process";
import { lstatSync } from "node:fs";
import { join } from "node:path";
import type { GuiSecretReference, GuiVaultStatusData } from "../../gui-shared/src";
import { readVaultSummary } from "./status-vault";

type BackendState = "available" | "missing" | "error";
type SecretInventory = {
  version: 1;
  backends: { gopass: BackendState; credentials: BackendState };
  secrets: GuiSecretReference[];
};

const EMPTY_INVENTORY: Omit<SecretInventory, "version"> = {
  backends: { gopass: "missing", credentials: "missing" },
  secrets: [],
};
const BACKEND_STATES = new Set<unknown>(["available", "missing", "error"]);

export function readSecretInventory(repoRoot: string, vault: GuiVaultStatusData): Omit<SecretInventory, "version"> {
  if (!isAuthoritativelyUnlocked(vault)) return EMPTY_INVENTORY;
  const helperPath = join(repoRoot, ".agents", "scripts", "secret-helper.sh");
  if (!isTrustedHelper(helperPath)) return EMPTY_INVENTORY;
  const result = spawnSync("/bin/bash", [helperPath, "inventory"], {
    encoding: "utf8",
    env: inventoryEnvironment(),
    maxBuffer: 65_536,
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 300,
  });
  if (result.error !== undefined || result.signal !== null || result.status !== 0 || result.stdout.length > 65_535) return EMPTY_INVENTORY;
  return parseUnlockedInventory(result.stdout, repoRoot);
}

function parseUnlockedInventory(output: string, repoRoot: string): Omit<SecretInventory, "version"> {
  try {
    const inventory: unknown = JSON.parse(output);
    const confirmed = readVaultSummary(repoRoot);
    return isInventory(inventory) && isAuthoritativelyUnlocked(confirmed)
      ? { backends: inventory.backends, secrets: inventory.secrets }
      : EMPTY_INVENTORY;
  } catch {
    return EMPTY_INVENTORY;
  }
}

function isAuthoritativelyUnlocked(vault: GuiVaultStatusData): boolean {
  return vault.status === "unlocked" && vault.unlocked && !vault.locked && vault.helper_status === "available";
}

function isTrustedHelper(path: string): boolean {
  try {
    const stat = lstatSync(path);
    return stat.isFile() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o022) === 0;
  } catch {
    return false;
  }
}

function isInventory(value: unknown): value is SecretInventory {
	if (!isRecord(value) || value.version !== 1 || !Array.isArray(value.secrets) || value.secrets.length > 512) return false;
	if (!isRecord(value.backends) || Object.keys(value).length !== 3 || Object.keys(value.backends).length !== 2) return false;
	if (!BACKEND_STATES.has(value.backends.gopass) || !BACKEND_STATES.has(value.backends.credentials)) return false;
	const secrets = value.secrets;
	return secrets.every((secret, index) => isSecretReference(secret, index === 0 ? "" : secrets[index - 1]?.name));
}

function isSecretReference(value: unknown, previousName: string | undefined): value is GuiSecretReference {
  if (!isRecord(value) || typeof value.name !== "string") return false;
  return /^[A-Z][A-Z0-9_]{0,127}$/.test(value.name)
    && value.status === "configured"
    && value.name > (previousName ?? "")
    && Object.keys(value).every((key) => key === "name" || key === "status");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function inventoryEnvironment(): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = { PATH: "/usr/bin:/bin:/usr/sbin:/sbin" };
  for (const name of ["HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "AIDEVOPS_VAULT_DIR", "AIDEVOPS_VAULT_RUNTIME_DIR", "AIDEVOPS_VAULT_PYTHON"]) {
    const value = process.env[name];
    if (value !== undefined) environment[name] = value;
  }
  return environment;
}
