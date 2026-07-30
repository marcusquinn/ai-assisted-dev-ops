#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Email, attachment, and mailbox expansion for folder ingestion."""

from __future__ import annotations

import email.policy
from email.message import Message
from email.parser import BytesParser
from pathlib import Path

from email_parse import html_to_text
from knowledge_folder_mbox import mbox_messages
from knowledge_folder_model import EvidenceInput, EvidenceProcessingError, ExpansionBudget
from knowledge_folder_types import classify_bytes, sha256_bytes


class EmailMixin:
    """Expand email containers after their canonical bytes are durable."""

    def _email_bytes(self, extension: str, data: bytes) -> bytes:
        if extension != ".emlx":
            return data
        length_line, separator, payload = data.partition(b"\n")
        if not separator or not length_line.isdigit():
            raise EvidenceProcessingError("emlx length header is malformed")
        message_length = int(length_line)
        if message_length > len(payload):
            raise EvidenceProcessingError("emlx message is truncated")
        return payload[:message_length]

    def _enrich_email(
        self, parent_id: str, raw_message: bytes, budget: ExpansionBudget
    ) -> list[dict[str, str]]:
        message = BytesParser(policy=email.policy.default).parsebytes(raw_message)
        relations = self._store_attachments(parent_id, message, budget)
        text_body = _message_text(message)
        if text_body:
            self._ensure_text_projection(parent_id, text_body)
        self._extend_meta(parent_id, _email_metadata(message, relations))
        return relations

    def _store_attachments(
        self, parent_id: str, message: Message, budget: ExpansionBudget
    ) -> list[dict[str, str]]:
        relations: list[dict[str, str]] = []
        for index, part in enumerate(message.iter_attachments()):
            relation = self._store_attachment(parent_id, part, index, budget)
            relations.append(relation)
            if relation.get("status") == "budget-stopped":
                break
        return relations

    def _store_attachment(
        self, parent_id: str, part: Message, index: int, budget: ExpansionBudget
    ) -> dict[str, str]:
        filename = part.get_filename() or f"attachment-{index + 1}.bin"
        payload = _attachment_bytes(part)
        if payload is None:
            return {
                "relationship": "attachment", "status": "unsupported",
                "filename": Path(filename).name, "content_type": part.get_content_type(),
            }
        if not budget.consume(len(payload)):
            return {"relationship": "attachment", "status": "budget-stopped"}
        mime_type = part.get_content_type() or "application/octet-stream"
        evidence = EvidenceInput(filename, sha256_bytes(payload), len(payload), "attachment", mime_type, data=payload)
        result = self._store(evidence)
        self._extend_meta(
            result.source_id,
            {
                "parent_sources": [parent_id],
                "attachment_filename": Path(filename).name,
                "content_type": part.get_content_type(),
            },
        )
        self._schedule_attachment(result.source_id, filename, mime_type, payload)
        return {"source_id": result.source_id, "relationship": "attachment"}

    def _schedule_attachment(self, source_id: str, filename: str, mime_type: str, payload: bytes) -> None:
        classification = classify_bytes(filename, payload[:8192])
        processors = classification.processors if classification.supported else ()
        failed = set(processors) if not classification.valid else set()
        dispositions = {processor: "failed" for processor in failed}
        self._ensure_enrichment(source_id, "attachment", mime_type, processors, dispositions)

    def _expand_mailbox(
        self, data: bytes, parent_id: str, budget: ExpansionBudget
    ) -> list[dict[str, str]]:
        relations: list[dict[str, str]] = []
        for index, raw_message in enumerate(mbox_messages(data)):
            if not budget.consume(len(raw_message)):
                relations.append({"relationship": "mailbox-message", "status": "budget-stopped"})
                break
            relations.extend(self._store_mailbox_message(parent_id, index, raw_message, budget))
        self._extend_meta(parent_id, {"children": relations})
        return relations

    def _store_mailbox_message(
        self, parent_id: str, index: int, raw_message: bytes, budget: ExpansionBudget
    ) -> list[dict[str, str]]:
        evidence = EvidenceInput(
            f"message-{index + 1}.eml", sha256_bytes(raw_message), len(raw_message),
            "email", "message/rfc822", data=raw_message,
        )
        result = self._store(evidence)
        try:
            children = self._enrich_email(result.source_id, raw_message, budget)
        except (LookupError, OSError, UnicodeError, ValueError, TypeError):
            self._ensure_enrichment(
                result.source_id, "email", "message/rfc822", ("email-parse",),
                {"email-parse": "failed"},
            )
            raise
        self._ensure_enrichment(
            result.source_id, "email", "message/rfc822", ("email-parse",),
            {"email-parse": "completed"},
        )
        self._extend_meta(result.source_id, {"parent_sources": [parent_id]})
        relation = {"source_id": result.source_id, "relationship": "mailbox-message"}
        return [relation, *children]


def _attachment_bytes(part: Message) -> bytes | None:
    if part.get_content_type() == "message/rfc822":
        return None
    return part.get_payload(decode=True)


def _message_text(message: Message) -> str:
    plain = message.get_body(preferencelist=("plain",))
    if plain is not None:
        content = plain.get_content()
        if isinstance(content, str):
            return content
    html = message.get_body(preferencelist=("html",))
    if html is None:
        return ""
    content = html.get_content()
    return html_to_text(content) if isinstance(content, str) else ""


def _email_metadata(message: Message, relations: list[dict[str, str]]) -> dict[str, object]:
    return {
        "from": str(message.get("From", "")),
        "to": str(message.get("To", "")),
        "cc": str(message.get("Cc", "")),
        "date": str(message.get("Date", "")),
        "subject": str(message.get("Subject", "")),
        "message_id": str(message.get("Message-ID", "")),
        "attachments": relations,
    }
