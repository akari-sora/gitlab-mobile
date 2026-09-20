#!/usr/bin/env python3
"""Emit a compact derivative of an actual, synthetic-data Flutter screenshot."""
from base64 import b64encode
from io import BytesIO
from pathlib import Path

from PIL import Image

source = Path('ci-output/screenshots/projects-light.png')
if source.is_file():
    with Image.open(source) as original:
        image = original.convert('RGB')
        image.thumbnail((300, 650))
        image = image.quantize(colors=32)
        output = BytesIO()
        image.save(output, format='PNG', optimize=True)
        png = output.getvalue()
    Path('ci-output/projects-light-preview.png').write_bytes(png)
    Path('ci-output/ui-preview-base64.txt').write_text(b64encode(png).decode('ascii'))
