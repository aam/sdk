// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library js_backend.backend;

import '../common.dart';
import '../common/backend_api.dart'
    show ForeignResolver, NativeRegistry, ImpactTransformer;
import '../common/codegen.dart' show CodegenImpact, CodegenWorkItem;
import '../common/names.dart' show Uris;
import '../common/resolution.dart' show Resolution, Target;
import '../common/tasks.dart' show CompilerTask;
import '../compiler.dart' show Compiler;
import '../constants/constant_system.dart';
import '../constants/expressions.dart';
import '../constants/values.dart';
import '../common_elements.dart' show CommonElements;
import '../deferred_load.dart' show DeferredLoadTask;
import '../dump_info.dart' show DumpInfoTask;
import '../elements/elements.dart';
import '../elements/entities.dart';
import '../elements/resolution_types.dart';
import '../elements/types.dart';
import '../enqueue.dart'
    show
        DirectEnqueuerStrategy,
        Enqueuer,
        EnqueueTask,
        ResolutionEnqueuer,
        TreeShakingEnqueuerStrategy;
import '../frontend_strategy.dart';
import '../io/multi_information.dart' show MultiSourceInformationStrategy;
import '../io/position_information.dart' show PositionSourceInformationStrategy;
import '../io/source_information.dart' show SourceInformationStrategy;
import '../io/start_end_information.dart'
    show StartEndSourceInformationStrategy;
import '../js/js.dart' as jsAst;
import '../js/js.dart' show js;
import '../js/js_source_mapping.dart' show JavaScriptSourceInformationStrategy;
import '../js/rewrite_async.dart';
import '../js_emitter/js_emitter.dart' show CodeEmitterTask, Emitter;
import '../kernel/task.dart';
import '../library_loader.dart' show LoadedLibraries;
import '../native/native.dart' as native;
import '../native/resolver.dart';
import '../ssa/ssa.dart' show SsaFunctionCompiler;
import '../tracer.dart';
import '../tree/tree.dart';
import '../types/types.dart';
import '../universe/call_structure.dart' show CallStructure;
import '../universe/selector.dart' show Selector;
import '../universe/world_builder.dart';
import '../universe/use.dart' show ConstantUse, StaticUse;
import '../universe/world_impact.dart'
    show ImpactStrategy, ImpactUseCase, WorldImpact, WorldImpactVisitor;
import '../util/util.dart';
import '../world.dart' show ClosedWorld, ClosedWorldRefiner;
import 'annotations.dart';
import 'backend_impact.dart';
import 'backend_serialization.dart' show JavaScriptBackendSerialization;
import 'backend_usage.dart';
import 'checked_mode_helpers.dart';
import 'codegen_listener.dart';
import 'constant_handler_javascript.dart';
import 'custom_elements_analysis.dart';
import 'enqueuer.dart';
import 'impact_transformer.dart';
import 'interceptor_data.dart';
import 'js_interop_analysis.dart' show JsInteropAnalysis;
import 'lookup_map_analysis.dart'
    show LookupMapResolutionAnalysis, LookupMapAnalysis;
import 'mirrors_analysis.dart';
import 'mirrors_data.dart';
import 'namer.dart';
import 'native_data.dart';
import 'no_such_method_registry.dart';
import 'patch_resolver.dart';
import 'resolution_listener.dart';
import 'type_variable_handler.dart';

part 'runtime_types.dart';

const VERBOSE_OPTIMIZER_HINTS = false;

abstract class FunctionCompiler {
  /// Generates JavaScript code for `work.element`.
  jsAst.Fun compile(CodegenWorkItem work, ClosedWorld closedWorld);

  Iterable get tasks;
}

/*
 * Invariants:
 *   canInline(function) implies canInline(function, insideLoop:true)
 *   !canInline(function, insideLoop: true) implies !canInline(function)
 */
class FunctionInlineCache {
  static const int _unknown = -1;
  static const int _mustNotInline = 0;
  // May-inline-in-loop means that the function may not be inlined outside loops
  // but may be inlined in a loop.
  static const int _mayInlineInLoopMustNotOutside = 1;
  // The function can be inlined in a loop, but not outside.
  static const int _canInlineInLoopMustNotOutside = 2;
  // May-inline means that we know that it can be inlined inside a loop, but
  // don't know about the general case yet.
  static const int _canInlineInLoopMayInlineOutside = 3;
  static const int _canInline = 4;
  static const int _mustInline = 5;

  final Map<MethodElement, int> _cachedDecisions =
      new Map<MethodElement, int>();

  /// Returns the current cache decision. This should only be used for testing.
  int getCurrentCacheDecisionForTesting(Element element) {
    return _cachedDecisions[element];
  }

  // Returns `true`/`false` if we have a cached decision.
  // Returns `null` otherwise.
  bool canInline(MethodElement element, {bool insideLoop}) {
    int decision = _cachedDecisions[element];

    if (decision == null) {
      // These synthetic elements are not yet present when we initially compute
      // this cache from metadata annotations, so look for their parent.
      if (element is ConstructorBodyElement) {
        ConstructorBodyElement body = element;
        decision = _cachedDecisions[body.constructor];
      }
      if (decision == null) {
        decision = _unknown;
      }
    }

    if (insideLoop) {
      switch (decision) {
        case _mustNotInline:
          return false;

        case _unknown:
        case _mayInlineInLoopMustNotOutside:
          // We know we can't inline outside a loop, but don't know for the
          // loop case. Return `null` to indicate that we don't know yet.
          return null;

        case _canInlineInLoopMustNotOutside:
        case _canInlineInLoopMayInlineOutside:
        case _canInline:
        case _mustInline:
          return true;
      }
    } else {
      switch (decision) {
        case _mustNotInline:
        case _mayInlineInLoopMustNotOutside:
        case _canInlineInLoopMustNotOutside:
          return false;

        case _unknown:
        case _canInlineInLoopMayInlineOutside:
          // We know we can inline inside a loop, but don't know for the
          // non-loop case. Return `null` to indicate that we don't know yet.
          return null;

        case _canInline:
        case _mustInline:
          return true;
      }
    }

    // Quiet static checker.
    return null;
  }

