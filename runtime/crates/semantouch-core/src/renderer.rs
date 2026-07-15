//! Pure `semantouch-ax-tree-v1` renderer (§7).

use semantouch_protocol::{Rect, UiNode, MAX_FIELD_BYTES, MAX_TREE_BYTES, DEFAULT_MAX_NODES};

#[derive(Clone, Copy, Debug)]
pub struct RenderOptions {
    pub max_nodes: usize,
    pub max_bytes: usize,
    pub max_field_bytes: usize,
}

impl Default for RenderOptions {
    fn default() -> Self {
        Self {
            max_nodes: DEFAULT_MAX_NODES,
            max_bytes: MAX_TREE_BYTES,
            max_field_bytes: MAX_FIELD_BYTES,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderResult {
    pub text: String,
    pub node_count: usize,
    pub truncated: bool,
}

pub fn render(root: &UiNode, options: RenderOptions) -> RenderResult {
    let mut flat: Vec<(usize, &UiNode)> = Vec::new();
    flatten(root, 0, &mut flat);
    let total = flat.len();
    let lines: Vec<String> = flat
        .iter()
        .map(|(d, n)| render_line(*d, n, &options))
        .collect();

    let mut accepted = 0usize;
    let mut used_bytes = 0usize;
    let mut first_omitted = None;
    for (i, line) in lines.iter().enumerate() {
        let sep = if accepted == 0 { 0 } else { 1 };
        let cost = sep + line.len();
        if accepted + 1 > options.max_nodes || used_bytes + cost > options.max_bytes {
            first_omitted = Some(i);
            break;
        }
        used_bytes += cost;
        accepted += 1;
    }

    if first_omitted.is_none() {
        return RenderResult {
            text: lines.join("\n"),
            node_count: accepted,
            truncated: false,
        };
    }

    loop {
        let omitted = total - accepted;
        let marker_depth = flat[accepted].0;
        let marker = marker_line(marker_depth, omitted);
        let sep = if accepted == 0 { 0 } else { 1 };
        if used_bytes + sep + marker.len() <= options.max_bytes || accepted == 0 {
            let mut out: Vec<String> = lines[..accepted].to_vec();
            out.push(marker);
            return RenderResult {
                text: out.join("\n"),
                node_count: accepted,
                truncated: true,
            };
        }
        accepted -= 1;
        let popped_sep = if accepted == 0 { 0 } else { 1 };
        used_bytes -= popped_sep + lines[accepted].len();
    }
}

fn flatten<'a>(node: &'a UiNode, depth: usize, out: &mut Vec<(usize, &'a UiNode)>) {
    out.push((depth, node));
    for child in &node.children {
        flatten(child, depth + 1, out);
    }
}

fn marker_line(depth: usize, omitted: usize) -> String {
    format!("{}… +{omitted} nodes omitted", indent(depth))
}

pub fn render_line(depth: usize, node: &UiNode, options: &RenderOptions) -> String {
    format!(
        "{}{} {}",
        indent(depth),
        identity_segment(node, options),
        attribute_segment(node, options)
    )
}

pub fn identity_segment(node: &UiNode, options: &RenderOptions) -> String {
    let mut s = format!("[e{}] {}", node.id, sanitize_token(&node.role));
    if let Some(sub) = &node.subrole {
        if !sub.is_empty() {
            s.push('.');
            s.push_str(&sanitize_token(sub));
        }
    }
    if let Some(title) = &node.title {
        if !title.is_empty() {
            s.push_str(" \"");
            s.push_str(&render_field(title, options.max_field_bytes));
            s.push('"');
        }
    }
    s
}

pub fn attribute_segment(node: &UiNode, options: &RenderOptions) -> String {
    attribute_tokens(node, options)
        .into_iter()
        .map(|(_, t)| t)
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn attribute_tokens(node: &UiNode, options: &RenderOptions) -> Vec<(String, String)> {
    let mut parts = Vec::new();
    if let Some(value) = &node.value {
        if !value.is_empty() {
            parts.push((
                "value".into(),
                format!(
                    "value=\"{}\"",
                    render_field(value, options.max_field_bytes)
                ),
            ));
        }
    }
    if let Some(ph) = &node.placeholder {
        if !ph.is_empty() {
            parts.push((
                "placeholder".into(),
                format!(
                    "placeholder=\"{}\"",
                    render_field(ph, options.max_field_bytes)
                ),
            ));
        }
    }
    if let Some(desc) = &node.description {
        if !desc.is_empty() {
            parts.push((
                "desc".into(),
                format!(
                    "desc=\"{}\"",
                    render_field(desc, options.max_field_bytes)
                ),
            ));
        }
    }
    if !node.enabled {
        parts.push(("enabled".into(), "enabled=false".into()));
    }
    if node.focused {
        parts.push(("focused".into(), "focused=true".into()));
    }
    if node.selected {
        parts.push(("selected".into(), "selected=true".into()));
    }
    parts.push(("frame".into(), format!("frame={}", render_frame(node.frame.as_ref()))));
    if !node.actions.is_empty() {
        let names: Vec<String> = node
            .actions
            .iter()
            .map(|a| sanitize_token(&strip_ax_prefix(a)))
            .collect();
        parts.push(("actions".into(), format!("actions=[{}]", names.join(","))));
    }
    parts
}

fn indent(depth: usize) -> String {
    "  ".repeat(depth)
}

pub fn render_frame(frame: Option<&Rect>) -> String {
    match frame {
        None => "?".into(),
        Some(f) => {
            let r = |v: f64| v.round() as i64;
            format!("{},{},{},{}", r(f.x), r(f.y), r(f.width), r(f.height))
        }
    }
}

pub fn strip_ax_prefix(name: &str) -> String {
    name.strip_prefix("AX").unwrap_or(name).to_string()
}

pub fn sanitize_token(token: &str) -> String {
    token
        .chars()
        .map(|c| {
            if c == '"' || c == '[' || c == ']' || c.is_whitespace() {
                '_'
            } else {
                c
            }
        })
        .collect()
}

pub fn escape_unit(c: char) -> String {
    match c {
        '\\' => "\\\\".into(),
        '"' => "\\\"".into(),
        '\n' => "\\n".into(),
        '\r' => "\\r".into(),
        '\t' => "\\t".into(),
        c if (c as u32) < 0x20 => format!("\\u{:04x}", c as u32),
        c => c.to_string(),
    }
}

pub fn render_field(raw: &str, cap: usize) -> String {
    let units: Vec<String> = raw.chars().map(escape_unit).collect();
    let total: usize = units.iter().map(|u| u.len()).sum();
    if total <= cap {
        return units.concat();
    }
    let ellipsis = "…";
    let budget = cap.saturating_sub(ellipsis.len());
    let mut out = String::new();
    let mut acc = 0usize;
    for unit in units {
        if acc + unit.len() > budget {
            break;
        }
        acc += unit.len();
        out.push_str(&unit);
    }
    out.push_str(ellipsis);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use semantouch_protocol::Rect;

    fn sample_tree() -> UiNode {
        UiNode {
            id: 1,
            role: "AXWindow".into(),
            subrole: None,
            title: Some("Demo".into()),
            value: None,
            description: None,
            placeholder: None,
            ax_identifier: None,
            enabled: true,
            focused: false,
            selected: false,
            frame: Some(Rect::new(0.0, 0.0, 100.0, 50.0)),
            actions: vec![],
            settable_attributes: vec![],
            children: vec![UiNode {
                id: 2,
                role: "AXButton".into(),
                subrole: None,
                title: Some("OK".into()),
                value: None,
                description: None,
                placeholder: None,
                ax_identifier: None,
                enabled: true,
                focused: true,
                selected: false,
                frame: Some(Rect::new(10.0, 10.0, 40.0, 20.0)),
                actions: vec!["AXPress".into()],
                settable_attributes: vec![],
                children: vec![],
            }],
        }
    }

    #[test]
    fn renders_deterministic_tree_text() {
        let r = render(&sample_tree(), RenderOptions::default());
        assert!(!r.truncated);
        assert_eq!(r.node_count, 2);
        assert!(r.text.contains("[e1] AXWindow \"Demo\""));
        assert!(r.text.contains("[e2] AXButton \"OK\""));
        assert!(r.text.contains("focused=true"));
        assert!(r.text.contains("actions=[Press]"));
        assert!(!r.text.ends_with('\n'));
    }

    #[test]
    fn truncates_under_node_budget() {
        let r = render(
            &sample_tree(),
            RenderOptions {
                max_nodes: 1,
                max_bytes: MAX_TREE_BYTES,
                max_field_bytes: MAX_FIELD_BYTES,
            },
        );
        assert!(r.truncated);
        assert_eq!(r.node_count, 1);
        assert!(r.text.contains("nodes omitted"));
    }
}
