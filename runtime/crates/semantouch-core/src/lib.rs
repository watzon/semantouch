//! Shared Semantouch coordinator for Windows/Linux runtimes.
//!
//! Owns the public contract: sessions, revisions, stable element IDs, reconstructable
//! diffs, policy, bounded waits, and action evidence. Platform drivers only supply
//! native observation and delivery through `semantouch-adapter`.

mod cancellation;
mod coordinator;
mod diff;
mod fingerprint;
mod policy;
mod renderer;
mod session;
mod stable_ids;
mod tree;
mod wait;

pub use cancellation::*;
pub use coordinator::*;
pub use diff::*;
pub use fingerprint::*;
pub use policy::*;
pub use renderer::*;
pub use session::*;
pub use stable_ids::*;
pub use tree::*;
pub use wait::*;
