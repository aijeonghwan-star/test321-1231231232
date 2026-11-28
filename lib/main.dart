import 'package:flutter/material.dart';

import 'imitate_screen.dart';
import 'match_screen.dart';

void main() => runApp(const VoiceMatchApp());

class VoiceMatchApp extends StatelessWidget {
  const VoiceMatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '목소리 흉내 연습',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF6C4CF1), useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF6C4CF1),
          brightness: Brightness.dark,
          useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tab == 0 ? '목소리 흉내 연습' : '목소리 닮은꼴 찾기'),
        centerTitle: true,
      ),
      // 탭을 바꿔도 각 화면 상태가 유지되도록 IndexedStack 사용
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: const [ImitateScreen(), MatchScreen()],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.graphic_eq), label: '흉내 연습'),
          NavigationDestination(icon: Icon(Icons.person_search), label: '닮은꼴 찾기'),
        ],
      ),
    );
  }
}