  void markAsInlinable(MethodElement element, {bool insideLoop}) {
    int oldDecision = _cachedDecisions[element];

    if (oldDecision == null) {
      oldDecision = _unknown;
    }

    if (insideLoop) {
      switch (oldDecision) {
        case _mustNotInline:
          throw new SpannableAssertionFailure(
              element,
              "Can't mark a function as non-inlinable and inlinable at the "
              "same time.");

        case _unknown:
          // We know that it can be inlined in a loop, but don't know about the
          // non-loop case yet.
          _cachedDecisions[element] = _canInlineInLoopMayInlineOutside;
          break;

        case _mayInlineInLoopMustNotOutside:
          _cachedDecisions[element] = _canInlineInLoopMustNotOutside;
          break;

        case _canInlineInLoopMustNotOutside:
        case _canInlineInLoopMayInlineOutside:
        case _canInline:
        case _mustInline:
          // Do nothing.
          break;
      }
    } else {
      switch (oldDecision) {
        case _mustNotInline:
        case _mayInlineInLoopMustNotOutside:
        case _canInlineInLoopMustNotOutside:
          throw new SpannableAssertionFailure(
              element,
              "Can't mark a function as non-inlinable and inlinable at the "
              "same time.");

        case _unknown:
        case _canInlineInLoopMayInlineOutside:
          _cachedDecisions[element] = _canInline;
          break;

        case _canInline:
        case _mustInline:
          // Do nothing.
          break;
      }
    }
  }

  void markAsNonInlinable(MethodElement element, {bool insideLoop: true}) {
    int oldDecision = _cachedDecisions[element];

    if (oldDecision == null) {
      oldDecision = _unknown;
    }

    if (insideLoop) {
      switch (oldDecision) {
        case _canInlineInLoopMustNotOutside:
        case _canInlineInLoopMayInlineOutside:
        case _canInline:
        case _mustInline:
          throw new SpannableAssertionFailure(
              element,
              "Can't mark a function as non-inlinable and inlinable at the "
              "same time.");

        case _mayInlineInLoopMustNotOutside:
        case _unknown:
          _cachedDecisions[element] = _mustNotInline;
          break;

        case _mustNotInline:
          // Do nothing.
          break;
      }
    } else {
      switch (oldDecision) {
        case _canInline:
        case _mustInline:
          throw new SpannableAssertionFailure(
              element,
              "Can't mark a function as non-inlinable and inlinable at the "
              "same time.");

        case _unknown:
          // We can't inline outside a loop, but we might still be allowed to do
          // so outside.
          _cachedDecisions[element] = _mayInlineInLoopMustNotOutside;
          break;

        case _canInlineInLoopMayInlineOutside:
          // We already knew that the function could be inlined inside a loop,
          // but didn't have information about the non-loop case. Now we know
          // that it can't be inlined outside a loop.
          _cachedDecisions[element] = _canInlineInLoopMustNotOutside;
          break;

        case _mayInlineInLoopMustNotOutside:
        case _canInlineInLoopMustNotOutside:
        case _mustNotInline:
          // Do nothing.
          break;
      }
    }
  }

  void markAsMustInline(MethodElement element) {
    _cachedDecisions[element] = _mustInline;
  }
}

enum SyntheticConstantKind {
  DUMMY_INTERCEPTOR,
  EMPTY_VALUE,
  TYPEVARIABLE_REFERENCE, // Reference to a type in reflection data.
  NAME
}

class JavaScriptBackend {
  static const String JS = 'JS';
  static const String JS_BUILTIN = 'JS_BUILTIN';
  static const String JS_EMBEDDED_GLOBAL = 'JS_EMBEDDED_GLOBAL';
  static const String JS_INTERCEPTOR_CONSTANT = 'JS_INTERCEPTOR_CONSTANT';

  final Compiler compiler;

  /// Returns true if the backend supports reflection.
  bool get supportsReflection => emitter.supportsReflection;

  final Annotations annotations;

  /// Set of classes that need to be considered for reflection although not
  /// otherwise visible during resolution.
  Iterable<ClassEntity> get classesRequiredForReflection {
    // TODO(herhut): Clean this up when classes needed for rti are tracked.
    return [commonElements.closureClass, commonElements.jsIndexableClass];
  }

  FunctionCompiler functionCompiler;

  CodeEmitterTask emitter;

  /**
   * The generated code as a js AST for compiled methods.
   */
  final Map<MemberElement, jsAst.Expression> generatedCode =
      <MemberElement, jsAst.Expression>{};

  FunctionInlineCache inlineCache = new FunctionInlineCache();

  /// If [true], the compiler will emit code that logs whenever a method is
  /// called. When TRACE_METHOD is 'console' this will be logged
  /// directly in the JavaScript console. When TRACE_METHOD is 'post' the
  /// information will be sent to a server via a POST request.
  static const String TRACE_METHOD = const String.fromEnvironment('traceCalls');
  static const bool TRACE_CALLS =
      TRACE_METHOD == 'post' || TRACE_METHOD == 'console';

  Namer _namer;

  Namer get namer {
    assert(invariant(NO_LOCATION_SPANNABLE, _namer != null,
        message: "Namer has not been created yet."));
    return _namer;
  }

  /**
   * Set of classes whose `operator ==` methods handle `null` themselves.
   */
  final Set<ClassElement> specialOperatorEqClasses = new Set<ClassElement>();

  List<CompilerTask> get tasks {
    List<CompilerTask> result = functionCompiler.tasks;
    result.add(emitter);
    result.add(patchResolverTask);
    result.add(kernelTask);
    return result;
  }

  final RuntimeTypesNeedBuilder _rtiNeedBuilder;
  RuntimeTypesNeed _rtiNeed;
  final _RuntimeTypes _rti;

  RuntimeTypesEncoder _rtiEncoder;

  /// True if the html library has been loaded.
  bool htmlLibraryIsLoaded = false;

  /// Resolution analysis for tracking reflective access to type variables.
  TypeVariableResolutionAnalysis _typeVariableResolutionAnalysis;

  /// Codegen handler for reflective access to type variables.
  TypeVariableCodegenAnalysis _typeVariableCodegenAnalysis;

  /// Resolution support for generating table of interceptors and
  /// constructors for custom elements.
  CustomElementsResolutionAnalysis _customElementsResolutionAnalysis;

  /// Codegen support for generating table of interceptors and
  /// constructors for custom elements.
  CustomElementsCodegenAnalysis _customElementsCodegenAnalysis;

  /// Resolution support for tree-shaking entries of `LookupMap`.
  LookupMapResolutionAnalysis lookupMapResolutionAnalysis;

  /// Codegen support for tree-shaking entries of `LookupMap`.
  LookupMapAnalysis _lookupMapAnalysis;

  /// Codegen support for typed JavaScript interop.
  JsInteropAnalysis jsInteropAnalysis;

  /// Support for classifying `noSuchMethod` implementations.
  NoSuchMethodRegistry noSuchMethodRegistry;

  /// Resolution support for computing reflectable elements.
  MirrorsResolutionAnalysis _mirrorsResolutionAnalysis;

  /// Codegen support for computing reflectable elements.
  MirrorsCodegenAnalysis _mirrorsCodegenAnalysis;

  /// Builds kernel representation for the program.
  KernelTask kernelTask;

  /// The compiler task responsible for the compilation of constants for both
  /// the frontend and the backend.
  final JavaScriptConstantTask constantCompilerTask;

  /// Backend transformation methods for the world impacts.
  ImpactTransformer impactTransformer;

