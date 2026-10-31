Test-only TLS material for `test/instance_ca_*_test.dart`; the private key (`ca.key`) is deliberately committed and must never be trusted outside tests.

- `ca.pem` / `ca.der`: the same self-signed test CA (SHA-256 `C4:8A:25:0A:F3:B5:20:5C:CC:0E:74:E3:0E:37:6C:6A:CA:E7:CF:28:26:58:F7:98:8D:1C:B1:2F:9E:CA:6A:9E`), valid until 2126; `ca.key` is its key.
- `other_ca.pem`: an unrelated test CA (SHA-256 `67:34:CB:A1:6A:EC:C9:06:2E:02:3B:FA:F0:A4:C8:04:72:7F:89:58:D0:C4:50:5F:04:3C:AF:1F:39:CF:04:33`); its key was discarded.
- The loopback server certificate (`localhost`, `127.0.0.1`) is issued from `ca.key` with `openssl` on every run, valid for two days: a committed leaf would expire, and Apple's verifier refuses leaves valid for more than 825 days.
