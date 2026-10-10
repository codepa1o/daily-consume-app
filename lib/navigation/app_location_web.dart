import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

const _pages = {'body', 'diary', 'workout', 'travel', 'female'};
final _pageChanges = StreamController<String?>.broadcast();
bool _listening = false;

String get _currentPage {
  final page = Uri.parse(web.window.location.href).queryParameters['page'];
  return _pages.contains(page) ? page! : 'body';
}

String get initialAppPage => _currentPage;

Stream<String?> get appPageChanges {
  if (!_listening) {
    _listening = true;
    web.window.addEventListener(
        'popstate', ((web.Event _) => _pageChanges.add(_currentPage)).toJS);
  }
  return _pageChanges.stream;
}

void pushAppPage(String page) {
  if (!_pages.contains(page) || page == _currentPage) return;
  final current = Uri.parse(web.window.location.href);
  final query = Map<String, String>.from(current.queryParameters);
  if (page == 'body') {
    query.remove('page');
  } else {
    query['page'] = page;
  }
  web.window.history
      .pushState(null, '', current.replace(queryParameters: query).toString());
}
