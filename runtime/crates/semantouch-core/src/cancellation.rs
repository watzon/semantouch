//! Cooperative cancellation for in-flight requests (PROTOCOL §17).

use parking_lot::Mutex;
use semantouch_protocol::ToolError;
use std::sync::Arc;

/// One-way cancellation latch shared across threads.
#[derive(Clone, Default)]
pub struct CancellationToken {
    inner: Arc<Inner>,
}

#[derive(Default)]
struct Inner {
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    cancelled: bool,
    reason: Option<String>,
    handler: Option<Box<dyn FnOnce() + Send>>,
}

impl CancellationToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.state.lock().cancelled
    }

    pub fn reason(&self) -> Option<String> {
        self.inner.state.lock().reason.clone()
    }

    /// Latch cancelled and run any registered handler exactly once.
    pub fn cancel(&self, reason: Option<String>) {
        let handler = {
            let mut st = self.inner.state.lock();
            if st.cancelled {
                return;
            }
            st.cancelled = true;
            st.reason = reason;
            st.handler.take()
        };
        if let Some(h) = handler {
            h();
        }
    }

    /// Register a cancel handler; if already cancelled, run immediately.
    pub fn on_cancel<F>(&self, handler: F)
    where
        F: FnOnce() + Send + 'static,
    {
        let mut st = self.inner.state.lock();
        if st.cancelled {
            drop(st);
            handler();
            return;
        }
        st.handler = Some(Box::new(handler));
    }

    pub fn throw_if_cancelled(&self) -> Result<(), ToolError> {
        let st = self.inner.state.lock();
        if st.cancelled {
            Err(ToolError::Cancelled {
                reason: st.reason.clone(),
            })
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn cancel_is_latched_and_one_shot() {
        let token = CancellationToken::new();
        let fired = Arc::new(AtomicBool::new(false));
        let f = fired.clone();
        token.on_cancel(move || {
            f.store(true, Ordering::SeqCst);
        });
        token.cancel(Some("client".into()));
        assert!(token.is_cancelled());
        assert_eq!(token.reason().as_deref(), Some("client"));
        token.cancel(Some("second".into()));
        assert_eq!(token.reason().as_deref(), Some("client"));
        assert!(fired.load(Ordering::SeqCst));
        assert!(token.throw_if_cancelled().is_err());
    }
}
