import hashlib
import io
import os
import sqlite3
import time
from pathlib import Path
from typing import Any

import fitz
import numpy as np
from fastapi import Depends, FastAPI, Header, HTTPException, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sentence_transformers import SentenceTransformer


INDEX_DIR = Path(os.getenv("IMAGE_RAG_INDEX_DIR", "/data/index"))
DB_PATH = INDEX_DIR / "image_rag.sqlite3"
THUMB_DIR = INDEX_DIR / "thumbs"
API_KEY = os.getenv("IMAGE_RAG_API_KEY", "")
MODEL_NAME = os.getenv("IMAGE_RAG_CLIP_MODEL", "clip-ViT-B-32")
DEVICE_SETTING = os.getenv("IMAGE_RAG_DEVICE", "auto")
RENDER_DPI = int(os.getenv("IMAGE_RAG_RENDER_DPI", "144"))
MAX_PAGES_PER_PDF = int(os.getenv("IMAGE_RAG_MAX_PAGES_PER_PDF", "80"))
ROOTS = [Path(p) for p in os.getenv("IMAGE_RAG_ROOTS", "/data/papers,/data/openwebui").split(",") if p.strip()]

app = FastAPI(
    title="Scientific Assistant Visual Search",
    version="0.1.0",
    description="CLIP visual search over PDF page renders and extracted PDF images.",
)

_model: SentenceTransformer | None = None


class IndexRequest(BaseModel):
    roots: list[str] | None = Field(default=None, description="Directories to scan recursively for PDF files.")
    force: bool = Field(default=False, description="Re-index files even if size and mtime did not change.")
    max_pages_per_pdf: int | None = Field(default=None, ge=1, description="Page render limit per PDF.")


class SearchRequest(BaseModel):
    query: str = Field(..., min_length=1)
    limit: int = Field(default=8, ge=1, le=50)


def require_auth(authorization: str | None = Header(default=None)) -> None:
    if not API_KEY:
        return
    if authorization != f"Bearer {API_KEY}":
        raise HTTPException(status_code=401, detail="Invalid bearer token")


def db() -> sqlite3.Connection:
    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    THUMB_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            source_path TEXT NOT NULL,
            source_sha256 TEXT NOT NULL,
            source_mtime REAL NOT NULL,
            source_size INTEGER NOT NULL,
            item_type TEXT NOT NULL,
            page INTEGER NOT NULL,
            image_index INTEGER,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            thumb_path TEXT NOT NULL,
            embedding BLOB NOT NULL,
            created_at REAL NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_items_source ON items(source_path)")
    return conn


def model() -> SentenceTransformer:
    global _model
    if _model is None:
        device = None if DEVICE_SETTING == "auto" else DEVICE_SETTING
        _model = SentenceTransformer(MODEL_NAME, device=device)
    return _model


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def encode_image_bytes(image_bytes: bytes) -> np.ndarray:
    from PIL import Image

    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    emb = model().encode([image], normalize_embeddings=True)[0]
    return np.asarray(emb, dtype=np.float32)


def encode_text(text: str) -> np.ndarray:
    emb = model().encode([text], normalize_embeddings=True)[0]
    return np.asarray(emb, dtype=np.float32)


def save_png_bytes(item_id: str, image_bytes: bytes) -> Path:
    path = THUMB_DIR / f"{item_id}.png"
    path.write_bytes(image_bytes)
    return path


def existing_current(conn: sqlite3.Connection, path: Path, size: int, mtime: float) -> bool:
    row = conn.execute(
        "SELECT 1 FROM items WHERE source_path = ? AND source_size = ? AND source_mtime = ? LIMIT 1",
        (str(path), size, mtime),
    ).fetchone()
    return row is not None


def remove_source(conn: sqlite3.Connection, path: Path) -> None:
    rows = conn.execute("SELECT thumb_path FROM items WHERE source_path = ?", (str(path),)).fetchall()
    for (thumb_path,) in rows:
        try:
            Path(thumb_path).unlink(missing_ok=True)
        except OSError:
            pass
    conn.execute("DELETE FROM items WHERE source_path = ?", (str(path),))


