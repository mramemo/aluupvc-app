import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const AluUpvcApp());
}

/// =====================
/// Models
/// =====================
class RulesDb {
  final List<Company> companies;
  RulesDb({required this.companies});

  static RulesDb fromJson(Map<String, dynamic> j) {
    final companies = (j['companies'] as List? ?? [])
        .map((e) => Company.fromJson(e as Map<String, dynamic>))
        .toList();
    return RulesDb(companies: companies);
  }

  Map<String, dynamic> toJson() => {
        'companies': companies.map((c) => c.toJson()).toList(),
      };
}

class Company {
  final String nameAr;
  final String nameEn;
  final List<Series> series;
  Company({required this.nameAr, required this.nameEn, required this.series});

  static Company fromJson(Map<String, dynamic> j) {
    final series = (j['series'] as List? ?? [])
        .map((e) => Series.fromJson(e as Map<String, dynamic>))
        .toList();
    return Company(
      nameAr: (j['name_ar'] ?? '').toString(),
      nameEn: (j['name_en'] ?? '').toString(),
      series: series,
    );
  }

  Map<String, dynamic> toJson() => {
        'name_ar': nameAr,
        'name_en': nameEn,
        'series': series.map((s) => s.toJson()).toList(),
      };
}

class Series {
  final String nameAr;
  final String nameEn;
  final List<Template> templates;
  Series({required this.nameAr, required this.nameEn, required this.templates});

  static Series fromJson(Map<String, dynamic> j) {
    final templates = (j['templates'] as List? ?? [])
        .map((e) => Template.fromJson(e as Map<String, dynamic>))
        .toList();
    return Series(
      nameAr: (j['name_ar'] ?? '').toString(),
      nameEn: (j['name_en'] ?? '').toString(),
      templates: templates,
    );
  }

  Map<String, dynamic> toJson() => {
        'name_ar': nameAr,
        'name_en': nameEn,
        'templates': templates.map((t) => t.toJson()).toList(),
      };
}

class Template {
  String nameAr;
  String nameEn;
  Map<String, double> constants;
  List<Part> parts;

  Template({
    required this.nameAr,
    required this.nameEn,
    required this.constants,
    required this.parts,
  });

  static Template fromJson(Map<String, dynamic> j) {
    final constantsRaw = (j['constants'] as Map?) ?? {};
    final constants = <String, double>{};
    for (final entry in constantsRaw.entries) {
      final k = entry.key.toString();
      final v = entry.value;
      final d = (v is num) ? v.toDouble() : double.tryParse(v.toString());
      if (d != null) constants[k] = d;
    }

    final parts = (j['parts'] as List? ?? [])
        .map((e) => Part.fromJson(e as Map<String, dynamic>))
        .toList();

    return Template(
      nameAr: (j['name_ar'] ?? '').toString(),
      nameEn: (j['name_en'] ?? '').toString(),
      constants: constants,
      parts: parts,
    );
  }

  Map<String, dynamic> toJson() => {
        'name_ar': nameAr,
        'name_en': nameEn,
        'constants': constants,
        'parts': parts.map((p) => p.toJson()).toList(),
      };
}

class Part {
  String group;
  String nameAr;
  String nameEn;
  String formula; // length formula
  String qty; // quantity formula
  String notesAr;
  String notesEn;

  Part({
    required this.group,
    required this.nameAr,
    required this.nameEn,
    required this.formula,
    required this.qty,
    required this.notesAr,
    required this.notesEn,
  });

