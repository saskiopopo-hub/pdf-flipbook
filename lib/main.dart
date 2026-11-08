import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:page_flip/page_flip.dart';
import 'package:pdfx/pdfx.dart';

void main() => runApp(const MyApp());

/// Génère un petit son doux de page tournée (WAV en mémoire, pas de fichier).
Uint8List makeFlipWav() {
  const sampleRate = 22050;
  const seconds = 0.42;
  final n = (sampleRate * seconds).toInt();
  final rnd = Random(7);
  final data = ByteData(44 + n * 2);

  void str(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);

  var a = 0.0;
  var b = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    final noise = rnd.nextDouble() * 2 - 1;
    a += 0.12 * (noise - a);
    b += 0.20 * (a - b);
    final attack = (t / 0.2).clamp(0.0, 1.0);
    final env = attack * pow(1 - t, 2.0);
    final v = (b * env * 6.0).clamp(-1.0, 1.0);
    data.setInt16(44 + i * 2, (v * 32767).toInt(), Endian.little);
  }
  return data.buffer.asUint8List();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Flipbook',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AudioPlayer _player = AudioPlayer();
  final Uint8List _flipWav = makeFlipWav();
  List<Uint8List> _pages = [];
  bool _loading = false;
  bool _soundOn = true;
  String _progress = '';
  String? _fileName;
  int _bookId = 0;
  Offset? _down;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _playFlip() async {
    if (!_soundOn) return;
    try {
      await _player.stop();
      await _player.play(BytesSource(_flipWav), volume: 0.7);
    } catch (_) {}
  }

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result == null || result.files.single.path == null) return;

    final path = result.files.single.path!;
    setState(() {
      _loading = true;
      _pages = [];
      _fileName = result.files.single.name;
      _progress = '';
    });

    try {
      final doc = await PdfDocument.openFile(path);
      final total = doc.pagesCount;
      final images = <Uint8List>[];

      for (var i = 1; i <= total; i++) {
        final page = await doc.getPage(i);
        final img = await page.render(
          width: page.width * 1.5,
          height: page.height * 1.5,
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#FFFFFF',
          quality: 85,
        );
        await page.close();
        if (img != null) images.add(img.bytes);
        if (mounted) setState(() => _progress = '$i / $total');
      }
      await doc.close();

      if (!mounted) return;
      setState(() {
        _pages = images;
        _bookId++;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'ouvrir ce PDF')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName ?? 'PDF Flipbook'),
        actions: [
          IconButton(
            icon: Icon(_soundOn ? Icons.volume_up : Icons.volume_off),
            tooltip: 'Son',
            onPressed: () => setState(() => _soundOn = !_soundOn),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Choisir un PDF',
            onPressed: _loading ? null : _pickPdf,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Conversion... $_progress'),
          ],
        ),
      );
    }

    if (_pages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book, size: 96, color: Colors.teal),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _pickPdf,
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('Choisir un PDF'),
            ),
          ],
        ),
      );
    }

    return Listener(
      onPointerDown: (e) => _down = e.position,
      onPointerUp: (e) {
        final d = _down;
        _down = null;
        if (d != null && (e.position.dx - d.dx).abs() > 40) {
          _playFlip();
        }
      },
      child: Container(
        color: Colors.blueGrey.shade50,
        child: PageFlipWidget(
          key: ValueKey(_bookId),
          backgroundColor: Colors.blueGrey.shade50,
          lastPage: const Center(
            child: Text('Fin du livre', style: TextStyle(fontSize: 22)),
          ),
          children: [
            for (final bytes in _pages)
              Container(
                color: Colors.white,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
          ],
        ),
      ),
    );
  }
}
