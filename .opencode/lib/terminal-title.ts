// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Terminal title helpers for OpenCode tools.
//
// The shell-side terminal-title-helper.sh updates Tabby/iTerm/etc. when a
// normal shell hook runs. OpenCode session-rename tools bypass that shell hook
// and write the session title directly to SQLite, so they must emit OSC 0
// themselves to keep the terminal/tab title in sync.

import { closeSync, openSync, writeSync } from "node:fs"

const OSC_TITLE_PREFIX = "\u001B]0;"
const OSC_TITLE_SUFFIX = "\u0007"
const TERMINAL_TITLE_CONTROLLER_SYMBOL = Symbol.for("aidevops.terminal-title-controller.v1")

type TerminalTitleEnv = Record<string, string | undefined>
type SharedTerminalTitleController = { emit: (title: string) => boolean }

// biome-ignore lint/complexity/useRegexLiterals: regex literals trigger noControlCharactersInRegex for this C0/DEL sanitizer range.
const CONTROL_CHARACTERS_PATTERN = new RegExp("[\\x00-\\x1F\\x7F]+", "g")

/**
 * Honour the same opt-out environment variables as terminal-title-helper.sh.
 */
export function isTerminalTitleEnabled(env: TerminalTitleEnv = process.env): boolean {
  return (
    env.AIDEVOPS_TERMINAL_TITLE_OWNER !== "native" &&
    env.TERMINAL_TITLE_ENABLED !== "false" &&
    env.AIDEVOPS_TABBY_ENABLED !== "false"
  )
}

/**
 * Remove C0 control characters so arbitrary LLM/session titles cannot inject
 * extra terminal control sequences into the OSC payload.
 */
export function sanitizeTerminalTitle(title: string): string {
  return title.replace(CONTROL_CHARACTERS_PATTERN, " ").trim()
}

/**
 * Build an OSC 0 title sequence for terminals such as Tabby.
 */
export function terminalTitleSequence(title: string): string {
  const sanitizedTitle = sanitizeTerminalTitle(title)
  if (!sanitizedTitle) {
    return ""
  }
  return `${OSC_TITLE_PREFIX}${sanitizedTitle}${OSC_TITLE_SUFFIX}`
}

function sharedTerminalTitleController(): SharedTerminalTitleController | undefined {
  const controller = Reflect.get(globalThis, TERMINAL_TITLE_CONTROLLER_SYMBOL) as
    | Partial<SharedTerminalTitleController>
    | undefined
  if (typeof controller?.emit !== "function") {
    return undefined
  }
  return controller as SharedTerminalTitleController
}

function writeTerminalTitleSequence(sequence: string): boolean {
  try {
    const fd = openSync("/dev/tty", "w")
    try {
      writeSync(fd, sequence)
      return true
    } finally {
      closeSync(fd)
    }
  } catch {
    try {
      return process.stderr.write(sequence)
    } catch {
      return false
    }
  }
}

/**
 * Best-effort terminal title update. Prefer /dev/tty so the sequence reaches
 * the controlling terminal even if a tool framework captures stdout; fall back
 * to stderr for runtimes where /dev/tty is unavailable so tool return payloads
 * are not polluted with terminal control sequences.
 */
export function emitTerminalTitle(title: string): boolean {
  if (!isTerminalTitleEnabled()) {
    return false
  }

  const sharedController = sharedTerminalTitleController()
  if (sharedController) {
    return sharedController.emit(title)
  }

  const sequence = terminalTitleSequence(title)
  if (!sequence) {
    return false
  }

  return writeTerminalTitleSequence(sequence)
}
