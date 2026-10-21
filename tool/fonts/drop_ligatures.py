"""Writes a copy of a font without its `calt` feature (code ligatures).

JetBrains Mono joins `>=`, `->` or `!=` into one glyph through `calt`, so code
read as `≥` or `→`. Removing only that feature keeps everything else the
font does: `ccmp`, mark positioning, `locl` and the outlines and metrics.

    python3 tool/fonts/drop_ligatures.py IN.ttf OUT.ttf

Needs fontTools (a development tool only; the app ships the output). The
bundled assets/fonts/JetBrainsMono-NoCalt-*.ttf were made this way from the
JetBrains Mono 2.304 release files with fontTools 4.62.1; another version may
pack the same tables into different bytes.
"""
from __future__ import annotations

import sys

from fontTools.ttLib import TTFont

DROPPED = {'calt'}


def drop_features(font: TTFont, dropped: set[str] = DROPPED) -> int:
    """Removes the [dropped] feature records from GSUB and renumbers every
    reference to the rest. Returns how many records were removed."""
    if 'GSUB' not in font:
        return 0
    table = font['GSUB'].table
    records = table.FeatureList.FeatureRecord
    keep = [index for index, record in enumerate(records) if record.FeatureTag not in dropped]
    renumber = {old: new for new, old in enumerate(keep)}
    table.FeatureList.FeatureRecord = [records[index] for index in keep]
    table.FeatureList.FeatureCount = len(keep)
    for script in table.ScriptList.ScriptRecord:
        systems = [script.Script.DefaultLangSys] + [lang.LangSys for lang in script.Script.LangSysRecord]
        for system in systems:
            if system is None:
                continue
            system.FeatureIndex = [renumber[index] for index in system.FeatureIndex if index in renumber]
            system.FeatureCount = len(system.FeatureIndex)
            if system.ReqFeatureIndex != 0xFFFF:
                system.ReqFeatureIndex = renumber.get(system.ReqFeatureIndex, 0xFFFF)
    variations = getattr(table, 'FeatureVariations', None)
    if variations is not None:
        for record in variations.FeatureVariationRecord:
            substitution = record.FeatureTableSubstitution
            substitution.SubstitutionRecord = [
                item for item in substitution.SubstitutionRecord if item.FeatureIndex in renumber
            ]
            for item in substitution.SubstitutionRecord:
                item.FeatureIndex = renumber[item.FeatureIndex]
            substitution.SubstitutionCount = len(substitution.SubstitutionRecord)
    return len(records) - len(keep)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    font = TTFont(argv[1], recalcTimestamp=False)
    removed = drop_features(font)
    font.save(argv[2])
    print(f'{argv[2]}: removed {removed} feature record(s)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
