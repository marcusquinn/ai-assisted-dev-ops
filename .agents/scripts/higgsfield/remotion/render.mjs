#!/usr/bin/env node
// Remotion render CLI for Higgsfield post-production
// Usage:
//   node render.mjs --brief <path> --videos <v1.mp4,v2.mp4,...> --output <path>
//   node render.mjs --still --text "Title" --aspect 9:16 --output title.png

import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildRenderManifest, buildRenderProps, buildSceneVideoFilenames, calculateFrames, fileDigest, validateBrief } from "./render-contract.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Aspect ratio to pixel dimensions lookup (shared by renderVideo and renderStill)
const ASPECT_DIMS = {
  "16:9": [1920, 1080],
  "9:16": [1080, 1920],
  "1:1": [1080, 1080],
  "4:3": [1440, 1080],
  "3:4": [1080, 1440],
  "4:5": [1080, 1350],
  "5:4": [1350, 1080],
};

/**
 * Copy a music file to Remotion's public/ directory with path traversal protection.
 * Returns the public-relative filename, or undefined if skipped.
 */
function copyMusicToPublic(brief, briefPath, publicDir) {
  if (!brief.music) return undefined;

  // Resolve relative music paths against the brief file's directory (not cwd),
  // since brief.music is authored relative to the brief's location.
  const briefDir = dirname(briefPath);
  const musicAbsPath = resolve(briefDir, brief.music);
  // Path traversal guard: only allow music files within the brief's directory tree
  // or the project directory. Prevents arbitrary file read via crafted brief.music paths.
  // Check existence first so realpathSync can resolve symlinks for the security check.
  if (!existsSync(musicAbsPath)) {
    console.warn(`Warning: music file not found: ${musicAbsPath}, skipping`);
    return undefined;
  }
  // Resolve symlinks to prevent symlink-based directory escapes
  const musicRealPath = realpathSync(musicAbsPath);
  const projectDir = resolve(__dirname, "..", "..");
  if (!musicRealPath.startsWith(`${briefDir}/`) && !musicRealPath.startsWith(`${projectDir}/`)) {
    console.warn(
      `Warning: music path "${musicRealPath}" resolves outside the brief directory ` +
      `("${briefDir}") and project directory ("${projectDir}"), skipping for security`
    );
    return undefined;
  }
  const musicFilename = `music-${fileDigest(musicAbsPath).slice(0, 12)}-${basename(musicAbsPath)}`;
  const musicDest = join(publicDir, musicFilename);
  copyFileSync(musicAbsPath, musicDest);
  console.log(`  Copied ${basename(musicAbsPath)} -> public/${musicFilename}`);
  return musicFilename;
}

/**
 * Parse CLI arguments into a key-value options object.
 * Supports --key value and --flag (boolean) patterns.
 * @returns {Record<string, string | boolean>} Parsed options
 */
function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith("--")) {
      const key = args[i].slice(2);
      const val = args[i + 1] && !args[i + 1].startsWith("--") ? args[++i] : true;
      opts[key] = val;
    }
  }
  return opts;
}

function copySceneVideos(videoPaths, publicDir) {
  const filenames = buildSceneVideoFilenames(videoPaths);
  filenames.forEach((filename, index) => {
    const videoPath = videoPaths[index];
    copyFileSync(videoPath, join(publicDir, filename));
    console.log(`  Copied ${basename(videoPath)} -> public/${filename}`);
  });
  return filenames;
}

function renderComposition(output, renderArgs, recipe, props) {
  try {
    execFileSync("npx", renderArgs, { cwd: __dirname, stdio: "inherit", timeout: 600000 });
    if (!existsSync(output) || statSync(output).size === 0) throw new Error("render produced no output bytes");
    const manifest = buildRenderManifest(output, basename(output), recipe, props);
    writeFileSync(`${output}.manifest.json`, `${JSON.stringify(manifest, null, 2)}\n`);
    console.log(`\nRender complete: ${output}`);
  } catch (error) {
    console.error(`Render failed: ${error.message}`);
    process.exit(1);
  }
}

/**
 * Render a multi-scene video composition from a brief JSON and scene video files.
 * Copies assets to public/, builds Remotion props, and invokes npx remotion render.
 * @param {Record<string, string | boolean>} opts - CLI options (brief, videos, output, transition, etc.)
 */
