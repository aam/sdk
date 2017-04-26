// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Partial test that the closed world computed from [WorldImpact]s derived from
// kernel is equivalent to the original computed from resolution.
library dart2js.kernel.closed_world2_test;

import 'package:async_helper/async_helper.dart';
import 'package:compiler/src/closure.dart';
import 'package:compiler/src/commandline_options.dart';
import 'package:compiler/src/common.dart';
import 'package:compiler/src/common_elements.dart';
import 'package:compiler/src/common/backend_api.dart';
import 'package:compiler/src/common/resolution.dart';
import 'package:compiler/src/common/work.dart';
import 'package:compiler/src/compiler.dart';
import 'package:compiler/src/deferred_load.dart';
import 'package:compiler/src/elements/resolution_types.dart';
import 'package:compiler/src/elements/elements.dart';
import 'package:compiler/src/elements/entities.dart';
import 'package:compiler/src/elements/types.dart';
import 'package:compiler/src/enqueue.dart';
import 'package:compiler/src/js_backend/backend.dart'
    hide RuntimeTypesNeedBuilderImpl;
import 'package:compiler/src/js_backend/backend_impact.dart';
import 'package:compiler/src/js_backend/backend_usage.dart';
import 'package:compiler/src/js_backend/custom_elements_analysis.dart';
import 'package:compiler/src/js_backend/native_data.dart';
import 'package:compiler/src/js_backend/impact_transformer.dart';
import 'package:compiler/src/js_backend/interceptor_data.dart';
import 'package:compiler/src/js_backend/lookup_map_analysis.dart';
import 'package:compiler/src/js_backend/mirrors_analysis.dart'
    hide MirrorsResolutionAnalysisImpl;
import 'package:compiler/src/js_backend/mirrors_data.dart';
import 'package:compiler/src/js_backend/no_such_method_registry.dart';
import 'package:compiler/src/js_backend/resolution_listener.dart';
import 'package:compiler/src/js_backend/type_variable_handler.dart';
import 'package:compiler/src/native/enqueue.dart';
import 'package:compiler/src/native/resolver.dart';
import 'package:compiler/src/kernel/element_map.dart';
import 'package:compiler/src/kernel/kernel_strategy.dart';
import 'package:compiler/src/options.dart';
import 'package:compiler/src/universe/world_builder.dart';
import 'package:compiler/src/universe/world_impact.dart';
import 'package:compiler/src/world.dart';
import 'package:expect/expect.dart';
import '../memory_compiler.dart';
import '../serialization/helper.dart';
import '../serialization/model_test_helper.dart';
import '../serialization/test_helper.dart';

import 'closed_world_test.dart' hide KernelWorkItemBuilder;
import 'impact_test.dart';

const SOURCE = const {
  'main.dart': '''
import 'dart:html';

main() {
  print('Hello World');
  ''.contains; // Trigger member closurization.
  new Element.div();
}
'''
};

