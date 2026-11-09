import 'dart:async';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

// ============================================================
// THEDOX CORE - SPACE HEALTH
// NASA Space Apps Challenge
// Firebase Realtime Database
// ============================================================

bool firebaseReady = false;

const String dbUrl = 'https://thedox-spacehealth-default-rtdb.firebaseio.com';

FirebaseDatabase get rtdb =>
    FirebaseDatabase.instanceFor(app: Firebase.app(), databaseURL: dbUrl);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp().timeout(const Duration(seconds: 6));
    rtdb.setPersistenceEnabled(true);
    firebaseReady = true;
  } catch (e) {
    debugPrint('Firebase no disponible, se usa modo local: $e');
  }
  runApp(const SpaceHealthApp());
}

// ---------------------- COLORES ----------------------
class C {
  static const bg = Color(0xFF070B14);
  static const card = Color(0xFF101827);
  static const cyan = Color(0xFF22D3EE);
  static const green = Color(0xFF34D399);
  static const amber = Color(0xFFFBBF24);
  static const red = Color(0xFFF43F5E);
  static const blue = Color(0xFF3B82F6);
}

// ---------------------- MODELOS ----------------------
enum Scenario { normal, warning, solarFlare, hypoxia }

enum Status { normal, warning, criticalRadiation, criticalHypoxia }

extension ScenarioX on Scenario {
  String get label => switch (this) {
    Scenario.normal => 'NORMAL',
    Scenario.warning => 'ADVERTENCIA',
    Scenario.solarFlare => 'TORMENTA SOLAR',
    Scenario.hypoxia => 'HIPOXIA',
  };
}

extension StatusX on Status {
  bool get isCritical =>
      this == Status.criticalRadiation || this == Status.criticalHypoxia;

  String get code => switch (this) {
    Status.normal => 'NORMAL',
    Status.warning => 'WARNING',
    Status.criticalRadiation => 'CRITICAL_RADIATION',
    Status.criticalHypoxia => 'CRITICAL_HYPOXIA',
  };

  Color get color => switch (this) {
    Status.normal => C.green,
    Status.warning => C.amber,
    Status.criticalRadiation => C.red,
    Status.criticalHypoxia => C.red,
  };

  String get title => switch (this) {
    Status.normal => 'ESTADO NOMINAL',
    Status.warning => 'ADVERTENCIA DE SALUD',
    Status.criticalRadiation => 'ALERTA CRÍTICA · RADIACIÓN',
    Status.criticalHypoxia => 'ALERTA CRÍTICA · HIPOXIA',
  };
}

class Target {
  final double hr, spo2, rad, stress;
  const Target(this.hr, this.spo2, this.rad, this.stress);
}

Target targetFor(Scenario s) => switch (s) {
  Scenario.normal => const Target(72, 98, 0.12, 2),
  Scenario.warning => const Target(100, 94, 2.5, 6),
  Scenario.solarFlare => const Target(112, 96, 45.5, 8),
  Scenario.hypoxia => const Target(135, 82, 0.15, 9),
};

class LogEntry {
  final DateTime time;
  final String event;
  final String level; // SEGURO, ATENCIÓN, ALERTA, INFO
  LogEntry(this.time, this.event, this.level);
}

Color levelColor(String level) => switch (level) {
  'ALERTA' => C.red,
  'ATENCIÓN' => C.amber,
  'SEGURO' => C.green,
  _ => C.cyan,
};

