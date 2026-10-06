"""Generate the small iOS app project; the implementation lives in Swift packages."""
from pathlib import Path
import plistlib
root = Path(__file__).resolve().parents[1]
(root/'Apps/iOS/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleDisplayName': 'Companion', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleName': '$(PRODUCT_NAME)',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.5.8', 'CFBundleVersion': '24',
    'CFBundleURLTypes': [{'CFBundleURLName': 'com.quenda.companion.pair', 'CFBundleURLSchemes': ['quenda-companion']}],
    'NSBonjourServices': ['_companion._tcp'],
    'NSLocalNetworkUsageDescription': '连接你的 Mac Companion，使用配对设备间的应用。'
    , 'NSMicrophoneUsageDescription': '采集手机麦克风声音，发送到你配对的 Mac 本地识别并输入文字。',
    'UIBackgroundModes': ['audio'],
    'UILaunchScreen': {}, 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
}))
(root/'Apps/macOS/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleDisplayName': 'Companion', 'CFBundleIdentifier': 'com.quenda.companion.mac',
    'CFBundleExecutable': 'QuendaCompanionMac', 'CFBundleName': 'Companion', 'CFBundleIconFile': 'Companion', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.5.8', 'CFBundleVersion': '24', 'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True, 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
    'NSBonjourServices': ['_companion._tcp'],
    'NSLocalNetworkUsageDescription': '连接本机 Quenda Gateway，并接受你配对的手机连接。',
}))
# Stable object IDs keep the generated project reviewable.
names = ['project','mainGroup','productsGroup','appFile','plistFile','product','sourceBuild','sourcesPhase','frameworksPhase','resourcesPhase','target','projectConfigs','targetConfigs','pDebug','pRelease','tDebug','tRelease','package','core','ui','coreBuild','uiBuild','assetsFile','assetsBuild','noticesFile','noticesBuild']
i = {name: f'{idx:024X}' for idx, name in enumerate(names, 1)}
objects = {
'project': f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }}; buildConfigurationList = {i["projectConfigs"]}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {i["mainGroup"]}; productRefGroup = {i["productsGroup"]}; projectDirPath = ""; projectRoot = ""; targets = ({i["target"]}); packageReferences = ({i["package"]});',
'mainGroup': f'isa = PBXGroup; children = ({i["appFile"]}, {i["plistFile"]}, {i["assetsFile"]}, {i["noticesFile"]}, {i["productsGroup"]}); sourceTree = "<group>";',
'productsGroup': f'isa = PBXGroup; name = Products; children = ({i["product"]}); sourceTree = "<group>";',
'appFile': 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>";',
'plistFile': 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";',
'product': 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = QuendaCompanion.app; sourceTree = BUILT_PRODUCTS_DIR;',
'sourceBuild': f'isa = PBXBuildFile; fileRef = {i["appFile"]};',
'sourcesPhase': f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({i["sourceBuild"]}); runOnlyForDeploymentPostprocessing = 0;',
'frameworksPhase': f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({i["coreBuild"]}, {i["uiBuild"]}); runOnlyForDeploymentPostprocessing = 0;',
 'noticesFile': 'isa = PBXFileReference; lastKnownFileType = text; path = ThirdPartyNotices.txt; sourceTree = "<group>";',
'noticesBuild': f'isa = PBXBuildFile; fileRef = {i["noticesFile"]};',
'assetsFile': 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";',
'assetsBuild': f'isa = PBXBuildFile; fileRef = {i["assetsFile"]};',
'resourcesPhase': f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({i["assetsBuild"]}, {i["noticesBuild"]}); runOnlyForDeploymentPostprocessing = 0;',
'package': 'isa = XCLocalSwiftPackageReference; relativePath = ../..;',
'core': f'isa = XCSwiftPackageProductDependency; package = {i["package"]}; productName = CompanionCore;',
'ui': f'isa = XCSwiftPackageProductDependency; package = {i["package"]}; productName = CompanionUI;',
'coreBuild': f'isa = PBXBuildFile; productRef = {i["core"]};',
'uiBuild': f'isa = PBXBuildFile; productRef = {i["ui"]};',
 'target': f'isa = PBXNativeTarget; buildConfigurationList = {i["targetConfigs"]}; buildPhases = ({i["sourcesPhase"]}, {i["frameworksPhase"]}, {i["resourcesPhase"]}); buildRules = (); dependencies = (); name = QuendaCompanion; productName = QuendaCompanion; productReference = {i["product"]}; productType = "com.apple.product-type.application"; packageProductDependencies = ({i["core"]}, {i["ui"]});',
}
for prefix in ['p','t']:
    for config in ['Debug','Release']:
        settings = 'CLANG_ENABLE_MODULES = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0;'
        if config == 'Debug': settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
        else: settings += ' SWIFT_OPTIMIZATION_LEVEL = "-O";'
        if prefix == 't': settings += ' ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Info.plist; PRODUCT_BUNDLE_IDENTIFIER = com.quenda.companion.ios; PRODUCT_NAME = "$(TARGET_NAME)"; TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";'
        objects[prefix+config] = f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {config};'
    objects['projectConfigs' if prefix == 'p' else 'targetConfigs'] = f'isa = XCConfigurationList; buildConfigurations = ({i[prefix+"Debug"]}, {i[prefix+"Release"]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;'
text = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
for name, value in objects.items(): text += f'  {i[name]} /* {name} */ = {{ {value} }};\n'
text += f'}}; rootObject = {i["project"]}; }}\n'
(root/'Apps/iOS/QuendaCompanion.xcodeproj/project.pbxproj').write_text(text)
(root/'Apps/iOS/QuendaCompanion.xcodeproj/xcshareddata/xcschemes/QuendaCompanion.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{i['target']}" BuildableName="QuendaCompanion.app" BlueprintName="QuendaCompanion" ReferencedContainer="container:QuendaCompanion.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{i['target']}" BuildableName="QuendaCompanion.app" BlueprintName="QuendaCompanion" ReferencedContainer="container:QuendaCompanion.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
