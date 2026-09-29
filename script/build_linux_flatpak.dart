#!/usr/bin/env dart
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _green = '\x1B[32m';
const String _cyan = '\x1B[36m';
const String _yellow = '\x1B[33m';
const String _red = '\x1B[31m';
const String _reset = '\x1B[0m';

void _log(String message, {String color = _cyan}) {
  print('$color$message$_reset');
}

Never _fail(String message, {int code = 1}) {
  _log(message, color: _red);
  exit(code);
}

Future<void> _run(
  String executable,
  List<String> arguments, {
  required String cwd,
  Map<String, String>? environment,
}) async {
  _log('> $executable ${arguments.join(' ')}');
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: cwd,
    environment: environment,
    runInShell: true,
  );

  process.stdout.transform(utf8.decoder).listen(stdout.write);
  process.stderr.transform(utf8.decoder).listen(stderr.write);
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    _fail(
      'Command failed with exit code $exitCode: $executable ${arguments.join(' ')}',
    );
  }
}

Future<void> _buildLinuxRelease(String projectRoot) async {
  final symbolsDir =
      Platform.environment['SPLIT_DEBUG_INFO']?.trim() ?? 'build/symbols';

  await _run(
    'flutter',
    ['build', 'linux', '--release', '--split-debug-info=$symbolsDir'],
    cwd: projectRoot,
  );
}

Future<void> _buildFlatpak(String projectRoot) async {
  final env = Platform.environment;
  final buildDir = env['BUILD_DIR']?.trim().isNotEmpty == true
      ? env['BUILD_DIR']!.trim()
      : 'build-flatpak';
  final repoDir = env['REPO_DIR']?.trim().isNotEmpty == true
      ? env['REPO_DIR']!.trim()
      : 'repo-flatpak';
  final manifest = env['MANIFEST']?.trim().isNotEmpty == true
      ? env['MANIFEST']!.trim()
      : 'flatpak/io.github.windy.breeze.yml';
  final bundleName = env['BUNDLE_NAME']?.trim().isNotEmpty == true
      ? env['BUNDLE_NAME']!.trim()
      : 'breeze.flatpak';

  final useUserInstall = (env['FLATPAK_BUILDER_USER']?.trim() ?? '1') == '1';
  final installDepsFrom =
      env['FLATPAK_INSTALL_DEPS_FROM']?.trim().isNotEmpty == true
      ? env['FLATPAK_INSTALL_DEPS_FROM']!.trim()
      : 'flathub';

  await Directory(
    '$projectRoot${Platform.pathSeparator}$buildDir',
  ).create(recursive: true);
  await Directory(
    '$projectRoot${Platform.pathSeparator}$repoDir',
  ).create(recursive: true);

  final args = <String>[
    '--force-clean',
    '--repo=$repoDir',
    if (useUserInstall) '--user',
    if (installDepsFrom.isNotEmpty) '--install-deps-from=$installDepsFrom',
    buildDir,
    manifest,
  ];

  await _run('flatpak-builder', args, cwd: projectRoot);
  await _run('flatpak', [
    'build-bundle',
    repoDir,
    bundleName,
    'io.github.windy.breeze',
  ], cwd: projectRoot);
}

Future<void> main() async {
  if (!Platform.isLinux) {
    _fail('This script only supports Linux CI runtime.');
  }

  final scriptFile = File.fromUri(Platform.script);
  final scriptDir = scriptFile.parent.path;
  final projectRoot = Directory(scriptDir).parent.path;

  _log('=== Breeze Linux Build Pipeline ===', color: _green);
  _log('Project root: $projectRoot', color: _green);

  await _buildLinuxRelease(projectRoot);
  await _buildFlatpak(projectRoot);

  _log(
    'Pipeline completed: build -> flatpak.',
    color: _green,
  );
}
