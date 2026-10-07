class SmbFormDraft {
  final String name;
  final String host;
  final String share;
  final String rootPath;
  final String username;

  const SmbFormDraft({
    this.name = '',
    this.host = '',
    this.share = '',
    this.rootPath = '',
    this.username = '',
  });
}

class SmbFormLogic {
  static String normalizeRootPath(String value) {
    var normalized = value.trim().replaceAll('\\', '/');
    normalized = normalized.replaceAll(RegExp('/+'), '/');
    normalized = normalized.replaceFirst(RegExp(r'^/+'), '');
    normalized = normalized.replaceFirst(RegExp(r'/+$'), '');
    return normalized;
  }

  static bool canBrowseShares(SmbFormDraft draft) => draft.host.trim().isNotEmpty;

  static bool canBrowseRootPath(SmbFormDraft draft) =>
      draft.host.trim().isNotEmpty && draft.share.trim().isNotEmpty;

  static bool canSave(SmbFormDraft draft) =>
      draft.host.trim().isNotEmpty && draft.share.trim().isNotEmpty;

  static String resolveDisplayName(SmbFormDraft draft) {
    final explicitName = draft.name.trim();
    if (explicitName.isNotEmpty) return explicitName;

    final normalizedRoot = normalizeRootPath(draft.rootPath);
    if (normalizedRoot.isNotEmpty) {
      final segments = normalizedRoot.split('/');
      return segments.last;
    }

    final share = draft.share.trim();
    if (share.isNotEmpty) return share;
    return draft.host.trim();
  }
}