  CodegenImpactTransformer _codegenImpactTransformer;

  PatchResolverTask patchResolverTask;

  /// The strategy used for collecting and emitting source information.
  SourceInformationStrategy sourceInformationStrategy;

  /// Interface for serialization of backend specific data.
  JavaScriptBackendSerialization serialization;

  NativeDataImpl _nativeData;
  final NativeBasicDataBuilderImpl _nativeBasicDataBuilder =
      new NativeBasicDataBuilderImpl();
  NativeBasicDataImpl _nativeBasicData;
  NativeData get nativeData => _nativeData;
  NativeDataBuilder get nativeDataBuilder => _nativeData;
  final NativeDataResolver _nativeDataResolver;
  InterceptorDataBuilder _interceptorDataBuilder;
  InterceptorData _interceptorData;
  OneShotInterceptorData _oneShotInterceptorData;
  BackendUsage _backendUsage;
  BackendUsageBuilder _backendUsageBuilder;
  MirrorsDataImpl _mirrorsData;
  CheckedModeHelpers _checkedModeHelpers;

  final SuperMemberData superMemberData = new SuperMemberData();

  native.NativeResolutionEnqueuer _nativeResolutionEnqueuer;
  native.NativeCodegenEnqueuer _nativeCodegenEnqueuer;

  BackendImpacts impacts;

  Target _target;

  Tracer tracer;

  static SourceInformationStrategy createSourceInformationStrategy(
      {bool generateSourceMap: false,
      bool useMultiSourceInfo: false,
      bool useNewSourceInfo: false}) {
    if (!generateSourceMap) return const JavaScriptSourceInformationStrategy();
    if (useMultiSourceInfo) {
      if (useNewSourceInfo) {
        return const MultiSourceInformationStrategy(const [
          const PositionSourceInformationStrategy(),
          const StartEndSourceInformationStrategy()
        ]);
      } else {
        return const MultiSourceInformationStrategy(const [
          const StartEndSourceInformationStrategy(),
          const PositionSourceInformationStrategy()
        ]);
      }
    } else if (useNewSourceInfo) {
      return const PositionSourceInformationStrategy();
    } else {
      return const StartEndSourceInformationStrategy();
    }
  }

  JavaScriptBackend(this.compiler,
      {bool generateSourceMap: true,
      bool useStartupEmitter: false,
      bool useMultiSourceInfo: false,
      bool useNewSourceInfo: false,
      bool useKernel: false})
      : _rti = new _RuntimeTypes(compiler),
        annotations = new Annotations(compiler),
        this.sourceInformationStrategy = createSourceInformationStrategy(
            generateSourceMap: generateSourceMap,
            useMultiSourceInfo: useMultiSourceInfo,
            useNewSourceInfo: useNewSourceInfo),
        constantCompilerTask = new JavaScriptConstantTask(compiler),
        _nativeDataResolver = new NativeDataResolverImpl(compiler),
        _rtiNeedBuilder =
            compiler.frontEndStrategy.createRuntimeTypesNeedBuilder() {
    _target = new JavaScriptBackendTarget(this);
    impacts = new BackendImpacts(compiler.options, commonElements);
    _mirrorsData = compiler.frontEndStrategy.createMirrorsDataBuilder();
    _backendUsageBuilder = new BackendUsageBuilderImpl(commonElements);
    _checkedModeHelpers = new CheckedModeHelpers(commonElements);
    emitter =
        new CodeEmitterTask(compiler, generateSourceMap, useStartupEmitter);

    _typeVariableResolutionAnalysis = new TypeVariableResolutionAnalysis(
        compiler.elementEnvironment, impacts, backendUsageBuilder);
    jsInteropAnalysis = new JsInteropAnalysis(this);
    _mirrorsResolutionAnalysis =
        compiler.frontEndStrategy.createMirrorsResolutionAnalysis(this);
    lookupMapResolutionAnalysis =
        new LookupMapResolutionAnalysis(reporter, compiler.elementEnvironment);

    noSuchMethodRegistry = new NoSuchMethodRegistry(
        commonElements, compiler.frontEndStrategy.createNoSuchMethodResolver());
    kernelTask = new KernelTask(compiler);
    patchResolverTask = new PatchResolverTask(compiler);
    functionCompiler =
        new SsaFunctionCompiler(this, sourceInformationStrategy, useKernel);
    serialization = new JavaScriptBackendSerialization(this);
  }

  /// The [ConstantSystem] used to interpret compile-time constants for this
  /// backend.
  ConstantSystem get constantSystem => constants.constantSystem;

  DiagnosticReporter get reporter => compiler.reporter;

  CommonElements get commonElements => compiler.commonElements;

  Resolution get resolution => compiler.resolution;

  Target get target => _target;

  /// Resolution support for generating table of interceptors and
  /// constructors for custom elements.
  CustomElementsResolutionAnalysis get customElementsResolutionAnalysis {
    assert(invariant(
        NO_LOCATION_SPANNABLE, _customElementsResolutionAnalysis != null,
        message: "CustomElementsResolutionAnalysis has not been created yet."));
    return _customElementsResolutionAnalysis;
  }

  /// Codegen support for generating table of interceptors and
  /// constructors for custom elements.
  CustomElementsCodegenAnalysis get customElementsCodegenAnalysis {
    assert(invariant(
        NO_LOCATION_SPANNABLE, _customElementsCodegenAnalysis != null,
        message: "CustomElementsCodegenAnalysis has not been created yet."));
    return _customElementsCodegenAnalysis;
  }

  NativeBasicData get nativeBasicData {
    assert(invariant(NO_LOCATION_SPANNABLE, _nativeBasicData != null,
        message: "NativeBasicData has not been computed yet."));
    return _nativeBasicData;
  }

  NativeBasicDataBuilder get nativeBasicDataBuilder => _nativeBasicDataBuilder;

  /// Resolution analysis for tracking reflective access to type variables.
  TypeVariableResolutionAnalysis get typeVariableResolutionAnalysis {
    assert(invariant(
        NO_LOCATION_SPANNABLE, _typeVariableCodegenAnalysis == null,
        message: "TypeVariableHandler has already been created."));
    return _typeVariableResolutionAnalysis;
  }

  /// Codegen handler for reflective access to type variables.
  TypeVariableCodegenAnalysis get typeVariableCodegenAnalysis {
    assert(invariant(
        NO_LOCATION_SPANNABLE, _typeVariableCodegenAnalysis != null,
        message: "TypeVariableHandler has not been created yet."));
    return _typeVariableCodegenAnalysis;
  }

  MirrorsData get mirrorsData => _mirrorsData;

  MirrorsDataBuilder get mirrorsDataBuilder => _mirrorsData;

  /// Resolution support for computing reflectable elements.
  MirrorsResolutionAnalysis get mirrorsResolutionAnalysis =>
      _mirrorsResolutionAnalysis;

