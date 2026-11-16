//! md2pdf - convert Markdown to PDF.
//!
//! Single file, standard library only, no `unsafe`, no subprocesses, no network.
//!
//! Build:  rustc -O md2pdf.rs
//! Usage:  md2pdf INPUT.md [-o OUTPUT.pdf] [--paper a4|letter] [--font-size PT] [--margin PT]
//!         md2pdf - -o out.pdf      (read Markdown from stdin)
//!
//! Supported: headings (ATX + setext), paragraphs, hard line breaks, bold, italic,
//! strikethrough, inline code, fenced code blocks, nested bullet/numbered lists,
//! blockquotes, tables (with alignment), horizontal rules, links and autolinks.
//!
//! Limits: text is set in the PDF built-in fonts (Helvetica/Courier), so only
//! Latin-1 / Windows-1252 characters render; others become '?'. Images are not
//! loaded (alt text is shown). Raw HTML is printed literally, never interpreted.

#![forbid(unsafe_code)]

use std::env;
use std::fmt::Write as _;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::rc::Rc;

/// Refuse inputs larger than this (bytes).
const MAX_INPUT: u64 = 64 * 1024 * 1024;
/// Maximum nesting of quotes / lists / inline emphasis (bounds recursion).
const MAX_NEST: usize = 16;
/// How far ahead the inline parser searches for a closing delimiter.
/// Keeps parsing linear even on adversarial input.
const LOOKAHEAD: usize = 4000;
const MAX_URL: usize = 2048;
const MAX_COLS: usize = 24;

// ───────────────────────────── document model ─────────────────────────────

#[derive(Clone, Copy, PartialEq, Default)]
struct Style {
    bold: bool,
    italic: bool,
    code: bool,
    strike: bool,
}

#[derive(Clone)]
struct Span {
    text: String,
    style: Style,
    link: Option<Rc<str>>,
}

#[derive(Clone, Copy, PartialEq)]
enum Align {
    Left,
    Center,
    Right,
}

type Cell = Vec<Span>;

enum Block {
    Heading(usize, Vec<Span>),
    Para(Vec<Span>),
    Code { lines: Vec<String>, depth: usize },
    Item { depth: usize, marker: String, spans: Vec<Span> },
    Quote(Vec<Block>),
    Table { head: Vec<Cell>, rows: Vec<Vec<Cell>>, align: Vec<Align> },
    Rule,
}

// ───────────────────────────── block parser ─────────────────────────────

fn indent_of(line: &str) -> usize {
    let mut n = 0;
    for c in line.chars() {
        match c {
            ' ' => n += 1,
            '\t' => n += 4,
            _ => break,
        }
    }
    n
}

/// Opening code fence: returns (fence char, fence length).
fn fence(t: &str) -> Option<(char, usize)> {
    let ch = t.chars().next()?;
    if ch != '`' && ch != '~' {
        return None;
    }
    let n = t.chars().take_while(|&c| c == ch).count();
    if n < 3 || (ch == '`' && t[n..].contains('`')) {
        return None;
    }
    Some((ch, n))
}

fn heading(t: &str) -> Option<(usize, &str)> {
    let n = t.bytes().take_while(|&b| b == b'#').count();
    if !(1..=6).contains(&n) {
        return None;
    }
    let rest = &t[n..];
    if !(rest.is_empty() || rest.starts_with(' ') || rest.starts_with('\t')) {
        return None;
    }
    let s = rest.trim();
    let stripped = s.trim_end_matches('#');
    let text = if stripped.is_empty() || stripped.ends_with(' ') { stripped.trim_end() } else { s };
    Some((n, text))
}

fn is_rule(t: &str) -> bool {
    let mut ch = None;
    let mut n = 0;
    for c in t.chars() {
        if c == ' ' || c == '\t' {
            continue;
        }
        if matches!(c, '-' | '*' | '_') && ch.map_or(true, |x| x == c) {
            ch = Some(c);
            n += 1;
        } else {
            return false;
        }
    }
    n >= 3
}

/// List marker: returns (indent, Some(start number) if ordered, item text).
fn marker(line: &str) -> Option<(usize, Option<u64>, &str)> {
    let t = line.trim_start();
    let b = t.as_bytes();
    let first = *b.first()?;
    let is_sep = |i: usize| b.get(i).map_or(true, |&c| c == b' ' || c == b'\t');
    if matches!(first, b'-' | b'*' | b'+') && is_sep(1) {
        return Some((indent_of(line), None, t[1..].trim_start()));
    }
    let digits = b.iter().take_while(|c| c.is_ascii_digit()).count();
    if (1..=9).contains(&digits) && matches!(b.get(digits), Some(b'.') | Some(b')')) && is_sep(digits + 1) {
        let start = t[..digits].parse().ok()?;
        return Some((indent_of(line), Some(start), t[digits + 1..].trim_start()));
    }
    None
}

/// Would this line end a running paragraph?
fn starts_block(line: &str) -> bool {
    let t = line.trim_start();
    if t.is_empty() || fence(t).is_some() || heading(t).is_some() || is_rule(t) || t.starts_with('>') {
        return true;
    }
    match marker(line) {
        Some((_, None, text)) => !text.is_empty(),
        Some((_, Some(n), text)) => n == 1 && !text.is_empty(),
        None => false,
    }
}

/// Join soft-wrapped source lines; "two trailing spaces" or "\" make a hard break.
fn join_lines(lines: &[&str]) -> String {
    let mut s = String::new();
    for (i, l) in lines.iter().enumerate() {
        let last = i + 1 == lines.len();
        let hard = !last && (l.ends_with("  ") || l.ends_with('\\'));
        let body = l.trim();
        let body = if hard { body.trim_end_matches('\\') } else { body };
        s.push_str(body);
        if !last {
            s.push(if hard { '\n' } else { ' ' });
        }
    }
    s
}

