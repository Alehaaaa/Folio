#!/usr/bin/env python3
"""Regenerate the native iOS Xcode project without copying shared Swift sources.

Run from any directory: python3 /books/app/iOS/generate_project.py
The project always compiles the current ../Sources/Folio files.
"""

from hashlib import sha1
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "FolioiOS.xcodeproj"
APP_VERSION = "1.0.6"
BUILD_VERSION = "7"
SHARED = [
    "Models",
    "LibraryStore",
    "EPUB",
    "EPUBHardcoverEnricher",
    "ReaderPrefs",
    "ReadingAnnotations",
    "ReaderScript",
    "BookAutoMatch",
    "DownloadQueue",
    "Hardcover",
    "Goodreads",
    "DefaultSources",
    "Extensions",
    "ExtensionBrowser",
    "WidgetShared",
    "WidgetBridge",
    "ReadingReminders",
]

IOS = sorted(p.stem for p in (ROOT / "Sources").glob("*.swift"))


def uid(key):
    return sha1(("Folio iOS " + key).encode("utf-8")).hexdigest()[:24].upper()


def ref(key, label):
    return f"{uid(key)} /* {label} */"


def fields(data):
    return "\n".join(f"\t\t\t{key} = {value};" for key, value in data)


def block(isa, props):
    return "{\n\t\t\tisa = " + isa + ";\n" + fields(props) + "\n\t\t}"


def arr(values, indent="\t\t\t"):
    return "(\n" + "".join(indent + "\t" + x + ",\n" for x in values) + indent + ")"


def settings(variant, target=False, widget=False):
    base = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ARCHS": "arm64",
        "CLANG_ENABLE_MODULES": "YES",
        "CODE_SIGNING_ALLOWED": "NO",
        "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
        "ONLY_ACTIVE_ARCH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    if target:
        base.update({
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CODE_SIGN_ENTITLEMENTS": "Resources/Folio.entitlements",
            "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": BUILD_VERSION,
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks")',
            "MARKETING_VERSION": APP_VERSION,
            "PRODUCT_BUNDLE_IDENTIFIER": "app.folio.reader.ios",
            "PRODUCT_NAME": "Folio",
            "SUPPORTS_MACCATALYST": "NO",
            "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
            "SWIFT_STRICT_CONCURRENCY": "minimal",
            "TARGETED_DEVICE_FAMILY": '"1,2"',
        })
    elif widget:
        base.update({
            "APPLICATION_EXTENSION_API_ONLY": "YES",
            "CODE_SIGN_ENTITLEMENTS": "WidgetExtension/FolioWidgets.entitlements",
            "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": BUILD_VERSION,
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "WidgetExtension/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks")',
            "MARKETING_VERSION": APP_VERSION,
            "PRODUCT_BUNDLE_IDENTIFIER": "app.folio.reader.ios.widgets",
            "PRODUCT_MODULE_NAME": "FolioWidgets",
            "PRODUCT_NAME": "FolioWidgets",
            "SKIP_INSTALL": "YES",
            "SUPPORTS_MACCATALYST": "NO",
            "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
            "SWIFT_STRICT_CONCURRENCY": "minimal",
            "TARGETED_DEVICE_FAMILY": '"1,2"',
        })
    else:
        base.update({
            "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"$(inherited) DEBUG"' if variant == "Debug" else '"$(inherited)"',
        })
    base["SWIFT_OPTIMIZATION_LEVEL"] = '"-Onone"' if variant == "Debug" else '"-O"'
    base["DEBUG_INFORMATION_FORMAT"] = "dwarf" if variant == "Debug" else '"dwarf-with-dsym"'
    return "{\n" + "\n".join(f"\t\t\t\t{k} = {v};" for k, v in base.items()) + "\n\t\t\t}"