  /// Codegen support for computing reflectable elements.
  MirrorsCodegenAnalysis get mirrorsCodegenAnalysis {
    assert(invariant(NO_LOCATION_SPANNABLE, _mirrorsCodegenAnalysis != null,
        message: "MirrorsCodegenAnalysis has not been created yet."));
    return _mirrorsCodegenAnalysis;
  }

  /// Codegen support for tree-shaking entries of `LookupMap`.
  LookupMapAnalysis get lookupMapAnalysis {
    assert(invariant(NO_LOCATION_SPANNABLE, _lookupMapAnalysis != null,
        message: "LookupMapAnalysis has not been created yet."));
    return _lookupMapAnalysis;
  }

  InterceptorData get interceptorData {
    assert(invariant(NO_LOCATION_SPANNABLE, _interceptorData != null,
        message: "InterceptorData has not been computed yet."));
    return _interceptorData;
  }

  InterceptorDataBuilder get interceptorDataBuilder {
    assert(invariant(NO_LOCATION_SPANNABLE, _interceptorData == null,
        message: "InterceptorData has already been computed."));
    return _interceptorDataBuilder;
  }

  OneShotInterceptorData get oneShotInterceptorData {
    assert(invariant(NO_LOCATION_SPANNABLE, _oneShotInterceptorData != null,
        message: "OneShotInterceptorData has not been prepared yet."));
    return _oneShotInterceptorData;
  }

  BackendUsage get backendUsage {
    assert(invariant(NO_LOCATION_SPANNABLE, _backendUsage != null,
        message: "BackendUsage has not been computed yet."));
    return _backendUsage;
  }

  BackendUsageBuilder get backendUsageBuilder {
    assert(invariant(NO_LOCATION_SPANNABLE, _backendUsage == null,
        message: "BackendUsage has already been computed."));
    return _backendUsageBuilder;
  }

  RuntimeTypesNeed get rtiNeed {
    assert(invariant(NO_LOCATION_SPANNABLE, _rtiNeed != null,
        message: "RuntimeTypesNeed has not been computed yet."));
    return _rtiNeed;
  }

  RuntimeTypesNeedBuilder get rtiNeedBuilder {
    assert(invariant(NO_LOCATION_SPANNABLE, _rtiNeed == null,
        message: "RuntimeTypesNeed has already been computed."));
    return _rtiNeedBuilder;
  }

  RuntimeTypesChecksBuilder get rtiChecksBuilder {
    assert(invariant(NO_LOCATION_SPANNABLE, !_rti.rtiChecksBuilderClosed,
        message: "RuntimeTypesChecks has already been computed."));
    return _rti;
  }

  RuntimeTypesSubstitutions get rtiSubstitutions => _rti;

  RuntimeTypesEncoder get rtiEncoder {
    assert(invariant(NO_LOCATION_SPANNABLE, _rtiEncoder != null,
        message: "RuntimeTypesEncoder has not been created."));
    return _rtiEncoder;
  }

  CheckedModeHelpers get checkedModeHelpers => _checkedModeHelpers;

  /// Returns constant environment for the JavaScript interpretation of the
  /// constants.
  JavaScriptConstantCompiler get constants {
    return constantCompilerTask.jsConstantCompiler;
  }

  MethodElement resolveExternalFunction(MethodElement element) {
    if (isForeign(element)) {
      return element;
    }
    if (_nativeDataResolver.isJsInteropMember(element)) {
      if (element.memberName == const PublicName('[]') ||
          element.memberName == const PublicName('[]=')) {
        reporter.reportErrorMessage(
            element, MessageKind.JS_INTEROP_INDEX_NOT_SUPPORTED);
      }
      return element;
    }
    return patchResolverTask.measure(() {
      return patchResolverTask.resolveExternalFunction(element);
    });
  }

  bool isForeign(Element element) =>
      element.library == commonElements.foreignLibrary;

  bool isBackendLibrary(LibraryElement library) {
    return library == commonElements.interceptorsLibrary ||
        library == compiler.commonElements.jsHelperLibrary;
  }

  Namer determineNamer(
      ClosedWorld closedWorld, CodegenWorldBuilder codegenWorldBuilder) {
    return compiler.options.enableMinification
        ? compiler.options.useFrequencyNamer
            ? new FrequencyBasedNamer(
                nativeData, closedWorld, codegenWorldBuilder)
            : new MinifyNamer(nativeData, closedWorld, codegenWorldBuilder)
        : new Namer(nativeData, closedWorld, codegenWorldBuilder);
  }

  /// Returns true if global optimizations such as type inferencing can apply to
  /// the field [element].
  ///
  /// One category of elements that do not apply is runtime helpers that the
  /// backend calls, but the optimizations don't see those calls.
  bool canFieldBeUsedForGlobalOptimizations(FieldElement element) {
    return !backendUsage.isFieldUsedByBackend(element) &&
        !mirrorsData.invokedReflectively(element);
  }

  /// Returns true if global optimizations such as type inferencing can apply to
  /// the parameter [element].
  ///
  /// One category of elements that do not apply is runtime helpers that the
  /// backend calls, but the optimizations don't see those calls.
  bool canFunctionParametersBeUsedForGlobalOptimizations(
      FunctionElement element) {
    if (element.isLocal) return true;
    MethodElement method = element;
    return !backendUsage.isFunctionUsedByBackend(method) &&
        !mirrorsData.invokedReflectively(method);
  }

  /// Maps compile-time classes to their runtime class.  The runtime class is
  /// always a superclass or the class itself.
  ClassElement getRuntimeClass(ClassElement class_) {
    if (class_.isSubclassOf(commonElements.jsIntClass))
      return commonElements.jsIntClass;
    if (class_.isSubclassOf(commonElements.jsArrayClass))
      return commonElements.jsArrayClass;
    return class_;
  }

  bool operatorEqHandlesNullArgument(FunctionElement operatorEqfunction) {
    return specialOperatorEqClasses.contains(operatorEqfunction.enclosingClass);
  }

  void validateInterceptorImplementsAllObjectMethods(
      ClassElement interceptorClass) {
    if (interceptorClass == null) return;
    interceptorClass.ensureResolved(resolution);
    ClassElement objectClass = commonElements.objectClass;
    objectClass.forEachMember((_, Element member) {
      if (member.isGenerativeConstructor) return;
      Element interceptorMember = interceptorClass.lookupMember(member.name);
      // Interceptors must override all Object methods due to calling convention
      // differences.
      assert(invariant(interceptorMember,
          interceptorMember.enclosingClass == interceptorClass,
          message:
              "Member ${member.name} not overridden in ${interceptorClass}. "
              "Found $interceptorMember from "
              "${interceptorMember.enclosingClass}."));
    });
  }