String hhmmss(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

// ---------------------- MOTOR DE TELEMETRÍA ----------------------
class TelemetryEngine extends ChangeNotifier {
  final Random _rng = Random();
  Timer? _timer;
  StreamSubscription<DatabaseEvent>? _sub;
  bool _started = false;
  int _tick = 0;
  int _demoToken = 0;
  Status? _pendingAlert;

  Scenario scenario = Scenario.normal;
  Status status = Status.normal;
  double hr = 72, spo2 = 98, rad = 0.12, stress = 2, dose = 12.4;
  double maxHr = 72, minSpo2 = 98, maxRad = 0.12;
  int? lastReactionMs;
  bool signalLost = false;
  bool autoDemoRunning = false;

  final List<double> hrHist = [];
  final List<double> spo2Hist = [];
  final List<double> radHist = [];
  final List<LogEntry> logs = [];

  String get linkLabel {
    if (signalLost) return 'OFFLINE · LOCAL MODE';
    return firebaseReady ? 'ONLINE · FIREBASE' : 'ONLINE · LOCAL SIM';
  }

  Color get linkColor => signalLost ? C.amber : C.green;

  double get healthScore {
    final s =
        100 -
        max(0, hr - 90) * 0.6 -
        max(0, 97 - spo2) * 3 -
        min(rad, 50) * 0.8 -
        stress * 2;
    return s.clamp(0.0, 100.0).toDouble();
  }

  List<String> get recommendations => switch (status) {
    Status.criticalRadiation => [
      'Evacúa al módulo central blindado',
      'Activa el blindaje secundario',
      'Registra dosis y tiempo de exposición',
      'Notifica a Control de Misión',
    ],
    Status.criticalHypoxia => [
      'Colócate la máscara de emergencia',
      'Verifica presión y flujo de O₂ de la cabina',
      'Reduce la actividad física',
      'Notifica a Control de Misión',
    ],
    Status.warning => [
      'Parámetros fuera del rango óptimo',
      'Realiza el test cognitivo y el autoreporte',
      'Hidrátate y descansa 15 minutos',
    ],
    Status.normal => [
      'Todos los parámetros dentro de rango',
      'Mantén la rutina de ejercicio (prevención de pérdida ósea)',
      'Registra tu ánimo y sueño diario',
    ],
  };

  void start() {
    if (_started) return;
    _started = true;
    for (var i = 0; i < 40; i++) {
      hrHist.add(hr);
      spo2Hist.add(spo2);
      radHist.add(rad);
    }
    addLog('Sistema THEDOX CORE iniciado · ASTRO-001', 'SEGURO');
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _step());
    if (firebaseReady) _attachFirebase();
  }

  void _step() {
    final t = targetFor(scenario);
    hr += (t.hr - hr) * 0.3 + (_rng.nextDouble() - 0.5) * 4;
    spo2 += (t.spo2 - spo2) * 0.3 + (_rng.nextDouble() - 0.5) * 0.8;
    rad += (t.rad - rad) * 0.4 + (_rng.nextDouble() - 0.5) * t.rad * 0.06;
    stress += (t.stress - stress) * 0.25;

    hr = hr.clamp(40.0, 190.0).toDouble();
    spo2 = spo2.clamp(70.0, 100.0).toDouble();
    rad = rad.clamp(0.01, 200.0).toDouble();
    stress = stress.clamp(0.0, 10.0).toDouble();

    // Dosis acumulada (tiempo acelerado x120 para la demo)
    dose = min(dose + rad / 3600 * 120, 500.0);

    maxHr = max(maxHr, hr);
    minSpo2 = min(minSpo2, spo2);
    maxRad = max(maxRad, rad);

    _push(hrHist, hr);
    _push(spo2Hist, spo2);
    _push(radHist, rad);

    final s = _computeStatus();
    if (s != status) {
      status = s;
      if (s.isCritical) {
        _pendingAlert = s;
        addLog('ALERTA: ${s.title}', 'ALERTA');
      } else if (s == Status.warning) {
        addLog('Advertencia: parámetros fuera de rango', 'ATENCIÓN');
      } else {
        addLog('Parámetros vitales normalizados', 'SEGURO');
      }
    }

    _tick++;
    if (_tick % 5 == 0) _pushTelemetry();
    notifyListeners();
  }

  void _push(List<double> list, double v) {
    list.add(v);
    if (list.length > 40) list.removeAt(0);
  }

  Status _computeStatus() {
    if (rad > 10) return Status.criticalRadiation;
    if (spo2 < 90) return Status.criticalHypoxia;
    if (hr > 100 || spo2 < 95 || stress >= 6 || rad > 1) {
      return Status.warning;
    }
    return Status.normal;
  }

  Status? takeAlert() {
    final a = _pendingAlert;
    _pendingAlert = null;
    return a;
  }

  // ---------- Acciones ----------
  void setScenario(Scenario s, {bool push = true}) {
    scenario = s;
    addLog('Simulación: escenario ${s.label}', 'INFO');
    if (push && firebaseReady) {
      try {
        rtdb
            .ref('simulation_controls')
            .update({'active_scenario': s.name})
            .then((_) {}, onError: (Object _) {});
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> runAutoDemo() async {
    if (autoDemoRunning) return;
    autoDemoRunning = true;
    final token = ++_demoToken;
    notifyListeners();

    final steps = <(Scenario, int)>[
      (Scenario.normal, 4),
      (Scenario.warning, 6),
      (Scenario.solarFlare, 10),
      (Scenario.normal, 6),
      (Scenario.hypoxia, 10),
      (Scenario.normal, 0),
    ];
    for (final step in steps) {
      if (token != _demoToken) return;
      setScenario(step.$1);
      await Future.delayed(Duration(seconds: step.$2));
    }
    if (token == _demoToken) {
      autoDemoRunning = false;
      notifyListeners();
    }
  }

  void stopAutoDemo() {
    _demoToken++;
    autoDemoRunning = false;
    notifyListeners();
  }

  Future<void> setSignalLost(bool lost) async {
    signalLost = lost;
    addLog(
      lost
          ? 'Enlace satelital perdido · modo local activado'
          : 'Enlace restablecido · sincronizando datos',
      lost ? 'ATENCIÓN' : 'SEGURO',
    );
    notifyListeners();
    if (!firebaseReady) return;
    try {
      if (lost) {
        await rtdb.goOffline();
      } else {
        await rtdb.goOnline();
      }
    } catch (_) {}
  }

  void registerReaction(int ms) {
    lastReactionMs = ms;
    final lvl = ms < 300 ? 'SEGURO' : (ms < 450 ? 'ATENCIÓN' : 'ALERTA');
    addLog('Test cognitivo completado: $ms ms', lvl);
  }

  void registerSymptoms({
    required List<String> symptoms,
    required int mood,
    required double sleep,
  }) {
    final s = symptoms.isEmpty ? 'sin síntomas' : symptoms.join(', ');
    final lvl = (symptoms.length >= 2 || mood <= 2) ? 'ATENCIÓN' : 'SEGURO';
    addLog(
      'Autoreporte: $s · ánimo $mood/5 · sueño ${sleep.toStringAsFixed(1)} h',
      lvl,
    );
  }

  void addLog(String event, String level) {
    logs.insert(0, LogEntry(DateTime.now(), event, level));
    if (logs.length > 100) logs.removeLast();
    if (firebaseReady) {
      try {
        rtdb
            .ref('mission_logs')
            .push()
            .set({
              'astronaut_id': 'ASTRO-001',
              'event': event,
              'level': level,
              'timestamp': ServerValue.timestamp,
            })
            .then((_) {}, onError: (Object _) {});
      } catch (_) {}
    }
    notifyListeners();
  }

  // ---------- Firebase ----------
  void _attachFirebase() {
    try {
      _sub = rtdb.ref('simulation_controls/active_scenario').onValue.listen((
        event,
      ) {
        final v = event.snapshot.value;
        if (v is! String) return;
        final key = v.toLowerCase().replaceAll('_', '');
        final match = Scenario.values.where((e) => e.name.toLowerCase() == key);
        if (match.isNotEmpty && match.first != scenario) {
          setScenario(match.first, push: false);
        }
      }, onError: (Object _) {});
    } catch (_) {}
  }

  void _pushTelemetry() {
    if (!firebaseReady) return;
    try {
      rtdb
          .ref('telemetry_live')
          .set({
            'timestamp': ServerValue.timestamp,
            'heart_rate_bpm': hr.round(),
            'spo2_percent': spo2.round(),
            'radiation_mSv_h': double.parse(rad.toStringAsFixed(2)),
            'accumulated_dose_mSv': double.parse(dose.toStringAsFixed(2)),
            'stress_level_index': stress.round(),
            'system_status': status.code,
          })
          .then((_) {}, onError: (Object _) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

final TelemetryEngine engine = TelemetryEngine();

// ---------------------- APP ----------------------
class SpaceHealthApp extends StatelessWidget {
  const SpaceHealthApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'THEDOX CORE - Space Health',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: C.bg,
        colorScheme: const ColorScheme.dark(primary: C.cyan, surface: C.card),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF0D1422),
          indicatorColor: C.cyan.withValues(alpha: 0.18),
        ),
      ),
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;
  bool dialogOpen = false;

  @override
  void initState() {
    super.initState();
    engine.start();
    engine.addListener(_onEngine);
  }

  @override
  void dispose() {
    engine.removeListener(_onEngine);
    super.dispose();
  }

  void _onEngine() {
    final alert = engine.takeAlert();
    if (alert == null || dialogOpen || engine.autoDemoRunning || !mounted) {
      return;
    }
    _showAlert(alert);
  }

  void _showAlert(Status s) {
    dialogOpen = true;
    final isRad = s == Status.criticalRadiation;
    final steps = engine.recommendations;
    final detail = isRad
        ? 'Radiación: ${engine.rad.toStringAsFixed(1)} mSv/h'
        : 'SpO2: ${engine.spo2.round()}% · Pulso: ${engine.hr.round()} BPM';

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A0F14),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: C.red, width: 1.5),
          borderRadius: BorderRadius.circular(18),
        ),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: C.red, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isRad ? 'ALERTA: TORMENTA SOLAR' : 'ALERTA: FALLA DE OXÍGENO',
                style: const TextStyle(
                  color: C.red,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              detail,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'PROTOCOLO DE SUPERVIVENCIA',
              style: TextStyle(
                fontSize: 11,
                color: C.amber,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 6),
            for (final step in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• $step',
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: C.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              engine.addLog('Protocolo de emergencia ejecutado', 'SEGURO');
              Navigator.pop(ctx);
            },
            child: const Text('EJECUTAR PROTOCOLO'),
          ),
        ],
      ),
    ).then((_) {
      dialogOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      const DashboardScreen(),
      const CognitiveScreen(),
      const HistoryScreen(),
    ];
    return Scaffold(
      body: SafeArea(child: screens[index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart, color: C.cyan),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.psychology_outlined),
            selectedIcon: Icon(Icons.psychology, color: C.cyan),
            label: 'Cognitivo',
          ),
          NavigationDestination(
            icon: Icon(Icons.history),
            selectedIcon: Icon(Icons.history, color: C.cyan),
            label: 'Historial',
          ),
        ],
      ),
    );
  }
}

