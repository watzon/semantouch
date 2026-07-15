//! Structural fingerprints for stable element-id reuse (§11).

use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

/// Structural fingerprint used to decide id reuse across rebuilds.
///
/// Excludes native pointers and frames. `parent_hash` chains ancestry;
/// `sibling_ordinal` disambiguates like-role siblings.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ElementFingerprint {
    pub role: String,
    pub subrole: Option<String>,
    pub identifier: Option<String>,
    pub parent_hash: u64,
    pub sibling_ordinal: u32,
    pub normalized_title: String,
}

impl ElementFingerprint {
    pub const ROOT_PARENT_HASH: u64 = 0;

    pub fn new(
        role: impl Into<String>,
        subrole: Option<String>,
        identifier: Option<String>,
        parent_hash: u64,
        sibling_ordinal: u32,
        title: Option<&str>,
    ) -> Self {
        Self {
            role: role.into(),
            subrole,
            identifier,
            parent_hash,
            sibling_ordinal,
            normalized_title: normalize_title(title),
        }
    }

    pub fn stable_hash(&self) -> u64 {
        let mut h = DefaultHasher::new();
        self.hash(&mut h);
        h.finish()
    }
}

/// Normalize a title for fingerprinting: trim, collapse whitespace, lowercase.
pub fn normalize_title(title: Option<&str>) -> String {
    match title {
        None => String::new(),
        Some(t) => t
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_normalization_collapses_whitespace_and_case() {
        assert_eq!(normalize_title(Some("  Hello   World ")), "hello world");
        assert_eq!(normalize_title(None), "");
        assert_eq!(normalize_title(Some("\t")), "");
    }

    #[test]
    fn sibling_ordinal_changes_hash() {
        let a = ElementFingerprint::new("button", None, None, 0, 0, Some("OK"));
        let b = ElementFingerprint::new("button", None, None, 0, 1, Some("OK"));
        assert_ne!(a.stable_hash(), b.stable_hash());
    }
}
