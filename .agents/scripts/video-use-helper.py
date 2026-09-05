# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Versioned video-use installation, read-only update checks and render smoke test.

No automatic upgrades, transcription, credential discovery or footage uploads.
The installed repository is a tool dependency, not a development checkout.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

AGENTS = Path(__file__).resolve().parent.parent
CONFIG = AGENTS / "configs/video-use-runtime.json.txt"
HELPERS = {"render", "grade", "pack_transcripts", "timeline_view"}


def command(args: list[str], *, cwd: Path | None = None) -> str:
    """Capture diagnostics without shell interpolation or credential values."""
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(
            f"{Path(args[0]).name} failed (exit {result.returncode}): "
            f"{result.stderr[-3000:]}"
        )
    return result.stdout.strip()


def configuration() -> dict:
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    if not re.fullmatch(r"[0-9a-f]{40}", config["reviewed_commit"]):
        raise ValueError("The reviewed commit must be a full immutable Git SHA")
    return config


def install_path(config: dict) -> Path:
    root = Path(
        os.environ.get(
            "AIDEVOPS_VIDEO_USE_HOME",
            str(Path.home() / ".aidevops/.agent-workspace/tools/video-use"),
        )
    )
    return root.expanduser().resolve() / config["reviewed_commit"]


def verify_source(path: Path, config: dict) -> None:
    if path.is_symlink() or not (path / ".git").is_dir():
        raise RuntimeError("Missing versioned installation; run install first")
    sha = command(["git", "-C", str(path), "rev-parse", "HEAD"])
    if sha != config["reviewed_commit"]:
        raise RuntimeError("Installed HEAD differs from the reviewed commit")
    if command(["git", "-C", str(path), "diff", "HEAD", "--"]):
        raise RuntimeError("Installed source has local changes; refusing execution")
    extras = command(
        [
            "git",
            "-C",
            str(path),
            "ls-files",
            "--others",
            "--exclude-standard",
            "--",
            "helpers",
            "skills",
        ]
    )
    if extras:
        raise RuntimeError("Untracked helper/skill files found; refusing execution")
    for name in config["required_files"]:
        source = path / name
        if not source.is_file() or source.is_symlink():
            raise RuntimeError(f"Incomplete installation: {name}")


def runtime_python(path: Path) -> Path:
    return path / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def verify_ffmpeg() -> None:
    for executable in ("ffmpeg", "ffprobe"):
        if not shutil.which(executable):
            raise RuntimeError(f"Missing dependency: {executable}")
    filters = command(["ffmpeg", "-hide_banner", "-filters"])
    available = {
        parts[1] for line in filters.splitlines() if len(parts := line.split()) >= 2
    }
    missing = {
        "subtitles",
        "overlay",
        "afade",
        "loudnorm",
        "zscale",
        "tonemap",
    } - available
    if missing:
        raise RuntimeError(
            "FFmpeg lacks required filters: "
            + ", ".join(sorted(missing))
            + ". Use a build with libass and zimg (macOS: ffmpeg-full). "
            "Put that build's bin directory first on PATH."
        )


def verify_runtime(path: Path, config: dict) -> None:
    verify_source(path, config)
    if (
        not runtime_python(path).is_file()
        or not (path / "aidevops-install.json").is_file()
    ):
        raise RuntimeError("Installation incomplete; dependency setup did not finish")
    verify_ffmpeg()
    command(
        [
            str(runtime_python(path)),
            "-c",
            "import requests, librosa, matplotlib, PIL, numpy",
        ]
    )


def install(config: dict, path: Path) -> None:
    """Create only a new version directory; never reset or overwrite an install."""
    if path.exists():
        verify_runtime(path, config)
        print(f"Already installed and verified: {path}")
        return
    for executable in ("git", "uv", "ffmpeg", "ffprobe"):
        if not shutil.which(executable):
            raise RuntimeError(f"Install {executable} before installing video-use")
    verify_ffmpeg()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.mkdir()  # Exclusive reservation: another installer must not share this path.
    print(f"Installing reviewed source into {path}", flush=True)
    command(
        [
            "git",
            "clone",
            "--no-checkout",
            "--filter=blob:none",
            config["repository"],
            str(path),
        ]
    )
    command(["git", "-C", str(path), "checkout", "--detach", config["reviewed_commit"]])
    verify_source(path, config)
    # uv.lock is retained in this version's directory; future runs do not resolve
    # or upgrade dependencies. Explicit installation may download Python/packages.
    command(["uv", "sync", "--project", str(path), "--python", config["python"]])
    frozen = command(["uv", "pip", "freeze", "--python", str(runtime_python(path))])
    receipt = {"reviewed_commit": config["reviewed_commit"], "dependencies": frozen}
    (path / "aidevops-install.json").write_text(
        json.dumps(receipt, indent=2) + "\n", encoding="utf-8"
    )
    verify_runtime(path, config)
    print("Installed and dependency-verified; run smoke-test before editing footage")


def status(config: dict, path: Path, upstream: bool = False) -> int:
    result = {
        "reviewed_commit": config["reviewed_commit"],
        "installation": str(path),
        "ready": False,
    }
    try:
        verify_runtime(path, config)
        result["ready"] = True
        result["installed_commit"] = config["reviewed_commit"]
    except (RuntimeError, OSError) as error:
        result["reason"] = str(error)
    if upstream:
        # Repository HEAD, not SKILL.md history: helper-only updates are visible.
        latest = command(
            [
                "gh",
                "api",
                f"repos/{config['github_repository']}/commits/HEAD",
                "--jq",
                ".sha",
            ]
        )
        if not re.fullmatch(r"[0-9a-f]{40}", latest):
            raise RuntimeError("GitHub returned an invalid commit")
        result["upstream_commit"] = latest
        result["update_available"] = latest != config["reviewed_commit"]
    print(json.dumps(result, indent=2))
    return 0 if upstream or result["ready"] else 1


