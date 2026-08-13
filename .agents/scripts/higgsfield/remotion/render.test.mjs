import assert from "node:assert/strict";
import { normalizeCaptions, validateBrief } from "./render-contract.mjs";

const aspectDimensions = { "9:16": [1080, 1920] };
const brief = { aspect: "9:16", scenes: [{ prompt: "one", duration: 1, fit: "contain" }] };

try {
  normalizeCaptions([{ startFrame: 99, text: "late" }], brief.scenes, 30);
  assert.fail("expected timing validation to fail");
} catch (error) {
  assert.match(`${error.message}`, /caption timing is outside the render/);
}

try {
  validateBrief({ ...brief, scenes: [...brief.scenes, { prompt: "two", duration: 1 }] }, ["one.mp4"], aspectDimensions);
  assert.fail("expected scene/video mismatch to fail");
} catch (error) {
  assert.match(`${error.message}`, /scene\/video count mismatch/);
}

console.log("PASS: renderer rejects mismatched scenes and unsafe caption timing");
