//! Synthetic Git ref-layout and retitling edge cases for task-named worktrees.

use std::path::Path;
use std::process::Command;

use harness_engine::Repos;
use sha2::{Digest, Sha256};

fn git(path: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .current_dir(path)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().into()
}

fn setup(root: &Path) -> (std::path::PathBuf, Repos) {
    let repo = root.join("sample-app");
    std::fs::create_dir(&repo).unwrap();
    git(&repo, &["init", "-b", "main"]);
    git(
        &repo,
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "--allow-empty",
            "-m",
            "initial",
        ],
    );
    let repos = Repos::with_worktrees_root(&root.join("data"), "test", root.join("trees"));
    (repo, repos)
}

#[tokio::test]
async fn allocation_skips_descendant_ref_conflicts_including_packed_and_case_only_refs() {
    for packed in [false, true] {
        for user_branch in ["task/fix-login/review", "TASK/FIX-LOGIN/review"] {
            let tmp = tempfile::tempdir().unwrap();
            let (repo, repos) = setup(tmp.path());
            git(&repo, &["branch", user_branch]);
            if packed {
                git(&repo, &["pack-refs", "--all"]);
            }
            let before = git(&repo, &["rev-parse", user_branch]);
            let tree = repos
                .create_worktree_for_task(&repo, "main", "Fix login")
                .await
                .unwrap();
            assert_eq!(tree.branch, "task/fix-login-2");
            assert_eq!(git(&repo, &["rev-parse", user_branch]), before);
            assert!(!tmp.path().join("trees/sample-app/fix-login").exists());
            repos
                .delete_worktree(&repo, Path::new(&tree.path))
                .await
                .unwrap();
            assert!(
                repos
                    .branches(&repo)
                    .await
                    .unwrap()
                    .contains(&user_branch.to_string())
            );
        }
    }
}

#[tokio::test]
async fn title_rename_uses_a_suffix_for_a_descendant_ref_conflict() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let user_branch = "task/fix-profile/review";
    git(&repo, &["branch", user_branch]);
    git(&repo, &["pack-refs", "--all"]);
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    let path = Path::new(&tree.path);
    let head = git(path, &["rev-parse", "HEAD"]);
    let renamed = repos
        .rename_worktree_branch(path, &tree.branch, "Fix profile")
        .await
        .unwrap();
    assert!(renamed.starts_with("task/fix-profile-"));
    assert_eq!(renamed.len(), "task/fix-profile-".len() + 6);
    assert_eq!(git(path, &["rev-parse", "HEAD"]), head);
    let owner = git(
        &repo,
        &[
            "config",
            "--local",
            "--get",
            &format!("branch.{renamed}.harness-worktree"),
        ],
    );
    let owner: serde_json::Value = serde_json::from_str(&owner).unwrap();
    assert_eq!(owner["branch"], renamed);
    repos.delete_worktree(&repo, path).await.unwrap();
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&user_branch.to_string())
    );
}

#[tokio::test]
async fn both_title_targets_occupied_leave_the_original_branch_and_ownership_untouched() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    let path = Path::new(&tree.path);
    let hash = format!("{:x}", Sha256::digest(tree.path.as_bytes()));
    let preferred = "task/fix-profile";
    let fallback = format!("{preferred}-{}", &hash[..6]);
    git(&repo, &["branch", preferred]);
    git(&repo, &["branch", &fallback]);
    let key = format!("branch.{}.harness-worktree", tree.branch);
    let owner = git(&repo, &["config", "--local", "--get", &key]);
    let head = git(path, &["rev-parse", "HEAD"]);
    let result = repos
        .rename_worktree_branch(path, &tree.branch, "Fix profile")
        .await;
    assert!(
        result.is_err(),
        "neither a user ref nor its stable-suffix collision may be overwritten"
    );
    assert_eq!(git(path, &["branch", "--show-current"]), tree.branch);
    assert_eq!(git(path, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&repo, &["config", "--local", "--get", &key]), owner);
    // A refused title must release its mutation locks and retain cleanup authority.
    repos.delete_worktree(&repo, path).await.unwrap();
    assert_eq!(git(&repo, &["rev-parse", preferred]), head);
    assert_eq!(git(&repo, &["rev-parse", &fallback]), head);
    assert!(!repos.branches(&repo).await.unwrap().contains(&tree.branch));
}

