import assert from "node:assert/strict";
import { normalizeCaptions, validateBrief } from "./render-contract.mjs";

const aspectDimensions = { "9:16": [1080, 1920] };
const brief = { aspect: "9:16", scenes: [{ prompt: "one", duration: 1, fit: "contain" }] };

assert.throws(
  () => normalizeCaptions([{ startFrame: 99, text: "late" }], brief.scenes, 30),
  /caption timing is outside the render/
);
assert.throws(
  () => validateBrief({ ...brief, scenes: [...brief.scenes, { prompt: "two", duration: 1 }] }, ["one.mp4"], aspectDimensions),
  /scene\/video count mismatch/
);

console.log("PASS: renderer rejects mismatched scenes and unsafe caption timing");
