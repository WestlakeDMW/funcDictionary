#!/usr/bin/env python3
"""Run against an already launched --ui-testing app. Leaves evidence in .build/cli-smoke-* ."""
import json
from pathlib import Path
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parent.parent
workspace = root / ('.build/cli-smoke-' + uuid.uuid4().hex[:8])
workspace.mkdir()
(workspace / 'sample.py').write_text('def clamp(value, lower, upper):\n    return max(lower, min(value, upper))\n')
app = root / '.build/macos-derived/Build/Products/Debug/funcDictionaryMac.app'

def call(cli, *arguments):
    result = subprocess.run([sys.executable, str(cli), '--project', str(workspace), *arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return json.loads(result.stdout)

linked = call(root / 'script/funcdictionary.py', 'link', '--app', str(app), '--wait', '15')
assert linked['state'] == 'linked'
directory = workspace / '.funcdictionary'
view = json.loads((directory / 'dictionary.json').read_text())
project_id = view['project']['id']
definition = json.loads((root / 'SupportingFiles/fixtures/01-complete-definition.json').read_text())['definitions'][0]
definition.update(id='def_smoke_clamp', project_id=project_id, snapshots=[], implementation_history=[], fuzzy_terms=[], references=[], human_priority=None, lifecycle=None, change_heat=None)
definition['identity'] = {'canonical_name': 'sample.clamp', 'display_name': '数值范围限制', 'kind': 'function'}
definition['function'] = {'domain': '数值处理', 'purpose': '将输入数值限制在上下限范围内；返回限制后的数值，无外部副作用', 'actions': ['限制数值范围']}
definition['code_locator'] = {'symbol': 'clamp', 'symbol_type': 'function', 'func': 'clamp(value, lower, upper)', 'signature': 'def clamp(value, lower, upper)', 'owner': 'sample', 'file': 'sample.py', 'module': 'sample', 'line_hint': 1}
definition['functional_locator'] = {'domain': '数值处理', 'role': '限制数值范围', 'trigger': '函数调用'}
definition['visual_locator'] = {'screen': '', 'container': '', 'region': '', 'hierarchy': []}
delta = {'schema_version': '1.0', 'delta_id': 'delta_smoke_clamp', 'project_id': project_id, 'base_revision': view['revision'], 'target_revision': view['revision'] + 1, 'created_at': '2026-09-24T09:00:00Z'}
for key in ['changed_fields', 'definitions_created', 'definitions_evolved', 'fuzzy_terms_added', 'relations_changed', 'references_changed', 'snapshots_changed', 'proposals', 'change_requests', 'conflict_records']:
    delta[key] = []
delta['definitions_created'] = [definition]
source = directory / 'draft.json'
source.write_text(json.dumps(delta, ensure_ascii=False))
cli = directory / 'funcdictionary.py'
applied = call(cli, 'submit', str(source), '--wait', '15')
assert applied['state'] == 'applied'
for query, direction in [('clamp', 'code'), ('限制数值', 'purpose')]:
    assert len(call(cli, 'search', query, '--direction', direction)['matches']) == 1
status = call(cli, 'status')
assert status['definitions'] == 1 and status['revision'] == 1 and status['pending'] == []
# Relinking the same root must reuse project identity and existing definitions.
assert call(cli, 'link', '--app', str(app))['project_id'] == project_id
assert call(cli, 'status')['definitions'] == 1
print(json.dumps({'result': 'PASS', 'workspace': str(workspace), 'linked': linked, 'applied': applied, 'status': status}, ensure_ascii=False, indent=2))
