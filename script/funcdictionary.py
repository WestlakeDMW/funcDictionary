#!/usr/bin/env python3
"""Project-local CLI for funcDictionary. Requires Python 3.9+, no dependencies."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def exchange(root):
    directory = root / ".funcdictionary"
    if directory.is_symlink() or directory.resolve().parent != root:
        raise ValueError("Exchange directory must stay inside the selected project")
    return directory


def dictionary(root):
    directory = exchange(root)
    data = read_json(directory / "dictionary.json")
    project = read_json(directory / "project.json")
    if data["project"]["id"] != project["id"]:
        raise ValueError("Project mismatch; relink in the app")
    return data


def load_validator():
    own = Path(__file__).resolve()
    candidates = [own.with_name("validate_json.py"),
                  own.parent.parent / ".agents/skills/func-sync/scripts/validate_json.py"]
    path = next((path for path in candidates if path.is_file()), None)
    if path is None:
        raise ValueError("Missing validator; prepare the Agent package in the app")
    spec = importlib.util.spec_from_file_location("funcdictionary_validator", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def search(data, query, direction="both"):
    terms = query.casefold().split()
    if not terms:
        return []
    matches = []
    for definition in data["definitions"]:
        locator = definition["code_locator"]
        code = [definition["id"], *definition["identity"].values(),
                *(locator.get(key, "") for key in ("symbol", "func", "signature", "owner", "file", "module"))]
        purpose = [*definition["function"].values(), *definition["functional_locator"].values(),
                   locator.get("func_comment", ""), *(term["text"] for term in definition["fuzzy_terms"])]
        fields = code if direction == "code" else purpose if direction == "purpose" else code + purpose
        texts = [str(value).casefold() for value in fields]
        if all(any(term in text for text in texts) for term in terms):
            score = sum(3 if term in texts else 1 for term in terms)
            matches.append((score, definition))
    return [value for _, value in sorted(matches, key=lambda item: (-item[0], item[1]["id"]))]


def submit(root, source, wait):
    directory = exchange(root)
    validator = load_validator()
    # Read exactly once; validate the bytes that will actually be published.
    payload = read_json(source)
    validator.reject_binary(payload)
    validator.validate_delta(payload)
    data = dictionary(root)
    if payload["project_id"] != data["project"]["id"]:
        raise ValueError("Delta belongs to another project")
    delta_id = payload["delta_id"]
    if not re.fullmatch(r"delta_[A-Za-z0-9_-]+", delta_id):
        raise ValueError("Unsafe delta_id")
    inbox = directory / "deltas"
    if inbox.is_symlink() or (inbox / "applied").is_symlink():
        raise ValueError("Delta directories must not be symlinks")
    destination = inbox / (delta_id + ".json")
    archived = inbox / "applied" / destination.name
    if archived.exists():
        if read_json(archived) != payload:
            raise ValueError("Applied delta_id cannot be reused for different content")
        if data["revision"] >= payload["target_revision"]:
            return {"state": "applied", "delta_id": delta_id, "revision": payload["target_revision"]}
        return {"state": "pending", "delta_id": delta_id, "message": "Applied receipt exists; waiting for app read-model refresh"}
    if payload["base_revision"] != data["revision"]:
        raise ValueError("Stale base_revision; reread dictionary.json and rebase")
    if payload["target_revision"] != payload["base_revision"] + 1:
        raise ValueError("Each Agent batch must advance revision by exactly one")
    existing = {item["id"] for item in data["definitions"]}
    for item in payload["definitions_created"]:
        if item["id"] in existing:
            raise ValueError("Existing definitions must evolve, not be recreated")
        if item["review_status"] != "unreviewed":
            raise ValueError("Agent-created definitions must be unreviewed")
        location = item["code_locator"]["file"]
        if location and (Path(location).is_absolute() or not (root / location).resolve().is_relative_to(root)):
            raise ValueError("Code locators must stay inside the project")
    for key in ("proposals", "change_requests"):
        if any(item["status"] != "pending" for item in payload[key]):
            raise ValueError("Agents cannot approve governance requests")
    inbox.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if read_json(destination) != payload:
            raise ValueError("Pending delta_id already has different content")
    else:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".pending-", dir=inbox, delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            # Exclusive publication: concurrent submitters cannot overwrite an ID.
            os.link(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
    deadline = time.monotonic() + wait
    while True:
        if archived.exists() and dictionary(root)["revision"] >= payload["target_revision"]:
            return {"state": "applied", "delta_id": delta_id, "revision": payload["target_revision"]}
        if time.monotonic() >= deadline:
            return {"state": "pending", "delta_id": delta_id,
                    "message": "Open this project in the app with auto-sync enabled; inspect sync errors if pending persists"}
        time.sleep(0.2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path.cwd(), help="Repository root (default: current directory)")
    commands = parser.add_subparsers(dest="command", required=True)
    link = commands.add_parser("link", help="Open the app and associate this repository")
    link.add_argument("--app", help="App bundle path, useful for a local build")
    link.add_argument("--wait", type=float, default=15)
    commands.add_parser("status", help="Read project identity, exported revision and pending imports")
    commands.add_parser("context", help="Read complete dictionary and selected function context")
    find = commands.add_parser("search", help="Find functions by code name or natural-language purpose")
    find.add_argument("query")
    find.add_argument("--direction", choices=["both", "code", "purpose"], default="both")
    add = commands.add_parser("submit", help="Validate and atomically publish an Agent delta")
    add.add_argument("file", type=Path)
    add.add_argument("--wait", type=float, default=0)
    args = parser.parse_args()
    try:
        root = args.project.expanduser().resolve(strict=True)
        if not root.is_dir():
            raise ValueError("Project must be a directory")
        directory = exchange(root)
        if args.command == "link":
            started = time.time_ns()
            url = "funcdictionary://link?" + urlencode({"path": str(root)})
            command = ["/usr/bin/open"] + (["-a", args.app] if args.app else []) + [url]
            subprocess.run(command, check=True)
            deadline = time.monotonic() + max(0, args.wait)
            while time.monotonic() < deadline:
                view = directory / "dictionary.json"
                if view.is_file() and view.stat().st_mtime_ns >= started:
                    data = dictionary(root)
                    print(json.dumps({"state": "linked", "project_id": data["project"]["id"],
                                      "agent_instructions": str(directory / "AGENTS.md")}, ensure_ascii=False))
                    return 0
                time.sleep(0.2)
            print(json.dumps({"state": "pending", "message": "App has not confirmed linking; check its error message"}))
            return 2
        if args.command == "submit":
            result = submit(root, args.file, max(0, args.wait))
        else:
            data = dictionary(root)
            if args.command == "context":
                result = data
            elif args.command == "search":
                result = {"project_id": data["project"]["id"], "revision": data["revision"],
                          "matches": search(data, args.query, args.direction)}
            else:
                result = {"project_id": data["project"]["id"], "revision": data["revision"],
                          "definitions": len(data["definitions"]),
                          "pending": sorted(path.name for path in (directory / "deltas").glob("*.json")),
                          "message": "Last app export; this does not prove the app or model provider is online"}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 2 if isinstance(result, dict) and result.get("state") == "pending" else 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(json.dumps({"state": "error", "message": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