fn split_cells(line: &str) -> Vec<String> {
    let t = line.trim();
    let t = t.strip_prefix('|').unwrap_or(t);
    let mut cells = Vec::new();
    let mut cur = String::new();
    let mut chars = t.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&'|') => {
                cur.push('|');
                chars.next();
            }
            '|' => cells.push(std::mem::take(&mut cur).trim().to_string()),
            _ => cur.push(c),
        }
    }
    if !cur.trim().is_empty() {
        cells.push(cur.trim().to_string());
    }
    cells
}

fn table_align(line: &str) -> Option<Vec<Align>> {
    if !line.contains('-') || !line.contains('|') {
        return None;
    }
    let cells = split_cells(line);
    if cells.is_empty() {
        return None;
    }
    let mut out = Vec::new();
    for c in &cells {
        let (l, r) = (c.starts_with(':'), c.ends_with(':') && c.len() > 1);
        let core = c.trim_matches(':');
        if core.is_empty() || !core.bytes().all(|b| b == b'-') {
            return None;
        }
        out.push(match (l, r) {
            (true, true) => Align::Center,
            (false, true) => Align::Right,
            _ => Align::Left,
        });
    }
    Some(out)
}

fn parse_blocks(lines: &[&str], nest: usize) -> Vec<Block> {
    let mut out: Vec<Block> = Vec::new();
    let mut list: Vec<(usize, u64)> = Vec::new(); // (indent, next number) per open list level
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let t = line.trim_start();
        let mut keep_list = false;

        if t.is_empty() {
            i += 1;
            keep_list = true;
        } else if let Some((ch, n)) = fence(t) {
            let ind = indent_of(line);
            let mut body = Vec::new();
            i += 1;
            while i < lines.len() {
                let l = lines[i];
                let lt = l.trim();
                i += 1;
                if lt.len() >= n && lt.chars().all(|c| c == ch) {
                    break;
                }
                // Drop up to `ind` columns of leading indentation.
                let mut cut = 0;
                for (col, c) in l.char_indices() {
                    if col >= ind || c != ' ' {
                        break;
                    }
                    cut = col + 1;
                }
                body.push(l[cut..].replace('\t', "    "));
            }
            let depth = match out.last() {
                Some(Block::Item { depth, .. }) if ind >= 2 && !list.is_empty() => depth + 1,
                Some(Block::Code { depth, .. }) if ind >= 2 && !list.is_empty() => *depth,
                _ => 0,
            };
            keep_list = depth > 0;
            out.push(Block::Code { lines: body, depth });
        } else if let Some((lv, text)) = heading(t) {
            out.push(Block::Heading(lv, parse_inline(text)));
            i += 1;
        } else if is_rule(t) {
            out.push(Block::Rule);
            i += 1;
        } else if t.starts_with('>') {
            let mut inner: Vec<&str> = Vec::new();
            while i < lines.len() {
                let lt = lines[i].trim_start();
                if let Some(rest) = lt.strip_prefix('>') {
                    inner.push(rest.strip_prefix(' ').unwrap_or(rest));
                } else if !inner.is_empty() && !starts_block(lines[i]) {
                    inner.push(lt); // lazy continuation
                } else {
                    break;
                }
                i += 1;
            }
            if nest < MAX_NEST {
                out.push(Block::Quote(parse_blocks(&inner, nest + 1)));
            } else {
                out.push(Block::Para(parse_inline(&join_lines(&inner))));
            }
        } else if let Some((ind, ordered, text)) = marker(line) {
            let mut parts = vec![text];
            i += 1;
            while i < lines.len() && !starts_block(lines[i]) && marker(lines[i]).is_none() {
                parts.push(lines[i]);
                i += 1;
            }
            while list.last().map_or(false, |&(li, _)| ind < li) {
                list.pop();
            }
            let deeper = list.last().map_or(true, |&(li, _)| ind >= li + 2);
            if deeper && list.len() < MAX_NEST {
                list.push((ind, ordered.unwrap_or(1)));
            }
            let depth = list.len() - 1;
            let mark = match ordered {
                Some(_) => {
                    let n = list[depth].1;
                    list[depth].1 = n.saturating_add(1);
                    format!("{n}.")
                }
                None => (if depth % 2 == 0 { "\u{2022}" } else { "\u{2013}" }).to_string(),
            };
            out.push(Block::Item { depth, marker: mark, spans: parse_inline(&join_lines(&parts)) });
            keep_list = true;
        } else if t.contains('|') && i + 1 < lines.len() && table_align(lines[i + 1]).is_some() {
            let mut align = table_align(lines[i + 1]).unwrap_or_default();
            let mut head: Vec<Cell> = split_cells(line).iter().map(|c| parse_inline(c)).collect();
            head.truncate(MAX_COLS);
            align.resize(head.len(), Align::Left);
            i += 2;
            let mut rows = Vec::new();
            while i < lines.len() && !lines[i].trim().is_empty() && lines[i].contains('|') {
                let mut row: Vec<Cell> = split_cells(lines[i]).iter().map(|c| parse_inline(c)).collect();
                row.truncate(head.len());
                rows.push(row);
                i += 1;
            }
            out.push(Block::Table { head, rows, align });
        } else {
            let mut parts = vec![line];
            i += 1;
            let mut setext = 0;
            while i < lines.len() {
                let lt = lines[i].trim();
                if !lt.is_empty() && lt.bytes().all(|b| b == b'=') {
                    setext = 1;
                } else if lt.len() >= 2 && lt.bytes().all(|b| b == b'-') {
                    setext = 2;
                }
                if setext > 0 {
                    i += 1;
                    break;
                }
                if starts_block(lines[i]) {
                    break;
                }
                parts.push(lines[i]);
                i += 1;
            }
            let spans = parse_inline(&join_lines(&parts));
            out.push(if setext > 0 { Block::Heading(setext, spans) } else { Block::Para(spans) });
        }
        if !keep_list {
            list.clear();
        }
    }
    out
}

