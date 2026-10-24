//! The tool-neutral `.agents/` setup for a new worktree, run right after
//! `git worktree add` and before a chat's agent starts in it (graff honors the
//! same files, its ADR 0283):
//!
//! - `.agents/linked` lists repository-relative literal paths, one per line
//!   (`#` comments, a leading `/` allowed). Each entry that is gitignored in the
//!   main checkout, exists there, and is absent in the new worktree becomes a
//!   symlink to the main checkout's copy, so a `.env` edited once is current in
//!   every worktree. Tracked paths, `..`, globs and missing paths are skipped;
//!   nothing is moved or deleted. Unix only (Windows symlinks need privileges).
//! - `.agents/prepare`, committed in the worktree, runs from its root. It
//!   should be fast and safe to repeat. Creation waits up to
//!   [`PREPARE_WAIT`] for it (the forwarded `CreateWorktree` deadline is 120 s);
//!   a longer script keeps running in the background and the chat starts.

use std::path::Path;
use std::time::Duration;

use tokio::process::Command;

/// How long worktree creation waits for `.agents/prepare`.
pub const PREPARE_WAIT: Duration = Duration::from_secs(90);

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Prepared {
    pub linked: usize,
    pub prepare: Option<PrepareOutcome>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum PrepareOutcome {
    Ok,
    Failed {
        code: Option<i32>,
        output_tail: String,
    },
    StillRunning,
    CouldNotStart(String),
}

/// One `.agents/linked` entry as a safe repository-relative path.
pub fn entry_path(line: &str) -> Option<&str> {
    let p = line.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\r');
    if p.is_empty() || p.starts_with('#') {
        return None;
    }
    let p = p.trim_start_matches('/').trim_end_matches('/');
    if p.is_empty() {
        return None;
    }
    for part in p.split('/') {
        if part.is_empty() || part == "." || part == ".." || part.contains(['*', '?', '[', '\\']) {
            return None;
        }
    }
    Some(p)
}

async fn ignored_in(repo: &Path, rel: &str) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["check-ignore", "-q", "--", rel])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Symlink each listed gitignored path from `repo` into `worktree`.
pub async fn link_shared(repo: &Path, worktree: &Path) -> usize {
    #[cfg(not(unix))]
    {
        let _ = (repo, worktree);
        0
    }
    #[cfg(unix)]
    {
        if repo == worktree {
            return 0;
        }
        let text = match std::fs::read_to_string(worktree.join(".agents/linked"))
            .or_else(|_| std::fs::read_to_string(repo.join(".agents/linked")))
        {
            Ok(t) => t,
            Err(_) => return 0,
        };
        let mut n = 0;
        for line in text.lines() {
            let Some(rel) = entry_path(line) else {
                continue;
            };
            let shared = repo.join(rel);
            let local = worktree.join(rel);
            if std::fs::symlink_metadata(&shared).is_err()
                || std::fs::symlink_metadata(&local).is_ok()
            {
                continue;
            }
            if !ignored_in(repo, rel).await {
                continue; // tracked files are never redirected
            }
            if let Some(parent) = local.parent() {
                if std::fs::create_dir_all(parent).is_err() {
                    continue;
                }
            }
            if std::os::unix::fs::symlink(&shared, &local).is_ok() {
                n += 1;
            }
        }
        n
    }
}

/// Run the worktree's `.agents/prepare`, waiting at most `wait`.
pub async fn run_prepare(worktree: &Path, wait: Duration) -> Option<PrepareOutcome> {
    let script = worktree.join(".agents/prepare");
    if !script.is_file() {
        return None;
    }
    #[cfg(unix)]
    let executable = {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(&script)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    };
    #[cfg(not(unix))]
    let executable = false;
    let mut cmd = if executable {
        Command::new("./.agents/prepare")
    } else {
        let mut c = Command::new("sh");
        c.arg("./.agents/prepare");
        c
    };
    cmd.current_dir(worktree)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(false);
    let child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return Some(PrepareOutcome::CouldNotStart(e.to_string())),
    };
    match tokio::time::timeout(wait, child.wait_with_output()).await {
        Ok(Ok(out)) if out.status.success() => Some(PrepareOutcome::Ok),
        Ok(Ok(out)) => {
            let mut all = String::from_utf8_lossy(&out.stdout).into_owned();
            all.push_str(&String::from_utf8_lossy(&out.stderr));
            let tail: String = all
                .chars()
                .rev()
                .take(2000)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            Some(PrepareOutcome::Failed {
                code: out.status.code(),
                output_tail: tail,
            })
        }
        Ok(Err(e)) => Some(PrepareOutcome::CouldNotStart(e.to_string())),
        Err(_) => Some(PrepareOutcome::StillRunning),
    }
}

