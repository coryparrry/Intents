#!/usr/bin/env python3
"""Regression coverage for the standalone app engine boundary and real app traces."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import select
import signal
import time
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import uuid

binary = sys.argv[1]
infer = '--infer' in sys.argv[2:]
checks = 0

def check(value, detail=''):
    global checks
    assert value, detail
    checks += 1

def invoke(payload):
    process = subprocess.run([binary], input=json.dumps(payload), text=True,
                             capture_output=True, timeout=180, check=True)
    check(len(process.stdout.strip().splitlines()) == 1, process.stdout[:500])
    return json.loads(process.stdout)

def uid(): return str(uuid.uuid4())
def case(prompt='Reply with exactly READY', expected='READY'):
    return {'id':uid(), 'name':'standalone app engine', 'prompt':prompt, 'expected':expected}
def base():
    suite = copy.deepcopy(defaults)
    suite.update(scoringMode='exactMatch', criteria='', instructions='Follow the prompt exactly.', cases=[case()])
    suite['modelConfiguration'].update(samplingMode='greedy', maximumResponseTokens=128,
        customization={'useCase':'general','guardrails':'standard','schemaPrompt':'included',
                       'toolCalling':'automatic','saveFullTranscript':True})
    return suite

def evidence(run):
    check('appRun' in run, run.get('error'))
    check(len(run['appRun']['results']) == len(run['results']))
    sample = run['appRun']['results'][0]
    check(sample == run['results'][0]['trace']['appSample'])
    check(sample.get('workflowTrace',{}).get('timingSource') == 'App-observed monotonic clock')
    check(len(sample['workflowTrace']['spans']) > 1)
    if infer:
        check(sample.get('errorCategory') is None, sample.get('errorMessage'))
        check(sample['usage']['inputTokens'] > 0)
        check(sample['usage']['outputTokens'] > 0)
        trace = sample['featureTrace']['transcript']
        check(trace['format'] == 'com.apple.FoundationModels.Transcript+json')
        transcript = json.loads(base64.b64decode(trace['transcriptJSON']))
        check(trace['entryCount'] > 0)
        check(len(run['results'][0]['trace']['transcript']) > 0)
        return sample, transcript
    return sample, None

def field(name, kind='string', **extra):
    return {'id':uid(),'name':name,'description':'Required '+name,'type':kind,'isOptional':False, **extra}

def tool(mode='fixture', endpoint=''):
    return {'id':uid(),'name':'getReadyWord','description':'Get the authoritative word READY.',
            'parameters':[],'schemaDefinitions':[],'mode':mode,'fixtureResponse':'READY','endpoint':endpoint}

availability = invoke({'operation':'availability'})
check(isinstance(availability.get('capabilities',{}).get('appEngine',{}).get('available'),bool))
defaults = invoke({'operation':'suite-defaults'})
check(defaults.get('modelConfiguration',{}).get('provider') == 'onDevice',defaults)
for provider in ['privateCloudCompute','customHTTP','coreAI']:
    suite=base();suite['modelConfiguration']['provider']=provider
    validation=invoke({'operation':'validate-suite','suite':suite})
    check(validation['valid'] is False,validation)
    check(validation['issue']=='Only the on-device Apple Foundation Model is supported.',validation)
    result=invoke({'operation':'evaluate','suite':suite})
    check(result['status']=='failed' and result['error']['kind']=='invalidInput',result)
    check(result['error']['message']=='Only the on-device Apple Foundation Model is supported.',result)
    check(result['results']==[] and 'appRun' not in result,result)
suite=base();suite['judgeConfiguration']['mode']='connection'
check(not invoke({'operation':'validate-suite','suite':suite})['valid'])
# An enabled profile supplies its own tool policy; inactive legacy policy must not block it.
for enabled, require_tool, valid in [(True, False, True), (True, True, False), (False, False, False)]:
    suite=base()
    suite['modelConfiguration']['customization']['toolCalling']='required'
    suite['features']['tools']=[]
    suite['features']['profile'].update(enabled=enabled, requireToolFirst=require_tool)
    result=invoke({'operation':'validate-suite','suite':suite})
    check(result['valid'] is valid,result)
suite=base();suite['repetitions']=6
check(not invoke({'operation':'validate-suite','suite':suite})['valid'])
suite=base();suite['features']['tools']=[tool('localHTTP','https://example.com/tool')]
check(not invoke({'operation':'validate-suite','suite':suite})['valid'])
suite=base();suite['features']['tools']=[tool('localHTTP','http://127.0.0.1:17873/tool')]
check(invoke({'operation':'validate-suite','suite':suite})['valid'])
suite=base();suite['cases'][0]['fieldAssertions']=[{'id':uid(),'pointer':'invalid','operation':'equals','expectedValue':'7'}]
check(not invoke({'operation':'validate-suite','suite':suite})['valid'])
suite=base();suite['features']['outputFields']=[field('answer','object',children=[field('value','integer',constraints={'integerMinimum':7,'integerMaximum':7})])]
suite['cases'][0]['fieldAssertions']=[{'id':uid(),'pointer':'/answer/value','operation':'equals','expectedValue':'7'}]
valid=invoke({'operation':'validate-suite','suite':suite})
check(valid['valid'],valid)
check(len(valid['revision'])==64)
exported=invoke({'operation':'export-suite','suite':suite})
check(uuid.UUID(exported['features']['outputFields'][0]['id']) == uuid.UUID(suite['features']['outputFields'][0]['id']))
check(exported['features']['outputFields'][0]['children'][0]['constraints']['integerMinimum'] == 7)
check(exported['features']['outputFields'][0]['children'][0]['constraints']['integerMaximum'] == 7)
check(exported['cases'][0]['fieldAssertions'][0]['pointer'] == '/answer/value')
check(exported['cases'][0]['fieldAssertions'][0]['expectedValue'] == '7')
check(uuid.UUID(exported['cases'][0]['fieldAssertions'][0]['id']) == uuid.UUID(suite['cases'][0]['fieldAssertions'][0]['id']))

with tempfile.TemporaryDirectory(prefix='app-eval-reference-') as directory:
    file=Path(directory)/'reference.txt';data=('READY '+ 'x'*17000).encode();file.write_bytes(data)
    output=invoke({'operation':'extract-reference','fileURL':file.as_uri(),'name':file.name,'mimeType':'text/plain'})
    check(output['truncated'] and output['text'].endswith('[File truncated during import.]'))
    check(output['sha256']==hashlib.sha256(data).hexdigest() and output['byteCount']==len(data))
    # Small valid text PDF; exercises PDFKit extraction, not a text substitute.
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    content=b'BT /F1 12 Tf 36 100 Td (Reference READY) Tj ET';objects.append(b'<< /Length '+str(len(content)).encode()+b' >>\nstream\n'+content+b'\nendstream')
    pdf=b'%PDF-1.4\n';offsets=[]
    for index,obj in enumerate(objects,1):offsets.append(len(pdf));pdf+=str(index).encode()+b' 0 obj\n'+obj+b'\nendobj\n'
    start=len(pdf);pdf+=b'xref\n0 6\n0000000000 65535 f \n'+b''.join(f'{offset:010d} 00000 n \n'.encode() for offset in offsets)+b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n'+str(start).encode()+b'\n%%EOF\n'
    file=Path(directory)/'reference.pdf';file.write_bytes(pdf)
    output=invoke({'operation':'extract-reference','fileURL':file.as_uri(),'name':file.name,'mimeType':'application/pdf'})
    check('Reference READY' in output['text'],output)
    check(output['attachment']['kind']=='text' and not output['truncated'])
    file=Path(directory)/'invalid.pdf';file.write_bytes(b'not a PDF')
    output=invoke({'operation':'extract-reference','fileURL':file.as_uri(),'name':file.name,'mimeType':'application/pdf'})
    check(output['status']=='failed')

if infer:
    check(availability['available'],availability)
    suite=base();suite['features'].update(prewarm=True,streamResponse=True)
    run=invoke({'operation':'evaluate','suite':suite});sample,transcript=evidence(run)
    check(run['status']=='completed' and run['results'][0]['passed'],run.get('error'))
    check(sample['featureTrace']['firstContentMilliseconds'] >= 0)
    check(any(span['metadata'].get('operation')=='prewarm' for span in sample['workflowTrace']['spans']))
    check(invoke({'operation':'analyze-run','run':run['appRun']}) == run['analysis'])
    suite=base();suite['cases'][0]['conversation']={'setupTurns':[{'id':uid(),'prompt':'Remember that the secret color is ORANGE. Reply OK.'}],
      'historyPolicy':'retainRecentCompleteTurns','retainedTurnCount':1}
    suite['cases'][0].update(prompt='What is the secret color? Reply with exactly the color.',expected='ORANGE')
    run=invoke({'operation':'evaluate','suite':suite});sample,_=evidence(run)
    check(sample['featureTrace']['conversation']['turns'][0]['kind']=='setup')
    check(len(sample['featureTrace']['conversation']['turns'])==2)
    suite=base();suite['cases'][0]['conversation']={'setupTurns':[],'restoredTranscriptJSON':json.dumps(transcript),
      'historyPolicy':'keepAll','retainedTurnCount':2}
    run=invoke({'operation':'evaluate','suite':suite});sample,_=evidence(run)
    check(sample['featureTrace']['conversation']['restoredEntryCount'] > 0)
    suite=base();suite['scoringMode']='containsExpected';suite['cases']=[case('Return answer.value as the integer 7.','7')]
    suite['features']['outputFields']=[field('answer','object',children=[field('value','integer',constraints={'integerMinimum':7,'integerMaximum':7})])]
    assertion={'id':uid(),'pointer':'/answer/value','operation':'equals','expectedValue':'7'}
    suite['cases'][0]['fieldAssertions']=[assertion]
    failure=copy.deepcopy(suite['cases'][0]);failure['id']=uid();failure['fieldAssertions']=[{**assertion,'id':uid(),'expectedValue':'8'}];suite['cases'].append(failure)
    run=invoke({'operation':'evaluate','suite':suite});sample,_=evidence(run)
    check(sample['fieldAssertionResults'][0]['passed'])
    check(run['appRun']['results'][1]['fieldAssertionResults'][0]['passed'] is False)
    check(run['appRun']['results'][1]['status']=='failed')
    suite=base();suite['features']['tools']=[tool()];suite['features']['profile'].update(enabled=True,requireToolFirst=True,afterToolInstructions='Reply exactly with the word returned by the tool.')
    suite['cases']=[case('Call getReadyWord and reply with exactly its returned word.')]
    run=invoke({'operation':'evaluate','suite':suite});sample,_=evidence(run)
    check(len(sample['featureTrace']['customToolCalls'])==1)
    check(sample['featureTrace']['customToolCalls'][0]['output']=='READY')
    check(len(sample['featureTrace']['profileEvents']) > 0)
    requests=[]
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            self.send_response(200);self.send_header('Content-Type','text/plain');self.send_header('Content-Length','5');self.end_headers();self.wfile.write(b'READY')
        def log_message(self,*args): pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        suite=base();suite['features']['tools']=[tool('localHTTP',f'http://127.0.0.1:{server.server_port}/tool')]
        suite['features']['profile'].update(enabled=True,requireToolFirst=True,afterToolInstructions='Reply exactly with the word returned by the tool.')
        suite['cases']=[case('Call getReadyWord and reply with exactly its returned word.')]
        run=invoke({'operation':'evaluate','suite':suite});sample,_=evidence(run)
        check(requests and requests[0]['toolName']=='getReadyWord')
        check(sample['featureTrace']['customToolCalls'][0]['output']=='READY')
        check(any(span['kind']=='httpRequest' for span in sample['workflowTrace']['spans']))
    finally: server.shutdown();server.server_close()
    suite=base();suite['scoringMode']='modelJudge';suite['criteria']='The response supplies the requested word without unrelated text.'
    run=invoke({'operation':'evaluate','suite':suite});sample,_=evidence(run)
    check(sample['judgeTrace']['rawResponse'])
    check(sample['judgeTrace']['attempts'])
    check(sample['judgeUsage']['outputTokens'] > 0)
    suite=base();suite['cases']=[case() for _ in range(100)];suite['features']['streamResponse']=True
    process=subprocess.Popen([binary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    process.stdin.write(json.dumps({'operation':'evaluate','suite':suite,'emitEvents':True}));process.stdin.close();process.stdin=None
    observed=[];deadline=time.monotonic()+60;completed=None
    try:
        while time.monotonic()<deadline:
            ready,_,_=select.select([process.stderr],[],[],max(0,deadline-time.monotonic()))
            if not ready:break
            line=process.stderr.readline()
            if not line:break
            value=json.loads(line);observed.append(value)
            if value.get('event')=='sample':completed=value;break
        check(completed is not None,'No real completed sample event arrived.')
        check(any(value.get('event')=='liveResponse' and value['value']['content'] for value in observed))
        check(completed['completed']==1 and completed['total']==100)
        check(completed['result']['status']=='passed')
        signalled=time.monotonic();process.send_signal(signal.SIGTERM)
        output,diagnostics=process.communicate(timeout=5)
        elapsed=time.monotonic()-signalled
        check(process.returncode==0,diagnostics)
        check(elapsed<3,f'Cooperative cancellation took {elapsed:.3f}s, exceeds host grace.')
        cancelled=json.loads(output)
        check(cancelled['status']=='cancelled' and cancelled['appRun']['cancelled'])
        check(len(cancelled['appRun']['results'])<100)
        check(cancelled['appRun']['results'][0]==completed['result'])
        check(cancelled['analysis']['missingSampleCount']>0)
        print(f'Actual cooperative cancellation: {elapsed:.3f}s; retained samples={len(cancelled["appRun"]["results"])}')
    finally:
        if process.poll() is None:process.kill();process.wait()
print(f'App engine protocol: {checks} assertions passed; inference={infer}')