main(List<String> args) {
  Arguments arguments = new Arguments.from(args);
  Uri entryPoint;
  Map<String, String> memorySourceFiles;
  if (arguments.uri != null) {
    entryPoint = arguments.uri;
    memorySourceFiles = const <String, String>{};
  } else {
    entryPoint = Uri.parse('memory:main.dart');
    memorySourceFiles = SOURCE;
  }

  asyncTest(() async {
    enableDebugMode();

    print('---- analyze-only ------------------------------------------------');
    Compiler compiler1 = compilerFor(
        entryPoint: entryPoint,
        memorySourceFiles: memorySourceFiles,
        options: [Flags.analyzeOnly, Flags.enableAssertMessage]);
    ElementResolutionWorldBuilder.useInstantiationMap = true;
    compiler1.resolution.retainCachesForTesting = true;
    await compiler1.run(entryPoint);
    Expect.isFalse(compiler1.compilationFailed);
    ResolutionEnqueuer enqueuer1 = compiler1.enqueuer.resolution;
    BackendUsage backendUsage1 = compiler1.backend.backendUsage;
    ClosedWorld closedWorld1 = compiler1.resolutionWorldBuilder.closeWorld();

    print('---- analyze-all -------------------------------------------------');
    Compiler compiler = compilerFor(
        entryPoint: entryPoint,
        memorySourceFiles: memorySourceFiles,
        options: [
          Flags.analyzeAll,
          Flags.useKernel,
          Flags.enableAssertMessage
        ]);
    await compiler.run(entryPoint);
    compiler.resolutionWorldBuilder.closeWorld();

    print('---- closed world from kernel ------------------------------------');
    KernelToElementMap elementMap = new KernelToElementMap(compiler.reporter);
    elementMap.addProgram(compiler.backend.kernelTask.program);
    KernelEquivalence equivalence = new KernelEquivalence(elementMap);
    NativeBasicData nativeBasicData = computeNativeBasicData(elementMap);
    checkNativeBasicData(
        compiler1.backend.nativeBasicData, nativeBasicData, equivalence);
    List list = createKernelResolutionEnqueuerListener(
        compiler.options,
        compiler.reporter,
        compiler.deferredLoadTask,
        elementMap,
        nativeBasicData);
    ResolutionEnqueuerListener resolutionEnqueuerListener = list[0];
    BackendUsageBuilder backendUsageBuilder2 = list[1];
    ImpactTransformer impactTransformer = list[2];

    ResolutionEnqueuer enqueuer2 = new ResolutionEnqueuer(
        compiler.enqueuer,
        compiler.options,
        compiler.reporter,
        const TreeShakingEnqueuerStrategy(),
        resolutionEnqueuerListener,
        new KernelResolutionWorldBuilder(
            elementMap, nativeBasicData, const OpenWorldStrategy()),
        new KernelWorkItemBuilder(elementMap, impactTransformer),
        'enqueuer from kelements');
    ClosedWorld closedWorld2 = computeClosedWorld(
        compiler.reporter, enqueuer2, elementMap.elementEnvironment);
    BackendUsage backendUsage2 = backendUsageBuilder2.close();
    checkBackendUsage(backendUsage1, backendUsage2, equivalence);

    checkResolutionEnqueuers(backendUsage1, backendUsage2, enqueuer1, enqueuer2,
        elementEquivalence: equivalence.entityEquivalence,
        typeEquivalence: (ResolutionDartType a, DartType b) {
      return equivalence.typeEquivalence(unalias(a), b);
    }, elementFilter: elementFilter, verbose: arguments.verbose);

    checkClosedWorlds(closedWorld1, closedWorld2, equivalence.entityEquivalence,
        verbose: arguments.verbose);
  });
}

List createKernelResolutionEnqueuerListener(
    CompilerOptions options,
    DiagnosticReporter reporter,
    DeferredLoadTask deferredLoadTask,
    KernelToElementMap elementMap,
    NativeBasicData nativeBasicData) {
  ElementEnvironment elementEnvironment = elementMap.elementEnvironment;
  CommonElements commonElements = elementMap.commonElements;
  BackendImpacts impacts = new BackendImpacts(options, commonElements);

  // TODO(johnniwinther): Create Kernel based implementations for these:
  RuntimeTypesNeedBuilder rtiNeedBuilder = new RuntimeTypesNeedBuilderImpl();
  MirrorsDataBuilder mirrorsDataBuilder = new MirrorsDataBuilderImpl();
  CustomElementsResolutionAnalysis customElementsResolutionAnalysis =
      new CustomElementsResolutionAnalysisImpl();
  MirrorsResolutionAnalysis mirrorsResolutionAnalysis =
      new MirrorsResolutionAnalysisImpl();

  LookupMapResolutionAnalysis lookupMapResolutionAnalysis =
      new LookupMapResolutionAnalysis(reporter, elementEnvironment);
  InterceptorDataBuilder interceptorDataBuilder =
      new InterceptorDataBuilderImpl(
          nativeBasicData, elementEnvironment, commonElements);
  BackendUsageBuilder backendUsageBuilder =
      new BackendUsageBuilderImpl(commonElements);
  NoSuchMethodRegistry noSuchMethodRegistry = new NoSuchMethodRegistry(
      commonElements, new KernelNoSuchMethodResolver(elementMap));
  NativeClassFinder nativeClassFinder = new BaseNativeClassFinder(
      elementEnvironment, commonElements, nativeBasicData);
  NativeResolutionEnqueuer nativeResolutionEnqueuer =
      new NativeResolutionEnqueuer(options, elementEnvironment, commonElements,
          backendUsageBuilder, nativeClassFinder);

  ResolutionEnqueuerListener listener = new ResolutionEnqueuerListener(
      options,
      elementEnvironment,
      commonElements,
      impacts,
      nativeBasicData,
      interceptorDataBuilder,
      backendUsageBuilder,
      rtiNeedBuilder,
      mirrorsDataBuilder,
      noSuchMethodRegistry,
      customElementsResolutionAnalysis,
      lookupMapResolutionAnalysis,
      mirrorsResolutionAnalysis,
      new TypeVariableResolutionAnalysis(
          elementEnvironment, impacts, backendUsageBuilder),
      nativeResolutionEnqueuer,
      deferredLoadTask);

  ImpactTransformer transformer = new JavaScriptImpactTransformer(
      options,
      elementEnvironment,
      commonElements,
      impacts,
      nativeBasicData,
      nativeResolutionEnqueuer,
      backendUsageBuilder,
      mirrorsDataBuilder,
      customElementsResolutionAnalysis,
      rtiNeedBuilder);
  return [listener, backendUsageBuilder, transformer];
}

