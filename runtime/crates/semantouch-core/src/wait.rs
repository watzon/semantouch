//! Pure wait_for condition evaluation and bounded deadline loop helpers.

use crate::cancellation::CancellationToken;
use semantouch_adapter::WaitObservation;
use semantouch_protocol::{
    ToolError, WaitCondition, WaitConditionResult, WaitForResult, WaitMode, WaitObserved,
};
use std::time::{Duration, Instant};

/// Evaluate one condition against a cheap observation.
pub fn evaluate_condition(cond: &WaitCondition, obs: &WaitObservation) -> bool {
    match cond.kind.as_str() {
        "title_contains" => {
            let value = cond.value.as_deref().unwrap_or("");
            obs.window_title
                .as_deref()
                .map(|t| t.contains(value))
                .unwrap_or(false)
        }
        "title_changed" => {
            let from = cond.from.as_deref().unwrap_or("");
            obs.window_title
                .as_deref()
                .map(|t| t != from)
                .unwrap_or(false)
        }
        "url_contains" => {
            let value = cond.value.as_deref().unwrap_or("");
            obs.url.as_deref().map(|u| u.contains(value)).unwrap_or(false)
        }
        "url_changed" => {
            let from = cond.from.as_deref().unwrap_or("");
            obs.url.as_deref().map(|u| u != from).unwrap_or(false)
        }
        "element_exists" => obs.roles_titles_values.iter().any(|(role, title, value)| {
            role_matches(cond, role)
                && title_matches(cond, title.as_deref())
                && value_matches(cond, value.as_deref())
        }),
        "element_gone" => {
            !obs.roles_titles_values.iter().any(|(role, title, value)| {
                role_matches(cond, role)
                    && title_matches(cond, title.as_deref())
                    && value_matches(cond, value.as_deref())
            })
        }
        _ => false,
    }
}

fn role_matches(cond: &WaitCondition, role: &str) -> bool {
    match &cond.role {
        None => true,
        Some(r) => role == r || role.ends_with(r.as_str()),
    }
}

fn title_matches(cond: &WaitCondition, title: Option<&str>) -> bool {
    match &cond.title_contains {
        None => true,
        Some(sub) => title.map(|t| t.contains(sub)).unwrap_or(false),
    }
}

fn value_matches(cond: &WaitCondition, value: Option<&str>) -> bool {
    match &cond.value_contains {
        None => true,
        Some(sub) => value.map(|v| v.contains(sub)).unwrap_or(false),
    }
}

pub fn combine(mode: WaitMode, flags: &[bool]) -> bool {
    match mode {
        WaitMode::All => flags.iter().all(|b| *b),
        WaitMode::Any => flags.iter().any(|b| *b),
    }
}

/// Bounded wait loop. `poll` is called repeatedly until satisfied or deadline.
/// Cancellation yields `ToolError::Cancelled`. An expired deadline is a normal
/// `satisfied: false` result — never a `timeout` error.
pub fn run_wait_loop<F>(
    conditions: &[WaitCondition],
    mode: WaitMode,
    timeout: Duration,
    token: Option<&CancellationToken>,
    mut poll: F,
) -> Result<WaitForResult, ToolError>
where
    F: FnMut() -> Result<WaitObservation, ToolError>,
{
    let start = Instant::now();
    let deadline = start + timeout;
    let poll_every = Duration::from_millis(50);

    loop {
        if let Some(t) = token {
            t.throw_if_cancelled()?;
        }
        let obs = poll()?;
        let flags: Vec<bool> = conditions
            .iter()
            .map(|c| evaluate_condition(c, &obs))
            .collect();
        let satisfied = combine(mode, &flags);
        let elapsed = start.elapsed();
        if satisfied || Instant::now() >= deadline {
            let results = conditions
                .iter()
                .zip(flags.iter())
                .map(|(c, f)| WaitConditionResult {
                    kind: c.kind.clone(),
                    satisfied: *f,
                })
                .collect();
            return Ok(WaitForResult {
                satisfied,
                elapsed_ms: elapsed.as_millis() as i64,
                conditions: results,
                observed: WaitObserved {
                    window_title: obs.window_title,
                    url: obs.url,
                },
                refresh_recommended: true,
            });
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        std::thread::sleep(poll_every.min(remaining));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deadline_is_normal_unsatisfied_result() {
        let conditions = vec![WaitCondition {
            kind: "title_contains".into(),
            from: None,
            value: Some("never".into()),
            role: None,
            title_contains: None,
            value_contains: None,
        }];
        let result = run_wait_loop(
            &conditions,
            WaitMode::All,
            Duration::from_millis(120),
            None,
            || {
                Ok(WaitObservation {
                    window_title: Some("other".into()),
                    url: None,
                    roles_titles_values: vec![],
                })
            },
        )
        .unwrap();
        assert!(!result.satisfied);
        assert!(result.elapsed_ms >= 100);
        assert!(result.refresh_recommended);
    }

    #[test]
    fn cancellation_aborts_wait() {
        let token = CancellationToken::new();
        token.cancel(Some("bye".into()));
        let conditions = vec![WaitCondition {
            kind: "title_contains".into(),
            from: None,
            value: Some("x".into()),
            role: None,
            title_contains: None,
            value_contains: None,
        }];
        let err = run_wait_loop(
            &conditions,
            WaitMode::All,
            Duration::from_secs(5),
            Some(&token),
            || Ok(WaitObservation::default()),
        )
        .unwrap_err();
        match err {
            ToolError::Cancelled { .. } => {}
            other => panic!("expected cancelled, got {other:?}"),
        }
    }

    #[test]
    fn element_exists_and_mode_any() {
        let obs = WaitObservation {
            window_title: Some("t".into()),
            url: None,
            roles_titles_values: vec![("AXButton".into(), Some("Save".into()), None)],
        };
        let c = WaitCondition {
            kind: "element_exists".into(),
            from: None,
            value: None,
            role: Some("AXButton".into()),
            title_contains: Some("Save".into()),
            value_contains: None,
        };
        assert!(evaluate_condition(&c, &obs));
        assert!(combine(WaitMode::Any, &[false, true]));
        assert!(!combine(WaitMode::All, &[false, true]));
    }
}
