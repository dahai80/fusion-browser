// Parity integration tests: load tests/parity.json, assert Rust to_markdown +
// compile() emit byte-exact markdown vs the pinned expected strings. Shared
// with Swift RustCoreParityTests (same fixture file, same expected strings).
use fb_core::compile::compile;
use fb_core::markdown::to_markdown;
use serde::Deserialize;
use std::fs;

#[derive(Debug, Deserialize)]
struct Fixture {
    cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
struct Case {
    name: String,
    input: InputJSON,
    expected_markdown: String,
}

// Raw JSON value kept as serde_json::Value so we can re-serialize it to bytes
// and feed compile() — avoids re-deriving the exact walker shape here.
#[derive(Debug, Deserialize)]
struct InputJSON(serde_json::Value);

fn load_fixture() -> Fixture {
    let path = env!("CARGO_MANIFEST_DIR").to_string() + "/tests/parity.json";
    let raw = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read parity.json at {}: {}", path, e));
    serde_json::from_str(&raw)
        .unwrap_or_else(|e| panic!("parse parity.json: {}", e))
}

#[test]
fn to_markdown_parity_all_cases() {
    let fixture = load_fixture();
    for c in &fixture.cases {
        let bytes = serde_json::to_vec(&c.input.0).unwrap();
        let res: fb_core::compile::ExtractResult =
            serde_json::from_slice(&bytes).expect("decode input");
        let md = to_markdown(&res);
        assert_eq!(
            md, c.expected_markdown,
            "to_markdown mismatch case={}",
            c.name
        );
    }
}

#[test]
fn compile_emits_markdown_field_parity() {
    // compile() returns combined JSON; the "markdown" field must match expected
    // byte-for-byte (Swift decodes this field as the wire markdown).
    #[derive(Debug, Deserialize)]
    struct Combined {
        markdown: String,
    }
    let fixture = load_fixture();
    for c in &fixture.cases {
        let bytes = serde_json::to_vec(&c.input.0).unwrap();
        let out = compile(&bytes).expect("compile ok");
        let combined: Combined = serde_json::from_slice(&out).expect("decode combined");
        assert_eq!(
            combined.markdown, c.expected_markdown,
            "compile markdown mismatch case={}",
            c.name
        );
    }
}

#[test]
fn compile_decode_err_is_err() {
    assert!(compile(b"{ not json").is_err());
}

#[test]
fn compile_empty_nodes_ok() {
    let fixture = load_fixture();
    let empty = fixture.cases.iter().find(|c| c.name == "empty_nodes").unwrap();
    let bytes = serde_json::to_vec(&empty.input.0).unwrap();
    let out = compile(&bytes).unwrap();
    let s = String::from_utf8(out).unwrap();
    assert!(s.contains("\"nodes\":[]"));
    assert!(s.contains("\"nodesAudited\":0"));
}
