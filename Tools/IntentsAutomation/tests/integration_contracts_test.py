import importlib.util
import json
import plistlib
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

if __name__=='__main__': unittest.main()
