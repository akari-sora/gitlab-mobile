#!/usr/bin/env python3
"""Download and install Android commandline tools with bounded retries, TLS enforcement, and integrity verification."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

# Specific transient curl exit codes permitted for bounded retry:
# 7: CURLE_COULDNT_CONNECT
# 28: CURLE_OPERATION_TIMEDOUT
# 35: CURLE_SSL_CONNECT_ERROR
# 52: CURLE_GOT_NOTHING
# 56: CURLE_RECV_ERROR
RETRYABLE_CURL_EXIT_CODES = {7, 28, 35, 52, 56}


def compute_sha256(path: Path) -> str:
    hasher = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def download_with_retry(
    url: str,
    output_path: Path,
    max_retries: int = 3,
    connect_timeout: int = 30,
    max_time: int = 300,
    sleep_fn=time.sleep,
    prefer_ipv4: bool = False,
) -> None:
    if not url.startswith('https://'):
        raise ValueError(f'Only HTTPS URLs are permitted: {url}')

    for attempt in range(1, max_retries + 1):
        if output_path.exists():
            output_path.unlink()

        curl_cmd = [
            'curl',
            '--proto', '=https',
            '--proto-redir', '=https',
            '--fail',
            '--location',
            '--connect-timeout', str(connect_timeout),
            '--max-time', str(max_time),
        ]
        if prefer_ipv4 or attempt > 1:
            curl_cmd.append('--ipv4')

        curl_cmd.extend([
            '--output', str(output_path),
            url,
        ])

        result = subprocess.run(curl_cmd)
        if result.returncode == 0:
            return

        if result.returncode not in RETRYABLE_CURL_EXIT_CODES:
            # Fatal / non-retryable error (e.g. 404, protocol error)
            raise subprocess.CalledProcessError(result.returncode, curl_cmd)

        if attempt < max_retries:
            backoff = min(attempt * 2, 10)
            sleep_fn(backoff)
        else:
            raise subprocess.CalledProcessError(result.returncode, curl_cmd)


def install_tools(
    url: str,
    expected_sha256: str,
    destination: Path,
    max_retries: int = 3,
    connect_timeout: int = 30,
    max_time: int = 300,
    sleep_fn=time.sleep,
    prefer_ipv4: bool = False,
) -> None:
    destination = Path(destination).resolve()
    expected_hash = expected_sha256.strip().lower()

    with tempfile.TemporaryDirectory() as temp_dir_str:
        temp_dir = Path(temp_dir_str)
        archive_path = temp_dir / 'tools.zip'

        download_with_retry(
            url=url,
            output_path=archive_path,
            max_retries=max_retries,
            connect_timeout=connect_timeout,
            max_time=max_time,
            sleep_fn=sleep_fn,
            prefer_ipv4=prefer_ipv4,
        )

        actual_hash = compute_sha256(archive_path)
        if actual_hash != expected_hash:
            raise ValueError(
                f'SHA-256 checksum mismatch for {url}: expected {expected_hash}, got {actual_hash}'
            )

        extract_dir = temp_dir / 'unpacked'
        extract_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive_path, 'r') as zf:
            zf.extractall(extract_dir)

        unpacked_tools = extract_dir / 'cmdline-tools'
        if not unpacked_tools.is_dir():
            raise RuntimeError(f'Extracted archive missing cmdline-tools directory: {extract_dir}')

        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            shutil.rmtree(destination)

        shutil.move(str(unpacked_tools), str(destination))

        sdkmanager = destination / 'bin' / 'sdkmanager'
        if sdkmanager.exists():
            sdkmanager.chmod(0o755)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True, help='HTTPS download URL')
    parser.add_argument('--sha256', required=True, help='Expected SHA-256 hash')
    parser.add_argument('--destination', required=True, type=Path, help='Target installation path')
    parser.add_argument('--retries', type=int, default=3, help='Max download attempts (default: 3)')
    parser.add_argument('--connect-timeout', type=int, default=30, help='Connection timeout in seconds')
    parser.add_argument('--max-time', type=int, default=300, help='Max transfer time in seconds')
    parser.add_argument('--ipv4', action='store_true', help='Force/prefer IPv4 to bypass broken dual-stack IPv6')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        install_tools(
            url=args.url,
            expected_sha256=args.sha256,
            destination=args.destination,
            max_retries=args.retries,
            connect_timeout=args.connect_timeout,
            max_time=args.max_time,
            prefer_ipv4=args.ipv4,
        )
    except subprocess.CalledProcessError as exc:
        print(f'Download failed with exit code {exc.returncode}', file=sys.stderr)
        sys.exit(exc.returncode)
    except Exception as exc:
        print(f'Installation failed: {exc}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
