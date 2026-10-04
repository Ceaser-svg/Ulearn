import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';

/// Resolves the profile's stored university identifier to its display record.
///
/// The profile API intentionally stores only the public identifier. Keeping the
/// lookup here means the Profile screen never has to know the wire shape or
/// display an internal ID when reference data is unavailable.
// ignore: specify_nonobvious_property_types
final universityByIdProvider = FutureProvider.family<String?, String>((
  ref,
  universityId,
) {
  if (universityId.isEmpty) return null;

  return ref.read(authRepositoryProvider).universityNameById(universityId);
});
