//! Task-derived names shared by host-created and agent-owned worktrees.
//! A worktree can be allocated before a chat title exists, so its first request
//! supplies the name. Only the first line is used; context appended below it is
//! not part of the task label.

pub fn task_slug(task: &str) -> String {
    let mut slug = String::new();
    let first_line = task
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("");
    for c in first_line.trim().chars() {
        if matches!(c, '\'' | '"' | '`') {
            continue;
        }
        if c.is_ascii_alphanumeric() {
            slug.push(c.to_ascii_lowercase());
        } else if !slug.is_empty() && !slug.ends_with('-') {
            slug.push('-');
        }
        if slug.len() >= 48 {
            break;
        }
    }
    let slug = slug.trim_end_matches('-');
    if slug.is_empty() {
        "changes".into()
    } else {
        slug.into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_names_are_descriptive_and_valid_ref_components() {
        assert_eq!(task_slug("  Fix `Login` Flow!  "), "fix-login-flow");
        assert_eq!(task_slug("Cafe's Dark Mode"), "cafes-dark-mode");
        assert_eq!(
            task_slug("\nFix redirect\nAdditional context"),
            "fix-redirect"
        );
        assert_eq!(task_slug("../../Fix: login @{flow}"), "fix-login-flow");
        assert_eq!(task_slug("***"), "changes");
        assert_eq!(task_slug(&"x".repeat(100)).len(), 48);
    }
}
