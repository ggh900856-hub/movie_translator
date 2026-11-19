import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

void main() => runApp(const MyApp());

const _audioChannel = MethodChannel('audio_extractor');

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

// ===================== تحويل الفصحى لعامية مصرية =====================
// المفاتيح مكتوبة من غير تشكيل، وبهمزة واحدة (ا) بدل أ/إ/آ

const Map<String, String> _egyPhrases = {
  'لا اعرف': 'معرفش',
  'لا استطيع': 'مقدرش',
  'لا اريد': 'مش عايز',
  'لا يمكن': 'مش ممكن',
  'لا يوجد': 'مفيش',
  'من اجل': 'عشان',
  'كيف حالك': 'عامل إيه',
};

const Map<String, String> _egyWords = {
  'ماذا': 'إيه',
  'لماذا': 'ليه',
  'كيف': 'إزاي',
  'اين': 'فين',
  'متى': 'إمتى',
  'الان': 'دلوقتي',
  'هذا': 'ده',
  'هذه': 'دي',
  'هؤلاء': 'دول',
  'ذلك': 'ده',
  'تلك': 'دي',
  'جدا': 'أوي',
  'كثيرا': 'كتير',
  'قليلا': 'شوية',
  'ايضا': 'كمان',
  'حسنا': 'تمام',
  'نعم': 'أيوه',
  'ليس': 'مش',
  'ليست': 'مش',
  'الذي': 'اللي',
  'التي': 'اللي',
  'الذين': 'اللي',
  'يجب': 'لازم',
  'هناك': 'فيه',
  'اريد': 'عايز',
  'يريد': 'عايز',
  'تريد': 'عايز',
  'نريد': 'عايزين',
  'يريدون': 'عايزين',
  'رجل': 'راجل',
  'امراة': 'ست',
  'طفل': 'عيل',
  'اطفال': 'عيال',
  'منزل': 'بيت',
  'المنزل': 'البيت',
  'سيارة': 'عربية',
  'ذهب': 'راح',
  'يذهب': 'يروح',
  'اذهب': 'روح',
  'نذهب': 'نروح',
  'ذهبنا': 'روحنا',
  'معي': 'معايا',
  'معك': 'معاك',
  'معه': 'معاه',
  'معها': 'معاها',
  'معهم': 'معاهم',
  'معنا': 'معانا',
  'لدي': 'عندي',
  'لديك': 'عندك',
  'لديه': 'عنده',
  'لديها': 'عندها',
  'لدينا': 'عندنا',
  'لديهم': 'عندهم',
  'جيد': 'كويس',
  'جيدة': 'كويسة',
  'سيء': 'وحش',
  'الجميع': 'كله',
  'هيا': 'يلا',
  'لكن': 'بس',
  'ولكن': 'بس',
  'فقط': 'بس',
  'لان': 'عشان',
  'لكي': 'عشان',
  'حتى': 'لحد',
  'مرحبا': 'أهلا',
  'ربما': 'ممكن',
  'رايت': 'شفت',
  'راى': 'شاف',
  'ارى': 'أشوف',
  'نرى': 'نشوف',
  'يرى': 'يشوف',
  'انظر': 'بص',
  'انظروا': 'بصوا',
  'غدا': 'بكرة',
  'امس': 'إمبارح',
  'البارحة': 'إمبارح',
  'شيء': 'حاجة',
  'اشياء': 'حاجات',
  'شيئا': 'حاجة',
  'احتاج': 'محتاج',
  'تحتاج': 'محتاج',
  'يحتاج': 'محتاج',
};

class _Tok {
  final String pre;
  final String core;
  final String post;
  _Tok(this.pre, this.core, this.post);
}

final RegExp _tokRe =
    RegExp(r'^([^\u0621-\u065F]*)([\u0621-\u065F]+)([^\u0621-\u065F]*)$');

_Tok? _parseTok(String t) {
  final m = _tokRe.firstMatch(t);
  if (m == null) return null;
  return _Tok(m.group(1)!, m.group(2)!, m.group(3)!);
}

String _norm(String s) => s
    .replaceAll(RegExp(r'[\u064B-\u065F\u0640]'), '')
    .replaceAll(RegExp(r'[أإآ]'), 'ا');