  static Part fromJson(Map<String, dynamic> j) {
    return Part(
      group: (j['group'] ?? 'Default').toString(),
      nameAr: (j['name_ar'] ?? '').toString(),
      nameEn: (j['name_en'] ?? '').toString(),
      formula: (j['formula'] ?? '').toString(),
      qty: (j['qty'] ?? '1').toString(),
      notesAr: (j['notes_ar'] ?? '').toString(),
      notesEn: (j['notes_en'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'group': group,
        'name_ar': nameAr,
        'name_en': nameEn,
        'formula': formula,
        'qty': qty,
        'notes_ar': notesAr,
        'notes_en': notesEn,
      };
}

/// Project input row
class SizeRow {
  String code;
  double wCm;
  double hCm;
  int qty;
  SizeRow({required this.code, required this.wCm, required this.hCm, required this.qty});
}

/// Output cut item
class CutItem {
  final String group;
  final String partName;
  final double lengthCm;
  final int qty;
  CutItem({required this.group, required this.partName, required this.lengthCm, required this.qty});

  double get lengthM => lengthCm / 100.0;
}

/// =====================
/// Expression Evaluator
/// Supports: numbers, + - * / () and variables (W, H, plus constants like ADD_W)
/// =====================
class ExprEval {
  static double? eval(String expr, {required double W, required double H, required Map<String, double> vars}) {
    final tokens = _tokenize(expr, W: W, H: H, vars: vars);
    if (tokens == null || tokens.isEmpty) return null;
    final rpn = _toRpn(tokens);
    if (rpn == null) return null;
    return _evalRpn(rpn);
  }

  static List<String>? _tokenize(String expr, {required double W, required double H, required Map<String, double> vars}) {
    var s = expr.trim();
    if (s.isEmpty) return null;

    // normalize Arabic digits and separators
    s = normalizeArabicNumbers(s);

    final out = <String>[];
    int i = 0;

    bool isDigit(String ch) => RegExp(r'[0-9.]').hasMatch(ch);

    String readNumber() {
      final start = i;
      while (i < s.length && isDigit(s[i])) i++;
      return s.substring(start, i);
    }

    String readIdent() {
      final start = i;
      while (i < s.length && RegExp(r'[A-Za-z_]').hasMatch(s[i])) i++;
      return s.substring(start, i);
    }

    while (i < s.length) {
      final ch = s[i];
      if (ch.trim().isEmpty) {
        i++;
        continue;
      }
      if ("+-*/()".contains(ch)) {
        out.add(ch);
        i++;
        continue;
      }
      if (isDigit(ch)) {
        final numStr = readNumber();
        out.add(numStr);
        continue;
      }
      if (RegExp(r'[A-Za-z_]').hasMatch(ch)) {
        final id = readIdent();
        double? v;
        if (id == 'W') v = W;
        if (id == 'H') v = H;
        v ??= vars[id];
        if (v == null) return null;
        out.add(v.toString());
        continue;
      }
      // unknown char
      return null;
    }

    // handle unary minus by inserting 0 before - when appropriate
    final fixed = <String>[];
    for (int k = 0; k < out.length; k++) {
      final t = out[k];
      if (t == '-' && (k == 0 || "+-*/(".contains(out[k - 1]))) {
        fixed.add('0');
      }
      fixed.add(t);
    }
    return fixed;
  }

  static int _prec(String op) => (op == '+' || op == '-') ? 1 : 2;

  static List<String>? _toRpn(List<String> tokens) {
    final output = <String>[];
    final stack = <String>[];
    bool isOp(String t) => t == '+' || t == '-' || t == '*' || t == '/';

    for (final t in tokens) {
      if (double.tryParse(t) != null) {
        output.add(t);
      } else if (isOp(t)) {
        while (stack.isNotEmpty && isOp(stack.last) && _prec(stack.last) >= _prec(t)) {
          output.add(stack.removeLast());
        }
        stack.add(t);
      } else if (t == '(') {
        stack.add(t);
      } else if (t == ')') {
        while (stack.isNotEmpty && stack.last != '(') {
          output.add(stack.removeLast());
        }
        if (stack.isEmpty) return null;
        stack.removeLast(); // pop '('
      } else {
        return null;
      }
    }
    while (stack.isNotEmpty) {
      final t = stack.removeLast();
      if (t == '(' || t == ')') return null;
      output.add(t);
    }
    return output;
  }

  static double? _evalRpn(List<String> rpn) {
    final st = <double>[];
    for (final t in rpn) {
      final num = double.tryParse(t);
      if (num != null) {
        st.add(num);
        continue;
      }
      if (st.length < 2) return null;
      final b = st.removeLast();
      final a = st.removeLast();
      switch (t) {
        case '+':
          st.add(a + b);
          break;
        case '-':
          st.add(a - b);
          break;
        case '*':
          st.add(a * b);
          break;
        case '/':
          st.add(a / b);
          break;
        default:
          return null;
      }
    }
    if (st.length != 1) return null;
    return st.single;
  }
}

/// =====================
/// Scan helpers (Arabic sketch OCR)
/// Patterns supported:
///  - W×H
///  - W×H×Q (Q at the end)
/// Arabic digits supported.
/// =====================
String normalizeArabicNumbers(String s) {
  const ar = ['٠','١','٢','٣','٤','٥','٦','٧','٨','٩'];
  const en = ['0','1','2','3','4','5','6','7','8','9'];
  for (int i = 0; i < ar.length; i++) {
    s = s.replaceAll(ar[i], en[i]);
  }
  s = s.replaceAll('،', '.');
  s = s.replaceAll('×', 'x');
  s = s.replaceAll('*', 'x');
  return s;
}

class ScanRow {
  double w;
  double h;
  int qty;
  ScanRow({required this.w, required this.h, required this.qty});
}

List<ScanRow> extractSketchRows(String raw) {
  final t = normalizeArabicNumbers(raw);
  final out = <ScanRow>[];

  // W x H x Q  (Q integer)
  final re3 = RegExp(r'(?<!\d)(\d+(?:\.\d+)?)\s*x\s*(\d+(?:\.\d+)?)\s*x\s*(\d+)(?!\d)');
  // W x H
  final re2 = RegExp(r'(?<!\d)(\d+(?:\.\d+)?)\s*x\s*(\d+(?:\.\d+)?)(?!\d)');

  for (final m in re3.allMatches(t)) {
    final w = double.tryParse(m.group(1)!) ?? 0;
    final h = double.tryParse(m.group(2)!) ?? 0;
    final q = int.tryParse(m.group(3)!) ?? 1;
    if (w > 0 && h > 0 && q > 0) out.add(ScanRow(w: w, h: h, qty: q));
  }

  // remove triple matches to avoid duplicates
  final t2 = t.replaceAll(re3, ' ');
  for (final m in re2.allMatches(t2)) {
    final w = double.tryParse(m.group(1)!) ?? 0;
    final h = double.tryParse(m.group(2)!) ?? 0;
    if (w > 0 && h > 0) out.add(ScanRow(w: w, h: h, qty: 1));
  }

  return out;
}

/// =====================
/// Storage
/// =====================
class RulesStore {
  static const _kKey = 'rules_json_v03';

  static Future<RulesDb> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_kKey);
    if (s != null && s.trim().isNotEmpty) {
      try {
        return RulesDb.fromJson(jsonDecode(s) as Map<String, dynamic>);
      } catch (_) {}
    }
    final raw = await rootBundle.loadString('assets/rules_default.json');
    final db = RulesDb.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    await save(db);
    return db;
  }

  static Future<void> save(RulesDb db) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, jsonEncode(db.toJson()));
  }

  static Future<void> resetToDefault() async {
    final raw = await rootBundle.loadString('assets/rules_default.json');
    final db = RulesDb.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    await save(db);
  }

  static Future<File> exportToFile() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_kKey) ?? '';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/rules_backup.json');
    await file.writeAsString(s.isEmpty ? '{}' : s, encoding: utf8);
    return file;
  }

  static Future<void> importFromPickedFile() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    if (res == null || res.files.isEmpty) return;
    final path = res.files.single.path;
    if (path == null) return;
    final content = await File(path).readAsString(encoding: utf8);
    final db = RulesDb.fromJson(jsonDecode(content) as Map<String, dynamic>);
    await save(db);
  }
}

/// =====================
/// App
/// =====================
class AluUpvcApp extends StatefulWidget {
  const AluUpvcApp({super.key});

  @override
  State<AluUpvcApp> createState() => _AluUpvcAppState();
}

class _AluUpvcAppState extends State<AluUpvcApp> {
  String lang = 'ar';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AluUPVC Pro Trial',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E5AA8)),
        useMaterial3: true,
      ),
      home: FutureBuilder<RulesDb>(
        future: RulesStore.load(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return HomePage(
            initialDb: snap.data!,
            lang: lang,
            onToggleLang: () => setState(() => lang = (lang == 'ar') ? 'en' : 'ar'),
            onDbChanged: (db) async {
              await RulesStore.save(db);
              setState(() {});
            },
            onRequestReload: () => setState(() {}),
          );
        },
      ),
    );
  }
}

