import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/app_database.dart';

const incomeCategories = ['工资', '奖金', '兼职', '红包', '其他收入'];

Future<DateTime?> showIncomeEditor(BuildContext context,
        {required DateTime date, IncomeEntry? existing}) =>
    showDialog<DateTime>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _IncomeEditor(date: date, existing: existing));

class _IncomeEditor extends StatefulWidget {
  const _IncomeEditor({required this.date, this.existing});
  final DateTime date;
  final IncomeEntry? existing;

  @override
  State<_IncomeEditor> createState() => _IncomeEditorState();
}

class _IncomeEditorState extends State<_IncomeEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount, _notes;
  late DateTime _date;
  late String _category;
  late final int? _owner;
  String _requestId = _newRequestId();
  bool _saving = false, _uncertain = false;
  String? _error;

  static String _newRequestId() {
    final random = math.Random.secure();
    return List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  void initState() {
    super.initState();
    _owner = ApiClient.instance.account?.id;
    _date = widget.existing?.date ?? widget.date;
    _category = widget.existing?.category ?? incomeCategories.first;
    _amount = TextEditingController(
        text: widget.existing == null
            ? ''
            : (widget.existing!.incomeCents / 100).toStringAsFixed(2));
    _notes = TextEditingController(text: widget.existing?.notes ?? '');
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    if (ApiClient.instance.account?.id != _owner) {
      setState(() => _error = '账号已切换，请关闭后重新记录');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AppDatabase.instance.saveIncome(
          id: widget.existing?.id,
          date: _date,
          category: _category,
          incomeCents: parseIncomeCents(_amount.text)!,
          notes: _notes.text.trim(),
          requestId: _requestId);
      if (mounted) Navigator.pop(context, _date);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // 网络结果不明时锁定原表单，继续使用相同请求编号安全重试。
        _uncertain = error is! ApiException ||
            error.statusCode == 0 ||
            error.statusCode >= 500;
        _error = _uncertain
            ? '保存结果尚未确认，请重试。原内容已保留，不会重复记账。'
            : (error as ApiException).message;
        if (!_uncertain) _requestId = _newRequestId();
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = _saving || _uncertain;
    final categories = {...incomeCategories, _category};
    return PopScope(
        canPop: !_saving,
        child: AlertDialog(
          title: Text(widget.existing == null ? '记收入' : '编辑收入'),
          content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                  child: Form(
                      key: _form,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        TextFormField(
                            controller: _amount,
                            readOnly: locked,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: '收入金额（元）',
                                prefixText: '¥ ',
                                helperMaxLines: 3,
                                errorMaxLines: 3,
                                helperText: '大于 0，最多两位小数，上限 100,000,000 元'),
                            validator: (text) =>
                                parseIncomeCents(text ?? '') == null
                                    ? '请输入有效收入金额，最多两位小数'
                                    : null),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                            initialValue: _category,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '收入分类'),
                            items: [
                              for (final category in categories)
                                DropdownMenuItem(
                                    value: category, child: Text(category))
                            ],
                            onChanged: locked
                                ? null
                                : (value) =>
                                    setState(() => _category = value!)),
                        const SizedBox(height: 12),
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.calendar_today_outlined),
                            title: const Text('收入日期'),
                            subtitle: Text(dateKey(_date)),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: locked
                                ? null
                                : () async {
                                    final date = await showDatePicker(
                                        context: context,
                                        initialDate: _date,
                                        firstDate: DateTime(2000),
                                        lastDate: DateTime.now());
                                    if (date != null && mounted)
                                      setState(() => _date = date);
                                  }),
                        TextFormField(
                            controller: _notes,
                            readOnly: locked,
                            maxLength: 1000,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                                labelText: '备注（选填）', hintText: '例如：本月工资、周末兼职')),
                        if (_error != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(_error!,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error))),
                      ])))),
          actions: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: Text(_uncertain ? '关闭并刷新确认' : '取消')),
            FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving
                    ? '保存中…'
                    : _uncertain
                        ? '重试保存'
                        : '保存'))
          ],
        ));
  }
}

class IncomeRecordCard extends StatelessWidget {
  const IncomeRecordCard(
      {super.key,
      required this.entry,
      required this.onEdit,
      required this.onDelete});
  final IncomeEntry entry;
  final VoidCallback onEdit, onDelete;

  @override
  Widget build(BuildContext context) => Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.south_west_rounded,
                  size: 18, color: Color(0xff64765a)),
              const SizedBox(width: 8),
              Expanded(child: Text(entry.category)),
              IconButton(
                  onPressed: onEdit,
                  tooltip: '编辑收入',
                  icon: const Icon(Icons.edit_outlined, size: 18)),
              IconButton(
                  onPressed: onDelete,
                  tooltip: '删除收入',
                  icon: const Icon(Icons.delete_outline, size: 18))
            ]),
            FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                    '+¥ ${(entry.incomeCents / 100).toStringAsFixed(2)}',
                    style: const TextStyle(
                        color: Color(0xff64765a),
                        fontSize: 20,
                        fontWeight: FontWeight.w600))),
            if (entry.notes.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(entry.notes)),
          ])));
}
