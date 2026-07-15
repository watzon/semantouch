//! Session-scoped stable element id table (§3, §11).

use crate::fingerprint::ElementFingerprint;
use parking_lot::Mutex;
use semantouch_adapter::NativeHandle;
use semantouch_protocol::{ElementId, ToolError};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

struct Entry {
    handle: Arc<dyn NativeHandle>,
    fingerprint: ElementFingerprint,
}

/// Assigns opaque `eN` ids; reuses only when fingerprint matches AND handle is live.
pub struct StableElementTable {
    inner: Mutex<Inner>,
}

struct Inner {
    reuse_across_passes: bool,
    next_counter: u64,
    entries_by_id: HashMap<u64, Entry>,
    id_by_fingerprint: HashMap<ElementFingerprint, u64>,
    seen_this_pass: HashSet<u64>,
    assigned_this_pass: HashSet<u64>,
    pass_in_progress: bool,
}

impl StableElementTable {
    pub fn new(reuse_across_passes: bool) -> Self {
        Self {
            inner: Mutex::new(Inner {
                reuse_across_passes,
                next_counter: 1,
                entries_by_id: HashMap::new(),
                id_by_fingerprint: HashMap::new(),
                seen_this_pass: HashSet::new(),
                assigned_this_pass: HashSet::new(),
                pass_in_progress: false,
            }),
        }
    }

    pub fn begin_pass(&self) {
        let mut g = self.inner.lock();
        g.seen_this_pass.clear();
        g.assigned_this_pass.clear();
        g.pass_in_progress = true;
    }

    /// Assign (reusing when possible) the numeric id for one element.
    pub fn assign(&self, handle: Arc<dyn NativeHandle>, fingerprint: ElementFingerprint) -> u64 {
        let mut g = self.inner.lock();
        if g.reuse_across_passes {
            if let Some(&candidate) = g.id_by_fingerprint.get(&fingerprint) {
                if let Some(prior) = g.entries_by_id.get(&candidate) {
                    if prior.handle.is_live() && !g.assigned_this_pass.contains(&candidate) {
                        let id = candidate;
                        g.entries_by_id.insert(
                            id,
                            Entry {
                                handle,
                                fingerprint: fingerprint.clone(),
                            },
                        );
                        g.assigned_this_pass.insert(id);
                        g.seen_this_pass.insert(id);
                        return id;
                    }
                }
            }
        }

        let new_id = g.next_counter;
        g.next_counter += 1;
        g.entries_by_id.insert(
            new_id,
            Entry {
                handle,
                fingerprint: fingerprint.clone(),
            },
        );
        g.id_by_fingerprint.insert(fingerprint, new_id);
        g.assigned_this_pass.insert(new_id);
        g.seen_this_pass.insert(new_id);
        new_id
    }

    /// Retire all ids (forceFullTree rebuild-ids) without rewinding the counter.
    pub fn reset(&self) {
        let mut g = self.inner.lock();
        g.entries_by_id.clear();
        g.id_by_fingerprint.clear();
        g.seen_this_pass.clear();
        g.assigned_this_pass.clear();
        g.pass_in_progress = false;
    }

    pub fn end_pass(&self) {
        let mut g = self.inner.lock();
        let dead: Vec<u64> = g
            .entries_by_id
            .keys()
            .copied()
            .filter(|id| !g.seen_this_pass.contains(id))
            .collect();
        for id in dead {
            if let Some(entry) = g.entries_by_id.remove(&id) {
                if g.id_by_fingerprint.get(&entry.fingerprint) == Some(&id) {
                    g.id_by_fingerprint.remove(&entry.fingerprint);
                }
            }
        }
        g.pass_in_progress = false;
    }

    pub fn resolve(
        &self,
        element_id: &ElementId,
        session_id: &str,
        revision: i64,
    ) -> Result<Arc<dyn NativeHandle>, ToolError> {
        let n = element_id
            .numeric()
            .ok_or_else(|| ToolError::StaleElement {
                session_id: session_id.into(),
                element_id: element_id.as_str().into(),
                revision,
            })?;
        let g = self.inner.lock();
        match g.entries_by_id.get(&n) {
            Some(entry) if entry.handle.is_live() => Ok(Arc::clone(&entry.handle)),
            _ => Err(ToolError::StaleElement {
                session_id: session_id.into(),
                element_id: element_id.as_str().into(),
                revision,
            }),
        }
    }