/// =====================
/// Home Page: project input (table), scan FAB, calculate -> Results
/// =====================
class HomePage extends StatefulWidget {
  final RulesDb initialDb;
  final String lang;
  final VoidCallback onToggleLang;
  final Future<void> Function(RulesDb) onDbChanged;
  final VoidCallback onRequestReload;

  const HomePage({
    super.key,
    required this.initialDb,
    required this.lang,
    required this.onToggleLang,
    required this.onDbChanged,
    required this.onRequestReload,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late RulesDb db;

  int companyIdx = 0;
  int seriesIdx = 0;
  int templateIdx = 0;

  final List<SizeRow> items = [];
  int _codeCounter = 1;

  @override
  void initState() {
    super.initState();
    db = widget.initialDb;
    items.add(SizeRow(code: 'W1', wCm: 120, hCm: 150, qty: 1));
    _codeCounter = 2;
  }

  Company get company => db.companies.isEmpty ? Company(nameAr: '—', nameEn: '—', series: []) : db.companies[companyIdx.clamp(0, db.companies.length - 1)];
  Series get series => company.series.isEmpty ? Series(nameAr: '—', nameEn: '—', templates: []) : company.series[seriesIdx.clamp(0, company.series.length - 1)];
  Template get template => series.templates.isEmpty ? Template(nameAr: '—', nameEn: '—', constants: {}, parts: []) : series.templates[templateIdx.clamp(0, series.templates.length - 1)];

  String t(String ar, String en) => (widget.lang == 'ar') ? ar : en;

  @override
  Widget build(BuildContext context) {
    final isAr = widget.lang == 'ar';
    return Scaffold(
      appBar: AppBar(
        title: Text(t('AluUPVC Pro (تجريبي)', 'AluUPVC Pro (Trial)')),
        actions: [
          TextButton(
            onPressed: widget.onToggleLang,
            child: Text(isAr ? 'EN' : 'AR'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              final updated = await Navigator.push<RulesDb>(
                context,
                MaterialPageRoute(builder: (_) => SettingsPage(db: db, lang: widget.lang)),
              );
              if (updated != null) {
                db = updated;
                await widget.onDbChanged(db);
              }
            },
          ),
        ],
      ),
      floatingActionButton: AnimatedAlign(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
        alignment: isAr ? Alignment.bottomRight : Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FloatingActionButton.extended(
            icon: const Icon(Icons.camera_alt_outlined),
            label: Text(t('Scan', 'Scan')),
            onPressed: () async {
              final rows = await _scanSketch(context);
              if (rows.isEmpty) return;
              final accepted = await showModalBottomSheet<List<ScanRow>>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => ScanReviewSheet(initialRows: rows, lang: widget.lang),
              );
              if (accepted == null || accepted.isEmpty) return;

              setState(() {
                for (final r in accepted) {
                  final code = 'W$_codeCounter';
                  _codeCounter++;
                  items.add(SizeRow(code: code, wCm: r.w, hCm: r.h, qty: r.qty));
                }
              });
            },
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _selectorCard(),
            const SizedBox(height: 12),
            _sizesTableCard(),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.calculate_outlined),
              label: Text(t('احسب المشروع', 'Calculate project')),
              onPressed: series.templates.isEmpty ? null : () async {
                final res = _calculateProject();
                if (res == null) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ResultsPage(
                      lang: widget.lang,
                      templateLabel: '${company.nameAr} / ${series.nameAr} / ${template.nameAr}',
                      items: res.items,
                      inputRows: items,
                      stockLenDefault: template.constants['STOCK_LEN'] ?? 6.0,
                      kerfDefault: template.constants['KERF'] ?? 0.003,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectorCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('اختيار القطاع', 'Select template'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: companyIdx.clamp(0, db.companies.isEmpty ? 0 : db.companies.length - 1),
                    decoration: InputDecoration(labelText: t('شركة', 'Company')),
                    items: List.generate(db.companies.length, (i) {
                      final c = db.companies[i];
                      return DropdownMenuItem(value: i, child: Text(widget.lang == 'ar' ? c.nameAr : c.nameEn));
                    }),
                    onChanged: (v) => setState(() {
                      companyIdx = v ?? 0;
                      seriesIdx = 0;
                      templateIdx = 0;
                    }),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: seriesIdx.clamp(0, company.series.isEmpty ? 0 : company.series.length - 1),
                    decoration: InputDecoration(labelText: t('سيستم', 'System')),
                    items: List.generate(company.series.length, (i) {
                      final s = company.series[i];
                      return DropdownMenuItem(value: i, child: Text(widget.lang == 'ar' ? s.nameAr : s.nameEn));
                    }),
                    onChanged: (v) => setState(() {
                      seriesIdx = v ?? 0;
                      templateIdx = 0;
                    }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              value: templateIdx.clamp(0, series.templates.isEmpty ? 0 : series.templates.length - 1),
              decoration: InputDecoration(labelText: t('نوع', 'Template')),
              items: List.generate(series.templates.length, (i) {
                final tm = series.templates[i];
                return DropdownMenuItem(value: i, child: Text(widget.lang == 'ar' ? tm.nameAr : tm.nameEn));
              }),
              onChanged: (v) => setState(() => templateIdx = v ?? 0),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sizesTableCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('جدول المقاسات', 'Sizes table'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(t('كود', 'Code'))),
                  const DataColumn(label: Text('W (cm)')),
                  const DataColumn(label: Text('H (cm)')),
                  DataColumn(label: Text(t('عدد', 'Qty'))),
                  const DataColumn(label: Text('')),
                ],
                rows: List.generate(items.length, (i) {
                  final r = items[i];
                  return DataRow(cells: [
                    DataCell(_cellText(
                      initial: r.code,
                      width: 90,
                      onChanged: (v) => setState(() => r.code = v.trim().isEmpty ? r.code : v.trim()),
                    )),
                    DataCell(_cellNum(
                      initial: r.wCm.toStringAsFixed(1),
                      width: 110,
                      onChanged: (v) => setState(() => r.wCm = double.tryParse(normalizeArabicNumbers(v)) ?? r.wCm),
                    )),
                    DataCell(_cellNum(
                      initial: r.hCm.toStringAsFixed(1),
                      width: 110,
                      onChanged: (v) => setState(() => r.hCm = double.tryParse(normalizeArabicNumbers(v)) ?? r.hCm),
                    )),
                    DataCell(_cellNum(
                      initial: r.qty.toString(),
                      width: 80,
                      onChanged: (v) => setState(() => r.qty = int.tryParse(normalizeArabicNumbers(v)) ?? r.qty),
                    )),
                    DataCell(IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => items.removeAt(i)),
                    )),
                  ]);
                }),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: Text(t('سطر جديد', 'Add row')),
                  onPressed: () => setState(() {
                    final code = 'W$_codeCounter';
                    _codeCounter++;
                    items.add(SizeRow(code: code, wCm: 0, hCm: 0, qty: 1));
                  }),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: Text(t('مسح', 'Clear')),
                  onPressed: () => setState(() {
                    items.clear();
                    _codeCounter = 1;
                    items.add(SizeRow(code: 'W1', wCm: 0, hCm: 0, qty: 1));
                    _codeCounter = 2;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              t('صيغة السكان: عرض×ارتفاع×عدد (مثل ٩٠×٢١٥×٢). لو بدون عدد يعتبر 1.',
                'Scan format: W×H×Qty (e.g., 90×215×2). Without qty -> 1.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _cellNum({required String initial, required void Function(String) onChanged, double width = 100}) {
    return SizedBox(
      width: width,
      child: TextFormField(
        initialValue: initial,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
        onChanged: onChanged,
      ),
    );
  }

  Widget _cellText({required String initial, required void Function(String) onChanged, double width = 90}) {
    return SizedBox(
      width: width,
      child: TextFormField(
        initialValue: initial,
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
        onChanged: onChanged,
      ),
    );
  }

  Future<List<ScanRow>> _scanSketch(BuildContext context) async {
    final picker = ImagePicker();
    final XFile? img = await picker.pickImage(source: ImageSource.camera);
    if (img == null) return [];
    final input = InputImage.fromFile(File(img.path));
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final res = await recognizer.processImage(input);
      return extractSketchRows(res.text);
    } finally {
      recognizer.close();
    }
  }

  _CalcResult? _calculateProject() {
    // basic validation of input rows
    for (final r in items) {
      if (r.wCm <= 0 || r.hCm <= 0 || r.qty <= 0) {
        _toast(t('تأكد من المقاسات والعدد.', 'Check sizes and quantities.'));
        return null;
      }
    }

    final tm = template;
    final vars = tm.constants;

    final agg = <String, CutItem>{}; // key = group|name|lenRounded

    int totalWindows = 0;

    for (final row in items) {
      totalWindows += row.qty;
      for (final part in tm.parts) {
        final len = ExprEval.eval(part.formula, W: row.wCm, H: row.hCm, vars: vars);
        final q = ExprEval.eval(part.qty, W: row.wCm, H: row.hCm, vars: vars);
        if (len == null || q == null) {
          _toast(t('خطأ في معادلة: ${part.nameAr}', 'Formula error: ${part.nameEn}'));
          return null;
        }
        final lenCm = len;
        if (lenCm <= 0) continue;

        final qtyPart = q.round(); // expect integer
        if (qtyPart <= 0) continue;

        final totalQty = qtyPart * row.qty;

        // Round length for grouping to 0.1 cm
        final lenRounded = (lenCm * 10).round() / 10.0;

        final key = '${part.group}|${part.nameAr}|$lenRounded';
        final existing = agg[key];
        if (existing == null) {
          agg[key] = CutItem(group: part.group, partName: part.nameAr, lengthCm: lenRounded, qty: totalQty);
        } else {
          agg[key] = CutItem(group: existing.group, partName: existing.partName, lengthCm: existing.lengthCm, qty: existing.qty + totalQty);
        }
      }
    }

    final itemsOut = agg.values.toList()
      ..sort((a, b) {
        final g = a.group.compareTo(b.group);
        if (g != 0) return g;
        final n = a.partName.compareTo(b.partName);
        if (n != 0) return n;
        return b.lengthCm.compareTo(a.lengthCm);
      });

    return _CalcResult(items: itemsOut, totalWindows: totalWindows);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _CalcResult {
  final List<CutItem> items;
  final int totalWindows;
  _CalcResult({required this.items, required this.totalWindows});
}

/// =====================
/// Scan Review Sheet
/// =====================
class ScanReviewSheet extends StatefulWidget {
  final List<ScanRow> initialRows;
  final String lang;
  const ScanReviewSheet({super.key, required this.initialRows, required this.lang});

  @override
  State<ScanReviewSheet> createState() => _ScanReviewSheetState();
}

class _ScanReviewSheetState extends State<ScanReviewSheet> {
  late List<ScanRow> rows;

  @override
  void initState() {
    super.initState();
    rows = widget.initialRows.map((e) => ScanRow(w: e.w, h: e.h, qty: e.qty)).toList();
  }

  String t(String ar, String en) => (widget.lang == 'ar') ? ar : en;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (_, controller) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(width: 44, height: 5, decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(10))),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.fact_check_outlined),
                    const SizedBox(width: 8),
                    Text(t('مراجعة المقاسات', 'Review sizes'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton(onPressed: () => Navigator.pop(context, <ScanRow>[]), child: Text(t('إلغاء', 'Cancel'))),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    return ListTile(
                      title: Row(
                        children: [
                          _miniField(label: 'W', initial: r.w.toStringAsFixed(1), onChanged: (v) => r.w = double.tryParse(normalizeArabicNumbers(v)) ?? r.w),
                          const SizedBox(width: 8),
                          _miniField(label: 'H', initial: r.h.toStringAsFixed(1), onChanged: (v) => r.h = double.tryParse(normalizeArabicNumbers(v)) ?? r.h),
                          const SizedBox(width: 8),
                          _miniField(label: t('عدد', 'Qty'), initial: r.qty.toString(), width: 80, onChanged: (v) => r.qty = int.tryParse(normalizeArabicNumbers(v)) ?? r.qty),
                        ],
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => rows.removeAt(i)),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: Text(t('اعتماد وإضافة', 'Accept & add')),
                    onPressed: rows.isEmpty ? null : () => Navigator.pop(context, rows),
                  ),
                ),
              )
            ],
          ),
        );
      },
    );
  }