#[tokio::test]
async fn similar_ref_prefixes_do_not_collide_without_a_component_boundary() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let sibling = "task/fix-login-extra";
    git(&repo, &["branch", sibling]);
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    assert_eq!(tree.branch, "task/fix-login");
    let renamed = repos
        .rename_worktree_branch(Path::new(&tree.path), &tree.branch, "Fix log")
        .await
        .unwrap();
    assert_eq!(renamed, "task/fix-log");
    repos
        .delete_worktree(&repo, Path::new(&tree.path))
        .await
        .unwrap();
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&sibling.to_string())
    );
}

#[tokio::test]
async fn detached_checkouts_are_not_retitled_or_used_to_delete_the_old_branch() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    let path = Path::new(&tree.path);
    let head = git(path, &["rev-parse", "HEAD"]);
    git(path, &["switch", "--detach"]);
    let actual = repos
        .rename_worktree_branch(path, &tree.branch, "Different task")
        .await
        .unwrap();
    assert_eq!(
        actual, "HEAD",
        "detached state uses the existing current_branch contract"
    );
    assert!(git(path, &["branch", "--show-current"]).is_empty());
    assert_eq!(git(path, &["rev-parse", "HEAD"]), head);
    repos.delete_worktree(&repo, path).await.unwrap();
    assert_eq!(git(&repo, &["rev-parse", &tree.branch]), head);
    assert!(
        !repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&"task/different-task".to_string())
    );
}

fn advance_main(repo: &Path) -> (String, String) {
    let before = git(repo, &["rev-parse", "refs/heads/main"]);
    git(
        repo,
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "--allow-empty",
            "-m",
            "advance synthetic main",
        ],
    );
    let after = git(repo, &["rev-parse", "refs/heads/main"]);
    assert_ne!(before, after);
    (before, after)
}

#[tokio::test]
async fn a_selected_local_base_is_not_shadowed_by_a_same_named_tag() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let (old, current) = advance_main(&repo);
    git(&repo, &["tag", "main", &old]);
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    assert_eq!(
        git(Path::new(&tree.path), &["rev-parse", "HEAD"]),
        current,
        "the selected branch, not the older tag, must supply the base"
    );
    assert_eq!(git(&repo, &["rev-parse", "refs/tags/main"]), old);
    assert_eq!(git(&repo, &["rev-parse", "refs/heads/main"]), current);
}

#[tokio::test]
async fn a_selected_remote_base_is_not_shadowed_by_a_same_named_tag() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let (old, current) = advance_main(&repo);
    git(&repo, &["remote", "add", "origin", repo.to_str().unwrap()]);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &current]);
    git(&repo, &["tag", "origin/main", &old]);
    let tree = repos
        .create_worktree_for_task(&repo, "origin/main", "Fix login")
        .await
        .unwrap();
    assert_eq!(
        git(Path::new(&tree.path), &["rev-parse", "HEAD"]),
        current,
        "the selected remote ref must supply the base"
    );
    assert_eq!(
        git(
            &repo,
            &[
                "config",
                "--local",
                "--get",
                &format!("branch.{}.remote", tree.branch)
            ]
        ),
        "origin"
    );
    assert_eq!(
        git(
            &repo,
            &[
                "config",
                "--local",
                "--get",
                &format!("branch.{}.merge", tree.branch)
            ]
        ),
        "refs/heads/main"
    );
    assert_eq!(git(&repo, &["rev-parse", "refs/tags/origin/main"]), old);
    assert_eq!(
        git(&repo, &["rev-parse", "refs/remotes/origin/main"]),
        current
    );
}

#[tokio::test]
async fn explicit_tags_and_full_snapshot_ids_keep_their_exact_commits() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let (old, current) = advance_main(&repo);
    git(&repo, &["tag", "snapshot", &old]);
    git(&repo, &["branch", "snapshot", &current]);
    // Full object ids are used by independent recovery. Even a pathological
    // local branch with the same spelling must not redirect that snapshot.
    git(&repo, &["branch", &old, &current]);
    let hash_named_branch = format!("refs/heads/{old}");
    add_remote_branch(&repo, "origin", "main", &old);
    git(
        &repo,
        &[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main",
        ],
    );
    for (base, expected) in [
        (old.as_str(), &old),
        ("refs/tags/snapshot", &old),
        ("refs/heads/snapshot", &current),
        (hash_named_branch.as_str(), &current),
        // Remote default-branch aliases must not reinterpret the HEAD revision.
        ("HEAD", &current),
    ] {
        let tree = repos
            .create_worktree_for_task(&repo, base, "Recover recorded snapshot")
            .await
            .unwrap();
        let path = Path::new(&tree.path);
        assert_eq!(git(path, &["rev-parse", "HEAD"]), *expected);
        repos.delete_worktree(&repo, path).await.unwrap();
    }
    assert_eq!(
        git(&repo, &["rev-parse", &format!("refs/heads/{old}")]),
        current
    );
    assert_eq!(git(&repo, &["rev-parse", "refs/heads/main"]), current);
}

