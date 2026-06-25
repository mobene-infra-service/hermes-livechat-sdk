import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../client.dart';
import '../errors.dart';
import '../internal/message_content.dart';
import '../models.dart';
import '../public_types.dart';
import 'chat_theme.dart';

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
  bool _sessionBlocked = false;
  // Closed-conversation ids whose messages can be pulled in as history on
  // demand. Populated when a session opens; the messages themselves are not
  // loaded until the visitor taps the toggle bar or scrolls to the top.
  List<String> _historyConversationIds = const [];
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
    if (mounted && !_sessionBlocked) {
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
      _sessionBlocked = false;
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
    if (text.isEmpty || _sending || _uploadingImage || _sessionBlocked) {
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
    if (_uploadingImage || _sending || _sessionBlocked) return;
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

  // _loadHistory pulls in one closed conversation at a time, newest first, and
  // reveals it while keeping the visitor anchored. If more history is available
  // the toggle remains so the visitor can keep paging upward.
  Future<void> _loadHistory() async {
    if (_historyLoading || _historyConversationIds.isEmpty) {
      return;
    }
    setState(() => _historyLoading = true);
    final beforeMax =
        _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    final beforePixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    try {
      final conversationId = _historyConversationIds.first;
      final loaded = await _client.conversationMessages(
        conversationId: conversationId,
      );
      if (!mounted) return;
      _historyConversationIds = _historyConversationIds.skip(1).toList();
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
      if (MessageSenderType.fromRaw(message.senderType).isMine) continue;
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
    if (!mounted) return;
    final blocking = _isBlockingIdentityError(error);
    if (blocking && _sessionBlocked) return;
    widget.onError?.call(error);
    setState(() {
      _errorText = error.message ?? error.error.name;
      if (blocking) {
        _sessionBlocked = true;
        _hasSession = false;
        _welcome = null;
      }
    });
  }

  bool _isBlockingIdentityError(HermesLiveChatException error) {
    return error.error == HermesLiveChatError.appInitTokenInvalid ||
        error.error == HermesLiveChatError.appInitTokenExpired;
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
    // 注入固定 Theme：让本页所有 `Theme.of(context).colorScheme` 取色都落到 widget 风格，
    // 不受宿主 App 主题影响。Builder 确保下方 colorScheme 读取到的是注入后的新 Theme。
    return Theme(
      data: hermesChatTheme(),
      child: Builder(
        builder: (context) {
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
                        if (_sessionBlocked) return;
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
                    enabled: !_conversationClosed && !_sessionBlocked,
                    busy: _starting || _sending || _uploadingImage,
                    uploadingImage: _uploadingImage,
                    onSend: _sendText,
                    onAttachImage: _pickAndSendImage,
                  ),
                ],
              ),
            ),
          );
        },
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
    final showHistoryToggle = _historyConversationIds.isNotEmpty;

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
      contentType: MessageContentType.welcome.raw,
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
    required this.createdAt,
    this.imageUrl,
  });

  factory _MessageBubble.fromMessage(Message message) {
    final content = message.content;
    final imageUrl =
        MessageContentType.fromRaw(message.contentType) == MessageContentType.image
            ? content['url']?.toString()
            : null;
    return _MessageBubble(
      text: _textForMessage(message),
      imageUrl: imageUrl,
      mine: MessageSenderType.fromRaw(message.senderType).isMine,
      senderType: message.senderType,
      createdAt: message.createdAt,
    );
  }

  final String text;
  final bool mine;
  final String senderType;
  final int createdAt;
  final String? imageUrl;

  static const _imageMaxWidth = 220.0;
  static const _imageMaxHeight = 320.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 访客气泡 = 主色实底；bot 气泡 = 白底 + 描边（与 widget 卡片化风格一致）。
    final background = mine ? colorScheme.primary : HermesChatPalette.surface;
    final foreground = mine ? colorScheme.onPrimary : colorScheme.onSurface;
    final alignment = mine ? Alignment.centerRight : Alignment.centerLeft;
    final columnAlignment =
        mine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    // 圆角 16，贴近发送方的一角收成小尾角。
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(HermesChatPalette.bubbleRadius),
      topRight: const Radius.circular(HermesChatPalette.bubbleRadius),
      bottomLeft: Radius.circular(
        mine ? HermesChatPalette.bubbleRadius : HermesChatPalette.bubbleTailRadius,
      ),
      bottomRight: Radius.circular(
        mine ? HermesChatPalette.bubbleTailRadius : HermesChatPalette.bubbleRadius,
      ),
    );

    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            crossAxisAlignment: columnAlignment,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: radius,
                  // bot 气泡描边；访客气泡为实底无描边。
                  border: mine
                      ? null
                      : Border.all(color: HermesChatPalette.botBubbleBorder),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
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
                        // 本人消息纯文本展示；对方消息走 flutter_markdown_plus 渲染，
                        // 链接 / 内联图片 / 列表 / 粗斜体均与 widget 对齐。
                        mine
                            ? Text(
                                text,
                                style: DefaultTextStyle.of(context)
                                    .style
                                    .copyWith(color: foreground),
                              )
                            : MarkdownBody(
                                data: text,
                                selectable: false,
                                styleSheet:
                                    _markdownStyleSheet(context, foreground),
                                onTapLink: (_, href, __) =>
                                    unawaited(_openMarkdownLink(href)),
                                imageBuilder: (uri, _, __) =>
                                    _buildMarkdownImage(uri),
                              ),
                    ],
                  ),
                ),
              ),
              if (createdAt > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 3, 4, 0),
                  child: Text(
                    _formatMessageTime(createdAt),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 构造 bot 气泡的 Markdown 样式表，对齐 widget `.md-body`。
///
/// [foreground] 正文主色（bot 气泡为 `#111827`）；链接、行内 code、列表 bullet 的
/// 视觉均与 widget 同源。
MarkdownStyleSheet _markdownStyleSheet(BuildContext context, Color foreground) {
  final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
  return base.copyWith(
    p: TextStyle(color: foreground, fontSize: 15, height: 1.4),
    a: const TextStyle(
      color: HermesChatPalette.primary,
      decoration: TextDecoration.underline,
    ),
    code: TextStyle(
      color: foreground,
      fontSize: 13,
      fontFamily: 'monospace',
      backgroundColor: HermesChatPalette.surfaceMuted,
    ),
    listBullet: TextStyle(color: foreground, fontSize: 15),
    blockSpacing: 6,
    listIndent: 18,
  );
}

/// 点击 markdown 链接时用外部浏览器打开；空链接 / 解析失败 / 启动失败均静默不打断聊天。
Future<void> _openMarkdownLink(String? href) async {
  if (href == null || href.isEmpty) return;
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication)
      .catchError((_) => false);
}

