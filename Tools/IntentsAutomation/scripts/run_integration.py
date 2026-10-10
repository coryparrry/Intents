#!/usr/bin/env python3
"""Owned M0 engineering runner: real UI -> scoped release -> Apple -> positive UI read.

This is an explicit approved-profile tool, not the product coordinator or a
general business assessor. It never counts an incomplete tree or saved report
as successful execution.
"""
import argparse, base64, hashlib, json, os, plistlib, re, subprocess, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
NODE = ROOT / 'Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node'
UI = ROOT / 'Tools/IntentsAutomation/dist/src/qualificationUI.js'

def read_json(path, maximum=65536):
    if path.stat().st_size > maximum: raise ValueError('Input exceeds byte budget')
    return json.loads(path.read_text())

def canonical(path):
    value = Path(path)
    if not value.is_absolute() or value.resolve() != value: raise ValueError('Canonical absolute path required')
    return value

def product_digest(app):
    records = []
    for file in sorted(app.rglob('*')):
        if file.is_symlink(): raise ValueError('Unqualified product symlink')
        if file.is_file():
            records.append({'path':str(file.relative_to(app)), 'sha256':hashlib.sha256(file.read_bytes()).hexdigest(), 'bytes':file.stat().st_size})
    return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(',',':')).encode()).hexdigest()

def signature_arrangement(app):
    try:
        subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True,timeout=15)
        details=subprocess.run(['/usr/bin/codesign','-dv',str(app)],check=True,capture_output=True,text=True,timeout=15).stderr
    except (subprocess.SubprocessError,OSError) as error: raise ValueError('Artifact signature verification failed') from error
    team=re.search(r'^TeamIdentifier=([A-Z0-9]{10})$',details,re.MULTILINE)
    if not team:
        if re.search(r'^Signature=adhoc$',details,re.MULTILINE) and re.search(r'^TeamIdentifier=not set$',details,re.MULTILINE): return 'simulator-ad-hoc'
        raise ValueError('Resolved signing identity required')
    return team.group(1)

def command(arguments, log, timeout):
    # Only the direct owned child is terminated on deadline. A timed-out Xcode
    # runner never authorizes readback or a controller handoff.
    with log.open('wb') as output:
        child = subprocess.Popen(arguments, stdout=output, stderr=subprocess.STDOUT, env={
            'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':os.environ['HOME'], 'TMPDIR':'/private/tmp'})
        try: return child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=5)
            raise ValueError('Owned child deadline expired; controller termination is unproved')

def preflight(profile):
    checked=subprocess.run([str(NODE),str(UI.parent/'qualificationPreflight.js'),'--stdin'],input=json.dumps(profile).encode(),capture_output=True,timeout=15)
    if checked.returncode: raise ValueError('Frozen UI plan failed pure preflight; no device effect is permitted')

