#!/usr/bin/env python3
"""Merge multiple PDF files into one output PDF.

Usage:
  python merge_pdf.py -o output.pdf -i input1.pdf input2.pdf [input3.pdf ...]
  python merge_pdf.py -h
"""

from __future__ import annotations

import argparse
from pathlib import Path

from pypdf import PdfWriter


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Merge multiple PDF files into one output PDF.",
        add_help=True,
    )
    parser.add_argument("-o", "--output", required=True, help="Output PDF file path")
    parser.add_argument("-i", "--input", nargs="+", required=True, help="Input PDF file paths")
    parser.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Overwrite output file if it already exists",
    )
    args = parser.parse_args()

    output_path = Path(args.output)
    input_paths = [Path(arg) for arg in args.input]

    missing = [path for path in input_paths if not path.is_file()]
    if missing:
        print("Missing input file(s):")
        for path in missing:
            print(f"- {path}")
        return 1

    if output_path.exists() and not args.force:
        print(f"Output file already exists: {output_path}")
        print("Use --force to overwrite.")
        return 1

    writer = PdfWriter()
    for path in input_paths:
        writer.append(str(path))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as output_file:
        writer.write(output_file)

    print(f"Merged {len(input_paths)} files into {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
