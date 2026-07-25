#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Detect fast-fail escalation triggers in model output."""
import sys
import json
import re

output = sys.argv[1]
triggers = json.loads(sys.argv[2])
prompt = sys.argv[3]
expected = json.loads(sys.argv[4])
output_lower = output.lower()

detected = []

for trigger in triggers:
    if trigger == "refusal":
        refusal_phrases = [
            "i don't understand", "i cannot", "not able to",
            "i'm unable", "i am unable", "i'm not sure what",
            "could you clarify", "i need more context",
        ]
        if any(p in output_lower for p in refusal_phrases):
            detected.append("refusal")

    elif trigger == "confabulation":
        output_paths = set(re.findall(r"[\w./\-]+\.(?:md|sh|json|yaml|txt)", output))
        prompt_paths = set(re.findall(r"[\w./\-]+\.(?:md|sh|json|yaml|txt)", prompt))
        hallucinated = output_paths - prompt_paths
        known_paths = {"build.txt", "AGENTS.md", "TODO.md", "README.md"}
        hallucinated = hallucinated - known_paths
        if len(hallucinated) > 3:
            detected.append("confabulation")

    elif trigger == "structural_violation":
        required_actions = expected.get("action", [])
        if required_actions and any(
            action.lower() not in output_lower for action in required_actions
        ):
            detected.append("structural_violation")

    elif trigger == "disengagement":
        minimum_length = expected.get("min_length", 0)
        threshold = max(1, (minimum_length + 4) // 5)
        if minimum_length > 0 and len(output.strip()) < threshold:
            detected.append("disengagement")

if detected:
    print(",".join(detected))
    sys.exit(1)
else:
    print("")
    sys.exit(0)
