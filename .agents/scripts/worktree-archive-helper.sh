#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Compact, verifiable worktree recovery archives.  The implementation lives in
# Python so archive metadata and path validation have one portable code path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
export PYTHONDONTWRITEBYTECODE=1

exec python3 - "$@" <<'PY'
import argparse, datetime as dt, hashlib, json, os, pathlib, re, shutil, stat, subprocess, sys, tarfile, tempfile

ROOT = pathlib.Path(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_ROOT", pathlib.Path.home() / ".aidevops/recovery/archives"))
MAX_FILES = int(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES", "10000"))
MAX_BYTES = int(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES", str(1024 * 1024 * 1024)))
ARTIFACTS = {"commits.bundle", "diff.patch", "staged.patch", "untracked-files.txt", "untracked-files.nul", "untracked.tar.gz", "failure.log"}
BUNDLE = "commits.bundle"
ARTIFACT_LIST = "artifacts"
CREATED_AT = "created_at"
DIFF = "diff.patch"
STAGED = "staged.patch"
COMMON_GIT_DIR = "common_git_dir"
GIT_BUNDLE = "bundle"
REPO = "repo"
ISSUE = "issue"
HEAD_SHA = "head_sha"
REV_PARSE = "rev-parse"
SCHEMA = "schema"
SIZE = "size"
UNTRACKED_NUL = "untracked-files.nul"
SURROGATEESCAPE = "surrogateescape"
UNTRACKED_TEXT = "untracked-files.txt"
UNTRACKED_TAR = "untracked.tar.gz"
UTF8 = "utf-8"
WORKTREE = "worktree"

def fail(message):
    raise SystemExit(f"worktree archive: {message}")

def run(*args, cwd=None, check=True, text=True):
    result = subprocess.run(args, cwd=cwd, text=text, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        fail(result.stderr.strip() or "command failed: " + " ".join(args))
    return result

def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def git(repo, *args, check=True, text=True):
    return run("git", "-C", str(repo), *args, check=check, text=text)

def slug(value, name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", value):
        fail(f"invalid {name}: {value}")
    return value

def positive(value, name):
    if not re.fullmatch(r"[1-9][0-9]*", value): fail(f"invalid {name}: {value}")
    return int(value)

def physical(path, name):
    path = pathlib.Path(path)
    if path.is_symlink() or not path.is_dir(): fail(f"{name} must be an existing non-symlink directory")
    return path.resolve()

def artifact(path, name, required=False):
    if not path.exists(): return None
    return {"name": name, "sha256": sha(path), "size": path.stat().st_size, "required": required}

def safe_member(name):
    pure = pathlib.PurePosixPath(name)
    return not pure.is_absolute() and ".." not in pure.parts and name not in ("", ".")

def manifest_path(archive): return pathlib.Path(archive) / "manifest.json"

def load_manifest(archive):
    archive = physical(archive, "archive directory")
    path = manifest_path(archive)
    if not path.is_file() or path.is_symlink(): fail("archive has no safe manifest.json")
    try: data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error: fail(f"invalid manifest: {error}")
    required = {"schema", "repo", "issue", "reason", "created_at", "source_worktree_path", "branch", "head_sha", "base_branch", "base_sha", "default_branch", "remote_branch_state", "dirty_state", "artifacts", "restore_instructions"}
    if data.get(SCHEMA) != "worktree-archive-v1" or not required <= data.keys(): fail("manifest schema is incomplete")
    return archive, data

def verify(archive, quiet=False):
    archive, data = load_manifest(archive)
    seen = set()
    for entry in data[ARTIFACT_LIST]:
        name = entry.get("name", "")
        if name not in ARTIFACTS or name in seen: fail("manifest contains an invalid artifact")
        seen.add(name); path = archive / name
        if path.is_symlink() or not path.is_file() or sha(path) != entry.get("sha256") or path.stat().st_size != entry.get(SIZE):
            fail(f"artifact verification failed: {name}")
    for name in (DIFF, STAGED):
        if name not in seen: fail(f"missing required artifact: {name}")
    tar = archive / UNTRACKED_TAR
    if tar.exists():
        with tarfile.open(tar, "r:gz") as handle:
            for member in handle.getmembers():
                if not safe_member(member.name) or not (member.isfile() or member.issym()): fail("unsafe untracked archive member")
                if member.issym() and (os.path.isabs(member.linkname) or ".." in pathlib.PurePosixPath(member.linkname).parts): fail("unsafe untracked symlink")
    bundle = archive / BUNDLE
    common = pathlib.Path(data.get(COMMON_GIT_DIR, ""))
    repo = common.parent if common.name == ".git" else common
    if bundle.exists() and (not repo.is_dir() or git(repo, GIT_BUNDLE, "verify", str(bundle), check=False).returncode): fail("invalid commits bundle")
    if not quiet: print(f"verified {archive}")
    return archive, data

def archive(args):
    repo_slug = slug(args.repo, REPO)
    issue = positive(args.issue, ISSUE)
    if args.reason not in ("failed-worker", "post-pr-cleanup"): fail("invalid reason")
    source = physical(args.worktree_path, "worktree path")
    if git(source, REV_PARSE, "--is-inside-work-tree").stdout.strip() != "true": fail("worktree path is not a Git worktree")
    registered = {pathlib.Path(line[9:]).resolve() for line in git(source, WORKTREE, "list", "--porcelain").stdout.splitlines() if line.startswith(f"{WORKTREE} ")}
    if source not in registered: fail("worktree path is not a registered worktree root")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9/_.-]*", args.base_branch): fail("invalid base branch")
    head = git(source, REV_PARSE, "HEAD").stdout.strip()
    base = args.base_sha or git(source, REV_PARSE, "--verify", "--quiet", f"refs/remotes/origin/{args.base_branch}", check=False).stdout.strip() or git(source, REV_PARSE, "--verify", "--quiet", args.base_branch, check=False).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40,64}", base or "") or git(source, "cat-file", "-e", f"{base}^{{commit}}", check=False).returncode: fail("base SHA is not an available commit")
    root = pathlib.Path(args.output_root).expanduser() if args.output_root else ROOT
    destination_parent = root / repo_slug.split("/")[0] / repo_slug.split("/")[1] / str(issue)
    destination_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = destination_parent / stamp
    suffix = 1
    while destination.exists(): suffix += 1; destination = destination_parent / f"{stamp}-{suffix}"
    stage = pathlib.Path(tempfile.mkdtemp(prefix=".staging-", dir=destination_parent))
    try:
        diff = stage / DIFF; staged = stage / STAGED
        diff.write_bytes(git(source, "diff", "--binary", text=False).stdout)
        staged.write_bytes(git(source, "diff", "--cached", "--binary", text=False).stdout)
        branch = git(source, "symbolic-ref", "--short", "HEAD", check=False).stdout.strip() or "DETACHED"
        local_count = int(git(source, "rev-list", "--count", f"{base}..{head}").stdout.strip())
        if local_count:
            git(source, GIT_BUNDLE, "create", str(stage / BUNDLE), branch if branch != "DETACHED" else head, f"^{base}")
        raw = git(source, "ls-files", "--others", "--exclude-standard", "-z", text=False).stdout.split(b"\0")
        paths = sorted(item for item in raw if item)
        if len(paths) > MAX_FILES: fail("untracked file limit exceeded")
        total = 0
        with open(stage / UNTRACKED_NUL, "wb") as listing, open(stage / UNTRACKED_TEXT, "w") as visible:
            for raw_path in paths:
                name = raw_path.decode(UTF8, SURROGATEESCAPE)
                if not safe_member(name): fail("unsafe untracked path")
                item = source / name; info = item.lstat()
                if not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)): fail("unsupported untracked file type")
                total += info.st_size
                if total > MAX_BYTES: fail("untracked byte limit exceeded")
                listing.write(raw_path + b"\0"); visible.write(name + "\n")
        if paths:
            with tarfile.open(stage / UNTRACKED_TAR, "w:gz", dereference=False) as handle:
                for raw_path in paths: handle.add(source / raw_path.decode(UTF8, SURROGATEESCAPE), arcname=raw_path.decode(UTF8, SURROGATEESCAPE), recursive=False)
        default = git(source, "symbolic-ref", "refs/remotes/origin/HEAD", check=False).stdout.strip().rsplit("/", 1)[-1] or args.base_branch
        remote_sha = git(source, REV_PARSE, f"refs/remotes/origin/{branch}", check=False).stdout.strip()
        dirty = {"unstaged": bool(diff.stat().st_size), "staged": bool(staged.stat().st_size), "untracked_count": len(paths), "untracked_bytes": total}
        artifacts = [value for value in (artifact(diff, DIFF, True), artifact(staged, STAGED, True), artifact(stage / BUNDLE, BUNDLE), artifact(stage / UNTRACKED_TEXT, UNTRACKED_TEXT), artifact(stage / UNTRACKED_NUL, UNTRACKED_NUL), artifact(stage / UNTRACKED_TAR, UNTRACKED_TAR)) if value]
        common = git(source, REV_PARSE, "--git-common-dir").stdout.strip()
        manifest = {SCHEMA:"worktree-archive-v1", "state":"complete", REPO:repo_slug, ISSUE:issue, "reason":args.reason, CREATED_AT:dt.datetime.now(dt.timezone.utc).isoformat(), "source_worktree_path":str(source), COMMON_GIT_DIR:str((source / common).resolve()) if not os.path.isabs(common) else common, "branch":branch, HEAD_SHA:head, "base_branch":args.base_branch, "base_sha":base, "default_branch":default, "remote_branch_state":{"state":"present" if remote_sha else "absent", "sha":remote_sha or None}, "dirty_state":dirty, "local_commit_count":local_count, ARTIFACT_LIST:artifacts, "restore_instructions":"Run worktree-archive-helper.sh restore ARCHIVE --target NEW_WORKTREE. Restore creates a detached worktree; create a recovery branch after inspection."}
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        verify(stage, quiet=True); os.chmod(stage, 0o700); stage.rename(destination)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True); raise
    print(destination)