// ───────────────────────────── inline parser ─────────────────────────────

fn parse_inline(src: &str) -> Vec<Span> {
    let chars: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    inline(&chars, Style::default(), None, &mut out, 0);
    out
}

fn run_len(c: &[char], i: usize) -> usize {
    c[i..].iter().take_while(|&&x| x == c[i]).count()
}

/// Find a run of exactly `n` backticks starting at or after `from`.
fn find_ticks(c: &[char], from: usize, n: usize) -> Option<usize> {
    let end = c.len().min(from + LOOKAHEAD);
    let mut j = from;
    while j < end {
        if c[j] == '`' {
            let r = run_len(c, j);
            if r == n {
                return Some(j);
            }
            j += r;
        } else {
            j += 1;
        }
    }
    None
}

/// Find the closing delimiter run for an emphasis opener of `n` × `ch`.
fn find_close(c: &[char], from: usize, ch: char, n: usize) -> Option<usize> {
    let end = c.len().min(from + LOOKAHEAD);
    let mut j = from;
    while j < end {
        if c[j] == '\\' {
            j += 2;
        } else if c[j] == '`' {
            let r = run_len(c, j);
            j = find_ticks(c, j + r, r).map_or(j + r, |e| e + r);
        } else if c[j] == ch {
            let r = run_len(c, j);
            let after_ok = ch != '_' || c.get(j + r).map_or(true, |x| !x.is_alphanumeric());
            if j > from && !c[j - 1].is_whitespace() && after_ok {
                if r == n {
                    return Some(j);
                }
                if r == 3 && n < 3 && ch != '~' {
                    return Some(j + r - n); // "***" closes an inner and an outer span
                }
            }
            j += r;
        } else {
            j += 1;
        }
    }
    None
}

/// Parse `[text](url "title")` starting at the `[`. Returns (index of `]`, index after `)`, url).
fn find_link(c: &[char], open: usize) -> Option<(usize, usize, String)> {
    let end = c.len().min(open + LOOKAHEAD);
    let mut depth = 0usize;
    let mut j = open;
    let close = loop {
        if j >= end {
            return None;
        }
        match c[j] {
            '\\' => j += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    break j;
                }
            }
            _ => {}
        }
        j += 1;
    };
    if c.get(close + 1) != Some(&'(') {
        return None;
    }
    let mut paren = 1usize;
    let mut k = close + 2;
    while k < end {
        match c[k] {
            '(' => paren += 1,
            ')' => {
                paren -= 1;
                if paren == 0 {
                    let dest: String = c[close + 2..k].iter().collect();
                    let url = dest.trim().split_whitespace().next().unwrap_or("");
                    let url = url.trim_start_matches('<').trim_end_matches('>');
                    return Some((close, k + 1, url.to_string()));
                }
            }
            _ => {}
        }
        k += 1;
    }
    None
}

/// Only plain web / mail links become clickable. Everything else
/// (javascript:, file:, data:, relative paths ...) is rendered as text only.
fn safe_url(url: &str) -> Option<Rc<str>> {
    let lower = url.to_ascii_lowercase();
    let ok_scheme = ["http://", "https://", "mailto:"].iter().any(|s| lower.starts_with(s));
    if ok_scheme && url.len() <= MAX_URL && !url.chars().any(|c| c.is_control()) {
        Some(Rc::from(url))
    } else {
        None
    }
}

fn flush(out: &mut Vec<Span>, buf: &mut String, style: Style, link: &Option<Rc<str>>) {
    if !buf.is_empty() {
        out.push(Span { text: std::mem::take(buf), style, link: link.clone() });
    }
}

fn inline(c: &[char], style: Style, link: Option<Rc<str>>, out: &mut Vec<Span>, depth: usize) {
    let mut buf = String::new();
    let mut i = 0;
    while i < c.len() {
        let ch = c[i];
        match ch {
            '\\' if c.get(i + 1).map_or(false, |x| x.is_ascii_punctuation()) => {
                buf.push(c[i + 1]);
                i += 2;
                continue;
            }
            '`' => {
                let n = run_len(c, i);
                if let Some(j) = find_ticks(c, i + n, n) {
                    flush(out, &mut buf, style, &link);
                    let mut text: String = c[i + n..j].iter().map(|&x| if x == '\n' { ' ' } else { x }).collect();
                    if text.len() > 2 && text.starts_with(' ') && text.ends_with(' ') && !text.trim().is_empty() {
                        text = text[1..text.len() - 1].to_string();
                    }
                    out.push(Span { text, style: Style { code: true, ..style }, link: link.clone() });
                    i = j + n;
                } else {
                    buf.extend(std::iter::repeat('`').take(n));
                    i += n;
                }
                continue;
            }
            '*' | '_' | '~' => {
                let n = run_len(c, i);
                let len_ok = if ch == '~' { n == 2 } else { n <= 3 };
                let next_ok = c.get(i + n).map_or(false, |x| !x.is_whitespace());
                let prev_ok = ch != '_' || i == 0 || !c[i - 1].is_alphanumeric();
                if len_ok && next_ok && prev_ok && depth < MAX_NEST {
                    if let Some(j) = find_close(c, i + n, ch, n) {
                        flush(out, &mut buf, style, &link);
                        let mut s = style;
                        match (ch, n) {
                            ('~', _) => s.strike = true,
                            (_, 1) => s.italic = true,
                            (_, 2) => s.bold = true,
                            _ => {
                                s.bold = true;
                                s.italic = true;
                            }
                        }
                        inline(&c[i + n..j], s, link.clone(), out, depth + 1);
                        i = j + n;
                        continue;
                    }
                }
                buf.extend(std::iter::repeat(ch).take(n));
                i += n;
                continue;
            }
            '!' | '[' => {
                let img = ch == '!';
                let open = if img { i + 1 } else { i };
                if c.get(open) == Some(&'[') && depth < MAX_NEST {
                    if let Some((close, end, url)) = find_link(c, open) {
                        flush(out, &mut buf, style, &link);
                        if img {
                            // Images are never fetched or read from disk.
                            let alt: String = c[open + 1..close].iter().collect();
                            let text = if alt.is_empty() { "[image]".into() } else { format!("[image: {alt}]") };
                            out.push(Span { text, style: Style { italic: true, ..style }, link: link.clone() });
                        } else {
                            let target = link.clone().or_else(|| safe_url(&url));
                            inline(&c[open + 1..close], style, target, out, depth + 1);
                        }
                        i = end;
                        continue;
                    }
                }
            }
            '<' => {
                let end = c.len().min(i + MAX_URL);
                if let Some(off) = c[i + 1..end].iter().position(|&x| x == '>' || x.is_whitespace()) {
                    let j = i + 1 + off;
                    if c[j] == '>' {
                        let url: String = c[i + 1..j].iter().collect();
                        if let Some(target) = safe_url(&url) {
                            flush(out, &mut buf, style, &link);
                            out.push(Span { text: url, style, link: Some(target) });
                            i = j + 1;
                            continue;
                        }
                    }
                }
            }
            _ => {}
        }
        buf.push(ch);
        i += 1;
    }
    flush(out, &mut buf, style, &link);
}