  /// Called before processing of the resolution queue is started.
  void onResolutionStart(ResolutionEnqueuer enqueuer) {
    // TODO(johnniwinther): Avoid the compiler.elementEnvironment.getThisType
    // calls. Currently needed to ensure resolution of the classes for various
    // queries in native behavior computation, inference and codegen.
    compiler.elementEnvironment.getThisType(commonElements.jsArrayClass);
    compiler.elementEnvironment
        .getThisType(commonElements.jsExtendableArrayClass);

    validateInterceptorImplementsAllObjectMethods(
        commonElements.jsInterceptorClass);
    // The null-interceptor must also implement *all* methods.
    validateInterceptorImplementsAllObjectMethods(commonElements.jsNullClass);
  }

  /// Called when the resolution queue has been closed.
  void onResolutionEnd() {
    _backendUsage = backendUsageBuilder.close();
    _interceptorData = interceptorDataBuilder.onResolutionComplete();
  }

  /// Called when the closed world from resolution has been computed.
  void onResolutionClosedWorld(
      ClosedWorld closedWorld, ClosedWorldRefiner closedWorldRefiner) {
    for (MemberEntity entity
        in compiler.enqueuer.resolution.processedEntities) {
      processAnnotations(entity, closedWorldRefiner);
    }
    mirrorsDataBuilder.computeMembersNeededForReflection(
        compiler.enqueuer.resolution.worldBuilder, closedWorld);
    _rtiNeed = rtiNeedBuilder.computeRuntimeTypesNeed(
        compiler.enqueuer.resolution.worldBuilder,
        closedWorld,
        compiler.types,
        commonElements,
        _backendUsage,
        enableTypeAssertions: compiler.options.enableTypeAssertions);
    _oneShotInterceptorData =
        new OneShotInterceptorData(interceptorData, commonElements);
    mirrorsResolutionAnalysis.onResolutionComplete();
  }

  void onTypeInferenceComplete(GlobalTypeInferenceResults results) {
    noSuchMethodRegistry.onTypeInferenceComplete(results);
  }

  /// Called when resolving a call to a foreign function.
  native.NativeBehavior resolveForeignCall(Send node, Element element,
      CallStructure callStructure, ForeignResolver resolver) {
    if (element.name == JS) {
      return _nativeDataResolver.resolveJsCall(node, resolver);
    } else if (element.name == JS_EMBEDDED_GLOBAL) {
      return _nativeDataResolver.resolveJsEmbeddedGlobalCall(node, resolver);
    } else if (element.name == JS_BUILTIN) {
      return _nativeDataResolver.resolveJsBuiltinCall(node, resolver);
    } else if (element.name == JS_INTERCEPTOR_CONSTANT) {
      // The type constant that is an argument to JS_INTERCEPTOR_CONSTANT names
      // a class that will be instantiated outside the program by attaching a
      // native class dispatch record referencing the interceptor.
      if (!node.argumentsNode.isEmpty) {
        Node argument = node.argumentsNode.nodes.head;
        ConstantExpression constant = resolver.getConstant(argument);
        if (constant != null && constant.kind == ConstantExpressionKind.TYPE) {
          TypeConstantExpression typeConstant = constant;
          if (typeConstant.type is ResolutionInterfaceType) {
            resolver.registerInstantiatedType(typeConstant.type);
            // No native behavior for this call.
            return null;
          }
        }
      }
      reporter.reportErrorMessage(
          node, MessageKind.WRONG_ARGUMENT_FOR_JS_INTERCEPTOR_CONSTANT);
    }
    // No native behavior for this call.
    return null;
  }

  ResolutionEnqueuer createResolutionEnqueuer(
      CompilerTask task, Compiler compiler) {
    _nativeBasicData =
        nativeBasicDataBuilder.close(compiler.elementEnvironment);
    _nativeResolutionEnqueuer = new native.NativeResolutionEnqueuer(
        compiler.options,
        compiler.elementEnvironment,
        commonElements,
        backendUsageBuilder,
        compiler.frontEndStrategy.createNativeClassResolver(nativeBasicData));
    _nativeData = new NativeDataImpl(nativeBasicData);
    _customElementsResolutionAnalysis = compiler.frontEndStrategy
        .createCustomElementsResolutionAnalysis(
            nativeBasicData, backendUsageBuilder);
    impactTransformer = new JavaScriptImpactTransformer(
        compiler.options,
        compiler.elementEnvironment,
        commonElements,
        impacts,
        nativeBasicData,
        _nativeResolutionEnqueuer,
        backendUsageBuilder,
        mirrorsDataBuilder,
        customElementsResolutionAnalysis,
        rtiNeedBuilder);
    _interceptorDataBuilder = new InterceptorDataBuilderImpl(
        nativeBasicData, compiler.elementEnvironment, commonElements);
    return new ResolutionEnqueuer(
        task,
        compiler.options,
        compiler.reporter,
        compiler.options.analyzeOnly && compiler.options.analyzeMain
            ? const DirectEnqueuerStrategy()
            : const TreeShakingEnqueuerStrategy(),
        new ResolutionEnqueuerListener(
            compiler.options,
            compiler.elementEnvironment,
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
            typeVariableResolutionAnalysis,
            _nativeResolutionEnqueuer,
            compiler.deferredLoadTask,
            kernelTask),
        compiler.frontEndStrategy.createResolutionWorldBuilder(
            nativeBasicData, const OpenWorldStrategy()),
        compiler.frontEndStrategy
            .createResolutionWorkItemBuilder(impactTransformer));
  }

  /// Creates an [Enqueuer] for code generation specific to this backend.
  CodegenEnqueuer createCodegenEnqueuer(
      CompilerTask task, Compiler compiler, ClosedWorld closedWorld) {
    _typeVariableCodegenAnalysis = new TypeVariableCodegenAnalysis(
        compiler.elementEnvironment, this, commonElements, mirrorsData);
    _lookupMapAnalysis = new LookupMapAnalysis(
        reporter,
        constantSystem,
        constants,
        compiler.elementEnvironment,
        commonElements,
        lookupMapResolutionAnalysis);
    _mirrorsCodegenAnalysis = mirrorsResolutionAnalysis.close();
    _customElementsCodegenAnalysis = new CustomElementsCodegenAnalysis(
        compiler.resolution, constantSystem, commonElements, nativeBasicData);
    _nativeCodegenEnqueuer = new native.NativeCodegenEnqueuer(
        compiler.options,
        compiler.elementEnvironment,
        commonElements,
        emitter,
        _nativeResolutionEnqueuer,
        nativeData);
    return new CodegenEnqueuer(
        task,
        compiler.options,
        const TreeShakingEnqueuerStrategy(),
        new CodegenWorldBuilderImpl(
            nativeBasicData, closedWorld, constants, const TypeMaskStrategy()),
        new CodegenWorkItemBuilder(this, compiler.options),
        new CodegenEnqueuerListener(
            compiler.elementEnvironment,
            commonElements,
            impacts,
            backendUsage,
            rtiNeed,
            customElementsCodegenAnalysis,
            typeVariableCodegenAnalysis,
            lookupMapAnalysis,
            mirrorsCodegenAnalysis,
            nativeCodegenEnqueuer));
  }

