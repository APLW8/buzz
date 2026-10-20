part of 'deep_link.dart';

/// Maximum encoded link size, including its scheme, for the QR-create format.
const maxAgentCreationLinkBytes = 1024;

/// An untrusted, validated draft. Opening it never creates an agent.
class AgentCreationDeepLink extends BuzzDeepLink {
  /// Creates a decoded draft for presentation without submitting it.
  const AgentCreationDeepLink({
    required this.name,
    required this.instructions,
    required this.avatar,
  });

  /// Editable display name.
  final String name;

  /// Editable private instructions, never automatically executed.
  final String instructions;

  /// HTTPS image URL or an emoji/color descriptor, never embedded image bytes.
  final Object avatar;

  /// The preview format already understood by Buzz's avatar renderer.
  String get avatarUrl {
    if (avatar case final String url) return url;
    final value = Map<String, String>.from(avatar as Map);
    return emojiAvatarDataUrl(
      value['emoji']!,
      0xff000000 | int.parse(value['color']!.substring(1), radix: 16),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentCreationDeepLink &&
      name == other.name &&
      instructions == other.instructions &&
      avatarUrl == other.avatarUrl;

  @override
  int get hashCode => Object.hash(name, instructions, avatarUrl);

  @override
  String toString() => 'AgentCreationDeepLink(redacted)';
}

/// Parses a bounded version-1 inline draft; unknown JSON fields are ignored.
AgentCreationDeepLink? parseAgentCreationDeepLink(Uri uri) {
  if (uri.scheme != 'buzz' ||
      uri.host != 'agent' ||
      uri.path != '/new' ||
      uri.hasQuery ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      utf8.encode(uri.toString()).length > maxAgentCreationLinkBytes ||
      !RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(uri.fragment)) {
    return null;
  }
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(uri.fragment))),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded['v'] is! int ||
        decoded['v'] != 1) {
      return null;
    }
    final name = decoded['name'];
    final instructions = decoded['instructions'];
    final avatar = decoded['avatar'];
    if (name is! String ||
        !RegExp(r'^[\w .-]{1,64}$').hasMatch(name.trim()) ||
        instructions is! String) {
      return null;
    }
    Object parsedAvatar;
    if (avatar is String) {
      final image = Uri.tryParse(avatar);
      if (image == null ||
          image.scheme != 'https' ||
          image.host.isEmpty ||
          image.userInfo.isNotEmpty ||
          image.hasFragment) {
        return null;
      }
      parsedAvatar = avatar;
    } else if (avatar is Map<String, dynamic>) {
      final emoji = avatar['emoji'];
      final color = avatar['color'];
      if (emoji is! String ||
          emoji.characters.length != 1 ||
          emoji.runes.length > 16 ||
          color is! String ||
          !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
        return null;
      }
      parsedAvatar = Map<String, String>.unmodifiable({
        'emoji': emoji,
        'color': color,
      });
    } else {
      return null;
    }
    return AgentCreationDeepLink(
      name: name.trim(),
      instructions: instructions,
      avatar: parsedAvatar,
    );
  } on FormatException {
    return null;
  }
}