// ───────────────────────────── fonts & encoding ─────────────────────────────

/// Index into the 8 built-in fonts: bit0 = bold, bit1 = italic, bit2 = monospace.
#[derive(Clone, Copy, PartialEq)]
struct Font(u8);

const FONT_NAMES: [&str; 8] = [
    "Helvetica",
    "Helvetica-Bold",
    "Helvetica-Oblique",
    "Helvetica-BoldOblique",
    "Courier",
    "Courier-Bold",
    "Courier-Oblique",
    "Courier-BoldOblique",
];

impl Font {
    fn of(s: Style, force_bold: bool) -> Font {
        Font((s.bold || force_bold) as u8 | (s.italic as u8) << 1 | (s.code as u8) << 2)
    }
}

// Adobe AFM advance widths (1/1000 em) for characters 32..=126.
#[rustfmt::skip]
const HELV: [u16; 95] = [
    278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,
    556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,
    1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,
    667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,
    333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,
    556,556,333,500,278,556,500,722,500,500,500,334,260,334,584,
];
#[rustfmt::skip]
const HELV_BOLD: [u16; 95] = [
    278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,
    556,556,556,556,556,556,556,556,556,556,333,333,584,584,584,611,
    975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,
    667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,
    333,556,611,556,611,556,333,611,611,278,278,556,278,889,611,611,
    611,611,389,556,333,611,556,778,556,556,500,389,280,389,584,
];

/// Advance width of a Windows-1252 byte in 1/1000 em.
fn glyph(font: Font, b: u8) -> f32 {
    if font.0 & 4 != 0 {
        return 600.0;
    }
    let bold = font.0 & 1 != 0;
    let table = if bold { &HELV_BOLD } else { &HELV };
    let base = |c: u8| table[(c - 32) as usize];
    let w = match b {
        32..=126 => base(b),
        0xA0 => 278,
        0xC0..=0xC5 => base(b'A'),
        0xC7 => base(b'C'),
        0xC8..=0xCB => base(b'E'),
        0xCC..=0xCF | 0xEC..=0xEF | 0xB7 => 278,
        0xD0 => 722,
        0xD1 => base(b'N'),
        0xD2..=0xD6 | 0xD8 => base(b'O'),
        0xD7 | 0xF7 => 584,
        0xD9..=0xDC => base(b'U'),
        0xDD => base(b'Y'),
        0xDE => 667,
        0xDF | 0xF8 => 611,
        0xE0..=0xE5 => base(b'a'),
        0xE6 => 889,
        0xE7 => base(b'c'),
        0xE8..=0xEB => base(b'e'),
        0xF0 | 0xF2..=0xF6 => base(b'o'),
        0xF1 => base(b'n'),
        0xF9..=0xFC => base(b'u'),
        0xFD | 0xFF => base(b'y'),
        0xFE => base(b'p'),
        0x85 | 0x89 | 0x8C | 0x97 | 0x99 | 0xC6 => 1000,
        0x91 | 0x92 => if bold { 278 } else { 222 },
        0x93 | 0x94 => if bold { 500 } else { 333 },
        0x95 => 350,
        0xA1 => 333,
        0xA9 | 0xAE => 737,
        0xB0 => 400,
        _ => 556,
    };
    w as f32
}

/// Unicode -> Windows-1252 (the encoding used for the PDF built-in fonts).
fn encode(text: &str, out: &mut Vec<u8>) {
    for ch in text.chars() {
        let c = ch as u32;
        let b = match c {
            0x0A => b'\n',
            0x09 => b' ',
            0x20..=0x7E | 0xA0..=0xFF => c as u8,
            0x20AC => 0x80,
            0x201A => 0x82,
            0x0192 => 0x83,
            0x201E => 0x84,
            0x2026 => 0x85,
            0x2020 => 0x86,
            0x2021 => 0x87,
            0x02C6 => 0x88,
            0x2030 => 0x89,
            0x0160 => 0x8A,
            0x2039 => 0x8B,
            0x0152 => 0x8C,
            0x017D => 0x8E,
            0x2018 => 0x91,
            0x2019 => 0x92,
            0x201C => 0x93,
            0x201D => 0x94,
            0x2022 => 0x95,
            0x2013 => 0x96,
            0x2014 => 0x97,
            0x02DC => 0x98,
            0x2122 => 0x99,
            0x0161 => 0x9A,
            0x203A => 0x9B,
            0x0153 => 0x9C,
            0x017E => 0x9E,
            0x0178 => 0x9F,
            0x2010 | 0x2011 | 0x2212 => b'-',
            0x2000..=0x200A | 0x202F => b' ',
            0x2192 => {
                out.extend_from_slice(b"->");
                continue;
            }
            0x2190 => {
                out.extend_from_slice(b"<-");
                continue;
            }
            0x200B..=0x200F | 0xFEFF | 0xFE0F => continue, // zero-width
            _ if ch.is_control() => continue,
            _ => b'?',
        };
        out.push(b);
    }
}

