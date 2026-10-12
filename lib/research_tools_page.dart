import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/api_client.dart';
import 'data/research_files.dart';

const _paper = Color(0xfff6f5ef);
const _surface = Color(0xfffffefa);
const _sage = Color(0xff64765a);
const _sageSoft = Color(0xffe9eee4);
const _muted = Color(0xff70756b);
const _line = Color(0xffe8e7df);

const _sources = <({String id, String label, IconData icon})>[
  (id: 'arxiv', label: 'arXiv', icon: Icons.auto_stories_outlined),
  (id: 'openreview', label: 'OpenReview', icon: Icons.rate_review_outlined),
  (id: 'acl_anthology', label: 'ACL Anthology', icon: Icons.translate_rounded),
  (id: 'biorxiv', label: 'bioRxiv', icon: Icons.biotech_outlined),
  (id: 'medrxiv', label: 'medRxiv', icon: Icons.health_and_safety_outlined),
  (id: 'pmlr', label: 'PMLR', icon: Icons.auto_graph_rounded),
  (id: 'pmc_oa', label: 'PMC OA', icon: Icons.local_hospital_outlined),
];

class ResearchToolsPage extends StatefulWidget {
  const ResearchToolsPage({super.key});

  @override
  State<ResearchToolsPage> createState() => _ResearchToolsPageState();
}

class _ResearchToolsPageState extends State<ResearchToolsPage> {
  final _query = TextEditingController();
  final _venue = TextEditingController();
  final _selectedSources = <String>{'arxiv'};
  final _selectedPapers = <String>{};
  final _downloadedById = <String, ResearchDownloadedFile>{};
  final _downloadProgress = <String, ({int received, int? total})>{};
  final _downloadErrors = <String, String>{};

