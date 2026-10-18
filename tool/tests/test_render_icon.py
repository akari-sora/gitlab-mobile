from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import render_icon

SVG = '{http://www.w3.org/2000/svg}'


class RenderIconTests(unittest.TestCase):
    def test_adaptive_glyph_stays_inside_the_safe_zone(self):
        reach = render_icon.glyph(render_icon.ADAPTIVE_SCALE)[2]
        self.assertLess(reach, render_icon.SAFE_RADIUS)

    def test_adaptive_and_full_bleed_glyphs_fill_the_same_share_of_the_visible_icon(self):
        full = render_icon.glyph(render_icon.FULL_SCALE)[2] / 512
        visible = 1024 * (36 / 108) / render_icon.INSET_COVERAGE
        adaptive = render_icon.glyph(render_icon.ADAPTIVE_SCALE)[2] / visible
        self.assertAlmostEqual(full, adaptive, delta=.02)

    def test_layers_are_well_formed_and_separate(self):
        background = ET.fromstring(render_icon.svg(background=True))
        self.assertIsNone(background.find(f'.//{SVG}mask'))
        foreground = render_icon.svg(background=False, scale=render_icon.ADAPTIVE_SCALE)
        root = ET.fromstring(foreground)
        self.assertIsNotNone(root.find(f'.//{SVG}mask'))
        self.assertNotIn('url(#bg)', foreground)
        self.assertIn(render_icon.ACCENT, foreground)

    def test_monochrome_is_a_single_colour(self):
        mono = render_icon.svg(background=False, scale=render_icon.ADAPTIVE_SCALE, monochrome=True)
        ET.fromstring(mono)
        self.assertNotIn(render_icon.ACCENT, mono)
        self.assertNotIn('url(#bg)', mono)


if __name__ == '__main__':
    unittest.main()