def restore(args):
    archive, data = verify(args.archive_dir, quiet=True)
    target = pathlib.Path(args.target).expanduser()
    if target.exists() or target.is_symlink(): fail("target must not exist")
    common = pathlib.Path(data[COMMON_GIT_DIR])
    if not common.exists(): fail("recorded repository is unavailable")
    repo = common.parent if common.name == ".git" else common
    if git(repo, REV_PARSE, "--git-common-dir", check=False).returncode: fail("recorded repository is not usable")
    recovered = data[HEAD_SHA]
    bundle = archive / BUNDLE
    if bundle.exists():
        ref = f"refs/aidevops/restores/{archive.name}"
        bundle_head = run("git", GIT_BUNDLE, "list-heads", str(bundle)).stdout.split()[0]
        git(repo, "fetch", str(bundle), f"{bundle_head}:{ref}"); recovered = git(repo, REV_PARSE, ref).stdout.strip()
    stage = target.parent / f".{target.name}.restore-{os.getpid()}"
    try:
        git(repo, WORKTREE, "add", "--detach", str(stage), recovered)
        for patch, indexed in ((archive / STAGED, True), (archive / DIFF, False)):
            if patch.stat().st_size: git(stage, "apply", "--index" if indexed else "--reject", str(patch))
        tar = archive / UNTRACKED_TAR
        if tar.exists():
            with tarfile.open(tar, "r:gz") as handle:
                for member in handle.getmembers():
                    if not safe_member(member.name): fail("unsafe untracked archive member")
                handle.extractall(stage, filter="data")
        git(repo, WORKTREE, "move", str(stage), str(target))
    except BaseException:
        if stage.exists(): git(repo, WORKTREE, "remove", "--force", str(stage), check=False)
        raise
    print(f"restored {target} at {recovered}; original branch was {data['branch']}")

