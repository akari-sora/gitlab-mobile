import 'dart:io';

import 'ai_endpoint.dart';

typedef AiInterfaceAddressLister =
    Future<List<InternetAddress>> Function({required bool includeLinkLocal});

/// Lists local addresses while retaining link-local interfaces. The indirection
/// keeps the platform query injectable for tests and future UI wiring.
Future<List<InternetAddress>> listAiInterfaceAddresses({
  required bool includeLinkLocal,
}) async {
  final interfaces = await NetworkInterface.list(
    includeLinkLocal: includeLinkLocal,
  );
  return <InternetAddress>[
    for (final interface in interfaces) ...interface.addresses,
  ];
}

/// Whether a cleartext LAN endpoint needs the explicit per-run confirmation.
///
/// This is a warning check, not the endpoint policy boundary. It deliberately
/// compares only the coarse private blocks available without interface prefix
/// information. Loopback never needs confirmation. An unavailable interface
/// list is unknown and therefore requires confirmation.
Future<bool> cleartextLanNeedsConfirmation(
  AiEndpoint endpoint, {
  AiInterfaceAddressLister listAddresses = listAiInterfaceAddresses,
}) async {
  if (!endpoint.cleartext) return false;
  final target = InternetAddress.tryParse(endpoint.base.host);
  final targetBlock = target == null ? null : _networkBlock(target);
  if (targetBlock == _NetworkBlock.loopback) return false;
  if (targetBlock == null) return true;

  try {
    final addresses = await listAddresses(includeLinkLocal: true);
    return !addresses.any((address) => _networkBlock(address) == targetBlock);
  } on Object {
    return true;
  }
}

enum _NetworkBlock {
  loopback,
  private10,
  private172,
  private192,
  linkLocal4,
  carrierGradeNat,
  uniqueLocal6,
  linkLocal6,
}

_NetworkBlock? _networkBlock(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length == 4) return _ipv4Block(bytes);
  if (bytes.length != 16) return null;
  final mapped =
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (mapped) return _ipv4Block(bytes.sublist(12));
  final loopback = bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
  if (loopback) return _NetworkBlock.loopback;
  if (bytes[0] & 0xfe == 0xfc) return _NetworkBlock.uniqueLocal6;
  if (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) {
    return _NetworkBlock.linkLocal6;
  }
  return null;
}

_NetworkBlock? _ipv4Block(List<int> bytes) {
  final first = bytes[0];
  final second = bytes[1];
  if (first == 127) return _NetworkBlock.loopback;
  if (first == 10) return _NetworkBlock.private10;
  if (first == 172 && second >= 16 && second <= 31) {
    return _NetworkBlock.private172;
  }
  if (first == 192 && second == 168) return _NetworkBlock.private192;
  if (first == 169 && second == 254) return _NetworkBlock.linkLocal4;
  if (first == 100 && second >= 64 && second <= 127) {
    return _NetworkBlock.carrierGradeNat;
  }
  return null;
}
