//! The terminal client (`graff tui`) that matches this Harness build.
//!
//! Each Harness release attaches `harness-tui-<version>-<os>-<arch>.tar.gz`
//! with a `.sha256` beside it (`tui/package.sh`). graff never downloads it,
//! so the app installs the one for its own version into
//! `~/.harness/tui/<version>`, where `~/.local/bin/graff-tui` points, and
//! removes older versions. Without this a machine kept whichever TUI was
//! installed first, and missed every bridge fix after it.

use std::path::{Path, PathBuf};
use std::time::Duration;

use sha2::{Digest, Sha256};

const RELEASES: &str = "https://github.com/justrach/harness/releases/download";
const MAX_TARBALL_BYTES: usize = 128 * 1024 * 1024;

/// `~/.harness/tui`, where every installed version lives.
pub fn root() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".harness").join("tui"))
}

/// The release asset's base name for this machine, without `.tar.gz`.
fn asset_stem(version: &str) -> Option<String> {
    let os = match std::env::consts::OS {
        "macos" => "macos",
        "linux" => "linux",
        _ => return None,
    };
    let arch = match std::env::consts::ARCH {
        "aarch64" => "aarch64",
        "x86_64" => "x86_64",
        _ => return None,
    };
    Some(format!("harness-tui-{version}-{os}-{arch}"))
}

/// `graff-tui` inside an installed version, when that install is complete.
pub fn installed(root: &Path, version: &str) -> Option<PathBuf> {
    let dir = root.join(version);
    let entry = dir.join("bin").join("graff-tui");
    (entry.is_file() && dir.join("libexec").join("harness-tui-bridge").is_file()).then_some(entry)
}

/// Install this version's TUI unless it is already there, then drop the
/// others. Returns the `graff-tui` entry point.
pub async fn ensure_installed(version: &str) -> anyhow::Result<PathBuf> {
    let root = root().ok_or_else(|| anyhow::anyhow!("no home directory"))?;
    if let Some(entry) = installed(&root, version) {
        prune(&root, version);
        return Ok(entry);
    }
    let stem = asset_stem(version)
        .ok_or_else(|| anyhow::anyhow!("no terminal client build for this platform"))?;
    let client = reqwest::Client::builder()
        .user_agent("harness-tui-installer")
        .timeout(Duration::from_secs(10 * 60))
        .build()?;
    let url = format!("{RELEASES}/v{version}/{stem}.tar.gz");
    let sums = client
        .get(format!("{url}.sha256"))
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    let expected = sums
        .split_whitespace()
        .next()
        .filter(|sha| sha.len() == 64)
        .map(str::to_ascii_lowercase)
        .ok_or_else(|| anyhow::anyhow!("{stem}.tar.gz.sha256 has no digest"))?;
    let mut response = client.get(&url).send().await?.error_for_status()?;
    let mut tarball = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        anyhow::ensure!(
            tarball.len().saturating_add(chunk.len()) <= MAX_TARBALL_BYTES,
            "the terminal client download is unexpectedly large"
        );
        tarball.extend_from_slice(&chunk);
    }
    let version = version.to_string();
    tokio::task::spawn_blocking(move || {
        let entry = unpack(&root, &version, &stem, &tarball, &expected)?;
        prune(&root, &version);
        Ok(entry)
    })
    .await?
}

