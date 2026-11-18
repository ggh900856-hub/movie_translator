import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

void main() => runApp(const MyApp());

class SrcLang {
  final String name;
  final TranslateLanguage ml;
  final String modelUrl;
  const SrcLang(this.name, this.ml, this.modelUrl);
}

const _base = 'https://alphacephei.com/vosk/models/';
const srcLangs = <SrcLang>[
  SrcLang('English', TranslateLanguage.english,
      '${_base}vosk-model-small-en-us-0.15.zip'),
  SrcLang('Français', TranslateLanguage.french,
      '${_base}vosk-model-small-fr-0.22.zip'),
  SrcLang('Deutsch', TranslateLanguage.german,
      '${_base}vosk-model-small-de-0.15.zip'),
  SrcLang('Español', TranslateLanguage.spanish,
      '${_base}vosk-model-small-es-0.42.zip'),
  SrcLang('Русский', TranslateLanguage.russian,
      '${_base}vosk-model-small-ru-0.22.zip'),
  SrcLang('Türkçe', TranslateLanguage.turkish,
      '${_base}vosk-model-small-tr-0.3.zip'),
];

class Sub {
  final double start;
  final double end;
  final String original;
  String arabic;
  Sub(this.start, this.end, this.original, this.arabic);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'مترجم الأفلام',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: MoviePage(),
      ),
    );
  }
}

class MoviePage extends StatefulWidget {
  const MoviePage({super.key});

  @override
  State<MoviePage> createState() => _MoviePageState();
}

class _MoviePageState extends State<MoviePage> {
  final OnDeviceTranslatorModelManager _mm = OnDeviceTranslatorModelManager();

  SrcLang _src = srcLangs[0];
  VideoPlayerController? _vc;
  final List<Sub> _subs = [];
  String _current = '';
  String _status = 'اختار فيلم أو فيديو وابدأ';
  double _progress = 0;
  bool _busy = false;

  @override
  void dispose() {
    _vc?.dispose();
    super.dispose();
  }

  Future<void> _ensureMlModel(TranslateLanguage l) async {
    if (!await _mm.isModelDownloaded(l.bcpCode)) {
      await _mm.downloadModel(l.bcpCode, isWifiRequired: false);
    }
  }

  Future<void> _pickAndProcess() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.video);
    if (picked == null || picked.files.single.path == null) return;
    final videoPath = picked.files.single.path!;

    _vc?.removeListener(_onTick);
    await _vc?.dispose();
    _vc = null;
    _subs.clear();
    _current = '';

    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'بنطلّع الصوت من الفيديو...';
    });

    try {
      // 1) استخراج الصوت: WAV مونو 16kHz
      final tmp = await getTemporaryDirectory();
      final wavPath = '${tmp.path}/audio.wav';
      final old = File(wavPath);
      if (await old.exists()) await old.delete();

      final session = await FFmpegKit.execute(
          '-y -i "$videoPath" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$wavPath"');
      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        throw 'فشل استخراج الصوت من الفيديو';
      }

      // 2) تحميل موديل Vosk (مرة واحدة)
      setState(() => _status = 'بنجهّز موديل التعرف على الكلام (مرة واحدة)...');
      final vosk = VoskFlutterPlugin.instance();
      final loader = ModelLoader();
      final modelName = _src.modelUrl.split('/').last.replaceAll('.zip', '');
      final String modelPath;
      if (await loader.isModelAlreadyLoaded(modelName)) {
        modelPath = await loader.modelPath(modelName);
      } else {
        modelPath = await loader.loadFromNetwork(_src.modelUrl);
      }
      final model = await vosk.createModel(modelPath);
      final rec = await vosk.createRecognizer(model: model, sampleRate: 16000);
      await rec.setWords(words: true);

      // 3) موديلات الترجمة
      setState(() => _status = 'بنجهّز موديل الترجمة...');
      await _ensureMlModel(_src.ml);
      await _ensureMlModel(TranslateLanguage.arabic);
      final translator = OnDeviceTranslator(
        sourceLanguage: _src.ml,
        targetLanguage: TranslateLanguage.arabic,
      );

      // 4) تفريغ الصوت + ترجمة
      setState(() => _status = 'بنسمع الفيلم ونترجم... ممكن ياخد وقت');
      final raf = await File(wavPath).open();
      final total = await raf.length();
      await raf.setPosition(44); // نتخطى هيدر WAV
      int readBytes = 44;
      const chunk = 32000; // ثانية صوت

      Future<void> handle(String jsonStr) async {
        final j = jsonDecode(jsonStr) as Map<String, dynamic>;
        final text = (j['text'] ?? '').toString().trim();
        final words = j['result'];
        if (text.isEmpty || words is! List || words.isEmpty) return;
        final start = (words.first['start'] as num).toDouble();
        final end = (words.last['end'] as num).toDouble();
        final ar = await translator.translateText(text);
        _subs.add(Sub(start, end, text, ar));
      }

      while (true) {
        final bytes = await raf.read(chunk);
        if (bytes.isEmpty) break;
        readBytes += bytes.length;
        final done = await rec.acceptWaveformBytes(Uint8List.fromList(bytes));
        if (done) {
          await handle(await rec.getResult());
        }
        if (mounted) {
          setState(() {
            _progress = readBytes / total;
            _status =
                'بنسمع ونترجم... ${(_progress * 100).toStringAsFixed(0)}%';
          });
        }
      }
      await handle(await rec.getFinalResult());
      await raf.close();
      await translator.close();

      // 5) تشغيل الفيديو
      final vc = VideoPlayerController.file(File(videoPath));
      await vc.initialize();
      vc.addListener(_onTick);
      _vc = vc;
      await vc.play();

      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'تمت الترجمة: ${_subs.length} جملة';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'حصل خطأ: $e';
        });
      }
    }
  }

  void _onTick() {
    final vc = _vc;
    if (vc == null) return;
    final pos = vc.value.position.inMilliseconds / 1000.0;
    String text = '';
    for (final s in _subs) {
      if (pos >= s.start - 0.2 && pos <= s.end + 0.6) {
        text = s.arabic;
        break;
      }
    }
    if (text != _current && mounted) {
      setState(() => _current = text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = _vc;
    return Scaffold(
      appBar: AppBar(title: const Text('مترجم الأفلام')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                const Text('لغة الفيلم: '),
                const SizedBox(width: 8),
                DropdownButton<SrcLang>(
                  value: _src,
                  items: srcLangs
                      .map((l) =>
                          DropdownMenuItem(value: l, child: Text(l.name)))
                      .toList(),
                  onChanged: _busy ? null : (v) => setState(() => _src = v!),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _pickAndProcess,
              icon: const Icon(Icons.video_library),
              label: const Text('اختار فيديو'),
            ),
            const SizedBox(height: 8),
            if (_busy)
              LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress),
            const SizedBox(height: 8),
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (vc != null && vc.value.isInitialized)
              Expanded(
                child: Column(
                  children: [
                    AspectRatio(
                      aspectRatio: vc.value.aspectRatio,
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          VideoPlayer(vc),
                          if (_current.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.all(8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                _current,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 16),
                              ),
                            ),
                        ],
                      ),
                    ),
                    VideoProgressIndicator(vc, allowScrubbing: true),
                    IconButton(
                      iconSize: 40,
                      icon: Icon(vc.value.isPlaying
                          ? Icons.pause_circle
                          : Icons.play_circle),
                      onPressed: () {
                        setState(() {
                          vc.value.isPlaying ? vc.pause() : vc.play();
                        });
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}