  Widget _miniField({required String label, required String initial, required void Function(String) onChanged, double width = 110}) {
    return SizedBox(
      width: width,
      child: TextFormField(
        initialValue: initial,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
        onChanged: onChanged,
      ),
    );
  }
}

/// =====================
/// Results Page: Cutting list + Stock cutting + Export CSV
/// =====================
class ResultsPage extends StatefulWidget {
  final String lang;
  final String templateLabel;
  final List<CutItem> items;
  final List<SizeRow> inputRows;
  final double stockLenDefault;
  final double kerfDefault;

  const ResultsPage({
    super.key,
    required this.lang,
    required this.templateLabel,
    required this.items,
    required this.inputRows,
    required this.stockLenDefault,
    required this.kerfDefault,
  });

  @override
  State<ResultsPage> createState() => _ResultsPageState();
}

class _ResultsPageState extends State<ResultsPage> with SingleTickerProviderStateMixin {
  late TabController _tab;
  late double stockLenM;
  late double kerfM;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    stockLenM = widget.stockLenDefault;
    kerfM = widget.kerfDefault;
  }

  String t(String ar, String en) => (widget.lang == 'ar') ? ar : en;

  @override
  Widget build(BuildContext context) {
    final totalPieces = widget.items.fold<int>(0, (p, e) => p + e.qty);
    final totalLenM = widget.items.fold<double>(0, (p, e) => p + e.lengthM * e.qty);

    return Scaffold(
      appBar: AppBar(
        title: Text(t('نتيجة المشروع', 'Project results')),
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(text: t('Cutting List', 'Cutting List')),
            Tab(text: t('تقسيم الأعواد', 'Stock cutting')),
            Tab(text: t('ملخص', 'Summary')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _cuttingListView(),
          _stockCuttingView(),
          _summaryView(totalPieces: totalPieces, totalLenM: totalLenM),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.share_outlined),
        label: Text(t('تصدير CSV', 'Export CSV')),
        onPressed: _exportCsv,
      ),
    );
  }

  Widget _cuttingListView() {
    final groups = <String, List<CutItem>>{};
    for (final it in widget.items) {
      groups.putIfAbsent(it.group, () => []).add(it);
    }
    final keys = groups.keys.toList()..sort();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            title: Text(widget.templateLabel),
            subtitle: Text(t('تجميع حسب (اسم القطعة + الطول)', 'Grouped by (Part + Length)')),
          ),
        ),
        const SizedBox(height: 12),
        for (final g in keys) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text('${t('مجموعة', 'Group')}: $g', style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          Card(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(t('القطعة', 'Part'))),
                  DataColumn(label: Text(t('الطول (م)', 'Len (m)'))),
                  DataColumn(label: Text(t('الكمية', 'Qty'))),
                ],
                rows: groups[g]!.map((it) {
                  return DataRow(cells: [
                    DataCell(Text(it.partName)),
                    DataCell(Text(it.lengthM.toStringAsFixed(2))),
                    DataCell(Text(it.qty.toString())),
                  ]);
                }).toList(),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _stockCuttingView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('إعدادات العود', 'Stock settings'), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<double>(
                        value: _nearestStock(stockLenM),
                        decoration: InputDecoration(labelText: t('طول العود', 'Stock length')),
                        items: [
                          DropdownMenuItem(value: 6.0, child: Text('6.00 m')),
                          DropdownMenuItem(value: 6.5, child: Text('6.50 m')),
                          DropdownMenuItem(value: -1, child: Text(t('مخصص', 'Custom'))),
                        ],
                        onChanged: (v) async {
                          if (v == null) return;
                          if (v == -1) {
                            final custom = await _askNumberDialog(t('طول مخصص بالمتر', 'Custom length (m)'), stockLenM.toStringAsFixed(2));
                            if (custom != null && custom > 0) setState(() => stockLenM = custom);
                          } else {
                            setState(() => stockLenM = v);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        initialValue: kerfM.toStringAsFixed(3),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: t('Kerf (م)', 'Kerf (m)')),
                        onChanged: (v) => setState(() => kerfM = double.tryParse(normalizeArabicNumbers(v)) ?? kerfM),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(t('ملاحظة: Kerf يُخصم بين القطع فقط.', 'Note: Kerf is counted between cuts only.'), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        ..._buildStockPlans(),
      ],
    );
  }

  double _nearestStock(double v) {
    if ((v - 6.0).abs() < 0.01) return 6.0;
    if ((v - 6.5).abs() < 0.01) return 6.5;
    return -1;
  }

  List<Widget> _buildStockPlans() {
    // Build per group
    final groups = <String, List<double>>{}; // group -> list of lengths (meters) expanded by qty
    for (final it in widget.items) {
      final list = groups.putIfAbsent(it.group, () => []);
      for (int k = 0; k < it.qty; k++) {
        list.add(it.lengthM);
      }
    }

    final keys = groups.keys.toList()..sort();
    final widgets = <Widget>[];

    for (final g in keys) {
      final pieces = groups[g]!..sort((a, b) => b.compareTo(a)); // decreasing
      final plan = StockCutter.firstFitDecreasing(pieces, stockLenM, kerfM);

      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6),
        child: Text('${t('مجموعة', 'Group')}: $g', style: const TextStyle(fontWeight: FontWeight.w800)),
      ));

      widgets.add(Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('عدد الأعواد: ${plan.bars.length}', 'Bars: ${plan.bars.length}')),
              const SizedBox(height: 8),
              ...List.generate(plan.bars.length, (i) {
                final bar = plan.bars[i];
                final used = bar.used;
                final waste = (stockLenM - used).clamp(0, stockLenM);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${t('عود', 'Bar')} ${i + 1}: ${bar.pieces.map((e) => e.toStringAsFixed(2)).join(' + ')}'),
                      Text('${t('المستخدم', 'Used')}: ${used.toStringAsFixed(2)} m   •   ${t('هالك', 'Waste')}: ${waste.toStringAsFixed(2)} m',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                );
              }),
              const Divider(),
              Text('${t('إجمالي الهالك', 'Total waste')}: ${plan.totalWaste(stockLenM).toStringAsFixed(2)} m'),
            ],
          ),
        ),
      ));
    }
    if (widgets.isEmpty) {
      widgets.add(Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(t('لا توجد بيانات.', 'No data.')))));
    }
    return widgets;
  }

  Widget _summaryView({required int totalPieces, required double totalLenM}) {
    final totalWindows = widget.inputRows.fold<int>(0, (p, e) => p + e.qty);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            title: Text(t('ملخص', 'Summary')),
            subtitle: Text(widget.templateLabel),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(title: Text(t('إجمالي عدد الفتحات', 'Total windows')), trailing: Text('$totalWindows')),
              ListTile(title: Text(t('إجمالي عدد القطع', 'Total pieces')), trailing: Text('$totalPieces')),
              ListTile(title: Text(t('إجمالي الأطوال (م)', 'Total length (m)')), trailing: Text(totalLenM.toStringAsFixed(2))),
            ],
          ),
        ),
      ],
    );
  }

  Future<double?> _askNumberDialog(String title, String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<double>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t('إلغاء', 'Cancel'))),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(normalizeArabicNumbers(ctrl.text));
              Navigator.pop(context, v);
            },
            child: Text(t('موافق', 'OK')),
          ),
        ],
      ),
    );
  }

  Future<void> _exportCsv() async {
    final sb = StringBuffer();
    sb.writeln('Group,Part,Length_m,Qty');

    for (final it in widget.items) {
      sb.writeln('"${it.group}","${it.partName}",${it.lengthM.toStringAsFixed(2)},${it.qty}');
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/cutting_list.csv');
    await file.writeAsString(sb.toString(), encoding: utf8);

    await Share.shareXFiles([XFile(file.path)], text: t('Cutting List', 'Cutting List'));
  }
}

