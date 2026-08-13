import { Audio } from "@remotion/media";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import type React from "react";
import { AbsoluteFill, OffthreadVideo, Sequence, staticFile, useVideoConfig } from "remotion";
import { CaptionOverlay } from "./CaptionOverlay";
import type { BriefProps, CaptionEntry } from "./types";

// Resolve video source: use staticFile() for local filenames in public/,
// pass through URLs as-is
function toVideoSrc(path: string): string {
  if (path.startsWith("http://") || path.startsWith("https://")) {
    return path;
  }
  // Local filename (e.g. "scene-0.mp4") — resolve via Remotion's public/ dir
  return staticFile(path);
}

export const FullVideo: React.FC<BriefProps> = ({
  title: _title,
  scenes,
  aspect: _aspect,
  captions,
  sceneVideos,
  transitionStyle = "fade",
  transitionDuration = 15,
  musicPath,
  fitPolicy = "cover",
}) => {
  const { fps } = useVideoConfig();
  const useTransitions = transitionStyle !== "none" && sceneVideos.length > 1;

  // Find caption for a given scene index.
  // Captions whose scene index exceeds the available scenes are clamped to the
  // last scene so they still render instead of being silently dropped.
  const lastSceneIndex = Math.max(0, sceneVideos.length - 1);
  const getCaptionForScene = (sceneIndex: number): CaptionEntry | undefined => {
    return captions?.find((c) => {
      const clampedScene = Math.min(c.scene, lastSceneIndex);
      return clampedScene === sceneIndex;
    });
  };

  if (useTransitions) {
    return (
      <AbsoluteFill style={{ backgroundColor: "black" }}>
        <TransitionSeries>
          {sceneVideos.flatMap((videoSrc, i) => {
            const scene = scenes[i];
            const sceneDurationFrames = (scene?.duration || 5) * fps;
            const caption = getCaptionForScene(i);

            const elements: React.ReactNode[] = [
              <TransitionSeries.Sequence
                // biome-ignore lint/suspicious/noArrayIndexKey: scenes lack stable IDs
                key={`scene-${i}`}
                durationInFrames={sceneDurationFrames}
              >
                <AbsoluteFill>
                  <OffthreadVideo
                    src={toVideoSrc(videoSrc)}
                    style={{ width: "100%", height: "100%", objectFit: scene?.fit || fitPolicy }}
                  />
                  {caption && (
                    <CaptionOverlay
                      text={caption.text}
                      position={caption.position}
                      style={caption.style}
                      durationInFrames={sceneDurationFrames}
                    />
                  )}
                </AbsoluteFill>
              </TransitionSeries.Sequence>,
            ];

            // Add fade transition between scenes (not after last)
            if (i < sceneVideos.length - 1) {
              elements.push(
                <TransitionSeries.Transition
                  // biome-ignore lint/suspicious/noArrayIndexKey: scenes lack stable IDs
                  key={`transition-${i}`}
                  presentation={fade()}
                  timing={linearTiming({ durationInFrames: transitionDuration })}
                />
              );
            }

            return elements;
          })}
        </TransitionSeries>

        {/* Background music — resolve via staticFile() like scene videos */}
        {musicPath && (
          <Audio
            src={toVideoSrc(musicPath)}
            volume={0.3}
          />
        )}
      </AbsoluteFill>
    );
  }

  // No transitions: simple sequential layout
  let frameOffset = 0;
  return (
    <AbsoluteFill style={{ backgroundColor: "black" }}>
      {sceneVideos.map((videoSrc, i) => {
        const scene = scenes[i];
        const sceneDurationFrames = (scene?.duration || 5) * fps;
        const caption = getCaptionForScene(i);
        const from = frameOffset;
        frameOffset += sceneDurationFrames;

        return (
          <Sequence
            // biome-ignore lint/suspicious/noArrayIndexKey: scenes lack stable IDs
            key={`scene-${i}`}
            from={from}
            durationInFrames={sceneDurationFrames}
          >
            <AbsoluteFill>
              <OffthreadVideo
                src={toVideoSrc(videoSrc)}
                style={{ width: "100%", height: "100%", objectFit: scene?.fit || fitPolicy }}
              />
              {caption && (
                <CaptionOverlay
                  text={caption.text}
                  position={caption.position}
                  style={caption.style}
                  durationInFrames={sceneDurationFrames}
                />
              )}
            </AbsoluteFill>
          </Sequence>
        );
      })}

      {musicPath && (
        <Audio
          src={toVideoSrc(musicPath)}
          volume={0.3}
        />
      )}
    </AbsoluteFill>
  );
};