    pub fn next_counter(&self) -> u64 {
        self.inner.lock().next_counter
    }

    pub fn live_ids(&self) -> Vec<u64> {
        let g = self.inner.lock();
        let mut ids: Vec<u64> = g.entries_by_id.keys().copied().collect();
        ids.sort_unstable();
        ids
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use semantouch_adapter::FakeHandle;

    fn fp(role: &str, ordinal: u32, title: &str) -> ElementFingerprint {
        ElementFingerprint::new(role, None, None, 0, ordinal, Some(title))
    }

    #[test]
    fn reuse_requires_fingerprint_and_live_handle() {
        let table = StableElementTable::new(true);
        let h1 = FakeHandle::new(1);
        table.begin_pass();
        let id1 = table.assign(h1.clone() as Arc<dyn NativeHandle>, fp("button", 0, "OK"));
        table.end_pass();
        assert_eq!(id1, 1);

        table.begin_pass();
        let h2 = FakeHandle::new(2);
        let id2 = table.assign(h2 as Arc<dyn NativeHandle>, fp("button", 0, "OK"));
        // h1 still live → reuse
        assert_eq!(id2, 1);
        table.end_pass();

        // Kill prior handle; same fingerprint must mint a fresh id (never recycle retired).
        h1.kill();
        table.begin_pass();
        let h3 = FakeHandle::new(3);
        // After end_pass the entry still held h2 (live). Kill path:
        // Replace: begin with dead prior by resetting handle liveness on stored entry.
        // Stored handle is h2 from last assign (refreshed). Kill h2:
        // We need the stored handle dead. Resolve and kill via FakeHandle.
        // Simpler: reset and mint, or kill through stored Arc — h2 is the live one.
        let _ = h3;
        table.end_pass();

        // Direct: store a handle, kill it, rebuild.
        let table2 = StableElementTable::new(true);
        let live = FakeHandle::new(10);
        table2.begin_pass();
        let a = table2.assign(live.clone() as Arc<dyn NativeHandle>, fp("btn", 0, "x"));
        table2.end_pass();
        live.kill();
        table2.begin_pass();
        let b = table2.assign(
            FakeHandle::new(11) as Arc<dyn NativeHandle>,
            fp("btn", 0, "x"),
        );
        table2.end_pass();
        assert_eq!(a, 1);
        assert_eq!(b, 2, "dead handle must not reuse id");
    }

    #[test]
    fn reset_retires_ids_without_rewinding_counter() {
        let table = StableElementTable::new(true);
        table.begin_pass();
        table.assign(FakeHandle::new(1) as Arc<dyn NativeHandle>, fp("a", 0, "t"));
        table.assign(FakeHandle::new(2) as Arc<dyn NativeHandle>, fp("b", 0, "t"));
        table.end_pass();
        assert_eq!(table.next_counter(), 3);
        table.reset();
        table.begin_pass();
        let id = table.assign(FakeHandle::new(3) as Arc<dyn NativeHandle>, fp("a", 0, "t"));
        table.end_pass();
        assert_eq!(id, 3);
        assert!(table.resolve(&ElementId::new(1), "s1", 1).is_err());
    }

    #[test]
    fn without_reuse_every_pass_mints_fresh_ids() {
        let table = StableElementTable::new(false);
        let h = FakeHandle::new(1);
        table.begin_pass();
        let a = table.assign(h.clone() as Arc<dyn NativeHandle>, fp("x", 0, "t"));
        table.end_pass();
        table.begin_pass();
        let b = table.assign(h as Arc<dyn NativeHandle>, fp("x", 0, "t"));
        table.end_pass();
        assert_eq!(a, 1);
        assert_eq!(b, 2);
    }
}
