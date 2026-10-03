import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key});

  @override
  Widget build(BuildContext context) => ClipOval(
        child: ColoredBox(
          color: const Color(0xff64765a),
          child: Image.asset(
            'assets/branding/rem_logo.png',
            width: 33,
            height: 33,
            fit: BoxFit.contain,
            cacheWidth: (33 * MediaQuery.devicePixelRatioOf(context)).ceil(),
            semanticLabel: '日常 · 蕾姆 Logo',
          ),
        ),
      );
}
