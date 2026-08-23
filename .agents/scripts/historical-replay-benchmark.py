#!/usr/bin/env python3
"""Deterministic historical coding-task replay benchmark CLI."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from _historical_replay_core import InvalidCase, qualify, validate_case
from _historical_replay_experiment import build_plan, execute


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--case", type=Path, required=True)
    qualification = commands.add_parser("qualify")
    qualification.add_argument("--case", type=Path, required=True)
    dry = commands.add_parser("dry-run")
    dry.add_argument("--corpus", type=Path, required=True)
    dry.add_argument("--models", type=Path, required=True)
    dry.add_argument("--budget", choices=("quick", "full"), default="quick")
    dry.add_argument("--output", type=Path, required=True)
    execution = commands.add_parser("run")
    execution.add_argument("--corpus", type=Path, required=True)
    execution.add_argument("--plan", type=Path, required=True)
    execution.add_argument("--eligible-provider", action="append", required=True)
    reporting = commands.add_parser("report")
    reporting.add_argument("--plan", type=Path, required=True)
    return root


def dispatch(args: argparse.Namespace) -> object:
    if args.command == "validate":
        return validate_case(args.case)
    if args.command == "qualify":
        return qualify(args.case)
    if args.command == "dry-run":
        return build_plan(args.corpus, args.models, args.budget, args.output)
    if args.command == "run":
        return execute(args.corpus, args.plan, set(args.eligible_provider))
    return json.loads((args.plan / "report.json").read_text())


def main() -> int:
    try:
        print(json.dumps(dispatch(parser().parse_args()), sort_keys=True))
        return 0
    except (InvalidCase, OSError) as exc:
        print(f"replay benchmark: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
