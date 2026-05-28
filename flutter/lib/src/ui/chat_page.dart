import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;

import '../client.dart';
import '../errors.dart';
import '../models.dart';
import '../public_types.dart';

class HermesLiveChatLauncher extends StatelessWidget {
  const HermesLiveChatLauncher({
    super.key,
    required this.identity,
    this.title = '在线客服',
    this.locale,
    this.label = '联系客服',
    this.icon = const Icon(Icons.support_agent),
    this.startSessionOnOpen = false,
    this.onError,
  });

  final VisitorIdentity identity;
  final String title;
  final String? locale;
  final String label;
  final Widget icon;
  final bool startSessionOnOpen;
  final ValueChanged<HermesLiveChatException>? onError;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      icon: icon,
      label: Text(label),
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => HermesLiveChatPage(
              identity: identity,
              title: title,
              locale: locale,
              startSessionOnOpen: startSessionOnOpen,
              onError: onError,
            ),
          ),
        );
      },
    );
  }
}

class HermesLiveChatPage extends StatefulWidget {
  const HermesLiveChatPage({
    super.key,
    required this.identity,
    this.title = '在线客服',
    this.locale,
    this.welcome,
    this.startSessionOnOpen = false,
    this.client,
    this.onError,
  });

  final VisitorIdentity identity;
  final String title;
  final String? locale;
  final String? welcome;
  final bool startSessionOnOpen;
  final HermesLiveChat? client;
  final ValueChanged<HermesLiveChatException>? onError;

  @override
  State<HermesLiveChatPage> createState() => _HermesLiveChatPageState();
}

class _HermesLiveChatPageState extends State<HermesLiveChatPage> {
  late final HermesLiveChat _client;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <Message>[];
  final _messageKeys = <String>{};

