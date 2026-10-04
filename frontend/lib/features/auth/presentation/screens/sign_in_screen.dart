import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lottie/lottie.dart';
import 'package:peerpass/app/router.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/widgets/content_width_limiter.dart';
import 'package:peerpass/core/widgets/failure_view.dart';
import 'package:peerpass/features/auth/presentation/providers/auth_providers.dart';
import 'package:peerpass/features/auth/presentation/widgets/credential_fields.dart';
import 'package:peerpass/features/auth/presentation/widgets/field_errors.dart';

/// Where an existing student signs back in.
///
/// A plain form with no local session: the router decides what a successful sign
/// in leads to, so a returning student is sent to onboarding if their profile is
/// still incomplete and home if it is not. The screen does not branch on that.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  Failure? _failure;
  bool _submitting = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
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
          .signIn(email: _email.text, password: _password.text);
    } on Failure catch (failure) {
      // Only a failure that survived to here is worth showing. A success moves
      // the router before this frame finishes, and the guard takes the student
      // away, so nothing below this runs.
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// The API's complaint about the address, rendered under the field.
  String? _fieldError(String field) => fieldErrorFor(_failure, field);

  /// Whatever is left once the field-level messages have been placed.
  Failure? get _bannerFailure => bannerFailureFor(_failure);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
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
                      const _AuthAnimation(asset: 'assets/lotties/Login.json'),
                      const SizedBox(height: AppDimens.xl),
                      Text(
                        'Welcome back',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: AppDimens.sm),
                      Text(
                        'Sign in to your PeerPass account',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppDimens.xxl),
                      CredentialFields(
                        emailController: _email,
                        passwordController: _password,
                        emailError: _fieldError('email'),
                        passwordError: _fieldError('password'),
                        // The server is the authority on whether an address
                        // exists. Autocomplete offers a previously used one
                        // rather than risking the account being named in
                        // traffic as having failed.
                        autofillHints: const [AutofillHints.password],
                        onChanged: () => setState(() {}),
                      ),
                      // A rejection that names a field is shown next to that field
                      // instead of in a banner, so the student is told which input to
                      // change. A banner is still shown when the rejection names no
                      // field, because then there is nowhere better to put it.
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
                            : const Text('Sign in'),
                      ),
                      const SizedBox(height: AppDimens.lg),
                      TextButton(
                        onPressed: _submitting
                            ? null
                            : () => context.go(AppRoutes.signUp),
                        child: const Text('No account yet? Create one'),
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
          maxWidth: AppDimens.signInAnimationMax,
          maxHeight: AppDimens.signInAnimationMax,
        ),
        child: AspectRatio(
          aspectRatio: 1,
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