/// 渲染 markdown 正文里的内联图片 `![](url)`：限制最大尺寸、弱面色占位、失败兜底文案。
Widget _buildMarkdownImage(Uri uri) {
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: HermesChatPalette.surfaceMuted,
        child: Image.network(
          uri.toString(),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              '图片加载失败',
              style: TextStyle(color: HermesChatPalette.textMuted),
            ),
          ),
        ),
      ),
    ),
  );
}

String _formatMessageTime(int seconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  return '${_twoDigits(date.month)}-${_twoDigits(date.day)} '
      '${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
}

String _twoDigits(int value) {
  return value.toString().padLeft(2, '0');
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

/// 取消息要展示的文案。IO 薄层：从 content 取出原始字段，规则委托给纯函数 [MessageDisplayRules.displayText]。
String _textForMessage(Message message) {
  return MessageDisplayRules.displayText(
    rawContentType: message.contentType,
    text: message.content['text']?.toString(),
    caption: message.content['caption']?.toString(),
  );
}

int _compareMessages(Message a, Message b) {
  final byTime = a.createdAt.compareTo(b.createdAt);
  if (byTime != 0) return byTime;
  final byRank =
      MessageDisplayRules.sortRank(a.contentType).compareTo(
    MessageDisplayRules.sortRank(b.contentType),
  );
  if (byRank != 0) return byRank;
  return a.uuid.compareTo(b.uuid);
}

String _mimeTypeForImage(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  return 'image/jpeg';
}