def create():
    objects = {}

    def add(key, label, isa, props):
        objects[key] = (label, block(isa, props))
        return ref(key, label)

    root_group = "group.root"
    ios_group = "group.ios"
    shared_group = "group.shared"
    resource_group = "group.resources"
    products_group = "group.products"
    source_members = []
    ios_files = []
    shared_files = []
    shared_refs = {}
    for filename in IOS:
        name = filename + ".swift"
        file_key = "ios." + name
        file_ref = add(file_key, name, "PBXFileReference", [
            ("lastKnownFileType", "sourcecode.swift"), ("path", name),
            ("sourceTree", '"<group>"'),
        ])
        ios_files.append(file_ref)
        source_members.append(add("build." + file_key, name + " in Sources", "PBXBuildFile", [
            ("fileRef", file_ref),
        ]))

    for filename in SHARED:
        name = filename + ".swift"
        file_key = "shared." + name
        file_ref = add(file_key, name, "PBXFileReference", [
            ("lastKnownFileType", "sourcecode.swift"), ("path", name),
            ("sourceTree", '"<group>"'),
        ])
        shared_files.append(file_ref)
        shared_refs[filename] = file_ref
        source_members.append(add("build." + file_key, name + " in Sources", "PBXBuildFile", [
            ("fileRef", file_ref),
        ]))

    catalog_ref = add("assets", "Assets.xcassets", "PBXFileReference", [
        ("lastKnownFileType", "folder.assetcatalog"),
        ("path", "Assets.xcassets"), ("sourceTree", '"<group>"'),
    ])
    info_ref = add("info", "Info.plist", "PBXFileReference", [
        ("lastKnownFileType", "text.plist.xml"), ("path", "Info.plist"),
        ("sourceTree", '"<group>"'),
    ])
    app_entitlements_ref = add("app.entitlements", "Folio.entitlements", "PBXFileReference", [
        ("lastKnownFileType", "text.plist.xml"), ("path", "Folio.entitlements"),
        ("sourceTree", '"<group>"'),
    ])
    widget_files = []
    for key, label, kind in [
        ("widget.source", "FolioWidgets.swift", "sourcecode.swift"),
        ("widget.info", "Info.plist", "text.plist.xml"),
        ("widget.entitlements", "FolioWidgets.entitlements", "text.plist.xml"),
    ]:
        widget_files.append(add(key, label, "PBXFileReference", [
            ("lastKnownFileType", kind), ("path", label),
            ("sourceTree", '"<group>"'),
        ]))
    js_refs = []
    js_builds = []
    for js_path in sorted((ROOT.parent.parent / "extensions").glob("*.js")):
        name = js_path.name
        key = "bundled." + name
        file_ref = add(key, name, "PBXFileReference", [
            ("lastKnownFileType", "sourcecode.javascript"),
            ("name", f'"{name}"'),
            ("path", f'"../../extensions/{name}"'),
            ("sourceTree", "SOURCE_ROOT"),
        ])
        js_refs.append(file_ref)
        js_builds.append(add("build." + key, name + " in Resources", "PBXBuildFile", [
            ("fileRef", file_ref),
        ]))
    app_ref = add("app", "Folio.app", "PBXFileReference", [
        ("explicitFileType", "wrapper.application"),
        ("includeInIndex", "0"),
        ("path", "Folio.app"),
        ("sourceTree", "BUILT_PRODUCTS_DIR"),
    ])
    widget_app_ref = add("widget.app", "FolioWidgets.appex", "PBXFileReference", [
        ("explicitFileType", "wrapper.app-extension"),
        ("includeInIndex", "0"),
        ("path", "FolioWidgets.appex"),
        ("sourceTree", "BUILT_PRODUCTS_DIR"),
    ])
    embedded_widget = add("build.widget.embed", "FolioWidgets.appex in Embed App Extensions", "PBXBuildFile", [
        ("fileRef", widget_app_ref),
        ("settings", "{ ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy); }"),
    ])
    widget_source_builds = [
        add("build.widget.source", "FolioWidgets.swift in Sources", "PBXBuildFile", [
            ("fileRef", widget_files[0]),
        ]),
        add("build.widget.shared", "WidgetShared.swift in Widget Sources", "PBXBuildFile", [
            ("fileRef", shared_refs["WidgetShared"]),
        ]),
    ]
    asset_build = add("build.assets", "Assets.xcassets in Resources", "PBXBuildFile", [
        ("fileRef", catalog_ref),
    ])
    package_ref = add("package.zipfoundation", "XCRemoteSwiftPackageReference ZIPFoundation", "XCRemoteSwiftPackageReference", [
        ("repositoryURL", '"https://github.com/weichsel/ZIPFoundation.git"'),
        ("requirement", '{ kind = upToNextMajorVersion; minimumVersion = 0.9.18; }'),
    ])
    product_ref = add("package.product", "ZIPFoundation", "XCSwiftPackageProductDependency", [
        ("package", package_ref), ("productName", "ZIPFoundation"),
    ])
    zip_build = add("build.zip", "ZIPFoundation in Frameworks", "PBXBuildFile", [
        ("productRef", product_ref),
    ])
    add("phase.frameworks", "Frameworks", "PBXFrameworksBuildPhase", [
        ("buildActionMask", "2147483647"),
        ("files", arr([zip_build])),
        ("runOnlyForDeploymentPostprocessing", "0"),
    ])
    add("phase.sources", "Sources", "PBXSourcesBuildPhase", [
        ("buildActionMask", "2147483647"),
        ("files", arr(source_members)),
        ("runOnlyForDeploymentPostprocessing", "0"),
    ])
    add("phase.resources", "Resources", "PBXResourcesBuildPhase", [
        ("buildActionMask", "2147483647"),
        ("files", arr([asset_build] + js_builds)),
        ("runOnlyForDeploymentPostprocessing", "0"),
    ])
    add("phase.widget.sources", "Widget Sources", "PBXSourcesBuildPhase", [
        ("buildActionMask", "2147483647"),
        ("files", arr(widget_source_builds)),
        ("runOnlyForDeploymentPostprocessing", "0"),
    ])
    add("phase.widget.frameworks", "Widget Frameworks", "PBXFrameworksBuildPhase", [
        ("buildActionMask", "2147483647"),
        ("files", "()"),
        ("runOnlyForDeploymentPostprocessing", "0"),
    ])
    add("phase.widget.embed", "Embed App Extensions", "PBXCopyFilesBuildPhase", [
        ("buildActionMask", "2147483647"),
        ("dstPath", '""'),
        ("dstSubfolderSpec", "13"),
        ("files", arr([embedded_widget])),
        ("name", '"Embed App Extensions"'),
        ("runOnlyForDeploymentPostprocessing", "0"),
    ])
    add(ios_group, "iOS Sources", "PBXGroup", [
        ("children", arr(ios_files)), ("name", '"iOS Sources"'),
        ("path", "Sources"), ("sourceTree", '"<group>"'),
    ])
    add(shared_group, "Shared Folio Sources", "PBXGroup", [
        ("children", arr(shared_files)), ("name", '"Shared Folio Sources"'),
        ("path", "../Sources/Folio"), ("sourceTree", '"<group>"'),
    ])
    add(resource_group, "Resources", "PBXGroup", [
        ("children", arr([info_ref, app_entitlements_ref, catalog_ref] + js_refs)),
        ("path", "Resources"), ("sourceTree", '"<group>"'),
    ])
    widget_group = "group.widget"
    add(widget_group, "Widget Extension", "PBXGroup", [
        ("children", arr(widget_files)),
        ("path", "WidgetExtension"), ("sourceTree", '"<group>"'),
    ])
    add(products_group, "Products", "PBXGroup", [
        ("children", arr([app_ref, widget_app_ref])), ("name", "Products"),
        ("sourceTree", '"<group>"'),
    ])
    add(root_group, "Root", "PBXGroup", [
        ("children", arr([ref(ios_group, "iOS Sources"), ref(shared_group, "Shared Folio Sources"),
                          ref(resource_group, "Resources"), ref(widget_group, "Widget Extension"),
                          ref(products_group, "Products")])),
        ("sourceTree", '"<group>"'),
    ])
    add("config.target.debug", "Debug", "XCBuildConfiguration", [
        ("buildSettings", settings("Debug", target=True)), ("name", "Debug"),
    ])
    add("config.target.release", "Release", "XCBuildConfiguration", [
        ("buildSettings", settings("Release", target=True)), ("name", "Release"),
    ])
    add("config.project.debug", "Debug", "XCBuildConfiguration", [
        ("buildSettings", settings("Debug")), ("name", "Debug"),
    ])
    add("config.project.release", "Release", "XCBuildConfiguration", [
        ("buildSettings", settings("Release")), ("name", "Release"),
    ])
    add("config.list.target", "Target build configuration list", "XCConfigurationList", [
        ("buildConfigurations", arr([ref("config.target.debug", "Debug"), ref("config.target.release", "Release")])),
        ("defaultConfigurationIsVisible", "0"), ("defaultConfigurationName", "Debug"),
    ])
    add("config.list.project", "Project build configuration list", "XCConfigurationList", [
        ("buildConfigurations", arr([ref("config.project.debug", "Debug"), ref("config.project.release", "Release")])),
        ("defaultConfigurationIsVisible", "0"), ("defaultConfigurationName", "Debug"),
    ])
    add("config.widget.debug", "Debug", "XCBuildConfiguration", [
        ("buildSettings", settings("Debug", widget=True)), ("name", "Debug"),
    ])
    add("config.widget.release", "Release", "XCBuildConfiguration", [
        ("buildSettings", settings("Release", widget=True)), ("name", "Release"),
    ])
    add("config.list.widget", "Widget build configuration list", "XCConfigurationList", [
        ("buildConfigurations", arr([ref("config.widget.debug", "Debug"), ref("config.widget.release", "Release")])),
        ("defaultConfigurationIsVisible", "0"), ("defaultConfigurationName", "Debug"),
    ])
    widget_target_id = add("widget.target", "FolioWidgets", "PBXNativeTarget", [
        ("buildConfigurationList", ref("config.list.widget", "Widget build configuration list")),
        ("buildPhases", arr([ref("phase.widget.sources", "Widget Sources"),
                             ref("phase.widget.frameworks", "Widget Frameworks")])),
        ("buildRules", "()"), ("dependencies", "()"),
        ("name", "FolioWidgets"), ("productName", "FolioWidgets"),
        ("productReference", widget_app_ref),
        ("productType", '"com.apple.product-type.app-extension"'),
    ])
    dependency_proxy = add("widget.proxy", "Widget dependency proxy", "PBXContainerItemProxy", [
        ("containerPortal", ref("project", "Project object")),
        ("proxyType", "1"),
        ("remoteGlobalIDString", uid("widget.target")),
        ("remoteInfo", "FolioWidgets"),
    ])
    widget_dependency = add("widget.dependency", "FolioWidgets target dependency", "PBXTargetDependency", [
        ("target", widget_target_id),
        ("targetProxy", dependency_proxy),
    ])
    target_id = add("target", "Folio", "PBXNativeTarget", [
        ("buildConfigurationList", ref("config.list.target", "Target build configuration list")),
        ("buildPhases", arr([ref("phase.sources", "Sources"), ref("phase.frameworks", "Frameworks"),
                             ref("phase.resources", "Resources"), ref("phase.widget.embed", "Embed App Extensions")])),
        ("buildRules", "()"), ("dependencies", arr([widget_dependency])),
        ("name", "Folio"), ("productName", "Folio"),
        ("productReference", app_ref), ("productType", '"com.apple.product-type.application"'),
        ("packageProductDependencies", arr([product_ref])),
    ])
    add("project", "Project object", "PBXProject", [
        ("attributes", f'{{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; TargetAttributes = {{ {uid("target")} = {{ CreatedOnToolsVersion = 27.2; }}; {uid("widget.target")} = {{ CreatedOnToolsVersion = 27.2; }}; }}; }}'),
        ("buildConfigurationList", ref("config.list.project", "Project build configuration list")),
        ("compatibilityVersion", '"Xcode 16.0"'),
        ("developmentRegion", "en"), ("hasScannedForEncodings", "0"),
        ("knownRegions", "(en, Base)"),
        ("mainGroup", ref(root_group, "Root")),
        ("productRefGroup", ref(products_group, "Products")),
        ("projectDirPath", '""'), ("projectRoot", '""'),
        ("packageReferences", arr([package_ref])),
        ("targets", arr([target_id, widget_target_id])),
    ])

    sections = [
        ("PBXBuildFile", "PBXBuildFile"),
        ("PBXContainerItemProxy", "PBXContainerItemProxy"),
        ("PBXCopyFilesBuildPhase", "PBXCopyFilesBuildPhase"),
        ("PBXFileReference", "PBXFileReference"),
        ("PBXFrameworksBuildPhase", "PBXFrameworksBuildPhase"),
        ("PBXGroup", "PBXGroup"),
        ("PBXNativeTarget", "PBXNativeTarget"),
        ("PBXProject", "PBXProject"),
        ("PBXResourcesBuildPhase", "PBXResourcesBuildPhase"),
        ("PBXSourcesBuildPhase", "PBXSourcesBuildPhase"),
        ("PBXTargetDependency", "PBXTargetDependency"),
        ("XCBuildConfiguration", "XCBuildConfiguration"),
        ("XCConfigurationList", "XCConfigurationList"),
        ("XCRemoteSwiftPackageReference", "XCRemoteSwiftPackageReference"),
        ("XCSwiftPackageProductDependency", "XCSwiftPackageProductDependency"),
    ]
    result = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {};",
              "\tobjectVersion = 60;", "\tobjects = {"]
    for title, isa in sections:
        result.append(f"/* Begin {title} section */")
        for key, (label, definition) in objects.items():
            if definition.split("isa = ", 1)[1].split(";", 1)[0] == isa:
                result.append(f"\t\t{uid(key)} /* {label} */ = {definition};")
        result.append(f"/* End {title} section */")
    result += ["\t};", f"\trootObject = {ref('project', 'Project object')};", "}"]
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "project.pbxproj").write_text("\n".join(result) + "\n")

    shared_scheme = PROJECT / "xcshareddata/xcschemes/Folio.xcscheme"
    shared_scheme.parent.mkdir(parents=True, exist_ok=True)
    target = uid("target")
    shared_scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
  <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Folio.app" BlueprintName="Folio" ReferencedContainer="container:FolioiOS.xcodeproj"/>
  </BuildActionEntry></BuildActionEntries>
 </BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Folio.app" BlueprintName="Folio" ReferencedContainer="container:FolioiOS.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    print(f"Generated {PROJECT} with {len(SHARED)} shared Swift sources, {len(IOS)} iOS sources, and {len(js_refs)} bundled JavaScript extensions")


if __name__ == "__main__":
    create()
