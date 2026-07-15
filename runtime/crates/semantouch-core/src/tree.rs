//! Assign public element ids to a raw observation tree.

use crate::fingerprint::ElementFingerprint;
use crate::stable_ids::StableElementTable;
use semantouch_adapter::RawNode;
use semantouch_protocol::UiNode;
use std::collections::HashMap;
use std::sync::Arc;

/// Build a `UiNode` tree from a raw adapter tree, assigning stable ids.
pub fn assign_tree(table: &StableElementTable, raw: &RawNode) -> UiNode {
    table.begin_pass();
    let root = assign_node(table, raw, ElementFingerprint::ROOT_PARENT_HASH);
    table.end_pass();
    root
}

fn assign_node(
    table: &StableElementTable,
    raw: &RawNode,
    parent_hash: u64,
) -> UiNode {
    // sibling ordinals among like-role children are computed by the parent.
    // For the root, ordinal is 0.
    assign_node_with_ordinal(table, raw, parent_hash, 0)
}

fn assign_node_with_ordinal(
    table: &StableElementTable,
    raw: &RawNode,
    parent_hash: u64,
    sibling_ordinal: u32,
) -> UiNode {
    let fp = ElementFingerprint::new(
        raw.role.clone(),
        raw.subrole.clone(),
        raw.identifier.clone(),
        parent_hash,
        sibling_ordinal,
        raw.title.as_deref(),
    );
    let id = table.assign(Arc::clone(&raw.handle), fp.clone());
    let self_hash = fp.stable_hash();

    // Group children by role for sibling ordinals.
    let mut role_counts: HashMap<String, u32> = HashMap::new();
    let mut children = Vec::with_capacity(raw.children.len());
    for child in &raw.children {
        let ord = {
            let c = role_counts.entry(child.role.clone()).or_insert(0);
            let o = *c;
            *c += 1;
            o
        };
        children.push(assign_node_with_ordinal(table, child, self_hash, ord));
    }

    UiNode {
        id,
        role: raw.role.clone(),
        subrole: raw.subrole.clone(),
        title: raw.title.clone(),
        value: raw.value.clone(),
        description: raw.description.clone(),
        placeholder: raw.placeholder.clone(),
        ax_identifier: raw.identifier.clone(),
        enabled: raw.enabled,
        focused: raw.focused,
        selected: raw.selected,
        frame: raw.frame,
        actions: raw.actions.clone(),
        settable_attributes: raw.settable_attributes.clone(),
        children,
    }
}

/// Find focused element id in a tree.
pub fn find_focused_id(node: &UiNode) -> Option<u64> {
    if node.focused {
        return Some(node.id);
    }
    for child in &node.children {
        if let Some(id) = find_focused_id(child) {
            return Some(id);
        }
    }
    None
}
