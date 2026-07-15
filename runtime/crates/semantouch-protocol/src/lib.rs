//! Semantouch wire contract shared by every platform runtime.
//!
//! Mirrors the frozen macOS Swift surface (`docs/PROTOCOL.md`, ComputerUseCore DTOs,
//! ToolCatalog) without depending on Apple frameworks. The 16-tool catalog, error codes,
//! session/revision/element-id shapes, and capability vocabulary live here so Windows and
//! Linux adapters cannot diverge into a second public tool API.

mod catalog;
mod dto;
mod error;
mod ids;
mod geometry;
mod capability;

pub use catalog::*;
pub use dto::*;
pub use error::*;
pub use ids::*;
pub use geometry::*;
pub use capability::*;

/// Protocol version identifier reported on the wire.
pub const PROTOCOL_VERSION: &str = "semantouch/1";

/// MCP protocol version the server reports on `initialize`.
pub const MCP_PROTOCOL_VERSION: &str = "2025-06-18";

/// Package / product version for this runtime workspace.
pub const PACKAGE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Tree text format token.
pub const TREE_FORMAT: &str = "semantouch-ax-tree-v1";

/// Default emitted-node budget for a snapshot.
pub const DEFAULT_MAX_NODES: usize = 600;

/// Hard upper bound for `maxNodes`.
pub const HARD_MAX_NODES: usize = 2000;

/// Per-field escaped UTF-8 byte cap in tree text.
pub const MAX_FIELD_BYTES: usize = 256;

/// Max tree text size in UTF-8 bytes.
pub const MAX_TREE_BYTES: usize = 120 * 1024;

/// Default `read_text` UTF-8 byte limit when omitted.
pub const DEFAULT_READ_TEXT_LIMIT: usize = 4096;
