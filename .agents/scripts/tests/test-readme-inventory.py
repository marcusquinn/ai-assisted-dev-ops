# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Focused regressions for truthful, auditable README/hero inventory counts."""

import argparse
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from readme_inventory import KEYS, display_counts, inventory
from readme_inventory_cli import process_documents
from readme_inventory_documents import (
    hero_description,
    hero_title,
    inventory_summary,
    update_readme,
    update_svg,
    validate_readme,
    validate_svg,
)
from repo_metrics_git import run_command

PROFILE = "---\ndescription: Example specialist\nmode: subagent\n---\nInstructions.\n"
COUNTS = dict(zip(KEYS, (14, 630, 468, 106)))


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.git("init", "-q")

    def git(self, *args):
        result = run_command(["git", *args], self.root)
        self.assertIsNotNone(result)
        self.assertEqual(result.returncode, 0)
        return result

    def write(self, path, text=PROFILE):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return target

    def write_all(self, paths, text=PROFILE):
        for path in paths:
            self.write(path, text)

    def test_source_categories_and_exclusions(self):
        included = {
            "main_agents": [".agents/build-plus.md"],
            "subagents": [
                ".agents/aidevops.md",
                ".agents/scripts/commands/example.md",
                ".agents/tools/browser/example.md",
            ],
            "scripts": [
                ".agents/scripts/example-helper.py",
                ".agents/scripts/generate-opencode-agents.sh",
                ".agents/scripts/implementation.py",
                ".agents/scripts/readme-helper.sh",
            ],
            "slash_commands": [".agents/scripts/commands/example.md"],
        }
        for names in included.values():
            for name in names:
                self.write(name)
        excluded = [
            ".agents/AGENTS.md",
            ".agents/tools/README.md",
            ".agents/tools/example-skill.md",
            ".agents/scripts/tests/example-helper.sh",
            ".agents/scripts/fixtures/fake-helper.py",
            ".agents/scripts/test-fake-helper.sh",
            ".agents/scripts/runner.test.ts",
            ".agents/scripts/types.d.ts",
            ".agents/scripts/generated/fake.py",
            ".agents/tools/generated/fake.md",
            ".agents/tools/vendor/fake.md",
            ".agents/custom/example.md",
            ".agents/draft/example.md",
            ".agents/tools/tests/example.md",
            ".agents/scripts/commands/README.md",
        ]
        self.write_all(excluded)
        self.git("add", ".agents")
        self.write(".agents/tools/untracked.md")
        data = inventory(self.root)
        self.assertEqual(data["files"], included)
        self.assertEqual(data["counts"], dict(zip(KEYS, (1, 3, 4, 1))))

    def test_callable_markdown_modules_do_not_require_mode_metadata(self):
        modules = [
            ".agents/tools/SKILL.md",
            ".agents/tools/example-skill/part.md",
            ".agents/tools/design/library/example/DESIGN.md",
            ".agents/reference/example.md",
            ".agents/workflows/example.md",
            ".agents/tools/workflows/example.md",
            ".agents/tools/docs/example.md",
            ".agents/tools/documentation/example.md",
            ".agents/tools/references/example.md",
            ".agents/templates/example.md",
            ".agents/marketing-sales/example.md",
        ]
        self.write_all(
            modules, "# Independently callable instructions\nFollow this procedure.\n"
        )
        self.git("add", ".agents")
        data = inventory(self.root)
        self.assertEqual(data["files"]["subagents"], sorted(modules))
        self.assertEqual(data["counts"]["subagents"], len(modules))

    def test_production_script_languages_and_extensionless_entrypoint(self):
        names = [
            f".agents/scripts/module{suffix}"
            for suffix in (
                ".sh",
                ".py",
                ".js",
                ".mjs",
                ".cjs",
                ".ts",
                ".tsx",
                ".awk",
                ".jq",
            )
        ]
        self.write_all(names, "# Production helper module\n")
        self.write(".agents/scripts/gh", "#!/usr/bin/env bash\ntrue\n").chmod(0o755)
        self.write(".agents/scripts/NOTES", "Not an executable script.\n")
        self.git("add", ".agents")
        self.assertEqual(
            inventory(self.root)["files"]["scripts"],
            sorted([*names, ".agents/scripts/gh"]),
        )

    def test_aliases_count_only_as_command_entry_points(self):
        self.write(".agents/tools/example.md")
        self.write(".agents/workflows/example.md")
        commands = self.root / ".agents/scripts/commands"
        commands.mkdir(parents=True)
        (commands / "example.md").symlink_to("../../workflows/example.md")
        (self.root / ".agents/tools/alias.md").symlink_to("example.md")
        self.git("add", ".agents")
        data = inventory(self.root)
        self.assertEqual(data["counts"], dict(zip(KEYS, (0, 2, 0, 1))))

    def test_external_and_missing_command_targets_fail(self):
        self.write("outside.md")
        commands = self.root / ".agents/scripts/commands"
        commands.mkdir(parents=True)
        alias = commands / "example.md"
        alias.symlink_to("../../../outside.md")
        self.git("add", ".agents")
        with self.assertRaisesRegex(ValueError, "escapes"):
            inventory(self.root)
        alias.unlink()
        alias.symlink_to("missing.md")
        with self.assertRaises(FileNotFoundError):
            inventory(self.root)

    def test_untracked_command_target_fails(self):
        self.write(".agents/workflows/example.md")
        alias = self.root / ".agents/scripts/commands/example.md"
        alias.parent.mkdir(parents=True)
        alias.symlink_to("../../workflows/example.md")
        self.git("add", ".agents/scripts/commands")
        with self.assertRaisesRegex(ValueError, "not a tracked"):
            inventory(self.root)