  WorldImpact codegen(CodegenWorkItem work) {
    MemberElement element = work.element;
    if (compiler.elementHasCompileTimeError(element)) {
      DiagnosticMessage message =
          // If there's more than one error, the first is probably most
          // informative, as the following errors may be side-effects of the
          // first error.
          compiler.elementsWithCompileTimeErrors[element].first;
      String messageText = message.message.computeMessage();
      jsAst.LiteralString messageLiteral =
          js.escapedString("Compile time error in $element: $messageText");
      generatedCode[element] =
          js("function () { throw new Error(#); }", [messageLiteral]);
      return const CodegenImpact();
    }
    var kind = element.kind;
    if (kind == ElementKind.TYPEDEF) {
      return const WorldImpact();
    }
    if (element.isConstructor &&
        element.enclosingClass == commonElements.jsNullClass) {
      // Work around a problem compiling JSNull's constructor.
      return const CodegenImpact();
    }
    if (kind.category == ElementCategory.VARIABLE) {
      FieldElement variableElement = element;
      ConstantExpression constant = variableElement.constant;
      if (constant != null) {
        ConstantValue initialValue = constants.getConstantValue(constant);
        if (initialValue != null) {
          work.registry.worldImpact
              .registerConstantUse(new ConstantUse.init(initialValue));
          // We don't need to generate code for static or top-level
          // variables. For instance variables, we may need to generate
          // the checked setter.
          if (Elements.isStaticOrTopLevel(element)) {
            return _codegenImpactTransformer
                .transformCodegenImpact(work.registry.worldImpact);
          }
        } else {
          assert(invariant(
              variableElement,
              variableElement.isInstanceMember ||
                  constant.isImplicit ||
                  constant.isPotential,
              message: "Constant expression without value: "
                  "${constant.toStructuredText()}."));
        }
      } else {
        // If the constant-handler was not able to produce a result we have to
        // go through the builder (below) to generate the lazy initializer for
        // the static variable.
        // We also need to register the use of the cyclic-error helper.
        work.registry.worldImpact.registerStaticUse(new StaticUse.staticInvoke(
            commonElements.cyclicThrowHelper, CallStructure.ONE_ARG));
      }
    }

    jsAst.Fun function = functionCompiler.compile(work, _closedWorld);
    if (function.sourceInformation == null) {
      function = function.withSourceInformation(
          sourceInformationStrategy.buildSourceMappedMarker());
    }
    generatedCode[element] = function;
    WorldImpact worldImpact = _codegenImpactTransformer
        .transformCodegenImpact(work.registry.worldImpact);
    compiler.dumpInfoTask.registerImpact(element, worldImpact);
    return worldImpact;
  }

  // TODO(johnniwinther): Remove this. It is now only used for testing.
  @deprecated
  native.NativeEnqueuer get nativeResolutionEnqueuer =>
      _nativeResolutionEnqueuer;

  native.NativeEnqueuer get nativeCodegenEnqueuer => _nativeCodegenEnqueuer;

  ClassElement defaultSuperclass(ClassElement element) {
    if (nativeBasicData.isJsInteropClass(element)) {
      return commonElements.jsJavaScriptObjectClass;
    }
    // Native classes inherit from Interceptor.
    return nativeBasicData.isNativeClass(element)
        ? commonElements.jsInterceptorClass
        : commonElements.objectClass;
  }

  /**
   * Unit test hook that returns code of an element as a String.
   *
   * Invariant: [element] must be a declaration element.
   */
  String getGeneratedCode(Element element) {
    assert(invariant(element, element.isDeclaration));
    return jsAst.prettyPrint(generatedCode[element], compiler.options);
  }

  /// Generates the output and returns the total size of the generated code.
  int assembleProgram(ClosedWorld closedWorld) {
    int programSize = emitter.assembleProgram(namer, closedWorld);
    noSuchMethodRegistry.emitDiagnostic(reporter);
    int totalMethodCount = generatedCode.length;
    if (totalMethodCount != mirrorsCodegenAnalysis.preMirrorsMethodCount) {
      int mirrorCount =
          totalMethodCount - mirrorsCodegenAnalysis.preMirrorsMethodCount;
      double percentage = (mirrorCount / totalMethodCount) * 100;
      DiagnosticMessage hint =
          reporter.createMessage(compiler.mainApp, MessageKind.MIRROR_BLOAT, {
        'count': mirrorCount,
        'total': totalMethodCount,
        'percentage': percentage.round()
      });

      List<DiagnosticMessage> infos = <DiagnosticMessage>[];
      for (LibraryElement library in compiler.libraryLoader.libraries) {
        if (library.isInternalLibrary) continue;
        for (ImportElement import in library.imports) {
          LibraryElement importedLibrary = import.importedLibrary;
          if (importedLibrary != compiler.commonElements.mirrorsLibrary)
            continue;
          MessageKind kind =
              compiler.mirrorUsageAnalyzerTask.hasMirrorUsage(library)
                  ? MessageKind.MIRROR_IMPORT
                  : MessageKind.MIRROR_IMPORT_NO_USAGE;
          reporter.withCurrentElement(library, () {
            infos.add(reporter.createMessage(import, kind));
          });
        }
      }
      reporter.reportHint(hint, infos);
    }
    return programSize;
  }

  /**
   * Returns [:true:] if the checking of [type] is performed directly on the
   * object and not on an interceptor.
   */
  bool hasDirectCheckFor(ResolutionDartType type) {
    Element element = type.element;
    return element == commonElements.stringClass ||
        element == commonElements.boolClass ||
        element == commonElements.numClass ||
        element == commonElements.intClass ||
        element == commonElements.doubleClass ||
        element == commonElements.jsArrayClass ||
        element == commonElements.jsMutableArrayClass ||
        element == commonElements.jsExtendableArrayClass ||
        element == commonElements.jsFixedArrayClass ||
        element == commonElements.jsUnmodifiableArrayClass;
  }

  /// This method is called immediately after the [library] and its parts have
  /// been loaded.
  void setAnnotations(LibraryEntity library) {
    if (!compiler.serialization.isDeserialized(library)) {
      AnnotationProcessor processor =
          compiler.frontEndStrategy.annotationProcesser;
      if (canLibraryUseNative(library)) {
        processor.extractNativeAnnotations(library, nativeBasicDataBuilder);
      }
      processor.extractJsInteropAnnotations(library, nativeBasicDataBuilder);
    }
    Uri uri = library.canonicalUri;
    if (uri == Uris.dart_html) {
      htmlLibraryIsLoaded = true;
    } else if (uri == LookupMapResolutionAnalysis.PACKAGE_LOOKUP_MAP) {
      lookupMapResolutionAnalysis.init(library);
    }
    annotations.onLibraryLoaded(library);
  }

