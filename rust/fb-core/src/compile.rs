// Walker JSON decode + combined-output assembly.
// Walker emits camelCase keys (nodeId/isDisabled/currentValue/nodesAudited/
// hiddenNodesPurged/matchedRules/hiddenFlags/renderHidden) — serde matches via
// rename_all="camelCase". Combined output shape (Swift decodes one blob):
//   {"markdown":"...","nodes":[{nodeId,role,name,isDisabled,currentValue}],
//    "audit":{nodesAudited,hiddenNodesPurged,matchedRules}}
use crate::markdown::to_markdown;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractResult {
    pub nodes: Vec<ExtractedNode>,
    pub url: String,
    pub title: String,
    pub nodes_audited: i64,
    pub hidden_nodes_purged: i64,
    pub matched_rules: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractedNode {
    pub node_id: String,
    pub role: String,
    pub name: String,
    pub is_disabled: bool,
    pub current_value: String,
    #[allow(dead_code)]
    pub fingerprint: String,
    #[allow(dead_code)]
    pub doc_path: String,
    pub hidden_flags: BTreeMap<String, bool>,
    pub render_hidden: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WireNode<'a> {
    node_id: &'a str,
    role: &'a str,
    name: &'a str,
    is_disabled: bool,
    current_value: &'a str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AuditOut<'a> {
    nodes_audited: i64,
    hidden_nodes_purged: i64,
    matched_rules: &'a [String],
}

#[derive(Debug, Serialize)]
struct CombinedOut<'a> {
    markdown: String,
    nodes: Vec<WireNode<'a>>,
    audit: AuditOut<'a>,
}

// Decode walker JSON -> emit combined {markdown,nodes,audit} JSON bytes.
// Returns Err on decode failure (caller maps to FB_ERR_DECODE).
pub fn compile(input: &[u8]) -> Result<Vec<u8>, serde_json::Error> {
    let res: ExtractResult = serde_json::from_slice(input)?;
    let markdown = to_markdown(&res);
    let nodes: Vec<WireNode> = res.nodes.iter().map(|n| WireNode {
        node_id: &n.node_id,
        role: &n.role,
        name: &n.name,
        is_disabled: n.is_disabled,
        current_value: &n.current_value,
    }).collect();
    let out = CombinedOut {
        markdown,
        nodes,
        audit: AuditOut {
            nodes_audited: res.nodes_audited,
            hidden_nodes_purged: res.hidden_nodes_purged,
            matched_rules: &res.matched_rules,
        },
    };
    serde_json::to_vec(&out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_and_emit() {
        let json = br#"{"nodes":[{"nodeId":"e1","role":"button","name":"Go","isDisabled":false,"currentValue":"","fingerprint":"f","docPath":"d","hiddenFlags":{},"renderHidden":false}],"url":"https://x","title":"T","nodesAudited":1,"hiddenNodesPurged":0,"matchedRules":[]}"#;
        let out = compile(json).unwrap();
        let s = String::from_utf8(out).unwrap();
        assert!(s.contains("\"markdown\":\"# Page\\nurl: https://x"));
        assert!(s.contains("\"nodeId\":\"e1\""));
        assert!(s.contains("\"nodesAudited\":1"));
    }

    #[test]
    fn decode_err_on_bad_json() {
        assert!(compile(b"not json").is_err());
    }
}
