import 'dart:async';

import 'package:flutter/material.dart';

import 'data/api_client.dart';
import 'data/skill_agent.dart';
import 'data/skill_agent_file_picker.dart';
import 'skill_agent_widgets.dart';

const _sage = Color(0xff64765a);
const _sageSoft = Color(0xffe9eee4);
const _paper = Color(0xfff6f5ef);
const _surface = Color(0xfffffefa);
const _line = Color(0xffe8e7df);
const _muted = Color(0xff70756b);

Widget _workspace(List<Widget> children) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          children: children,
        ),
      ),
    );

Widget _surfaceCard({required Widget child, EdgeInsets padding = const EdgeInsets.all(18)}) =>
    Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(22),
      ),
      child: child,
    );

String _friendlyError(Object error) => error is ApiException
    ? error.message
    : error is StateError
        ? error.message.toString()
        : '操作失败，请重试';

class SkillAgentRunsPage extends StatefulWidget {
  const SkillAgentRunsPage({super.key});
  @override
  State<SkillAgentRunsPage> createState() => _SkillAgentRunsPageState();
}

class _SkillAgentRunsPageState extends State<SkillAgentRunsPage> {
  final _api = SkillAgentApi.instance;
  final _skill = TextEditingController(text: defaultSkillAgentSkillUrl);
  final _question = TextEditingController();
  List<SkillAgentRun> _runs = [];
  SkillAgentRun? _selected;
  int? _owner;
  bool _busy = false, _loading = true;
  String _answer = '', _error = '', _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    ApiClient.instance.addListener(_accountChanged);
    _load();
  }

  void _accountChanged() {
    final nextOwner = ApiClient.instance.account?.id;
    if (nextOwner == _owner || !mounted) return;
    _owner = nextOwner;
    setState(() {
      _runs = [];
      _selected = null;
      _answer = '';
      _error = '';
      _loading = nextOwner != null;
    });
    if (nextOwner != null) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final runs = await _api.runs();
      if (mounted) setState(() => _runs = runs);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _start({String? skillUrl, String? question}) async {
    final url = (skillUrl ?? _skill.text).trim();
    final prompt = (question ?? _question.text).trim();
    if (url.isEmpty || prompt.isEmpty || _busy) return;
    _skill.text = url;
    _question.text = prompt;
    setState(() {
      _busy = true;
      _answer = '';
      _error = '';
      _statusMessage = '正在连接…';
      _selected = null;
    });
    try {
      await for (final event in _api.startRun(url, prompt)) {
        if (!mounted) return;
        final kind = event['event'] as String? ?? '';
        if (kind == 'status') {
          setState(() => _statusMessage = event['message'] as String? ?? '正在准备…');
        } else if (kind == 'delta') {
          _statusMessage = '正在生成回答…';
          setState(() => _answer += event['content'] as String? ?? '');
        } else if (kind == 'done') {
          setState(() => _answer = event['content'] as String? ?? _answer);
        } else if (kind == 'error') {
          setState(() {
            _answer = event['partial'] as String? ?? _answer;
            _error = event['message'] as String? ?? '运行失败';
          });
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  Future<void> _selectRun(int id) async {
    try {
      final run = await _api.run(id);
      if (mounted) setState(() => _selected = run);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _rerun() async {
    final selected = _selected;
    if (selected == null) return;
    try {
      final input = await _api.rerun(selected.id);
      await _start(
          skillUrl: input['skill_url'] as String? ?? '',
          question: input['question'] as String? ?? '');
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  @override
  void dispose() {
    ApiClient.instance.removeListener(_accountChanged);
    _skill.dispose();
    _question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _workspace([
        _surfaceCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('单次运行', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('快速测试 Skill；回答会逐段显示并保存到运行记录。',
                style: TextStyle(color: _muted)),
            const SizedBox(height: 16),
            TextField(
              controller: _skill,
              maxLength: 2000,
              decoration: const InputDecoration(
                  labelText: 'GitHub SKILL.md 链接',
                  border: OutlineInputBorder(),
                  counterText: ''),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _question,
              minLines: 2,
              maxLines: 5,
              maxLength: 12000,
              decoration: const InputDecoration(
                  labelText: '测试问题', border: OutlineInputBorder()),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : () => _start(),
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(_busy ? '运行中…' : '开始运行'),
              ),
            ),
          ]),
        ),
        if (_error.isNotEmpty) _notice(_error, error: true),
        if (_busy && _answer.isEmpty)
          _surfaceCard(
            child: Row(children: [
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text(_statusMessage, style: const TextStyle(color: _muted)),
            ]),
          ),
        if (_answer.isNotEmpty)
          _surfaceCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('当前回答', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              SkillAgentRichText(_answer, style: const TextStyle(height: 1.55)),
              if (_busy) const LinearProgressIndicator(color: _sage),
            ]),
          ),
        Row(children: [
          Expanded(child: Text('最近运行', style: Theme.of(context).textTheme.titleLarge)),
          IconButton(onPressed: _load, tooltip: '刷新', icon: const Icon(Icons.refresh_rounded)),
        ]),
        if (_loading)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
        else if (_runs.isEmpty)
          _emptyCard('还没有运行记录')
        else
          ..._runs.map((run) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _surfaceCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    leading: Icon(run.status == 'success' ? Icons.check_circle_outline : Icons.error_outline,
                        color: run.status == 'success' ? _sage : const Color(0xffad5b43)),
                    title: Text(run.question, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${run.model} · ${(run.latencyMs / 1000).toStringAsFixed(1)} 秒 · ${_dateLabel(run.createdAt)}'
                        '${run.searchUsed ? ' · 搜索' : ''}${run.ragUsed ? ' · 知识库' : ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    onTap: () => _selectRun(run.id),
                  ),
                ),
              )),
        if (_selected != null) _runDetail(_selected!),
      ]);

  Widget _runDetail(SkillAgentRun run) => _surfaceCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('运行 #${run.id}', style: Theme.of(context).textTheme.titleLarge)),
            TextButton.icon(onPressed: _busy ? null : _rerun, icon: const Icon(Icons.replay_rounded), label: const Text('重跑')),
          ]),
          Text(run.skillUrl, style: const TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(height: 12),
          Text(run.question, style: const TextStyle(fontWeight: FontWeight.w600)),
          const Divider(height: 24),
          SkillAgentRichText(run.answer.isEmpty ? run.error : run.answer,
              style: const TextStyle(height: 1.55)),
          if (run.error.isNotEmpty && run.answer.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(run.error, style: const TextStyle(color: Color(0xffa4513c)))),
        ]),
      );
}

