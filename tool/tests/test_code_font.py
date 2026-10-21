"""Checks that the bundled code font draws characters as written.

JetBrains Mono joins `>=`, `->` or `!=` into one ligature glyph through its
`calt` feature, so code read as `≥` or `→`. The bundled files are the 2.304
fonts with only that feature removed (tool/fonts/drop_ligatures.py), so
combining marks and other shaping still work. This reads the OpenType tables
directly, so it needs no font library."""
from __future__ import annotations

from pathlib import Path
import re
import struct
import unittest

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / 'assets' / 'fonts'
# Features that join or swap glyphs in running text by default.
JOINING = {'calt', 'liga', 'clig', 'dlig', 'rlig', 'rclt'}


def tables(data: bytes) -> dict[str, tuple[int, int]]:
    """Maps each table tag to its (offset, length) in an sfnt file."""
    count = struct.unpack_from('>H', data, 4)[0]
    found = {}
    for index in range(count):
        tag, _, offset, length = struct.unpack_from('>4sIII', data, 12 + 16 * index)
        found[tag.decode('latin-1')] = (offset, length)
    return found


def layout_features(data: bytes, tag: str) -> set[str]:
    """Feature tags in the GSUB or GPOS table [tag], or none without it."""
    entry = tables(data).get(tag)
    if entry is None:
        return set()
    base = entry[0]
    feature_list = base + struct.unpack_from('>H', data, base + 6)[0]
    count = struct.unpack_from('>H', data, feature_list)[0]
    # Each FeatureRecord is a 4-byte tag and a 2-byte offset.
    return {
        data[feature_list + 2 + 6 * index:feature_list + 6 + 6 * index].decode('latin-1')
        for index in range(count)
    }


def synthetic_font(features: list[str], extra: str = 'GDEF') -> bytes:
    """A minimal sfnt with an [extra] table before a GSUB whose feature list
    holds [features], so both record strides matter."""
    feature_list = struct.pack('>H', len(features)) + b''.join(
        tag.encode('latin-1') + struct.pack('>H', 0) for tag in features
    )
    gsub = struct.pack('>HHHHH', 1, 0, 0, 10, 0) + feature_list
    gdef = struct.pack('>HHHHHH', 1, 0, 0, 0, 0, 0)
    header = struct.pack('>IHHHH', 0x00010000, 2, 32, 1, 0)
    first = 12 + 16 * 2
    directory = struct.pack('>4sIII', extra.encode('latin-1'), 0, first, len(gdef)) + struct.pack(
        '>4sIII', b'GSUB', 0, first + len(gdef), len(gsub)
    )
    return header + directory + gdef + gsub


class CodeFontTest(unittest.TestCase):
    def bundled(self) -> list[Path]:
        pubspec = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
        paths = [
            ROOT / match
            for match in re.findall(
                r'''^\s*-\s*asset:\s*["']?([^"'\s]+\.(?:ttf|otf))["']?\s*$''', pubspec, re.M
            )
        ]
        self.assertTrue(paths, 'pubspec.yaml declares no bundled font files')
        return paths

    def test_bundled_fonts_have_no_ligatures(self):
        for path in self.bundled():
            with self.subTest(font=path.name):
                data = path.read_bytes()
                self.assertEqual(layout_features(data, 'GSUB') & JOINING, set())
                # Apple's own layout tables could carry ligatures too.
                self.assertEqual({'morx', 'mort'} & set(tables(data)), set())

    def test_bundled_fonts_keep_normal_shaping(self):
        # Only the ligatures go: composition and mark placement stay.
        for path in self.bundled():
            with self.subTest(font=path.name):
                data = path.read_bytes()
                self.assertIn('ccmp', layout_features(data, 'GSUB'))
                self.assertLessEqual({'mark', 'mkmk'}, layout_features(data, 'GPOS'))
                self.assertLessEqual({'cmap', 'glyf', 'head', 'hmtx', 'GDEF'}, set(tables(data)))

    def test_every_font_file_is_declared(self):
        declared = {path.resolve() for path in self.bundled()}
        on_disk = {path.resolve() for path in FONTS.iterdir() if path.suffix in {'.ttf', '.otf'}}
        self.assertEqual(on_disk, declared)

    def test_reader_finds_a_joining_feature_after_others(self):
        found = layout_features(synthetic_font(['aalt', 'ccmp', 'calt']), 'GSUB')
        self.assertEqual(found, {'aalt', 'ccmp', 'calt'})
        self.assertEqual(set(tables(synthetic_font(['aalt']))), {'GDEF', 'GSUB'})
        # Apple's layout table is seen too, so its check is not vacuous.
        self.assertIn('morx', tables(synthetic_font(['aalt'], extra='morx')))


if __name__ == '__main__':
    unittest.main()