/// Stock cutting: First-Fit Decreasing
class StockPlan {
  final List<StockBar> bars;
  StockPlan(this.bars);

  double totalWaste(double stockLen) {
    double w = 0;
    for (final b in bars) {
      w += (stockLen - b.used).clamp(0, stockLen);
    }
    return w;
  }
}

class StockBar {
  final List<double> pieces; // meters
  final double kerf;
  StockBar({required this.pieces, required this.kerf});

  double get used {
    if (pieces.isEmpty) return 0;
    final sum = pieces.fold<double>(0, (p, e) => p + e);
    final cuts = (pieces.length - 1);
    return sum + cuts * kerf;
  }

  bool canFit(double piece, double stockLen) {
    final newPieces = [...pieces, piece];
    final sum = newPieces.fold<double>(0, (p, e) => p + e);
    final cuts = (newPieces.length - 1);
    return sum + cuts * kerf <= stockLen + 1e-9;
  }
}

class StockCutter {
  static StockPlan firstFitDecreasing(List<double> pieces, double stockLen, double kerf) {
    final bars = <StockBar>[];
    for (final p in pieces) {
      bool placed = false;
      for (final b in bars) {
        if (b.canFit(p, stockLen)) {
          b.pieces.add(p);
          placed = true;
          break;
        }
      }
      if (!placed) {
        bars.add(StockBar(pieces: [p], kerf: kerf));
      }
    }
    return StockPlan(bars);
  }
}