  StreamSubscription<HermesLiveChatEvent>? _events;
  ConnectionState _connectionState = ConnectionState.idle;
  String? _welcome;
  String? _errorText;
  bool _loadingWelcome = true;
  bool _starting = false;
  bool _sending = false;
  bool _hasSession = false;
  bool _conversationClosed = false;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? HermesLiveChat.instance;
    _events = _client.events.listen(_handleEvent);
    _bootstrap();
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (widget.startSessionOnOpen && mounted) {
      await _ensureSession();
    }
    if (mounted) {
      await _loadWelcome();
    }
  }

  Future<void> _loadWelcome() async {
    try {
      final welcome = widget.welcome ??
          await _client.prefetchWelcome(locale: widget.locale);
      if (!mounted) return;
      setState(() {
        _welcome = welcome.trim().isEmpty ? null : welcome.trim();
        _errorText = null;
      });
    } on HermesLiveChatException catch (error) {
      _handleError(error);
    } catch (error) {
      _handleError(
        HermesLiveChatException(
          HermesLiveChatError.unknown,
          message: error.toString(),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingWelcome = false;
        });
      }
    }
  }

  Future<void> _ensureSession() async {
    if (_hasSession || _starting) return;
    setState(() {
      _starting = true;
      _errorText = null;
    });
    try {
      await _client.startSession(widget.identity);
      if (!mounted) return;
      _hasSession = true;
      final conversationId = _client.currentConversationId;
      if (conversationId != null && conversationId.isNotEmpty) {
        final history = await _client.history(conversationId: conversationId);
        if (!mounted) return;
        _mergeMessages(history);
      }
    } on HermesLiveChatException catch (error) {
      _handleError(error);
    } catch (error) {
      _handleError(
        HermesLiveChatException(
          HermesLiveChatError.unknown,
          message: error.toString(),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _starting = false;
        });
      }
    }
  }

  Future<void> _sendText() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || _conversationClosed) return;

    _input.clear();
    setState(() {
      _sending = true;
      _errorText = null;
    });

    try {
      await _ensureSession();
      if (!mounted || !_hasSession) {
        if (mounted) _input.text = text;
        return;
      }
      final messages = await _client.sendTextMessages(text);
      if (!mounted) return;
      _mergeMessages(messages);
    } on HermesLiveChatException catch (error) {
      if (mounted) _input.text = text;
      _handleError(error);
    } catch (error) {
      if (mounted) _input.text = text;
      _handleError(
        HermesLiveChatException(
          HermesLiveChatError.unknown,
          message: error.toString(),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  void _handleEvent(HermesLiveChatEvent event) {
    if (!mounted) return;
    switch (event) {
      case ConnectionStateChanged(:final state):
        setState(() {
          _connectionState = state;
        });
      case MessageReceived(:final message):
        _mergeMessages([message]);
        if (message.senderType != 'visitor') {
          final conversationId = message.conversationId;
          unawaited(
            _client
                .markRead(
                  conversationId: conversationId,
                  messageId: message.uuid,
                )
                .catchError((_) {}),
          );
        }
      case ConversationUpdated(:final conversation):
        setState(() {
          _conversationClosed = false;
          if (conversation.status == 'closed') {
            _hasSession = true;
          }
        });
      case MessageRead():
        break;
      case HermesError(:final error):
        _handleError(error);
    }
  }

  void _mergeMessages(Iterable<Message> items) {
    var changed = false;
    for (final message in items) {
      final key = message.uuid.isNotEmpty ? message.uuid : message.clientMsgId;
      if (key.isEmpty || _messageKeys.contains(key)) continue;
      _messageKeys.add(key);
      _messages.add(message);
      changed = true;
    }
    if (!changed) return;
    _messages.sort(_compareMessages);
    setState(() {});
    _scrollToBottom();
  }

  void _handleError(HermesLiveChatException error) {
    widget.onError?.call(error);
    if (!mounted) return;
    setState(() {
      _errorText = error.message ?? error.error.name;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: _ConnectionBar(state: _connectionState),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_errorText != null)
              _ErrorBanner(
                message: _errorText!,
                onClose: () {
                  setState(() {
                    _errorText = null;
                  });
                },
              ),
            Expanded(
              child: _buildMessageList(colorScheme),
            ),
            _Composer(
              controller: _input,
              enabled: !_conversationClosed,
              busy: _starting || _sending,
              onSend: _sendText,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList(ColorScheme colorScheme) {
    if (_loadingWelcome && _messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasPersistedWelcome =
        _messages.any((message) => message.contentType == 'welcome');
    final hasWelcome = _welcome != null &&
        !_hasSession &&
        _messages.isEmpty &&
        !hasPersistedWelcome;
    final count = _messages.length + (hasWelcome ? 1 : 0);
    if (count == 0) {
      return Center(
        child: Text(
          '开始输入消息',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: count,
      itemBuilder: (context, index) {
        if (hasWelcome && index == 0) {
          return _MessageBubble(
            text: _welcome!,
            mine: false,
            senderType: 'system',
          );
        }
        final message = _messages[index - (hasWelcome ? 1 : 0)];
        return _MessageBubble.fromMessage(message);
      },
    );
  }
}

class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar({required this.state});

  final ConnectionState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final text = switch (state) {
      ConnectionState.connecting => '连接中',
      ConnectionState.connected => '已连接',
      ConnectionState.disconnected => '已断开',
      ConnectionState.idle => '未连接',
    };
    final color = switch (state) {
      ConnectionState.connected => colorScheme.primary,
      ConnectionState.connecting => colorScheme.tertiary,
      ConnectionState.disconnected => colorScheme.error,
      ConnectionState.idle => colorScheme.onSurfaceVariant,
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colorScheme.onErrorContainer),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: '关闭',
              icon: Icon(Icons.close, color: colorScheme.onErrorContainer),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.text,
    required this.mine,
    required this.senderType,
    this.imageUrl,
  });

  factory _MessageBubble.fromMessage(Message message) {
    final content = message.content;
    final imageUrl =
        message.contentType == 'image' ? content['url']?.toString() : null;
    return _MessageBubble(
      text: _textForMessage(message),
      imageUrl: imageUrl,
      mine: message.senderType == 'visitor',
      senderType: message.senderType,
    );
  }

  final String text;
  final bool mine;
  final String senderType;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background =
        mine ? colorScheme.primary : colorScheme.surfaceContainerHighest;
    final foreground = mine ? colorScheme.onPrimary : colorScheme.onSurface;
    final alignment = mine ? Alignment.centerRight : Alignment.centerLeft;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(12),
      topRight: const Radius.circular(12),
      bottomLeft: Radius.circular(mine ? 12 : 3),
      bottomRight: Radius.circular(mine ? 3 : 12),
    );

    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: DecoratedBox(
            decoration: BoxDecoration(color: background, borderRadius: radius),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (imageUrl != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        imageUrl!,
                        width: 220,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Text(
                          '图片加载失败',
                          style: TextStyle(color: foreground),
                        ),
                      ),
                    ),
                  if (text.isNotEmpty)
                    Text(
                      text,
                      style: TextStyle(color: foreground),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled && !busy,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: enabled ? '输入消息' : '会话已结束',
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.45),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '发送',
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              onPressed: enabled && !busy ? onSend : null,
            ),
          ],
        ),
      ),
    );
  }
}

String _textForMessage(Message message) {
  if (message.contentType == 'text') {
    return message.content['text']?.toString() ?? '';
  }
  if (message.contentType == 'welcome' || message.contentType == 'close') {
    return message.content['text']?.toString() ?? '';
  }
  if (message.contentType == 'image') {
    return message.content['caption']?.toString() ?? '';
  }
  return message.content['text']?.toString() ?? '[${message.contentType}]';
}

int _compareMessages(Message a, Message b) {
  final byTime = a.createdAt.compareTo(b.createdAt);
  if (byTime != 0) return byTime;
  final byRank = _messageSortRank(a).compareTo(_messageSortRank(b));
  if (byRank != 0) return byRank;
  return a.uuid.compareTo(b.uuid);
}

int _messageSortRank(Message message) {
  if (message.contentType == 'welcome') return 0;
  if (message.contentType == 'close') return 2;
  return 1;
}
