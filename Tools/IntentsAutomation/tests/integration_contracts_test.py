import base64
import hashlib
import importlib.util
import json
import plistlib
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import shutil
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
def module(name):
    spec = importlib.util.spec_from_file_location(name,SCRIPTS/(name+'.py'))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result); return result
runner, generator = module('run_integration'), module('generate_host')

class IntegrationContracts(unittest.TestCase):
    @patch.object(runner,'preflight')
    def test_product_drift_and_wrong_host_rejected_before_execution(self, _preflight):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            root=Path(directory).resolve(); product=root/'Subject.app';product.mkdir();(product/'binary').write_bytes(b'frozen');(product/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'example.Subject'}))
            source=root/'IntentsAutomationHostSources';source.mkdir()
            for file in (runner.ROOT/'Integration/AutomationHost').glob('*.swift'): shutil.copy2(file,source/file.name)
            host=root/'Host.app';(host/'PlugIns/Host.xctest').mkdir(parents=True);(host/'binary').write_bytes(b'host')
            (root/'.intents-owned-snapshot.json').write_text('{"schemaVersion":1,"runID":"run"}')
            tests=root/'host.xctestrun'
            value={'Host':{'BlueprintName':'IntentsAutomationHost','TestHostPath':str(host),'TestBundlePath':str(host/'PlugIns/Host.xctest'),'UITargetAppPath':str(product)}}
            tests.write_bytes(plistlib.dumps(value)); digest=runner.product_digest(product)
            profile={'schemaVersion':1,'runID':'run','attemptID':'attempt','target':{'id':'00000000-0000-0000-0000-000000000000','platform':'ios','kind':'simulator','bundleId':'example.Subject','bundlePath':None,'loginSession':None},
                     'productPath':str(product),'productDigest':digest,'ownedCopyRoot':str(root),'xctestrun':str(tests),'hostProductDigest':runner.product_digest(host),'preparation':{'installFrozenProduct':True,'disposable':True},
                     'hostPlan':{'schemaVersion':1,'runID':'run','attemptID':'attempt','segmentID':'system','leaseGeneration':2,'bundleID':'example.Subject','productDigest':digest,'operations':[{'id':'invoke','kind':'invoke','typeID':'FindIntent','parameters':{},'resultCodec':'noValue'}]},
                     'setup':{'operations':[{'kind':'tap'}],'bindings':{},'approvedEffects':['activate','tap']},
                     'expectedPositiveLabel':'Synthetic fixture','evidenceDirectory':str(root/'evidence')}
            with patch.object(runner,'signature_arrangement',return_value='SUBJECT123'): runner.verify_profile(profile)
            (product/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'other.Subject'}))
            profile['productDigest']=runner.product_digest(product);profile['hostPlan']['productDigest']=profile['productDigest']
            with self.assertRaisesRegex(ValueError,'bundle identifier'): runner.verify_profile(profile)
            (product/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'example.Subject'}))
            profile['productDigest']=digest;profile['hostPlan']['productDigest']=digest
            value['Host']['UITargetAppPath']=str(root/'Other.app');tests.write_bytes(plistlib.dumps(value))
            with self.assertRaisesRegex(ValueError,'differs'): runner.verify_profile(profile)
            tests.write_bytes(plistlib.dumps({'Host':{'BlueprintName':'ForeignTarget','TestBundlePath':'Host','UITargetAppPath':str(product)}}))
            with self.assertRaisesRegex(ValueError,'Exact generated'): runner.verify_profile(profile)
            (product/'binary').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'Frozen product changed'): runner.verify_profile(profile)

    def test_host_rejects_unknown_codecs_before_any_device_work(self):
        host={'schemaVersion':1,'runID':'run','attemptID':'attempt','segmentID':'system','leaseGeneration':2,'bundleID':'example.Subject','productDigest':'a'*64,'operations':[{'id':'invoke','kind':'invoke','typeID':'Intent','parameters':{'name':{'kind':'date','value':'today'}}}]}
        with self.assertRaisesRegex(ValueError,'Unqualified input'): runner.validate_host(host)
        host['operations'][0]['parameters']={'count':{'kind':'integer','value':str(2**63)}}
        with self.assertRaisesRegex(ValueError,'Int64'): runner.validate_host(host)

    def test_host_optional_fields_have_one_meaning_before_preparation(self):
        host={'schemaVersion':1,'runID':'run','attemptID':'attempt','segmentID':'system','leaseGeneration':2,'bundleID':'example.Subject','productDigest':'a'*64,'operations':[]}
        for operation in [
            {'id':'q','kind':'query','typeID':'Item','parameters':{}},
            {'id':'q','kind':'query','typeID':'Item','parameters':{},'queryIDs':['1'],'queryText':'x'},
            {'id':'q','kind':'query','typeID':'Item','parameters':{},'queryText':'x','properties':{'name':'unsupported'}},
            {'id':'i','kind':'invoke','typeID':'Intent','parameters':{},'queryText':'ignored'},
            {'id':'i','kind':'invoke','typeID':'Intent','parameters':{'p':{'kind':'enum','typeId':123,'value':'a'}}}]:
            with self.subTest(operation=operation):
                host['operations']=[operation]
                with self.assertRaises(ValueError): runner.validate_host(host)
        host['schemaVersion']=True
        with self.assertRaisesRegex(ValueError,'Malformed host'): runner.validate_host(host)

    def test_associated_host_inherits_app_signing_team_without_original_edits(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            root=Path(directory).resolve(); owned=root/'copy';owned.mkdir();(owned/'.intents-owned-snapshot.json').write_text('{"schemaVersion":1,"runID":"run"}')
            project=owned/'Subject.xcodeproj';project.mkdir()
            objects={'project':{'isa':'PBXProject','mainGroup':'main','productRefGroup':'products','buildConfigurationList':'projectConfigs','targets':['subject']},
                     'main':{'isa':'PBXGroup','children':['products']},'products':{'isa':'PBXGroup','children':[]},
                     'subject':{'isa':'PBXNativeTarget','name':'Subject','productType':'com.apple.product-type.application','buildConfigurationList':'subjectConfigs'},
                     'projectConfigs':{'buildConfigurations':['projectDebug','projectRelease']},'subjectConfigs':{'buildConfigurations':['subjectDebug','subjectRelease']}}
            for mode in ('Debug','Release'):
                objects['project'+mode]={'isa':'XCBuildConfiguration','name':mode,'buildSettings':{'DEVELOPMENT_TEAM':'PROJECT123'}}
                objects['subject'+mode]={'isa':'XCBuildConfiguration','name':mode,'buildSettings':{'DEVELOPMENT_TEAM':'SUBJECT123'}}
            original=plistlib.dumps({'rootObject':'project','objects':objects});(project/'project.pbxproj').write_bytes(original)
            outside=root/'original.pbxproj';outside.write_bytes(original)
            generated=generator.generate(root/'generated')
            generator.associate_private_copy(generated,project,owned,'Subject')
            actual=plistlib.loads(subprocess.check_output(['plutil','-convert','xml1','-o','-',str(project/'project.pbxproj')]))
            target=next(value for value in actual['objects'].values() if value.get('name')=='IntentsAutomationHost' and value.get('isa')=='PBXNativeTarget')
            configs=actual['objects'][target['buildConfigurationList']]['buildConfigurations']
            self.assertTrue(all(actual['objects'][key]['buildSettings']['DEVELOPMENT_TEAM']=='SUBJECT123' for key in configs))
            self.assertEqual(outside.read_bytes(),original)

    def test_owned_child_returns_exit_status_and_logs_output(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            log=Path(directory).resolve()/'child.log'
            self.assertEqual(runner.command(['/bin/sh','-c','echo owned; exit 3'],log,10),3)
            self.assertEqual(log.read_text(),'owned\n')

    def owned_children(self):
        children=[]; spawn=subprocess.Popen
        def record(*arguments,**options):
            children.append(spawn(*arguments,**options)); return children[-1]
        return children, patch.object(runner.subprocess,'Popen',side_effect=record)

    def test_owned_child_deadline_terminates_and_raises(self):
        children, recording = self.owned_children()
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory, recording:
            with self.assertRaisesRegex(ValueError,'Owned child deadline expired'):
                runner.command(['/bin/sleep','30'],Path(directory).resolve()/'child.log',0.1)
        self.assertEqual(len(children),1)
        self.assertEqual(children[0].returncode,-signal.SIGTERM)

    def test_owned_child_ignoring_terminate_is_killed_and_raises(self):
        children, recording = self.owned_children()
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory, recording:
            with self.assertRaisesRegex(ValueError,'Owned child deadline expired'):
                runner.command(['/bin/sh','-c',"trap '' TERM; exec /bin/sleep 30"],Path(directory).resolve()/'child.log',0.5)
        self.assertEqual(len(children),1)
        self.assertEqual(children[0].returncode,-signal.SIGKILL)

class IntegrationRunAcceptance(unittest.TestCase):
    """Drives run() offline: device, Xcode, and UI children are simulated, receipts are real files."""
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.directory.cleanup)
        root=self.root=Path(self.directory.name).resolve()
        self.product=root/'Subject.app';self.product.mkdir();(self.product/'binary').write_bytes(b'frozen')
        self.host=root/'Host.app';self.host.mkdir();(self.host/'binary').write_bytes(b'host')
        self.lock=root/'Tools/IntentsAutomation/dependencies.lock.json';self.lock.parent.mkdir(parents=True);self.lock.write_bytes(b'{"lock":1}')
        digest=runner.product_digest(self.product)
        self.profile={'schemaVersion':1,'runID':'run','attemptID':'attempt',
            'target':{'id':'00000000-0000-0000-0000-000000000000','platform':'ios','kind':'simulator','bundleId':'example.Subject','bundlePath':None,'loginSession':None},
            'productPath':str(self.product),'productDigest':digest,'ownedCopyRoot':str(root),'xctestrun':str(root/'host.xctestrun'),
            'hostProductDigest':runner.product_digest(self.host),'preparation':{'installFrozenProduct':True,'disposable':True},
            'hostPlan':{'schemaVersion':1,'runID':'run','attemptID':'attempt','segmentID':'system','leaseGeneration':2,'bundleID':'example.Subject','productDigest':digest,
                        'operations':[{'id':'first','kind':'invoke','typeID':'FindIntent','parameters':{}},{'id':'second','kind':'invoke','typeID':'OpenIntent','parameters':{}}]},
            'setup':{'operations':[{'kind':'tap'}],'bindings':{},'approvedEffects':['activate','tap']},
            'expectedPositiveLabel':'Synthetic fixture','evidenceDirectory':str(root/'evidence')}
        self.evidence=root/'evidence'
        self.receipts=[self.receipt()]
        self.nodes=[{'label':'Synthetic fixture','hittable':True}]
        self.during_readback=lambda: None
        self.calls=[]

    def receipt(self, **changes):
        value={'complete':True,'runID':'run','attemptID':'attempt','segmentID':'system','leaseGeneration':2,'bundleID':'example.Subject',
               'productDigest':self.profile['productDigest'],'operations':[{'operationID':'first','dispatched':True},{'operationID':'second','dispatched':True}]}
        value.update(changes); return value

    def fake_command(self, arguments, log, timeout):
        self.calls.append(arguments); log.write_text('simulated')
        if arguments[:2]==[str(runner.NODE),str(runner.UI)]:
            request=json.loads(Path(arguments[3]).read_text()); destination=Path(request['evidenceDirectory']); destination.mkdir()
            readback=request['scope']['segmentId']=='readback'
            if readback: self.during_readback()
            (destination/'release.json').write_text(json.dumps({'released':True}))
            (destination/'snapshot.json').write_text(json.dumps({'nodes':self.nodes if readback else []}))
        elif 'xcresulttool' in arguments:
            output=Path(arguments[arguments.index('--output-path')+1]); output.mkdir()
            for index,receipt in enumerate(self.receipts): (output/f'receipt-{index}.json').write_text(json.dumps(receipt))
            (output/'manifest.json').write_text(json.dumps(self.receipt()))
        return 0

    def fake_subprocess_run(self, arguments, **options):
        return subprocess.CompletedProcess(arguments,0,stdout=str(self.product)+'\n',stderr='')

    def execute(self):
        target={'BlueprintName':'IntentsAutomationHost','TestHostPath':str(self.host),'TestBundlePath':str(self.host/'PlugIns/Host.xctest'),'UITargetAppPath':str(self.product)}
        with patch.object(runner,'ROOT',self.root), patch.object(runner,'verify_profile',return_value=({'Host':target},target)), \
             patch.object(runner,'command',side_effect=self.fake_command), patch.object(runner.subprocess,'run',side_effect=self.fake_subprocess_run), \
             patch.object(runner,'signature_arrangement',return_value='SUBJECT123'), patch('builtins.print'):
            runner.run(self.profile)

    def assertRejected(self, message):
        with self.assertRaisesRegex(ValueError,message): self.execute()
        self.assertFalse((self.evidence/'handoff.json').exists())

    def test_unique_complete_receipt_and_positive_readback_write_success_handoff(self):
        self.execute()
        handoff=json.loads((self.evidence/'handoff.json').read_text())
        self.assertIs(handoff['systemCompleted'],True); self.assertIs(handoff['independentPositiveReadback'],True)
        self.assertEqual((handoff['runID'],handoff['attemptID'],handoff['productDigest']),('run','attempt',self.profile['productDigest']))
        self.assertEqual(handoff['dependencyDigest'],hashlib.sha256(b'{"lock":1}').hexdigest())
        self.assertEqual((self.evidence/'dependency-lock.json').read_bytes(),b'{"lock":1}')
        frozen=plistlib.loads((self.evidence/'host.xctestrun').read_bytes())['Host']['EnvironmentVariables']['INTENTS_AUTOMATION_HOST_PLAN_B64']
        plan=json.loads(base64.b64decode(frozen))
        self.assertEqual((plan['runID'],plan['attemptID'],plan['segmentID'],plan['leaseGeneration']),('run','attempt','system',2))
        self.assertEqual([call[1] for call in self.calls if call[0]=='/usr/bin/xcrun'],['simctl','xcodebuild','xcresulttool'])

    def test_missing_receipt_rejected(self):
        self.receipts=[]
        self.assertRejected('No unique complete Apple receipt')

    def test_duplicate_receipts_rejected(self):
        self.receipts=[self.receipt(),self.receipt()]
        self.assertRejected('No unique complete Apple receipt')

    def test_incomplete_receipt_rejected(self):
        self.receipts=[self.receipt(complete=False)]
        self.assertRejected('No unique complete Apple receipt')

    def test_receipt_for_another_scope_rejected(self):
        for key,value in (('runID','other'),('attemptID','other'),('segmentID','setup'),('leaseGeneration',1),('bundleID','other.Subject'),('productDigest','b'*64)):
            with self.subTest(key=key):
                self.setUp(); self.receipts=[self.receipt(**{key:value})]
                self.assertRejected('No unique complete Apple receipt')

    def test_operations_without_matching_execution_proof_rejected(self):
        for operations in ([{'operationID':'second','dispatched':True},{'operationID':'first','dispatched':True}],
                           [{'operationID':'first','dispatched':True}],
                           [{'operationID':'first','dispatched':True},{'operationID':'second','dispatched':False}],
                           [{'operationID':'first','dispatched':True},{'operationID':'second'}],
                           [{'operationID':'first','dispatched':True,'error':'denied'},{'operationID':'second','dispatched':True}]):
            with self.subTest(operations=operations):
                self.setUp(); self.receipts=[self.receipt(operations=operations)]
                self.assertRejected('Apple operations lack matching execution proof')

    def test_readback_without_hittable_expected_label_rejected(self):
        for nodes in ([],[{'label':'Synthetic fixture','hittable':False}],[{'label':'Other','hittable':True}]):
            with self.subTest(nodes=nodes):
                self.setUp(); self.nodes=nodes
                self.assertRejected('Independent positive readback failed')

    def test_dependency_lock_drift_during_execution_rejected(self):
        self.during_readback=lambda: self.lock.write_bytes(b'{"lock":2}')
        self.assertRejected('Dependency lock drift during execution')

    def fail_child(self, tool):
        succeed=self.fake_command
        self.fake_command=lambda arguments,log,timeout: 65 if tool in arguments else succeed(arguments,log,timeout)

    def test_failed_apple_execution_rejected(self):
        self.fail_child('xcodebuild')
        self.assertRejected('Real Apple execution failed')

    def test_failed_receipt_export_rejected(self):
        self.fail_child('xcresulttool')
        self.assertRejected('Apple receipt export failed')

    def test_unreleased_ui_controller_forbids_apple_execution(self):
        succeed=self.fake_command
        def unreleased(arguments,log,timeout):
            code=succeed(arguments,log,timeout)
            if arguments[:2]==[str(runner.NODE),str(runner.UI)]:
                destination=Path(json.loads(Path(arguments[3]).read_text())['evidenceDirectory']); (destination/'release.json').write_text('{"released":false}')
            return code
        self.fake_command=unreleased
        self.assertRejected('UI controller release unproved')
        self.assertFalse(any('xcodebuild' in call for call in self.calls))

    def test_owned_deadline_during_apple_execution_aborts_run(self):
        succeed=self.fake_command
        def expire(arguments,log,timeout):
            if 'xcodebuild' in arguments: raise ValueError('Owned child deadline expired; controller termination is unproved')
            return succeed(arguments,log,timeout)
        self.fake_command=expire
        self.assertRejected('Owned child deadline expired')
        self.assertFalse((self.evidence/'attachments').exists())

if __name__=='__main__': unittest.main()