/// Verify the tarball, unpack it beside the final directory, and rename it
/// into place, so a killed install never passes for a complete one.
fn unpack(
    root: &Path,
    version: &str,
    stem: &str,
    tarball: &[u8],
    expected: &str,
) -> anyhow::Result<PathBuf> {
    let actual = format!("{:x}", Sha256::digest(tarball));
    anyhow::ensure!(
        actual == expected,
        "checksum mismatch for {stem}.tar.gz (expected {expected}, got {actual})"
    );
    std::fs::create_dir_all(root)?;
    let work = root.join(format!(".install-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&work)?;
    let result = (|| {
        let archive = work.join(format!("{stem}.tar.gz"));
        std::fs::write(&archive, tarball)?;
        let status = std::process::Command::new("tar")
            .arg("-xzf")
            .arg(&archive)
            .arg("-C")
            .arg(&work)
            .status()?;
        anyhow::ensure!(status.success(), "couldn't unpack {stem}.tar.gz");
        let unpacked = work.join(stem);
        anyhow::ensure!(
            unpacked.join("bin").join("harness-tui").is_file()
                && unpacked
                    .join("libexec")
                    .join("harness-tui-bridge")
                    .is_file(),
            "{stem}.tar.gz is not a terminal client release"
        );
        let dest = root.join(version);
        if dest.exists() {
            // An earlier install that didn't finish.
            std::fs::remove_dir_all(&dest)?;
        }
        std::fs::rename(&unpacked, &dest)?;
        installed(root, version).ok_or_else(|| anyhow::anyhow!("{stem}.tar.gz has no graff-tui"))
    })();
    let _ = std::fs::remove_dir_all(&work);
    result
}

/// Remove every other installed version, and leftovers of killed installs.
/// The TUI's own state (`codex-home`) and anything that isn't a version stay.
fn prune(root: &Path, keep: &str) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let is_version = name.split('.').count() >= 3
            && name
                .split('.')
                .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()));
        if (is_version && name != keep) || name.starts_with(".install-") {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tarball shaped like `tui/package.sh`'s output.
    fn release_tarball(dir: &Path, stem: &str) -> Vec<u8> {
        let stage = dir.join("stage");
        let top = stage.join(stem);
        std::fs::create_dir_all(top.join("bin")).unwrap();
        std::fs::create_dir_all(top.join("libexec")).unwrap();
        std::fs::write(top.join("bin").join("harness-tui"), "#!/bin/sh\n").unwrap();
        std::fs::write(top.join("libexec").join("harness-tui"), "tui").unwrap();
        std::fs::write(top.join("libexec").join("harness-tui-bridge"), "bridge").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("harness-tui", top.join("bin").join("graff-tui")).unwrap();
        let tarball = dir.join("t.tar.gz");
        let status = std::process::Command::new("tar")
            .arg("-czf")
            .arg(&tarball)
            .arg("-C")
            .arg(&stage)
            .arg(stem)
            .status()
            .unwrap();
        assert!(status.success());
        std::fs::read(tarball).unwrap()
    }

    #[cfg(unix)]
    #[test]
    fn installs_the_release_and_removes_older_versions() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("tui");
        let stem = "harness-tui-0.2.115-macos-aarch64";
        let tarball = release_tarball(dir.path(), stem);
        let sha = format!("{:x}", Sha256::digest(&tarball));
        std::fs::create_dir_all(root.join("0.2.109").join("bin")).unwrap();
        std::fs::create_dir_all(root.join("codex-home")).unwrap();
        std::fs::create_dir_all(root.join(".install-stale")).unwrap();

        let entry = unpack(&root, "0.2.115", stem, &tarball, &sha).unwrap();
        prune(&root, "0.2.115");

        assert_eq!(entry, root.join("0.2.115").join("bin").join("graff-tui"));
        assert_eq!(installed(&root, "0.2.115"), Some(entry));
        assert!(!root.join("0.2.109").exists(), "older version removed");
        assert!(
            !root.join(".install-stale").exists(),
            "killed install removed"
        );
        assert!(
            root.join("codex-home").exists(),
            "the TUI's own state stays"
        );
    }

    #[test]
    fn refuses_a_tarball_that_does_not_match_its_digest() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("tui");
        let err = unpack(
            &root,
            "0.2.115",
            "harness-tui-0.2.115-macos-aarch64",
            b"x",
            &"0".repeat(64),
        )
        .unwrap_err();
        assert!(err.to_string().contains("checksum mismatch"), "{err}");
        assert!(installed(&root, "0.2.115").is_none());
    }
}
