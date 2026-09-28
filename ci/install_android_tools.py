#!/usr/bin/env python3
"""Download and install Android commandline tools with multi-endpoint failover,
adaptive network protocols, bounded retries, and integrity verification."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

# Specific transient curl exit codes permitted for bounded retry:
# 7: CURLE_COULDNT_CONNECT
# 28: CURLE_OPERATION_TIMEDOUT
# 35: CURLE_SSL_CONNECT_ERROR
# 52: CURLE_GOT_NOTHING
# 56: CURLE_RECV_ERROR
RETRYABLE_CURL_EXIT_CODES = {7, 28, 35, 52, 56}


class HTTPSOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Enforce HTTPS on all redirects to avoid credential or data leaks."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError(f'Redirect to non-HTTPS URL prohibited: {newurl}')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def compute_sha256(path: Path) -> str:
    """Compute the SHA-256 hash of a file."""
    hasher = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def download_with_curl(
    url: str,
    output_path: Path,
    prefer_ipv4: bool = False,
    force_http1: bool = False,
    connect_timeout: int = 30,
    max_time: int = 600,
) -> int:
    """Download a URL using curl with specific protocol flags."""
    cmd = [
        'curl',
        '--proto', '=https',
        '--proto-redir', '=https',
        '--fail',
        '--location',
        '--connect-timeout', str(connect_timeout),
        '--max-time', str(max_time),
    ]
    if prefer_ipv4:
        cmd.append('--ipv4')
    if force_http1:
        cmd.append('--http1.1')
    cmd.extend(['--output', str(output_path), url])

    result = subprocess.run(cmd)
    return result.returncode


def download_with_python(url: str, output_path: Path, timeout: int = 90) -> None:
    """Fallback download using Python urllib with HTTPS enforcement and streaming."""
    if not url.startswith('https://'):
        raise ValueError(f'Only HTTPS URLs are permitted: {url}')

    req = urllib.request.Request(
        url,
        headers={'User-Agent': 'GitLab-CI-Android-Installer/1.0'},
    )
    opener = urllib.request.build_opener(HTTPSOnlyRedirectHandler())
    with opener.open(req, timeout=timeout) as response:
        final_url = response.geturl()
        if not final_url.startswith('https://'):
            raise ValueError(f'Redirect to non-HTTPS URL prohibited: {final_url}')
        with open(output_path, 'wb') as out_file:
            shutil.copyfileobj(response, out_file, length=1024 * 1024)


def download_with_retry(
    urls: list[str] | str | None = None,
    output_path: Path | None = None,
    arg3: str | int = '',
    max_retries: int = 4,
    connect_timeout: int = 30,
    max_time: int = 600,
    sleep_fn=time.sleep,
    prefer_ipv4: bool = False,
    *,
    expected_sha256: str = '',
    url: str | None = None,
) -> None:
    """Download archive using multi-endpoint rotation, adaptive curl, and Python fallback."""
    if urls is None and url is not None:
        urls = [url]
    elif isinstance(urls, str):
        urls = [urls]
    elif urls is None:
        raise ValueError('At least one download URL is required')

    if output_path is None:
        raise ValueError('output_path is required')

    if isinstance(arg3, int):
        max_retries = arg3
    elif isinstance(arg3, str) and arg3:
        expected_sha256 = arg3

    for u in urls:
        if not u.startswith('https://'):
            raise ValueError(f'Only HTTPS URLs are permitted: {u}')

    expected_hash = expected_sha256.strip().lower()
    last_returncode = None
    last_cmd = None
    last_error = None
    checksum_mismatch_hash = None

    for attempt in range(1, max_retries + 1):
        if output_path.exists():
            output_path.unlink()

        current_url = urls[(attempt - 1) % len(urls)]
        use_ipv4 = prefer_ipv4 or (attempt > 1)
        use_http1 = attempt > 2
        attempt_timeout = connect_timeout if attempt == 1 else max(connect_timeout, 45)

        cmd = [
            'curl',
            '--proto', '=https',
            '--proto-redir', '=https',
            '--fail',
            '--location',
            '--connect-timeout', str(attempt_timeout),
            '--max-time', str(max_time),
        ]
        if use_ipv4:
            cmd.append('--ipv4')
        if use_http1:
            cmd.append('--http1.1')
        cmd.extend(['--output', str(output_path), current_url])

        last_cmd = cmd
        try:
            result = subprocess.run(cmd)
            returncode = result.returncode
        except Exception as exc:
            returncode = -1
            last_error = exc

        last_returncode = returncode

        if returncode == 0:
            if expected_hash:
                if output_path.exists():
                    actual_hash = compute_sha256(output_path)
                    if actual_hash == expected_hash:
                        return
                    checksum_mismatch_hash = actual_hash
                    print(
                        f'Checksum mismatch on attempt {attempt}: got {actual_hash}, expected {expected_hash}',
                        file=sys.stderr,
                    )
                    output_path.unlink()
            else:
                return

        # Non-retryable exit code
        if returncode != 0 and returncode not in RETRYABLE_CURL_EXIT_CODES:
            if len(urls) == 1:
                raise subprocess.CalledProcessError(returncode, cmd)

        if attempt < max_retries:
            backoff = min(attempt * 2, 10)
            sleep_fn(backoff)

    # If all curl attempts failed or produced bad checksum, attempt Python urllib fallback
    print('Curl attempts exhausted. Attempting fallback via Python urllib...', file=sys.stderr)
    for fallback_url in urls:
        try:
            if output_path.exists():
                output_path.unlink()
            download_with_python(fallback_url, output_path, timeout=max_time)
            if output_path.exists():
                if expected_hash:
                    actual_hash = compute_sha256(output_path)
                    if actual_hash == expected_hash:
                        return
                    checksum_mismatch_hash = actual_hash
                    print(
                        f'Python fallback checksum mismatch: got {actual_hash}, expected {expected_hash}',
                        file=sys.stderr,
                    )
                    output_path.unlink()
                else:
                    return
        except Exception as exc:
            last_error = exc
            print(f'Python fallback for {fallback_url} failed: {exc}', file=sys.stderr)

    if output_path.exists():
        output_path.unlink()

    if checksum_mismatch_hash is not None:
        raise ValueError(
            f'SHA-256 checksum mismatch: expected {expected_hash}, got {checksum_mismatch_hash}'
        )

    if last_returncode is not None and last_returncode != 0:
        raise subprocess.CalledProcessError(last_returncode, last_cmd or ['curl'])

    raise RuntimeError(f'All download attempts failed. Last error: {last_error}')


# Alias for compatibility with orchestrator / explorer naming
resilient_download = download_with_retry


def install_tools(
    url: str | list[str] | None = None,
    expected_sha256: str = '',
    destination: Path | str | None = None,
    max_retries: int = 4,
    connect_timeout: int = 30,
    max_time: int = 600,
    sleep_fn=time.sleep,
    prefer_ipv4: bool = False,
    *,
    urls: list[str] | None = None,
) -> None:
    """Download, verify, unpack, and install Android commandline tools."""
    if urls is None:
        if isinstance(url, list):
            urls = url
        elif isinstance(url, str):
            urls = [url]
        else:
            raise ValueError('At least one URL must be specified')

    if destination is None:
        raise ValueError('Destination path is required')

    destination = Path(destination).resolve()
    expected_hash = expected_sha256.strip().lower()

    with tempfile.TemporaryDirectory() as temp_dir_str:
        temp_dir = Path(temp_dir_str)
        archive_path = temp_dir / 'tools.zip'
        ensure_dl_google_com_route()

        download_with_retry(
            urls=urls,
            output_path=archive_path,
            expected_sha256=expected_hash,
            max_retries=max_retries,
            connect_timeout=connect_timeout,
            max_time=max_time,
            sleep_fn=sleep_fn,
            prefer_ipv4=prefer_ipv4,
        )

        actual_hash = compute_sha256(archive_path)
        if actual_hash != expected_hash:
            raise ValueError(
                f'SHA-256 checksum mismatch: expected {expected_hash}, got {actual_hash}'
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


def is_http_accessible(url: str = 'https://dl.google.com/android/repository/repository2-3.xml', timeout: float = 5.0) -> bool:
    """Test if a URL responds with 200 within timeout."""
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'curl/8.0'})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


def verify_tls_sni(ip: str, hostname: str, timeout: float = 5.0) -> bool:
    """Verify that connecting to IP with SNI hostname returns a valid certificate."""
    ctx = ssl.create_default_context()
    try:
        with socket.create_connection((ip, 443), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=hostname) as ssock:
                cert = ssock.getpeercert()
                sans = [v for (k, v) in cert.get('subjectAltName', []) if k == 'DNS']
                return hostname in sans or any(
                    s.startswith('*.') and hostname.endswith(s[1:]) for s in sans
                )
    except Exception:
        return False


def ensure_dl_google_com_route(hosts_file: Path = Path('/etc/hosts')) -> bool:
    """Ensure dl.google.com routes to a reachable edge endpoint on broken CI networks."""
    test_url = 'https://dl.google.com/android/repository/repository2-3.xml'
    if is_http_accessible(test_url, timeout=5.0):
        print('dl.google.com is reachable via default DNS.')
        return True

    print('dl.google.com is unreachable or timing out on default DNS. Resolving edge mirrors...', file=sys.stderr)
    fallback_hosts = ['redirector.gvt1.com', 'dl-ssl.google.com']
    for host in fallback_hosts:
        try:
            addrs = socket.getaddrinfo(host, 443, socket.AF_INET)
            ips = sorted(list(set(a[4][0] for a in addrs)))
        except Exception as e:
            print(f'Failed to resolve {host}: {e}', file=sys.stderr)
            continue

        for ip in ips:
            if verify_tls_sni(ip, 'dl.google.com', timeout=3.0):
                print(f'Verified dl.google.com TLS SNI on edge IP {ip} (from {host}).', file=sys.stderr)
                try:
                    if not hosts_file.exists() or not os.access(hosts_file, os.W_OK):
                        print(f'{hosts_file} is not writable or does not exist.', file=sys.stderr)
                        return False
                    content = hosts_file.read_text()
                    if 'dl.google.com' not in content:
                        hosts_file.write_text(content.rstrip() + f'\n{ip} dl.google.com\n')
                        print(f'Added "{ip} dl.google.com" to {hosts_file}', file=sys.stderr)
                    return True
                except Exception as e:
                    print(f'Could not write {hosts_file}: {e}', file=sys.stderr)
                    return False

    print('Warning: No working edge IP found for dl.google.com routing.', file=sys.stderr)
    return False


def install_sdk_components(android_home: Path, compile_sdk: str = '36') -> None:
    """Directly download and install Android SDK platform-tools, platforms, and build-tools."""
    android_home = Path(android_home).resolve()
    components = {
        'platform-tools': (
            [
                'https://dl.google.com/android/repository/platform-tools_r36.0.0-linux.zip',
                'https://redirector.gvt1.com/edgedl/android/repository/platform-tools_r36.0.0-linux.zip',
            ],
            android_home / 'platform-tools',
            'platform-tools',
        ),
        f'platforms;android-{compile_sdk}': (
            [
                f'https://dl.google.com/android/repository/platform-{compile_sdk}_r02.zip',
                f'https://redirector.gvt1.com/edgedl/android/repository/platform-{compile_sdk}_r02.zip',
            ],
            android_home / f'platforms/android-{compile_sdk}',
            f'android-{compile_sdk}',
        ),
        'build-tools;36.0.0': (
            [
                'https://dl.google.com/android/repository/build-tools_r36_linux.zip',
                'https://redirector.gvt1.com/edgedl/android/repository/build-tools_r36_linux.zip',
            ],
            android_home / 'build-tools/36.0.0',
            'android-16',
        ),
    }

    with tempfile.TemporaryDirectory() as temp_dir_str:
        temp_dir = Path(temp_dir_str)
        for name, (urls, target_dir, inner_name) in components.items():
            if target_dir.exists():
                print(f'{name} already installed at {target_dir}')
                continue
            print(f'Directly installing {name} to {target_dir}...')
            archive_path = temp_dir / f'{name.replace(";", "_")}.zip'
            download_with_retry(
                urls=urls,
                output_path=archive_path,
                max_retries=3,
                connect_timeout=30,
                max_time=300,
                prefer_ipv4=True,
            )
            extract_dir = temp_dir / f'extract_{name.replace(";", "_")}'
            extract_dir.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(archive_path, 'r') as zf:
                zf.extractall(extract_dir)

            source_folder = extract_dir / inner_name
            if not source_folder.exists():
                subdirs = [d for d in extract_dir.iterdir() if d.is_dir()]
                if subdirs:
                    source_folder = subdirs[0]
                else:
                    raise RuntimeError(f'No directory extracted for {name}')

            target_dir.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source_folder), str(target_dir))
            for item in target_dir.rglob('*'):
                if item.is_file() and not item.name.endswith(('.jar', '.txt', '.prop', '.properties', '.xml', '.zip')):
                    try:
                        item.chmod(item.stat().st_mode | 0o755)
                    except Exception:
                        pass
            print(f'Successfully installed {name} to {target_dir}')


def parse_args(argv=None):
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ensure-network', action='store_true', help='Ensure dl.google.com has accessible route and exit')
    parser.add_argument('--install-components', action='store_true', help='Directly install platform-tools, platforms, and build-tools')
    parser.add_argument('--android-home', type=Path, help='Target ANDROID_HOME for component installation')
    parser.add_argument('--compile-sdk', default='36', help='Compile SDK version (default: 36)')
    parser.add_argument('--primary-url', help='Primary HTTPS download URL')
    parser.add_argument('--fallback-url', help='Fallback HTTPS download URL')
    parser.add_argument('--url', help='Download URL (alias for --primary-url)')
    parser.add_argument('--expected-sha256', help='Expected SHA-256 hash')
    parser.add_argument('--sha256', help='Expected SHA-256 hash (alias for --expected-sha256)')
    parser.add_argument('--output-dir', type=Path, help='Output directory for commandline-tools')
    parser.add_argument('--destination', type=Path, help='Target installation path (alias for --output-dir)')
    parser.add_argument('--tools-revision', help='Revision number for commandline-tools (e.g. 15859902)')
    parser.add_argument('--retries', type=int, default=4, help='Max download attempts (default: 4)')
    parser.add_argument('--connect-timeout', type=int, default=30, help='Connection timeout in seconds')
    parser.add_argument('--max-time', type=int, default=600, help='Max transfer time in seconds')
    parser.add_argument('--ipv4', action='store_true', help='Prefer IPv4 on initial attempt')
    return parser.parse_args(argv)


def main(argv=None):
    """Entry point for CLI execution."""
    args = parse_args(argv)

    if args.ensure_network:
        ensure_dl_google_com_route()
        sys.exit(0)

    if args.install_components:
        if not args.android_home:
            print('Error: --android-home is required when using --install-components', file=sys.stderr)
            sys.exit(2)
        install_sdk_components(args.android_home, args.compile_sdk)
        sys.exit(0)

    urls = []
    if args.primary_url:
        urls.append(args.primary_url)
    elif args.url:
        urls.append(args.url)
    if args.fallback_url and args.fallback_url not in urls:
        urls.append(args.fallback_url)

    if not urls:
        print('Error: At least one download URL (--primary-url or --url) is required.', file=sys.stderr)
        sys.exit(2)

    expected_sha256 = args.expected_sha256 or args.sha256
    if not expected_sha256:
        print('Error: Expected SHA-256 hash (--expected-sha256 or --sha256) is required.', file=sys.stderr)
        sys.exit(2)

    dest = args.output_dir or args.destination
    if not dest:
        print('Error: Target directory (--output-dir or --destination) is required.', file=sys.stderr)
        sys.exit(2)

    dest = Path(dest).resolve()
    if args.tools_revision and dest.name != args.tools_revision:
        dest = dest / args.tools_revision

    try:
        install_tools(
            urls=urls,
            expected_sha256=expected_sha256,
            destination=dest,
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