def validate_host(host):
    keys={'schemaVersion','runID','attemptID','segmentID','leaseGeneration','bundleID','productDigest','operations'}
    if set(host)!=keys or type(host['schemaVersion']) is not int or host['schemaVersion']!=1 or type(host['leaseGeneration']) is not int or host['leaseGeneration']<1: raise ValueError('Malformed host scope')
    operations=host['operations']
    if not isinstance(operations,list) or not 1<=len(operations)<=10: raise ValueError('Host operation budget exceeded')
    ids=set()
    for operation in operations:
        if not isinstance(operation,dict) or not {'id','kind','typeID','parameters'}<=set(operation) or not set(operation)<={'id','kind','typeID','parameters','resultCodec','queryText','queryIDs','properties'}: raise ValueError('Malformed host operation')
        for key in ('id','typeID'):
            if not isinstance(operation[key],str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,256}',operation[key]): raise ValueError('Invalid host operation identity')
        if operation['id'] in ids: raise ValueError('Duplicate host operation')
        ids.add(operation['id'])
        if operation['kind'] not in ('invoke','query') or not isinstance(operation['parameters'],dict): raise ValueError('Unknown host operation')
        if operation.get('resultCodec') not in (None,'noValue','text','bool','integer','decimal','textArray'): raise ValueError('Unqualified result codec')
        if operation['kind']=='invoke' and any(key in operation for key in ('queryText','queryIDs','properties')): raise ValueError('Invoke fields would be ignored')
        if operation['kind']=='query':
            if operation['parameters'] or 'resultCodec' in operation: raise ValueError('Query fields would be ignored')
            if ('queryText' in operation)==('queryIDs' in operation): raise ValueError('Exactly one query selector required')
            if 'queryText' in operation and (not isinstance(operation['queryText'],str) or len(operation['queryText'].encode('utf-16-le'))>65536): raise ValueError('Invalid query text')
            if 'queryIDs' in operation and (not isinstance(operation['queryIDs'],list) or not 1<=len(operation['queryIDs'])<=100 or any(not isinstance(value,str) or not value or len(value.encode('utf-16-le'))>2048 for value in operation['queryIDs'])): raise ValueError('Invalid query identifiers')
            properties=operation.get('properties',{})
            if not isinstance(properties,dict) or len(properties)>50 or any(not re.fullmatch(r'[A-Za-z0-9_.:-]{1,256}',name) or codec not in ('text','bool','integer') for name,codec in properties.items()): raise ValueError('Unqualified query property codec')
        for name,value in operation['parameters'].items():
            if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,256}',name) or not isinstance(value,dict): raise ValueError('Invalid parameter')
            kind=value.get('kind')
            fields={'null':{'kind'},'omission':{'kind'},'bool':{'kind','boolValue'},'text':{'kind','value'},'integer':{'kind','value'},'decimal':{'kind','value'},'enum':{'kind','typeId','value'},'entity':{'kind','typeId','value'}}.get(kind)
            if not fields or set(value)!=fields: raise ValueError('Unqualified input codec')
            if 'typeId' in fields and (not isinstance(value['typeId'],str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,256}',value['typeId'])): raise ValueError('Invalid parameter type identity')
            if kind=='bool' and type(value['boolValue']) is not bool: raise ValueError('Invalid Boolean')
            if 'value' in fields and (not isinstance(value['value'],str) or len(value['value'].encode('utf-16-le'))>65536): raise ValueError('Invalid bounded input')
            if kind=='integer' and (not re.fullmatch(r'-?(0|[1-9][0-9]*)',value['value']) or not -(2**63)<=int(value['value'])<2**63): raise ValueError('Int64 input unavailable')
            if kind=='decimal':
                import math
                if not re.fullmatch(r'-?(0|[1-9][0-9]*)(\.[0-9]+)?',value['value']) or not math.isfinite(float(value['value'])): raise ValueError('Finite Double input required')

def verify_profile(profile):
    keys = {'schemaVersion','runID','attemptID','target','productPath','productDigest',
            'ownedCopyRoot','xctestrun','hostProductDigest','hostPlan','preparation','setup','expectedPositiveLabel','evidenceDirectory'}
    if set(profile) != keys or type(profile['schemaVersion']) is not int or profile['schemaVersion'] != 1: raise ValueError('Malformed integration profile')
    preflight(profile)
    target = profile['target']
    if set(target)!={'id','platform','kind','bundleId','bundlePath','loginSession'} or target.get('platform') != 'ios' or target.get('kind') != 'simulator' or not re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}',target.get('id','')) or target.get('bundlePath') is not None or target.get('loginSession') is not None:
        raise ValueError('This engineering runner requires an exact disposable simulator target')
    if profile['preparation']!={'installFrozenProduct':True,'disposable':True}: raise ValueError('Explicit disposable product installation approval required')
    product, owned, test = (canonical(profile[key]) for key in ('productPath','ownedCopyRoot','xctestrun'))
    marker = read_json(owned / '.intents-owned-snapshot.json')
    if marker.get('schemaVersion') != 1 or not marker.get('runID'): raise ValueError('Private snapshot ownership missing')
    if product_digest(product) != profile['productDigest']: raise ValueError('Frozen product changed')
    app_info = plistlib.loads((product/'Info.plist').read_bytes())
    if app_info.get('CFBundleIdentifier')!=target['bundleId']: raise ValueError('Product bundle identifier mismatch')
    for source in (ROOT/'Integration/AutomationHost').glob('*.swift'):
        if (owned/'IntentsAutomationHostSources'/source.name).read_bytes()!=source.read_bytes(): raise ValueError('Owned host source template changed')
    host = profile['hostPlan']; validate_host(host)
    if host.get('schemaVersion') != 1 or host.get('bundleID') != target.get('bundleId') or host.get('productDigest') != profile['productDigest']:
        raise ValueError('Host product identity mismatch')
    if not isinstance(profile['expectedPositiveLabel'],str) or not profile['expectedPositiveLabel']:
        raise ValueError('A positive readback contract is required')
    setup = profile['setup']
    if set(setup) != {'operations','bindings','approvedEffects'} or not setup['operations']:
        raise ValueError('Explicit UI setup and authority required')
    if 'activate' not in setup['approvedEffects']: raise ValueError('Activation authority missing')
    # Only the Intents-owned generated test target may be selected.
    xctestrun = plistlib.loads(test.read_bytes())
    targets = []
    def walk(value):
        if isinstance(value,dict):
            if 'TestBundlePath' in value: targets.append(value)
            for nested in value.values(): walk(nested)
        elif isinstance(value,list):
            for nested in value: walk(nested)
    walk(xctestrun)
    if len(targets) != 1 or targets[0].get('BlueprintName') != 'IntentsAutomationHost':
        raise ValueError('Exact generated test target required')
    def resolve_build_path(value):
        return Path(value.replace('__TESTROOT__',str(test.parent))).resolve()
    runner_app = resolve_build_path(targets[0]['UITargetAppPath'])
    if runner_app != product: raise ValueError('XCTest subject differs from approved product')
    host_app=resolve_build_path(targets[0]['TestHostPath'])
    test_bundle=Path(targets[0]['TestBundlePath'].replace('__TESTHOST__',str(host_app)).replace('__TESTROOT__',str(test.parent))).resolve()
    if not test_bundle.is_relative_to(host_app) or not test_bundle.is_dir(): raise ValueError('Owned test bundle missing')
    if product_digest(host_app)!=profile['hostProductDigest']: raise ValueError('Frozen host artifact changed')
    if signature_arrangement(host_app)!=signature_arrangement(product): raise ValueError('App and UI host must share their signing team')
    return xctestrun, targets[0]

