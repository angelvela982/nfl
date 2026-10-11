"""Recreate the dependency-free Xcode project. Python standard library only."""
from pathlib import Path
import hashlib, json, plistlib
ROOT = Path(__file__).resolve().parents[1]
objects = {}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def put(name, value):
    key = uid(name); objects[key] = value; return key
files = sorted((ROOT/'NFLPulse').glob('*.swift'))
refs, builds = [], []
for f in files:
    ref=put('file:'+f.name, {'isa':'PBXFileReference','lastKnownFileType':'sourcecode.swift','path':f.name,'sourceTree':'<group>'})
    refs.append(ref)
    builds.append(put('build:'+f.name, {'isa':'PBXBuildFile','fileRef':ref}))
refs.append(put('info', {'isa':'PBXFileReference','lastKnownFileType':'text.plist.xml','path':'Info.plist','sourceTree':'<group>'}))
source_group=put('source-group', {'isa':'PBXGroup','children':refs,'path':'NFLPulse','sourceTree':'<group>'})
product=put('product', {'isa':'PBXFileReference','explicitFileType':'wrapper.application','includeInIndex':0,'path':'NFLPulse.app','sourceTree':'BUILT_PRODUCTS_DIR'})
products=put('products', {'isa':'PBXGroup','children':[product],'name':'Products','sourceTree':'<group>'})
main=put('main', {'isa':'PBXGroup','children':[source_group,products],'sourceTree':'<group>'})
sources=put('sources', {'isa':'PBXSourcesBuildPhase','buildActionMask':2147483647,'files':builds,'runOnlyForDeploymentPostprocessing':0})
frameworks=put('frameworks', {'isa':'PBXFrameworksBuildPhase','buildActionMask':2147483647,'files':[],'runOnlyForDeploymentPostprocessing':0})
resources=put('resources', {'isa':'PBXResourcesBuildPhase','buildActionMask':2147483647,'files':[],'runOnlyForDeploymentPostprocessing':0})
project_configs=[]; target_configs=[]
for mode in ['Debug','Release']:
    project_configs.append(put('project-'+mode, {'isa':'XCBuildConfiguration','name':mode,'buildSettings':{'ALWAYS_SEARCH_USER_PATHS':'NO','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_VERSION':'5.0','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else ''}}))
    target_configs.append(put('target-'+mode, {'isa':'XCBuildConfiguration','name':mode,'buildSettings':{'CODE_SIGN_STYLE':'Automatic','CURRENT_PROJECT_VERSION':'2','GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'NFLPulse/Info.plist','IPHONEOS_DEPLOYMENT_TARGET':'17.0','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks'],'MARKETING_VERSION':'0.2.0','PRODUCT_BUNDLE_IDENTIFIER':'com.hermano.nflpulse','PRODUCT_NAME':'$(TARGET_NAME)','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','SWIFT_VERSION':'5.0','TARGETED_DEVICE_FAMILY':'1','SWIFT_EMIT_LOC_STRINGS':'YES'}}))
pc=put('project-configs', {'isa':'XCConfigurationList','buildConfigurations':project_configs,'defaultConfigurationIsVisible':0,'defaultConfigurationName':'Release'})
tc=put('target-configs', {'isa':'XCConfigurationList','buildConfigurations':target_configs,'defaultConfigurationIsVisible':0,'defaultConfigurationName':'Release'})
target=put('target', {'isa':'PBXNativeTarget','buildConfigurationList':tc,'buildPhases':[sources,frameworks,resources],'buildRules':[],'dependencies':[],'name':'NFLPulse','productName':'NFLPulse','productReference':product,'productType':'com.apple.product-type.application'})
project=put('project', {'isa':'PBXProject','attributes':{'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'1600','TargetAttributes':{target:{'CreatedOnToolsVersion':'16.0'}}},'buildConfigurationList':pc,'compatibilityVersion':'Xcode 14.0','developmentRegion':'es','hasScannedForEncodings':0,'knownRegions':['es','en','Base'],'mainGroup':main,'productRefGroup':products,'projectDirPath':'','projectRoot':'','targets':[target]})
def encode(v, indent=0):
    tab='\t'*indent
    if isinstance(v, dict): return '{\n'+''.join('\t'*(indent+1)+json.dumps(str(k))+' = '+encode(val,indent+1)+';\n' for k,val in v.items())+tab+'}'
    if isinstance(v,list): return '(\n'+''.join('\t'*(indent+1)+encode(x,indent+1)+',\n' for x in v)+tab+')'
    if isinstance(v,int): return str(v)
    return json.dumps(v,ensure_ascii=False)
root={'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project}
(ROOT/'NFLPulse.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(root)+'\n')
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NFLPulse.app" BlueprintName="NFLPulse" ReferencedContainer="container:NFLPulse.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NFLPulse.app" BlueprintName="NFLPulse" ReferencedContainer="container:NFLPulse.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NFLPulse.app" BlueprintName="NFLPulse" ReferencedContainer="container:NFLPulse.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(ROOT/'NFLPulse.xcodeproj/xcshareddata/xcschemes/NFLPulse.xcscheme').write_text(scheme)
# Validate the generated object graph and XML. This is not an Xcode compilation.
assert len(set(objects)) == len(objects)
for f in files: assert f.is_file()
assert all(objects[x]['isa']=='PBXBuildFile' for x in builds)
with (ROOT/'NFLPulse/Info.plist').open('rb') as f: plistlib.load(f)
print(f'Proyecto generado: {len(files)} archivos Swift; grafo y plist comprobados.')