class SkillAgentKnowledgePage extends StatefulWidget {
  const SkillAgentKnowledgePage({super.key});
  @override
  State<SkillAgentKnowledgePage> createState() => _SkillAgentKnowledgePageState();
}

class _SkillAgentKnowledgePageState extends State<SkillAgentKnowledgePage> {
  final _api = SkillAgentApi.instance;
  List<SkillAgentDocument> _documents = [];
  Timer? _timer;
  int? _owner;
  bool _loading = true, _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    ApiClient.instance.addListener(_accountChanged);
    _load();
  }

  void _accountChanged() {
    final nextOwner = ApiClient.instance.account?.id;
    if (nextOwner == _owner || !mounted) return;
    _owner = nextOwner;
    _timer?.cancel();
    _timer = null;
    setState(() {
      _documents = [];
      _error = '';
      _loading = nextOwner != null;
    });
    if (nextOwner != null) _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _api.documents();
      if (!mounted) return;
      setState(() {
        _documents = rows;
        _loading = false;
      });
      final pending = rows.any((item) => item.status == 'queued' || item.status == 'indexing');
      if (pending && _timer == null) {
        _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
      } else if (!pending) {
        _timer?.cancel();
        _timer = null;
      }
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = _friendlyError(error); });
    }
  }

  Future<void> _poll() async => _load();

  Future<void> _upload() async {
    try {
      final file = await pickSkillAgentFile();
      if (file == null || !mounted) return;
      setState(() { _busy = true; _error = ''; });
      await _api.upload(file);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _details(SkillAgentDocument document) async {
    try {
      final result = await _api.document(document.id);
      if (!mounted) return;
      final chunks = result['chunks'] is List ? result['chunks'] as List : const [];
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .78,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(children: [
                  const Icon(Icons.description_outlined, color: _sage),
                  const SizedBox(width: 10),
                  Expanded(child: Text(document.filename, style: const TextStyle(fontWeight: FontWeight.w700))),
                ]),
              ),
              Expanded(
                child: chunks.isEmpty
                    ? const Center(child: Text('索引完成后可查看文本切片'))
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: chunks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final row = chunks[index] as Map;
                          final page = (row['page_number'] as num?)?.toInt() ?? 0;
                          return _surfaceCard(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('片段 ${index + 1}${page > 0 ? ' · 第 $page 页' : ''}', style: const TextStyle(color: _muted, fontSize: 12)),
                              const SizedBox(height: 8),
                              SelectableText(row['content'] as String? ?? ''),
                            ]),
                          );
                        },
                      ),
              ),
            ]),
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _delete(SkillAgentDocument document) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除这份资料？'),
            content: Text('${document.filename} 及其索引切片将被删除。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    try {
      await _api.deleteDocument(document.id);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _reindex(SkillAgentDocument document) async {
    try {
      await _api.reindexDocument(document.id);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    ApiClient.instance.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _workspace([
        _surfaceCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('本地知识库', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('上传 Markdown、TXT 或 PDF，索引完成后会自动参与对话和评测检索。单个文件最大 10 MB。',
                style: TextStyle(color: _muted)),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : _upload,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_file_rounded),
                label: Text(_busy ? '上传中…' : '选择资料'),
              ),
            ),
          ]),
        ),
        if (_error.isNotEmpty) _notice(_error, error: true),
        Row(children: [
          Expanded(child: Text('已上传资料', style: Theme.of(context).textTheme.titleLarge)),
          IconButton(onPressed: _load, tooltip: '刷新', icon: const Icon(Icons.refresh_rounded)),
        ]),
        if (_loading)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
        else if (_documents.isEmpty)
          _emptyCard('知识库还是空的，选择一份资料开始建立索引。')
        else
          ..._documents.map((document) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _surfaceCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    leading: Icon(_documentIcon(document.fileType), color: _sage),
                    title: Text(document.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${_statusLabel(document.status)} · ${document.chunkCount} 个片段${document.error.isEmpty ? '' : ' · ${document.error}'}',
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => _details(document),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) => value == 'reindex' ? _reindex(document) : _delete(document),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'reindex', child: Text('重新索引')),
                        PopupMenuItem(value: 'delete', child: Text('删除资料')),
                      ],
                    ),
                  ),
                ),
              )),
      ]);
}