def run(profile):
    xctestrun, test_target = verify_profile(profile)
    evidence = canonical(profile['evidenceDirectory'])
    evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
    (evidence / 'approved-profile.json').write_text(json.dumps(profile,indent=2))
    state = evidence / 'device'
    dependency_file=ROOT/'Tools/IntentsAutomation/dependencies.lock.json'
    dependency_bytes=dependency_file.read_bytes(); dependency_digest=hashlib.sha256(dependency_bytes).hexdigest()
    (evidence/'dependency-lock.json').write_bytes(dependency_bytes)
    started = time.time()
    def ui(segment_id, generation, operations=None):
        destination = evidence / segment_id
        scope = {'protocolVersion':1,'runId':profile['runID'],'attemptId':profile['attemptID'],
                 'segmentId':segment_id,'leaseGeneration':generation}
        request = {'schemaVersion':1,'target':profile['target'],'scope':scope,'stateDirectory':str(state),
                   'evidenceDirectory':str(destination),'approvedEffects':profile['setup']['approvedEffects'] if operations else ['activate']}
        if operations:
            request['segment'] = {'scope':scope,'operationId':segment_id,'phase':'setup','bindings':profile['setup']['bindings'],
                                  'timeoutMs':60000,'operations':operations}
        path = evidence / (segment_id+'.json'); path.write_text(json.dumps(request))
        if command([str(NODE),str(UI),'--profile',str(path)],evidence/(segment_id+'.log'),120):
            raise ValueError('Actual UI segment failed; inspect owned evidence')
        if read_json(destination/'release.json').get('released') is not True:
            raise ValueError('UI controller release unproved; Apple execution forbidden')
        return read_json(destination/'snapshot.json',16*1024*1024)
    if command(['/usr/bin/xcrun','simctl','install',profile['target']['id'],profile['productPath']],evidence/'prepare-install.log',60): raise ValueError('Frozen product installation failed')
    installed=subprocess.run(['/usr/bin/xcrun','simctl','get_app_container',profile['target']['id'],profile['target']['bundleId'],'app'],check=True,capture_output=True,text=True,timeout=15).stdout.strip()
    if product_digest(Path(installed))!=profile['productDigest']: raise ValueError('Installed simulator product identity mismatch')
    ui('setup',1,profile['setup']['operations'])
    if product_digest(canonical(profile['productPath'])) != profile['productDigest']: raise ValueError('Product drift before dispatch')
    plan = dict(profile['hostPlan']); plan.update(runID=profile['runID'],attemptID=profile['attemptID'],segmentID='system',leaseGeneration=2)
    encoded = json.dumps(plan).encode()
    if len(encoded)>32768: raise ValueError('Host plan exceeds environment budget')
    test_target.setdefault('EnvironmentVariables',{})['INTENTS_AUTOMATION_HOST_PLAN_B64'] = base64.b64encode(encoded).decode()
    def freeze_paths(value):
        if isinstance(value,dict): return {key:freeze_paths(nested) for key,nested in value.items()}
        if isinstance(value,list): return [freeze_paths(nested) for nested in value]
        if isinstance(value,str): return value.replace('__TESTROOT__',str(canonical(profile['xctestrun']).parent))
        return value
    host_file = evidence/'host.xctestrun'; host_file.write_bytes(plistlib.dumps(freeze_paths(xctestrun)))
    host_app=Path(test_target['TestHostPath'].replace('__TESTROOT__',str(canonical(profile['xctestrun']).parent)))
    if product_digest(host_app)!=profile['hostProductDigest']: raise ValueError('Host artifact drift before dispatch')
    result = evidence/'system.xcresult'
    destination = ('platform=iOS Simulator,id=' if profile['target']['kind']=='simulator' else 'platform=iOS,id=')+profile['target']['id']
    if command(['/usr/bin/xcrun','xcodebuild','test-without-building','-xctestrun',str(host_file),'-destination',destination,
                '-only-testing:IntentsAutomationHost/SegmentTests/testSegment','-jobs','2','-parallel-testing-enabled','NO',
                '-resultBundlePath',str(result)],evidence/'system.log',180): raise ValueError('Real Apple execution failed')
    attachments = evidence/'attachments'
    if command(['/usr/bin/xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(attachments)],evidence/'export.log',30):
        raise ValueError('Apple receipt export failed')
    receipts = [read_json(file) for file in attachments.glob('*.json') if file.name!='manifest.json']
    matching = [receipt for receipt in receipts if isinstance(receipt,dict) and receipt.get('complete') is True and
                all(receipt.get(key)==plan[key] for key in ('runID','attemptID','segmentID','leaseGeneration','bundleID','productDigest'))]
    if len(matching)!=1: raise ValueError('No unique complete Apple receipt')
    expected = [operation['id'] for operation in plan['operations']]
    actual = matching[0].get('operations',[])
    if [operation.get('operationID') for operation in actual]!=expected or any(operation.get('dispatched') is not True or operation.get('error') for operation in actual):
        raise ValueError('Apple operations lack matching execution proof')
    if product_digest(host_app)!=profile['hostProductDigest']: raise ValueError('Host artifact drift')
    def verify_installed():
        installed=subprocess.run(['/usr/bin/xcrun','simctl','get_app_container',profile['target']['id'],profile['target']['bundleId'],'app'],check=True,capture_output=True,text=True,timeout=15).stdout.strip()
        if product_digest(Path(installed))!=profile['productDigest']: raise ValueError('Installed product drift after dispatch')
    verify_installed()
    snapshot = ui('readback',3)
    verify_installed()
    if not any(node.get('label')==profile['expectedPositiveLabel'] and node.get('hittable') is True for node in snapshot['nodes']):
        raise ValueError('Independent positive readback failed; no absence inferred')
    if product_digest(canonical(profile['productPath'])) != profile['productDigest']: raise ValueError('Frozen product drift')
    if dependency_file.read_bytes()!=dependency_bytes: raise ValueError('Dependency lock drift during execution')
    summary = {'schemaVersion':1,'runID':profile['runID'],'attemptID':profile['attemptID'],'targetID':profile['target']['id'],
               'appBundleID':profile['target']['bundleId'],'productDigest':profile['productDigest'],
               'dependencyDigest':dependency_digest,'systemCompleted':True,'independentPositiveReadback':True,'resourcesReleased':True,
               'artifactSigningArrangement':signature_arrangement(host_app),'elapsedSeconds':round(time.time()-started,2),'businessAssessment':'engineering fixture contract only'}
    (evidence/'handoff.json').write_text(json.dumps(summary,indent=2)); print(json.dumps(summary))

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--profile',type=Path,required=True)
    try: run(read_json(parser.parse_args().profile))
    except (ValueError,OSError,KeyError,TypeError,subprocess.SubprocessError) as error: parser.exit(1,str(error)+'\n')
