#!/usr/bin/env python3
"""Generate an Intents-owned standalone UI test host; never edit the subject."""
import argparse, json, shutil, subprocess, plistlib
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parents[3] / 'Integration' / 'AutomationHost'

def generate(destination: Path):
    destination.mkdir(parents=True, exist_ok=False)
    sources = destination / 'Sources'; sources.mkdir()
    files = sorted(TEMPLATE.glob('*.swift'))
    for source in files: shutil.copy2(source, sources / source.name)
    objects = []
    def add(identifier, value): objects.append(f'{identifier} = {value};')
    refs, builds = [], []
    for index, source in enumerate(files, 1):
        ref, build = f'F{index:023X}', f'B{index:023X}'
        refs.append(ref); builds.append(build)
        add(ref, '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ' + json.dumps(source.name) + '; sourceTree = "<group>";}')
        add(build, '{isa = PBXBuildFile; fileRef = ' + ref + ';}')
    ids = {name: f'A{index:023X}' for index, name in enumerate(['project','root','source','products','product','target','sources','frameworks','resources','projectConfigs','targetConfigs','projectDebug','projectRelease','targetDebug','targetRelease'], 1)}
    def obj(name, body): add(ids[name], '{' + body + '}')
    obj('root', f'isa = PBXGroup; children = ({ids["source"]},{ids["products"]}); sourceTree = "<group>";')
    obj('source', 'isa = PBXGroup; path = Sources; children = (' + ','.join(refs) + '); sourceTree = "<group>";')
    obj('products', f'isa = PBXGroup; children = ({ids["product"]}); name = Products; sourceTree = "<group>";')
    obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = IntentsAutomationHost.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    obj('sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(builds) + '); runOnlyForDeploymentPostprocessing = 0;')
    for name in ['frameworks','resources']:
        obj(name, f'isa = PBX{name.title()}BuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {ids["targetConfigs"]}; buildPhases = ({ids["sources"]},{ids["frameworks"]},{ids["resources"]}); buildRules = (); dependencies = (); name = IntentsAutomationHost; productName = IntentsAutomationHost; productReference = {ids["product"]}; productType = "com.apple.product-type.bundle.ui-testing";')
    obj('project', f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2700;}}; buildConfigurationList = {ids["projectConfigs"]}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {ids["root"]}; productRefGroup = {ids["products"]}; projectDirPath = ""; projectRoot = ""; targets = ({ids["target"]});')
    for kind in ['project', 'target']:
        for mode in ['Debug', 'Release']:
            settings = 'SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; SWIFT_VERSION = 6.0;'
            if kind == 'target':
                settings += 'PRODUCT_BUNDLE_IDENTIFIER = com.coryparry.Intents.AutomationHost; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; FRAMEWORK_SEARCH_PATHS = ("$(inherited)","$(PLATFORM_DIR)/Developer/Library/Frameworks"); OTHER_LDFLAGS = ("$(inherited)","-framework",AppIntentsTesting); LD_RUNPATH_SEARCH_PATHS = ("$(inherited)","@executable_path/Frameworks","@loader_path/Frameworks");'
            obj(kind + mode, f'isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {mode};')
        obj(kind+'Configs', f'isa = XCConfigurationList; buildConfigurations = ({ids[kind+"Debug"]},{ids[kind+"Release"]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
    project = destination / 'IntentsAutomationHost.xcodeproj'; project.mkdir()
    (project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ids["project"]};}}\n')
    schemes = project / 'xcshareddata' / 'xcschemes'; schemes.mkdir(parents=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids["target"]}" BuildableName="IntentsAutomationHost.xctest" BlueprintName="IntentsAutomationHost" ReferencedContainer="container:IntentsAutomationHost.xcodeproj"/>'
    (schemes / 'IntentsAutomationHost.xcscheme').write_text(f'<?xml version="1.0"?><Scheme version="1.7"><BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{reference}</TestableReference></Testables></TestAction></Scheme>')
    return project