class SkillAgentEvaluationsPage extends StatefulWidget {
  const SkillAgentEvaluationsPage({super.key});
  @override
  State<SkillAgentEvaluationsPage> createState() => _SkillAgentEvaluationsPageState();
}

class _SkillAgentEvaluationsPageState extends State<SkillAgentEvaluationsPage> {
  final _api = SkillAgentApi.instance;
  List<SkillAgentSuite> _suites = [];
  int? _selectedId;
  int? _owner;
  Map<String, dynamic> _suiteDetail = {}, _report = {};
  bool _loading = true, _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    ApiClient.instance.addListener(_accountChanged);
    _load();
  }

  void _accountChanged() {
    final nextOwner = ApiClient.instance.account?.id;
    if (nextOwner == _owner || !mounted) return;
    _owner = nextOwner;
    setState(() {
      _suites = [];
      _selectedId = null;
      _suiteDetail = {};
      _report = {};
      _error = '';
      _loading = nextOwner != null;
    });
    if (nextOwner != null) _load();
  }

  Future<void> _load({int? select}) async {
    try {
      final rows = await _api.suites();
      if (!mounted) return;
      setState(() {
        _suites = rows;
        _selectedId = select ?? (_suites.any((item) => item.id == _selectedId)
            ? _selectedId
            : (_suites.isEmpty ? null : _suites.first.id));
        _loading = false;
      });
      if (_selectedId != null) await _loadSuite(_selectedId!);
    } catch (error) {
      if (mounted) setState(() { _error = _friendlyError(error); _loading = false; });
    }
  }

  Future<void> _loadSuite(int id) async {
    try {
      final suite = await _api.suite(id);
      if (mounted && id == _selectedId) setState(() => _suiteDetail = suite);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _createSuite() async {
    final values = await _showFields(context, '创建测试集', const [
      ('name', '测试集名称'),
      ('skill_url', 'GitHub SKILL.md 链接'),
      ('description', '测试集说明（可留空）'),
    ], defaults: const {'skill_url': defaultSkillAgentSkillUrl},
        optional: const {'description'});
    if (values == null) return;
    try {
      final row = await _api.createSuite(values['name']!, values['skill_url']!, values['description']!);
      await _load(select: (row['id'] as num).toInt());
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _addCase() async {
    final suiteId = _selectedId;
    if (suiteId == null) return;
    final values = await _showFields(context, '添加测试用例', const [
      ('title', '用例名称'),
      ('question', '测试问题'),
      ('expected_behavior', '期望行为'),
      ('scoring_focus', '评分重点'),
    ]);
    if (values == null) return;
    try {
      await _api.createCase(suiteId, values);
      await _loadSuite(suiteId);
      await _load(select: suiteId);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _startEvaluation() async {
    final suiteId = _selectedId;
    if (suiteId == null || _busy) return;
    setState(() { _busy = true; _error = ''; _report = {}; });
    try {
      final response = await _api.runSuite(suiteId);
      final runId = (response['eval_run_id'] as num).toInt();
      await _pollEvaluation(runId);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted) await _load(select: suiteId);
    }
  }

  Future<void> _pollEvaluation(int id) async {
    while (mounted) {
      final report = await _api.evalRun(id);
      if (!mounted) return;
      setState(() => _report = report);
      final status = (report['run'] as Map?)?['status'] as String? ?? '';
      if (status == 'completed' || status == 'failed') return;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _openReport(int id) async {
    try {
      final report = await _api.evalRun(id);
      if (mounted) setState(() => _report = report);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  @override
  void dispose() {
    ApiClient.instance.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cases = _suiteDetail['cases'] is List ? _suiteDetail['cases'] as List : const [];
    final selectedSuites = _suites.where((item) => item.id == _selectedId).toList();
    final recent = selectedSuites.isEmpty
        ? const <Map<String, dynamic>>[]
        : selectedSuites.first.recentRuns;
    return _workspace([
      Row(children: [
        Expanded(child: Text('测试集与 Judge 评分', style: Theme.of(context).textTheme.titleLarge)),
        FilledButton.tonalIcon(onPressed: _createSuite, icon: const Icon(Icons.add), label: const Text('新建测试集')),
      ]),
      const SizedBox(height: 8),
      const Text('每个用例会对比原始回答和搜索 / 知识库增强回答，并由 Judge 按六个维度评分。',
          style: TextStyle(color: _muted)),
      if (_error.isNotEmpty) _notice(_error, error: true),
      if (_loading)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
      else if (_suites.isEmpty)
        _emptyCard('还没有测试集')
      else ...[
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final suite in _suites)
            ChoiceChip(
              label: Text('${suite.name} · ${suite.caseCount}'),
              selected: suite.id == _selectedId,
              onSelected: (_) {
                setState(() { _selectedId = suite.id; _report = {}; });
                _loadSuite(suite.id);
              },
              selectedColor: _sageSoft,
            ),
        ]),
        const SizedBox(height: 12),
        _surfaceCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(_string(_suiteDetail['suite'] is Map ? Map<String, dynamic>.from(_suiteDetail['suite'] as Map) : {}, 'name'),
                  style: Theme.of(context).textTheme.titleMedium)),
              TextButton.icon(onPressed: _addCase, icon: const Icon(Icons.add), label: const Text('添加用例')),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: _busy || cases.isEmpty ? null : _startEvaluation,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(_busy ? '评测中…' : '运行评测'),
              ),
            ]),
            Text(_string(_suiteDetail['suite'] is Map ? Map<String, dynamic>.from(_suiteDetail['suite'] as Map) : {}, 'description'),
                style: const TextStyle(color: _muted)),
            const SizedBox(height: 8),
            for (final item in cases)
              _caseCard(Map<String, dynamic>.from(item as Map)),
            if (cases.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 18), child: Text('添加测试用例后即可运行评测。', style: TextStyle(color: _muted))),
          ]),
        ),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('最近评测', style: Theme.of(context).textTheme.titleMedium),
          for (final item in recent)
            ListTile(
              leading: const Icon(Icons.assessment_outlined, color: _sage),
              title: Text('评测 #${item['id']} · ${_statusLabel(item['status'] as String? ?? '')}'),
              subtitle: Text('增强版均分 ${item['average_score'] ?? 0} · ${_dateLabel(DateTime.tryParse(item['created_at'] as String? ?? '')?.toLocal() ?? DateTime.now())}'),
              onTap: () => _openReport((item['id'] as num).toInt()),
            ),
        ],
        if (_report.isNotEmpty) _evaluationReport(_report),
      ],
    ]);
  }

  Widget _caseCard(Map<String, dynamic> item) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: _paper, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item['title'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(item['question'] as String? ?? '', maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text('期望：${item['expected_behavior'] ?? ''}', style: const TextStyle(color: _muted, fontSize: 12)),
          ]),
        ),
      );

  Widget _evaluationReport(Map<String, dynamic> report) {
    final run = report['run'] is Map ? Map<String, dynamic>.from(report['run'] as Map) : <String, dynamic>{};
    final results = report['results'] is List ? (report['results'] as List).whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList() : <Map<String, dynamic>>[];
    final byCase = <int, List<Map<String, dynamic>>>{};
    for (final item in results) {
      byCase.putIfAbsent((item['test_case_id'] as num?)?.toInt() ?? 0, () => []).add(item);
    }
    return _surfaceCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${run['suite_name'] ?? '评测报告'} · ${_statusLabel(run['status'] as String? ?? '')}',
            style: Theme.of(context).textTheme.titleLarge),
        Text('增强版平均分：${run['average_score'] ?? 0} / 5', style: const TextStyle(color: _sage, fontWeight: FontWeight.w700)),
        if ((run['error_message'] as String? ?? '').isNotEmpty)
          Text(run['error_message'] as String, style: const TextStyle(color: Color(0xffa4513c))),
        const Divider(height: 26),
        for (final entries in byCase.values)
          _comparison(entries),
      ]),
    );
  }

  Widget _comparison(List<Map<String, dynamic>> entries) {
    final title = entries.first['case_title'] as String? ?? '测试用例';
    final baselineRows = entries.where((item) => item['variant'] == 'baseline').toList();
    final enhancedRows = entries.where((item) => item['variant'] == 'enhanced').toList();
    final baseline = baselineRows.isEmpty ? null : baselineRows.first;
    final enhanced = enhancedRows.isEmpty ? null : enhancedRows.first;
    final baselineScore = (baseline?['overall'] as num?)?.toDouble();
    final enhancedScore = (enhanced?['overall'] as num?)?.toDouble();
    final difference = baselineScore == null || enhancedScore == null
        ? null
        : enhancedScore - baselineScore;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        if (difference != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              '增强版较基础版 ${difference >= 0 ? '+' : ''}${difference.toStringAsFixed(2)} 分',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (context, constraints) {
          final children = [
            _variantCard('基础回答', baseline),
            _variantCard('增强回答', enhanced),
          ];
          if (constraints.maxWidth < 700) {
            return Column(children: [children[0], const SizedBox(height: 8), children[1]]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: children[0]), const SizedBox(width: 10), Expanded(child: children[1]),
          ]);
        }),
      ]),
    );
  }

  Widget _variantCard(String title, Map<String, dynamic>? row) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: _paper, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$title · ${row?['overall'] ?? '—'} / 5', style: const TextStyle(color: _sage, fontWeight: FontWeight.w700)),
          if (row != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final score in const <(String, String)>[
                  ('角色', 'role_adherence'),
                  ('约束', 'constraint_adherence'),
                  ('完成', 'task_completion'),
                  ('事实', 'factual_safety'),
                  ('格式', 'format_quality'),
                  ('来源', 'source_usage'),
                ])
                  _scoreChip(score.$1, row[score.$2]),
              ],
            ),
            const SizedBox(height: 8),
            SkillAgentRichText(row['agent_answer'] as String? ?? ''),
            if ((row['judge_comment'] as String? ?? '').isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text(row['judge_comment'] as String, style: const TextStyle(color: _muted, fontSize: 12))),
            if ((row['error_message'] as String? ?? '').isNotEmpty)
              Text(row['error_message'] as String, style: const TextStyle(color: Color(0xffa4513c))),
          ],
        ]),
      );

  Widget _scoreChip(String label, Object? value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _sageSoft,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('$label ${value ?? '—'}',
            style: const TextStyle(color: _sage, fontSize: 11)),
      );
}