#[cfg(unix)]
#[tokio::test]
async fn occupied_symlink_destinations_are_never_followed_or_replaced() {
    for broken in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let (repo, repos) = setup(tmp.path());
        let destination = tmp.path().join("trees/sample-app/fix-login");
        std::fs::create_dir_all(destination.parent().unwrap()).unwrap();
        let target = tmp.path().join("unrelated-folder");
        if !broken {
            std::fs::create_dir(&target).unwrap();
            std::fs::write(target.join("keep.txt"), b"preserve symlink target\n").unwrap();
        }
        std::os::unix::fs::symlink(&target, &destination).unwrap();
        let tree = repos
            .create_worktree_for_task(&repo, "main", "Fix login")
            .await
            .unwrap();
        assert_eq!(tree.branch, "task/fix-login-2");
        assert_eq!(std::fs::read_link(&destination).unwrap(), target);
        if broken {
            assert!(!target.exists());
        } else {
            assert_eq!(
                std::fs::read(target.join("keep.txt")).unwrap(),
                b"preserve symlink target\n"
            );
            assert!(!target.join(".git").exists());
        }
        repos
            .delete_worktree(&repo, Path::new(&tree.path))
            .await
            .unwrap();
        assert!(
            std::fs::symlink_metadata(&destination)
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
}

#[tokio::test]
async fn exhausting_the_name_budget_preserves_existing_directories_and_allows_a_retry() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let base = tmp.path().join("trees/sample-app");
    std::fs::create_dir_all(&base).unwrap();
    for index in 1..=1_000 {
        let name = if index == 1 {
            "fix-login".to_string()
        } else {
            format!("fix-login-{index}")
        };
        std::fs::create_dir(base.join(name)).unwrap();
    }
    std::fs::write(base.join("fix-login/keep.txt"), b"existing folder\n").unwrap();
    let result = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await;
    assert!(result.is_err());
    assert_eq!(std::fs::read_dir(&base).unwrap().count(), 1_000);
    assert_eq!(
        std::fs::read(base.join("fix-login/keep.txt")).unwrap(),
        b"existing folder\n"
    );
    assert_eq!(repos.branches(&repo).await.unwrap(), ["main"]);
    // Release only a known-empty synthetic directory, not any person's work.
    std::fs::remove_dir(base.join("fix-login-1000")).unwrap();
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    assert_eq!(tree.branch, "task/fix-login-1000");
    repos
        .delete_worktree(&repo, Path::new(&tree.path))
        .await
        .unwrap();
    assert_eq!(std::fs::read_dir(&base).unwrap().count(), 999);
}

fn add_remote_branch(repo: &Path, remote: &str, branch: &str, commit: &str) {
    // Configuration/ref writes only: no clone, fetch, or external API requests.
    git(repo, &["remote", "add", remote, repo.to_str().unwrap()]);
    git(
        repo,
        &[
            "update-ref",
            &format!("refs/remotes/{remote}/{branch}"),
            commit,
        ],
    );
}

#[tokio::test]
async fn remote_only_origin_branch_picker_labels_round_trip_to_worktree_creation() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let (_, current) = advance_main(&repo);
    let selected = "feature/login";
    add_remote_branch(&repo, "origin", selected, &current);
    let labels = repos.branches(&repo).await.unwrap();
    assert!(labels.contains(&selected.to_string()));
    let tree = repos
        .create_worktree_for_task(&repo, selected, "Fix login")
        .await
        .unwrap();
    assert_eq!(git(Path::new(&tree.path), &["rev-parse", "HEAD"]), current);
    assert_eq!(
        git(
            &repo,
            &[
                "config",
                "--local",
                "--get",
                &format!("branch.{}.remote", tree.branch)
            ]
        ),
        "origin"
    );
    assert_eq!(
        git(
            &repo,
            &[
                "config",
                "--local",
                "--get",
                &format!("branch.{}.merge", tree.branch)
            ]
        ),
        "refs/heads/feature/login"
    );
    repos
        .delete_worktree(&repo, Path::new(&tree.path))
        .await
        .unwrap();
    assert_eq!(
        git(&repo, &["rev-parse", "refs/remotes/origin/feature/login"]),
        current
    );
}

