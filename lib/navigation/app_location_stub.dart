import 'dart:async';

String get initialAppPage => 'body';
Stream<String?> get appPageChanges => const Stream<String?>.empty();
void pushAppPage(String page) {}