def associate_private_copy(generated: Path, project: Path, owned_root: Path, subject_name: str):
    """Add only the owned test target to an explicitly marked private snapshot."""
    root = owned_root.resolve(strict=True)
    marker = json.loads((root / '.intents-owned-snapshot.json').read_text())
    if marker.get('schemaVersion') != 1 or not marker.get('runID'):
        raise ValueError('Missing private snapshot ownership')
    project = project.resolve(strict=True)
    project.relative_to(root)
    def read(path):
        return json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(path)]))
    template = read(generated / 'project.pbxproj')
    snapshot = read(project / 'project.pbxproj')
    objects = snapshot['objects']; template_objects = template['objects']
    subjects = [key for key, value in objects.items() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == subject_name and value.get('productType') == 'com.apple.product-type.application']
    if len(subjects) != 1: raise ValueError('Exact subject application target required')
    subject = subjects[0]; target = next(key for key, value in template_objects.items() if value.get('isa') == 'PBXNativeTarget')
    source_group = next(key for key, value in template_objects.items() if value.get('isa') == 'PBXGroup' and value.get('path') == 'Sources')
    source_destination = root / 'IntentsAutomationHostSources'
    source_destination.mkdir(exist_ok=False)
    for source in (generated.parent / 'Sources').glob('*.swift'): shutil.copy2(source, source_destination / source.name)
    template_objects[source_group]['path'] = str(source_destination.relative_to(project.parent))
    subject_configs = {objects[key]['name']: objects[key]['buildSettings'] for key in
                       objects[objects[subject]['buildConfigurationList']]['buildConfigurations']}
    project_configs = {objects[key]['name']: objects[key]['buildSettings'] for key in
                       objects[objects[snapshot['rootObject']]['buildConfigurationList']]['buildConfigurations']}
    for value in template_objects.values():
        if value.get('isa') == 'XCBuildConfiguration':
            value['buildSettings']['TEST_TARGET_NAME'] = subject_name
            # Apple's public testing setup requires the UI target and app to share
            # a signing team. Preserve resolved project/target settings in the copy.
            name = value['name']
            team = subject_configs.get(name, {}).get('DEVELOPMENT_TEAM') or project_configs.get(name, {}).get('DEVELOPMENT_TEAM')
            if team:
                value['buildSettings']['DEVELOPMENT_TEAM'] = team
    skip = {'PBXProject'}
    excluded = {template['rootObject'], template_objects[template['rootObject']]['mainGroup'], template_objects[template['rootObject']]['productRefGroup'], template_objects[template['rootObject']]['buildConfigurationList']}
    for key, value in template_objects.items():
        if key in excluded or value.get('isa') in skip: continue
        if key in objects: raise ValueError('Generated target identity collision')
        objects[key] = value
    proxy, dependency = 'C00000000000000000000001', 'C00000000000000000000002'
    if proxy in objects or dependency in objects: raise ValueError('Dependency identity collision')
    objects[proxy] = {'isa':'PBXContainerItemProxy','containerPortal':snapshot['rootObject'],'proxyType':'1','remoteGlobalIDString':subject,'remoteInfo':subject_name}
    objects[dependency] = {'isa':'PBXTargetDependency','target':subject,'targetProxy':proxy}
    objects[target]['dependencies'].append(dependency)
    root_project = objects[snapshot['rootObject']]
    root_project['targets'].append(target)
    root_project.setdefault('attributes',{}).setdefault('TargetAttributes',{})[target] = {'TestTargetID':subject,'CreatedOnToolsVersion':'27.0'}
    objects[root_project['mainGroup']]['children'].append(source_group)
    product_ref = objects[target]['productReference']
    objects[root_project['productRefGroup']]['children'].append(product_ref)
    # Xcode accepts XML property-list project documents. Only this private copy changes.
    (project / 'project.pbxproj').write_bytes(plistlib.dumps(snapshot, fmt=plistlib.FMT_XML, sort_keys=False))
    schemes = project / 'xcshareddata' / 'xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
    source_scheme = generated / 'xcshareddata' / 'xcschemes' / 'IntentsAutomationHost.xcscheme'
    scheme = source_scheme.read_text().replace('container:IntentsAutomationHost.xcodeproj', 'container:' + project.name)
    (schemes / source_scheme.name).write_text(scheme)
    return project

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--private-project',type=Path); parser.add_argument('--owned-copy-root',type=Path); parser.add_argument('--subject-target')
    args = parser.parse_args()
    if any([args.private_project,args.owned_copy_root,args.subject_target]) and not all([args.private_project,args.owned_copy_root,args.subject_target]): parser.error('All private-copy association arguments required')
    project = generate(args.output)
    if args.private_project: project = associate_private_copy(project,args.private_project,args.owned_copy_root,args.subject_target)
    print(project)
