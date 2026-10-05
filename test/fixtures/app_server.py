#!/usr/bin/env python3
"""Protocol fixture, not evidence of a real Codex turn."""
import json, sys
for line in sys.stdin:
    m = json.loads(line)
    if 'id' not in m: continue
    method = m['method']
    if method == 'initialize': result = {'userAgent': 'fixture'}
    elif method == 'model/list': result = {'data': [{'model': 'fixture-model', 'isDefault': True}]}
    elif method == 'thread/start': result = {'thread': {'id': 'fixture-thread'}}
    elif method == 'thread/resume': result = {'thread': {'id': m['params']['threadId']}}
    elif method == 'turn/start':
        assert m['params']['model'] == 'fixture-model', 'Turn must use advertised model'
        result = {'turn': {'id': 'fixture-turn'}}
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
        print(json.dumps({'method':'turn/started','params':{'turn':{'id':'fixture-turn'}}}), flush=True)
        print(json.dumps({'method':'item/agentMessage/delta','params':{'itemId':'fixture-item','delta':'Fixture answer'}}), flush=True)
        print(json.dumps({'method':'turn/completed','params':{'turn':{'id':'fixture-turn','status':'completed'}}}), flush=True)
        continue
    else: result = {}
    print(json.dumps({'id':m['id'],'result':result}), flush=True)