  String _tab = 'search';
  int _limit = 10;
  bool _searching = false;
  bool _hasSearched = false;
  bool _batchDownloading = false;
  String? _searchError;
  String? _lastQuery;
  List<Map<String, dynamic>> _results = [];
  List<Map<String, String>> _sourceErrors = [];
  List<ResearchDownloadedFile> _savedFiles = [];
  ResearchDirectory _directory =
      const ResearchDirectory(label: '正在读取保存位置…');
  DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_loadLocalFiles());
  }

  @override
  void dispose() {
    _query.dispose();
    _venue.dispose();
    super.dispose();
  }

  Future<void> _loadLocalFiles() async {
    try {
      final values = await Future.wait([
        researchDirectory(),
        listResearchFiles(),
      ]);
      if (!mounted) return;
      setState(() {
        _directory = values[0] as ResearchDirectory;
        _savedFiles = values[1] as List<ResearchDownloadedFile>;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _directory = ResearchDirectory(
              label: kIsWeb ? '由浏览器管理下载位置' : '本地文献');
        });
      }
    }
  }

  Future<void> _chooseDirectory() async {
    try {
      final directory = await chooseResearchDirectory();
      if (directory == null || !mounted) return;
      setState(() => _directory = directory);
      await _loadLocalFiles();
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '无法选择保存文件夹');
    } catch (_) {
      _showMessage('无法选择保存文件夹');
    }
  }

  Future<void> _useDefaultDirectory() async {
    try {
      final directory = await useDefaultResearchDirectory();
      if (!mounted) return;
      setState(() => _directory = directory);
      await _loadLocalFiles();
    } catch (_) {
      _showMessage('无法切换到本地默认目录');
    }
  }

  Future<void> _search({String? suggestedQuery}) async {
    final query = (suggestedQuery ?? _query.text).trim();
    if (query.isEmpty || _searching || _selectedSources.isEmpty) return;
    if (_selectedSources.contains('openreview') && _venue.text.trim().isEmpty) {
      _showMessage('请填写 OpenReview 会议 ID');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _query.text = query;
      _searching = true;
      _hasSearched = true;
      _searchError = null;
      _sourceErrors = [];
      _results = [];
      _selectedPapers.clear();
    });
    try {
      final response = await ApiClient.instance.request(
        'POST',
        'research/papers/search',
        timeout: const Duration(seconds: 120),
        body: {
          'query': query,
          'sources': [
            for (final source in _sources)
              if (_selectedSources.contains(source.id)) source.id,
          ],
          'limit': _limit,
          if (_selectedSources.contains('openreview'))
            'venue_id': _venue.text.trim(),
        },
      ) as Map<String, dynamic>;
      final results = (response['results'] as List? ?? [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final errors = (response['source_errors'] as List? ?? [])
          .whereType<Map>()
          .map((item) => Map<String, String>.from(item.map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              )))
          .toList();
      if (!mounted) return;
      setState(() {
        _lastQuery = query;
        _results = results;
        _sourceErrors = errors;
      });
    } catch (error) {
      if (mounted) setState(() => _searchError = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _togglePaper(String id) {
    setState(() {
      if (!_selectedPapers.add(id)) _selectedPapers.remove(id);
    });
  }

  Future<void> _downloadSelected() async {
    if (_batchDownloading) return;
    setState(() => _batchDownloading = true);
    final papers = _results
        .where((paper) => _selectedPapers.contains(paper['id']))
        .toList();
    var saved = 0;
    for (final paper in papers) {
      if (!mounted) break;
      if (await _downloadPaper(paper)) saved++;
    }
    if (mounted) {
      setState(() {
        _batchDownloading = false;
        _selectedPapers.clear();
      });
      _showMessage('批量下载完成，成功 $saved/${papers.length} 篇');
    }
  }

  Future<bool> _downloadPaper(Map<String, dynamic> paper) async {
    final id = paper['id'] as String?;
    final source = paper['source'] as String?;
    final record = paper['record'];
    if (id == null || source == null || record is! Map) return false;
    ResearchPdfSink? sink;
    setState(() {
      _downloadProgress[id] = (received: 0, total: null);
      _downloadErrors.remove(id);
    });
    try {
      sink = await beginResearchPdf(
        paper['filename'] as String? ?? '论文.pdf',
      );
      await ApiClient.instance.requestPdf(
        'POST',
        'research/papers/download',
        body: {
          'source': source,
          'paper': Map<String, dynamic>.from(record),
        },
        onChunk: (chunk) => writeResearchPdfChunk(sink!, chunk),
        onProgress: (received, total) {
          final now = DateTime.now();
          if (now.difference(_lastProgressUpdate).inMilliseconds < 90 &&
              (total == null || received < total)) return;
          _lastProgressUpdate = now;
          if (mounted) {
            setState(() => _downloadProgress[id] =
                (received: received, total: total));
          }
        },
      );
      final file = await finishResearchPdf(sink);
      sink = null;
      if (!mounted) return false;
      setState(() {
        _downloadProgress.remove(id);
        _downloadedById[id] = file;
        _savedFiles = [file, ..._savedFiles.where((item) => item.uri != file.uri)];
      });
      if (!_batchDownloading) _showMessage('已保存到 ${_directory.label}');
      return true;
    } catch (error) {
      if (sink != null) {
        try {
          await abortResearchPdf(sink);
        } catch (_) {}
      }
      if (!mounted) return false;
      setState(() {
        _downloadProgress.remove(id);
        _downloadErrors[id] = error.toString();
      });
      _showMessage(error.toString());
      return false;
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _openPdf(String uri) async {
    try {
      await openResearchPdf(uri);
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  Future<void> _openUrl(String url) async {
    try {
      await openResearchUrl(url);
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: _paper,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(children: [
                _header(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: 'search',
                        icon: Icon(Icons.search_rounded),
                        label: Text('论文搜索'),
                      ),
                      ButtonSegment(
                        value: 'saved',
                        icon: Icon(Icons.folder_open_rounded),
                        label: Text('已下载'),
                      ),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (selection) {
                      setState(() => _tab = selection.first);
                      if (_tab == 'saved') unawaited(_loadLocalFiles());
                    },
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _tab == 'search'
                        ? _searchView(key: const ValueKey('search-view'))
                        : _savedView(key: const ValueKey('saved-view')),
                  ),
                ),
              ]),
            ),
          ),
        ),
        bottomNavigationBar: _tab == 'search' && _selectedPapers.isNotEmpty
            ? _selectionBar()
            : null,
      );

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _sageSoft,
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Icon(Icons.science_outlined, color: _sage),
          ),
          const SizedBox(width: 13),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('科研工具',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                SizedBox(height: 3),
                Text('搜索开放学术来源，保存论文 PDF',
                    style: TextStyle(color: _muted, fontSize: 12)),
              ],
            ),
          ),
          if (_selectedPapers.isNotEmpty)
            Text('${_selectedPapers.length} 篇已选',
                style: const TextStyle(color: _sage, fontSize: 12)),
        ]),
      );

  Widget _searchView({Key? key}) => CustomScrollView(
        key: key,
        slivers: [
          SliverToBoxAdapter(child: _searchControls()),
          if (_searching)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _LoadingState(),
            )
          else if (_searchError != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _ErrorState(message: _searchError!, onRetry: () => _search()),
            )
          else if (_hasSearched && _results.isEmpty && _sourceErrors.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(
                  title: '没有找到论文',
                  subtitle: '试试更短的关键词，或再选一个搜索来源。'),
            )
          else if (_hasSearched && _results.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _ErrorState(
                message: '所选来源暂时无法搜索，请稍后重试。',
                onRetry: () => _search(),
              ),
            )
          else if (!_hasSearched)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _WelcomeState(onSuggestion: (value) => _search(suggestedQuery: value)),
            )
          else ...[
            if (_sourceErrors.isNotEmpty)
              SliverToBoxAdapter(child: _sourceErrorBanner()),
            SliverToBoxAdapter(child: _resultsHeading()),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _paperCard(_results[index]),
                  ),
                  childCount: _results.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ],
      );

  Widget _searchControls() => Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: '输入论文标题或关键词',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空',
                          onPressed: () => setState(_query.clear),
                          icon: const Icon(Icons.close_rounded),
                        ),
                  filled: true,
                  fillColor: _surface,
                  contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(17),
                    borderSide: const BorderSide(color: _line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(17),
                    borderSide: const BorderSide(color: _line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(17),
                    borderSide: const BorderSide(color: _sage, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 9),
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: _searching ? null : _search,
                icon: _searching
                    ? const SizedBox.square(
                        dimension: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward_rounded),
                label: const Text('搜索'),
                style: FilledButton.styleFrom(
                  backgroundColor: _sage,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            const Expanded(
              child: Text('搜索来源',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            const Text('每个来源',
                style: TextStyle(color: _muted, fontSize: 11)),
            const SizedBox(width: 7),
            DropdownButton<int>(
              value: _limit,
              underline: const SizedBox.shrink(),
              isDense: true,
              items: const [10, 20, 30]
                  .map((value) => DropdownMenuItem(
                        value: value,
                        child: Text('$value 条'),
                      ))
                  .toList(),
              onChanged: _searching
                  ? null
                  : (value) {
                      if (value != null) setState(() => _limit = value);
                    },
            ),
          ]),
          const SizedBox(height: 5),
          Wrap(
            spacing: 7,
            runSpacing: 3,
            children: [
              for (final source in _sources)
                FilterChip(
                  avatar: Icon(source.icon, size: 16),
                  label: Text(source.label),
                  selected: _selectedSources.contains(source.id),
                  showCheckmark: false,
                  selectedColor: _sageSoft,
                  onSelected: _searching
                      ? null
                      : (selected) => setState(() {
                            if (selected) {
                              _selectedSources.add(source.id);
                            } else if (_selectedSources.length > 1) {
                              _selectedSources.remove(source.id);
                            }
                          }),
                ),
            ],
          ),
          if (_selectedSources.contains('openreview')) ...[
            const SizedBox(height: 4),
            TextField(
              controller: _venue,
              decoration: const InputDecoration(
                labelText: 'OpenReview 会议 ID',
                hintText: '例如 ICLR.cc/2024/Conference',
                isDense: true,
              ),
            ),
          ],
          const SizedBox(height: 7),
          _directoryRow(),
        ]),
      );

  Widget _directoryRow() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: _line),
        ),
        child: Row(children: [
          const Icon(Icons.folder_outlined, size: 18, color: _sage),
          const SizedBox(width: 8),
          const Text('PDF 保存到',
              style: TextStyle(fontSize: 12, color: _muted)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(_directory.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          if (!kIsWeb)
            TextButton(
              onPressed: _batchDownloading || _downloadProgress.isNotEmpty
                  ? null
                  : _chooseDirectory,
              child: const Text('选择'),
            ),
          if (_directory.custom && !kIsWeb)
            IconButton(
              tooltip: '恢复本地默认目录',
              visualDensity: VisualDensity.compact,
              onPressed: _batchDownloading || _downloadProgress.isNotEmpty
                  ? null
                  : _useDefaultDirectory,
              icon: const Icon(Icons.restore_rounded, size: 18),
            ),
        ]),
      );

  Widget _resultsHeading() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 9, 20, 8),
        child: Row(children: [
          Expanded(
            child: Text(
              '“${_lastQuery ?? ''}”的搜索结果',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ),
          Text('${_results.length} 篇',
              style: const TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _selectedPapers.length == _results.length
                ? () => setState(_selectedPapers.clear)
                : () => setState(() => _selectedPapers
                    .addAll(_results.map((paper) => paper['id'] as String))),
            child: Text(_selectedPapers.length == _results.length ? '取消全选' : '全选'),
          ),
        ]),
      );

  Widget _sourceErrorBanner() => Container(
        margin: const EdgeInsets.fromLTRB(18, 8, 18, 2),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xfffff2dc),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline_rounded, color: Color(0xff946c2e)),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '${_sourceErrors.map((item) => _sourceLabel(item['source'] ?? '')).join('、')} 暂时无响应，已显示其他来源结果。',
              style: const TextStyle(fontSize: 12, color: Color(0xff725321)),
            ),
          ),
          TextButton(onPressed: _search, child: const Text('重试')),
        ]),
      );

  Widget _paperCard(Map<String, dynamic> paper) {
    final id = paper['id'] as String? ?? '';
    final source = _sourceLabel(paper['source'] as String? ?? '');
    final authors = (paper['authors'] as List? ?? []).whereType<String>().toList();
    final downloaded = _downloadedById[id];
    final progress = _downloadProgress[id];
    final error = _downloadErrors[id];
    final selected = _selectedPapers.contains(id);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 18),
      color: _surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: selected ? _sage : _line, width: selected ? 1.4 : 1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 9),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Checkbox(
                value: selected,
                activeColor: _sage,
                onChanged: id.isEmpty ? null : (_) => _togglePaper(id),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      _tag(source, _sageSoft, _sage),
                      if (paper['year'] != null)
                        _tag('${paper['year']}', const Color(0xfff2eee2), _muted),
                      if (paper['venue'] is String && (paper['venue'] as String).isNotEmpty)
                        _tag(paper['venue'] as String, const Color(0xffedf1f2), const Color(0xff536d77)),
                    ]),
                    const SizedBox(height: 8),
                    Text(
                      paper['title'] as String? ?? '未命名论文',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.3),
                    ),
                    if (authors.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(authors.take(4).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _muted, fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ]),
        ),
        if ((paper['abstract'] as String?)?.trim().isNotEmpty == true)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              dense: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 18),
              childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              title: const Text('查看摘要', style: TextStyle(fontSize: 12, color: _sage)),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(paper['abstract'] as String,
                      style: const TextStyle(fontSize: 13, height: 1.55, color: Color(0xff4e514a))),
                ),
              ],
            ),
          ),
        if (_downloadProgress.containsKey(id))
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: Column(children: [
              LinearProgressIndicator(
                value: progress != null &&
                        progress.total != null &&
                        progress.total! > 0
                    ? (progress.received / progress.total!)
                        .clamp(0.0, 1.0)
                        .toDouble()
                    : null,
                color: _sage,
                backgroundColor: _sageSoft,
              ),
              const SizedBox(height: 5),
              Text(
                progress == null ||
                        progress.total == null ||
                        progress.total! <= 0
                    ? '已接收 ${_formatBytes(progress?.received ?? 0)}'
                    : '下载中 ${(progress.received / progress.total! * 100).clamp(0, 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ]),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: Row(children: [
              const Icon(Icons.error_outline, size: 16, color: Color(0xffa34d3f)),
              const SizedBox(width: 6),
              Expanded(child: Text(error, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xffa34d3f)))),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Row(children: [
            if (paper['article_url'] is String)
              TextButton.icon(
                onPressed: () => _openUrl(paper['article_url'] as String),
                icon: const Icon(Icons.open_in_new_rounded, size: 17),
                label: const Text('来源页'),
              ),
            const Spacer(),
            if (downloaded != null)
              FilledButton.tonalIcon(
                onPressed: () => _openPdf(downloaded.uri),
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: const Text('打开 PDF'),
              )
            else
              FilledButton.tonalIcon(
                onPressed: _downloadProgress.containsKey(id) ? null : () => _downloadPaper(paper),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(error == null ? '下载 PDF' : '重试下载'),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _savedView({Key? key}) => CustomScrollView(
        key: key,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
              child: _directoryRow(),
            ),
          ),
          if (_savedFiles.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(
                  title: '还没有下载论文',
                  subtitle: '搜索结果中的 PDF 会保存在上方显示的位置。'),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(children: [
                  const Expanded(
                    child: Text('本地论文',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  Text('${_savedFiles.length} 篇',
                      style: const TextStyle(color: _muted, fontSize: 12)),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _loadLocalFiles,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ]),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                final file = _savedFiles[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Card(
                  color: _surface,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(color: _line),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: _sageSoft,
                      child: Icon(Icons.picture_as_pdf_outlined, color: _sage),
                    ),
                    title: Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text('${_formatBytes(file.size)} · ${_formatDate(file.modifiedAt)}',
                        style: const TextStyle(fontSize: 11, color: _muted)),
                    trailing: IconButton.filledTonal(
                      tooltip: '打开查看',
                      onPressed: () => _openPdf(file.uri),
                      icon: const Icon(Icons.open_in_new_rounded),
                    ),
                  ),
                  ),
                );
                  },
                  childCount: _savedFiles.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ],
      );

  Widget _selectionBar() => SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
          decoration: const BoxDecoration(
            color: _surface,
            border: Border(top: BorderSide(color: _line)),
          ),
          child: Row(children: [
            Expanded(
              child: Text('已选择 ${_selectedPapers.length} 篇',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: _batchDownloading
                  ? null
                  : () => setState(_selectedPapers.clear),
              child: const Text('清除'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _batchDownloading ? null : _downloadSelected,
              icon: _batchDownloading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(_batchDownloading ? '批量下载中' : '下载选中'),
              style: FilledButton.styleFrom(backgroundColor: _sage),
            ),
          ]),
        ),
      );

  Widget _tag(String text, Color background, Color foreground) => Container(
        constraints: const BoxConstraints(maxWidth: 210),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: background, borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: foreground, fontSize: 10, fontWeight: FontWeight.w600)),
      );

  String _sourceLabel(String id) {
    for (final source in _sources) {
      if (source.id == id) return source.label;
    }
    return id;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox.square(
              dimension: 36,
              child: CircularProgressIndicator(color: _sage, strokeWidth: 3)),
          SizedBox(height: 15),
          Text('正在搜索所选学术来源…',
              style: TextStyle(color: _muted, fontSize: 13)),
        ]),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.menu_book_outlined, size: 46, color: _sage),
            const SizedBox(height: 13),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 6),
            Text(subtitle, textAlign: TextAlign.center,
                style: const TextStyle(color: _muted, fontSize: 12, height: 1.45)),
          ]),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_outlined, size: 42, color: Color(0xffa34d3f)),
            const SizedBox(height: 12),
            const Text('搜索暂时失败', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(message, textAlign: TextAlign.center,
                style: const TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试')),
          ]),
        ),
      );
}

class _WelcomeState extends StatelessWidget {
  const _WelcomeState({required this.onSuggestion});
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 30),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                  color: _sageSoft, borderRadius: BorderRadius.circular(26)),
              child: const Icon(Icons.travel_explore_rounded, size: 38, color: _sage),
            ),
            const SizedBox(height: 16),
            const Text('从一个问题开始',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 7),
            const Text(
                '选择来源，输入关键词或标题。结果可以展开查看摘要，\n选中后批量下载并保存在本地。',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 12, height: 1.5)),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                for (final sample in const [
                  'Attention Is All You Need',
                  'diffusion model',
                  'graph neural network',
                ])
                  ActionChip(
                    avatar: const Icon(Icons.bolt_rounded, size: 16),
                    label: Text(sample),
                    onPressed: () => onSuggestion(sample),
                  ),
              ],
            ),
          ]),
        ),
      );
}
