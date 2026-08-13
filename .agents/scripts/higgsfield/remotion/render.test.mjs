import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

const renderer = new URL("./render.mjs", import.meta.url).pathname;
const root = mkdtempSync(join(tmpdir(), "remotion-render-"));

try {
  const brief = join(root, "brief.json");
  const video = join(root, "scene.mp4");
  writeFileSync(video, "fixture bytes");
  writeFileSync(brief, JSON.stringify({ aspect: "9:16", scenes: [{ prompt: "one", duration: 1, fit: "contain" }], captions: [{ startFrame: 99, text: "late" }] }));
  execFileSync(process.execPath, [renderer, "--brief", brief, "--videos", video], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  assert.fail("expected timing validation to fail");
} catch (error) {
  assert.match(`${error.stderr}`, /caption timing is outside the render/);
}

try {
  const brief = join(root, "brief-mismatch.json");
  const video = join(root, "scene-mismatch.mp4");
  writeFileSync(video, "fixture bytes");
  writeFileSync(brief, JSON.stringify({ aspect: "9:16", scenes: [{ prompt: "one", duration: 1 }, { prompt: "two", duration: 1 }] }));
  execFileSync(process.execPath, [renderer, "--brief", brief, "--videos", video], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  assert.fail("expected scene/video mismatch to fail");
} catch (error) {
  assert.match(`${error.stderr}`, /scene\/video count mismatch/);
}

rmSync(root, { recursive: true, force: true });
console.log("PASS: renderer rejects mismatched scenes and unsafe caption timing");
