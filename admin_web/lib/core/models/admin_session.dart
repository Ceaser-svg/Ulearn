/// A signed-in administrator.
///
/// Carries the two tokens the transport needs and the one field the shell
/// shows. Nothing else from the sign-in response is kept: the console has no
/// use for it, and holding less of a credential response in memory is cheaper
/// than remembering to clear it.
class AdminSession {
  const AdminSession({
    required this.accessToken,
    required this.refreshToken,
    required this.email,
  });

  final String accessToken;
  final String refreshToken;
  final String email;
}