  /// This method is called when all new libraries loaded through
  /// [LibraryLoader.loadLibrary] has been loaded and their imports/exports
  /// have been computed.
  void onLibrariesLoaded(LoadedLibraries loadedLibraries) {
    if (loadedLibraries.containsLibrary(Uris.dart_core)) {
      assert(loadedLibraries.containsLibrary(Uris.dart_core));
      assert(loadedLibraries.containsLibrary(Uris.dart__interceptors));
      assert(loadedLibraries.containsLibrary(Uris.dart__js_helper));

      // These methods are overwritten with generated versions.
      inlineCache.markAsNonInlinable(commonElements.getInterceptorMethod,
          insideLoop: true);

      specialOperatorEqClasses
        ..add(commonElements.objectClass)
        ..add(commonElements.jsInterceptorClass)
        ..add(commonElements.jsNullClass);
    }
  }

  /// Called after the queue is closed. [onQueueEmpty] may be called multiple
  /// times, but [onQueueClosed] is only called once.
  void onQueueClosed() {
    jsInteropAnalysis.onQueueClosed();
  }

  // TODO(johnniwinther): Create a CodegenPhase object for the backend to hold
  // data only available during code generation.
  ClosedWorld _closedWorldCache;
  ClosedWorld get _closedWorld {
    assert(invariant(NO_LOCATION_SPANNABLE, _closedWorldCache != null,
        message: "ClosedWorld has not be set yet."));
    return _closedWorldCache;
  }

  void set _closedWorld(ClosedWorld value) {
    _closedWorldCache = value;
  }

  /// Called when the compiler starts running the codegen enqueuer. The
  /// [WorldImpact] of enabled backend features is returned.
  WorldImpact onCodegenStart(
      ClosedWorld closedWorld, CodegenWorldBuilder codegenWorldBuilder) {
    _closedWorld = closedWorld;
    _namer = determineNamer(closedWorld, codegenWorldBuilder);
    tracer = new Tracer(closedWorld, namer, compiler);
    _rtiEncoder =
        _namer.rtiEncoder = new _RuntimeTypesEncoder(namer, commonElements);
    emitter.createEmitter(namer, closedWorld, codegenWorldBuilder);
    _codegenImpactTransformer = new CodegenImpactTransformer(
        compiler.options,
        compiler.elementEnvironment,
        commonElements,
        impacts,
        checkedModeHelpers,
        nativeData,
        backendUsage,
        rtiNeed,
        nativeCodegenEnqueuer,
        namer,
        oneShotInterceptorData,
        lookupMapAnalysis,
        rtiChecksBuilder);
    return const WorldImpact();
  }

  /// Called when code generation has been completed.
  void onCodegenEnd() {
    sourceInformationStrategy.onComplete();
    tracer.close();
  }

  // Does this element belong in the output
  bool shouldOutput(Element element) => true;

  /// Returns `true` if the `native` pseudo keyword is supported for [library].
  bool canLibraryUseNative(LibraryElement library) {
    return native.maybeEnableNative(compiler, library);
  }

  bool isTargetSpecificLibrary(LibraryElement library) {
    Uri canonicalUri = library.canonicalUri;
    if (canonicalUri == Uris.dart__js_helper ||
        canonicalUri == Uris.dart__interceptors) {
      return true;
    }
    return false;
  }

  /// Process backend specific annotations.
  void processAnnotations(
      MemberElement element, ClosedWorldRefiner closedWorldRefiner) {
    if (element.isMalformed) {
      // Elements that are marked as malformed during parsing or resolution
      // might be registered here. These should just be ignored.
      return;
    }

    MemberElement implementation = element.implementation;
    if (element.isFunction || element.isConstructor) {
      if (annotations.noInline(implementation)) {
        inlineCache.markAsNonInlinable(implementation);
      }
    }

    LibraryElement library = element.library;
    if (!library.isPlatformLibrary && !canLibraryUseNative(library)) return;
    bool hasNoInline = false;
    bool hasForceInline = false;
    bool hasNoThrows = false;
    bool hasNoSideEffects = false;
    for (MetadataAnnotation metadata in element.implementation.metadata) {
      metadata.ensureResolved(resolution);
      ConstantValue constantValue =
          compiler.constants.getConstantValue(metadata.constant);
      if (!constantValue.isConstructedObject) continue;
      ObjectConstantValue value = constantValue;
      ClassElement cls = value.type.element;
      if (cls == commonElements.forceInlineClass) {
        hasForceInline = true;
        if (VERBOSE_OPTIMIZER_HINTS) {
          reporter.reportHintMessage(
              element, MessageKind.GENERIC, {'text': "Must inline"});
        }
        inlineCache.markAsMustInline(element);
      } else if (cls == commonElements.noInlineClass) {
        hasNoInline = true;
        if (VERBOSE_OPTIMIZER_HINTS) {
          reporter.reportHintMessage(
              element, MessageKind.GENERIC, {'text': "Cannot inline"});
        }
        inlineCache.markAsNonInlinable(element);
      } else if (cls == commonElements.noThrowsClass) {
        hasNoThrows = true;
        if (!Elements.isStaticOrTopLevelFunction(element) &&
            !element.isFactoryConstructor) {
          reporter.internalError(
              element,
              "@NoThrows() is currently limited to top-level"
              " or static functions and factory constructors.");
        }
        if (VERBOSE_OPTIMIZER_HINTS) {
          reporter.reportHintMessage(
              element, MessageKind.GENERIC, {'text': "Cannot throw"});
        }
        closedWorldRefiner.registerCannotThrow(element);
      } else if (cls == commonElements.noSideEffectsClass) {
        hasNoSideEffects = true;
        if (VERBOSE_OPTIMIZER_HINTS) {
          reporter.reportHintMessage(
              element, MessageKind.GENERIC, {'text': "Has no side effects"});
        }
        closedWorldRefiner.registerSideEffectsFree(element);
      }
    }
    if (hasForceInline && hasNoInline) {
      reporter.internalError(
          element, "@ForceInline() must not be used with @NoInline.");
    }
    if (hasNoThrows && !hasNoInline) {
      reporter.internalError(
          element, "@NoThrows() should always be combined with @NoInline.");
    }
    if (hasNoSideEffects && !hasNoInline) {
      reporter.internalError(element,
          "@NoSideEffects() should always be combined with @NoInline.");
    }
  }

  MethodElement helperForBadMain() => commonElements.badMain;

  MethodElement helperForMissingMain() => commonElements.missingMain;

  MethodElement helperForMainArity() => commonElements.mainHasTooManyParameters;

  /// Enable deferred loading. Returns `true` if the backend supports deferred
  /// loading.
  bool enableDeferredLoadingIfSupported(Spannable node) => true;

