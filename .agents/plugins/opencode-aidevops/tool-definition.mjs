// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// OpenCode owns packages/opencode/src/tool/bash.txt. Adapt only its known
// listing-only paragraph through the public tool.definition hook; do not
// replace the tool, its parameters, or any runtime permission enforcement.
export const LEGACY_PARENT_GUIDANCE = `1. Directory Verification:
   - If the command will create new directories or files, first use \`ls\` to verify the parent directory exists and is the correct location
   - For example, before running "mkdir foo/bar", first use \`ls foo\` to check that "foo" exists and is the intended parent directory`;

export const BOUNDED_PARENT_GUIDANCE = `1. Directory Verification:
   - Before creating files or directories, verify the exact intended parent path relative to the command's workdir (or use an absolute path).
   - When only existence and directory type are needed, use a bounded check such as \`test -d "foo"\` before \`mkdir "foo/bar"\`. Exit 0 confirms a directory; failure must stop creation. This does not enumerate children.
   - A successful check does not establish that an arbitrary existing directory is the correct parent: confirm the intended location from task context first. Quote paths, including paths with spaces.
   - When child names are materially needed, use an appropriately scoped directory listing or dedicated Read operation instead.
   - These checks do not grant filesystem access or replace pre-edit Git checks, destructive-operation confirmation, or other permission controls.`;

export async function adaptToolDefinition(input, output) {
  if (input.toolID !== "bash" || typeof output.description !== "string") return;
  // Exact matching leaves future upstream revisions and other plugins' text
  // untouched rather than broadly deleting an unknown safety paragraph.
  output.description = output.description.replace(LEGACY_PARENT_GUIDANCE, BOUNDED_PARENT_GUIDANCE);
}
