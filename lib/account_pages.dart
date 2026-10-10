import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import 'data/api_client.dart';
import 'data/legacy_migration.dart';
import 'update/app_updates_platform.dart';
import 'couple_page.dart';

Future<bool> serverAction(
    BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error is ApiException ? error.message : '操作失败，请重试'),
      ));
    }
    return false;
  }
}

class NetworkFailure extends StatelessWidget {
  const NetworkFailure(
      {super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => SafeArea(
          child: Center(
              child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_outlined, size: 38),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试')),
        ]),
      )));
}

class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, required this.bytes, this.radius = 26});

  final Uint8List? bytes;
  final double radius;

  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: radius,
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        backgroundImage: bytes == null ? null : MemoryImage(bytes!),
        child: bytes == null
            ? Icon(Icons.person_outline, size: radius + 4)
            : null,
      );
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.homeBuilder});
  final Widget Function(Key key) homeBuilder;
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _api = ApiClient.instance;
  int? _owner;
  bool _checkingLegacy = false;
  bool _deferred = false;
  String? _migrationError;

  @override
  void initState() {
    super.initState();
    _api.addListener(_changed);
    _api.restore();
  }

  void _changed() {
    if (!mounted) return;
    final owner = _api.account?.id;
    if (_api.status == AuthStatus.signedIn && owner != _owner) {
      _owner = owner;
      _deferred = false;
      _checkingLegacy = true;
      _scan(owner);
    }
    if (_api.status == AuthStatus.signedOut) {
      _owner = null;
      _deferred = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _api.status == AuthStatus.signedOut) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
    }
    setState(() {});
  }

  Future<void> _scan(int? owner) async {
    String? error;
    try {
      await LegacyMigration.instance.scan();
    } catch (failure) {
      error =
          failure is ApiException ? failure.message : '无法读取本机旧数据，请重试；旧数据已保留';
    }
    if (!mounted || _api.account?.id != owner) return;
    setState(() {
      _checkingLegacy = false;
      _migrationError = error;
    });
  }

  @override
  void dispose() {
    _api.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_api.status == AuthStatus.restoring ||
        (_api.status == AuthStatus.signedIn && _checkingLegacy)) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_api.status == AuthStatus.unavailable) {
      return Scaffold(
          body: NetworkFailure(message: _api.message, onRetry: _api.restore));
    }
    if (_api.status == AuthStatus.signedOut) return const LoginPage();
    if (_migrationError != null) {
      return Scaffold(
          body: NetworkFailure(
              message: _migrationError!,
              onRetry: () {
                setState(() => _checkingLegacy = true);
                _scan(_owner);
              }));
    }
    if (LegacyMigration.instance.pending != null && !_deferred) {
      return LegacyImportPage(
          onContinue: () => setState(() => _deferred = true));
    }
    return widget
        .homeBuilder(ValueKey('${_api.account!.id}:${_api.dataRevision}'));
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _nickname = TextEditingController();
  bool _register = false;
  bool _busy = false;
  bool _hidePassword = true;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirmation.dispose();
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiClient.instance.signIn(_username.text, _password.text,
          register: _register, nickname: _nickname.text);
    } catch (error) {
      if (mounted)
        setState(
            () => _error = error is ApiException ? error.message : '登录失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
          body: SafeArea(
              child: Center(
        child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: AutofillGroup(
                    child: Form(
                  key: _form,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.spa_outlined,
                            size: 42,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(height: 18),
                        const Text('DAY BY DAY',
                            style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        Text(_register ? '开启你的日常。' : '欢迎回来。',
                            style: const TextStyle(
                                fontFamily: 'serif', fontSize: 32)),
                        const SizedBox(height: 8),
                        const Text('登录后查看属于你的身体、饮食和训练记录。'),
                        const SizedBox(height: 28),
                        TextFormField(
                            controller: _username,
                            enabled: !_busy,
                            maxLength: 32,
                            autofillHints: const [AutofillHints.username],
                            decoration: const InputDecoration(
                                labelText: '用户名',
                                hintText: '3–32 位中文、字母、数字、下划线或短横线'),
                            validator: (value) =>
                                RegExp(r'^[A-Za-z0-9_\-\u4e00-\u9fff]{3,32}$')
                                        .hasMatch(value?.trim() ?? '')
                                    ? null
                                    : '请输入有效用户名（3–32 位）'),
                        const SizedBox(height: 10),
                        TextFormField(
                            controller: _password,
                            enabled: !_busy,
                            obscureText: _hidePassword,
                            maxLength: 128,
                            autofillHints: [
                              _register
                                  ? AutofillHints.newPassword
                                  : AutofillHints.password
                            ],
                            decoration: InputDecoration(
                                labelText: '密码',
                                hintText: '8–128 位',
                                suffixIcon: IconButton(
                                    tooltip: _hidePassword ? '显示密码' : '隐藏密码',
                                    onPressed: () => setState(
                                        () => _hidePassword = !_hidePassword),
                                    icon: Icon(_hidePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined))),
                            validator: (value) => (value?.length ?? 0) >= 8 &&
                                    (value?.length ?? 0) <= 128
                                ? null
                                : '密码长度为 8–128 位',
                            onFieldSubmitted: (_) {
                              if (!_register) _submit();
                            }),
                        if (_register) ...[
                          const SizedBox(height: 10),
                          TextFormField(
                              controller: _confirmation,
                              enabled: !_busy,
                              obscureText: true,
                              maxLength: 128,
                              decoration:
                                  const InputDecoration(labelText: '确认密码'),
                              validator: (value) =>
                                  value == _password.text ? null : '两次密码不一致'),
                          const SizedBox(height: 10),
                          TextFormField(
                              controller: _nickname,
                              enabled: !_busy,
                              maxLength: 32,
                              decoration:
                                  const InputDecoration(labelText: '昵称（选填）'),
                              onFieldSubmitted: (_) => _submit()),
                        ],
                        if (_error != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Text(_error!,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error))),
                        if (ApiClient.instance.message.isNotEmpty &&
                            _error == null)
                          Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Text(ApiClient.instance.message)),
                        const SizedBox(height: 24),
                        SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                                onPressed: _busy ? null : _submit,
                                style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 15)),
                                child: Text(_busy
                                    ? '请稍候…'
                                    : _register
                                        ? '注册并登录'
                                        : '登录'))),
                        Align(
                            alignment: Alignment.center,
                            child: TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => setState(() {
                                          _register = !_register;
                                          _error = null;
                                          _confirmation.clear();
                                          _form.currentState?.reset();
                                        }),
                                child:
                                    Text(_register ? '已有账号？去登录' : '还没有账号？注册'))),
                      ]),
                )))),
      )));
}

