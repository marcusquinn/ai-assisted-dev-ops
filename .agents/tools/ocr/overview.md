---
description: OCR tools overview and selection guide for text extraction from images, screenshots, and documents
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

<!-- AI-CONTEXT-START -->

| Input | Tool | Strengths | Limits |
|-------|------|-----------|--------|
| Screenshot / photo / sign | **PaddleOCR** (Baidu, 71k, Apache-2.0) | Best scene-text accuracy; bounding boxes; PP-StructureV3 tables; PaddleOCR-VL (0.9B); MCP server (v3.1.0+); 100+ languages | ~500MB dep; not for doc-to-markdown → use MinerU; invoices → Docling; PDF forms → LibPDF |
| Mirrored / rotated PDF scan | **Document forensics** (`document-creation-helper.sh forensics`) | Page-level text-layer audit; conservative flip/rotation scoring; cited sidecar; versioned manifest; optional searchable readable copy; originals remain immutable | Poppler + jq + Python 3 required; transforms need ImageMagick; readable repaired PDFs need Tesseract; weak/sparse evidence remains `uncertain` |
| Complex PDF (tables, columns, formulas) | **MinerU** (OpenDataLab, 53k, AGPL-3.0) | Layout-aware; multi-column, tables, formulas, LaTeX; strips headers/footers; 109 languages; JSON reading order; pipeline/hybrid/VLM backends | PDF-only; AGPL copyleft; screenshots → PaddleOCR; schema extraction → Docling; simple PDFs → Pandoc |
| Invoice / receipt / form | **Docling + ExtractThinker** (IBM, 52.7k, MIT) | Schema-mapped Pydantic output; PDF/DOCX/PPTX/XLSX/HTML/images; PII redaction (Presidio); local/edge/cloud privacy; UK VAT + QuickFile; MCP server | Requires LLM; three-component setup; slower than pure OCR; screenshots → PaddleOCR/GLM-OCR |
| Any image (quick, local) | **GLM-OCR** (THUDM/Ollama, MIT) | Zero-config (`ollama pull glm-ocr`); fully local; Peekaboo screen capture integration | No bounding boxes or structured JSON; weaker scene text; ~2GB model → PaddleOCR for accuracy |
| PDF text + positions | **LibPDF** (Commercial) | Coordinate-positioned text; form filling; digital signatures (PAdES); handles malformed PDFs; ~5MB, no Python/GPU | PDF-only; cannot OCR scanned/image PDFs → MinerU; structured extraction → Docling |
| Simple text PDF | **Pandoc** | Fastest text-only conversion | No layout awareness; no OCR → MinerU for complex layouts |
| Document understanding (VLM) | **PaddleOCR-VL** | Local document/structured understanding | Not plain OCR → PaddleOCR for text extraction |

## Subagents

| File | Purpose |
|------|---------|
| `tools/ocr/paddleocr.md` | PaddleOCR — scene text OCR, MCP server, PP-OCRv5 and VL models |
| `tools/ocr/glm-ocr.md` | GLM-OCR — local OCR via Ollama |
| `tools/ocr/ocr-research.md` | OCR research findings and pipeline design |
| `tools/conversion/mineru.md` | MinerU — PDF to markdown/JSON |
| `tools/document/document-extraction.md` | Docling + ExtractThinker — structured extraction |
| `tools/pdf/overview.md` | LibPDF — PDF manipulation and text extraction |

## Common Workflows

```bash
# Screenshot to text
paddleocr-helper.sh ocr screenshot.png                    # best accuracy, bounding boxes
ollama run glm-ocr "Extract all text" --images screenshot.png  # simplest, Ollama required

# PDF to LLM-ready markdown
mineru -p document.pdf -o output_dir                      # complex layouts, tables, formulas
pandoc document.pdf -o document.md                        # simple text PDFs, fastest

# Audit damaged scans; add --write-readable for a separate searchable PDF
document-creation-helper.sh forensics scans.pdf --output ./audit

# Invoice to structured JSON
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local

# Batch image OCR
for img in ./images/*.png; do paddleocr-helper.sh ocr "$img"; done

# Pipelines: image → PaddleOCR → raw text or ExtractThinker → structured JSON
#            damaged PDF → local forensic candidates → sidecar + manifest + optional readable PDF
#            PDF → MinerU → markdown → LLM
#            PDF → Docling → ExtractThinker → structured JSON → QuickFile
# PaddleOCR and Docling MCP servers plug into Claude Desktop / the agent framework.
```

<!-- AI-CONTEXT-END -->
