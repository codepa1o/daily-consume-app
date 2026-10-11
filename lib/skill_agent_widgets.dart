import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'data/skill_agent_file_picker.dart';

const _agentLinkColor = Color(0xff64765a);

class SkillAgentRichText extends StatefulWidget {
  const SkillAgentRichText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<SkillAgentRichText> createState() => _SkillAgentRichTextState();
}

class _SkillAgentRichTextState extends State<SkillAgentRichText> {
  final _recognizers = <TapGestureRecognizer>[];
  static final _urlPattern = RegExp(r'https?://[^\s<>()，。；]+');

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  List<InlineSpan> _spans() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final match in _urlPattern.allMatches(widget.text)) {
      final rawUrl = match.group(0)!;
      var url = rawUrl;
      while (url.isNotEmpty && '.,;:!?]'.contains(url[url.length - 1])) {
        url = url.substring(0, url.length - 1);
      }
      if (url.isEmpty) continue;
      if (match.start > offset) {
        spans.add(TextSpan(text: widget.text.substring(offset, match.start)));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => openSkillAgentUrl(url);
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: url,
        style: const TextStyle(color: _agentLinkColor, decoration: TextDecoration.underline),
        recognizer: recognizer,
      ));
      if (url.length < rawUrl.length) {
        spans.add(TextSpan(text: rawUrl.substring(url.length)));
      }
      offset = match.end;
    }
    if (offset < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(offset)));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: widget.text));
    return spans;
  }

  @override
  Widget build(BuildContext context) => SelectableText.rich(
        TextSpan(style: widget.style, children: _spans()),
      );
}
