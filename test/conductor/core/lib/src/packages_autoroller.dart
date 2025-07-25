// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:process/process.dart';

import 'git.dart';
import 'globals.dart';
import 'repository.dart';
import 'stdio.dart';
import 'validate_checkout_post_gradle_regeneration.dart';

/// A service for rolling the SDK's pub packages to latest and open a PR upstream.
class PackageAutoroller {
  PackageAutoroller({
    required this.githubClient,
    required this.token,
    required this.framework,
    required this.orgName,
    required this.processManager,
    required this.githubUsername,
    Stdio? stdio,
  }) {
    this.stdio = stdio ?? VerboseStdio.local();
    if (token.trim().isEmpty) {
      throw Exception('empty token!');
    }
    if (githubClient.trim().isEmpty) {
      throw Exception('Must provide path to GitHub client!');
    }
    if (orgName.trim().isEmpty) {
      throw Exception('Must provide an orgName!');
    }
  }

  late final Stdio stdio;

  final FrameworkRepository framework;
  final ProcessManager processManager;

  /// Path to GitHub CLI client.
  final String githubClient;

  final String githubUsername;

  /// GitHub API access token.
  final String token;

  static const String hostname = 'github.com';

  String get gitAuthor => '$githubUsername <$githubUsername@google.com>';

  String get prBody {
    return '''
This PR was generated by the automated
[Pub packages autoroller](https://github.com/flutter/flutter/blob/main/dev/conductor/core/bin/packages_autoroller.dart).''';
  }

  /// Name of the feature branch to be opened on against the mirror repo.
  ///
  /// We never re-use a previous branch, so the branch name ends in an index
  /// number, which gets incremented for each roll.
  late final Future<String> featureBranchName =
      (() async {
        final List<String> remoteBranches = await framework.listRemoteBranches(
          framework.mirrorRemote!.name,
        );

        int x = 1;
        String name(int index) => 'packages-autoroller-branch-$index';

        while (remoteBranches.contains(name(x))) {
          x += 1;
        }

        return name(x);
      })();

  void log(String message) {
    stdio.printStatus(_redactToken(message));
  }

  /// Name of the GitHub organization to push the feature branch to.
  final String orgName;

