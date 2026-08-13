import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  buildRenderProps,
  buildSceneVideoFilenames,
  normalizeCaptions,
  validateBrief,
} from "./render-contract.mjs";

const aspectDimensions = { "9:16": [1080, 1920] };
const brief = { aspect: "9:16", scenes: [{ prompt: "one", duration: 1, fit: "contain" }] };

assert.throws(
  () => normalizeCaptions([{ startFrame: 99, text: "late" }], brief.scenes, 30),
  /caption timing is outside the render/
);
const testPath = new URL(import.meta.url).pathname;
assert.match(buildSceneVideoFilenames([testPath])[0], /^scene-0-[a-f0-9]{12}\.mp4$/);
assert.deepEqual(
  buildRenderProps(brief, ["scene-0.mp4"], 15, undefined).sceneVideos,
  ["scene-0.mp4"]
);
assert.throws(
  () =>
    validateBrief(
      { ...brief, scenes: [...brief.scenes, { prompt: "two", duration: 1 }] },
      ["one.mp4"],
      aspectDimensions,
    ),
  /scene\/video count mismatch/
);
const renderPath = new URL("./render.mjs", import.meta.url).pathname;
const helpOutput = execFileSync(process.execPath, [renderPath, "--help"], {
  encoding: "utf8",
});
assert.match(helpOutput, /Higgsfield Post-Production Renderer/);

console.log(
  "PASS: renderer rejects mismatched scenes and unsafe caption timing, and prints help safely",
);
