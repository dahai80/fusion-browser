// AXTree markdown reduction — byte-exact replica of FBAXTreeReducer.toMarkdown (Swift).
// Format contract (see AXTree.swift:70-84):
//   Line 1: "# Page"
//   Line 2: "url: <url>"
//   Line 3: "title: <title>"
//   Line 4: "" (blank)
//   Line 5: "# 交互节点"
//   Then per node: "- [@eN] <role>" + optional suffixes IN ORDER:
//     name     -> " “<name>”"   (U+201C / U+201D curly quotes, only if non-empty)
//     val      -> " (val:<currentValue>)"  (only if non-empty)
//     disabled -> " [disabled]"  (only if true)
//     purged   -> " {purged:<keys>}"  (if renderHidden OR hiddenFlags non-empty;
//                keys = hiddenFlags.keys sorted asc, plus "render:hidden" appended
//                last if renderHidden, joined with ",")
// Joined with "\n" (no trailing newline).
use crate::compile::{ExtractedNode, ExtractResult};

const LEFT_DQUOTE: &str = "\u{201C}";
const RIGHT_DQUOTE: &str = "\u{201D}";

pub fn to_markdown(res: &ExtractResult) -> String {
    let mut lines: Vec<String> = Vec::with_capacity(res.nodes.len() + 5);
    lines.push("# Page".to_string());
    lines.push(format!("url: {}", res.url));
    lines.push(format!("title: {}", res.title));
    lines.push(String::new());
    lines.push("# 交互节点".to_string());
    for n in &res.nodes {
        lines.push(format_node(n));
    }
    lines.join("\n")
}

fn format_node(n: &ExtractedNode) -> String {
    let mut line = format!("- [@{}] {}", n.node_id, n.role);
    if !n.name.is_empty() {
        line.push(' ');
        line.push_str(LEFT_DQUOTE);
        line.push_str(&n.name);
        line.push_str(RIGHT_DQUOTE);
    }
    if !n.current_value.is_empty() {
        line.push_str(&format!(" (val:{})", n.current_value));
    }
    if n.is_disabled {
        line.push_str(" [disabled]");
    }
    if n.render_hidden || !n.hidden_flags.is_empty() {
        let mut hits: Vec<String> = n.hidden_flags.keys().cloned().collect();
        hits.sort();
        if n.render_hidden {
            hits.push("render:hidden".to_string());
        }
        line.push_str(&format!(" {{purged:{}}}", hits.join(",")));
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compile::ExtractResult;
    use std::collections::BTreeMap;

    fn node(id: &str, role: &str, name: &str, val: &str, disabled: bool,
            hidden: &[&str], render_hidden: bool) -> ExtractedNode {
        let mut hf = BTreeMap::new();
        for k in hidden {
            hf.insert(k.to_string(), true);
        }
        ExtractedNode {
            node_id: id.to_string(),
            role: role.to_string(),
            name: name.to_string(),
            is_disabled: disabled,
            current_value: val.to_string(),
            fingerprint: String::new(),
            doc_path: String::new(),
            hidden_flags: hf,
            render_hidden,
        }
    }

    fn result(nodes: Vec<ExtractedNode>) -> ExtractResult {
        let n = nodes.len() as i64;
        ExtractResult {
            nodes,
            url: "https://example.com".to_string(),
            title: "Example".to_string(),
            nodes_audited: n,
            hidden_nodes_purged: 0,
            matched_rules: vec![],
        }
    }

    #[test]
    fn header_exact() {
        let md = to_markdown(&result(vec![]));
        assert_eq!(md, "# Page\nurl: https://example.com\ntitle: Example\n\n# 交互节点");
    }

    #[test]
    fn plain_node() {
        let md = to_markdown(&result(vec![node("e1", "button", "Login", "", false, &[], false)]));
        assert!(md.contains("- [@e1] button \u{201C}Login\u{201D}"));
    }

    #[test]
    fn disabled_and_val() {
        let md = to_markdown(&result(vec![node("e2", "textbox", "用户名", "********", true, &[], false)]));
        assert!(md.contains("- [@e2] textbox \u{201C}用户名\u{201D} (val:********) [disabled]"));
    }

    #[test]
    fn purged_sorted_with_render() {
        let md = to_markdown(&result(vec![node("e3", "link", "", "", false, &["opacity:0", "display:none"], true)]));
        // sorted: "display:none","opacity:0" then "render:hidden"
        assert!(md.contains("{purged:display:none,opacity:0,render:hidden}"));
    }
}
