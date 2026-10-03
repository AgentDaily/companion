"""Isolated Gateway contract fixture. Never contacts a model or the real Gateway."""
import argparse
import asyncio
from uuid import uuid4
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
import uvicorn

app = FastAPI()
sessions = {}

def info(s):
    return {k: s[k] for k in ('id','agent_id','title','agent_name','updated_at','status')}

@app.get('/api/health')
def health(): return {'status': 'ok'}
@app.get('/api/agents')
def agents(): return [{'id': 'quenda-code', 'name': '测试 Agent'}]
@app.get('/api/workspaces')
def workspaces(): return [{'id':'test-workspace', 'name':'测试工作区'}]
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
@app.get('/api/sessions/{sid}/interactions')
def interactions(sid: str): return sessions[sid]['interactions']
@app.get('/test/stats/{sid}')
def stats(sid: str):
    s=sessions[sid]
    return {'commands':s['commands'], 'peers':len(s['peers'])}

def message(s, role, content): s['messages'].append({'id':uuid4().hex,'role':role,'content':content})
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
                content=command['content']; message(s,'user',content)
                await emit(s,'stream_start')
                if content=='slow':
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
