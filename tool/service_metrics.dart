import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

void main() {
  final serviceRoot = Directory('lib/services');
  final serviceFiles = serviceRoot
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList(growable: false);
  final libFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList(growable: false);

  var serviceTypes = 0;
  var serviceCallables = 0;
  var networkCalls = 0;
  var jsonDecodes = 0;
  var conversionSites = 0;
  var timerSites = 0;

  for (final file in libFiles) {
    final source = file.readAsStringSync();
    final normalized = file.path.replaceAll('\\', '/');
    final visitor = _MetricVisitor(
      inServiceDirectory:
          normalized.startsWith('lib/services/') ||
          normalized.contains('/lib/services/'),
    );
    parseString(content: source, path: file.path).unit.accept(visitor);
    serviceTypes += visitor.serviceTypes;
    serviceCallables += visitor.serviceCallables;
    networkCalls += visitor.networkCalls;
    jsonDecodes += visitor.jsonDecodes;
    conversionSites += visitor.conversionSites;
    timerSites += visitor.timerSites;
  }

  stdout.writeln('service_files=${serviceFiles.length}');
  stdout.writeln('service_types=$serviceTypes');
  stdout.writeln('service_callables=$serviceCallables');
  stdout.writeln('network_call_sites=$networkCalls');
  stdout.writeln('json_decode_sites=$jsonDecodes');
  stdout.writeln('conversion_sites=$conversionSites');
  stdout.writeln('timer_sites=$timerSites');
}

final class _MetricVisitor extends RecursiveAstVisitor<void> {
  _MetricVisitor({required this.inServiceDirectory});

  static final _serviceSuffix = RegExp(
    r'(?:Service|Manager|Repository|Helper|Adapter)$',
  );
  static const _networkMethods = {
    'get',
    'post',
    'put',
    'delete',
    'getJson',
    'postJson',
    'putJson',
    'deleteJson',
  };
  static const _conversionMethods = {
    'cast',
    'from',
    'map',
    'toJson',
    'toList',
    'where',
  };

  final bool inServiceDirectory;
  int serviceTypes = 0;
  int serviceCallables = 0;
  int networkCalls = 0;
  int jsonDecodes = 0;
  int conversionSites = 0;
  int timerSites = 0;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (_serviceSuffix.hasMatch(node.name.lexeme)) serviceTypes++;
    super.visitClassDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    if (_serviceSuffix.hasMatch(node.name.lexeme)) serviceTypes++;
    super.visitMixinDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (inServiceDirectory) serviceCallables++;
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (inServiceDirectory) serviceCallables++;
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (inServiceDirectory) serviceCallables++;
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target?.toSource();
    final method = node.methodName.name;
    if (target == 'NetUtils' && _networkMethods.contains(method)) {
      networkCalls++;
    }
    if (target == null && method == 'jsonDecode') jsonDecodes++;
    if (_conversionMethods.contains(method)) conversionSites++;
    if (target == 'Timer' || method == 'periodic') timerSites++;
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.name.lexeme == 'Timer') timerSites++;
    super.visitInstanceCreationExpression(node);
  }
}
