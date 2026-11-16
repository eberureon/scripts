# md2pdf

A small, fast Markdown-to-PDF converter written in Rust. One source file, standard library only.

## Build

Requires a Rust toolchain (`rustc`). No Cargo project or crates needed.

```sh
rustc -O md2pdf.rs
```

## Usage

```sh
md2pdf INPUT.md [-o OUTPUT.pdf] [--paper a4|letter] [--font-size PT] [--margin PT]
```

```sh
md2pdf notes.md                      # writes notes.pdf
md2pdf notes.md -o out.pdf --paper letter --font-size 12 --margin 72
cat notes.md | md2pdf - -o out.pdf   # read from stdin
```

| Option        | Default               | Notes                 |
|---------------|-----------------------|-----------------------|
| `-o`          | input name + `.pdf`   | Required with stdin   |
| `--paper`     | `a4`                  | `a4` or `letter`      |
| `--font-size` | `11`                  | 6 to 24 points        |
| `--margin`    | `60`                  | 20 to 150 points      |

## Supported Markdown

- Headings (`#` style and underlined style)
- Paragraphs and hard line breaks
- **Bold**, *italic*, ~~strikethrough~~, `inline code`
- Fenced code blocks
- Nested bullet and numbered lists
- Blockquotes, including nested ones
- Tables with column alignment
- Horizontal rules
- Links and autolinks (clickable in the PDF)

Pages are numbered, and the first top-level heading becomes the PDF title.

## Security

- No third-party dependencies, so there is no supply chain to audit.
- `#![forbid(unsafe_code)]`; no subprocesses and no network access.
- Only `http`, `https` and `mailto` links become clickable. Other schemes
  (`javascript:`, `file:`, ...) are rendered as plain text.
- Raw HTML is printed literally, never interpreted.
- Images are never fetched or read from disk; the alt text is shown instead.
- Input is capped at 64 MiB, and nesting depth and delimiter lookahead are
  bounded, so hostile input cannot cause runaway recursion or parse time.
- All text written into the PDF is escaped.

## Limitations

- Text uses the PDF built-in fonts (Helvetica and Courier), so only
  Latin-1 / Windows-1252 characters render. Others (CJK, emoji, ...) appear as `?`.
- Covers the common Markdown subset, not full CommonMark: no reference-style
  links, footnotes, or multi-paragraph list items.
- Page content is not compressed, so files are larger than they could be.
- Images are not embedded.
