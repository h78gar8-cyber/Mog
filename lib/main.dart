import 'package:flutter/material.dart';
import 'ui/theme/app_theme.dart';
import 'ui/screens/editor_screen.dart';

void main() {
  runApp(const MotionForgeApp());
}

class MotionForgeApp extends StatelessWidget {
  const MotionForgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MotionForge Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      // قفل التوجيه على الوضع الطولي فقط، لأن كل تخطيط التحرير مصمم لذلك
      home: const EditorScreen(),
    );
  }
}