/// Link shared files, then run the prepare script, for a freshly added worktree.
pub async fn prepare_worktree(repo: &Path, worktree: &Path) -> Prepared {
    let linked = link_shared(repo, worktree).await;
    let prepare = run_prepare(worktree, PREPARE_WAIT).await;
    match &prepare {
        Some(PrepareOutcome::Ok) | None => {}
        Some(outcome) => {
            tracing::warn!(worktree = %worktree.display(), ?outcome, ".agents/prepare did not finish cleanly")
        }
    }
    if linked > 0 || prepare.is_some() {
        tracing::info!(worktree = %worktree.display(), linked, prepared = ?prepare, "prepared worktree from .agents/");
    }
    Prepared { linked, prepare }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_are_literal_repo_relative_paths() {
        assert_eq!(entry_path("/.env"), Some(".env"));
        assert_eq!(entry_path("  config/local/ \r"), Some("config/local"));
        for bad in [
            "",
            "  ",
            "# secrets",
            "/",
            "../x",
            "a/../b",
            "./x",
            "*.env",
            "certs/**",
            "a//b",
        ] {
            assert_eq!(entry_path(bad), None, "{bad:?}");
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_new_worktree_links_shared_files_and_runs_prepare() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        std::fs::create_dir_all(repo.join(".agents")).unwrap();
        let git = |args: &[&str], cwd: &Path| {
            assert!(
                std::process::Command::new("git")
                    .args(args)
                    .current_dir(cwd)
                    .status()
                    .unwrap()
                    .success()
            );
        };
        git(&["init", "-q", "-b", "main"], &repo);
        git(&["config", "user.email", "t@t"], &repo);
        git(&["config", "user.name", "t"], &repo);
        std::fs::write(repo.join(".gitignore"), ".env\nprepared\n").unwrap();
        std::fs::write(repo.join("tracked.cfg"), "tracked\n").unwrap();
        std::fs::write(
            repo.join(".agents/linked"),
            "/.env\ntracked.cfg\n../escape\nmissing\n",
        )
        .unwrap();
        std::fs::write(repo.join(".agents/prepare"), "#!/bin/sh\npwd > prepared\n").unwrap();
        std::fs::set_permissions(
            repo.join(".agents/prepare"),
            std::fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        git(&["add", "."], &repo);
        git(&["commit", "-qm", "init"], &repo);
        std::fs::write(repo.join(".env"), "TOKEN=one\n").unwrap();
        let wt = dir.path().join("wt");
        git(
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "w",
                wt.to_str().unwrap(),
                "main",
            ],
            &repo,
        );

        let prepared = prepare_worktree(&repo, &wt).await;
        assert_eq!(
            prepared,
            Prepared {
                linked: 1,
                prepare: Some(PrepareOutcome::Ok)
            }
        );
        assert!(
            std::fs::symlink_metadata(wt.join(".env"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        std::fs::write(repo.join(".env"), "TOKEN=two\n").unwrap();
        assert_eq!(
            std::fs::read_to_string(wt.join(".env")).unwrap(),
            "TOKEN=two\n"
        );
        assert!(
            !std::fs::symlink_metadata(wt.join("tracked.cfg"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            std::fs::read_to_string(wt.join("prepared")).unwrap().trim(),
            wt.canonicalize().unwrap().to_string_lossy()
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_failing_or_slow_prepare_is_reported_not_fatal() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".agents")).unwrap();
        std::fs::write(
            dir.path().join(".agents/prepare"),
            "echo broke >&2\nexit 3\n",
        )
        .unwrap();
        match run_prepare(dir.path(), Duration::from_secs(10)).await {
            Some(PrepareOutcome::Failed {
                code: Some(3),
                output_tail,
            }) => assert!(output_tail.contains("broke")),
            other => panic!("{other:?}"),
        }
        std::fs::write(dir.path().join(".agents/prepare"), "sleep 5\n").unwrap();
        assert_eq!(
            run_prepare(dir.path(), Duration::from_millis(200)).await,
            Some(PrepareOutcome::StillRunning)
        );
        assert_eq!(
            run_prepare(&dir.path().join("none"), Duration::from_secs(1)).await,
            None
        );
    }
}
