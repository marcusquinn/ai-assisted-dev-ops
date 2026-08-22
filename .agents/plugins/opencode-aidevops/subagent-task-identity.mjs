// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Return a non-empty scalar session ID without coercing aggregate metadata. */
export function scalarSessionID(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function uniqueScalarSessionID(values) {
  const present = values.filter((value) => value !== undefined && value !== null && value !== "");
  if (present.some((value) => typeof value !== "string")) return "";
  const ids = [...new Set(present.map(scalarSessionID).filter(Boolean))];
  return ids.length === 1 ? ids[0] : "";
}

function hasConflictingScalarSessionIDs(values) {
  const ids = new Set(values.map(scalarSessionID).filter(Boolean));
  return ids.size > 1;
}

function metadataChildSessionValues(metadata) {
  return [metadata?.sessionId, metadata?.sessionID, metadata?.session_id];
}

function nativeTaskSessionValues(output) {
  const metadata = output?.metadata || {};
  const errorTaskIDs = [output?.error?.message, output?.error, output?.message]
    .map(scalarSessionID)
    .map((text) => text.match(/^(?:(?:Error|Tool execution failed):\s*)?Subagent failed \(task_id:\s*([^)]+)\):/)?.[1]);
  const renderedMatch = scalarSessionID(output?.output).match(/^<task id="([^"]+)" state="(?:running|completed|error)">/);
  return [metadata.task_id, metadata.taskId, metadata.taskID, ...errorTaskIDs, renderedMatch?.[1]];
}

export function explicitChildSessionIdentity(output) {
  const metadata = output?.metadata || {};
  const taskValues = nativeTaskSessionValues(output);
  const metadataValues = metadataChildSessionValues(metadata);
  const taskID = uniqueScalarSessionID(taskValues);
  const metadataID = uniqueScalarSessionID(metadataValues);
  if (hasConflictingScalarSessionIDs(taskValues)
    || hasConflictingScalarSessionIDs(metadataValues)
    || (taskID && metadataID && taskID !== metadataID)) {
    return { childID: "", reason: "child_identity_conflict" };
  }
  if (taskID) return { childID: taskID, reason: "native_task_id" };
  const taskMetadataPresent = [metadata.task_id, metadata.taskId, metadata.taskID]
    .some((value) => value !== undefined && value !== null && value !== "");
  return metadataID && !taskMetadataPresent
    ? { childID: metadataID, reason: "metadata" }
    : { childID: "", reason: "" };
}