// ---------------------- WIDGETS REUTILIZABLES ----------------------
class Panel extends StatelessWidget {
  final Widget child;
  final Color? border;
  final EdgeInsets padding;
  const Panel({
    super.key,
    required this.child,
    this.border,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: padding,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF111A2B), Color(0xFF0D1422)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: border == null
              ? Colors.white.withValues(alpha: 0.07)
              : border!.withValues(alpha: 0.85),
          width: border == null ? 1 : 1.5,
        ),
      ),
      child: child,
    );
  }
}

class Tag extends StatelessWidget {
  final String text;
  final Color color;
  const Tag(this.text, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class MiniChart extends StatelessWidget {
  final List<double> data;
  final Color color;
  final double minY, maxY;
  const MiniChart({
    super.key,
    required this.data,
    required this.color,
    required this.minY,
    required this.maxY,
  });

  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(show: false),
        titlesData: FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var i = 0; i < data.length; i++)
                FlSpot(i.toDouble(), data[i]),
            ],
            isCurved: true,
            color: color,
            barWidth: 2.5,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    );
  }
}

class Ring extends StatelessWidget {
  final double value; // 0..1
  final Color color;
  final double size;
  final Widget child;
  const Ring({
    super.key,
    required this.value,
    required this.color,
    required this.size,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: value.clamp(0.0, 1.0).toDouble(),
              strokeWidth: 8,
              strokeCap: StrokeCap.round,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class ScreenTitle extends StatelessWidget {
  final String title, subtitle;
  const ScreenTitle(this.title, this.subtitle, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.3,
            color: C.cyan,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 12, color: Colors.white54),
        ),
      ],
    );
  }
}