class DocumentTests(unittest.TestCase):
    def readme(self):
        return hero_title(COUNTS) + "\n" + inventory_summary(COUNTS)

    def svg(self):
        numbers = display_counts(COUNTS)
        text = "".join(
            f'<text data-count="{key}">{numbers[key]}</text>' for key in KEYS
        )
        return (
            '<svg xmlns="http://www.w3.org/2000/svg">'
            f"<title>{hero_title(COUNTS)}</title><desc>{hero_description(COUNTS)}</desc>{text}</svg>"
        )

    def test_small_counts_never_round_up(self):
        self.assertEqual(
            display_counts(dict(zip(KEYS, (1, 2, 3, 4)))),
            dict(zip(KEYS, ("1", "2", "3", "4"))),
        )

    def test_all_readme_occurrences_checked(self):
        self.assertEqual(validate_readme(self.readme(), COUNTS), [])
        for label in (
            "15 primary agents",
            "2,250+ subagents",
            "2,140+ helper scripts",
            "185+ slash commands",
        ):
            with self.subTest(label=label):
                self.assertTrue(validate_readme(self.readme() + "\n" + label, COUNTS))

    def test_update_roundtrip_and_idempotence(self):
        changed = dict(zip(KEYS, (15, 710, 489, 118)))
        text = update_readme(self.readme(), changed)
        svg = update_svg(self.svg(), changed)
        self.assertEqual(validate_readme(text, changed), [])
        self.assertEqual(validate_svg(svg, changed), [])
        self.assertEqual(update_readme(text, changed), text)
        self.assertEqual(update_svg(svg, changed), svg)

    def test_legacy_readme_without_summary_remains_supported(self):
        changed = dict(zip(KEYS, (15, 710, 489, 118)))
        updated = update_readme(hero_title(COUNTS), changed)
        self.assertEqual(validate_readme(updated, changed), [])
        with self.assertRaises(ValueError):
            update_readme(
                self.readme().replace("<!-- aidevops:inventory:end -->", ""), changed
            )

    def test_missing_or_duplicate_svg_figures_fail(self):
        duplicate = self.svg().replace(
            "</svg>", '<text data-count="scripts">460+</text></svg>'
        )
        self.assertTrue(validate_svg(duplicate, COUNTS))
        with self.assertRaises(ValueError):
            update_svg(duplicate, COUNTS)
        self.assertTrue(validate_svg(self.svg().replace("600+", "2,250+"), COUNTS))

    def test_svg_rejects_declarations_and_oversized_input(self):
        invalid = (
            '<!DOCTYPE svg [<!ENTITY x "expanded">]>' + self.svg(),
            '<!DOCTYPE svg SYSTEM "never-fetch.dtd">' + self.svg(),
            " " * 65537 + self.svg(),
            "<broken>",
        )
        for text in invalid:
            with self.subTest(text=text[:60]):
                with self.assertRaises(ValueError):
                    validate_svg(text, COUNTS)
                with self.assertRaises(ValueError):
                    update_svg(text, COUNTS)

    def test_svg_quotes_and_prefixes_roundtrip(self):
        prefixed = self.svg().replace("xmlns=", "xmlns:s=")
        for tag in ("svg", "title", "desc", "text"):
            prefixed = prefixed.replace("<" + tag, "<s:" + tag).replace(
                "</" + tag, "</s:" + tag
            )
        changed = dict(zip(KEYS, (15, 710, 489, 118)))
        for variant in (self.svg().replace('"', "'"), prefixed):
            with self.subTest(variant=variant):
                self.assertEqual(validate_svg(variant, COUNTS), [])
                self.assertEqual(
                    validate_svg(update_svg(variant, changed), changed), []
                )

    def test_dry_run_then_apply(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            readme = root / "README.md"
            readme.write_text(self.readme(), encoding="utf-8")
            args = argparse.Namespace(file=readme, command="update", apply=False)
            changed = dict(zip(KEYS, (15, 710, 489, 118)))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(process_documents(args, root, changed), 0)
                self.assertEqual(readme.read_text(encoding="utf-8"), self.readme())
                args.apply = True
                self.assertEqual(process_documents(args, root, changed), 0)
            self.assertEqual(
                validate_readme(readme.read_text(encoding="utf-8"), changed), []
            )
            self.assertEqual(
                readme.with_name("README.md.bak").read_text(encoding="utf-8"),
                self.readme(),
            )


if __name__ == "__main__":
    unittest.main()
