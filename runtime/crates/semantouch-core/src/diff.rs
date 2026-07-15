//! Pure incremental diffing over two `UiNode` snapshots (§15).
//!
//! Correctness contract: `apply(compute(previous, current), previous) == current`.

use crate::renderer::{
    attribute_segment, identity_segment, render_field, render_frame, render_line, sanitize_token,
    strip_ax_prefix, RenderOptions,
};
use semantouch_protocol::UiNode;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
pub struct Added {
    pub node: UiNode,
    pub parent_id: Option<u64>,
    pub index: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Changed {
    pub id: u64,
    pub before: UiNode,
    pub after: UiNode,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Diff {
    pub base_revision: i64,
    pub revision: i64,
    pub added: Vec<Added>,
    pub changed: Vec<Changed>,
    pub removed: Vec<u64>,
    pub reused_id_conflict: bool,
}

impl Diff {
    pub fn is_empty(&self) -> bool {
        self.added.is_empty() && self.changed.is_empty() && self.removed.is_empty()
    }
}

struct Located {
    node: UiNode,
    parent_id: Option<u64>,
    index: usize,
}

fn shell(node: &UiNode) -> UiNode {
    node.shell()
}

fn index_tree(node: &UiNode, parent_id: Option<u64>, child_index: usize, map: &mut HashMap<u64, Located>) {
    map.insert(
        node.id,
        Located {
            node: shell(node),
            parent_id,
            index: child_index,
        },
    );
    for (i, child) in node.children.iter().enumerate() {
        index_tree(child, Some(node.id), i, map);
    }
}

/// Compute the diff transforming `previous` into `current`.
pub fn compute(
    previous: &UiNode,
    current: &UiNode,
    base_revision: i64,
    revision: i64,
    options: RenderOptions,
) -> Diff {
    let mut prev_index = HashMap::new();
    let mut cur_index = HashMap::new();
    index_tree(previous, None, 0, &mut prev_index);
    index_tree(current, None, 0, &mut cur_index);

    let mut removed = Vec::new();
    let mut added = Vec::new();
    let mut changed = Vec::new();
    let mut reused_id_conflict = false;

    for id in prev_index.keys() {
        if !cur_index.contains_key(id) {
            removed.push(*id);
        }
    }

    for (id, cur) in &cur_index {
        match prev_index.get(id) {
            None => {
                added.push(Added {
                    node: cur.node.clone(),
                    parent_id: cur.parent_id,
                    index: cur.index,
                });
            }
            Some(prev) => {
                let placement_changed =
                    prev.parent_id != cur.parent_id || prev.index != cur.index;
                let identity_changed = identity_segment(&prev.node, &options)
                    != identity_segment(&cur.node, &options);
                if placement_changed || identity_changed {
                    reused_id_conflict = true;
                    removed.push(*id);
                    added.push(Added {
                        node: cur.node.clone(),
                        parent_id: cur.parent_id,
                        index: cur.index,
                    });
                } else if attribute_segment(&prev.node, &options)
                    != attribute_segment(&cur.node, &options)
                {
                    changed.push(Changed {
                        id: *id,
                        before: prev.node.clone(),
                        after: cur.node.clone(),
                    });
                }
            }
        }
    }

    added.sort_by_key(|a| a.node.id);
    changed.sort_by_key(|c| c.id);
    removed.sort_unstable();
    Diff {
        base_revision,
        revision,
        added,
        changed,
        removed,
        reused_id_conflict,
    }
}

/// Reconstruct current by applying `diff` to `previous`.
pub fn apply(diff: &Diff, previous: &UiNode) -> UiNode {
    let mut located = HashMap::new();
    index_tree(previous, None, 0, &mut located);

    for id in &diff.removed {
        located.remove(id);
    }
    for change in &diff.changed {
        if let Some(existing) = located.get(&change.id) {
            let parent_id = existing.parent_id;
            let index = existing.index;
            located.insert(
                change.id,
                Located {
                    node: shell(&change.after),
                    parent_id,
                    index,
                },
            );
        }
    }
    for add in &diff.added {
        located.insert(
            add.node.id,
            Located {
                node: shell(&add.node),
                parent_id: add.parent_id,
                index: add.index,
            },
        );
    }

    let mut children_by_parent: HashMap<u64, Vec<(usize, u64)>> = HashMap::new();
    let mut root_id = None;
    for (id, entry) in &located {
        match entry.parent_id {
            Some(parent) => children_by_parent
                .entry(parent)
                .or_default()
                .push((entry.index, *id)),
            None => root_id = Some(*id),
        }
    }

    let root = match root_id {
        Some(r) => r,
        None => return previous.clone(),
    };

    fn build(
        id: u64,
        located: &HashMap<u64, Located>,
        children_by_parent: &HashMap<u64, Vec<(usize, u64)>>,
    ) -> UiNode {
        let mut node = located
            .get(&id)
            .map(|l| l.node.clone())
            .unwrap_or(UiNode {
                id,
                role: "AXUnknown".into(),
                subrole: None,
                title: None,
                value: None,
                description: None,
                placeholder: None,
                ax_identifier: None,
                enabled: true,
                focused: false,
                selected: false,
                frame: None,
                actions: vec![],
                settable_attributes: vec![],
                children: vec![],
            });
        let mut kids = children_by_parent.get(&id).cloned().unwrap_or_default();
        kids.sort_by_key(|(idx, _)| *idx);
        node.children = kids
            .into_iter()
            .map(|(_, cid)| build(cid, located, children_by_parent))
            .collect();
        node
    }

    build(root, &located, &children_by_parent)
}

const ATTRIBUTE_KEY_ORDER: &[&str] = &[
    "value",
    "placeholder",
    "desc",
    "enabled",
    "focused",
    "selected",
    "frame",
    "actions",
];

/// Render diff to the frozen wire grammar (§15).
pub fn render_diff(diff: &Diff, options: RenderOptions) -> String {
    let mut lines = vec![format!(
        "UI revision {}, based on {}",
        diff.revision, diff.base_revision
    )];
    for change in &diff.changed {
        lines.push(render_changed(change, &options));
    }
    for add in &diff.added {
        let body = render_line(0, &add.node, &options);
        let parent_ref = add
            .parent_id
            .map(|p| format!("e{p}"))
            .unwrap_or_else(|| "root".into());
        lines.push(format!("+ {body} @{parent_ref}:{}", add.index));
    }
    if !diff.removed.is_empty() {
        lines.push(format!("- [{}]", collapse_removed(&diff.removed)));
    }
    lines.join("\n")
}

fn render_changed(change: &Changed, options: &RenderOptions) -> String {
    let mut olds = Vec::new();
    let mut news = Vec::new();
    for key in ATTRIBUTE_KEY_ORDER {
        let old_token = full_attribute_token(key, &change.before, options);
        let new_token = full_attribute_token(key, &change.after, options);
        if old_token != new_token {
            if let Some(t) = old_token {
                olds.push(t);
            }
            if let Some(t) = new_token {
                news.push(t);
            }
        }
    }
    let identity = identity_segment(&change.after, options);
    let old_part = if olds.is_empty() {
        String::new()
    } else {
        format!(" {}", olds.join(" "))
    };
    let new_part = if news.is_empty() {
        String::new()
    } else {
        format!(" {}", news.join(" "))
    };
    format!("~ {identity}{old_part} →{new_part}")
}

fn full_attribute_token(key: &str, node: &UiNode, options: &RenderOptions) -> Option<String> {
    match key {
        "value" => node.value.as_ref().filter(|v| !v.is_empty()).map(|v| {
            format!("value=\"{}\"", render_field(v, options.max_field_bytes))
        }),
        "placeholder" => node
            .placeholder
            .as_ref()
            .filter(|v| !v.is_empty())
            .map(|v| format!("placeholder=\"{}\"", render_field(v, options.max_field_bytes))),
        "desc" => node
            .description
            .as_ref()
            .filter(|v| !v.is_empty())
            .map(|v| format!("desc=\"{}\"", render_field(v, options.max_field_bytes))),
        "enabled" => Some(format!("enabled={}", node.enabled)),
        "focused" => Some(format!("focused={}", node.focused)),
        "selected" => Some(format!("selected={}", node.selected)),
        "frame" => Some(format!("frame={}", render_frame(node.frame.as_ref()))),
        "actions" => {
            if node.actions.is_empty() {
                None
            } else {
                let names: Vec<String> = node
                    .actions
                    .iter()
                    .map(|a| sanitize_token(&strip_ax_prefix(a)))
                    .collect();
                Some(format!("actions=[{}]", names.join(",")))
            }
        }
        _ => None,
    }
}

pub fn collapse_removed(ids: &[u64]) -> String {
    if ids.is_empty() {
        return String::new();
    }
    let mut pieces = Vec::new();
    let mut run_start = ids[0];
    let mut run_end = ids[0];

    let flush = |pieces: &mut Vec<String>, run_start: u64, run_end: u64| {
        let length = run_end - run_start + 1;
        if length >= 3 {
            pieces.push(format!("e{run_start}..e{run_end}"));
        } else {
            for value in run_start..=run_end {
                pieces.push(format!("e{value}"));
            }
        }
    };

    for &id in ids.iter().skip(1) {
        if id == run_end + 1 {
            run_end = id;
        } else {
            flush(&mut pieces, run_start, run_end);
            run_start = id;
            run_end = id;
        }
    }
    flush(&mut pieces, run_start, run_end);
    pieces.join(",")
}

#[cfg(test)]
mod tests {
    use super::*;
    use semantouch_protocol::Rect;

    fn node(id: u64, role: &str, title: &str, children: Vec<UiNode>) -> UiNode {
        UiNode {
            id,
            role: role.into(),
            subrole: None,
            title: Some(title.into()),
            value: None,
            description: None,
            placeholder: None,
            ax_identifier: None,
            enabled: true,
            focused: false,
            selected: false,
            frame: Some(Rect::new(0.0, 0.0, 10.0, 10.0)),
            actions: vec![],
            settable_attributes: vec![],
            children,
        }
    }

    #[test]
    fn apply_reconstructs_current_exactly() {
        let prev = node(
            1,
            "AXWindow",
            "A",
            vec![node(2, "AXButton", "OK", vec![])],
        );
        let mut curr = prev.clone();
        curr.children[0].value = Some("pressed".into());
        curr.children.push(node(3, "AXButton", "Cancel", vec![]));

        let diff = compute(&prev, &curr, 1, 2, RenderOptions::default());
        assert!(!diff.reused_id_conflict);
        let rebuilt = apply(&diff, &prev);
        assert_eq!(rebuilt, curr);

        let text = render_diff(&diff, RenderOptions::default());
        assert!(text.starts_with("UI revision 2, based on 1"));
        assert!(text.contains("~ "));
        assert!(text.contains("+ "));
    }

    #[test]
    fn collapse_removed_runs() {
        assert_eq!(collapse_removed(&[3, 51, 52, 53, 54, 55]), "e3,e51..e55");
        assert_eq!(collapse_removed(&[1, 2]), "e1,e2");
    }
}
