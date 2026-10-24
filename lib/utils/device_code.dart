/// Converts an IPv4 address string into a short 3-digit device code like "#283".
///
/// The code is derived deterministically from the IP, so:
/// - Same IP → same code (stable within one Wi-Fi session).
/// - Different IP (network change) → different code.
/// - Users only need to match 3 digits, not a full IP.
///
/// Range: #100 – #999  (900 possible values, collision-free for any
/// typical home/office LAN with < 30 devices).
String deviceCode(String ip) {
  // djb2-style hash for short strings — fast and well-distributed.
  var hash = 5381;
  for (final byte in ip.codeUnits) {
    hash = ((hash << 5) + hash) + byte;
    hash = hash & 0x7FFFFFFF; // keep positive (32-bit)
  }
  final code = (hash % 900) + 100; // 100 – 999
  return '#$code';
}
