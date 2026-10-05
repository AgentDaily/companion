"""Isolated Gateway contract fixture. Never contacts a model or the real Gateway."""
import argparse
import asyncio
import base64
from uuid import uuid4
from fastapi.responses import Response
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
import uvicorn

app = FastAPI()
sessions = {}
projects = [{"id": "test-workspace", "name": "测试工作区"}]
provider_documents = {}
attachment_bytes = {}

def info(s):
    return {k: s[k] for k in ('id','agent_id','title','agent_name','updated_at','status')}

@app.get('/api/health')
def health(): return {'status': 'ok'}
@app.get('/api/agents')
def agents(): return [{'id': 'quenda-code', 'name': '测试 Agent'}]
@app.get('/api/workspaces')
def workspaces(): return projects
@app.post('/api/workspaces')
def create_workspace(body: dict):
    project = {"id": uuid4().hex[:8], "name": body["name"], "path": body.get("path") or "/tmp/fixture/" + body["name"]}
    projects.append(project)
    return project
@app.get('/api/models')
def models(agent_id: str):
    doc = settings(agent_id)
    return [{"provider_id": p["id"], "provider_name": p["name"], "model_id": m["id"], "model_name": m["name"], "vision": m.get("vision", False)} for p in doc["providers"] for m in p["models"]]
@app.get('/api/models/settings/{agent_id}')
def settings(agent_id: str):
    return provider_documents.setdefault(agent_id, {"revision": "1", "providers": [{"id": "fixture", "name": "Fixture", "base_url": "http://127.0.0.1:9999/v1", "api": "openai-completions", "configured": False, "models": [{"id": "fixture-model", "name": "Fixture model", "vision": True}]}], "models": {}})
@app.put('/api/models/settings/{agent_id}')
def save_settings(agent_id: str, body: dict):
    doc = settings(agent_id)
    if doc["revision"] != body["revision"]: raise HTTPException(409, "Settings changed elsewhere")
    for pid, values in body["patch"].get("providers", {}).items():
        entry = next((p for p in doc["providers"] if p["id"] == pid), None)
        if entry is None:
            entry = {"id": pid, "models": []}; doc["providers"].append(entry)
        entry.update({k: v for k, v in values.items() if k != "api_key"})
        if values.get("api_key"): entry["configured"] = True
    doc["models"].update(body["patch"].get("models", {}))
    doc["revision"] = str(int(doc["revision"]) + 1)
    return doc
@app.get('/api/sessions')
def list_sessions(): return [info(s) for s in sessions.values()]
@app.post('/api/sessions')
def create(body: dict):
    s = dict(id=uuid4().hex, agent_id=body['agent_id'], title='测试会话', agent_name='测试 Agent', updated_at='2026-10-03T10:00:00Z', status='active', messages=[], interactions=[], history=[], peers=set(), commands=[], task=None)
    sessions[s['id']] = s
    return info(s)
@app.get('/api/sessions/{sid}/message-pages')
def messages(sid: str, limit: int = 50, before: int | None = None):
    s=sessions[sid]; end=len(s['messages']) if before is None else before; start=max(0,end-limit)
    return {'items':s['messages'][start:end], 'before':start, 'has_more':start>0}
@app.get('/api/sessions/{sid}/attachments/{aid}')
def attachment(sid: str, aid: str):
    if (sid, aid) not in attachment_bytes: raise HTTPException(404)
    data, media = attachment_bytes[(sid, aid)]
    return Response(data, media_type=media)
@app.get('/api/sessions/{sid}/interactions')
def interactions(sid: str): return sessions[sid]['interactions']
@app.get('/test/stats/{sid}')
def stats(sid: str):
    s=sessions[sid]
    return {'commands':s['commands'], 'peers':len(s['peers'])}

def message(s, role, content, attachments=()):
    metadata = [{"id": uuid4().hex[:8], "name": a["name"], "media_type": a["media_type"], "size": len(base64.b64decode(a["data"], validate=True))} for a in attachments]
    for a, m in zip(attachments, metadata): attachment_bytes[(s['id'], m['id'])] = (base64.b64decode(a['data']), a['media_type'])
    s['messages'].append({'id':uuid4().hex,'role':role,'content':content, 'attachments':metadata})
async def emit(s, kind, content='', remember=True):
    event={'type':kind,'content':content,'metadata':{'sequence':len(s['history'])}}
    if kind=='stream_start': s['history']=[]
    if remember: s['history'].append(event)
    for ws in list(s['peers']):
        try: await ws.send_json(event)
        except Exception: s['peers'].discard(ws)

async def slow(s):
    await asyncio.sleep(0.5)
    await emit(s,'stream_chunk','恢复后')
    message(s,'assistant','恢复前恢复后')
    s['task']=None
    await emit(s,'stream_end','恢复前恢复后',remember=False)

@app.websocket('/ws/sessions/{sid}')
async def socket(ws: WebSocket, sid: str):
    if sid not in sessions: await ws.close(code=1008); return
    await ws.accept(); s=sessions[sid]; s['peers'].add(ws)
    if s['task'] is not None:
        await ws.send_json({'type':'stream_start','content':'','metadata':{'resumed':True}})
        for e in s['history']:
            if e['type']!='stream_start': await ws.send_json(e)
    try:
        while True:
            command=await ws.receive_json(); s['commands'].append(command)
            kind=command['type']
            if kind=='user_message':
                content=command['content']; message(s,'user',content, command.get('attachments', []))
                await emit(s,'stream_start')
                if s['agent_id']=='24r-autonomous-test':
                    result = '## 今日总结\n自主分析完成：已结合心情、困难、进展和活动动线。'
                    await emit(s,'stream_chunk','我先检查活动记录，再分析心情。')
                    message(s,'assistant',result)
                    await emit(s,'stream_end',result,remember=False)
                elif content=='slow':
                    await emit(s,'stream_chunk','恢复前'); s['task']=asyncio.create_task(slow(s))
                elif content=='interaction':
                    interaction={'id':'interaction-1','kind':'select','title':'选择服务','message':'请选择','questions':[{'id':'question-1','kind':'select','title':'服务','message':'翻译还是总结？','required':True,'multiple':False,'options':[{'id':'translate','label':'翻译'},{'id':'summary','label':'总结'}]}]}
                    s['interactions']=[interaction]
                    await emit(s,'interaction_requested',interaction,remember=False)
                else:
                    await emit(s,'stream_chunk','你好，')
                    await emit(s,'permission_requested',{'id':'permission-1','request':{'description':'测试工具','tool_name':'test_tool'}})
            elif kind=='permission_response':
                allowed=command['decision']=='allow'
                await emit(s,'permission_resolved',{'id':command['request_id'],'allowed':allowed})
                content='你好，世界' if allowed else '你好，已取消'
                await emit(s,'stream_chunk','世界' if allowed else '已取消')
                message(s,'assistant',content); await emit(s,'stream_end',content,remember=False)
            elif kind=='interaction_response':
                s['interactions']=[]; message(s,'user','服务：翻译')
                await emit(s,'stream_start'); message(s,'assistant','已选择翻译')
                await emit(s,'stream_end','已选择翻译',remember=False)
            elif kind=='interrupt':
                if s['task'] is not None: s['task'].cancel(); s['task']=None
                message(s,'assistant','恢复前'); await emit(s,'stream_interrupted',remember=False)
    except WebSocketDisconnect: pass
    finally: s['peers'].discard(ws)

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--port',type=int,required=True); args=parser.parse_args()
    uvicorn.run(app,host='127.0.0.1',port=args.port,log_level='error')