/// PDF literal string body: ASCII only, everything risky escaped.
fn pdf_str(bytes: &[u8], out: &mut String) {
    for &b in bytes {
        match b {
            b'(' | b')' | b'\\' => {
                out.push('\\');
                out.push(b as char);
            }
            32..=126 => out.push(b as char),
            _ => {
                let _ = write!(out, "\\{:03o}", b);
            }
        }
    }
}

/// Percent-encode anything that is not plain URL-safe ASCII.
fn uri_escape(url: &str) -> String {
    let mut s = String::with_capacity(url.len());
    for &b in url.as_bytes() {
        if b.is_ascii_graphic() && !matches!(b, b'(' | b')' | b'\\' | b'<' | b'>' | b'"') {
            s.push(b as char);
        } else {
            let _ = write!(s, "%{:02X}", b);
        }
    }
    s
}

// ───────────────────────────── line breaking ─────────────────────────────

#[derive(Clone)]
struct Piece {
    bytes: Vec<u8>,
    font: Font,
    size: f32,
    width: f32,
    link: Option<Rc<str>>,
    strike: bool,
    code: bool,
}

impl Piece {
    fn same(&self, o: &Piece) -> bool {
        self.font == o.font && self.size == o.size && self.strike == o.strike && self.code == o.code && self.link == o.link
    }
    fn push(&mut self, b: u8) {
        self.bytes.push(b);
        self.width += glyph(self.font, b) * self.size / 1000.0;
    }
}

type Line = Vec<Piece>;

fn line_width(l: &Line) -> f32 {
    l.iter().map(|p| p.width).sum()
}

struct Wrapper {
    max_w: f32,
    lines: Vec<Line>,
    line: Line,
    line_w: f32,
    word: Line,
    word_w: f32,
    space: bool,
}

impl Wrapper {
    fn add(&mut self, p: Piece) {
        self.line_w += p.width;
        match self.line.last_mut() {
            Some(last) if last.same(&p) => {
                last.bytes.extend_from_slice(&p.bytes);
                last.width += p.width;
            }
            _ => self.line.push(p),
        }
    }

    fn newline(&mut self) {
        self.lines.push(std::mem::take(&mut self.line));
        self.line_w = 0.0;
    }

    fn flush_word(&mut self) {
        if self.word.is_empty() {
            return;
        }
        let word = std::mem::take(&mut self.word);
        let ww = std::mem::replace(&mut self.word_w, 0.0);
        let first = &word[0];
        let space_w = if self.space && !self.line.is_empty() { glyph(first.font, b' ') * first.size / 1000.0 } else { 0.0 };
        self.space = false;
        if !self.line.is_empty() && self.line_w + space_w + ww > self.max_w {
            self.newline();
        } else if space_w > 0.0 {
            // The space keeps link/strike decoration only if both neighbours share it.
            let decorated = self.line.last().map_or(false, |l| l.same(first));
            let mut sp = Piece { bytes: Vec::new(), width: 0.0, ..first.clone() };
            if !decorated {
                sp.link = None;
                sp.strike = false;
                sp.code = false;
            }
            sp.push(b' ');
            self.add(sp);
        }
        if ww <= self.max_w {
            for p in word {
                self.add(p);
            }
        } else {
            // Unbreakable text wider than the line (e.g. a long URL): split by character.
            for p in word {
                for &b in &p.bytes {
                    let mut one = Piece { bytes: Vec::new(), width: 0.0, ..p.clone() };
                    one.push(b);
                    if !self.line.is_empty() && self.line_w + one.width > self.max_w {
                        self.newline();
                    }
                    self.add(one);
                }
            }
        }
    }
}

fn wrap(spans: &[Span], size: f32, bold: bool, max_w: f32) -> Vec<Line> {
    let mut w = Wrapper { max_w, lines: Vec::new(), line: Vec::new(), line_w: 0.0, word: Vec::new(), word_w: 0.0, space: false };
    let mut bytes = Vec::new();
    for s in spans {
        bytes.clear();
        encode(&s.text, &mut bytes);
        let proto = Piece {
            bytes: Vec::new(),
            font: Font::of(s.style, bold),
            size: if s.style.code { size * 0.9 } else { size },
            width: 0.0,
            link: s.link.clone(),
            strike: s.style.strike,
            code: s.style.code,
        };
        for &b in &bytes {
            match b {
                b' ' => {
                    w.flush_word();
                    w.space = true;
                }
                b'\n' => {
                    w.flush_word();
                    if !w.line.is_empty() {
                        w.newline();
                    }
                    w.space = false;
                }
                _ => {
                    if !w.word.last().map_or(false, |l| l.same(&proto)) {
                        w.word.push(proto.clone());
                    }
                    let last = w.word.last_mut().expect("just pushed");
                    let before = last.width;
                    last.push(b);
                    w.word_w += last.width - before;
                }
            }
        }
    }
    w.flush_word();
    if !w.line.is_empty() {
        w.newline();
    }
    w.lines
}

// ───────────────────────────── layout / rendering ─────────────────────────────

#[derive(Default)]
struct Page {
    content: String,
    links: Vec<([f32; 4], Rc<str>)>,
}

struct Doc {
    pages: Vec<Page>,
    pw: f32,
    ph: f32,
    margin: f32,
    base: f32,
    y: f32,
    left: f32,
    fresh: bool,            // nothing drawn yet at this position: suppress the next gap
    bars: Vec<(f32, f32)>,  // open blockquote bars: (x, top y on current page)
}

