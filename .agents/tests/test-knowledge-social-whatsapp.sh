#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-whatsapp.sh — safe export and official webhook tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIDEVOPS_TEST_MODE=1

exec python3 "${SCRIPT_DIR}/fixtures/knowledge-social-whatsapp/test_whatsapp_ingestion.py"
