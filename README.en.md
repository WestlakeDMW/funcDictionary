<p align="center"><img src="Docs/Brand/funcDictionary-icon.png" width="144" alt="funcDictionary icon"></p>

# funcDictionary

**A queryable function dictionary for Vibe Coding, kept up to date as your code evolves.**

[中文](README.md) · [English](README.en.md) · [Installation](#installation) · [Agent integration](#agent-integration-and-continuous-updates)

funcDictionary is a native macOS app that connects a user's natural-language expressions and an AI agent's feature names to actual project functions. It provides a shared reference: **user wording → agreed names and aliases → stable entry ID → current implementation and call sites**.

During Vibe Coding, requests such as “sync the project” or “the refresh button in the top-right corner” often require an agent to search files, read code, and infer the intended component. Switching agents or starting a new conversation can repeat that work. funcDictionary stores established mappings in a project dictionary so the next agent can query existing definitions before locating code, aiming to reduce repeated discovery, context usage, and token consumption.

Reducing token use is a design goal, not a measured result: no savings percentage or comparative benchmark is available. Initial indexing still requires an agent to read the source. The benefit depends on dictionary quality and ongoing maintenance.

> **Status: an open-source MVP under the MIT license, distributed as source. No signed, notarized installer is provided yet.** macOS is the actively maintained platform. The app interface is primarily Chinese; this English README does not imply a fully localized interface.

## Features

| Feature | How it supports Vibe Coding |
| --- | --- |
| Project function dictionary | Stores shared feature names, purposes, human aliases, and stable IDs that different agents can reuse |
| Bidirectional lookup | Finds entries from descriptions, function names, aliases, or paths; explains the purpose behind a function |
| Global search | While the app is running, `⌘⇧Space` opens cross-project search with project groups and keyboard navigation |
| Implementation and call-site evidence | Shows current code locations and recorded direct callers; copies locator information for further work |
| Human annotations | Keeps your preferred wording, notes, and importance judgments for later agents |
| Rename and move history | Preserves stable identity, previous names, and change records across conversations |
| Agent data interface | Exports JSON dictionaries, context, protocol, validator, and CLI into the project for existing agent sessions |
| Incremental synchronization | Imports valid updates for linked, accessible projects while the app runs; queues files while closed and processes them on restart |

Global search runs locally using tokenization, identifier splitting, built-in Chinese/English synonyms, and weighted matching. It does not require a remote model call for every query. The CLI uses entry-field matching and does not reproduce the app's global-search ranking. Both rely on content already indexed in the dictionary.

## Installation

### Requirements

| Component | Requirement |
| --- | --- |
| Runtime | macOS 14 or newer; this is the deployment target, not a claim that every supported version has been tested |
| Build tools | Full Xcode 27 with the macOS SDK; the current `.icon` source uses Icon Composer 27 settings |
| Command line | Git; Python 3.9+ for the project CLI, with no additional Python dependencies |
| Agent | Your existing coding-agent session; its provider manages model authentication, quotas, and permissions |

Launch Xcode once and complete its component installation and license setup. Command Line Tools alone cannot replace full Xcode.

### Option 1: build and run from source

```sh
git clone https://github.com/WestlakeDMW/funcDictionary.git
cd funcDictionary
./script/build_and_run.sh
```

The script builds the `funcDictionaryMac` target and opens the app. Local code signing is disabled by default, so no Apple development team is required. The default build output is:

```text
.build/macos-derived/Build/Products/Debug/funcDictionaryMac.app
```

If you have several Xcode installations or the selected developer tools point to Command Line Tools, specify full Xcode for this run:

```sh
FUNC_DICTIONARY_XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh
```

Replace the path with the appropriate `Contents/Developer` directory if your Xcode installation has a different name or location.

### Option 2: use Xcode

1. Clone or download this repository.
2. Open `funcDictionary.xcodeproj` in full Xcode.
3. Select the **funcDictionaryMac** scheme and **My Mac** destination.
4. Choose **Product → Run** (`⌘R`).

Use the macOS scheme. The `funcDictionary` scheme belongs to the deferred iOS/Catalyst track.

### Keep the app in your Applications folder

After building successfully, reveal the output in Finder:

```sh
open .build/macos-derived/Build/Products/Debug
```

Drag `funcDictionaryMac.app` into your own `~/Applications` folder, creating that folder if needed. You can then launch it from Finder or Spotlight. This is a local development build, not a validated distribution installer. When linking projects for the first time, use the app copy you intend to keep.

### Updates and demo mode

From a clean source checkout, pull changes and rebuild. Commit or back up your own changes first:

```sh
git pull --ff-only
./script/build_and_run.sh
```

To explore sample content in an isolated demo:

```sh
FUNC_DICTIONARY_DEMO_DATA=1 FUNC_DICTIONARY_UI_TESTING=1 ./script/build_and_run.sh
```

This mode uses test settings and an in-memory database; it is not for persistent project dictionaries. Back up local app data and project exchange files before upgrading a normal installation.

## First use

1. Launch the app in normal mode. Click **添加项目** (Add Project) and select the source repository root.
2. Click **复制接入说明** (Copy Agent Instructions) and give them to your current agent.
3. Have the agent preserve existing project rules and connect the maintenance workflow to a Skill or `AGENTS.md` entry point it actually loads.
4. The agent reads existing functions and call sites, creates entries in batches, validates and submits them, and waits for the app's import confirmation.
5. Search descriptions, names, or aliases. Use **编辑说明** (Edit Notes) to add your preferred wording.

Adding a directory prepares a project and integration files; it does not automatically index the source. For large repositories, work by module and record completed and outstanding coverage.

While the app runs, `⌘⇧Space` opens cross-project search. You can also use **检索 → 全局功能检索…** (Search → Global Function Search, `⌘⇧K`). If another tool uses the global shortcut, use the menu. You can disable the system-wide shortcut in settings.

## Agent integration and continuous updates

Linking a project creates `.funcdictionary/` at its source root:

| File | Purpose |
| --- | --- |
| `AGENTS.md` | Instructions for indexing, querying, and completing coding tasks |
| `dictionary.json` | Latest app-exported full dictionary and revision |
| `agent-context.json` | Current selection and project context |
| `protocol.md`, JSON schemas, `validate_json.py` | Delta format and validation |
| `funcdictionary.py` | Project CLI for queries, status, and submissions |
| `deltas/`, `deltas/applied/` | Pending updates and applied receipts |

### Query existing definitions before locating code

Run these commands at the root of an already linked repository:

```sh
# Inspect the last exported revision, entry count, and pending imports
python3 .funcdictionary/funcdictionary.py --project . status

# Find a feature by purpose, or understand a named function
python3 .funcdictionary/funcdictionary.py --project . search '同步项目' --direction purpose
python3 .funcdictionary/funcdictionary.py --project . search 'startSync' --direction code

# Read the complete dictionary; output grows with the entry count
python3 .funcdictionary/funcdictionary.py --project . context
```

The purpose query above means “sync the project.” The built-in indexing workflow currently requests Chinese purpose descriptions. Use wording or aliases present in your dictionary; English function identifiers can be queried directly.

For routine lookup, use relevant `search` results to avoid inserting the entire dictionary into every conversation. Initial indexing and delta validation still require the complete data specified by the workflow. Query commands read local exports and can work offline; they do not prove the app or model provider is online.

### Finish coding by updating the dictionary

Connect this workflow to rules your agent actually executes: read the existing dictionary → change code → update affected entries, calls, and history → validate and submit → confirm import. Different agents and conversations reuse the same project's stable IDs, agreed names, and human annotations.

```sh
# The agent creates draft.json according to the exported protocol
python3 .funcdictionary/validate_json.py .funcdictionary/draft.json
python3 .funcdictionary/funcdictionary.py --project . submit .funcdictionary/draft.json --wait 30
```

The CLI returns JSON: exit code `0` means success, `1` means error, and `2` means pending app confirmation. A submission is imported only when it reports `state: applied`; `pending` is not completion. The app must be running and the project accessible. For stale revisions, reread the dictionary and recompute changes instead of forcing an overwrite. Concurrent agents must coordinate writes by revision.

Normal valid updates import automatically. Uncertain identity or conflicting content requires resolution while preserving human information and the last trusted definition. Previous names and stable identifiers support continuity after renames and moves.

**Exported files alone cannot force every agent to follow the workflow.** The host agent must load and execute it. Continuous handoff between real agents and automatic task completion without reminders still need end-to-end acceptance testing. See [Agent workflow](SupportingFiles/agent-workflow.md) and the [func-sync Skill](.agents/skills/func-sync/SKILL.md).

## Scope and data

- Functions without entries are not automatically discoverable. AI descriptions and call records depend on code evidence; missing call records do not mean a function is unused.
- Dictionaries, queries, and app storage are primarily local. `.funcdictionary/` can contain non-public code information and human notes: add it to the linked project's Git ignore rules. This repository already ignores that directory, databases, and build products.
- Your external agent controls authentication, costs, and data transmission. This project provides neither a hosted model service nor guaranteed token savings.
- Each project keeps independent data. Cross-project search aggregates local results without merging identities. Cross-agent and cross-conversation continuity refer to a shared project dictionary, not automatic cross-device synchronization.
- Production CloudKit synchronization has not been validated. iOS, iPadOS, and Mac Catalyst releases are deferred.
- Distribution installers still require your own app identifiers, signing, and notarization. JSON export is not a complete database backup or migration solution.

## Troubleshooting

**Missing SDKs, build tools, or icon compilation errors?** Use full Xcode 27, finish its first-launch setup, and specify the correct Developer directory as described above.

**No search results?** Check that the agent has indexed and submitted entries and that the app has imported them. Inspect the revision, aliases, and coverage. CLI field matching cannot guarantee a hit for every paraphrase.

**Submissions remain pending?** Open the app, check source-directory access and the project's synchronization status, and correct the reported error. Reread current data before submitting a replacement for a stale revision.

**How do I continue with another agent?** Give it the integration instructions and the same project dictionary. Reuse names, IDs, and human notes instead of creating a separate dictionary from scratch.

## Development and verification

```sh
./script/build_and_run.sh --test
python3 -m unittest discover -s script -p 'test_*.py'
./script/build_and_run.sh --verify
```

Builds, tests, UI interaction, search performance, and real-agent integration are verified separately. GitHub Actions currently runs CLI tests, not macOS UI or model tasks. See [Open-source readiness](Docs/OpenSourceReadiness.md).

| Path | Contents |
| --- | --- |
| `funcDictionaryMac/` | macOS SwiftUI UI, global search, agent integration, and delta watching |
| `funcDictionary/Domain/` | Domain models, search engines, revisions, and delta rules |
| `funcDictionary/Data/` | Core Data and other persistence adapters |
| `SupportingFiles/` | Schemas, synthetic fixtures, and agent workflow |
| `script/` | Build scripts, CLI, and verification |
| `funcDictionaryMac/funcDictionary.icon/` | Current Icon Composer source |

See the [simplified PRD](Docs/PRD-精简版.md) for product background. Historical documents describe their recorded versions only. Some supporting project documentation is currently Chinese.

## Contributing and license

[Issues](https://github.com/WestlakeDMW/funcDictionary/issues) and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and use synthetic data when reproducing problems. Report security issues privately as described in [SECURITY.md](SECURITY.md).

Code and included branding assets are available under the [MIT License](LICENSE). Third-party tools and trademarks retain their own licenses. This project is not officially affiliated with Apple or any agent-tool provider.