def list_archives(args):
    root = ROOT
    if not root.is_dir(): return
    for manifest in sorted(root.glob("*/*/*/*/manifest.json")):
        try: archive, data = verify(manifest.parent, quiet=True)
        except SystemExit: continue
        if args.repo and data[REPO] != args.repo: continue
        if args.issue and data[ISSUE] != args.issue: continue
        print(json.dumps({"archive":str(archive), REPO:data[REPO], ISSUE:data[ISSUE], CREATED_AT:data[CREATED_AT]}, sort_keys=True))

def parse_size(value):
    match = re.fullmatch(r"([1-9][0-9]*)([KMGTP])", value)
    if not match: fail("max total size must be like 20G")
    return int(match.group(1)) * 1024 ** ("KMGTP".index(match.group(2)) + 1)

def prune(args):
    age = positive(args.older_than[:-1], "older-than") if re.fullmatch(r"[1-9][0-9]*d", args.older_than) else fail("older-than must be like 14d")
    cap = parse_size(args.max_total_size); now = dt.datetime.now(dt.timezone.utc)
    candidates = []
    for manifest in ROOT.glob("*/*/*/*/manifest.json") if ROOT.is_dir() else []:
        try: archive, data = verify(manifest.parent, quiet=True); created = dt.datetime.fromisoformat(data[CREATED_AT])
        except (SystemExit, ValueError): continue
        candidates.append((archive, created, sum(entry[SIZE] for entry in data[ARTIFACT_LIST])))
    total = sum(item[2] for item in candidates); remove = []
    for item in sorted(candidates, key=lambda value: value[1]):
        if (now - item[1]).days >= age or total > cap:
            remove.append(item); total -= item[2]
    for archive, _, size in remove: print(f"{'APPLY' if args.apply else 'DRY-RUN'} {archive} {size}")
    if args.apply:
        for archive, _, _ in remove: verify(archive, quiet=True); shutil.rmtree(archive)