class LegacyImportPage extends StatefulWidget {
  const LegacyImportPage({super.key, required this.onContinue});
  final VoidCallback onContinue;
  @override
  State<LegacyImportPage> createState() => _LegacyImportPageState();
}

class _LegacyImportPageState extends State<LegacyImportPage> {
  bool _confirmed = false;
  bool _busy = false;
  String? _error;
  @override
  Widget build(BuildContext context) {
    final snapshot = LegacyMigration.instance.pending;
    final account = ApiClient.instance.account!;
    return Scaffold(
        body: SafeArea(
            child: Center(
                child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.cloud_upload_outlined, size: 40),
              const SizedBox(height: 18),
              const Text('把旧记录带到账号里',
                  style: TextStyle(fontFamily: 'serif', fontSize: 27)),
              const SizedBox(height: 14),
              Text('当前账号：${account.username}'),
              const SizedBox(height: 10),
              Text(
                  '发现 ${snapshot?.total ?? 0} 条本机旧数据（含训练设置）。导入成功并核对完整后，才会清理本机数据库。'),
              const SizedBox(height: 10),
              const Text('如果服务器已有不同的同日记录，导入会停止并保留本机数据。'),
              const SizedBox(height: 18),
              CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _confirmed,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _confirmed = value ?? false),
                  title: Text('我确认这些旧记录属于 ${account.username}')),
              if (_error != null)
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 16),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                      onPressed: !_confirmed || _busy
                          ? null
                          : () async {
                              setState(() {
                                _busy = true;
                                _error = null;
                              });
                              try {
                                await LegacyMigration.instance
                                    .importToCurrentAccount();
                                if (mounted) widget.onContinue();
                              } catch (error) {
                                if (mounted)
                                  setState(() => _error = error is ApiException
                                      ? error.message
                                      : '导入失败，本机数据已保留，请重试');
                              } finally {
                                if (mounted) setState(() => _busy = false);
                              }
                            },
                      child: Text(_busy ? '正在导入并核对…' : '确认归属并导入'))),
              TextButton(
                  onPressed: _busy ? null : widget.onContinue,
                  child: const Text('稍后导入，可在“我的”中继续')),
              TextButton(
                  onPressed: _busy
                      ? null
                      : () => serverAction(context, ApiClient.instance.signOut),
                  child: const Text('切换账号')),
            ],
          )),
    ))));
  }
}