String _toEgyptian(String text) {
  final tokens = text.split(' ');
  final out = <String>[];
  var i = 0;
  while (i < tokens.length) {
    final a = _parseTok(tokens[i]);

    // عبارات من كلمتين
    if (a != null && a.post.isEmpty && i + 1 < tokens.length) {
      final b = _parseTok(tokens[i + 1]);
      if (b != null) {
        final rep = _egyPhrases['${_norm(a.core)} ${_norm(b.core)}'];
        if (rep != null) {
          out.add('${a.pre}$rep${b.post}');
          i += 2;
          continue;
        }
      }
    }

    if (a != null) {
      final key = _norm(a.core);
      final rep = _egyWords[key];
      if (rep != null) {
        out.add('${a.pre}$rep${a.post}');
      } else if (key.length > 2 &&
          key.startsWith('و') &&
          _egyWords[key.substring(1)] != null) {
        // كلمة بواو العطف: "وماذا" ← "وإيه"
        out.add('${a.pre}و${_egyWords[key.substring(1)]}${a.post}');
      } else {
        out.add(tokens[i]);
      }
    } else {
      out.add(tokens[i]);
    }
    i++;
  }
  return out.join(' ');
}

// ======================================================================

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

  bool _egy = false; // عامية مصرية
  bool _busy = false; // مرحلة التجهيز قبل ما الفيديو يشتغل
  bool _processing = false; // الترجمة شغالة في الخلفية
  bool _waiting = false; // الفيديو واقف مستني الترجمة
  double _processedUpTo = 0; // الترجمة وصلت لثانية كام
  double _totalSec = 0;
  int _runId = 0;

  @override
  void dispose() {
    _runId++; // يوقف أي معالجة شغالة
    _audioChannel.setMethodCallHandler(null);
    _vc?.removeListener(_onTick);
    _vc?.dispose();
    super.dispose();
  }

  String _fmt(double s) {
    final m = s ~/ 60;
    final sec = (s % 60).floor();
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  // يعرض اسم المرحلة + النسبة الإجمالية للتجهيز (0 → 1)
  void _setStage(String label, double overall, int myRun) {
    if (!mounted || myRun != _runId) return;
    final v = overall.clamp(0.0, 1.0);
    final text = '$label ${(v * 100).floor()}%';
    if (text == _status) return;
    setState(() {
      _progress = v;
      _status = text;
    });
  }

  String _display(String arabic) => _egy ? _toEgyptian(arabic) : arabic;

  Future<void> _seekBy(int seconds) async {
    final vc = _vc;
    if (vc == null || !vc.value.isInitialized) return;
    var target = vc.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    final dur = vc.value.duration;
    if (target > dur) target = dur;
    await vc.seekTo(target);
  }

  // تحميل ملف مع نسبة حقيقية
  Future<void> _downloadFile(
      String url, String dest, void Function(double) onProgress) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw 'فشل تحميل الموديل (${resp.statusCode})';
      }
      final total = resp.contentLength;
      final sink = File(dest).openWrite();
      int got = 0;
      int lastPct = -1;
      await for (final chunk in resp) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          final pi = (got * 100 / total).floor();
          if (pi != lastPct) {
            lastPct = pi;
            onProgress(got / total);
          }
        }
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
    }
  }

  // فك ضغط مع نسبة حقيقية
  Future<void> _unzip(
      String zipPath, String destRoot, void Function(double) onProgress) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = archive.files.where((f) => f.isFile).toList();
    if (files.isEmpty) throw 'ملف الموديل فاضي';

    final first = files.first.name;
    final slash = first.indexOf('/');
    final prefix = slash > 0 ? first.substring(0, slash + 1) : '';

    int i = 0;
    int lastPct = -1;
    for (final f in files) {
      var rel = f.name;
      if (prefix.isNotEmpty && rel.startsWith(prefix)) {
        rel = rel.substring(prefix.length);
      }
      i++;
      if (rel.isEmpty || rel.contains('..')) continue;
      final out = File('$destRoot/$rel');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>);
      final pi = (i * 100 / files.length).floor();
      if (pi != lastPct) {
        lastPct = pi;
        onProgress(i / files.length);
        await Future.delayed(Duration.zero); // نسيب الشاشة تتحدث
      }
    }
  }

  // يرجّع مسار موديل Vosk (بيحمّله ويفكه لو مش موجود)
  Future<String> _prepareVoskModel(int myRun) async {
    final support = await getApplicationSupportDirectory();
    final modelName = _src.modelUrl.split('/').last.replaceAll('.zip', '');
    final root = '${support.path}/vosk/$modelName';
    final marker = File('$root/.ok');

    if (await marker.exists()) {
      _setStage('موديل الكلام موجود', 0.80, myRun);
      return root;
    }

    // لو فيه محاولة ناقصة قبل كده نمسحها
    final dir = Directory(root);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    final zipPath = '${support.path}/vosk/$modelName.zip';
    await _downloadFile(_src.modelUrl, zipPath, (p) {
      _setStage('بنحمّل موديل التعرف على الكلام', 0.45 + 0.25 * p, myRun);
    });
    if (!mounted || myRun != _runId) return root;

    await _unzip(zipPath, root, (p) {
      _setStage('بنفك ضغط الموديل', 0.70 + 0.10 * p, myRun);
    });

    try {
      await File(zipPath).delete();
    } catch (_) {}
    await marker.writeAsString('ok');
    return root;
  }

  Future<void> _pickAndProcess() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.video);
    if (picked == null || picked.files.single.path == null) return;
    final videoPath = picked.files.single.path!;

    final myRun = ++_runId;

    _vc?.removeListener(_onTick);
    await _vc?.dispose();
    _vc = null;
    _subs.clear();
    _current = '';
    _waiting = false;
    _processedUpTo = 0;
    _totalSec = 0;

    setState(() {
      _busy = true;
      _processing = false;
      _progress = 0;
      _status = 'بنطلّع الصوت من الفيديو 0%';
    });

    // استقبال نسبة استخراج الصوت من أندرويد (0 → 45% من التجهيز)
    _audioChannel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        final p = (call.arguments as num).toInt();
        if (_busy) {
          _setStage('بنطلّع الصوت من الفيديو', 0.45 * p / 100.0, myRun);
        }
      }
    });

    RandomAccessFile? raf;
    OnDeviceTranslator? translator;

    try {
      // 1) استخراج الصوت: WAV مونو 16kHz
      final tmp = await getTemporaryDirectory();
      final wavPath = '${tmp.path}/audio.wav';
      final old = File(wavPath);
      if (await old.exists()) await old.delete();

      await _audioChannel.invokeMethod('extract', {
        'input': videoPath,
        'output': wavPath,
      });
      if (!mounted || myRun != _runId) return;

      // 2) موديل Vosk: تحميل + فك ضغط (45 → 80%)
      final modelPath = await _prepareVoskModel(myRun);
      if (!mounted || myRun != _runId) return;

      // 3) موديلات الترجمة (80 → 90%)
      final needed = [_src.ml, TranslateLanguage.arabic];
      for (var i = 0; i < needed.length; i++) {
        final l = needed[i];
        _setStage('بنحمّل موديل الترجمة ${i + 1} من ${needed.length}',
            0.80 + 0.10 * (i / needed.length), myRun);
        if (!await _mm.isModelDownloaded(l.bcpCode)) {
          await _mm.downloadModel(l.bcpCode, isWifiRequired: false);
        }
        _setStage('بنحمّل موديل الترجمة ${i + 1} من ${needed.length}',
            0.80 + 0.10 * ((i + 1) / needed.length), myRun);
        if (!mounted || myRun != _runId) return;
      }
      translator = OnDeviceTranslator(
        sourceLanguage: _src.ml,
        targetLanguage: TranslateLanguage.arabic,
      );

      // 4) تحميل موديل الكلام في الذاكرة (90 → 100%)
      _setStage('بنحمّل الموديل في الذاكرة', 0.90, myRun);
      final vosk = VoskFlutterPlugin.instance();
      final model = await vosk.createModel(modelPath);
      _setStage('بنحمّل الموديل في الذاكرة', 0.97, myRun);
      final rec = await vosk.createRecognizer(model: model, sampleRate: 16000);
      await rec.setWords(words: true);
      _setStage('التجهيز خلص', 1.0, myRun);
      if (!mounted || myRun != _runId) return;

      // 5) نشغّل الفيديو فورًا، والترجمة تكمل في الخلفية
      final total = await File(wavPath).length();
      _totalSec = (total - 44) / 32000.0;

      final vc = VideoPlayerController.file(File(videoPath));
      await vc.initialize();
      if (!mounted || myRun != _runId) {
        await vc.dispose();
        return;
      }
      vc.addListener(_onTick);
      _vc = vc;
      setState(() {
        _busy = false;
        _processing = true;
        _progress = 0;
        _status = 'الترجمة 0%';
      });
      await vc.play();

      // 6) تفريغ الصوت + ترجمة
      raf = await File(wavPath).open();
      await raf.setPosition(44); // نتخطى هيدر WAV
      int readBytes = 44;
      int lastPercent = -1;
      const chunk = 128000; // 4 ثواني صوت

      Future<void> handle(String jsonStr) async {
        final j = jsonDecode(jsonStr) as Map<String, dynamic>;
        final text = (j['text'] ?? '').toString().trim();
        final words = j['result'];
        if (text.isEmpty || words is! List || words.isEmpty) return;
        final start = (words.first['start'] as num).toDouble();
        final end = (words.last['end'] as num).toDouble();
        final ar = await translator!.translateText(text);
        _subs.add(Sub(start, end, text, ar));
      }

      while (true) {
        if (!mounted || myRun != _runId) return;
        final bytes = await raf.read(chunk);
        if (bytes.isEmpty) break;
        readBytes += bytes.length;

        final done = await rec.acceptWaveformBytes(Uint8List.fromList(bytes));
        if (done) {
          await handle(await rec.getResult());
        }

        _processedUpTo = (readBytes - 44) / 32000.0;
        final percent = _totalSec > 0
            ? ((_processedUpTo / _totalSec) * 100).floor()
            : 0;
        if (percent != lastPercent && mounted && myRun == _runId) {
          lastPercent = percent;
          setState(() {
            _progress = _totalSec > 0 ? _processedUpTo / _totalSec : 0;
            _status =
                'الترجمة وصلت لـ ${_fmt(_processedUpTo)} من ${_fmt(_totalSec)} ($percent%)';
          });
        }
      }
      await handle(await rec.getFinalResult());
      _processedUpTo = _totalSec + 1000; // خلصنا، مفيش انتظار تاني

      if (mounted && myRun == _runId) {
        setState(() {
          _progress = 1;
          _status = 'تمت الترجمة 100%: ${_subs.length} جملة';
        });
      }
    } catch (e) {
      if (mounted && myRun == _runId) {
        setState(() {
          _status = 'حصل خطأ: $e';
        });
      }
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      try {
        await translator?.close();
      } catch (_) {}
      if (mounted && myRun == _runId) {
        setState(() {
          _busy = false;
          _processing = false;
        });
        if (_waiting) {
          _waiting = false;
          _vc?.play();
        }
      }
    }
  }

  void _onTick() {
    final vc = _vc;
    if (vc == null) return;
    final pos = vc.value.position.inMilliseconds / 1000.0;

    // لو المشاهدة سبقت الترجمة: نقف ونستنى
    if (_processing) {
      if (!_waiting && vc.value.isPlaying && pos > _processedUpTo - 4) {
        _waiting = true;
        vc.pause();
        if (mounted) setState(() {});
      } else if (_waiting && pos < _processedUpTo - 12) {
        _waiting = false;
        vc.play();
        if (mounted) setState(() {});
      }
    }

    String text = '';
    for (final s in _subs) {
      if (pos >= s.start - 0.2 && pos <= s.end + 0.6) {
        text = _display(s.arabic);
        break;
      }
    }
    if (text != _current && mounted) {
      setState(() => _current = text);
    }
  }

  Widget _controls(VideoPlayerController vc) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: vc,
        builder: (context, v, _) {
          return Column(
            children: [
              Text(
                '${_fmt(v.position.inMilliseconds / 1000.0)} / ${_fmt(v.duration.inMilliseconds / 1000.0)}',
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 34,
                    tooltip: 'رجوع 30 ثانية',
                    icon: const Icon(Icons.replay_30),
                    onPressed: () => _seekBy(-30),
                  ),
                  IconButton(
                    iconSize: 34,
                    tooltip: 'رجوع 10 ثواني',
                    icon: const Icon(Icons.replay_10),
                    onPressed: () => _seekBy(-10),
                  ),
                  IconButton(
                    iconSize: 48,
                    icon: Icon(
                        v.isPlaying ? Icons.pause_circle : Icons.play_circle),
                    onPressed: () {
                      v.isPlaying ? vc.pause() : vc.play();
                    },
                  ),
                  IconButton(
                    iconSize: 34,
                    tooltip: 'تقديم 10 ثواني',
                    icon: const Icon(Icons.forward_10),
                    onPressed: () => _seekBy(10),
                  ),
                  IconButton(
                    iconSize: 34,
                    tooltip: 'تقديم 30 ثانية',
                    icon: const Icon(Icons.forward_30),
                    onPressed: () => _seekBy(30),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vc = _vc;
    final locked = _busy || _processing;
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
                  onChanged: locked ? null : (v) => setState(() => _src = v!),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('عامية مصرية'),
              subtitle: const Text('تحويل تقريبي للكلمات الشائعة'),
              value: _egy,
              onChanged: (v) {
                setState(() => _egy = v);
                _current = '';
                _onTick();
              },
            ),
            FilledButton.icon(
              onPressed: locked ? null : _pickAndProcess,
              icon: const Icon(Icons.video_library),
              label: const Text('اختار فيديو'),
            ),
            const SizedBox(height: 8),
            if (_busy || _processing) LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text(_status, textAlign: TextAlign.center),
            if (_waiting)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'الفيديو واقف شوية لحد ما الترجمة تسبقه...',
                  style: TextStyle(color: Colors.orange),
                  textAlign: TextAlign.center,
                ),
              ),
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
                    _controls(vc),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}