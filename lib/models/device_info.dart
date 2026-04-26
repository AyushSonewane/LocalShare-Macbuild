import 'dart:convert';

class DeviceInfo {
  final String id;
  final String name;
  final String ip;
  final int port;
  final DateTime lastSeen;
  /// True when this device is on the Receive tab and ready to accept files.
  final bool isReceiving;
  /// Operating system platform string, e.g. 'android', 'windows', 'ios', 'macos', 'linux'.
  final String platform;

  DeviceInfo({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    required this.lastSeen,
    this.isReceiving = false,
    this.platform = '',
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        ip: json['ip'] as String,
        port: json['port'] as int,
        lastSeen: DateTime.now(),
        isReceiving: (json['recv'] as bool?) ?? false,
        platform: (json['platform'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ip': ip,
        'port': port,
        'recv': isReceiving,
        'platform': platform,
      };

  String toBeacon() => jsonEncode(toJson());

  DeviceInfo copyWith({
    String? id,
    String? name,
    String? ip,   // was missing — needed when IP changes between network switches
    int? port,
    DateTime? lastSeen,
    bool? isReceiving,
    String? platform,
  }) =>
      DeviceInfo(
        id: id ?? this.id,
        name: name ?? this.name,
        ip: ip ?? this.ip,
        port: port ?? this.port,
        lastSeen: lastSeen ?? this.lastSeen,
        isReceiving: isReceiving ?? this.isReceiving,
        platform: platform ?? this.platform,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DeviceInfo && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'DeviceInfo(name=$name, ip=$ip, platform=$platform, receiving=$isReceiving)';
}