/// Computes that NativeBasicData for the libraries in [worldBuilder].
/// TODO(johnniwinther): Use [KernelAnnotationProcessor] instead.
NativeBasicData computeNativeBasicData(KernelToElementMap elementMap) {
  NativeBasicDataBuilderImpl builder = new NativeBasicDataBuilderImpl();
  ElementEnvironment elementEnvironment = elementMap.elementEnvironment;
  for (LibraryEntity library in elementEnvironment.libraries) {
    if (library.canonicalUri.scheme == 'dart') {
      new KernelAnnotationProcessor(elementMap)
          .extractNativeAnnotations(library, builder);
    }
  }
  return builder.close(elementEnvironment);
}

void checkNativeBasicData(NativeBasicDataImpl data1, NativeBasicDataImpl data2,
    KernelEquivalence equivalence) {
  checkMapEquivalence(
      data1,
      data2,
      'nativeClassTagInfo',
      data1.nativeClassTagInfo,
      data2.nativeClassTagInfo,
      equivalence.entityEquivalence,
      (a, b) => a == b);
  // TODO(johnniwinther): Check the remaining properties.
}

void checkBackendUsage(BackendUsageImpl usage1, BackendUsageImpl usage2,
    KernelEquivalence equivalence) {
  checkSetEquivalence(
      usage1,
      usage2,
      'globalClassDependencies',
      usage1.globalClassDependencies,
      usage2.globalClassDependencies,
      equivalence.entityEquivalence);
  checkSetEquivalence(
      usage1,
      usage2,
      'globalFunctionDependencies',
      usage1.globalFunctionDependencies,
      usage2.globalFunctionDependencies,
      equivalence.entityEquivalence);
  checkSetEquivalence(
      usage1,
      usage2,
      'helperClassesUsed',
      usage1.helperClassesUsed,
      usage2.helperClassesUsed,
      equivalence.entityEquivalence);
  checkSetEquivalence(
      usage1,
      usage2,
      'helperFunctionsUsed',
      usage1.helperFunctionsUsed,
      usage2.helperFunctionsUsed,
      equivalence.entityEquivalence);
  check(
      usage1,
      usage2,
      'needToInitializeIsolateAffinityTag',
      usage1.needToInitializeIsolateAffinityTag,
      usage2.needToInitializeIsolateAffinityTag);
  check(
      usage1,
      usage2,
      'needToInitializeDispatchProperty',
      usage1.needToInitializeDispatchProperty,
      usage2.needToInitializeDispatchProperty);
  check(usage1, usage2, 'requiresPreamble', usage1.requiresPreamble,
      usage2.requiresPreamble);
  check(usage1, usage2, 'isInvokeOnUsed', usage1.isInvokeOnUsed,
      usage2.isInvokeOnUsed);
  check(usage1, usage2, 'isRuntimeTypeUsed', usage1.isRuntimeTypeUsed,
      usage2.isRuntimeTypeUsed);
  check(usage1, usage2, 'isIsolateInUse', usage1.isIsolateInUse,
      usage2.isIsolateInUse);
  check(usage1, usage2, 'isFunctionApplyUsed', usage1.isFunctionApplyUsed,
      usage2.isFunctionApplyUsed);
  check(usage1, usage2, 'isNoSuchMethodUsed', usage1.isNoSuchMethodUsed,
      usage2.isNoSuchMethodUsed);
}
