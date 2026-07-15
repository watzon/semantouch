//! Per-application policy gate (default password-manager denylist).

use semantouch_protocol::{PolicyDenyReason, ToolError};
use std::collections::HashSet;

/// How aggressively fallback input may disturb the foreground.
pub use semantouch_protocol::InterferencePolicy;

/// Policy engine shared by all platforms.
#[derive(Clone, Debug)]
pub struct PolicyEngine {
    pub default_interference: InterferencePolicy,
    app_denylist: HashSet<String>,
}

impl Default for PolicyEngine {
    fn default() -> Self {
        Self::with_default_sensitive_denylist()
    }
}

impl PolicyEngine {
    pub fn with_denylist(denylist: impl IntoIterator<Item = String>) -> Self {
        Self {
            default_interference: InterferencePolicy::BackgroundOnly,
            app_denylist: denylist.into_iter().map(|s| s.to_lowercase()).collect(),
        }
    }

    pub fn with_default_sensitive_denylist() -> Self {
        Self::with_denylist(default_sensitive_app_denylist())
    }

    /// Build from process environment.
    ///
    /// `SEMANTOUCH_DENIED_APPS` always augments. Built-in sensitive protection is
    /// included unless `SEMANTOUCH_ALLOW_SENSITIVE_APPS=1`.
    pub fn from_env() -> Self {
        let env: Vec<(String, String)> = std::env::vars().collect();
        Self::from_env_map(&env.into_iter().collect())
    }

    pub fn from_env_map(env: &std::collections::HashMap<String, String>) -> Self {
        let allow_sensitive = env.get("SEMANTOUCH_ALLOW_SENSITIVE_APPS").map(|s| s.as_str()) == Some("1");
        let mut set = if allow_sensitive {
            HashSet::new()
        } else {
            default_sensitive_app_denylist()
                .into_iter()
                .map(|s| s.to_lowercase())
                .collect()
        };
        if let Some(extra) = env.get("SEMANTOUCH_DENIED_APPS") {
            for part in extra.split(',') {
                let t = part.trim();
                if !t.is_empty() {
                    set.insert(t.to_lowercase());
                }
            }
        }
        Self {
            default_interference: InterferencePolicy::BackgroundOnly,
            app_denylist: set,
        }
    }

    pub fn is_app_denied(
        &self,
        bundle_id: Option<&str>,
        display_name: Option<&str>,
        path: Option<&str>,
    ) -> bool {
        for token in identity_tokens(bundle_id, display_name, path) {
            if self.app_denylist.contains(&token) {
                return true;
            }
        }
        false
    }

    pub fn deny_if_blocked(
        &self,
        bundle_id: Option<&str>,
        display_name: Option<&str>,
        path: Option<&str>,
        tool: Option<&str>,
    ) -> Result<(), ToolError> {
        if self.is_app_denied(bundle_id, display_name, path) {
            Err(ToolError::PolicyDenied {
                reason: PolicyDenyReason::AppDenied,
                app: display_name
                    .or(bundle_id)
                    .or(path)
                    .map(|s| s.to_string()),
                tool: tool.map(|s| s.to_string()),
            })
        } else {
            Ok(())
        }
    }

    pub fn deny_tool_disabled(tool: &str) -> ToolError {
        ToolError::PolicyDenied {
            reason: PolicyDenyReason::ToolDisabled,
            app: None,
            tool: Some(tool.into()),
        }
    }
}

fn identity_tokens(
    bundle_id: Option<&str>,
    display_name: Option<&str>,
    path: Option<&str>,
) -> HashSet<String> {
    let mut out = HashSet::new();
    if let Some(b) = bundle_id {
        out.insert(b.to_lowercase());
    }
    if let Some(d) = display_name {
        out.insert(d.to_lowercase());
    }
    if let Some(p) = path {
        out.insert(p.to_lowercase());
        if let Some(base) = p.rsplit(['/', '\\']).next() {
            out.insert(base.to_lowercase());
        }
    }
    out
}

pub fn default_sensitive_app_denylist() -> Vec<String> {
    [
        // 1Password
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "1Password",
        "1Password 7",
        "1Password.app",
        "1Password 7.app",
        // Bitwarden
        "com.bitwarden.desktop",
        "Bitwarden",
        "Bitwarden.app",
        // Dashlane
        "com.dashlane.dashlanephonefinal",
        "com.dashlane.Dashlane",
        "Dashlane",
        "Dashlane.app",
        // LastPass
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        "LastPass",
        "LastPass.app",
        // NordPass
        "com.nordsec.nordpass",
        "NordPass",
        "NordPass.app",
        // Proton Pass
        "me.proton.pass.electron",
        "me.proton.pass.catalyst",
        "Proton Pass",
        "Proton Pass.app",
        // Windows / Linux common package names
        "1password.exe",
        "bitwarden.exe",
        "keepassxc",
        "org.keepassxc.KeePassXC",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

/// Pure interference decision table (§16).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InterferencePlan {
    DeliverInBackground,
    FocusRequired,
    DeliverTargeted,
    BriefFocus,
    Takeover,
}

impl InterferencePlan {
    pub fn decide(
        mode: InterferencePolicy,
        target_is_frontmost: bool,
        action_supports_targeted: bool,
        synthesizer_supports_targeted: bool,
    ) -> Self {
        if target_is_frontmost {
            return Self::DeliverInBackground;
        }
        match mode {
            InterferencePolicy::BackgroundOnly => {
                if action_supports_targeted && synthesizer_supports_targeted {
                    Self::DeliverTargeted
                } else {
                    Self::FocusRequired
                }
            }
            InterferencePolicy::AllowBriefFocus => Self::BriefFocus,
            InterferencePolicy::ForegroundTakeover => Self::Takeover,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_denylist_blocks_password_managers() {
        let p = PolicyEngine::with_default_sensitive_denylist();
        assert!(p.is_app_denied(Some("com.1password.1password"), None, None));
        assert!(p.is_app_denied(None, Some("Bitwarden"), None));
        assert!(p.is_app_denied(None, None, Some("/usr/bin/keepassxc")));
        assert!(!p.is_app_denied(Some("com.apple.TextEdit"), Some("TextEdit"), None));
    }

    #[test]
    fn env_allow_sensitive_clears_builtin_but_keeps_operator_deny() {
        let mut env = std::collections::HashMap::new();
        env.insert("SEMANTOUCH_ALLOW_SENSITIVE_APPS".into(), "1".into());
        env.insert("SEMANTOUCH_DENIED_APPS".into(), "SecretApp, other".into());
        let p = PolicyEngine::from_env_map(&env);
        assert!(!p.is_app_denied(Some("com.1password.1password"), None, None));
        assert!(p.is_app_denied(None, Some("SecretApp"), None));
    }

    #[test]
    fn interference_table_never_silently_escalates() {
        assert_eq!(
            InterferencePlan::decide(InterferencePolicy::BackgroundOnly, false, false, false),
            InterferencePlan::FocusRequired
        );
        assert_eq!(
            InterferencePlan::decide(InterferencePolicy::BackgroundOnly, false, true, true),
            InterferencePlan::DeliverTargeted
        );
        assert_eq!(
            InterferencePlan::decide(InterferencePolicy::AllowBriefFocus, false, false, false),
            InterferencePlan::BriefFocus
        );
        assert_eq!(
            InterferencePlan::decide(InterferencePolicy::BackgroundOnly, true, false, false),
            InterferencePlan::DeliverInBackground
        );
    }
}
