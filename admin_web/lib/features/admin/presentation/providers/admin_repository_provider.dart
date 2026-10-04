import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/features/admin/data/repositories/admin_repository.dart';
import 'package:peerpass_admin/features/admin/data/repositories/http_admin_repository.dart';

/// The console's data source.
///
/// Watching the transport rather than holding it means a test can replace the
/// repository wholesale and no screen has to know how it is built.
final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => HttpAdminRepository(ref.watch(adminApiClientProvider)),
);