/// =====================
/// Settings Page: manage rules, template editor (basic), duplicate, import/export
/// =====================
class SettingsPage extends StatefulWidget {
  final RulesDb db;
  final String lang;
  const SettingsPage({super.key, required this.db, required this.lang});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late RulesDb db;

  int companyIdx = 0;
  int seriesIdx = 0;
  int templateIdx = 0;

  @override
  void initState() {
    super.initState();
    db = widget.db;
  }

  Company get company => db.companies.isEmpty ? Company(nameAr: '—', nameEn: '—', series: []) : db.companies[companyIdx.clamp(0, db.companies.length - 1)];
  Series get series => company.series.isEmpty ? Series(nameAr: '—', nameEn: '—', templates: []) : company.series[seriesIdx.clamp(0, company.series.length - 1)];
  Template get template => series.templates.isEmpty ? Template(nameAr: '—', nameEn: '—', constants: {}, parts: []) : series.templates[templateIdx.clamp(0, series.templates.length - 1)];

  String t(String ar, String en) => (widget.lang == 'ar') ? ar : en;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('الإعدادات', 'Settings')),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            onPressed: () async {
              await RulesStore.resetToDefault();
              final fresh = await RulesStore.load();
              setState(() => db = fresh);
            },
            tooltip: t('إرجاع الافتراضي', 'Reset'),
          ),
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () => Navigator.pop(context, db),
            tooltip: t('حفظ', 'Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('القواعد (Templates)', 'Rules (Templates)'), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: companyIdx.clamp(0, db.companies.isEmpty ? 0 : db.companies.length - 1),
                          decoration: InputDecoration(labelText: t('شركة', 'Company')),
                          items: List.generate(db.companies.length, (i) {
                            final c = db.companies[i];
                            return DropdownMenuItem(value: i, child: Text(widget.lang == 'ar' ? c.nameAr : c.nameEn));
                          }),
                          onChanged: (v) => setState(() {
                            companyIdx = v ?? 0;
                            seriesIdx = 0;
                            templateIdx = 0;
                          }),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: seriesIdx.clamp(0, company.series.isEmpty ? 0 : company.series.length - 1),
                          decoration: InputDecoration(labelText: t('سيستم', 'System')),
                          items: List.generate(company.series.length, (i) {
                            final s = company.series[i];
                            return DropdownMenuItem(value: i, child: Text(widget.lang == 'ar' ? s.nameAr : s.nameEn));
                          }),
                          onChanged: (v) => setState(() {
                            seriesIdx = v ?? 0;
                            templateIdx = 0;
                          }),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<int>(
                    value: templateIdx.clamp(0, series.templates.isEmpty ? 0 : series.templates.length - 1),
                    decoration: InputDecoration(labelText: t('Template', 'Template')),
                    items: List.generate(series.templates.length, (i) {
                      final tm = series.templates[i];
                      return DropdownMenuItem(value: i, child: Text(widget.lang == 'ar' ? tm.nameAr : tm.nameEn));
                    }),
                    onChanged: (v) => setState(() => templateIdx = v ?? 0),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: series.templates.isEmpty ? null : () async {
                          final updated = await Navigator.push<Template>(
                            context,
                            MaterialPageRoute(builder: (_) => TemplateEditorPage(template: template, lang: widget.lang)),
                          );
                          if (updated != null) {
                            setState(() {
                              series.templates[templateIdx] = updated;
                            });
                          }
                        },
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(t('تعديل', 'Edit')),
                      ),
                      OutlinedButton.icon(
                        onPressed: series.templates.isEmpty ? null : () async {
                          final dup = _duplicateTemplate(template);
                          final name = await _askText(t('اسم النسخة', 'Duplicate name'), '${template.nameAr} (نسخة)');
                          if (name == null || name.trim().isEmpty) return;
                          dup.nameAr = name.trim();
                          // Smart default adjustments for 4-sash sliding: if name contains "4"
                          if (name.contains('4') || name.contains('٤')) {
                            dup.constants['SASHES'] = 4;
                            dup.constants['FLY_QTY'] = 2;
                          }
                          setState(() => series.templates.add(dup));
                        },
                        icon: const Icon(Icons.copy_outlined),
                        label: Text(t('Duplicate', 'Duplicate')),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final file = await RulesStore.exportToFile();
                          await Share.shareXFiles([XFile(file.path)], text: 'rules_backup.json');
                        },
                        icon: const Icon(Icons.upload_file),
                        label: Text(t('تصدير القواعد', 'Export rules')),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await RulesStore.importFromPickedFile();
                          final fresh = await RulesStore.load();
                          setState(() => db = fresh);
                        },
                        icon: const Icon(Icons.download),
                        label: Text(t('استيراد القواعد', 'Import rules')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('ملاحظات', 'Notes'), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(t(
                    '• التخصيمات تدخلها من تعديل الـTemplate.\n'
                    '• كل Template له Constants خاصة به (مثل ADD_W, SASHES, STOCK_LEN, KERF).\n'
                    '• لو معادلة غلط، Preview هيقولك.',
                    '• Enter deductions inside Template Editor.\n'
                    '• Each template has its own Constants (ADD_W, SASHES, STOCK_LEN, KERF).\n'
                    '• Preview helps validate formulas.',
                  )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Template _duplicateTemplate(Template t) {
    return Template(
      nameAr: t.nameAr,
      nameEn: t.nameEn,
      constants: Map<String, double>.from(t.constants),
      parts: t.parts.map((p) => Part(
        group: p.group,
        nameAr: p.nameAr,
        nameEn: p.nameEn,
        formula: p.formula,
        qty: p.qty,
        notesAr: p.notesAr,
        notesEn: p.notesEn,
      )).toList(),
    );
  }

  Future<String?> _askText(String title, String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t('إلغاء', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: Text(t('موافق', 'OK'))),
        ],
      ),
    );
  }
}

