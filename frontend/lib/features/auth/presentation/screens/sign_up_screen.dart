import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lottie/lottie.dart';
import 'package:peerpass/app/router.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/utils/validators.dart';
import 'package:peerpass/core/widgets/content_width_limiter.dart';
import 'package:peerpass/core/widgets/failure_view.dart';
import 'package:peerpass/features/auth/presentation/providers/auth_providers.dart';
import 'package:peerpass/features/auth/presentation/widgets/credential_fields.dart';
import 'package:peerpass/features/auth/presentation/widgets/field_errors.dart';

/// Where a new student creates an account.
///
/// Collects an address and a password and nothing else. A name is asked for
/// immediately afterwards, in the wizard, because registration is also what
/// grants the session -- and requiring a name before the account exists would
/// mean a student who abandons the form has an account they never finished
/// making, or no account at all depending on how the form is wired. The wizard
/// is the better place for it: it is the part that can be resumed.
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  Failure? _failure;
  bool _submitting = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_submitting) return;

    setState(() {
      _submitting = true;
      _failure = null;
    });

    try {
      await ref
          .read(authControllerProvider)
          .register(email: _email.text, password: _password.text);
    } on Failure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// The API's complaint about a named field, rendered under that field.
  String? _fieldError(String field) => fieldErrorFor(_failure, field);

  /// Whatever is left once the field-level messages have been placed.
  Failure? get _bannerFailure => bannerFailureFor(_failure);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(leading: const BackButton()),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ContentWidthLimiter(
              child: Padding(
                padding: const EdgeInsets.all(AppDimens.xl),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _AuthAnimation(asset: 'assets/lotties/SignUp.json'),
                      const SizedBox(height: AppDimens.xl),
                      Text(
                        'Create your account',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: AppDimens.sm),
                      Text(
                        'It takes a moment',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppDimens.xxl),
                      CredentialFields(
                        emailController: _email,
                        passwordController: _password,
                        autofillHints: const [AutofillHints.newPassword],
                        emailError: _fieldError('email'),
                        passwordError: _fieldError('password'),
                        onChanged: () => setState(() {}),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _confirmation,
                        enabled: !_submitting,
                        autocorrect: false,
                        obscureText: true,
                        // A different hint from the field above: this one must not
                        // be the browser's idea of "the" password, or autofill
                        // fills it with something that then fails to match.
                        autofillHints: const [],
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: 'Confirm password',
                          prefixIcon: const Icon(Icons.lock_reset_outlined),
                          // The API has no separate confirmation field, so its
                          // complaint about the password belongs here too: it is
                          // the field the student is about to correct.
                          errorText: _fieldError('password'),
                        ),
                        onChanged: (_) => setState(() {}),
                        validator: (value) =>
                            Validators.passwordsMatch(_password.text, value),
                      ),
                      if (_bannerFailure case final banner?) ...[
                        const SizedBox(height: AppDimens.lg),
                        FailureView(failure: banner),
                      ],
                      const SizedBox(height: AppDimens.xl),
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Create account'),
                      ),
                      const SizedBox(height: AppDimens.lg),
                      TextButton(
                        onPressed: _submitting
                            ? null
                            : () => context.go(AppRoutes.signIn),
                        child: const Text('Already have an account? Sign in'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthAnimation extends StatelessWidget {
  const _AuthAnimation({required this.asset});

  final String asset;

  @override
  Widget build(BuildContext context) {
    final reducedMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppDimens.signUpAnimationMaxWidth,
          maxHeight: AppDimens.signUpAnimationMaxHeight,
        ),
        child: AspectRatio(
          aspectRatio: 1934 / 1562,
          child: Lottie.asset(
            asset,
            animate: !reducedMotion,
            repeat: true,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