impl Doc {
    fn new(pw: f32, ph: f32, margin: f32, base: f32) -> Doc {
        Doc { pages: vec![Page::default()], pw, ph, margin, base, y: ph - margin, left: margin, fresh: true, bars: Vec::new() }
    }

    fn content(&mut self) -> &mut String {
        &mut self.pages.last_mut().expect("at least one page").content
    }

    fn rect(&mut self, x: f32, y: f32, w: f32, h: f32, gray: f32) {
        let _ = write!(self.content(), "{gray:.2} g {x:.2} {y:.2} {w:.2} {h:.2} re f 0 g\n");
    }

    fn flush_bars(&mut self) {
        let y = self.y;
        for (x, top) in self.bars.clone() {
            if top > y {
                self.rect(x, y, 2.5, top - y, 0.72);
            }
        }
    }

    fn new_page(&mut self) {
        self.flush_bars();
        self.pages.push(Page::default());
        self.y = self.ph - self.margin;
        self.fresh = true;
        for b in &mut self.bars {
            b.1 = self.y;
        }
    }

    fn ensure(&mut self, h: f32) {
        if self.y - h < self.margin && self.y < self.ph - self.margin {
            self.new_page();
        }
    }

    fn gap(&mut self, h: f32) {
        if !self.fresh {
            self.y -= h;
        }
    }

    /// Draw one line of text at the cursor and move the cursor down by `lh`.
    fn put_line(&mut self, mut x: f32, line: &[Piece], lh: f32) {
        self.ensure(lh);
        let by = self.y - lh * 0.74; // baseline
        for p in line {
            if p.code {
                self.rect(x - 1.0, by - p.size * 0.28, p.width + 2.0, p.size * 1.22, 0.93);
            }
            let mut s = String::new();
            if p.link.is_some() {
                s.push_str("0.05 0.3 0.75 rg ");
            }
            let _ = write!(s, "BT /F{} {:.2} Tf {:.2} {:.2} Td (", p.font.0 + 1, p.size, x, by);
            pdf_str(&p.bytes, &mut s);
            s.push_str(") Tj ET\n");
            if p.link.is_some() {
                let _ = write!(s, "{:.2} {:.2} {:.2} 0.5 re f 0 g\n", x, by - 1.5, p.width);
            }
            if p.strike {
                let _ = write!(s, "{:.2} {:.2} {:.2} 0.6 re f\n", x, by + p.size * 0.27, p.width);
            }
            self.content().push_str(&s);
            if let Some(url) = &p.link {
                let r = [x, by - p.size * 0.25, x + p.width, by + p.size * 0.8];
                self.pages.last_mut().expect("page").links.push((r, url.clone()));
            }
            x += p.width;
        }
        self.y -= lh;
        self.fresh = false;
    }

    fn block(&mut self, b: &Block) {
        let right = self.pw - self.margin;
        let base = self.base;
        match b {
            Block::Heading(lv, spans) => {
                let size = base * [2.0, 1.6, 1.3, 1.15, 1.0, 0.9][(*lv).clamp(1, 6) - 1];
                let lh = size * 1.3;
                self.gap(size * 0.9);
                let lines = wrap(spans, size, true, right - self.left);
                self.ensure(lh * lines.len() as f32 + base * 3.0); // keep with following text
                for l in &lines {
                    self.put_line(self.left, l, lh);
                }
                if *lv == 1 {
                    self.y -= 3.0;
                    self.rect(self.left, self.y, right - self.left, 0.6, 0.7);
                    self.y -= 2.0;
                }
            }
            Block::Para(spans) => {
                self.gap(base * 0.6);
                for l in &wrap(spans, base, false, right - self.left) {
                    self.put_line(self.left, l, base * 1.45);
                }
            }
            Block::Item { depth, marker, spans } => {
                self.gap(base * 0.25);
                let lh = base * 1.45;
                let x = self.left + *depth as f32 * 18.0;
                let mark = wrap(&[Span { text: marker.clone(), style: Style::default(), link: None }], base, false, f32::MAX);
                let mw = mark.first().map_or(0.0, line_width);
                let tx = x + (mw + 5.0).max(14.0);
                self.ensure(lh);
                let y0 = self.y;
                if let Some(m) = mark.first() {
                    self.put_line(x, m, lh);
                }
                let lines = wrap(spans, base, false, (right - tx).max(40.0));
                if !lines.is_empty() {
                    self.y = y0;
                }
                for l in &lines {
                    self.put_line(tx, l, lh);
                }
            }
            Block::Code { lines, depth } => {
                self.gap(base * 0.7);
                let size = base * 0.85;
                let (lh, pad) = (size * 1.35, 6.0);
                let x = self.left + *depth as f32 * 18.0;
                let w = right - x;
                let cols = (((w - 2.0 * pad) / (size * 0.6)) as usize).max(1);
                let font = Font(4);
                self.ensure(lh + pad);
                self.rect(x, self.y - pad, w, pad, 0.95);
                self.y -= pad;
                let mut bytes = Vec::new();
                for l in lines {
                    bytes.clear();
                    encode(l, &mut bytes);
                    let mut chunks: Vec<&[u8]> = bytes.chunks(cols).collect();
                    if chunks.is_empty() {
                        chunks.push(&[]);
                    }
                    for chunk in chunks {
                        self.ensure(lh);
                        self.rect(x, self.y - lh, w, lh, 0.95);
                        let piece = Piece { bytes: chunk.to_vec(), font, size, width: 0.0, link: None, strike: false, code: false };
                        self.put_line(x + pad, &[piece], lh);
                    }
                }
                self.rect(x, self.y - pad, w, pad, 0.95);
                self.y -= pad;
                self.fresh = false;
            }
            Block::Quote(children) => {
                self.gap(base * 0.6);
                self.bars.push((self.left + 2.0, self.y));
                self.left += 14.0;
                self.fresh = true;
                for c in children {
                    self.block(c);
                }
                self.left -= 14.0;
                self.flush_bar_top();
                self.fresh = false;
            }
            Block::Rule => {
                self.gap(base * 0.9);
                self.ensure(4.0);
                self.rect(self.left, self.y, right - self.left, 0.7, 0.6);
                self.y -= base * 0.3;
                self.fresh = false;
            }
            Block::Table { head, rows, align } => self.table(head, rows, align),
        }
    }

