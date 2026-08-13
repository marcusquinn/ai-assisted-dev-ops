import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

export function fileDigest(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

export function stableDigest(value) {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

export function validateBrief(brief, videoPaths, aspectDimensions) {
  const scenes = brief.scenes || [];
  if (!Array.isArray(scenes) || scenes.length === 0) throw new Error("brief requires at least one scene");
  if (scenes.length !== videoPaths.length) throw new Error("scene/video count mismatch");
  if (!aspectDimensions[brief.aspect || "9:16"]) throw new Error("brief has an unsupported aspect ratio");
  for (const scene of scenes) {
    if (!Number.isFinite(scene.duration) || scene.duration <= 0) throw new Error("every scene requires a positive duration");
    if (scene.fit && !["cover", "contain"].includes(scene.fit)) throw new Error("scene fit must be cover or contain");
  }
}

export function calculateFrames(scenes, sceneVideoFilenames, transitionDuration, fps) {
  const sceneCount = Math.min(scenes.length, sceneVideoFilenames.length);
  const totalSceneDuration = scenes.slice(0, sceneCount).reduce((sum, scene) => sum + (scene.duration || 5), 0);
  const transitionOverlap = Math.max(0, sceneCount - 1) * transitionDuration;
  return {
    sceneCount,
    totalSceneDuration,
    totalFrames: Math.max(1, totalSceneDuration * fps - transitionOverlap),
  };
}

export function normalizeCaptions(rawCaptions, scenes, fps) {
  const lastSceneIndex = Math.max(0, scenes.length - 1);
  return rawCaptions.map((caption) => {
    if (typeof caption.scene === "number") {
      if (caption.scene < 0 || caption.scene > lastSceneIndex) throw new Error("caption scene is outside the render");
      return { ...caption, scene: caption.scene };
    }
    let frameOffset = 0;
    for (let scene = 0; scene < scenes.length; scene += 1) {
      const sceneFrames = (scenes[scene].duration || 5) * fps;
      if ((caption.startFrame || 0) >= frameOffset && (caption.startFrame || 0) < frameOffset + sceneFrames) {
        return {
          scene,
          text: caption.text || "",
          position: caption.position || "bottom",
          style: caption.style || "bold-white",
          startFrame: caption.startFrame,
          endFrame: caption.endFrame,
          words: caption.words || [],
        };
      }
      frameOffset += sceneFrames;
    }
    throw new Error("caption timing is outside the render");
  });
}

export function buildSceneVideoFilenames(videoPaths) {
  return videoPaths.map((videoPath, index) => `scene-${index}-${fileDigest(videoPath).slice(0, 12)}.mp4`);
}

export function buildRenderProps(brief, sceneVideos, transitionDuration, musicPath) {
  const scenes = brief.scenes || [];
  return {
    title: brief.title || "Untitled",
    scenes,
    aspect: brief.aspect || "9:16",
    captions: normalizeCaptions(brief.captions || [], scenes, 30),
    sceneVideos,
    transitionStyle: brief.transitionStyle || "fade",
    transitionDuration,
    musicPath,
    fitPolicy: brief.fitPolicy || "cover",
  };
}

export function buildRenderManifest(outputPath, outputName, recipe, props) {
  return {
    schema_version: 1,
    output: outputName,
    output_sha256: `sha256:${fileDigest(outputPath)}`,
    recipe_sha256: `sha256:${stableDigest(recipe)}`,
    captions: props.captions,
    fit_policy: props.fitPolicy,
    status: "completed",
  };
}
