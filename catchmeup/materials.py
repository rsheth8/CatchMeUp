"""Local source documents, kept separate from spoken/audio evidence."""
from __future__ import annotations

import hashlib
import json
import shutil
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

from . import brains
from .sync import atomic_json_write

MAX_BYTES = 50 * 1024 * 1024
MAX_TEXT = 2_000_000
MAX_PAGES = 300
SUPPORTED = {".pdf", ".pptx", ".txt", ".md"}


def root(slug: str) -> Path:
    if not brains.SLUG_RE.fullmatch(slug):
        raise ValueError("Use a brain's slug, as shown by ./catchup brain list.")
    brains.load_brain(slug)
    return brains.brain_dir(slug) / "materials"


def extract(path: Path) -> tuple[list[dict], list[str]]:
    """Text extraction only. Never pretend image-only pages have been understood."""
    suffix = path.suffix.lower()
    if suffix not in SUPPORTED:
        raise ValueError("Supported materials: PDF, PPTX, TXT, MD. Export Keynote/PowerPoint to PDF or PPTX.")
    if path.stat().st_size > MAX_BYTES:
        raise ValueError("Material exceeds the 50 MB limit; split it into smaller documents.")
    pages, warnings = [], []
    if suffix == ".pdf":
        try:
            from pypdf import PdfReader
        except ImportError as exc:
            raise ValueError("PDF support needs an update: run ./catchup setup.") from exc
        from pypdf.errors import PdfReadError
        try:
            reader = PdfReader(path)
        except PdfReadError as exc:
            raise ValueError("This PDF could not be read. Re-export it and try again.") from exc
        if reader.is_encrypted:
            raise ValueError("This PDF is encrypted. Import an unlocked copy you are authorized to use.")
        if len(reader.pages) > MAX_PAGES:
            raise ValueError("PDF exceeds 300 pages; split it before importing.")
        for i, page in enumerate(reader.pages, 1):
            pages.append({"number": i, "label": f"page {i}", "text": page.extract_text() or ""})
        warnings.append("Text extraction only: diagrams, handwriting, and image-only content are not interpreted.")
    elif suffix == ".pptx":
        with zipfile.ZipFile(path) as archive:
            if sum(x.file_size for x in archive.infolist()) > MAX_BYTES * 4:
                raise ValueError("Expanded presentation is too large; split it before importing.")
            # Follow presentation relationships: filename order need not match slide order.
            relns = "http://schemas.openxmlformats.org/package/2006/relationships"
            officens = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
            pns = "http://schemas.openxmlformats.org/presentationml/2006/main"
            ans = "http://schemas.openxmlformats.org/drawingml/2006/main"
            rels = ET.fromstring(archive.read("ppt/_rels/presentation.xml.rels"))
            targets = {r.attrib["Id"]: r.attrib["Target"] for r in rels.findall(f"{{{relns}}}Relationship")
                       if r.attrib.get("TargetMode") != "External"}
            presentation = ET.fromstring(archive.read("ppt/presentation.xml"))
            slides = presentation.findall(f"{{{pns}}}sldIdLst/{{{pns}}}sldId")
            if len(slides) > MAX_PAGES:
                raise ValueError("Presentation exceeds 300 slides; split it before importing.")
            for i, slide in enumerate(slides, 1):
                target = targets[slide.attrib[f"{{{officens}}}id"]]
                name = target.lstrip("/") if target.startswith("/") else "ppt/" + target
                node = ET.fromstring(archive.read(name))
                paragraphs = ["".join(p.itertext()) for p in node.findall(f".//{{{ans}}}t")]
                pages.append({"number": i, "label": f"slide {i}", "text": "\n".join(paragraphs)})
        warnings.append("Slide text only: images, charts, animations, and speaker notes are not interpreted.")
    else:
        text = path.read_text(encoding="utf-8-sig")
        lines = text.splitlines()
        for i in range(0, len(lines), 40):
            pages.append({"number": i // 40 + 1, "label": f"lines {i + 1}–{min(i + 40, len(lines))}",
                          "text": "\n".join(lines[i:i + 40])})
    if sum(len(p["text"]) for p in pages) > MAX_TEXT:
        raise ValueError("Extracted text is too large; split the material before importing.")
    empty = sum(not p["text"].strip() for p in pages)
    if empty:
        warnings.append(f"{empty} page(s)/slide(s) have no readable text; OCR or a text export is needed.")
    if not any(p["text"].strip() for p in pages):
        raise ValueError("No readable text found. Use OCR or export a text-based copy before importing.")
    return pages, warnings


def list_materials(slug: str) -> list[dict]:
    return [json.loads(p.read_text()) for p in sorted(root(slug).glob("*/material.json"))]


def add(slug: str, path: Path, recap: str | None = None) -> tuple[dict, bool]:
    folder = root(slug)
    path = path.expanduser().resolve(strict=True)
    if not path.is_file():
        raise ValueError("Choose a document file, not a directory.")
    if path.stat().st_size > MAX_BYTES:
        raise ValueError("Material exceeds the 50 MB limit.")
    linked = None
    if recap:
        candidates = [r for r in brains.iter_brain_records(slug)
                      if recap.lower() in str(r.get("title", "")).lower()
                      or Path(r["_dir"]).name == recap]
        if len(candidates) != 1:
            raise ValueError("--recap must match exactly one recap title or folder ID. Use ./catchup library.")
        linked = {"id": Path(candidates[0]["_dir"]).name, "title": candidates[0]["title"]}
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    destination = folder / digest
    index = destination / "material.json"
    if index.exists():
        material = json.loads(index.read_text())
        if linked and linked not in material["recaps"]:
            material["recaps"].append(linked)
            atomic_json_write(index, material)
        return material, False
    pages, warnings = extract(path)
    material = {"version": 1, "id": digest, "name": path.name, "pages": pages,
                "warnings": warnings, "recaps": [linked] if linked else [],
                "addedAt": datetime.now(timezone.utc).isoformat()}
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, destination / ("original" + path.suffix.lower()))
    atomic_json_write(index, material)
    return material, True


def records(slug: str) -> list[dict]:
    """Retrieval-only records: never turn documents into recordings or audio clips."""
    mode = brains.load_brain(slug).get("kind", "lecture")
    result = []
    for material in list_materials(slug):
        chunks = []
        linked = ", ".join(r["title"] for r in material.get("recaps", []))
        for page in material["pages"]:
            text = page["text"]
            for i in range(0, len(text), 1400):
                piece = text[i:i + 1600]
                if piece.strip():
                    label = f"Material {material['name']} [{material['id'][:8]}] · {page['label']} · excerpt {i // 1400 + 1}"
                    if linked:
                        label += f" · attached to {linked}"
                    chunks.append((label, piece))
        result.append({"title": material["name"], "mode": mode, "brain": slug,
                       "_material_chunks": chunks})
    return result