class MyPage extends StatefulWidget {
  const MyPage({super.key});
  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    ApiClient.instance.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ApiClient.instance.removeListener(_changed);
    super.dispose();
  }

  Future<void> _changeAvatar() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
        maxWidth: kIsWeb ? 512 : null,
        maxHeight: kIsWeb ? 512 : null,
        imageQuality: kIsWeb ? 85 : null,
      );
      if (picked == null || !mounted) return;
      if (kIsWeb) {
        await serverAction(
          context,
          () async => ApiClient.instance.saveAvatar(await picked.readAsBytes()),
        );
        return;
      }
      final cropped = await ImageCropper().cropImage(
        sourcePath: picked.path,
        maxWidth: 512,
        maxHeight: 512,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 85,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: '裁剪头像',
            toolbarColor: const Color(0xff64765a),
            toolbarWidgetColor: Colors.white,
            cropStyle: CropStyle.circle,
            lockAspectRatio: true,
            initAspectRatio: CropAspectRatioPreset.square,
            aspectRatioPresets: [CropAspectRatioPreset.square],
          ),
          IOSUiSettings(
            title: '裁剪头像',
            doneButtonTitle: '使用',
            cancelButtonTitle: '取消',
            cropStyle: CropStyle.circle,
            aspectRatioLockEnabled: true,
            aspectRatioPickerButtonHidden: true,
            aspectRatioPresets: [CropAspectRatioPreset.square],
          ),
        ],
      );
      if (cropped == null || !mounted) return;
      await serverAction(
        context,
        () async => ApiClient.instance.saveAvatar(await cropped.readAsBytes()),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('照片选择或裁剪失败，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editProfile() async {
    final account = ApiClient.instance.account!;
    final nickname = TextEditingController(text: account.nickname);
    final age = TextEditingController(text: account.age?.toString() ?? '');
    final form = GlobalKey<FormState>();
    var gender = account.gender;
    var saving = false;
    String? error;
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !saving,
          child: AlertDialog(
            title: const Text('个人资料'),
            content: SingleChildScrollView(
                child: Form(
              key: form,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(
                  controller: nickname,
                  enabled: !saving,
                  maxLength: 32,
                  decoration: const InputDecoration(labelText: '昵称'),
                  validator: (value) =>
                      (value?.trim().isEmpty ?? true) ? '请输入昵称' : null,
                ),
                TextFormField(
                  controller: age,
                  enabled: !saving,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '年龄（可选）'),
                  validator: (raw) {
                    final value = raw?.trim() ?? '';
                    if (value.isEmpty) return null;
                    final years = int.tryParse(value);
                    if (years == null || years < 1 || years > 120) {
                      return '请输入 1–120 的整数年龄';
                    }
                    return null;
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: gender,
                  decoration: const InputDecoration(labelText: '性别'),
                  items: const [
                    DropdownMenuItem(value: 'unset', child: Text('未设置')),
                    DropdownMenuItem(value: 'male', child: Text('男生')),
                    DropdownMenuItem(value: 'female', child: Text('女生')),
                  ],
                  onChanged:
                      saving ? null : (value) => update(() => gender = value!),
                ),
                const SizedBox(height: 14),
                const Text('选择女生后显示女性健康栏。更改性别只隐藏入口，历史记录会保留。',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
              ]),
            )),
            actions: [
              TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!form.currentState!.validate()) return;
                          update(() {
                            saving = true;
                            error = null;
                          });
                          try {
                            await ApiClient.instance.saveProfile(nickname.text,
                                gender, int.tryParse(age.text.trim()));
                            if (dialogContext.mounted)
                              Navigator.pop(dialogContext);
                          } catch (failure) {
                            if (dialogContext.mounted)
                              update(() {
                                saving = false;
                                error = failure is ApiException
                                    ? failure.message
                                    : '保存失败，请重试';
                              });
                          }
                        },
                  child: Text(saving ? '保存中…' : '保存')),
            ],
          ),
        ),
      ),
    );
    await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    nickname.dispose();
    age.dispose();
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    await serverAction(context, ApiClient.instance.signOut);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _import() async {
    final username = ApiClient.instance.account!.username;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('确认旧记录归属'),
              content: Text('将本机旧记录导入账号 $username。服务器完整导入后，本机数据库会被清理。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('确认属于此账号并导入'))
              ],
            ));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    await serverAction(
        context, LegacyMigration.instance.importToCurrentAccount);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final account = ApiClient.instance.account;
    if (account == null) return const SizedBox.shrink();
    final registered =
        '${account.createdAt.year}-${account.createdAt.month.toString().padLeft(2, '0')}-${account.createdAt.day.toString().padLeft(2, '0')}';
    final ageLabel = account.age == null ? '未设置' : '${account.age} 岁';
    return SafeArea(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
            children: [
          const Text('我的', style: TextStyle(fontFamily: 'serif', fontSize: 32)),
          const SizedBox(height: 24),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: _busy ? null : _changeAvatar,
                          customBorder: const CircleBorder(),
                          child: AccountAvatar(
                            bytes: account.avatarBytes,
                            radius: 30,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text('点击头像更换',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                        const SizedBox(height: 16),
                        Text(account.nickname,
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 14),
                        Text('用户名　${account.username}'),
                        const SizedBox(height: 10),
                        Text('性别　${switch (account.gender) {
                          'female' => '女生',
                          'male' => '男生',
                          _ => '未设置'
                        }}'),
                        const SizedBox(height: 10),
                        Text('年龄　$ageLabel'),
                        const SizedBox(height: 10),
                        Text('注册时间　$registered'),
                      ]))),
          const SizedBox(height: 14),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.favorite_border),
                  title: const Text('情侣空间'),
                  subtitle: const Text('两个人的照片、留言和日常回忆'),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: !_busy,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const CouplePage()));
                  })),
          Card(
              child: ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('个人资料'),
            subtitle: const Text('昵称、性别、年龄'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_busy,
            onTap: _editProfile,
          )),
          if (LegacyMigration.instance.pending != null)
            Card(
                child: ListTile(
                    leading: const Icon(Icons.cloud_upload_outlined),
                    title: const Text('导入本机旧记录'),
                    subtitle: const Text('确认数据归属后导入当前账号'),
                    trailing: const Icon(Icons.chevron_right),
                    enabled: !_busy,
                    onTap: _import)),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: const Text('检查更新'),
                  subtitle: Text(UpdateScope.maybeOf(context)
                              ?.currentVersion
                              .isNotEmpty ==
                          true
                      ? '当前版本 ${UpdateScope.maybeOf(context)!.currentVersion}'
                      : '点击检测新版本'),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: !_busy,
                  onTap: () => checkForAppUpdates(context))),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.history_outlined),
                  title: const Text('更新日志'),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: !_busy,
                  onTap: () => serverAction(
                      context, () => showInstalledUpdateLog(context)))),
          Card(
              child: Column(children: [
            ListTile(
                leading: const Icon(Icons.switch_account_outlined),
                title: const Text('切换账号'),
                subtitle: const Text('退出当前账号，重新登录'),
                enabled: !_busy,
                onTap: _logout),
            const Divider(height: 1),
            ListTile(
                leading: const Icon(Icons.logout_rounded),
                title: const Text('退出登录'),
                enabled: !_busy,
                onTap: _logout),
          ])),
          if (_busy)
            const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator())),
          const SizedBox(height: 20),
          const Text('记录保存在服务器，卸载后重新登录仍可查看。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]));
  }
}
