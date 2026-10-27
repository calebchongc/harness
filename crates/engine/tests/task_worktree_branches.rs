//! Synthetic, non-Harness repositories: naming is task-derived, while cleanup
//! authority comes from local ownership metadata rather than a branch prefix.

use std::path::Path;
use std::process::Command;

use harness_engine::Repos;

fn git(cwd: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

fn init_repo(path: &Path) {
    std::fs::create_dir_all(path).unwrap();
    git(path, &["init", "-b", "main"]);
    git(
        path,
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
}

#[tokio::test]
async fn task_worktrees_are_descriptive_and_do_not_reuse_user_branches() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    let task = "Fix login redirect after sign-in";
    let user_branch = "task/fix-login-redirect-after-sign-in";
    git(&repo, &["branch", user_branch]);
    std::fs::write(repo.join("uncommitted.txt"), "leave shared work alone\n").unwrap();

    let first = repos
        .create_worktree_for_task(&repo, "main", task)
        .await
        .unwrap();
    let second = repos
        .create_worktree_for_task(&repo, "main", task)
        .await
        .unwrap();
    assert_eq!(first.branch, "task/fix-login-redirect-after-sign-in-2");
    assert_eq!(second.branch, "task/fix-login-redirect-after-sign-in-3");
    assert_ne!(first.path, second.path);
    assert_eq!(git(&repo, &["branch", "--show-current"]), "main");
    assert_eq!(
        std::fs::read_to_string(repo.join("uncommitted.txt")).unwrap(),
        "leave shared work alone\n"
    );
    assert!(!Path::new(&first.path).join("uncommitted.txt").exists());

    // A user-chosen branch stays theirs, even in an application-created folder.
    let path = Path::new(&first.path);
    git(path, &["switch", user_branch]);
    assert_eq!(
        repos
            .rename_worktree_branch(path, user_branch, "Another task")
            .await
            .unwrap(),
        user_branch
    );
    repos.delete_worktree(&repo, path).await.unwrap();
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&user_branch.to_string())
    );

    // Ownership follows our title rename, so cleanup can still identify our
    // generated branch without treating every task/* branch as disposable.
    let renamed = repos
        .rename_worktree_branch(
            Path::new(&second.path),
            &second.branch,
            "Fix login callback",
        )
        .await
        .unwrap();
    assert_eq!(renamed, "task/fix-login-callback");
    repos
        .delete_worktree(&repo, Path::new(&second.path))
        .await
        .unwrap();
    let branches = repos.branches(&repo).await.unwrap();
    assert!(!branches.contains(&renamed));
    assert!(branches.contains(&user_branch.to_string()));
}

#[tokio::test]
async fn a_task_prefix_alone_does_not_authorize_renaming_or_deletion() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let path = tmp.path().join("fix-login");
    let branch = "task/fix-login";
    git(
        &repo,
        &[
            "worktree",
            "add",
            "-b",
            branch,
            path.to_str().unwrap(),
            "main",
        ],
    );
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    // Even the original-folder naming guard matches, but there is no ownership record.
    assert_eq!(
        repos
            .rename_worktree_branch(&path, branch, "Different task")
            .await
            .unwrap(),
        branch
    );
    repos.delete_worktree(&repo, &path).await.unwrap();
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&branch.to_string())
    );
}
