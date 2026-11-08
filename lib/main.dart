// main.dart
//
// One screen: connect to the sensor, show the live heart rate, and show
// whether it's normal, elevated, or tachycardia.

import 'package:flutter/material.dart';

import 'heart_rate.dart';
import 'heart_rate_monitor.dart';

void main() {
  runApp(const TachyApp());
}

class TachyApp extends StatelessWidget {
  const TachyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tachycardia Monitor',
      theme: ThemeData(colorSchemeSeed: Colors.red, useMaterial3: true),
      home: const HeartRateScreen(),
    );
  }
}

class HeartRateScreen extends StatefulWidget {
  const HeartRateScreen({super.key});

  @override
  State<HeartRateScreen> createState() => _HeartRateScreenState();
}

class _HeartRateScreenState extends State<HeartRateScreen> {
  final HeartRateMonitor monitor = HeartRateMonitor();

  @override
  void dispose() {
    monitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tachycardia Monitor')),
      // Rebuilds whenever the monitor calls notifyListeners().
      body: ListenableBuilder(
        listenable: monitor,
        builder: (context, _) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(monitor.status, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                _connectButton(),
                const Spacer(),
                Text(
                  monitor.bpm?.toString() ?? '--',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 96,
                    fontWeight: FontWeight.bold,
                    color: _stateColor(monitor.state),
                  ),
                ),
                const Text('BPM', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                Text(
                  _stateLabel(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: _stateColor(monitor.state),
                  ),
                ),
                const Spacer(),
                Text(
                  'Tachycardia = above ${monitor.detector.thresholdBpm} BPM '
                  'for ${monitor.detector.sustainFor.inSeconds} s',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _connectButton() {
    if (monitor.busy) {
      return const FilledButton(onPressed: null, child: Text('Working...'));
    }
    if (monitor.connected) {
      return OutlinedButton(
        onPressed: monitor.disconnect,
        child: const Text('Disconnect'),
      );
    }
    return FilledButton(
      onPressed: monitor.connect,
      child: const Text('Connect to sensor'),
    );
  }

  String _stateLabel() {
    switch (monitor.state) {
      case HeartRateState.noData:
        return monitor.connected ? 'Waiting for reading...' : '';
      case HeartRateState.normal:
        return 'Normal';
      case HeartRateState.elevated:
        final since = monitor.detector.aboveSince;
        final secs = since == null
            ? 0
            : monitor.lastReading!.difference(since).inSeconds;
        return 'Elevated (${secs}s)';
      case HeartRateState.tachycardia:
        return 'TACHYCARDIA';
    }
  }

  Color _stateColor(HeartRateState s) {
    switch (s) {
      case HeartRateState.noData:
        return Colors.grey;
      case HeartRateState.normal:
        return Colors.green;
      case HeartRateState.elevated:
        return Colors.orange;
      case HeartRateState.tachycardia:
        return Colors.red;
    }
  }
}