class SkillAgentDiagnosticsPage extends StatefulWidget {
  const SkillAgentDiagnosticsPage({super.key});
  @override
  State<SkillAgentDiagnosticsPage> createState() => _SkillAgentDiagnosticsPageState();
}

class _SkillAgentDiagnosticsPageState extends State<SkillAgentDiagnosticsPage> {
  Map<String, dynamic> _status = {};
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final status = await SkillAgentApi.instance.diagnostics();
      if (mounted) setState(() => _status = status);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => _workspace([
        Row(children: [
          Expanded(child: Text('系统诊断', style: Theme.of(context).textTheme.titleLarge)),
          IconButton(onPressed: _load, tooltip: '刷新', icon: const Icon(Icons.refresh_rounded)),
        ]),
        const Text('诊断页只展示服务配置状态，不会返回密钥内容。', style: TextStyle(color: _muted)),
        if (_loading)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
        else if (_error.isNotEmpty)
          _notice(_error, error: true)
        else
          _surfaceCard(
            child: Column(children: [
              _diagnosticRow('模型服务', _status['llm_configured'] == true, _status['model'] as String? ?? ''),
              _diagnosticRow('实时搜索', _status['search_configured'] == true && _status['search_enabled'] == true,
                  _status['search_configured'] == true ? '已配置' : '未配置 TAVILY_API_KEY'),
              _diagnosticRow('知识库向量服务', _status['embedding_configured'] == true && _status['rag_enabled'] == true,
                  _status['embedding_configured'] == true ? '已配置' : '未配置 DASHSCOPE_API_KEY'),
              _diagnosticRow('后台任务', _status['worker_enabled'] == true, _status['worker_enabled'] == true ? '已启用' : '已关闭'),
              const Divider(height: 24),
              Align(alignment: Alignment.centerLeft, child: Text('接口模式：${_status['api_mode'] ?? '—'} · 推理强度：${_status['reasoning_effort'] ?? '—'}', style: const TextStyle(color: _muted))),
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerLeft, child: Text('回答模型：${_status['model'] ?? '—'} · Judge 模型：${_status['review_model'] ?? '—'}', style: const TextStyle(color: _muted))),
            ]),
          ),
      ]);

  Widget _diagnosticRow(String title, bool ready, String detail) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(ready ? Icons.check_circle_outline : Icons.info_outline,
              color: ready ? _sage : const Color(0xffb27b38)),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(detail, style: const TextStyle(color: _muted)),
        ]),
      );
}

