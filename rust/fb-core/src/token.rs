// fb_core_estimate_tokens: local heuristic token counter (no external tokenizer dep).
// NOT a real BPE — cheap approximation for the benchmark/observability path.
// Heuristic: count runs of word chars as tokens + 1 per non-word char, similar to
// a coarse whitespace+punctuation split. Stays deterministic + allocation-light.
pub fn estimate_tokens(md: &str) -> u32 {
    let mut tokens: u32 = 0;
    let mut in_word = false;
    for ch in md.chars() {
        let is_word = ch.is_alphanumeric() || ch == '_' || ch == '-';
        if is_word {
            if !in_word {
                tokens = tokens.saturating_add(1);
                in_word = true;
            }
        } else {
            in_word = false;
            if ch.is_whitespace() {
                continue;
            }
            tokens = tokens.saturating_add(1);
        }
    }
    tokens
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_words_and_punct() {
        // "# Page\nurl: x" -> tokens: "#", "Page", "url", ":", "x" = 5
        assert_eq!(estimate_tokens("# Page\nurl: x"), 5);
    }

    #[test]
    fn empty_is_zero() {
        assert_eq!(estimate_tokens(""), 0);
    }

    #[test]
    fn curly_quotes_split() {
        // "“name”" -> curly quotes are non-word non-space -> 2 punct tokens + 1 word = 3
        assert_eq!(estimate_tokens("“name”"), 3);
    }
}
