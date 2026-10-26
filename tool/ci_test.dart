import 'dart:convert';
import 'dart:io';

// Expose actual test errors as Actions annotations, including on Windows where
// the public job API otherwise reports only an unhelpful exit code.
Future<void> main(List<String> arguments) async {
  final process = await Process.start(Platform.isWindows ? 'flutter.bat' : 'flutter', [
    'test',
    '--reporter=json',
    ...arguments,
  ], runInShell: Platform.isWindows);
  String escape(String s) => s.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
  var passed = 0;
  final names = <int, String>{};
  final output = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
    Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      stdout.writeln(line);
      return;
    }
    if (event['type'] == 'testStart') {
      final test = event['test'] as Map<String, dynamic>;
      names[test['id'] as int] = test['name'] as String;
    } else if (event['type'] == 'error') {
      final message = event['error'].toString();
      final name = names[event['testID']] ?? 'Flutter test failure';
      stderr.writeln('::error title=${escape(name)}::${escape(message)}');
      stderr.writeln(event['stackTrace'] ?? '');
    } else if (event['type'] == 'testDone') {
      if (event['result'] == 'success') passed++;
      stdout.writeln('Tests passed: $passed; result: ${event['result']}');
    } else if (event['type'] == 'print') {
      stdout.writeln(event['message']);
    }
  });
  await Future.wait([output, process.stderr.forEach(stderr.add)]);
  exitCode = await process.exitCode;
}