def insert_item(
    conn: sqlite3.Connection,
    *,
    item_id: str,
    source_path: Path,
    source_sha256: str,
    source_mtime: float,
    source_size: int,
    item_type: str,
    page: int,
    image_index: int | None,
    width: int,
    height: int,
    thumb_path: Path,
    embedding: np.ndarray,
) -> None:
    conn.execute(
        """
        INSERT OR REPLACE INTO items
        (id, source_path, source_sha256, source_mtime, source_size, item_type, page, image_index,
         width, height, thumb_path, embedding, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            item_id,
            str(source_path),
            source_sha256,
            source_mtime,
            source_size,
            item_type,
            page,
            image_index,
            width,
            height,
            str(thumb_path),
            embedding.astype(np.float32).tobytes(),
            time.time(),
        ),
    )


def render_page_png(page: fitz.Page) -> tuple[bytes, int, int]:
    pix = page.get_pixmap(dpi=RENDER_DPI, alpha=False)
    return pix.tobytes("png"), pix.width, pix.height


def index_pdf(conn: sqlite3.Connection, path: Path, force: bool, max_pages: int) -> dict[str, Any]:
    stat = path.stat()
    if not force and existing_current(conn, path, stat.st_size, stat.st_mtime):
        count = conn.execute("SELECT COUNT(*) FROM items WHERE source_path = ?", (str(path),)).fetchone()[0]
        return {"path": str(path), "status": "skipped", "items": count}

    source_sha = sha256_file(path)
    remove_source(conn, path)

    page_items = 0
    embedded_image_items = 0
    doc = fitz.open(path)
    try:
        for page_index in range(min(len(doc), max_pages)):
            page = doc.load_page(page_index)

            png_bytes, width, height = render_page_png(page)
            page_id = hashlib.sha256(f"{source_sha}:page:{page_index + 1}".encode()).hexdigest()[:32]
            page_thumb = save_png_bytes(page_id, png_bytes)
            page_emb = encode_image_bytes(png_bytes)
            insert_item(
                conn,
                item_id=page_id,
                source_path=path,
                source_sha256=source_sha,
                source_mtime=stat.st_mtime,
                source_size=stat.st_size,
                item_type="page_render",
                page=page_index + 1,
                image_index=None,
                width=width,
                height=height,
                thumb_path=page_thumb,
                embedding=page_emb,
            )
            page_items += 1

            for image_index, image_info in enumerate(page.get_images(full=True), start=1):
                xref = image_info[0]
                try:
                    extracted = doc.extract_image(xref)
                    image_bytes = extracted.get("image")
                    if not image_bytes:
                        continue
                    image_id = hashlib.sha256(f"{source_sha}:image:{page_index + 1}:{image_index}:{xref}".encode()).hexdigest()[:32]
                    image_thumb = save_png_bytes(image_id, image_bytes)
                    image_emb = encode_image_bytes(image_bytes)
                    insert_item(
                        conn,
                        item_id=image_id,
                        source_path=path,
                        source_sha256=source_sha,
                        source_mtime=stat.st_mtime,
                        source_size=stat.st_size,
                        item_type="embedded_image",
                        page=page_index + 1,
                        image_index=image_index,
                        width=int(extracted.get("width", 0)),
                        height=int(extracted.get("height", 0)),
                        thumb_path=image_thumb,
                        embedding=image_emb,
                    )
                    embedded_image_items += 1
                except Exception:
                    continue
    finally:
        doc.close()

    conn.commit()
    return {
        "path": str(path),
        "status": "indexed",
        "page_renders": page_items,
        "embedded_images": embedded_image_items,
        "items": page_items + embedded_image_items,
    }


@app.get("/health")
def health() -> dict[str, Any]:
    conn = db()
    try:
        items = conn.execute("SELECT COUNT(*) FROM items").fetchone()[0]
    finally:
        conn.close()
    return {"ok": True, "model": MODEL_NAME, "items": items}


@app.post("/index", dependencies=[Depends(require_auth)])
def index(req: IndexRequest) -> dict[str, Any]:
    roots = [Path(p) for p in req.roots] if req.roots else ROOTS
    max_pages = req.max_pages_per_pdf or MAX_PAGES_PER_PDF
    pdfs: list[Path] = []
    for root in roots:
        if root.exists():
            pdfs.extend(sorted(root.rglob("*.pdf")))

    conn = db()
    results = []
    try:
        for pdf in pdfs:
            try:
                results.append(index_pdf(conn, pdf, req.force, max_pages))
            except Exception as exc:
                results.append({"path": str(pdf), "status": "failed", "error": str(exc)})
    finally:
        conn.close()

    return {"roots": [str(r) for r in roots], "pdfs_seen": len(pdfs), "results": results}


@app.post("/search", dependencies=[Depends(require_auth)])
def search(req: SearchRequest) -> dict[str, Any]:
    query_emb = encode_text(req.query)
    conn = db()
    try:
        rows = conn.execute(
            """
            SELECT id, source_path, item_type, page, image_index, width, height, thumb_path, embedding
            FROM items
            """
        ).fetchall()
    finally:
        conn.close()

    scored = []
    for row in rows:
        emb = np.frombuffer(row[8], dtype=np.float32)
        score = float(np.dot(query_emb, emb))
        scored.append((score, row))
    scored.sort(reverse=True, key=lambda x: x[0])

    items = []
    for score, row in scored[: req.limit]:
        item_id, source_path, item_type, page, image_index, width, height, thumb_path, _ = row
        items.append(
            {
                "id": item_id,
                "score": score,
                "source_path": source_path,
                "item_type": item_type,
                "page": page,
                "image_index": image_index,
                "width": width,
                "height": height,
                "preview_url": f"/images/{item_id}.png",
                "thumb_path": thumb_path,
            }
        )
    return {"query": req.query, "count": len(items), "items": items}


@app.get("/images/{item_id}.png", dependencies=[Depends(require_auth)])
def image(item_id: str) -> Response:
    conn = db()
    try:
        row = conn.execute("SELECT thumb_path FROM items WHERE id = ?", (item_id,)).fetchone()
    finally:
        conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Image not found")
    path = Path(row[0])
    if not path.exists():
        raise HTTPException(status_code=404, detail="Image file not found")
    return FileResponse(path, media_type="image/png")