    /// Close the innermost blockquote bar.
    fn flush_bar_top(&mut self) {
        if let Some((x, top)) = self.bars.pop() {
            if top > self.y {
                self.rect(x, self.y, 2.5, top - self.y, 0.72);
            }
        }
    }

    fn table(&mut self, head: &[Cell], rows: &[Vec<Cell>], align: &[Align]) {
        let n = head.len();
        if n == 0 {
            return;
        }
        let size = self.base * 0.92;
        let (lh, pad, vpad) = (size * 1.4, 5.0, 3.0);
        let avail = self.pw - self.margin - self.left;
        self.gap(self.base * 0.7);

        // Natural column widths, shrunk proportionally if the table is too wide.
        let all: Vec<(&[Cell], bool)> = std::iter::once((head, true)).chain(rows.iter().map(|r| (r.as_slice(), false))).collect();
        let mut widths = vec![0f32; n];
        for (row, bold) in &all {
            for (i, cell) in row.iter().enumerate().take(n) {
                for l in wrap(cell, size, *bold, f32::MAX) {
                    widths[i] = widths[i].max(line_width(&l));
                }
            }
        }
        for w in &mut widths {
            *w += 2.0 * pad + 0.5;
        }
        if widths.iter().sum::<f32>() > avail {
            // Narrow columns keep their natural width; only the wide ones share what is left.
            let mut fixed = vec![false; n];
            loop {
                let open = fixed.iter().filter(|f| !**f).count();
                let used: f32 = (0..n).filter(|&i| fixed[i]).map(|i| widths[i]).sum();
                let fair = (avail - used) / open.max(1) as f32;
                let newly: Vec<usize> = (0..n).filter(|&i| !fixed[i] && widths[i] <= fair).collect();
                if newly.is_empty() || newly.len() == open {
                    let wide: f32 = (0..n).filter(|&i| !fixed[i]).map(|i| widths[i]).sum();
                    if newly.is_empty() {
                        for i in (0..n).filter(|&i| !fixed[i]) {
                            widths[i] *= (avail - used) / wide;
                        }
                    }
                    break;
                }
                for i in newly {
                    fixed[i] = true;
                }
            }
        }

        for (row, bold) in &all {
            let cells: Vec<Vec<Line>> = (0..n)
                .map(|i| row.get(i).map_or_else(Vec::new, |c| wrap(c, size, *bold, (widths[i] - 2.0 * pad).max(1.0))))
                .collect();
            let nlines = cells.iter().map(|c| c.len()).max().unwrap_or(0).max(1);
            let h = nlines as f32 * lh + 2.0 * vpad;
            self.ensure(h);
            let top = self.y;
            let mut x = self.left;
            for (i, cell) in cells.iter().enumerate() {
                if *bold {
                    self.rect(x, top - h, widths[i], h, 0.92);
                }
                let _ = write!(self.content(), "0.6 G 0.5 w {:.2} {:.2} {:.2} {:.2} re S\n", x, top - h, widths[i], h);
                self.y = top - vpad;
                for l in cell {
                    let free = (widths[i] - 2.0 * pad - line_width(l)).max(0.0);
                    let off = match align.get(i) {
                        Some(Align::Center) => free / 2.0,
                        Some(Align::Right) => free,
                        _ => 0.0,
                    };
                    self.put_line(x + pad + off, l, lh);
                }
                x += widths[i];
            }
            self.y = top - h;
            self.fresh = false;
        }
    }

    /// Serialise to PDF 1.4 bytes.
    fn finish(mut self, title: &str) -> Vec<u8> {
        // Page-number footers.
        let total = self.pages.len();
        let (pw, margin) = (self.pw, self.margin);
        for (i, p) in self.pages.iter_mut().enumerate() {
            let label = format!("{} / {}", i + 1, total);
            let w = label.bytes().map(|b| glyph(Font(0), b)).sum::<f32>() * 8.0 / 1000.0;
            let _ = write!(p.content, "0.45 g BT /F1 8 Tf {:.2} {:.2} Td ({}) Tj ET 0 g\n", (pw - w) / 2.0, margin * 0.5, label);
        }

        let mut out: Vec<u8> = Vec::new();
        let mut offsets: Vec<usize> = Vec::new();
        out.extend_from_slice(b"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");
        let mut obj = |out: &mut Vec<u8>, body: &str| {
            offsets.push(out.len());
            let _ = write!(out, "{} 0 obj\n{}\nendobj\n", offsets.len(), body);
        };

        const FIRST_PAGE: usize = 12; // 1 catalog, 2 page tree, 3 info, 4..=11 fonts
        obj(&mut out, "<< /Type /Catalog /Pages 2 0 R >>");

        let kids: String = (0..total).map(|i| format!("{} 0 R ", FIRST_PAGE + 2 * i)).collect();
        let fonts: String = (0..8).map(|i| format!("/F{} {} 0 R ", i + 1, 4 + i)).collect();
        obj(
            &mut out,
            &format!(
                "<< /Type /Pages /Count {total} /Kids [ {kids}] /MediaBox [0 0 {:.2} {:.2}] /Resources << /Font << {fonts}>> >> >>",
                self.pw, self.ph
            ),
        );

        // Title as UTF-16BE hex string: no escaping pitfalls, full Unicode.
        let mut hex = String::from("FEFF");
        for u in title.encode_utf16() {
            let _ = write!(hex, "{:04X}", u);
        }
        obj(&mut out, &format!("<< /Title <{hex}> /Producer (md2pdf) >>"));

        for name in FONT_NAMES {
            obj(&mut out, &format!("<< /Type /Font /Subtype /Type1 /BaseFont /{name} /Encoding /WinAnsiEncoding >>"));
        }

        for (i, p) in self.pages.iter().enumerate() {
            let mut annots = String::new();
            for (r, url) in &p.links {
                let _ = write!(
                    annots,
                    "<< /Type /Annot /Subtype /Link /Rect [{:.2} {:.2} {:.2} {:.2}] /Border [0 0 0] /A << /S /URI /URI ({}) >> >> ",
                    r[0], r[1], r[2], r[3], uri_escape(url)
                );
            }
            obj(&mut out, &format!("<< /Type /Page /Parent 2 0 R /Contents {} 0 R /Annots [ {annots}] >>", FIRST_PAGE + 2 * i + 1));
            obj(&mut out, &format!("<< /Length {} >>\nstream\n{}endstream", p.content.len(), p.content));
        }

        let xref = out.len();
        let _ = write!(out, "xref\n0 {}\n0000000000 65535 f \n", offsets.len() + 1);
        for o in &offsets {
            let _ = write!(out, "{:010} 00000 n \n", o);
        }
        let _ = write!(out, "trailer\n<< /Size {} /Root 1 0 R /Info 3 0 R >>\nstartxref\n{}\n%%EOF\n", offsets.len() + 1, xref);
        out
    }
}

