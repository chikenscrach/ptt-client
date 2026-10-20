import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_model.dart';
import '../widgets/terminal_view.dart';
import '../services/ptt_session.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.model});
  final AppModel model;
  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _resuming = false;
  PttSession get session => widget.model.session;
  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send(String key) {
    try {
      session.sendKey(key);
    } catch (error) {
      _error(error);
    }
  }

  void _error(Object error) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(error.toString())));

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final content = _body(context);
      if (size.maxHeight >= 620) return content;
      return SingleChildScrollView(
        child: SizedBox(height: 620, child: content),
      );
    },
  );

  Widget _body(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(
              session.loggedIn
                  ? Icons.verified_user_outlined
                  : Icons.lock_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Text(session.message),
            ),
            FilledButton.icon(
              onPressed:
                  session.busy || session.status == SessionStatus.connecting
                  ? null
                  : () async {
                      try {
                        if (!session.connected) await session.connect();
                        if (mounted && !session.loggedIn) await _login();
                      } catch (error) {
                        if (mounted) _error(error);
                      }
                    },
              icon: const Icon(Icons.login, size: 18),
              label: Text(session.loggedIn ? '已登入' : '連線／登入'),
            ),
            if (session.connected)
              TextButton(
                onPressed: session.busy ? null : session.disconnect,
                child: const Text('中斷連線'),
              ),
            IconButton(
              tooltip: '複製終端畫面',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: session.screen.text));
                _error('已複製目前終端畫面');
              },
              icon: const Icon(Icons.copy_all_outlined),
            ),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '可用鍵盤操作，或縮放、拖曳畫面。手機請使用下方快捷鍵與輸入欄。',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ),
      if (session.busy || session.status == SessionStatus.connecting)
        const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Focus(
            focusNode: _focus,
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent ||
                  !session.connected ||
                  session.busy) {
                return KeyEventResult.ignored;
              }
              final keys = {
                LogicalKeyboardKey.arrowUp: '\x1b[A',
                LogicalKeyboardKey.arrowDown: '\x1b[B',
                LogicalKeyboardKey.arrowRight: '\x1b[C',
                LogicalKeyboardKey.arrowLeft: '\x1b[D',
                LogicalKeyboardKey.enter: '\r',
                LogicalKeyboardKey.numpadEnter: '\r',
                LogicalKeyboardKey.escape: '\x1b',
                LogicalKeyboardKey.backspace: '\x7f',
                LogicalKeyboardKey.pageUp: '\x1b[5~',
                LogicalKeyboardKey.pageDown: '\x1b[6~',
                LogicalKeyboardKey.home: '\x1b[H',
                LogicalKeyboardKey.end: '\x1b[F',
                LogicalKeyboardKey.tab: '\t',
              };
              final mapped = keys[event.logicalKey];
              if (mapped != null) {
                _send(mapped);
                return KeyEventResult.handled;
              }
              if (HardwareKeyboard.instance.isControlPressed) {
                final label = event.logicalKey.keyLabel.toUpperCase();
                if (label.length == 1 &&
                    label.codeUnitAt(0) >= 65 &&
                    label.codeUnitAt(0) <= 90) {
                  _send(String.fromCharCode(label.codeUnitAt(0) - 64));
                  return KeyEventResult.handled;
                }
              }
              if (event.character?.isNotEmpty == true) {
                _send(event.character!);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: GestureDetector(
              onTap: _focus.requestFocus,
              child: TerminalView(screen: session.screen),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final entry in {
              '返回': '\x1b[D',
              '↑': '\x1b[A',
              '↓': '\x1b[B',
              '進入': '\r',
              '空白／繼續': ' ',
              '上一頁': '\x1b[5~',
              '下一頁': '\x1b[6~',
              '取消': '\x1b',
            }.entries)
              OutlinedButton(
                onPressed: !session.connected || session.busy
                    ? null
                    : () => _send(entry.value),
                child: Text(entry.key),
              ),
          ],
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: session.connected && !session.busy,
                  decoration: const InputDecoration(
                    labelText: '終端輸入',
                    hintText: '輸入後按 Enter 送出',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _submit(),
                  inputFormatters: [
                    FilteringTextInputFormatter.deny(
                      RegExp(r'[\x00-\x1f\x7f]'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: '送出',
                onPressed: !session.connected || session.busy ? null : _submit,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ),
    ],
  );

  void _submit() {
    _send('${_input.text}\r');
    _input.clear();
  }

  Future<void> _login() async {
    if (_resuming) return;
    _resuming = true;
    try {
      final credentials = await showDialog<(String, String)>(
        context: context,
        builder: (_) => _LoginDialog(username: widget.model.username),
      );
      if (credentials == null) return;
      await widget.model.rememberUsername(credentials.$1);
      await session.login(credentials.$1, credentials.$2);
    } catch (error) {
      if (mounted) _error(error);
    } finally {
      _resuming = false;
    }
  }
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog({required this.username});
  final String username;
  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  late final _user = TextEditingController(text: widget.username);
  final _password = TextEditingController();
  @override
  void dispose() {
    _user.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, (_user.text.trim(), _password.text));
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('登入 PTT'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _user,
            autofocus: widget.username.isEmpty,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '帳號'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _password,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            autofocus: widget.username.isNotEmpty,
            decoration: const InputDecoration(labelText: '密碼'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 14),
          const Text(
            '帳密透過加密連線直接送往 PTT。只記住帳號，密碼不寫入檔案。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('登入')),
    ],
  );
}
