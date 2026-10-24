//! Bounded inline native visual data. Scripts are inert until a UI renders them.

pub const VISUAL_TITLE_MAX_CHARS: usize = 200;
pub const VISUAL_SCRIPT_MAX_BYTES: usize = 64 * 1024;

/// Shared ingress/storage bounds; byte length deliberately measures UTF-8.
pub fn validate_visual(title: &str, script: &str) -> Result<(), &'static str> {
    if title.trim().is_empty() || title.chars().count() > VISUAL_TITLE_MAX_CHARS {
        return Err("visual title must be nonblank and at most 200 characters");
    }
    if script.trim().is_empty() || script.len() > VISUAL_SCRIPT_MAX_BYTES {
        return Err("visual script must be nonblank and at most 64 KiB of UTF-8");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn visual_limits_measure_title_characters_and_script_utf8_bytes() {
        assert!(validate_visual(&"界".repeat(200), &"é".repeat(32768)).is_ok());
        assert!(validate_visual(&"界".repeat(201), "x").is_err());
        assert!(validate_visual("title", &"é".repeat(32769)).is_err());
        for (title, script) in [(" \n", "x"), ("title", " \n\t")] {
            assert!(validate_visual(title, script).is_err());
        }
    }
}