// ───────────────────────────── command line ─────────────────────────────

const USAGE: &str = "usage: md2pdf INPUT.md [-o OUTPUT.pdf] [--paper a4|letter] [--font-size PT] [--margin PT]
       md2pdf - -o OUTPUT.pdf     (read Markdown from stdin)";

struct Opts {
    input: String,
    output: Option<PathBuf>,
    paper: (f32, f32),
    font_size: f32,
    margin: f32,
}

fn parse_args() -> Result<Opts, String> {
    let mut o = Opts { input: String::new(), output: None, paper: (595.28, 841.89), font_size: 11.0, margin: 60.0 };
    let mut args = env::args().skip(1);
    let mut have_input = false;
    while let Some(a) = args.next() {
        let mut value = |name: &str| args.next().ok_or(format!("{name} needs a value"));
        match a.as_str() {
            "-h" | "--help" => return Err(USAGE.to_string()),
            "-o" | "--output" => o.output = Some(PathBuf::from(value("-o")?)),
            "--paper" => {
                o.paper = match value("--paper")?.to_ascii_lowercase().as_str() {
                    "a4" => (595.28, 841.89),
                    "letter" => (612.0, 792.0),
                    other => return Err(format!("unknown paper size '{other}' (use a4 or letter)")),
                }
            }
            "--font-size" => {
                o.font_size = value("--font-size")?.parse().ok().filter(|v| (6.0..=24.0).contains(v)).ok_or("--font-size must be 6..24")?
            }
            "--margin" => {
                o.margin = value("--margin")?.parse().ok().filter(|v| (20.0..=150.0).contains(v)).ok_or("--margin must be 20..150")?
            }
            s if s.starts_with('-') && s != "-" => return Err(format!("unknown option '{s}'\n{USAGE}")),
            _ if !have_input => {
                o.input = a;
                have_input = true;
            }
            _ => return Err(format!("unexpected argument '{a}'\n{USAGE}")),
        }
    }
    if !have_input {
        return Err(USAGE.to_string());
    }
    Ok(o)
}

fn read_limited(r: impl Read) -> io::Result<Vec<u8>> {
    let mut buf = Vec::new();
    r.take(MAX_INPUT + 1).read_to_end(&mut buf)?;
    if buf.len() as u64 > MAX_INPUT {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "input larger than 64 MiB"));
    }
    Ok(buf)
}

fn plain(spans: &[Span]) -> String {
    spans.iter().map(|s| s.text.as_str()).collect()
}

fn run() -> Result<(), String> {
    let o = parse_args()?;
    let (raw, output) = if o.input == "-" {
        let out = o.output.clone().ok_or("reading from stdin requires -o OUTPUT.pdf")?;
        (read_limited(io::stdin().lock()).map_err(|e| format!("stdin: {e}"))?, out)
    } else {
        let path = Path::new(&o.input);
        let f = File::open(path).map_err(|e| format!("{}: {e}", o.input))?;
        let out = o.output.clone().unwrap_or_else(|| path.with_extension("pdf"));
        if fs::canonicalize(&out).ok().is_some_and(|c| fs::canonicalize(path).ok() == Some(c)) {
            return Err("output would overwrite the input file".into());
        }
        (read_limited(f).map_err(|e| format!("{}: {e}", o.input))?, out)
    };

    let text = String::from_utf8_lossy(&raw);
    let text = text.strip_prefix('\u{FEFF}').unwrap_or(&text);
    let lines: Vec<&str> = text.lines().collect();
    let blocks = parse_blocks(&lines, 0);

    let title = blocks
        .iter()
        .find_map(|b| match b {
            Block::Heading(1, s) => Some(plain(s)),
            _ => None,
        })
        .unwrap_or_else(|| output.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default());

    let mut doc = Doc::new(o.paper.0, o.paper.1, o.margin, o.font_size);
    for b in &blocks {
        doc.block(b);
    }
    let pages = doc.pages.len();
    let pdf = doc.finish(&title);

    let mut f = File::create(&output).map_err(|e| format!("{}: {e}", output.display()))?;
    f.write_all(&pdf).and_then(|_| f.flush()).map_err(|e| format!("{}: {e}", output.display()))?;
    eprintln!("wrote {} ({} page{}, {} bytes)", output.display(), pages, if pages == 1 { "" } else { "s" }, pdf.len());
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::from(1)
        }
    }
}
