import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:image_picker/image_picker.dart';

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
  final _imagePicker = ImagePicker();
  final _messages = <Message>[];
  final _messageKeys = <String>{};
  final _readMarkedMessageIds = <String>{};

  StreamSubscription<HermesLiveChatEvent>? _events;
  ConnectionState _connectionState = ConnectionState.idle;
  String? _welcome;
  String? _errorText;
  bool _loadingWelcome = true;
  bool _starting = false;
  bool _sending = false;
  bool _uploadingImage = false;
  bool _hasSession = false;
  bool _conversationClosed = false;
  // Closed-conversation ids whose messages can be pulled in as history on
  // demand. Populated when a session opens; the messages themselves are not
  // loaded until the visitor taps the toggle bar or scrolls to the top.
  List<String> _historyConversationIds = const [];
  bool _historyExpanded = false;
  bool _historyLoading = false;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? HermesLiveChat.instance;
    _events = _client.events.listen(_handleEvent);
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    _input.dispose();
    _scroll.removeListener(_onScroll);
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
      // Closed conversations are not loaded eagerly: record their ids so the
      // toggle bar knows there is earlier history to pull in on demand.
      try {
        final conversations = await _client.conversations();
        if (!mounted) return;
        _historyConversationIds = _closedConversationIds(
          conversations,
          conversationId,
        );
      } catch (_) {
        // History discovery is best-effort; the active thread and sending still
        // work without it.
      }
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
    if (text.isEmpty || _sending || _uploadingImage || _conversationClosed) {
      return;
    }

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

  Future<void> _pickAndSendImage() async {
    if (_uploadingImage || _sending || _conversationClosed) return;
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
      );
      if (image == null) return;
      final bytes = await image.readAsBytes();
      if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        _handleError(
          const HermesLiveChatException(
            HermesLiveChatError.attachmentTooLarge,
            message: '图片不能超过 10MB',
          ),
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _uploadingImage = true;
        _errorText = null;
      });
      await _ensureSession();
      if (!mounted || !_hasSession) return;
      final mimeType = _mimeTypeForImage(image.name);
      final messages = await _client.sendImageMessages(
        bytes: bytes,
        mimeType: mimeType,
        filename: image.name.isEmpty ? null : image.name,
      );
      if (!mounted) return;
      _mergeMessages(messages);
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
          _uploadingImage = false;
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
      case ConversationUpdated(:final conversation):
        setState(() {
          if (conversation.status == 'closed') {
            _conversationClosed = true;
            _hasSession = false;
          } else {
            _conversationClosed = false;
            _hasSession = true;
          }
        });
      case MessageRead():
        break;
      case HermesError(:final error):
        _handleError(error);
    }
  }

  void _mergeMessages(Iterable<Message> items, {bool scrollToBottom = true}) {
    var changed = false;
    for (final message in items) {
      final hasIdentity =
          message.uuid.isNotEmpty || message.clientMsgId.isNotEmpty;
      if (!hasIdentity || _hasMessageIdentity(message)) continue;
      _rememberMessageKeys(message);
      _messages.add(message);
      changed = true;
    }
    if (changed) {
      _messages.sort(_compareMessages);
      setState(() {});
      if (scrollToBottom) _scrollToBottom();
    }
    _markVisibleMessagesRead();
  }

  bool _hasMessageIdentity(Message message) {
    return (message.uuid.isNotEmpty && _messageKeys.contains(message.uuid)) ||
        (message.clientMsgId.isNotEmpty &&
            _messageKeys.contains(message.clientMsgId));
  }

  void _rememberMessageKeys(Message message) {
    if (message.uuid.isNotEmpty) _messageKeys.add(message.uuid);
    if (message.clientMsgId.isNotEmpty) _messageKeys.add(message.clientMsgId);
  }

  // _closedConversationIds lists the most recent closed conversations whose
  // messages can be pulled in as history, newest first and capped to keep the
  // on-demand fetch bounded. The active conversation (if any) is excluded — it
  // is the live thread, not history.
  List<String> _closedConversationIds(
    List<Conversation> conversations,
    String? activeId,
  ) {
    final ids = <String>[];
    for (final item in conversations) {
      if (ids.length >= 3) break;
      if (item.uuid.isEmpty || item.uuid == activeId) continue;
      if (item.status != 'closed') continue;
      if (!ids.contains(item.uuid)) ids.add(item.uuid);
    }
    return ids;
  }

  // _onScroll pulls in collapsed history when the visitor reaches the very top,
  // mirroring the toggle bar tap. Guarded inside _loadHistory so it fires once.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels <= _scroll.position.minScrollExtent) {
      unawaited(_loadHistory());
    }
  }

  // _loadHistory pulls in earlier closed-conversation messages on demand and
  // reveals them while keeping the visitor anchored: prepending older messages
  // above the viewport would otherwise yank the scroll position, so we offset by
  // the height that appears. The fetch runs once; failures reset so the visitor
  // can retry by tapping the bar again.
  Future<void> _loadHistory() async {
    if (_historyExpanded ||
        _historyLoading ||
        _historyConversationIds.isEmpty) {
      return;
    }
    setState(() => _historyLoading = true);
    final beforeMax =
        _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    final beforePixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    try {
      final loaded = <Message>[];
      for (final conversationId in _historyConversationIds) {
        loaded.addAll(
          await _client.conversationMessages(conversationId: conversationId),
        );
      }
      if (!mounted) return;
      _historyExpanded = true;
      _mergeMessages(loaded, scrollToBottom: false);
      _anchorAfterPrepend(beforeMax, beforePixels);
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
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  // _anchorAfterPrepend keeps the reading position fixed once the prepended
  // history has laid out: the scrollable grew by (afterMax - beforeMax) above
  // the viewport, so we push the offset down by the same amount.
  void _anchorAfterPrepend(double beforeMax, double beforePixels) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final afterMax = _scroll.position.maxScrollExtent;
      final delta = afterMax - beforeMax;
      if (delta <= 0) return;
      _scroll.jumpTo(
        (beforePixels + delta).clamp(
          _scroll.position.minScrollExtent,
          afterMax,
        ),
      );
    });
  }

  void _markVisibleMessagesRead() {
    for (final message in _messages) {
      if (message.senderType == 'visitor') continue;
      if (message.readAt != null) continue;
      if (message.uuid.isEmpty || message.conversationId.isEmpty) continue;
      if (!_readMarkedMessageIds.add(message.uuid)) continue;

      unawaited(
        _client
            .markRead(
          conversationId: message.conversationId,
          messageId: message.uuid,
        )
            .catchError((_) {
          _readMarkedMessageIds.remove(message.uuid);
        }),
      );
    }
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
              busy: _starting || _sending || _uploadingImage,
              uploadingImage: _uploadingImage,
              onSend: _sendText,
              onAttachImage: _pickAndSendImage,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList(ColorScheme colorScheme) {
    if (_loadingWelcome && _messages.isEmpty) {
      return const Center(child: _TypingLoader(label: '正在加载会话'));
    }

    // Show the prefetched welcome whenever there is no active conversation —
    // first visit, or the previous one is closed. Closed-conversation history
    // may sit above it, but the new chat starts with its own greeting.
    final showWelcome = _welcome != null && !_hasActiveConversation();
    final visible = <Message>[..._messages];
    if (showWelcome) {
      visible.add(_welcomeMessage());
      visible.sort(_compareMessages);
    }

    // On a fresh chat earlier closed-conversation history is not loaded yet.
    // While it is unloaded, a "view earlier messages" bar sits at the top;
    // tapping it (or scrolling to the top) pulls the messages in.
    final showHistoryToggle =
        _historyConversationIds.isNotEmpty && !_historyExpanded;

    if (visible.isEmpty && !showHistoryToggle) {
      return Center(
        child: Text(
          '开始输入消息',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    final headerCount = showHistoryToggle ? 1 : 0;
    return RefreshIndicator(
      onRefresh: _loadHistory,
      notificationPredicate: (_) => showHistoryToggle && !_historyLoading,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        itemCount: visible.length + headerCount,
        itemBuilder: (context, index) {
          if (showHistoryToggle && index == 0) {
            return _HistoryToggle(
              loading: _historyLoading,
              onTap: _historyLoading ? null : () => unawaited(_loadHistory()),
            );
          }
          final message = visible[index - headerCount];
          return _MessageBubble.fromMessage(message);
        },
      ),
    );
  }

  bool _hasActiveConversation() {
    final id = _client.currentConversationId;
    return id != null && id.isNotEmpty;
  }

  // _welcomeMessage builds the synthetic greeting bubble. Its createdAt is
  // anchored one second before the forming chat's earliest message so it lands
  // after any closed-conversation history and above the visitor's first message;
  // it falls back to "now" when shown on its own. Re-stamping "now" each render
  // would let the greeting drift below an already-sent message.
  Message _welcomeMessage() {
    return Message(
      uuid: 'welcome',
      conversationId: '',
      clientMsgId: 'welcome',
      senderType: 'system',
      senderId: 'system',
      contentType: 'welcome',
      content: {'text': _welcome},
      createdAt: _welcomeCreatedAt(),
    );
  }

  int _welcomeCreatedAt() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final historyIds = _historyConversationIds.toSet();
    var earliest = -1;
    for (final message in _messages) {
      // Closed-conversation history is older and stays above the welcome.
      if (historyIds.contains(message.conversationId)) continue;
      if (earliest < 0 || message.createdAt < earliest) {
        earliest = message.createdAt;
      }
    }
    if (earliest < 0) return now;
    final anchored = earliest - 1;
    return anchored < now ? anchored : now;
  }
}

class _HistoryToggle extends StatelessWidget {
  const _HistoryToggle({required this.loading, this.onTap});

  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final label = loading ? '正在加载更早消息...' : '查看更早消息';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: TextButton(
          onPressed: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
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

  static const _imageMaxWidth = 220.0;
  static const _imageMaxHeight = 320.0;

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
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _imageMaxWidth,
                        maxHeight: _imageMaxHeight,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ColoredBox(
                          color: colorScheme.surfaceContainerHighest,
                          child: Image.network(
                            imageUrl!,
                            width: _imageMaxWidth,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                '图片加载失败',
                                style: TextStyle(color: foreground),
                              ),
                            ),
                          ),
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
    required this.uploadingImage,
    required this.onSend,
    required this.onAttachImage,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool busy;
  final bool uploadingImage;
  final VoidCallback onSend;
  final VoidCallback onAttachImage;

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
            IconButton(
              tooltip: '发送图片',
              icon: const Icon(Icons.image_outlined),
              onPressed: enabled && !busy ? onAttachImage : null,
            ),
            const SizedBox(width: 4),
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
                  ? _ButtonTypingDots(
                      color: colorScheme.onPrimary,
                      icon: uploadingImage ? Icons.image_outlined : null,
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

class _TypingLoader extends StatelessWidget {
  const _TypingLoader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: colorScheme.shadow.withValues(alpha: 0.08),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  child: const Icon(Icons.support_agent, size: 18),
                ),
                const SizedBox(width: 10),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(18),
                      topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(6),
                      bottomRight: Radius.circular(18),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 10,
                    ),
                    child: _TypingDots(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

class _ButtonTypingDots extends StatelessWidget {
  const _ButtonTypingDots({required this.color, this.icon});

  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 18,
      child: Center(
        child: icon == null
            ? _TypingDots(
                color: color,
                dotSize: 5,
                spacing: 3,
              )
            : Icon(
                icon,
                size: 18,
                color: color,
              ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots({
    required this.color,
    this.dotSize = 6,
    this.spacing = 4,
  });

  final Color color;
  final double dotSize;
  final double spacing;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1050),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final wave =
                (math.sin((_controller.value + index * 0.16) * math.pi * 2) +
                        1) /
                    2;
            final scale = 0.72 + wave * 0.36;
            final opacity = 0.35 + wave * 0.65;
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.spacing / 2),
              child: Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: scale,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.color,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox.square(dimension: widget.dotSize),
                  ),
                ),
              ),
            );
          }),
        );
      },
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

String _mimeTypeForImage(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  return 'image/jpeg';
}
