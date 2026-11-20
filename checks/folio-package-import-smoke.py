#!/usr/bin/env python3
"""Check imported regular books and expanded macOS packages in an isolated Folio library."""

import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path


APP = Path(__file__).resolve().parents[1] / "app"
EPUB = APP / "shots/testdata/Files/2B64E42D-2D9A-46A4-BB8B-14F35B2C9B50.epub"
PDF = APP / "shots/testdata/Files/614D8D84-5602-49F3-A3D2-56C22C746CFA.pdf"
ICON = APP / "shots/icon/Folio.iconset/icon_16x16.png"


def verify():
    # Use the supplied fixture's UUID, independent of book metadata or chapter count.
    source = next((APP / "shots/testdata/Files").glob("*.epub"))
    with tempfile.TemporaryDirectory(prefix="folio-format-smoke-") as root_name:
        root = Path(root_name)
        inputs = root / "inputs"
        data_dir = root / "library"
        inputs.mkdir()
        names = []

        def add(path):
            names.append(path)
            return path

        epub_file = add(inputs / "standard.epub")
        shutil.copy2(source, epub_file)
        epub_folder = add(inputs / "apple-books.epub")
        epub_folder.mkdir()
        with zipfile.ZipFile(epub_file) as source_zip:
            source_zip.extractall(epub_folder)

        epub_no_extension = add(inputs / "expanded-book")
        shutil.copytree(epub_folder, epub_no_extension)

        cbz_folder = add(inputs / "expanded.cbz")
        cbz_folder.mkdir()
        for n in range(1, 3):
            shutil.copy2(ICON, cbz_folder / f"{n:03}.png")
        cbz_file = add(inputs / "compressed.cbz")
        with zipfile.ZipFile(cbz_file, "w", compression=zipfile.ZIP_DEFLATED) as output_zip:
            for picture in sorted(cbz_folder.glob("*.png")):
                output_zip.write(picture, picture.name)

        rtfd = add(inputs / "package.rtfd")
        rtfd.mkdir()
        (rtfd / "TXT.rtf").write_text(r"{\rtf1\ansi\deff0 This is a rich text package.}", encoding="ascii")
        rtf = add(inputs / "plain.rtf")
        rtf.write_text(r"{\rtf1\ansi\deff0 This is a regular RTF document.}", encoding="ascii")

        textbundle = add(inputs / "notes.textbundle")
        (textbundle / "assets").mkdir(parents=True)
        shutil.copy2(ICON, textbundle / "assets" / "one.png")
        (textbundle / "text.md").write_text("# Bundle test\n\n![Cover](assets/one.png)\n", encoding="utf-8")

        html_folder = add(inputs / "website.html")
        (html_folder / "assets").mkdir(parents=True)
        shutil.copy2(ICON, html_folder / "assets" / "one.png")
        (html_folder / "index.html").write_text('<html><body><img src="assets/one.png"></body></html>', encoding="utf-8")

        pdf = add(inputs / "sample.pdf")
        shutil.copy2(PDF, pdf)
        text = add(inputs / "text.txt")
        text.write_text("The ordinary text format still imports.", encoding="utf-8")
        markdown = add(inputs / "plain.md")
        markdown.write_text("# Ordinary markdown\n\nThis still works.\n", encoding="utf-8")
        html = add(inputs / "plain.html")
        html.write_text("<html><body>Ordinary HTML.</body></html>", encoding="utf-8")

        executable = APP / ".build/debug/Folio"
        if not executable.exists():
            raise RuntimeError(f"Build Folio first: {executable}")
        env = dict(os.environ, FOLIO_DATA_DIR=str(data_dir), FOLIO_IMPORT=":".join(map(str, names)), FOLIO_SHOT_FRAMES="360")
        result = subprocess.run([str(executable), "--screenshot", str(root / "reader.png")], env=env, capture_output=True, text=True, timeout=50)
        if result.returncode:
            raise AssertionError(result.stderr[-2500:])
        library = json.loads((data_dir / "library.json").read_text())
        books = library["books"]
        assert len(books) == len(names), f"Imported {len(books)} of {len(names)} requested books: {books}"
        formats = [book["format"] for book in books]
        assert formats.count("epub") == 3, formats
        assert formats.count("comic") == 2, formats
        assert formats.count("rtf") == 2, formats
        assert formats.count("markdown") == 2, formats
        assert formats.count("html") == 2, formats
        assert "pdf" in formats and "text" in formats
        for book in books:
            stored = data_dir / "Files" / book["fileName"]
            assert stored.exists(), stored
            if book["format"] == "epub":
                assert stored.is_file(), f"EPUB must be a portable ZIP file: {stored}"
                with zipfile.ZipFile(stored) as archive:
                    assert archive.testzip() is None
                    assert archive.namelist()[0] == "mimetype"
                    assert archive.getinfo("mimetype").compress_type == zipfile.ZIP_STORED
            if book["format"] == "comic":
                assert zipfile.is_zipfile(stored)
            if stored.suffix == ".textbundle":
                extracted = data_dir / "Extracted" / book["id"]
                assert (extracted / "assets/one.png").is_file()
                assert '<img alt="Cover" src="assets/one.png">' in (extracted / "folio-index.html").read_text()
            if stored.is_dir() and stored.suffix == ".html":
                extracted = data_dir / "Extracted" / book["id"]
                assert (extracted / "assets/one.png").is_file()
        assert (root / "reader.png").is_file(), "No reader screenshot"
        print(f"PASS: {len(books)} Folio imports across 7 formats, including ZIP files, expanded Books EPUB, CBZ, RTFD, and TextBundle")


if __name__ == "__main__":
    verify()
