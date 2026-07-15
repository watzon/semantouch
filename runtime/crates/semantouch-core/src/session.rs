//! App sessions, process-scoped session ids, per-session revisions (§3).

use crate::stable_ids::StableElementTable;
use parking_lot::Mutex;
use semantouch_protocol::{ElementId, SessionId, UiNode};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

pub struct AppSession {
    pub session_id: SessionId,
    pub app_id: String,
    pub pid: Option<i32>,
    pub created_at: Instant,
    pub revision: i64,
    pub element_table: StableElementTable,
    pub last_tree: Option<UiNode>,
    pub last_window_id: Option<i64>,
    pub dirty: bool,
    /// The previous delivered snapshot cannot be used as a diff base.
    pub lineage_broken: bool,
}

impl AppSession {
    fn new(session_id: SessionId, app_id: String, pid: Option<i32>) -> Self {
        Self {
            session_id,
            app_id,
            pid,
            created_at: Instant::now(),
            revision: 0, // bumped on first committed snapshot to 1
            element_table: StableElementTable::new(true),
            last_tree: None,
            last_window_id: None,
            dirty: false,
            lineage_broken: false,
        }
    }
}

/// Thread-safe registry of app sessions.
pub struct SessionManager {
    inner: Mutex<Inner>,
}

struct Inner {
    sessions: HashMap<String, Arc<Mutex<AppSession>>>,
    session_by_app: HashMap<String, String>,
    next_session: u64,
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionManager {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner {
                sessions: HashMap::new(),
                session_by_app: HashMap::new(),
                next_session: 1,
            }),
        }
    }

    pub fn ensure_session(&self, app_id: &str, pid: Option<i32>) -> Arc<Mutex<AppSession>> {
        let mut g = self.inner.lock();
        if let Some(sid) = g.session_by_app.get(app_id) {
            if let Some(s) = g.sessions.get(sid) {
                return Arc::clone(s);
            }
        }
        let n = g.next_session;
        g.next_session += 1;
        let sid = SessionId::new(n);
        let key = sid.as_str().to_string();
        let session = Arc::new(Mutex::new(AppSession::new(sid, app_id.to_string(), pid)));
        g.session_by_app.insert(app_id.to_string(), key.clone());
        g.sessions.insert(key, Arc::clone(&session));
        session
    }

    pub fn session(&self, id: &str) -> Option<Arc<Mutex<AppSession>>> {
        self.inner.lock().sessions.get(id).cloned()
    }

    pub fn session_for_app(&self, app_id: &str) -> Option<Arc<Mutex<AppSession>>> {
        let g = self.inner.lock();
        let sid = g.session_by_app.get(app_id)?;
        g.sessions.get(sid).cloned()
    }

    pub fn current_revision(&self, session_id: &str) -> Option<i64> {
        let s = self.session(session_id)?;
        let rev = s.lock().revision;
        Some(rev)
    }

    pub fn bump_revision(&self, session_id: &str) -> Option<i64> {
        let s = self.session(session_id)?;
        let mut g = s.lock();
        g.revision += 1;
        Some(g.revision)
    }

    pub fn end_session(&self, session_id: &str) -> bool {
        let mut g = self.inner.lock();
        if let Some(sess) = g.sessions.remove(session_id) {
            let app_id = sess.lock().app_id.clone();
            g.session_by_app.remove(&app_id);
            true
        } else {
            false
        }
    }

    pub fn active_session_ids(&self) -> Vec<String> {
        self.inner.lock().sessions.keys().cloned().collect()
    }

    pub fn mint_element_id_string(n: u64) -> ElementId {
        ElementId::new(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_ids_monotonic_and_not_reused() {
        let m = SessionManager::new();
        let s1 = m.ensure_session("app.a", Some(1));
        let s2 = m.ensure_session("app.b", Some(2));
        assert_eq!(s1.lock().session_id.as_str(), "s1");
        assert_eq!(s2.lock().session_id.as_str(), "s2");
        // same app returns same session
        let s1b = m.ensure_session("app.a", Some(1));
        assert_eq!(s1b.lock().session_id.as_str(), "s1");
        assert!(m.end_session("s1"));
        assert!(!m.end_session("s1"));
        let s3 = m.ensure_session("app.a", Some(1));
        assert_eq!(s3.lock().session_id.as_str(), "s3");
    }

    #[test]
    fn revision_only_advances_via_bump() {
        let m = SessionManager::new();
        let s = m.ensure_session("app", None);
        assert_eq!(s.lock().revision, 0);
        assert_eq!(m.bump_revision("s1"), Some(1));
        assert_eq!(m.current_revision("s1"), Some(1));
        assert_eq!(m.current_revision("s9"), None);
    }
}