def run_helper(config: dict, path: Path, helper: str, arguments: list[str]) -> None:
    if helper not in HELPERS:
        raise ValueError(
            "Only local render/grade/pack/timeline helpers are exposed; "
            "transcription requires separate upload and cost approval"
        )
    verify_runtime(path, config)
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    subprocess.run(
        [str(runtime_python(path)), str(path / f"helpers/{helper}.py"), *arguments],
        check=True,
    )


def smoke_test(config: dict, path: Path, output: Path) -> None:
    """Exercise the real renderer using generated media and synthetic captions."""
    verify_runtime(path, config)
    output = output.expanduser().resolve()
    if output == path or path in output.parents:
        raise ValueError("Smoke output must be outside the tool installation")
    if not output.parent.is_dir():
        raise ValueError("Smoke output parent must already exist")
    output.mkdir()  # Refuse existing output directories; never overwrite footage.
    edit = output / "edit"
    edit.mkdir()
    source = output / "source.mp4"
    overlay = edit / "overlay.mp4"
    common = ["ffmpeg", "-v", "error", "-nostdin", "-threads", "2"]
    command(
        [
            *common,
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x180:rate=30",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000",
            "-t",
            "3",
            "-c:v",
            "libx264",
            "-threads",
            "2",
            "-c:a",
            "aac",
            str(source),
        ]
    )
    command(
        [
            *common,
            "-f",
            "lavfi",
            "-i",
            "color=white:size=64x64:rate=30",
            "-t",
            "0.5",
            "-c:v",
            "libx264",
            "-threads",
            "2",
            str(overlay),
        ]
    )
    transcripts = edit / "transcripts"
    transcripts.mkdir()
    words = [
        {"type": "word", "text": text, "start": start, "end": start + 0.2}
        for text, start in (
            ("First", 0.2),
            ("clip", 0.5),
            ("Second", 1.7),
            ("clip", 2.0),
        )
    ]
    (transcripts / "source.json").write_text(
        json.dumps({"words": words}), encoding="utf-8"
    )
    edl = {
        "version": 1,
        "sources": {"source": str(source)},
        "ranges": [
            {"source": "source", "start": 0, "end": 1},
            {"source": "source", "start": 1.5, "end": 2.5},
        ],
        "grade": "none",
        "overlays": [{"file": "overlay.mp4", "start_in_output": 0.5, "duration": 0.5}],
    }
    edl_path = edit / "edl.json"
    edl_path.write_text(json.dumps(edl, indent=2), encoding="utf-8")
    final = edit / "preview.mp4"
    run_helper(
        config,
        path,
        "render",
        [
            str(edl_path),
            "-o",
            str(final),
            "--draft",
            "--build-subtitles",
            "--no-loudnorm",
        ],
    )
    probe = json.loads(
        command(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_streams",
                "-show_format",
                "-of",
                "json",
                str(final),
            ]
        )
    )
    video = next(
        stream for stream in probe["streams"] if stream["codec_type"] == "video"
    )
    if not any(stream["codec_type"] == "audio" for stream in probe["streams"]):
        raise RuntimeError("Smoke render lost its audio stream")
    if video["r_frame_rate"] != "30/1" or (video["width"], video["height"]) != (
        1280,
        720,
    ):
        raise RuntimeError("Smoke render has unexpected dimensions or frame rate")
    if abs(float(probe["format"]["duration"]) - 2.0) > 0.15:
        raise RuntimeError("Smoke render duration differs from the EDL")
    if "00:00:01,200" not in (edit / "master.srt").read_text(encoding="utf-8"):
        raise RuntimeError("Output-timeline captions are misaligned")
    for name, timestamp in (("before", "0.25"), ("overlay", "0.60"), ("after", "1.25")):
        command(
            [
                *common,
                "-ss",
                timestamp,
                "-i",
                str(final),
                "-frames:v",
                "1",
                "-update",
                "1",
                str(edit / f"{name}.png"),
            ]
        )
    (edit / "verification.json").write_text(
        json.dumps(probe, indent=2), encoding="utf-8"
    )
    print(f"Smoke checks passed; inspect the three frames and listen to {final}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser(
        "install", help="Explicit network install of reviewed code and dependencies"
    )
    sub.add_parser(
        "status", help="Verify installed files and dependencies without network access"
    )
    sub.add_parser("check-upstream", help="Read-only repository HEAD comparison via gh")
    run = sub.add_parser("run", help="Run a local helper; does not install or update")
    run.add_argument("helper", choices=sorted(HELPERS))
    run.add_argument("arguments", nargs=argparse.REMAINDER)
    smoke = sub.add_parser(
        "smoke-test", help="Render synthetic media; no ASR or API charges"
    )
    smoke.add_argument(
        "output", type=Path, help="New directory under an existing parent"
    )
    args = parser.parse_args()
    config = configuration()
    path = install_path(config)
    if args.action == "install":
        install(config, path)
    elif args.action in {"status", "check-upstream"}:
        return status(config, path, args.action == "check-upstream")
    elif args.action == "run":
        run_helper(config, path, args.helper, args.arguments)
    else:
        smoke_test(config, path, args.output)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"video-use: {exc}", file=sys.stderr)
        sys.exit(1)