/// =====================
/// Template Editor: constants + parts + preview
/// =====================
class TemplateEditorPage extends StatefulWidget {
  final Template template;
  final String lang;
  const TemplateEditorPage({super.key, required this.template, required this.lang});

  @override
  State<TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends State<TemplateEditorPage> with SingleTickerProviderStateMixin {
  late Template tm;
  late TabController tab;

  final previewW = TextEditingController(text: '200');
  final previewH = TextEditingController(text: '150');
  final previewQty = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    tm = Template(
      nameAr: widget.template.nameAr,
      nameEn: widget.template.nameEn,
      constants: Map<String, double>.from(widget.template.constants),
      parts: widget.template.parts.map((p) => Part(
        group: p.group, nameAr: p.nameAr, nameEn: p.nameEn, formula: p.formula, qty: p.qty, notesAr: p.notesAr, notesEn: p.notesEn,
      )).toList(),
    );
    tab = TabController(length: 3, vsync: this);
  }

  String t(String ar, String en) => (widget.lang == 'ar') ? ar : en;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('تعديل Template', 'Edit Template')),
        bottom: TabBar(
          controller: tab,
          tabs: [
            Tab(text: t('Constants', 'Constants')),
            Tab(text: t('Parts', 'Parts')),
            Tab(text: t('Preview', 'Preview')),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () {
              Navigator.pop(context, tm);
            },
          )
        ],
      ),
      body: TabBarView(
        controller: tab,
        children: [
          _constantsTab(),
          _partsTab(),
          _previewTab(),
        ],
      ),
    );
  }

  Widget _constantsTab() {
    final keys = tm.constants.keys.toList()..sort();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('اسم الـTemplate', 'Template name'), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                TextFormField(
                  initialValue: tm.nameAr,
                  decoration: InputDecoration(labelText: t('عربي', 'Arabic')),
                  onChanged: (v) => setState(() => tm.nameAr = v),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  initialValue: tm.nameEn,
                  decoration: InputDecoration(labelText: t('إنجليزي', 'English')),
                  onChanged: (v) => setState(() => tm.nameEn = v),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('Constants', 'Constants'), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                ...keys.map((k) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Expanded(child: Text(k, style: const TextStyle(fontWeight: FontWeight.w700))),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 140,
                        child: TextFormField(
                          initialValue: tm.constants[k]!.toString(),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                          onChanged: (v) {
                            final d = double.tryParse(normalizeArabicNumbers(v));
                            if (d != null) setState(() => tm.constants[k] = d);
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => tm.constants.remove(k)),
                      )
                    ],
                  ),
                )),
                const SizedBox(height: 6),
                FilledButton.icon(
                  onPressed: () async {
                    final name = await _askText(t('اسم الثابت', 'Constant name'), 'ADD_W');
                    if (name == null || name.trim().isEmpty) return;
                    setState(() => tm.constants[name.trim()] = 0.0);
                  },
                  icon: const Icon(Icons.add),
                  label: Text(t('إضافة ثابت', 'Add constant')),
                ),
                const SizedBox(height: 8),
                Text(t('مهم: تستخدم constants داخل المعادلات مثل ADD_W, SASHES, STOCK_LEN.', 'Use constants inside formulas: ADD_W, SASHES, STOCK_LEN.'), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _partsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('Parts', 'Parts'), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                ...List.generate(tm.parts.length, (i) {
                  final p = tm.parts[i];
                  return Card(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.45),
                    child: ListTile(
                      title: Text(p.nameAr.isEmpty ? '(بدون اسم)' : p.nameAr),
                      subtitle: Text('${t('Group', 'Group')}: ${p.group} • ${t('Formula', 'Formula')}: ${p.formula} • Qty: ${p.qty}'),
                      trailing: Wrap(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () async {
                              final updated = await showDialog<Part>(
                                context: context,
                                builder: (_) => PartDialog(part: p, lang: widget.lang),
                              );
                              if (updated != null) setState(() => tm.parts[i] = updated);
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => setState(() => tm.parts.removeAt(i)),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 10),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: Text(t('إضافة قطعة', 'Add part')),
                  onPressed: () async {
                    final p = await showDialog<Part>(
                      context: context,
                      builder: (_) => PartDialog(part: Part(group: 'Default', nameAr: '', nameEn: '', formula: 'W', qty: '1', notesAr: '', notesEn: ''), lang: widget.lang),
                    );
                    if (p != null) setState(() => tm.parts.add(p));
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('قوالب سريعة للمعادلات', 'Formula shortcuts'), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _chip('(W + ADD_W) / SASHES'),
                    _chip('H - DED_H_SASH'),
                    _chip('H - DED_H_FLY'),
                    _chip('W - 1'),
                    _chip('(W) / 2'),
                    _chip('SASHES * 2'),
                    _chip('FLY_QTY * 2'),
                  ],
                ),
                const SizedBox(height: 6),
                Text(t('تقدر تنسخ أي قالب وتعدله داخل القطعة.', 'Copy any shortcut into a part formula.'), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(String s) {
    return ActionChip(
      label: Text(s),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: s));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('تم النسخ', 'Copied'))));
      },
    );
  }

  Widget _previewTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('Preview', 'Preview'), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: TextField(controller: previewW, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'W (cm)', border: OutlineInputBorder(), isDense: true))),
                    const SizedBox(width: 10),
                    Expanded(child: TextField(controller: previewH, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'H (cm)', border: OutlineInputBorder(), isDense: true))),
                    const SizedBox(width: 10),
                    Expanded(child: TextField(controller: previewQty, keyboardType: const TextInputType.numberWithOptions(decimal: false), decoration: InputDecoration(labelText: t('عدد', 'Qty'), border: const OutlineInputBorder(), isDense: true))),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text(t('تشغيل Preview', 'Run preview')),
                  onPressed: () {
                    final W = double.tryParse(normalizeArabicNumbers(previewW.text)) ?? 0;
                    final H = double.tryParse(normalizeArabicNumbers(previewH.text)) ?? 0;
                    final Q = int.tryParse(normalizeArabicNumbers(previewQty.text)) ?? 1;
                    if (W <= 0 || H <= 0 || Q <= 0) return;

                    final out = <CutItem>[];
                    for (final p in tm.parts) {
                      final len = ExprEval.eval(p.formula, W: W, H: H, vars: tm.constants);
                      final q = ExprEval.eval(p.qty, W: W, H: H, vars: tm.constants);
                      if (len == null || q == null) {
                        _toast('${t('خطأ في', 'Error in')} ${p.nameAr}');
                        return;
                      }
                      if (len <= 0) continue;
                      final qq = q.round() * Q;
                      if (qq <= 0) continue;
                      out.add(CutItem(group: p.group, partName: p.nameAr, lengthCm: (len * 10).round() / 10.0, qty: qq));
                    }

                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text(t('نتيجة Preview', 'Preview result')),
                        content: SizedBox(
                          width: double.maxFinite,
                          child: ListView(
                            shrinkWrap: true,
                            children: out.map((e) => ListTile(
                              title: Text(e.partName),
                              subtitle: Text('${t('طول', 'Len')}: ${e.lengthM.toStringAsFixed(2)} m • ${t('كمية', 'Qty')}: ${e.qty} • ${t('Group', 'Group')}: ${e.group}'),
                            )).toList(),
                          ),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context), child: Text(t('إغلاق', 'Close'))),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<String?> _askText(String title, String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t('إلغاء', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: Text(t('موافق', 'OK'))),
        ],
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// Part add/edit dialog
class PartDialog extends StatefulWidget {
  final Part part;
  final String lang;
  const PartDialog({super.key, required this.part, required this.lang});