// ---------------------- DASHBOARD ----------------------
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final e = engine;
        final st = e.status;
        final crit = st.isCritical;

        final hrColor = e.hr > 120 ? C.red : (e.hr > 100 ? C.amber : C.cyan);
        final spoColor = e.spo2 < 90 ? C.red : (e.spo2 < 95 ? C.amber : C.blue);
        final radColor = e.rad > 10 ? C.red : (e.rad > 1 ? C.amber : C.green);
        final stressColor = e.stress >= 7
            ? C.red
            : (e.stress >= 5 ? C.amber : C.green);
        final score = e.healthScore;
        final scoreColor = score < 40
            ? C.red
            : (score < 70 ? C.amber : C.green);

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            // ---- Encabezado ----
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: C.cyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.hub, color: C.cyan),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'THEDOX CORE // SPACE HEALTH',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
                        ),
                      ),
                      Text(
                        'ASTRO-001 · Artemis-Mars Alpha',
                        style: TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Panel de simulación',
                  icon: const Icon(Icons.bolt, color: C.cyan),
                  onPressed: () => showSimulationSheet(context),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Tag(e.linkLabel, e.linkColor),
                const SizedBox(width: 8),
                Tag(
                  'ESCENARIO: ${e.scenario.label}',
                  e.scenario == Scenario.normal ? C.cyan : C.amber,
                ),
              ],
            ),
            const SizedBox(height: 14),

            // ---- Banner de estado ----
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: st.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: st.color.withValues(alpha: 0.7)),
              ),
              child: Row(
                children: [
                  Icon(
                    crit
                        ? Icons.warning_amber_rounded
                        : (st == Status.warning
                              ? Icons.info_outline
                              : Icons.verified_outlined),
                    color: st.color,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          st.title,
                          style: TextStyle(
                            color: st.color,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          e.recommendations.first,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ---- Índice de salud + ritmo cardíaco ----
            Panel(
              child: Row(
                children: [
                  Ring(
                    value: score / 100,
                    color: scoreColor,
                    size: 84,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          score.round().toString(),
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(
                          '/100',
                          style: TextStyle(fontSize: 9, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ÍNDICE DE SALUD DEL ASTRONAUTA',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white54,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Combina pulso, oxígeno, radiación y estrés en un solo indicador.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Panel(
              border: e.hr > 120 ? C.red : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.favorite, color: hrColor, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'RITMO CARDÍACO',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white54,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const Spacer(),
                      Tag(
                        e.hr > 120
                            ? 'ELEVADO'
                            : (e.hr > 100 ? 'ALTO' : 'ESTABLE'),
                        hrColor,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        e.hr.round().toString(),
                        style: const TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'BPM',
                        style: TextStyle(fontSize: 12, color: Colors.white54),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 90,
                    child: MiniChart(
                      data: e.hrHist,
                      color: hrColor,
                      minY: 40,
                      maxY: 160,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ---- SpO2 + Radiación ----
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Panel(
                      border: e.spo2 < 90 ? C.red : null,
                      child: Column(
                        children: [
                          const Text(
                            'OXÍGENO · SpO2',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white54,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Ring(
                            value: (e.spo2 - 70) / 30,
                            color: spoColor,
                            size: 92,
                            child: Text(
                              '${e.spo2.round()}%',
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Tag(
                            e.spo2 < 90
                                ? 'HIPOXIA'
                                : (e.spo2 < 95 ? 'BAJO' : 'ÓPTIMO'),
                            spoColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Panel(
                      border: e.rad > 10 ? C.red : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.radar, color: radColor, size: 18),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  'RADIACIÓN',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white54,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            e.rad.toStringAsFixed(2),
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Text(
                            'mSv/h',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                          const Spacer(),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: (e.dose / 500).clamp(0.0, 1.0).toDouble(),
                              minHeight: 8,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.08,
                              ),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                radColor,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Dosis: ${e.dose.toStringAsFixed(1)} / 500 mSv',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white54,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Tag(
                            e.rad > 10
                                ? 'PELIGRO'
                                : (e.rad > 1 ? 'ELEVADA' : 'SEGURO'),
                            radColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ---- Estrés ----
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.psychology, color: stressColor, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'NIVEL DE ESTRÉS',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white54,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const Spacer(),
                      Tag(
                        e.stress >= 7
                            ? 'FATIGA'
                            : (e.stress >= 5 ? 'MODERADO' : 'BAJO'),
                        stressColor,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${e.stress.round()} / 10',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: e.stress / 10,
                      minHeight: 8,
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation<Color>(stressColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ---- Recomendaciones ----
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'RECOMENDACIONES AUTOMÁTICAS',
                    style: TextStyle(
                      fontSize: 11,
                      color: C.cyan,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final r in e.recommendations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.chevron_right, size: 18, color: st.color),
                          Expanded(
                            child: Text(
                              r,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------- PANEL DE SIMULACIÓN ----------------------
void showSimulationSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF0D1422),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: ListenableBuilder(
        listenable: engine,
        builder: (context, _) {
          Widget scenarioButton(
            String label,
            IconData icon,
            Color color,
            Scenario s,
          ) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: color.withValues(alpha: 0.9),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: Icon(icon),
                label: Text(label),
                onPressed: () {
                  engine.stopAutoDemo();
                  engine.setScenario(s);
                  Navigator.pop(ctx);
                },
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'PANEL DE SIMULACIÓN · DEMO MODE',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: C.cyan,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Text(
                  'Inyecta telemetría simulada de un wearable espacial en vivo.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 16),
                scenarioButton(
                  'Modo normal (valores saludables)',
                  Icons.check_circle,
                  Colors.green.shade700,
                  Scenario.normal,
                ),
                scenarioButton(
                  'Advertencia (fatiga y estrés)',
                  Icons.info_outline,
                  Colors.amber.shade800,
                  Scenario.warning,
                ),
                scenarioButton(
                  'Tormenta solar (radiación 45 mSv/h)',
                  Icons.wb_sunny,
                  Colors.orange.shade800,
                  Scenario.solarFlare,
                ),
                scenarioButton(
                  'Falla de oxígeno (SpO2 82%)',
                  Icons.air,
                  Colors.red.shade800,
                  Scenario.hypoxia,
                ),
                const Divider(color: Colors.white12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: C.cyan,
                    side: const BorderSide(color: C.cyan),
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: Icon(
                    engine.autoDemoRunning
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                  ),
                  label: Text(
                    engine.autoDemoRunning
                        ? 'Detener demo automática'
                        : 'Iniciar demo automática (~40 s)',
                  ),
                  onPressed: () {
                    if (engine.autoDemoRunning) {
                      engine.stopAutoDemo();
                    } else {
                      engine.runAutoDemo();
                      Navigator.pop(ctx);
                    }
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: C.amber,
                  title: const Text(
                    'Simular pérdida de señal satelital',
                    style: TextStyle(fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Los datos se guardan localmente (Firebase offline).',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  value: engine.signalLost,
                  onChanged: (v) => engine.setSignalLost(v),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

// ---------------------- COGNITIVO Y SÍNTOMAS ----------------------
enum _Rt { idle, waiting, ready, result, tooSoon }

class CognitiveScreen extends StatefulWidget {
  const CognitiveScreen({super.key});

  @override
  State<CognitiveScreen> createState() => _CognitiveScreenState();
}

class _CognitiveScreenState extends State<CognitiveScreen> {
  _Rt state = _Rt.idle;
  final Stopwatch sw = Stopwatch();
  Timer? timer;
  int ms = 0;

  bool dizzy = false, nausea = false, fatigue = false, blurred = false;
  double mood = 4;
  double sleep = 7;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void _start() {
    timer?.cancel();
    setState(() => state = _Rt.waiting);
    timer = Timer(Duration(milliseconds: 2000 + Random().nextInt(3000)), () {
      if (!mounted) return;
      sw
        ..reset()
        ..start();
      setState(() => state = _Rt.ready);
    });
  }

  void _tap() {
    if (state == _Rt.waiting) {
      timer?.cancel();
      setState(() => state = _Rt.tooSoon);
    } else if (state == _Rt.ready) {
      sw.stop();
      ms = sw.elapsedMilliseconds;
      engine.registerReaction(ms);
      setState(() => state = _Rt.result);
    } else {
      _start();
    }
  }

  String get _classification =>
      ms < 300 ? 'ÓPTIMO' : (ms < 450 ? 'ATENCIÓN' : 'POSIBLE FATIGA');

  @override
  Widget build(BuildContext context) {
    final bg = switch (state) {
      _Rt.idle => C.cyan,
      _Rt.waiting => C.red,
      _Rt.ready => C.green,
      _Rt.tooSoon => C.amber,
      _Rt.result => C.cyan,
    };
    final fg = state == _Rt.waiting ? Colors.white : Colors.black87;
    final big = switch (state) {
      _Rt.idle => 'TOCA PARA INICIAR',
      _Rt.waiting => 'ESPERA...',
      _Rt.ready => '¡TOCA AHORA!',
      _Rt.tooSoon => 'MUY PRONTO',
      _Rt.result => '$ms ms',
    };
    final small = switch (state) {
      _Rt.idle =>
        'Cuando la pantalla se ponga verde, toca lo más rápido posible',
      _Rt.waiting => 'No toques todavía',
      _Rt.ready => '',
      _Rt.tooSoon => 'Toca para reintentar',
      _Rt.result => '$_classification · toca para repetir',
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const ScreenTitle(
          'MÓDULO COGNITIVO Y SÍNTOMAS',
          'Detección temprana de fatiga mental y estrés por aislamiento',
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTapDown: (_) => _tap(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 190,
            width: double.infinity,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: bg.withValues(alpha: 0.35),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  big,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    small,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'AUTOREPORTE DE SÍNTOMAS',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: C.cyan,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
          child: Column(
            children: [
              CheckboxListTile(
                title: const Text('Mareo / desorientación espacial'),
                value: dizzy,
                activeColor: C.cyan,
                checkColor: Colors.black,
                onChanged: (v) => setState(() => dizzy = v ?? false),
              ),
              CheckboxListTile(
                title: const Text('Náuseas'),
                value: nausea,
                activeColor: C.cyan,
                checkColor: Colors.black,
                onChanged: (v) => setState(() => nausea = v ?? false),
              ),
              CheckboxListTile(
                title: const Text('Cansancio extremo'),
                value: fatigue,
                activeColor: C.cyan,
                checkColor: Colors.black,
                onChanged: (v) => setState(() => fatigue = v ?? false),
              ),
              CheckboxListTile(
                title: const Text('Visión borrosa'),
                value: blurred,
                activeColor: C.cyan,
                checkColor: Colors.black,
                onChanged: (v) => setState(() => blurred = v ?? false),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Estado de ánimo: ${mood.round()} / 5',
                style: const TextStyle(fontSize: 13),
              ),
              Slider(
                value: mood,
                min: 1,
                max: 5,
                divisions: 4,
                activeColor: C.cyan,
                onChanged: (v) => setState(() => mood = v),
              ),
              Text(
                'Horas de sueño: ${sleep.toStringAsFixed(1)} h',
                style: const TextStyle(fontSize: 13),
              ),
              Slider(
                value: sleep,
                min: 0,
                max: 12,
                divisions: 24,
                activeColor: C.cyan,
                onChanged: (v) => setState(() => sleep = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: C.cyan,
            foregroundColor: Colors.black,
            minimumSize: const Size(double.infinity, 50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: const Icon(Icons.send),
          label: const Text(
            'ENVIAR REPORTE',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          onPressed: () {
            final list = <String>[
              if (dizzy) 'mareo',
              if (nausea) 'náuseas',
              if (fatigue) 'cansancio extremo',
              if (blurred) 'visión borrosa',
            ];
            engine.registerSymptoms(
              symptoms: list,
              mood: mood.round(),
              sleep: sleep,
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  list.length >= 2 || mood <= 2
                      ? 'Reporte guardado. Se recomienda contactar al médico de vuelo.'
                      : 'Reporte guardado correctamente.',
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ---------------------- HISTORIAL ----------------------
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final e = engine;

        Widget stat(String label, String value, Color color) {
          return Expanded(
            child: Panel(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontSize: 10, color: Colors.white54),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            const ScreenTitle(
              'HISTORIAL Y RESUMEN DE MISIÓN',
              'Persistencia offline con Firebase',
            ),
            const SizedBox(height: 14),
            Panel(
              border: e.signalLost ? C.amber : null,
              child: Row(
                children: [
                  Icon(
                    e.signalLost ? Icons.cloud_off : Icons.cloud_done,
                    color: e.linkColor,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      e.signalLost
                          ? 'Sin señal satelital: los registros se guardan en el dispositivo y se sincronizan al reconectar.'
                          : 'Enlace activo. Los registros se sincronizan con Firebase Realtime Database y quedan en caché local.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                stat('PULSO MÁX.', '${e.maxHr.round()} BPM', C.red),
                const SizedBox(width: 10),
                stat('SpO2 MÍN.', '${e.minSpo2.round()}%', C.blue),
                const SizedBox(width: 10),
                stat('RAD. MÁX.', e.maxRad.toStringAsFixed(1), C.amber),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              'REGISTROS (${e.logs.length})',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: C.cyan,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 8),
            for (final log in e.logs)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Panel(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.storage,
                        color: levelColor(log.level),
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              log.event,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hhmmss(log.time),
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Tag(log.level, levelColor(log.level)),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
