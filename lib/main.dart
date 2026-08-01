import 'package:flutter/material.dart';

import 'package:everlink/ui/home_page.dart';

void main() {
  runApp(const EverlinkApp());
}

/// 应用根组件。
class EverlinkApp extends StatelessWidget {
  const EverlinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EverLink 设备调试',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.light,
        ),
      ),
      home: const HomePage(),
    );
  }
}
