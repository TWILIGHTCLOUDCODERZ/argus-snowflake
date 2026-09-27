#!/usr/bin/env python3
"""
ARGUS · render the synthetic regulation + filing corpora to PDF  ·  Created by TCC

Regulators publish circulars as PDFs, so the document pipeline (Cortex
AI_PARSE_DOCUMENT -> extraction -> Cortex Search) runs on real PDFs, not Markdown.

  policy_corpus/*.md   -> policy_corpus/pdf/*.pdf
  filings_corpus/*.md  -> filings_corpus/pdf/*.pdf

Needs fpdf2 (in the project .venv) and Windows' Arial TTF fonts (Unicode-safe).
"""
from __future__ import annotations
import glob, os, re
from fpdf import FPDF
from fpdf.enums import XPos, YPos

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
FONTS = r"C:\Windows\Fonts"
NL = dict(new_x=XPos.LMARGIN, new_y=YPos.NEXT)   # after each block, back to the left margin

def blocks(md: str):
    """Yield (kind, text). Hard-wrapped lines of one paragraph are joined back together."""
    para: list[str] = []
    def flush():
        if para:
            yield ("p", " ".join(para)); para.clear()
    for raw in md.splitlines():
        line = raw.strip()
        if not line:
            yield from flush(); yield ("gap", ""); continue
        if line.startswith("# "):
            yield from flush(); yield ("h1", line[2:])
        elif line.startswith("## "):
            yield from flush(); yield ("h2", line[3:])
        elif line.startswith("- "):
            yield from flush(); yield ("li", line[2:])
        elif line.startswith("**") or (line.startswith("*") and line.endswith("*")):
            yield from flush(); yield ("meta", line)       # one metadata line each
        else:
            para.append(line)
    yield from flush()

def md_to_pdf(src: str, dst: str) -> None:
    pdf = FPDF(format="A4")
    pdf.set_margins(20, 18, 20)
    pdf.add_font("Arial", "", os.path.join(FONTS, "arial.ttf"))
    pdf.add_font("Arial", "B", os.path.join(FONTS, "arialbd.ttf"))
    pdf.add_font("Arial", "I", os.path.join(FONTS, "ariali.ttf"))
    pdf.set_auto_page_break(True, margin=18)
    pdf.add_page()
    w = pdf.epw

    for kind, text in blocks(open(src, encoding="utf-8").read()):
        if kind == "gap":
            pdf.ln(2)
        elif kind == "h1":
            pdf.set_font("Arial", "B", 15); pdf.multi_cell(w, 7, text, **NL); pdf.ln(2)
        elif kind == "h2":
            pdf.ln(2); pdf.set_font("Arial", "B", 11.5); pdf.multi_cell(w, 6, text, **NL); pdf.ln(1)
        elif kind == "meta" and not text.startswith("**"):
            pdf.set_font("Arial", "I", 9); pdf.multi_cell(w, 5, text.strip("*"), **NL)
        elif kind == "li":
            pdf.set_font("Arial", "", 10.5)
            pdf.multi_cell(w, 5.5, "\u2022  " + text, markdown=True, **NL)
        else:   # paragraph or **Label:** value line — fpdf2 renders **bold** inline
            pdf.set_font("Arial", "", 10.5)
            pdf.multi_cell(w, 5.5, text, markdown=True, **NL)
    pdf.output(dst)

count = 0
for folder in ("policy_corpus", "filings_corpus"):
    out_dir = os.path.join(ROOT, folder, "pdf")
    os.makedirs(out_dir, exist_ok=True)
    for src in sorted(glob.glob(os.path.join(ROOT, folder, "*.md"))):
        dst = os.path.join(out_dir, os.path.splitext(os.path.basename(src))[0] + ".pdf")
        md_to_pdf(src, dst)
        count += 1
        print(f"  {os.path.relpath(dst, ROOT)}  ({os.path.getsize(dst):,} bytes)")
print(f"Rendered {count} PDFs.")
