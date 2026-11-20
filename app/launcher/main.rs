// Starts the native Folio app built by build.rs, passing every argument through
// (including `--screenshot <file.png>`).
use std::{env, os::unix::process::CommandExt, path::PathBuf, process::Command};

fn main() {
    let mut candidates = vec![PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("Folio.app/Contents/MacOS/Folio")];
    if let Ok(exe) = env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("Folio.app/Contents/MacOS/Folio"));
            candidates.push(dir.join("../../Folio.app/Contents/MacOS/Folio"));
        }
    }
    let Some(app) = candidates.into_iter().find(|p| p.exists()) else {
        eprintln!("Folio.app wasn't found; run `cargo build` in the app folder first.");
        std::process::exit(1);
    };
    let err = Command::new(&app).args(env::args_os().skip(1)).exec();
    eprintln!("couldn't start {}: {err}", app.display());
    std::process::exit(1);
}