  Future<void> roll() async {
    final Directory tempDir = framework.fileSystem.systemTempDirectory.createTempSync();
    try {
      await authLogin();
      final bool openPrAlready = await hasOpenPrs();
      if (openPrAlready) {
        // Don't open multiple roll PRs.
        return;
      }
      final Directory frameworkDir = await framework.checkoutDirectory;
      final String regenerateBinary = await _prebuildRegenerateGradleLockfilesBinary(
        frameworkDir,
        tempDir,
      );
      final bool didUpdate = await updatePackages();
      if (!didUpdate) {
        log('Packages are already at latest.');
        return;
      }
      await _regenerateGradleLockfiles(frameworkDir, regenerateBinary);
      await pushBranch();
      await createPr(repository: await framework.checkoutDirectory);
      await authLogout();
    } on Exception catch (exception) {
      final String message = _redactToken(exception.toString());
      throw Exception('${exception.runtimeType}: $message');
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore failures
      }
    }
  }

  // Ensure we don't leak the GitHub token in exception messages
  String _redactToken(String message) => message.replaceAll(token, '[GitHub TOKEN]');

  /// Attempt to update all pub packages.
  ///
  /// Will return whether or not any changes were made.
  Future<bool> updatePackages({bool verbose = true}) async {
    await framework.newBranch(await featureBranchName);
    final io.Process flutterProcess = await framework.streamFlutter(<String>[
      if (verbose) '--verbose',
      'update-packages',
      '--force-upgrade',
    ]);
    final int exitCode = await flutterProcess.exitCode;
    if (exitCode != 0) {
      throw ConductorException('Failed to update packages with exit code $exitCode');
    }
    // If the git checkout is clean, then pub packages are already at latest
    // that cleanly resolve.
    if (await framework.gitCheckoutClean()) {
      return false;
    }
    await framework.commit('roll packages', addFirst: true, author: gitAuthor);
    return true;
  }

  Future<String> _prebuildRegenerateGradleLockfilesBinary(
    Directory repoRoot,
    Directory tempDir,
  ) async {
    final String entrypoint = '${repoRoot.path}/dev/tools/bin/generate_gradle_lockfiles.dart';
    final File target = tempDir.childFile('generate_gradle_lockfiles');
    await framework.streamDart(<String>[
      'pub',
      'get',
    ], workingDirectory: '${repoRoot.path}/dev/tools');
    await framework.streamDart(<String>['compile', 'exe', entrypoint, '-o', target.path]);

    assert(
      target.existsSync(),
      'expected ${target.path} to exist after compilation, but it did not.',
    );

    processManager.runSync(<String>['chmod', '+x', target.path]);

    return target.path;
  }

  Future<void> _regenerateGradleLockfiles(Directory repoRoot, String regenerateBinary) async {
    final List<String> cmd = <String>[regenerateBinary, '--no-gradle-generation', '--no-exclusion'];
    final io.Process regenerateProcess = await processManager.start(cmd);
    regenerateProcess.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) => stdio.printTrace('[stdout] $line'));
    regenerateProcess.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) => stdio.printTrace('[stderr] $line'));

    final int exitCode = await regenerateProcess.exitCode;
    if (exitCode != 0) {
      throw io.ProcessException(cmd.first, cmd.sublist(1), 'Process failed', exitCode);
    }
    switch (CheckoutStatePostGradleRegeneration(
      await framework.gitStatus(),
      framework.fileSystem.path,
    )) {
      // If the git checkout is clean, we did not update any lockfiles and we do
      // not need an additional commit.
      case NoDiff():
        stdio.printTrace('No diff after calling generate_gradle_lockfiles.dart');
        return;
      case OnlyLockfileChanges():
        stdio.printTrace('Committing Gradle lockfile changes...');
        await framework.commit('Re-generate Gradle lockfiles', addFirst: true, author: gitAuthor);
      case NonLockfileChanges(changes: final List<String> changes):
        throw StateError(
          'Expected all diffs after re-generating gradle lockfiles to end in '
          '`.lockfile`, but encountered: $changes',
        );
      case MalformedLine(line: final String line):
        throw StateError('Unexpected line of STDOUT from git status: "$line"');
    }
  }

  Future<void> pushBranch() async {
    final String projectName = framework.mirrorRemote!.url.split(r'/').last;
    // Encode the token into the remote URL for authentication to work
    final String remote = 'https://$token@$hostname/$orgName/$projectName';
    await framework.pushRef(
      fromRef: await featureBranchName,
      toRef: await featureBranchName,
      remote: remote,
    );
  }

  Future<void> authLogout() {
    return cli(<String>['auth', 'logout', '--hostname', hostname], allowFailure: true);
  }

  Future<void> authLogin() {
    return cli(<String>[
      'auth',
      'login',
      '--hostname',
      hostname,
      '--git-protocol',
      'https',
      '--with-token',
    ], stdin: '$token\n');
  }

  static const String _prTitle = 'Roll pub packages';

  /// Create a pull request on GitHub.
  ///
  /// Depends on the gh cli tool.
  Future<void> createPr({
    required io.Directory repository,
    String body = 'This PR was generated by `flutter update-packages --force-upgrade`.',
    String base = FrameworkRepository.defaultBranch,
    bool draft = false,
  }) async {
    const List<String> labels = <String>['tool', 'autosubmit'];

    // We will wrap title and body in double quotes before delegating to gh
    // binary
    await cli(<String>[
      'pr',
      'create',
      '--title',
      _prTitle,
      '--body',
      body.trim(),
      '--head',
      '$orgName:${await featureBranchName}',
      '--base',
      base,
      for (final String label in labels) ...<String>['--label', label],
      if (draft) '--draft',
    ], workingDirectory: repository.path);
  }

  Future<void> help([List<String>? args]) {
    return cli(<String>['help', ...?args]);
  }

  /// Run a sub-process with the GitHub CLI client.
  ///
  /// Will return STDOUT of the sub-process.
  Future<String> cli(
    List<String> args, {
    bool allowFailure = false,
    String? stdin,
    String? workingDirectory,
  }) async {
    log('Executing "$githubClient ${args.join(' ')}" in $workingDirectory');
    final io.Process process = await processManager.start(
      <String>[githubClient, ...args],
      workingDirectory: workingDirectory,
      environment: <String, String>{},
    );
    final List<String> stderrStrings = <String>[];
    final List<String> stdoutStrings = <String>[];
    final Future<void> stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .forEach(stdoutStrings.add);
    final Future<void> stderrFuture = process.stderr
        .transform(utf8.decoder)
        .forEach(stderrStrings.add);
    if (stdin != null) {
      process.stdin.write(stdin);
      await process.stdin.flush();
      await process.stdin.close();
    }
    final int exitCode = await process.exitCode;
    await Future.wait(<Future<Object?>>[stdoutFuture, stderrFuture]);
    final String stderr = stderrStrings.join();
    final String stdout = stdoutStrings.join();
    if (!allowFailure && exitCode != 0) {
      throw GitException('$stderr\n$stdout', args);
    }
    log(stdout);
    return stdout;
  }

  Future<bool> hasOpenPrs() async {
    // gh pr list --author christopherfujino --repo flutter/flutter --state open --json number
    final String openPrString = await cli(<String>[
      'pr',
      'list',

      '--author',
      githubUsername,

      '--repo',
      'flutter/flutter',

      '--state',
      'open',

      '--search',
      _prTitle,

      // Return structured JSON with the PR numbers of open PRs
      '--json',
      'number',
    ]);

    // This will be an array of objects, one for each open PR.
    final List<Object?> openPrs = json.decode(openPrString) as List<Object?>;

    // We are only interested in pub rolls, not devicelab flaky PRs
    if (openPrs.isNotEmpty) {
      log('$githubUsername already has open tool PRs:\n$openPrs');
      return true;
    }
    return false;
  }
}