def parser():
    result = argparse.ArgumentParser(description="Create compact, verifiable worktree recovery archives")
    sub = result.add_subparsers(dest="command", required=True)
    add = sub.add_parser("archive"); add.add_argument("worktree_path"); add.add_argument("--repo", required=True); add.add_argument("--issue", required=True); add.add_argument("--reason", required=True); add.add_argument("--base-branch", required=True); add.add_argument("--base-sha"); add.add_argument("--output-root"); add.set_defaults(func=archive)
    restore_p = sub.add_parser("restore"); restore_p.add_argument("archive_dir"); restore_p.add_argument("--target", required=True); restore_p.set_defaults(func=restore)
    listing = sub.add_parser("list"); listing.add_argument("--repo", type=lambda value: slug(value, REPO)); listing.add_argument("--issue", type=lambda value: positive(value, ISSUE)); listing.set_defaults(func=list_archives)
    check = sub.add_parser("verify"); check.add_argument("archive_dir"); check.set_defaults(func=lambda args: verify(args.archive_dir))
    pruning = sub.add_parser("prune"); pruning.add_argument("--older-than", required=True); pruning.add_argument("--max-total-size", required=True); mode = pruning.add_mutually_exclusive_group(); mode.add_argument("--dry-run", action="store_true"); mode.add_argument("--apply", action="store_true"); pruning.set_defaults(func=prune)
    return result

def main():
    os.umask(0o077); args = parser().parse_args(); args.func(args)

if __name__ == "__main__": main()
PY
