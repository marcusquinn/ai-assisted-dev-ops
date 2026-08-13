// Types for Higgsfield post-production pipeline

export type CaptionPosition = "top" | "center" | "bottom";

export type CaptionStyle =
  | "bold-white"   // Bangers font, white + black shadow, spring entrance
  | "minimal"      // Clean sans-serif, thin white, fade in/out
  | "impact"       // Large bold, gradient background bar
  | "typewriter"   // Monospace, character-by-character reveal
  | "highlight";   // Word-by-word color highlight (TikTok style)

export interface CaptionEntry {
  scene: number;
  text: string;
  position: CaptionPosition;
  style: CaptionStyle;
  startFrame?: number;
  endFrame?: number;
  words?: Array<{ text: string; startFrame: number; endFrame: number }>;
}

export interface SceneEntry {
  prompt: string;
  duration: number;
  dialogue?: string | null;
  fit?: "cover" | "contain";
}

export interface BriefProps {
  title: string;
  scenes: SceneEntry[];
  aspect: string;
  captions: CaptionEntry[];
  sceneVideos: string[];       // Absolute paths to scene video files
  sceneImages?: string[];      // Absolute paths to scene start-frame images
  transitionStyle?: "fade" | "slide" | "wipe" | "none";
  transitionDuration?: number; // Frames (default 15 at 30fps = 0.5s)
  musicPath?: string;          // Optional background music
  fitPolicy?: "cover" | "contain";
}

export interface SceneVideoProps {
  src: string;
  durationInSeconds: number;
}

export interface SceneGraphicProps {
  text: string;
  subtitle?: string;
  width: number;
  height: number;
  backgroundColor?: string;
  textColor?: string;
  fontFamily?: string;
}

export interface CaptionOverlayProps {
  text: string;
  position: CaptionPosition;
  style: CaptionStyle;
  durationInFrames: number;
}

// Aspect ratio dimensions
export const ASPECT_DIMENSIONS: Record<string, { width: number; height: number }> = {
  "16:9": { width: 1920, height: 1080 },
  "9:16": { width: 1080, height: 1920 },
  "1:1":  { width: 1080, height: 1080 },
  "4:3":  { width: 1440, height: 1080 },
  "3:4":  { width: 1080, height: 1440 },
  "4:5":  { width: 1080, height: 1350 },
  "5:4":  { width: 1350, height: 1080 },
};