function renderVideo(opts) {
  const briefPath = resolve(opts.brief);
  if (!existsSync(briefPath)) {
    console.error(`Brief not found: ${briefPath}`);
    process.exit(1);
  }

  const brief = JSON.parse(readFileSync(briefPath, "utf-8"));
  const videoPaths = opts.videos ? opts.videos.split(",").map((v) => resolve(v.trim())) : [];
  const output = opts.output ? resolve(opts.output) : resolve("output.mp4");

  // Validate videos exist
  for (const v of videoPaths) {
    if (!existsSync(v)) {
      console.error(`Video not found: ${v}`);
      process.exit(1);
    }
  }
  try {
    validateBrief(brief, videoPaths, ASPECT_DIMS);
  } catch (error) {
    console.error(`Invalid render input: ${error.message}`);
    process.exit(1);
  }

  // Copy videos into Remotion's public/ directory so staticFile() can resolve them.
  // staticFile() only accepts filenames (not absolute paths), so we copy each video
  // to public/ with a deterministic name and pass only the filename in props.
  const publicDir = join(__dirname, "public");
  if (!existsSync(publicDir)) {
    mkdirSync(publicDir, { recursive: true });
  }
  const sceneVideoFilenames = copySceneVideos(videoPaths, publicDir);

  const fps = 30;
  const scenes = brief.scenes || [];

  // Build props for Remotion
  const transitionDuration = parseInt(opts["transition-duration"] || "15", 10);
  const props = buildRenderProps(
    { ...brief, transitionStyle: brief.transitionStyle || opts.transition },
    sceneVideoFilenames,
    transitionDuration,
    copyMusicToPublic(brief, briefPath, publicDir)
  );

  const { totalSceneDuration, totalFrames } = calculateFrames(
    scenes, sceneVideoFilenames, props.transitionDuration, fps
  );
  const [width, height] = ASPECT_DIMS[props.aspect] || ASPECT_DIMS["9:16"];

  const propsJson = JSON.stringify(props);

  const renderArgs = [
    "remotion", "render",
    "src/index.ts",
    "FullVideo",
    output,
    `--props=${propsJson}`,
    `--width=${width}`,
    `--height=${height}`,
    `--frames=0-${totalFrames - 1}`,
    "--codec=h264",
    "--log=verbose",
  ];

  console.log(`Rendering ${sceneVideoFilenames.length} scenes -> ${output}`);
  console.log(`  Aspect: ${props.aspect} (${width}x${height})`);
  console.log(`  Duration: ${totalSceneDuration}s (${totalFrames} frames @ ${fps}fps)`);
  console.log(`  Transitions: ${props.transitionStyle} (${props.transitionDuration}f)`);
  console.log(`  Captions: ${props.captions.length}`);

  const recipe = { brief_sha256: fileDigest(briefPath), input_sha256: videoPaths.map(fileDigest), props, width, height, totalFrames, fps };
  renderComposition(output, renderArgs, recipe, props);
}

/**
 * Render a single still image (title card / graphic) via Remotion.
 * @param {Record<string, string | boolean>} opts - CLI options (text, subtitle, aspect, bg, color, font, output)
 */
function renderStill(opts) {
  const output = opts.output ? resolve(opts.output) : resolve("graphic.png");
  const aspect = opts.aspect || "9:16";
  const [width, height] = ASPECT_DIMS[aspect] || ASPECT_DIMS["9:16"];

  const props = {
    text: opts.text || "Title",
    subtitle: opts.subtitle || "",
    width,
    height,
    backgroundColor: opts.bg || "#0a0a0a",
    textColor: opts.color || "#ffffff",
    fontFamily: opts.font || "Inter",
  };

  const propsJson = JSON.stringify(props);

  const stillArgs = [
    "remotion", "still",
    "src/index.ts",
    "SceneGraphic",
    output,
    `--props=${propsJson}`,
    `--width=${width}`,
    `--height=${height}`,
    "--log=verbose",
  ];

  console.log(`Rendering still: "${props.text}" -> ${output}`);

  try {
    execFileSync("npx", stillArgs, {
      cwd: __dirname,
      stdio: "inherit",
      timeout: 120000,
    });
    console.log(`\nStill rendered: ${output}`);
  } catch (err) {
    console.error(`Still render failed: ${err.message}`);
    process.exit(1);
  }
}

// Main
const opts = parseArgs();

function printUsage() {
  console.log(`
Higgsfield Post-Production Renderer (Remotion)

Usage:
  node render.mjs --brief <path> --videos <v1.mp4,v2.mp4,...> [--output out.mp4]
  node render.mjs --still --text "Title" [--subtitle "Sub"] [--aspect 9:16] [--output out.png]

Video options:
  --brief              Path to pipeline brief JSON
  --videos             Comma-separated scene video paths
  --output             Output file path (default: output.mp4)
  --transition         Transition style: fade, slide, wipe, none (default: fade)
  --transition-duration  Transition duration in frames (default: 15)

Still options:
  --still              Render a still image (title card / graphic)
  --text               Title text
  --subtitle           Subtitle text
  --aspect             Aspect ratio (default: 9:16)
  --bg                 Background color (default: #0a0a0a)
  --color              Text color (default: #ffffff)
  --font               Font family (default: Inter)
  --output             Output file path (default: graphic.png)
`);
}

if (opts.help || (!opts.brief && !opts.still)) {
  printUsage();
} else if (opts.still) {
  renderStill(opts);
} else {
  renderVideo(opts);
}