#[tokio::test]
async fn a_unique_non_origin_remote_base_beats_a_same_named_tag() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let (old, current) = advance_main(&repo);
    let selected = "feature/login";
    add_remote_branch(&repo, "upstream", selected, &current);
    git(&repo, &["tag", selected, &old]);
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&selected.to_string())
    );
    let tree = repos
        .create_worktree_for_task(&repo, selected, "Fix login")
        .await
        .unwrap();
    assert_eq!(git(Path::new(&tree.path), &["rev-parse", "HEAD"]), current);
    assert_eq!(
        git(
            &repo,
            &[
                "config",
                "--local",
                "--get",
                &format!("branch.{}.remote", tree.branch)
            ]
        ),
        "upstream"
    );
    repos
        .delete_worktree(&repo, Path::new(&tree.path))
        .await
        .unwrap();
    assert_eq!(git(&repo, &["rev-parse", "refs/tags/feature/login"]), old);
}

#[tokio::test]
async fn ambiguous_remote_picker_labels_fail_closed_instead_of_using_a_tag() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let (old, current) = advance_main(&repo);
    let selected = "feature/login";
    add_remote_branch(&repo, "origin", selected, &old);
    add_remote_branch(&repo, "upstream", selected, &current);
    git(&repo, &["tag", selected, &old]);
    git(
        &repo,
        &[
            "config",
            "--local",
            "checkout.defaultRemote",
            "synthetic-no-preference",
        ],
    );
    let before = repos.branches(&repo).await.unwrap();
    let result = repos
        .create_worktree_for_task(&repo, selected, "Fix login")
        .await;
    assert!(
        result.is_err(),
        "a picker label shared by remotes must not silently select a tag or arbitrary remote"
    );
    assert_eq!(repos.branches(&repo).await.unwrap(), before);
    assert!(!tmp.path().join("trees/sample-app/fix-login").exists());
    // An explicit choice must still work after the failed request released its lock.
    let tree = repos
        .create_worktree_for_task(&repo, "upstream/feature/login", "Fix login")
        .await
        .unwrap();
    assert_eq!(git(Path::new(&tree.path), &["rev-parse", "HEAD"]), current);
    assert_eq!(
        git(&repo, &["rev-parse", "refs/remotes/origin/feature/login"]),
        old
    );
    assert_eq!(git(&repo, &["rev-parse", "refs/tags/feature/login"]), old);
}

#[tokio::test]
async fn an_explicit_default_remote_disambiguates_a_shared_picker_label() {
    for preferred in ["origin", "upstream"] {
        let tmp = tempfile::tempdir().unwrap();
        let (repo, repos) = setup(tmp.path());
        let (old, current) = advance_main(&repo);
        let selected = "feature/login";
        add_remote_branch(&repo, "origin", selected, &old);
        add_remote_branch(&repo, "upstream", selected, &current);
        git(
            &repo,
            &["config", "--local", "checkout.defaultRemote", preferred],
        );
        let tree = repos
            .create_worktree_for_task(&repo, selected, "Fix login")
            .await
            .unwrap();
        let expected = if preferred == "origin" {
            &old
        } else {
            &current
        };
        assert_eq!(
            git(Path::new(&tree.path), &["rev-parse", "HEAD"]),
            *expected
        );
        assert_eq!(
            git(
                &repo,
                &[
                    "config",
                    "--local",
                    "--get",
                    &format!("branch.{}.remote", tree.branch)
                ]
            ),
            preferred
        );
        repos
            .delete_worktree(&repo, Path::new(&tree.path))
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn an_existing_local_branch_wins_over_remote_labels_and_tags() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, repos) = setup(tmp.path());
    let (old, current) = advance_main(&repo);
    let selected = "feature/login";
    git(&repo, &["branch", selected, &old]);
    add_remote_branch(&repo, "origin", selected, &current);
    git(&repo, &["tag", selected, &current]);
    let tree = repos
        .create_worktree_for_task(&repo, selected, "Fix login")
        .await
        .unwrap();
    assert_eq!(git(Path::new(&tree.path), &["rev-parse", "HEAD"]), old);
    repos
        .delete_worktree(&repo, Path::new(&tree.path))
        .await
        .unwrap();
    assert_eq!(git(&repo, &["rev-parse", "refs/heads/feature/login"]), old);
    assert_eq!(
        git(&repo, &["rev-parse", "refs/remotes/origin/feature/login"]),
        current
    );
    assert_eq!(
        git(&repo, &["rev-parse", "refs/tags/feature/login"]),
        current
    );
}
