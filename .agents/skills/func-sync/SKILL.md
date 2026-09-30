---
name: func-sync
description: Keep the current project funcDictionary up to date. Use at the end of any coding task that changes functions, methods, or direct call sites, as well as when the user asks to sync definitions or uses $func-sync or /func-sync.
---

# func-sync

Use this skill proactively at the end of any coding task that changes functions,
methods, signatures, locations, or direct call sites. Also use it for an
explicit dictionary-sync request. Read only the current Project and its
`.funcdictionary` directory, plus project files needed to explain completed
implementation changes. Do not inspect other repositories or invent an
external project context.

## Invocation semantics

- `$func-sync` is the official Skill invocation.
- `/func-sync` is a product-language and user-intent alias. It is not a
  registered custom Slash Command; do not claim that it is one.
- “同步词典”, “同步 funcDictionary”, and “生成 Dictionary Delta” are also
  matching intents.

## Required result

Produce a `DictionaryDelta` JSON object with `schema_version: "1.0"`, stable
`delta_id`, `project_id`, `base_revision`, `target_revision`, changed fields,
and the typed arrays required by the protocol. Write only through the current
project's `.funcdictionary/deltas/` exchange directory when a file is needed.
Run the validator before returning the file:

```text
python3 .agents/skills/func-sync/scripts/validate_json.py path/to/delta.json
```

Use the protocol summary in [references/protocol.md](references/protocol.md)
for the field names and invariants. The validator is standard-library-only and
must be run on every generated or modified exchange JSON.

## Real-time sync (watched directory)

The macOS app watches every linked project's `.funcdictionary/deltas/`
directory and applies valid Delta files automatically. Work with it instead of
asking a human to import files:

- After code edits that add or change dictionary elements, and before ending
  the turn, generate a Dictionary Delta and write it to
  `.funcdictionary/deltas/delta_<stable-id>.json`.
- Read the `revision` from `.funcdictionary/agent-context.json` first and use
  it as `base_revision` (`base_revision + 1` becomes `target_revision` unless
  batching further changes).
- Run the validator before writing; an invalid file stays unapplied.
- The app applies the file, archives it under `deltas/applied/`, and refreshes
  `agent-context.json`. A stale `base_revision` is rejected: re-read the
  refreshed context and emit a corrected Delta instead of retrying the old
  one.
- Never rewrite or reuse an already-applied `delta_id`; generate a new one
  for each change batch.

For direct call relationships, use `type: calls` from caller
(`source_definition_id`) to callee (`target_definition_id`). Put the relative
call-site path, positive line number, and short evidence in `metadata.file`,
`metadata.line`, and `metadata.evidence`. Record each distinct call site. Do not
infer direct calls from general-purpose dependencies or write an edge without
code evidence.
When a call disappears, send the former full relation in `relations_removed`;
when its file or line changes, upsert it through `relations_changed`.

## Safety and governance boundaries

- Never replace a Delta with a free-form dictionary, prose-only result, or
  embedded Base64 image.
- Snapshot metadata uses relative `snapshots/<name>.jpg` paths. Never put an
  absolute local path, security-scoped bookmark, or screenshot bytes in shared
  JSON.
- Preserve `Definition.id` across confirmed rename, move, and signature changes;
  update the locator and history, and retain the old name as a human alias.
  Do not guess when the new implementation's identity is unclear. Preserve the
  last trusted definition and submit a `ConflictRecord` for in-app resolution.
- Keep new definitions `unreviewed`, preserve human notes, aliases, and
  importance judgments, and never mark an item approved on the user's behalf.
- The Skill does not control arbitrary agents. The host agent must load the
  project instructions and run this workflow at the end of the coding task.

## Verification handoff

Report the generated path, validator result, base/target revisions, and any
unverified assumptions. A caller that imports the Delta must still enforce
projectID, baseRevision, deltaID idempotency, transaction rollback, and
ConflictRecord routing at the app boundary.

## Repository dictionary bootstrap

When `.funcdictionary/AGENTS.md` exists, read it and `dictionary.json` before
scanning or updating functions. The app exports the complete Agent workflow,
validator, schemas and CLI to every associated repository. First-time indexing
must cover existing functions, methods and overloads, not just recent changes.
Read implementations and callers; record evidence, Chinese purposes, stable
identities, and incomplete coverage. Preserve human comments and importance
judgments. Confirmed code refactors should update the existing Definition
without a routine approval step.

Prefer the following over direct inbox writes:

```sh
python3 .funcdictionary/funcdictionary.py --project . submit .funcdictionary/draft.json --wait 30
```

Exit code 2 and `state: pending` mean the app has not acknowledged import.
Wait for applied, then reread the complete dictionary before another batch.
