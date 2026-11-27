// Builds the SwiftPM app and genuine Xcode WidgetKit extension, then assembles Folio.app.
use std::{env, fs, path::PathBuf, process::Command};

fn main() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    println!("cargo:rerun-if-changed=Package.swift");
    println!("cargo:rerun-if-changed=Core");
    println!("cargo:rerun-if-changed=Mac");
    println!("cargo:rerun-if-changed=iOS/Sources");
    println!("cargo:rerun-if-changed=Support");
    println!("cargo:rerun-if-changed=WidgetExtension");
    println!("cargo:rerun-if-env-changed=FOLIO_SIGN_IDENTITY");

    let mut swift = Command::new("swift");
    swift.args(["build", "-c", "release", "--package-path"]).arg(&root).current_dir(&root);
    remove_cargo_environment(&mut swift);
    run(&mut swift, "swift build");

    // A SwiftPM executable hand-wrapped as .appex cannot serve WidgetKit correctly
    // on recent macOS. Xcode must link the widget as an app-extension (XPC!).
    let mut xcode = Command::new("xcodebuild");
    xcode.args(["-project"])
        .arg(root.join("WidgetExtension/FolioWidgets.xcodeproj"))
        .args(["-scheme", "FolioWidgets", "-configuration", "Release", "-sdk", "macosx", "-derivedDataPath"])
        .arg(root.join(".build/widget-derived"))
        .args(["CODE_SIGNING_ALLOWED=NO", "build"])
        .current_dir(&root);
    remove_cargo_environment(&mut xcode);
    run(&mut xcode, "xcodebuild FolioWidgets");

    let bin = root.join(".build/release/Folio");
    let app = root.join("Folio.app/Contents");
    fs::create_dir_all(app.join("MacOS")).unwrap();
    fs::create_dir_all(app.join("Resources")).unwrap();
    fs::copy(&bin, app.join("MacOS/Folio")).expect("copy Folio binary");
    fs::copy(root.join("Support/Info.plist"), app.join("Info.plist")).expect("copy Info.plist");
    // Compiles Support/AppIcon.icon into Assets.car + AppIcon.icns.
    run(Command::new(root.join("Support/compile-macos-icon.sh")).arg(app.join("Resources")), "compile AppIcon");

    let built_widget = root.join(".build/widget-derived/Build/Products/Release/FolioWidgets.appex");
    assert!(built_widget.is_dir(), "Xcode did not produce FolioWidgets.appex");
    let plugins = app.join("PlugIns");
    fs::create_dir_all(&plugins).expect("create PlugIns");
    let widget = plugins.join("FolioWidgets.appex");
    if widget.exists() { fs::remove_dir_all(&widget).expect("remove previous FolioWidgets.appex"); }
    run(Command::new("ditto").arg(&built_widget).arg(&widget), "copy FolioWidgets.appex");

    let identity = signing_identity();
    let widget_entitlements = if identity == "-" {
        // Ad-hoc signatures have no Team ID and cannot claim a shared App Group.
        // The widget still needs its sandbox entitlement to run in WidgetKit.
        let path = root.join(".build/folio-widget-adhoc.entitlements");
        fs::write(&path, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>")
            .expect("write ad-hoc widget entitlements");
        path
    } else {
        root.join("WidgetExtension/FolioWidgets.entitlements")
    };
    sign(&widget, &identity, Some(&widget_entitlements));
    sign(&root.join("Folio.app"), &identity,
         (identity != "-").then(|| root.join("Support/Folio.entitlements")).as_ref());

    run(Command::new("codesign").args(["--verify", "--deep", "--strict"])
        .arg(root.join("Folio.app")), "verify signed Folio.app");
}

fn remove_cargo_environment(command: &mut Command) {
    // Cargo's environment can confuse the Swift and Xcode toolchains.
    for (key, _) in env::vars() {
        if key.starts_with("CARGO") || key.starts_with("RUSTC") || key == "TARGET" || key == "HOST" || key == "OUT_DIR"
            || key == "CC" || key == "CXX" || key == "CFLAGS" || key == "LDFLAGS" || key == "OPT_LEVEL"
            || key == "PROFILE" || key == "DEBUG" || key == "NUM_JOBS" {
            command.env_remove(&key);
        }
    }
}

fn run(command: &mut Command, what: &str) {
    let status = command.status().unwrap_or_else(|e| panic!("could not run {what}: {e}"));
    assert!(status.success(), "{what} failed with {status}");
}

fn signing_identity() -> String {
    if let Ok(explicit) = env::var("FOLIO_SIGN_IDENTITY") {
        return if explicit.is_empty() { "-".into() } else { explicit };
    }
    // Prefer the single identity installed on a developer Mac without
    // committing the developer's name, Team ID or certificate fingerprint.
    let Ok(output) = Command::new("security")
        .args(["find-identity", "-v", "-p", "codesigning"]).output() else {
        return "-".into();
    };
    if !output.status.success() { return "-".into(); }
    let text = String::from_utf8_lossy(&output.stdout);
    let identities: Vec<_> = text.lines().filter_map(|line| {
        let (prefix, _) = line.split_once('"')?;
        let hash = prefix.split_whitespace().last()?;
        (hash.len() == 40 && hash.bytes().all(|c| c.is_ascii_hexdigit())).then(|| hash.to_owned())
    }).collect();
    if identities.len() == 1 { identities[0].clone() } else { "-".into() }
}

fn sign(bundle: &std::path::Path, identity: &str, entitlements: Option<&PathBuf>) {
    let mut command = Command::new("codesign");
    command.args(["--force", "--sign", identity, "--timestamp=none"]);
    if let Some(entitlements) = entitlements {
        command.arg("--entitlements").arg(entitlements);
    }
    run(command.arg(bundle), "codesign");
}