  @override
  State<PartDialog> createState() => _PartDialogState();
}

class _PartDialogState extends State<PartDialog> {
  late Part p;
  final groups = ['Frame', 'Sash', 'Fly', 'Glass', 'Default'];

  @override
  void initState() {
    super.initState();
    p = Part(
      group: widget.part.group,
      nameAr: widget.part.nameAr,
      nameEn: widget.part.nameEn,
      formula: widget.part.formula,
      qty: widget.part.qty,
      notesAr: widget.part.notesAr,
      notesEn: widget.part.notesEn,
    );
  }

  String t(String ar, String en) => (widget.lang == 'ar') ? ar : en;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t('تعديل قطعة', 'Edit part')),
      content: SingleChildScrollView(
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              value: groups.contains(p.group) ? p.group : 'Default',
              decoration: InputDecoration(labelText: t('Group', 'Group')),
              items: groups.map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
              onChanged: (v) => setState(() => p.group = v ?? 'Default'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: TextEditingController(text: p.nameAr),
              decoration: InputDecoration(labelText: t('اسم عربي', 'Arabic name'), border: const OutlineInputBorder(), isDense: true),
              onChanged: (v) => p.nameAr = v,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: TextEditingController(text: p.nameEn),
              decoration: InputDecoration(labelText: t('اسم إنجليزي (اختياري)', 'English (optional)'), border: const OutlineInputBorder(), isDense: true),
              onChanged: (v) => p.nameEn = v,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: TextEditingController(text: p.formula),
              decoration: InputDecoration(labelText: t('معادلة الطول (سم)', 'Length formula (cm)'), border: const OutlineInputBorder(), isDense: true),
              onChanged: (v) => p.formula = v,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: TextEditingController(text: p.qty),
              decoration: InputDecoration(labelText: t('معادلة الكمية', 'Qty formula'), border: const OutlineInputBorder(), isDense: true),
              onChanged: (v) => p.qty = v,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: TextEditingController(text: p.notesAr),
              decoration: InputDecoration(labelText: t('ملاحظات', 'Notes'), border: const OutlineInputBorder(), isDense: true),
              onChanged: (v) => p.notesAr = v,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('إلغاء', 'Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, p), child: Text(t('حفظ', 'Save'))),
      ],
    );
  }
}