  /// Enable compilation of code with compile time errors. Returns `true` if
  /// supported by the backend.
  bool enableCodegenWithErrorsIfSupported(Spannable node) => true;

  jsAst.Expression rewriteAsync(
      FunctionElement element, jsAst.Expression code) {
    AsyncRewriterBase rewriter = null;
    jsAst.Name name = namer.methodPropertyName(element);
    switch (element.asyncMarker) {
      case AsyncMarker.ASYNC:
        rewriter = new AsyncRewriter(reporter, element,
            asyncHelper:
                emitter.staticFunctionAccess(commonElements.asyncHelper),
            wrapBody: emitter.staticFunctionAccess(commonElements.wrapBody),
            newCompleter: emitter
                .staticFunctionAccess(commonElements.syncCompleterConstructor),
            safeVariableName: namer.safeVariablePrefixForAsyncRewrite,
            bodyName: namer.deriveAsyncBodyName(name));
        break;
      case AsyncMarker.SYNC_STAR:
        rewriter = new SyncStarRewriter(reporter, element,
            endOfIteration:
                emitter.staticFunctionAccess(commonElements.endOfIteration),
            newIterable: emitter.staticFunctionAccess(
                commonElements.syncStarIterableConstructor),
            yieldStarExpression:
                emitter.staticFunctionAccess(commonElements.yieldStar),
            uncaughtErrorExpression: emitter
                .staticFunctionAccess(commonElements.syncStarUncaughtError),
            safeVariableName: namer.safeVariablePrefixForAsyncRewrite,
            bodyName: namer.deriveAsyncBodyName(name));
        break;
      case AsyncMarker.ASYNC_STAR:
        rewriter = new AsyncStarRewriter(reporter, element,
            asyncStarHelper:
                emitter.staticFunctionAccess(commonElements.asyncStarHelper),
            streamOfController:
                emitter.staticFunctionAccess(commonElements.streamOfController),
            wrapBody: emitter.staticFunctionAccess(commonElements.wrapBody),
            newController: emitter.staticFunctionAccess(
                commonElements.asyncStarControllerConstructor),
            safeVariableName: namer.safeVariablePrefixForAsyncRewrite,
            yieldExpression:
                emitter.staticFunctionAccess(commonElements.yieldSingle),
            yieldStarExpression:
                emitter.staticFunctionAccess(commonElements.yieldStar),
            bodyName: namer.deriveAsyncBodyName(name));
        break;
      default:
        assert(element.asyncMarker == AsyncMarker.SYNC);
        return code;
    }
    return rewriter.rewrite(code);
  }

  /// Creates an impact strategy to use for compilation.
  ImpactStrategy createImpactStrategy(
      {bool supportDeferredLoad: true,
      bool supportDumpInfo: true,
      bool supportSerialization: true}) {
    return new JavaScriptImpactStrategy(resolution, compiler.dumpInfoTask,
        supportDeferredLoad: supportDeferredLoad,
        supportDumpInfo: supportDumpInfo,
        supportSerialization: supportSerialization);
  }

  EnqueueTask makeEnqueuer() => new EnqueueTask(compiler);
}

class JavaScriptImpactStrategy extends ImpactStrategy {
  final Resolution resolution;
  final DumpInfoTask dumpInfoTask;
  final bool supportDeferredLoad;
  final bool supportDumpInfo;
  final bool supportSerialization;

  JavaScriptImpactStrategy(this.resolution, this.dumpInfoTask,
      {this.supportDeferredLoad,
      this.supportDumpInfo,
      this.supportSerialization});

  @override
  void visitImpact(var impactSource, WorldImpact impact,
      WorldImpactVisitor visitor, ImpactUseCase impactUse) {
    // TODO(johnniwinther): Compute the application strategy once for each use.
    if (impactUse == ResolutionEnqueuer.IMPACT_USE) {
      if (supportDeferredLoad || supportSerialization) {
        impact.apply(visitor);
      } else {
        impact.apply(visitor);
        if (impactSource is Element) {
          resolution.uncacheWorldImpact(impactSource);
        }
      }
    } else if (impactUse == DeferredLoadTask.IMPACT_USE) {
      impact.apply(visitor);
      // Impacts are uncached globally in [onImpactUsed].
    } else if (impactUse == DumpInfoTask.IMPACT_USE) {
      impact.apply(visitor);
      dumpInfoTask.unregisterImpact(impactSource);
    } else {
      impact.apply(visitor);
    }
  }

  @override
  void onImpactUsed(ImpactUseCase impactUse) {
    if (impactUse == DeferredLoadTask.IMPACT_USE && !supportSerialization) {
      // TODO(johnniwinther): Allow emptying when serialization has been
      // performed.
      resolution.emptyCache();
    }
  }
}

class JavaScriptBackendTarget extends Target {
  final JavaScriptBackend _backend;

  JavaScriptBackendTarget(this._backend);

  @override
  bool isTargetSpecificLibrary(LibraryElement element) {
    return _backend.isTargetSpecificLibrary(element);
  }

  @override
  void resolveNativeMember(MemberElement element, NativeRegistry registry) {
    return _backend._nativeDataResolver.resolveNativeMember(element, registry);
  }

  @override
  MethodElement resolveExternalFunction(MethodElement element) {
    return _backend.resolveExternalFunction(element);
  }

  @override
  dynamic resolveForeignCall(Send node, Element element,
      CallStructure callStructure, ForeignResolver resolver) {
    return _backend.resolveForeignCall(node, element, callStructure, resolver);
  }

  @override
  bool isDefaultNoSuchMethod(MethodElement element) {
    return _backend.commonElements.isDefaultNoSuchMethodImplementation(element);
  }

  @override
  ClassElement defaultSuperclass(ClassElement element) {
    return _backend.defaultSuperclass(element);
  }

  @override
  bool isNativeClass(ClassEntity element) =>
      _backend.nativeBasicData.isNativeClass(element);

  @override
  bool isForeign(Element element) => _backend.isForeign(element);
}

class SuperMemberData {
  /// A set of member that are called from subclasses via `super`.
  final Set<MemberEntity> _aliasedSuperMembers = new Setlet<MemberEntity>();

  /// Record that [member] is called from a subclass via `super`.
  bool maybeRegisterAliasedSuperMember(MemberEntity member, Selector selector) {
    if (!canUseAliasedSuperMember(member, selector)) {
      // Invoking a super getter isn't supported, this would require changes to
      // compact field descriptors in the emitter.
      return false;
    }
    _aliasedSuperMembers.add(member);
    return true;
  }

  bool canUseAliasedSuperMember(MemberEntity member, Selector selector) {
    return !selector.isGetter;
  }

  /// Returns `true` if [member] is called from a subclass via `super`.
  bool isAliasedSuperMember(MemberEntity member) {
    return _aliasedSuperMembers.contains(member);
  }
}