Future<Map<String, String>?> _showFields(
    BuildContext context, String title, List<(String, String)> fields,
    {Map<String, String> defaults = const {}, Set<String> optional = const {}}) async {
  final controllers = {
    for (final field in fields) field.$1: TextEditingController(text: defaults[field.$1] ?? ''),
  };
  final values = await showDialog<Map<String, String>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final field in fields) ...[
              TextField(
                controller: controllers[field.$1],
                minLines: field.$1 == 'question' || field.$1 == 'expected_behavior' || field.$1 == 'scoring_focus' || field.$1 == 'description' ? 2 : 1,
                maxLines: field.$1 == 'question' || field.$1 == 'expected_behavior' || field.$1 == 'scoring_focus' || field.$1 == 'description' ? 4 : 1,
                maxLength: field.$1 == 'skill_url' ? 2000 : 6000,
                decoration: InputDecoration(labelText: field.$2),
              ),
              const SizedBox(height: 8),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final result = {for (final entry in controllers.entries) entry.key: entry.value.text.trim()};
            if (result.entries.any((entry) =>
                entry.value.isEmpty && !optional.contains(entry.key))) return;
            Navigator.pop(context, result);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  for (final controller in controllers.values) {
    controller.dispose();
  }
  return values;
}

Widget _emptyCard(String message) => _surfaceCard(
      child: Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(message, style: const TextStyle(color: _muted)))),
    );

Widget _notice(String message, {bool error = false}) => Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: error ? const Color(0xfffff0eb) : _sageSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: error ? const Color(0xffedc3b4) : _line),
      ),
      child: Text(message, style: TextStyle(color: error ? const Color(0xff914d39) : _sage)),
    );

IconData _documentIcon(String type) => type == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.description_outlined;

String _statusLabel(String status) => switch (status) {
      'queued' => '排队中',
      'indexing' => '索引中',
      'ready' || 'completed' || 'success' => '已完成',
      'running' => '运行中',
      'failed' => '失败',
      _ => status.isEmpty ? '未知' : status,
    };

String _dateLabel(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

String _string(Map<String, dynamic> row, String key) => row[key] as String? ?? '';
