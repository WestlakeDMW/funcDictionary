# funcDictionary exchange protocol 1.0

## Files

The `.funcdictionary` directory is project-local:

```text
.funcdictionary/
├── project.json
├── definitions.json
├── clusters.json
├── dictionary.json        # authoritative CLI read model (ProjectSnapshot)
├── AGENTS.md              # app-bundled Agent workflow
├── funcdictionary.py      # link/status/search/context/submit
├── coverage.json          # agent-authored scan coverage
├── agent-context.json
├── snapshot.json
├── snapshots/*.jpg
└── deltas/delta_<stable-id>.json
```

JSON is UTF-8, ISO-8601 for dates, snake_case for synthesized keys, and
sorted by key before writing. Images remain files; JSON carries only metadata.

## Stable identity

`Definition.id` is the stable identity. A rename, file move, symbol move, or
signature change updates locators and appends implementation history while
preserving that ID; retain the previous natural-language name as an alias.
When identity or human-authored meaning is genuinely unclear, preserve the last
trusted value and include a `ConflictRecord` for resolution in the Definition
detail.

`CodeLocator.function` is encoded as `code_locator.func`. The agent context
property `currentFunction` is encoded as `current_func`. These two spellings
are part of the exchange contract. `CodeLocator.comment` is encoded as
`func_comment` and carries a human-written one-line note shown beside the func
in the dictionary; evolve it with the change key `code_locator.func_comment`.

Direct calls use a `calls` relation directed from caller
(`source_definition_id`) to callee (`target_definition_id`). Each relation
records a relative `metadata.file`, positive `metadata.line`, and concise
`metadata.evidence`. Emit one relation per distinct call site. Generic `uses`
or `depends_on` relations do not stand in for observed direct calls.

## Snapshot

A snapshot contains `schema_version`, `project`, `definitions`, `clusters`,
`agent_context`, `revision`, and `generated_at`. Every definition must belong
to the snapshot project. Snapshot files use relative paths of the exact form
`snapshots/<filename>.jpg`; `perceptual_hash` and dimensions are metadata.

## Dictionary Delta

A Delta contains:

- `delta_id`, `project_id`, `base_revision`, `target_revision`, and `created_at`;
- `changed_fields`;
- `definitions_created` and `definitions_evolved`;
- `fuzzy_terms_added`, `relations_changed`, `relations_removed`, `references_changed`, and
  `snapshots_changed`;
- `proposals`, `change_requests`, and `conflict_records`.

`target_revision` must be at least `base_revision`. App import rejects another
project, a stale base revision, invalid schema, or an unsafe path. Reapplying
the same `delta_id` is a no-op. Conflicts are attached to the affected
Definition and can be resolved there. Empty evolution values clear editable
text fields; required values such as canonical name remain enforced by domain
validation.

When a call site is removed from code, include the former full relation in
`relations_removed`; when its location or evidence changes, upsert it through
`relations_changed`. The app records both operations in the caller's history.

Each reference or snapshot change carries its owning `definition_id` together
with the changed value, so an import can update the correct Definition without
guessing from a global array.
