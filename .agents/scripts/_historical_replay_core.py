"""Immutable case validation and synthetic repository qualification."""

from __future__ import annotations

import hashlib
import json
import subprocess
import tarfile
import tempfile
from pathlib import Path
from typing import Any

SCHEMA = "aidevops-historical-replay/v1"
CASE_FILES = ("prompt.md", "verifier.sh", "gold.patch")
CLASSES = ("autonomous", "prescriptive")
PROFILES = ("aidevops", "wordpress-plugin", "nextjs")


class InvalidCase(RuntimeError):
    """A replay case failed closed."""


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise InvalidCase(f"cannot read valid JSON from {path.name}: {exc}") from exc


def run(command: list[str] | tuple[str, ...], cwd: Path) -> subprocess.CompletedProcess[str]:
    # Commands are arrays built by this harness; case scripts execute only in a
    # disposable synthetic repository after explicit operator action.
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)  # nosec B603


def case_identity(case_dir: Path, manifest: dict[str, Any]) -> str:
    identity = {
        "base_tree": manifest.get("base_tree"),
        "harness_policy": manifest.get("harness_policy"),
        "framework_version": manifest.get("framework_version"),
        "runtime_version": manifest.get("runtime_version"),
        "files": {name: digest(case_dir / name) for name in CASE_FILES},
    }
    return hashlib.sha256(canonical(identity)).hexdigest()


def validate_case(case_dir: Path, *, qualified: bool = False) -> dict[str, Any]:
    manifest_path = case_dir / "case.json"
    if not manifest_path.is_file():
        raise InvalidCase("missing case.json")
    manifest = load_json(manifest_path)
    required = ("profile", "experiment_class", "base_tree", "harness_policy", "framework_version", "runtime_version")
    missing = [key for key in required if not manifest.get(key)]
    if missing:
        raise InvalidCase("missing required fields: " + ", ".join(missing))
    if manifest["profile"] not in PROFILES:
        raise InvalidCase(f"unsupported profile: {manifest['profile']}")
    if manifest["experiment_class"] not in CLASSES:
        raise InvalidCase(f"unsupported experiment_class: {manifest['experiment_class']}")
    for name in CASE_FILES:
        if not (case_dir / name).is_file():
            raise InvalidCase(f"missing immutable artifact: {name}")
    actual = case_identity(case_dir, manifest)
    declared = manifest.get("case_id")
    if declared and declared != actual:
        raise InvalidCase(f"case identity mismatch: declared {declared}, calculated {actual}")
    manifest["case_id"] = actual
    receipt_path = case_dir / "qualification.json"
    if qualified or receipt_path.exists():
        receipt = load_json(receipt_path)
        if receipt.get("case_id") != actual or receipt.get("status") != "qualified":
            raise InvalidCase("missing, stale, or failed qualification receipt")
    return manifest


def export_base(case_dir: Path, manifest: dict[str, Any], destination: Path) -> None:
    archive = case_dir / "base.tar"
    if not archive.is_file():
        raise InvalidCase("missing base.tar; cases must archive a tree without future history")
    expected = manifest.get("base_tree_sha256")
    if expected and digest(archive) != expected:
        raise InvalidCase("base.tar hash mismatch")
    destination.mkdir(parents=True)
    with tarfile.open(archive) as bundle:
        root = destination.resolve()
        for member in bundle.getmembers():
            target = (destination / member.name).resolve()
            if target != root and root not in target.parents:
                raise InvalidCase("base.tar contains an unsafe path")
        bundle.extractall(destination, filter="data")
    commands = (("git", "init", "-q"), ("git", "add", "-A"),
                ("git", "-c", "user.name=Replay", "-c", "user.email=replay@invalid", "commit", "-qm", "synthetic base"))
    for command in commands:
        result = run(command, destination)
        if result.returncode:
            raise InvalidCase(f"synthetic repository creation failed: {result.stderr.strip()}")


def verifier(repo: Path, script: Path) -> subprocess.CompletedProcess[str]:
    return run(("bash", str(script)), repo)


def qualify(case_dir: Path) -> dict[str, Any]:
    manifest = validate_case(case_dir)
    with tempfile.TemporaryDirectory(prefix="aidevops-replay-") as temp:
        repo = Path(temp) / "repo"
        export_base(case_dir, manifest, repo)
        if verifier(repo, case_dir / "verifier.sh").returncode == 0:
            raise InvalidCase("broken base unexpectedly passes the target verifier")
        applied = run(("git", "apply", "--index", str(case_dir / "gold.patch")), repo)
        if applied.returncode:
            raise InvalidCase(f"gold patch does not apply: {applied.stderr.strip()}")
        first = verifier(repo, case_dir / "verifier.sh")
        second = verifier(repo, case_dir / "verifier.sh")
        if first.returncode or second.returncode:
            raise InvalidCase("gold patch fails the verifier")
        if (first.stdout, first.stderr) != (second.stdout, second.stderr):
            raise InvalidCase("verifier output is non-deterministic across identical runs")
        for command in manifest.get("pass_to_pass", []):
            if run(("bash", "-lc", command), repo).returncode:
                raise InvalidCase(f"pass-to-pass check failed: {command}")
    receipt = {"schema": SCHEMA, "case_id": manifest["case_id"], "status": "qualified", "verifier_sha256": digest(case_dir / "verifier.sh")}
    (case_dir / "qualification.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt
