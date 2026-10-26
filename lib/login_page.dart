import 'package:flutter/material.dart';

import 'backend_client.dart';
import 'session_store.dart';

/// Signs an admin in. Pops with the new [Session] on success, or with null if
/// the user goes back without signing in.
///
/// Shown on top of the lock list, never instead of it: locks already on the
/// phone must open even when the server is down or the login has expired.
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.backend,
    required this.sessions,
    this.reason,
  });

  final BackendClient backend;
  final SessionStore sessions;

  /// Why the user is here, if not simply "first start", e.g. an expired login.
  final String? reason;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your username and password.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await widget.backend.login(username, password);
    if (!mounted) return;

    switch (result) {
      case BackendOk(value: final session):
        try {
          // Save first, then use: a login that isn't remembered would just
          // ask again on the next start.
          await widget.sessions.save(session);
        } catch (error) {
          debugPrint('Could not save the session: $error');
          setState(() {
            _busy = false;
            _error = 'Signed in, but this phone could not store the login.';
          });
          return;
        }
        widget.backend.token = session.token;
        if (mounted) Navigator.pop(context, session);
        return;
      case BackendUnauthorized():
        // Same words whichever was wrong, as the server deliberately won't say.
        _showError('Wrong username or password.');
        // Clearing the password makes a retry a fresh attempt, not an edit.
        _password.clear();
      case BackendUnreachable(:final reason):
        _showError(
          "Can't reach the server ($reason).\n"
          'Is it running, and is the USB cable connected with adb reverse set?',
        );
      case BackendError(:final reason):
        _showError(reason);
    }
  }

  void _showError(String message) {
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (widget.reason != null) ...[
              Text(widget.reason!, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 24),
            ],
            TextField(
              controller: _username,
              enabled: !_busy,
              autofillHints: const [AutofillHints.username],
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _signIn(),
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _signIn,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Sign in'),
            ),
            const SizedBox(height: 32),
            Text(
              'Locks already on this phone still unlock without signing in. '
              'Signing in is what backs them up and brings in locks from '
              'other admins.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
