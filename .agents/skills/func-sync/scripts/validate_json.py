#!/usr/bin/env python3
"""Validate funcDictionary 1.0 snapshot and delta exchange JSON.

This intentionally uses only the Python standard library so the repository
Skill remains runnable in a clean agent environment.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any


class ValidationError(ValueError):
    pass


DATE_KEYS = {"created_at", "updated_at", "generated_at", "occurred_at", "calculated_at"}


def fail(message: str) -> None:
    raise ValidationError(message)


def require_object(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{path}: expected an object")
    return value


def require_keys(value: dict[str, Any], keys: set[str], path: str) -> None:
    missing = sorted(keys - value.keys())
    if missing:
        fail(f"{path}: missing keys: {', '.join(missing)}")


def require_prefix(value: Any, prefix: str, path: str) -> None:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value) or not value.startswith(prefix):
        fail(f"{path}: invalid stable ID")


def require_nonempty_string(value: Any, path: str) -> None:
    if not isinstance(value, str) or not value.strip():
        fail(f"{path}: expected a non-empty string")


def require_unit_interval(value: Any, path: str) -> None:
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not 0 <= value <= 1:
        fail(f"{path}: expected a number between 0 and 1")


def require_date(value: Any, path: str) -> None:
    if not isinstance(value, str):
        fail(f"{path}: expected ISO-8601 date")
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"{path}: invalid ISO-8601 date ({exc})")


def reject_binary(value: Any, path: str = "$") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            reject_binary(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_binary(child, f"{path}[{index}]")
    elif isinstance(value, str):
        lower = value.lower()
        if lower.startswith("data:image/") or "base64," in lower:
            fail(f"{path}: embedded image/Base64 is not allowed")


def validate_snapshot_path(value: Any, path: str) -> None:
    if not isinstance(value, str) or "\\" in value:
        fail(f"{path}: snapshot path must use relative POSIX form")
    pure = PurePosixPath(value)
    parts = pure.parts
    if len(parts) != 2 or parts[0] != "snapshots" or parts[1] in {"", ".", ".."} or not parts[1].lower().endswith(".jpg"):
        fail(f"{path}: expected snapshots/<filename>.jpg")


def validate_snapshot_metadata(value: Any, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"id", "file", "width", "height", "size_bytes", "perceptual_hash", "revision", "milestone"}, path)
    if not isinstance(item["id"], str) or not item["id"]:
        fail(f"{path}.id: must not be empty")
    validate_snapshot_path(item["file"], f"{path}.file")
    for key in ("width", "height", "size_bytes"):
        if not isinstance(item[key], int) or item[key] <= 0:
            fail(f"{path}.{key}: must be a positive integer")
    if not isinstance(item["revision"], int) or item["revision"] < 0:
        fail(f"{path}.revision: must be non-negative")
    if not isinstance(item["perceptual_hash"], str) or not item["perceptual_hash"]:
        fail(f"{path}.perceptual_hash: must not be empty")
    if not isinstance(item["milestone"], bool):
        fail(f"{path}.milestone: expected boolean")


def validate_fuzzy_term(value: Any, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"id", "text", "source", "weight", "usage_count"}, path)
    require_nonempty_string(item["id"], f"{path}.id")
    require_nonempty_string(item["text"], f"{path}.text")
    if item["source"] not in {"user", "human_added", "ai_generated"}:
        fail(f"{path}.source: unsupported fuzzy-term source")
    require_unit_interval(item["weight"], f"{path}.weight")
    if not isinstance(item["usage_count"], int) or isinstance(item["usage_count"], bool) or item["usage_count"] < 1:
        fail(f"{path}.usage_count: must be a positive integer")


def validate_reference(value: Any, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"id", "kind", "value"}, path)
    require_nonempty_string(item["id"], f"{path}.id")
    require_nonempty_string(item["kind"], f"{path}.kind")
    require_nonempty_string(item["value"], f"{path}.value")


def validate_change_map(value: Any, path: str) -> None:
    if not isinstance(value, dict):
        fail(f"{path}: expected a change map")
    for key, child in value.items():
        if not isinstance(key, str) or not key.strip():
            fail(f"{path}: change keys must be non-empty strings")
        if isinstance(child, str):
            continue
        if isinstance(child, dict):
            if set(child) != {"from", "to"}:
                fail(f"{path}.{key}: object form must contain only from and to")
            if not isinstance(child["from"], str) or not isinstance(child["to"], str):
                fail(f"{path}.{key}: from and to must be strings")
            continue
        fail(f"{path}.{key}: expected a string or from/to object")


def validate_history_event(value: Any, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"revision", "change_type", "changes", "code_impact", "semantic_impact", "milestone", "occurred_at"}, path)
    if not isinstance(item["revision"], int) or isinstance(item["revision"], bool) or item["revision"] < 0:
        fail(f"{path}.revision: must be non-negative")
    require_nonempty_string(item["change_type"], f"{path}.change_type")
    validate_change_map(item["changes"], f"{path}.changes")
    require_unit_interval(item["code_impact"], f"{path}.code_impact")
    require_unit_interval(item["semantic_impact"], f"{path}.semantic_impact")
    if not isinstance(item["milestone"], bool):
        fail(f"{path}.milestone: expected boolean")
    require_date(item["occurred_at"], f"{path}.occurred_at")


def validate_definition(value: Any, project_id: str, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"id", "project_id", "schema_version", "identity", "function", "code_locator", "visual_locator", "functional_locator", "fuzzy_terms", "relations", "references", "snapshots", "implementation_history", "review_status", "active_context", "lineage", "created_at", "updated_at"}, path)
    require_prefix(item["id"], "def_", f"{path}.id")
    if item["project_id"] != project_id:
        fail(f"{path}.project_id: crosses project boundary")
    if item["schema_version"] != "1.0":
        fail(f"{path}.schema_version: expected 1.0")
    identity = require_object(item["identity"], f"{path}.identity")
    require_keys(identity, {"canonical_name", "display_name", "kind"}, f"{path}.identity")
    if not isinstance(identity["canonical_name"], str) or not identity["canonical_name"].strip():
        fail(f"{path}.identity.canonical_name: must not be empty")
    locator = require_object(item["code_locator"], f"{path}.code_locator")
    require_keys(locator, {"symbol", "symbol_type", "func", "signature", "owner", "file", "module"}, f"{path}.code_locator")
    for index, term in enumerate(item["fuzzy_terms"]):
        validate_fuzzy_term(term, f"{path}.fuzzy_terms[{index}]")
    for index, reference in enumerate(item["references"]):
        validate_reference(reference, f"{path}.references[{index}]")
    for index, snapshot in enumerate(item["snapshots"]):
        validate_snapshot_metadata(snapshot, f"{path}.snapshots[{index}]")
    for index, relation in enumerate(item["relations"]):
        relation_object = require_object(relation, f"{path}.relations[{index}]")
        if relation_object.get("source_definition_id") != item["id"]:
            fail(f"{path}.relations[{index}]: source does not own relation")
        validate_relation(relation, project_id, f"{path}.relations[{index}]")
    for key in DATE_KEYS:
        if key in item:
            require_date(item[key], f"{path}.{key}")
    for index, event in enumerate(item["implementation_history"]):
        validate_history_event(event, f"{path}.implementation_history[{index}]")


def validate_relation(value: Any, project_id: str, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"id", "type", "source_definition_id", "target_definition_id", "metadata"}, path)
    require_nonempty_string(item["id"], f"{path}.id")
    require_nonempty_string(item["type"], f"{path}.type")
    require_prefix(item["source_definition_id"], "def_", f"{path}.source_definition_id")
    require_prefix(item["target_definition_id"], "def_", f"{path}.target_definition_id")
    if not isinstance(item["metadata"], dict) or not all(isinstance(key, str) and isinstance(child, str) for key, child in item["metadata"].items()):
        fail(f"{path}.metadata: expected a string map")
    if item["type"] == "calls":
        call_file = item["metadata"].get("file", "")
        line = item["metadata"].get("line", "")
        relative_path = PurePosixPath(call_file)
        if (not call_file.strip() or relative_path.is_absolute() or ".." in relative_path.parts
                or not line.isdigit() or int(line) < 1 or not item["metadata"].get("evidence", "").strip()):
            fail(f"{path}.metadata: calls require a relative file, positive line, and evidence")
    if not project_id:
        fail(f"{path}: missing project context")


def validate_evolution(value: Any, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"definition_id", "change_type", "changes", "code_impact", "semantic_impact", "milestone"}, path)
    require_prefix(item["definition_id"], "def_", f"{path}.definition_id")
    require_nonempty_string(item["change_type"], f"{path}.change_type")
    validate_change_map(item["changes"], f"{path}.changes")
    require_unit_interval(item["code_impact"], f"{path}.code_impact")
    require_unit_interval(item["semantic_impact"], f"{path}.semantic_impact")
    if not isinstance(item["milestone"], bool):
        fail(f"{path}.milestone: expected boolean")


def validate_cluster(value: Any, project_id: str, known_definition_ids: set[str], path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"id", "project_id", "name", "definition_ids", "primary_definition_id", "status", "created_at", "updated_at"}, path)
    require_nonempty_string(item["id"], f"{path}.id")
    if item["project_id"] != project_id:
        fail(f"{path}.project_id: crosses project boundary")
    require_nonempty_string(item["name"], f"{path}.name")
    if not isinstance(item["definition_ids"], list) or len(item["definition_ids"]) < 2:
        fail(f"{path}.definition_ids: must contain at least two definitions")
    if len(set(item["definition_ids"])) != len(item["definition_ids"]):
        fail(f"{path}.definition_ids: duplicate definition ID")
    for index, definition_id in enumerate(item["definition_ids"]):
        require_prefix(definition_id, "def_", f"{path}.definition_ids[{index}]")
        if definition_id not in known_definition_ids:
            fail(f"{path}.definition_ids[{index}]: unknown definition")
    require_prefix(item["primary_definition_id"], "def_", f"{path}.primary_definition_id")
    if item["primary_definition_id"] not in item["definition_ids"]:
        fail(f"{path}.primary_definition_id: must be a cluster member")
    if item["status"] not in {"pending", "approved", "adjusted", "rejected"}:
        fail(f"{path}.status: unsupported proposal status")
    require_nonempty_string(item["created_at"], f"{path}.created_at")
    require_date(item["created_at"], f"{path}.created_at")
    require_date(item["updated_at"], f"{path}.updated_at")


def validate_proposal(value: Any, project_id: str, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"id", "project_id", "action", "definition_ids", "status", "summary", "payload", "created_at"}, path)
    require_nonempty_string(item["id"], f"{path}.id")
    if item["project_id"] != project_id:
        fail(f"{path}.project_id: crosses project boundary")
    if item["action"] not in {"split", "merge", "deprecated", "identity_change", "cluster"}:
        fail(f"{path}.action: unsupported proposal action")
    if not isinstance(item["definition_ids"], list) or not item["definition_ids"]:
        fail(f"{path}.definition_ids: must not be empty")
    for index, definition_id in enumerate(item["definition_ids"]):
        require_prefix(definition_id, "def_", f"{path}.definition_ids[{index}]")
    if len(set(item["definition_ids"])) != len(item["definition_ids"]):
        fail(f"{path}.definition_ids: duplicate definition ID")
    if item["action"] == "cluster" and len(item["definition_ids"]) < 2:
        fail(f"{path}.definition_ids: cluster proposal needs at least two definitions")
    if item["status"] not in {"pending", "approved", "adjusted", "rejected"}:
        fail(f"{path}.status: unsupported proposal status")
    require_nonempty_string(item["summary"], f"{path}.summary")
    if not isinstance(item["payload"], dict) or not all(isinstance(key, str) and isinstance(child, str) for key, child in item["payload"].items()):
        fail(f"{path}.payload: expected a string map")
    require_date(item["created_at"], f"{path}.created_at")


def validate_change_request(value: Any, project_id: str, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"id", "project_id", "definition_id", "requested_change", "reason", "risk", "affected_definition_ids", "status", "created_at"}, path)
    require_nonempty_string(item["id"], f"{path}.id")
    if item["project_id"] != project_id:
        fail(f"{path}.project_id: crosses project boundary")
    require_prefix(item["definition_id"], "def_", f"{path}.definition_id")
    requested = require_object(item["requested_change"], f"{path}.requested_change")
    require_keys(requested, {"type", "summary"}, f"{path}.requested_change")
    require_nonempty_string(requested["type"], f"{path}.requested_change.type")
    require_nonempty_string(requested["summary"], f"{path}.requested_change.summary")
    require_nonempty_string(item["reason"], f"{path}.reason")
    require_nonempty_string(item["risk"], f"{path}.risk")
    if not isinstance(item["affected_definition_ids"], list):
        fail(f"{path}.affected_definition_ids: expected an array")
    for index, definition_id in enumerate(item["affected_definition_ids"]):
        require_prefix(definition_id, "def_", f"{path}.affected_definition_ids[{index}]")
    if item["status"] not in {"pending", "approved", "rejected"}:
        fail(f"{path}.status: unsupported change-request status")
    require_date(item["created_at"], f"{path}.created_at")


def validate_conflict(value: Any, project_id: str, path: str) -> None:
    item = require_object(value, path)
    require_keys(item, {"id", "project_id", "definition_id", "field", "base_revision", "local_revision", "remote_revision", "local_value", "remote_value", "status", "created_at"}, path)
    require_nonempty_string(item["id"], f"{path}.id")
    if item["project_id"] != project_id:
        fail(f"{path}.project_id: crosses project boundary")
    require_prefix(item["definition_id"], "def_", f"{path}.definition_id")
    require_nonempty_string(item["field"], f"{path}.field")
    for key in ("base_revision", "local_revision", "remote_revision"):
        if not isinstance(item[key], int) or isinstance(item[key], bool) or item[key] < 0:
            fail(f"{path}.{key}: must be non-negative")
    if not isinstance(item["local_value"], str) or not isinstance(item["remote_value"], str):
        fail(f"{path}: conflict values must be strings")
    if item["status"] not in {"needs_review", "resolved"}:
        fail(f"{path}.status: unsupported conflict status")
    require_date(item["created_at"], f"{path}.created_at")


def validate_project(value: Any, path: str = "$.project") -> str:
    project = require_object(value, path)
    require_keys(project, {"id", "name", "schema_version", "created_at", "updated_at", "archived"}, path)
    require_prefix(project["id"], "project_", f"{path}.id")
    if not isinstance(project["name"], str) or not project["name"].strip():
        fail(f"{path}.name: must not be empty")
    if project["schema_version"] != "1.0":
        fail(f"{path}.schema_version: expected 1.0")
    require_date(project["created_at"], f"{path}.created_at")
    require_date(project["updated_at"], f"{path}.updated_at")
    return project["id"]


def validate_snapshot(document: dict[str, Any]) -> None:
    require_keys(document, {"schema_version", "project", "definitions", "clusters", "agent_context", "revision", "generated_at"}, "$")
    if document["schema_version"] != "1.0":
        fail("$.schema_version: expected 1.0")
    project_id = validate_project(document["project"])
    if not isinstance(document["revision"], int) or document["revision"] < 0:
        fail("$.revision: must be non-negative")
    require_date(document["generated_at"], "$.generated_at")
    definition_ids: set[str] = set()
    for index, definition in enumerate(document["definitions"]):
        validate_definition(definition, project_id, f"$.definitions[{index}]")
        if definition["id"] in definition_ids:
            fail(f"$.definitions[{index}].id: duplicate stable ID")
        definition_ids.add(definition["id"])
    for index, cluster in enumerate(document["clusters"]):
        validate_cluster(cluster, project_id, definition_ids, f"$.clusters[{index}]")
    context = require_object(document["agent_context"], "$.agent_context")
    require_keys(context, {"definition_id", "canonical_name", "current_symbol", "current_func", "code_locator", "visual_locator", "functional_locator", "relevant_relations"}, "$.agent_context")
    if context["definition_id"] and context["definition_id"] not in definition_ids:
        fail("$.agent_context.definition_id: unknown definition")
    if context["definition_id"]:
        require_prefix(context["definition_id"], "def_", "$.agent_context.definition_id")
    for index, relation in enumerate(context["relevant_relations"]):
        validate_relation(relation, project_id, f"$.agent_context.relevant_relations[{index}]")


def validate_delta(document: dict[str, Any]) -> None:
    required = {"schema_version", "delta_id", "project_id", "base_revision", "target_revision", "created_at", "changed_fields", "definitions_created", "definitions_evolved", "fuzzy_terms_added", "relations_changed", "references_changed", "snapshots_changed", "proposals", "change_requests", "conflict_records"}
    require_keys(document, required, "$")
    if document["schema_version"] != "1.0":
        fail("$.schema_version: expected 1.0")
    require_prefix(document["delta_id"], "delta_", "$.delta_id")
    require_prefix(document["project_id"], "project_", "$.project_id")
    if not isinstance(document["base_revision"], int) or not isinstance(document["target_revision"], int) or document["base_revision"] < 0 or document["target_revision"] < document["base_revision"]:
        fail("$: target_revision must be >= base_revision and both must be non-negative")
    require_date(document["created_at"], "$.created_at")
    seen: set[str] = set()
    for index, definition in enumerate(document["definitions_created"]):
        validate_definition(definition, document["project_id"], f"$.definitions_created[{index}]")
        if definition["id"] in seen:
            fail(f"$.definitions_created[{index}].id: duplicate stable ID")
        seen.add(definition["id"])
    for index, evolution in enumerate(document["definitions_evolved"]):
        validate_evolution(evolution, f"$.definitions_evolved[{index}]")
    for index, relation in enumerate(document["relations_changed"]):
        validate_relation(relation, document["project_id"], f"$.relations_changed[{index}]")
    removed_relations = document.get("relations_removed", [])
    if not isinstance(removed_relations, list):
        fail("$.relations_removed: expected an array")
    for index, relation in enumerate(removed_relations):
        validate_relation(relation, document["project_id"], f"$.relations_removed[{index}]")
    for index, change in enumerate(document["references_changed"]):
        item = require_object(change, f"$.references_changed[{index}]")
        require_keys(item, {"definition_id", "reference"}, f"$.references_changed[{index}]")
        require_prefix(item["definition_id"], "def_", f"$.references_changed[{index}].definition_id")
        validate_reference(item["reference"], f"$.references_changed[{index}].reference")
    for index, change in enumerate(document["snapshots_changed"]):
        item = require_object(change, f"$.snapshots_changed[{index}]")
        require_keys(item, {"definition_id", "snapshot"}, f"$.snapshots_changed[{index}]")
        require_prefix(item["definition_id"], "def_", f"$.snapshots_changed[{index}].definition_id")
        validate_snapshot_metadata(item["snapshot"], f"$.snapshots_changed[{index}].snapshot")
    for index, proposal in enumerate(document["proposals"]):
        validate_proposal(proposal, document["project_id"], f"$.proposals[{index}]")
    for index, request in enumerate(document["change_requests"]):
        validate_change_request(request, document["project_id"], f"$.change_requests[{index}]")
    for index, conflict in enumerate(document["conflict_records"]):
        validate_conflict(conflict, document["project_id"], f"$.conflict_records[{index}]")


def validate_file(path: Path) -> str:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{path}: cannot read JSON ({exc})")
    if not isinstance(document, dict):
        fail(f"{path}: root must be an object")
    reject_binary(document)
    if "delta_id" in document:
        validate_delta(document)
        return "delta"
    validate_snapshot(document)
    return "snapshot"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        for path in args.paths:
            kind = validate_file(path)
            print(f"VALID {path} kind={kind}")
    except ValidationError as exc:
        print(f"INVALID: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
