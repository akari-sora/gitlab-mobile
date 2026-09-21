#!/usr/bin/env python3
"""Install CI packages using authenticated Debian HTTPS sources and bounded retries."""

from pathlib import Path
import re
import subprocess
import sys


def configure_sources(root=Path('/etc/apt')):
    paths = [root / 'sources.list']
    paths += sorted((root / 'sources.list.d').glob('*.list'))
    paths += sorted((root / 'sources.list.d').glob('*.sources'))
    for path in paths:
        if not path.is_file():
            continue
        original = path.read_text()
        updated = re.sub(
            r'http://(deb\.debian\.org|security\.debian\.org)(?=/|\s|$)',
            r'https://\1', original,
        )
        if updated != original:
            path.write_text(updated)


def install(packages):
    if not packages:
        raise ValueError('At least one package is required')
    configure_sources()
    options = [
        '-o', 'Acquire::Retries=3',
        '-o', 'Acquire::http::Timeout=30',
        '-o', 'Acquire::https::Timeout=30',
    ]
    # A partial index refresh must fail rather than silently using stale indexes.
    subprocess.check_call([
        'apt-get', *options, '-o', 'APT::Update::Error-Mode=any', 'update', '-qq',
    ])
    subprocess.check_call([
        'apt-get', *options, 'install', '-y', '--no-install-recommends', *packages,
    ])


if __name__ == '__main__':
    install(sys.argv[1:])
