// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import type { CommandRunner } from "./ai-research-runtime-types"

async function readLimitedStream(
  stream: ReadableStream<Uint8Array>,
  limit: number,
  onLimit: () => void,
): Promise<string> {
  const reader = stream.getReader()
  const chunks: Uint8Array[] = []
  let storedBytes = 0

  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    const remaining = limit - storedBytes
    if (value.byteLength > remaining) {
      if (remaining > 0) {
        chunks.push(value.slice(0, remaining))
        storedBytes += remaining
      }
      onLimit()
      await reader.cancel()
      break
    }
    chunks.push(value)
    storedBytes += value.byteLength
  }

  const merged = new Uint8Array(storedBytes)
  let offset = 0
  for (const chunk of chunks) {
    merged.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder().decode(merged)
}

export const runCommand: CommandRunner = async invocation => {
  if (invocation.signal?.aborted) {
    return {
      stdout: "",
      stderr: "",
      exitCode: 130,
      timedOut: false,
      aborted: true,
      outputLimitExceeded: false,
      spawnFailed: false,
    }
  }

  let child: ReturnType<typeof Bun.spawn>
  try {
    child = Bun.spawn(invocation.command, {
      cwd: invocation.cwd,
      env: invocation.env,
      stdout: "pipe",
      stderr: "pipe",
    })
  } catch {
    return {
      stdout: "",
      stderr: "",
      exitCode: 127,
      timedOut: false,
      aborted: false,
      outputLimitExceeded: false,
      spawnFailed: true,
    }
  }

  let timedOut = false
  let aborted = false
  let outputLimitExceeded = false
  const stop = () => {
    if (child.exitCode === null) child.kill()
  }
  const timeout = setTimeout(() => {
    timedOut = true
    stop()
  }, invocation.timeoutMs)
  const abort = () => {
    aborted = true
    stop()
  }
  invocation.signal?.addEventListener("abort", abort, { once: true })
  const markOutputLimit = () => {
    outputLimitExceeded = true
    stop()
  }

  try {
    const [stdout, stderr, exitCode] = await Promise.all([
      readLimitedStream(
        child.stdout as ReadableStream<Uint8Array>,
        invocation.maxOutputBytes,
        markOutputLimit,
      ),
      readLimitedStream(
        child.stderr as ReadableStream<Uint8Array>,
        invocation.maxOutputBytes,
        markOutputLimit,
      ),
      child.exited,
    ])
    return {
      stdout,
      stderr,
      exitCode,
      timedOut,
      aborted,
      outputLimitExceeded,
      spawnFailed: false,
    }
  } finally {
    clearTimeout(timeout)
    invocation.signal?.removeEventListener("abort", abort)
  }
}
