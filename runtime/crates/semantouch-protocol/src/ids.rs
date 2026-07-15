//! Session (`sN`) and element (`eN`) identifiers (§3).

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

/// Session id: `s` + positive decimal integer, never reused within a process.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SessionId(String);

impl SessionId {
    pub fn new(n: u64) -> Self {
        assert!(n >= 1, "session ids start at 1");
        Self(format!("s{n}"))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn parse_checked(raw: &str) -> Option<Self> {
        if !raw.starts_with('s') {
            return None;
        }
        let rest = &raw[1..];
        if rest.is_empty() || !rest.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        if rest.starts_with('0') && rest.len() > 1 {
            return None;
        }
        let n: u64 = rest.parse().ok()?;
        if n == 0 {
            return None;
        }
        Some(Self(raw.to_string()))
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl FromStr for SessionId {
    type Err = &'static str;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse_checked(s).ok_or("invalid session id")
    }
}

impl AsRef<str> for SessionId {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

/// Element id: `e` + positive decimal integer, never reused within a session.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ElementId(String);

impl ElementId {
    pub fn new(n: u64) -> Self {
        assert!(n >= 1, "element ids start at 1");
        Self(format!("e{n}"))
    }

    pub fn from_numeric(n: u64) -> Self {
        Self::new(n)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn numeric(&self) -> Option<u64> {
        self.0.strip_prefix('e')?.parse().ok()
    }

    pub fn parse_checked(raw: &str) -> Option<Self> {
        if !raw.starts_with('e') {
            return None;
        }
        let rest = &raw[1..];
        if rest.is_empty() || !rest.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        if rest.starts_with('0') && rest.len() > 1 {
            return None;
        }
        let n: u64 = rest.parse().ok()?;
        if n == 0 {
            return None;
        }
        Some(Self(raw.to_string()))
    }
}

impl fmt::Display for ElementId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl FromStr for ElementId {
    type Err = &'static str;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse_checked(s).ok_or("invalid element id")
    }
}

impl AsRef<str> for ElementId {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_ids_are_monotonic_shaped() {
        assert_eq!(SessionId::new(1).as_str(), "s1");
        assert_eq!(SessionId::new(42).as_str(), "s42");
        assert!(SessionId::parse_checked("s0").is_none());
        assert!(SessionId::parse_checked("s01").is_none());
        assert!(SessionId::parse_checked("session1").is_none());
        assert!(SessionId::parse_checked("s12").is_some());
    }

    #[test]
    fn element_ids_are_monotonic_shaped() {
        assert_eq!(ElementId::new(1).as_str(), "e1");
        assert_eq!(ElementId::from_numeric(9).numeric(), Some(9));
        assert!(ElementId::parse_checked("e0").is_none());
        assert!(ElementId::parse_checked("e").is_none());
        assert!(ElementId::parse_checked("e3").is_some());
    }
}
