// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.kernel.element_map;

import 'package:kernel/ast.dart' as ir;

import '../common.dart';
import '../common/resolution.dart';
import '../compile_time_constants.dart';
import '../constants/constant_system.dart';
import '../constants/constructors.dart';
import '../constants/evaluation.dart';
import '../constants/expressions.dart';
import '../constants/values.dart';
import '../common_elements.dart';
import '../elements/elements.dart';
import '../elements/entities.dart';
import '../elements/types.dart';
import '../frontend_strategy.dart';
import '../js_backend/constant_system_javascript.dart';
import '../js_backend/native_data.dart';
import '../js_backend/no_such_method_registry.dart';
import '../native/native.dart' as native;
import '../native/resolver.dart';
import '../ordered_typeset.dart';
import '../ssa/kernel_impact.dart';
import '../universe/call_structure.dart';
import '../universe/world_builder.dart';
import '../util/util.dart' show Link, LinkBuilder;
import 'element_adapter.dart';
import 'elements.dart';

part 'native_basic_data.dart';
part 'no_such_method_resolver.dart';
part 'types.dart';

/// Element builder used for creating elements and types corresponding to Kernel
/// IR nodes.
class KernelToElementMap extends KernelElementAdapterMixin {
  CommonElements _commonElements;
  native.BehaviorBuilder _nativeBehaviorBuilder;
  final DiagnosticReporter reporter;
  ElementEnvironment _elementEnvironment;
  DartTypeConverter _typeConverter;
  KernelConstantEnvironment _constantEnvironment;
  _KernelDartTypes _types;

  /// Library environment. Used for fast lookup.
  _KEnv _env = new _KEnv();

  /// List of library environments by `KLibrary.libraryIndex`. This is used for
  /// fast lookup into library classes and members.
  List<_KLibraryEnv> _libraryEnvs = <_KLibraryEnv>[];

  /// List of class environments by `KClass.classIndex`. This is used for
  /// fast lookup into class members.
  List<_KClassEnv> _classEnvs = <_KClassEnv>[];

  Map<ir.Library, KLibrary> _libraryMap = <ir.Library, KLibrary>{};
  Map<ir.Class, KClass> _classMap = <ir.Class, KClass>{};
  Map<ir.TypeParameter, KTypeVariable> _typeVariableMap =
      <ir.TypeParameter, KTypeVariable>{};

  List<_MemberData> _memberList = <_MemberData>[];

  Map<ir.Member, KConstructor> _constructorMap = <ir.Member, KConstructor>{};
  Map<ir.Procedure, KFunction> _methodMap = <ir.Procedure, KFunction>{};
  Map<ir.Field, KField> _fieldMap = <ir.Field, KField>{};

  Map<ir.TreeNode, KLocalFunction> _localFunctionMap =
      <ir.TreeNode, KLocalFunction>{};

  KernelToElementMap(this.reporter) {
    _elementEnvironment = new KernelElementEnvironment(this);
    _commonElements = new CommonElements(_elementEnvironment);
    _constantEnvironment = new KernelConstantEnvironment(this);
    _nativeBehaviorBuilder =
        new KernelBehaviorBuilder(_commonElements, _constantEnvironment);
    _types = new _KernelDartTypes(this);
    _typeConverter = new DartTypeConverter(this);
  }

  /// Adds libraries in [program] to the set of libraries.
  ///
  /// The main method of the first program is used as the main method for the
  /// compilation.
  void addProgram(ir.Program program) {
    _env.addProgram(program);
  }

  KMethod get _mainFunction {
    return _env.mainMethod != null ? _getMethod(_env.mainMethod) : null;
  }

  KLibrary get _mainLibrary {
    return _env.mainMethod != null
        ? _getLibrary(_env.mainMethod.enclosingLibrary)
        : null;
  }

  Iterable<LibraryEntity> get _libraries {
    if (_env.length != _libraryMap.length) {
      // Create a [KLibrary] for each library.
      _env.forEachLibrary((_KLibraryEnv env) {
        _getLibrary(env.library, env);
      });
    }
    return _libraryMap.values;
  }

  @override
  CommonElements get commonElements => _commonElements;

  @override
  ElementEnvironment get elementEnvironment => _elementEnvironment;

  ConstantEnvironment get constantEnvironment => _constantEnvironment;

  DartTypes get types => _types;

  @override
  native.BehaviorBuilder get nativeBehaviorBuilder => _nativeBehaviorBuilder;

  LibraryEntity lookupLibrary(Uri uri) {
    _KLibraryEnv libraryEnv = _env.lookupLibrary(uri);
    return _getLibrary(libraryEnv.library, libraryEnv);
  }

  KLibrary _getLibrary(ir.Library node, [_KLibraryEnv libraryEnv]) {
    return _libraryMap.putIfAbsent(node, () {
      Uri canonicalUri = node.importUri;
      _libraryEnvs.add(libraryEnv ?? _env.lookupLibrary(canonicalUri));
      String name = node.name;
      if (name == null) {
        // Use the file name as script name.
        String path = canonicalUri.path;
        name = path.substring(path.lastIndexOf('/') + 1);
      }
      return new KLibrary(_libraryMap.length, name, canonicalUri);
    });
  }

  MemberEntity lookupLibraryMember(KLibrary library, String name,
      {bool setter: false}) {
    _KLibraryEnv libraryEnv = _libraryEnvs[library.libraryIndex];
    ir.Member member = libraryEnv.lookupMember(name, setter: setter);
    return member != null ? getMember(member) : null;
  }

  ClassEntity lookupClass(KLibrary library, String name) {
    _KLibraryEnv libraryEnv = _libraryEnvs[library.libraryIndex];
    _KClassEnv classEnv = libraryEnv.lookupClass(name);
    if (classEnv != null) {
      return _getClass(classEnv.cls, classEnv);
    }
    return null;
  }

  void _forEachClass(KLibrary library, void f(ClassEntity cls)) {
    _KLibraryEnv libraryEnv = _libraryEnvs[library.libraryIndex];
    libraryEnv.forEachClass((_KClassEnv classEnv) {
      f(_getClass(classEnv.cls, classEnv));
    });
  }

  MemberEntity lookupClassMember(KClass cls, String name,
      {bool setter: false}) {
    _KClassEnv classEnv = _classEnvs[cls.classIndex];
    ir.Member member = classEnv.lookupMember(name, setter: setter);
    return member != null ? getMember(member) : null;
  }

  ConstructorEntity lookupConstructor(KClass cls, String name) {
    _KClassEnv classEnv = _classEnvs[cls.classIndex];
    ir.Member member = classEnv.lookupConstructor(name);
    return member != null ? getConstructor(member) : null;
  }

  KClass _getClass(ir.Class node, [_KClassEnv classEnv]) {
    return _classMap.putIfAbsent(node, () {
      KLibrary library = _getLibrary(node.enclosingLibrary);
      if (classEnv == null) {
        classEnv = _libraryEnvs[library.libraryIndex].lookupClass(node.name);
      }
      _classEnvs.add(classEnv);
      return new KClass(library, _classMap.length, node.name,
          isAbstract: node.isAbstract);
    });
  }

  Iterable<ConstantExpression> _getClassMetadata(KClass cls) {
    return _classEnvs[cls.classIndex].getMetadata(this);
  }

  KTypeVariable _getTypeVariable(ir.TypeParameter node) {
    return _typeVariableMap.putIfAbsent(node, () {
      if (node.parent is ir.Class) {
        ir.Class cls = node.parent;
        int index = cls.typeParameters.indexOf(node);
        return new KTypeVariable(_getClass(cls), node.name, index);
      }
      if (node.parent is ir.FunctionNode) {
        ir.FunctionNode func = node.parent;
        int index = func.typeParameters.indexOf(node);
        if (func.parent is ir.Constructor) {
          ir.Constructor constructor = func.parent;
          ir.Class cls = constructor.enclosingClass;
          return _getTypeVariable(cls.typeParameters[index]);
        }
        if (func.parent is ir.Procedure) {
          ir.Procedure procedure = func.parent;
          if (procedure.kind == ir.ProcedureKind.Factory) {
            ir.Class cls = procedure.enclosingClass;
            return _getTypeVariable(cls.typeParameters[index]);
          } else {
            return new KTypeVariable(_getMethod(procedure), node.name, index);
          }
        }
      }
      throw new UnsupportedError('Unsupported type parameter type node $node.');
    });
  }

  ParameterStructure _getParameterStructure(ir.FunctionNode node) {
    // TODO(johnniwinther): Cache the computed function type.
    int requiredParameters = node.requiredParameterCount;
    int positionalParameters = node.positionalParameters.length;
    List<String> namedParameters =
        node.namedParameters.map((p) => p.name).toList()..sort();
    return new ParameterStructure(
        requiredParameters, positionalParameters, namedParameters);
  }

  KConstructor _getConstructor(ir.Member node) {
    return _constructorMap.putIfAbsent(node, () {
      int memberIndex = _memberList.length;
      KConstructor constructor;
      KClass enclosingClass = _getClass(node.enclosingClass);
      Name name = getName(node.name);
      bool isExternal = node.isExternal;

      ir.FunctionNode functionNode;
      if (node is ir.Constructor) {
        functionNode = node.function;
        constructor = new KGenerativeConstructor(memberIndex, enclosingClass,
            name, _getParameterStructure(functionNode),
            isExternal: isExternal, isConst: node.isConst);
      } else if (node is ir.Procedure) {
        functionNode = node.function;
        constructor = new KFactoryConstructor(memberIndex, enclosingClass, name,
            _getParameterStructure(functionNode),
            isExternal: isExternal, isConst: node.isConst);
      } else {
        // TODO(johnniwinther): Convert `node.location` to a [SourceSpan].
        throw new SpannableAssertionFailure(
            NO_LOCATION_SPANNABLE, "Unexpected constructor node: ${node}.");
      }
      _memberList.add(new _ConstructorData(node, functionNode));
      return constructor;
    });
  }

  KFunction _getMethod(ir.Procedure node) {
    return _methodMap.putIfAbsent(node, () {
      int memberIndex = _memberList.length;
      KLibrary library;
      KClass enclosingClass;
      if (node.enclosingClass != null) {
        enclosingClass = _getClass(node.enclosingClass);
        library = enclosingClass.library;
      } else {
        library = _getLibrary(node.enclosingLibrary);
      }
      Name name = getName(node.name);
      bool isStatic = node.isStatic;
      bool isExternal = node.isExternal;
      bool isAbstract = node.isAbstract;
      KFunction function;
      switch (node.kind) {
        case ir.ProcedureKind.Factory:
          throw new UnsupportedError("Cannot create method from factory.");
        case ir.ProcedureKind.Getter:
          function = new KGetter(memberIndex, library, enclosingClass, name,
              isStatic: isStatic,
              isExternal: isExternal,
              isAbstract: isAbstract);
          break;
        case ir.ProcedureKind.Method:
        case ir.ProcedureKind.Operator:
          function = new KMethod(memberIndex, library, enclosingClass, name,
              _getParameterStructure(node.function),
              isStatic: isStatic,
              isExternal: isExternal,
              isAbstract: isAbstract);
          break;
        case ir.ProcedureKind.Setter:
          function = new KSetter(
              memberIndex, library, enclosingClass, getName(node.name).setter,
              isStatic: isStatic,
              isExternal: isExternal,
              isAbstract: isAbstract);
          break;
      }
      _memberList.add(new _FunctionData(node, node.function));
      return function;
    });
  }

  KField _getField(ir.Field node) {
    return _fieldMap.putIfAbsent(node, () {
      int memberIndex = _memberList.length;
      KLibrary library;
      KClass enclosingClass;
      if (node.enclosingClass != null) {
        enclosingClass = _getClass(node.enclosingClass);
        library = enclosingClass.library;
      } else {
        library = _getLibrary(node.enclosingLibrary);
      }
      Name name = getName(node.name);
      bool isStatic = node.isStatic;
      _memberList.add(new _FieldData(node));
      return new KField(memberIndex, library, enclosingClass, name,
          isStatic: isStatic,
          isAssignable: node.isMutable,
          isConst: node.isConst);
    });
  }

  KLocalFunction _getLocal(ir.TreeNode node) {
    return _localFunctionMap.putIfAbsent(node, () {
      MemberEntity memberContext;
      Entity executableContext;
      ir.TreeNode parent = node.parent;
      while (parent != null) {
        if (parent is ir.Member) {
          executableContext = memberContext = getMember(parent);
          break;
        }
        if (parent is ir.FunctionDeclaration ||
            parent is ir.FunctionExpression) {
          KLocalFunction localFunction = _getLocal(parent);
          executableContext = localFunction;
          memberContext = localFunction.memberContext;
          break;
        }
        parent = parent.parent;
      }
      String name;
      FunctionType functionType;
      if (node is ir.FunctionDeclaration) {
        name = node.variable.name;
        functionType = getFunctionType(node.function);
      } else if (node is ir.FunctionExpression) {
        functionType = getFunctionType(node.function);
      }
      return new KLocalFunction(
          name, memberContext, executableContext, functionType);
    });
  }

  @override
  DartType getDartType(ir.DartType type) => _typeConverter.convert(type);

  @override
  InterfaceType createInterfaceType(
      ir.Class cls, List<ir.DartType> typeArguments) {
    return new InterfaceType(getClass(cls), getDartTypes(typeArguments));
  }

  @override
  InterfaceType getInterfaceType(ir.InterfaceType type) =>
      _typeConverter.convert(type);

  @override
  List<DartType> getDartTypes(List<ir.DartType> types) {
    // TODO(johnniwinther): Add the type argument to the list literal when we
    // no longer use resolution types.
    List<DartType> list = /*<DartType>*/ [];
    types.forEach((ir.DartType type) {
      list.add(getDartType(type));
    });
    return list;
  }

  void _ensureThisAndRawType(KClass cls, _KClassEnv env) {
    if (env.thisType == null) {
      ir.Class node = env.cls;
      // TODO(johnniwinther): Add the type argument to the list literal when we
      // no longer use resolution types.
      if (node.typeParameters.isEmpty) {
        env.thisType =
            env.rawType = new InterfaceType(cls, const/*<DartType>*/ []);
      } else {
        env.thisType = new InterfaceType(
            cls,
            new List/*<DartType>*/ .generate(node.typeParameters.length,
                (int index) {
              return new TypeVariableType(
                  _getTypeVariable(node.typeParameters[index]));
            }));
        env.rawType = new InterfaceType(
            cls,
            new List/*<DartType>*/ .filled(
                node.typeParameters.length, const DynamicType()));
      }
    }
  }

  InterfaceType _getThisType(KClass cls) {
    _KClassEnv env = _classEnvs[cls.classIndex];
    _ensureThisAndRawType(cls, env);
    return env.thisType;
  }

  InterfaceType _getRawType(KClass cls) {
    _KClassEnv env = _classEnvs[cls.classIndex];
    _ensureThisAndRawType(cls, env);
    return env.rawType;
  }

  void _ensureSupertypes(KClass cls, _KClassEnv env) {
    if (env.orderedTypeSet == null) {
      _ensureThisAndRawType(cls, env);

      ir.Class node = env.cls;

      if (node.supertype == null) {
        env.orderedTypeSet = new OrderedTypeSet.singleton(env.thisType);
      } else {
        InterfaceType processSupertype(ir.Supertype node) {
          InterfaceType type = _typeConverter.visitSupertype(node);
          KClass superclass = type.element;
          _KClassEnv env = _classEnvs[superclass.classIndex];
          _ensureSupertypes(superclass, env);
          return type;
        }

        env.supertype = processSupertype(node.supertype);
        LinkBuilder<InterfaceType> linkBuilder =
            new LinkBuilder<InterfaceType>();
        if (node.mixedInType != null) {
          linkBuilder
              .addLast(env.mixedInType = processSupertype(node.mixedInType));
        }
        node.implementedTypes.forEach((ir.Supertype supertype) {
          linkBuilder.addLast(processSupertype(supertype));
        });
        Link<InterfaceType> interfaces = linkBuilder.toLink();
        OrderedTypeSetBuilder setBuilder =
            new _KernelOrderedTypeSetBuilder(this, cls);
        env.orderedTypeSet =
            setBuilder.createOrderedTypeSet(env.supertype, interfaces);
      }
    }
  }

  OrderedTypeSet _getOrderedTypeSet(KClass cls) {
    _KClassEnv env = _classEnvs[cls.classIndex];
    _ensureSupertypes(cls, env);
    return env.orderedTypeSet;
  }

  int _getHierarchyDepth(KClass cls) {
    _KClassEnv env = _classEnvs[cls.classIndex];
    _ensureSupertypes(cls, env);
    return env.orderedTypeSet.maxDepth;
  }

  InterfaceType _substByContext(InterfaceType type, InterfaceType context) {
    return type.subst(
        context.typeArguments, _getThisType(context.element).typeArguments);
  }

  InterfaceType _getSuperType(KClass cls) {
    _KClassEnv env = _classEnvs[cls.classIndex];
    _ensureSupertypes(cls, env);
    return env.supertype;
  }

  void _forEachSupertype(KClass cls, void f(InterfaceType supertype)) {
    _KClassEnv env = _classEnvs[cls.classIndex];
    _ensureSupertypes(cls, env);
    env.orderedTypeSet.supertypes.forEach(f);
  }

  void _forEachMixin(KClass cls, void f(ClassEntity mixin)) {
    while (cls != null) {
      _KClassEnv env = _classEnvs[cls.classIndex];
      _ensureSupertypes(cls, env);
      if (env.mixedInType != null) {
        f(env.mixedInType.element);
      }
      cls = env.supertype?.element;
    }
  }

  void _forEachClassMember(
      KClass cls, void f(ClassEntity cls, MemberEntity member)) {
    _KClassEnv env = _classEnvs[cls.classIndex];
    env.forEachMember((ir.Member member) {
      f(cls, getMember(member));
    });
    _ensureSupertypes(cls, env);
    if (env.supertype != null) {
      _forEachClassMember(env.supertype.element, f);
    }
  }

  @override
  FunctionType getFunctionType(ir.FunctionNode node) {
    DartType returnType = getDartType(node.returnType);
    List<DartType> parameterTypes = /*<DartType>*/ [];
    List<DartType> optionalParameterTypes = /*<DartType>*/ [];
    for (ir.VariableDeclaration variable in node.positionalParameters) {
      if (parameterTypes.length == node.requiredParameterCount) {
        optionalParameterTypes.add(getDartType(variable.type));
      } else {
        parameterTypes.add(getDartType(variable.type));
      }
    }
    List<String> namedParameters = <String>[];
    List<DartType> namedParameterTypes = /*<DartType>*/ [];
    List<ir.VariableDeclaration> sortedNamedParameters =
        node.namedParameters.toList()..sort((a, b) => a.name.compareTo(b.name));
    for (ir.VariableDeclaration variable in sortedNamedParameters) {
      namedParameters.add(variable.name);
      namedParameterTypes.add(getDartType(variable.type));
    }
    return new FunctionType(returnType, parameterTypes, optionalParameterTypes,
        namedParameters, namedParameterTypes);
  }

  LibraryEntity getLibrary(ir.Library node) => _getLibrary(node);

  ir.Library getKernelLibrary(KLibrary entity) =>
      _libraryEnvs[entity.libraryIndex].library;

  ir.Class getKernelClass(KClass entity) => _classEnvs[entity.classIndex].cls;

  @override
  Local getLocalFunction(ir.TreeNode node) => _getLocal(node);

  @override
  ClassEntity getClass(ir.Class node) => _getClass(node);

  @override
  FieldEntity getField(ir.Field node) => _getField(node);

  TypeVariableEntity getTypeVariable(ir.TypeParameter node) =>
      _getTypeVariable(node);

  @override
  FunctionEntity getMethod(ir.Procedure node) => _getMethod(node);

  @override
  MemberEntity getMember(ir.Member node) {
    if (node is ir.Field) {
      return _getField(node);
    } else if (node is ir.Constructor) {
      return _getConstructor(node);
    } else if (node is ir.Procedure) {
      if (node.kind == ir.ProcedureKind.Factory) {
        return _getConstructor(node);
      } else {
        return _getMethod(node);
      }
    }
    throw new UnsupportedError("Unexpected member: $node");
  }

  @override
  FunctionEntity getConstructor(ir.Member node) => _getConstructor(node);

  ConstantConstructor _getConstructorConstant(KConstructor constructor) {
    _ConstructorData data = _memberList[constructor.memberIndex];
    return data.getConstructorConstant(this, constructor);
  }

  ConstantExpression _getFieldConstant(KField field) {
    _FieldData data = _memberList[field.memberIndex];
    return data.getFieldConstant(this, field);
  }

  FunctionType _getFunctionType(KFunction function) {
    _FunctionData data = _memberList[function.memberIndex];
    return data.getFunctionType(this);
  }

  ResolutionImpact computeWorldImpact(KMember member) {
    return _memberList[member.memberIndex].getWorldImpact(this);
  }
}

/// Environment for fast lookup of program libraries.
class _KEnv {
  final Set<ir.Program> programs = new Set<ir.Program>();

  Map<Uri, _KLibraryEnv> _libraryMap;

  /// TODO(johnniwinther): Handle arbitrary load order if needed.
  ir.Member get mainMethod => programs.first?.mainMethod;

  void addProgram(ir.Program program) {
    if (programs.add(program)) {
      if (_libraryMap != null) {
        _addLibraries(program);
      }
    }
  }

  void _addLibraries(ir.Program program) {
    for (ir.Library library in program.libraries) {
      _libraryMap[library.importUri] = new _KLibraryEnv(library);
    }
  }

  void _ensureLibraryMap() {
    if (_libraryMap == null) {
      _libraryMap = <Uri, _KLibraryEnv>{};
      for (ir.Program program in programs) {
        _addLibraries(program);
      }
    }
  }

  /// Return the [_KLibraryEnv] for the library with the canonical [uri].
  _KLibraryEnv lookupLibrary(Uri uri) {
    _ensureLibraryMap();
    return _libraryMap[uri];
  }

  /// Calls [f] for each library in this environment.
  void forEachLibrary(void f(_KLibraryEnv library)) {
    _ensureLibraryMap();
    _libraryMap.values.forEach(f);
  }

  /// Returns the number of libraries in this environment.
  int get length {
    _ensureLibraryMap();
    return _libraryMap.length;
  }
}

/// Environment for fast lookup of library classes and members.
class _KLibraryEnv {
  final ir.Library library;

  Map<String, _KClassEnv> _classMap;
  Map<String, ir.Member> _memberMap;
  Map<String, ir.Member> _setterMap;

  _KLibraryEnv(this.library);

  void _ensureClassMap() {
    if (_classMap == null) {
      _classMap = <String, _KClassEnv>{};
      for (ir.Class cls in library.classes) {
        _classMap[cls.name] = new _KClassEnv(cls);
      }
    }
  }

  /// Return the [_KClassEnv] for the class [name] in [library].
  _KClassEnv lookupClass(String name) {
    _ensureClassMap();
    return _classMap[name];
  }

  /// Calls [f] for each class in this library.
  void forEachClass(void f(_KClassEnv cls)) {
    _ensureClassMap();
    _classMap.values.forEach(f);
  }

  /// Return the [ir.Member] for the member [name] in [library].
  ir.Member lookupMember(String name, {bool setter: false}) {
    if (_memberMap == null) {
      _memberMap = <String, ir.Member>{};
      _setterMap = <String, ir.Member>{};
      for (ir.Member member in library.members) {
        if (member is ir.Procedure) {
          if (member.kind == ir.ProcedureKind.Setter) {
            _setterMap[member.name.name] = member;
          } else {
            _memberMap[member.name.name] = member;
          }
        } else if (member is ir.Field) {
          _memberMap[member.name.name] = member;
          if (member.isMutable) {
            _setterMap[member.name.name] = member;
          }
        } else {
          throw new SpannableAssertionFailure(
              NO_LOCATION_SPANNABLE, "Unexpected library member node: $member");
        }
      }
    }
    return _memberMap[name];
  }
}

/// Environment for fast lookup of class members.
class _KClassEnv {
  final ir.Class cls;

  InterfaceType thisType;
  InterfaceType rawType;
  InterfaceType supertype;
  InterfaceType mixedInType;
  OrderedTypeSet orderedTypeSet;

  Map<String, ir.Member> _constructorMap;
  Map<String, ir.Member> _memberMap;
  Map<String, ir.Member> _setterMap;

  Iterable<ConstantExpression> _metadata;

  _KClassEnv(this.cls);

  void _ensureMaps() {
    if (_memberMap == null) {
      _memberMap = <String, ir.Member>{};
      _setterMap = <String, ir.Member>{};
      _constructorMap = <String, ir.Member>{};
      for (ir.Member member in cls.members) {
        if (member is ir.Constructor ||
            member is ir.Procedure && member.kind == ir.ProcedureKind.Factory) {
          _constructorMap[member.name.name] = member;
        } else if (member is ir.Procedure) {
          if (member.kind == ir.ProcedureKind.Setter) {
            _setterMap[member.name.name] = member;
          } else {
            _memberMap[member.name.name] = member;
          }
        } else if (member is ir.Field) {
          _memberMap[member.name.name] = member;
          if (member.isMutable) {
            _setterMap[member.name.name] = member;
          }
          _memberMap[member.name.name] = member;
        } else {
          throw new SpannableAssertionFailure(
              NO_LOCATION_SPANNABLE, "Unexpected class member node: $member");
        }
      }
    }
  }

  /// Return the [ir.Member] for the member [name] in [library].
  ir.Member lookupMember(String name, {bool setter: false}) {
    _ensureMaps();
    return setter ? _setterMap[name] : _memberMap[name];
  }

  /// Return the [ir.Member] for the member [name] in [library].
  ir.Member lookupConstructor(String name) {
    _ensureMaps();
    return _constructorMap[name];
  }

  void forEachMember(f(ir.Member member)) {
    _ensureMaps();
    _memberMap.values.forEach(f);
  }

  Iterable<ConstantExpression> getMetadata(KernelToElementMap worldBuilder) {
    if (_metadata == null) {
      _metadata = worldBuilder.getMetadata(cls.annotations);
    }
    return _metadata;
  }
}

class _MemberData {
  final ir.Member node;

  _MemberData(this.node);

  ResolutionImpact getWorldImpact(KernelToElementMap elementMap) {
    return buildKernelImpact(node, elementMap);
  }
}

class _FunctionData extends _MemberData {
  final ir.FunctionNode functionNode;
  FunctionType _type;
  CallStructure _callStructure;

  _FunctionData(ir.Member node, this.functionNode) : super(node);

  FunctionType getFunctionType(KernelToElementMap elementMap) {
    return _type ??= elementMap.getFunctionType(functionNode);
  }

  CallStructure get callStructure {
    return _callStructure ??= new CallStructure(
        functionNode.positionalParameters.length +
            functionNode.namedParameters.length,
        functionNode.namedParameters.map((d) => d.name).toList());
  }
}

class _ConstructorData extends _FunctionData {
  ConstantConstructor _constantConstructor;

  _ConstructorData(ir.Member node, ir.FunctionNode functionNode)
      : super(node, functionNode);

  ConstantConstructor getConstructorConstant(
      KernelToElementMap elementMap, KConstructor constructor) {
    if (_constantConstructor == null) {
      if (node is ir.Constructor && constructor.isConst) {
        _constantConstructor =
            new Constantifier(elementMap).computeConstantConstructor(node);
      } else {
        throw new SpannableAssertionFailure(
            constructor,
            "Unexpected constructor $constructor in "
            "KernelWorldBuilder._getConstructorConstant");
      }
    }
    return _constantConstructor;
  }
}

class _FieldData extends _MemberData {
  ConstantExpression _constant;

  _FieldData(ir.Field node) : super(node);

  ir.Field get node => super.node;

  ConstantExpression getFieldConstant(
      KernelToElementMap elementMap, KField field) {
    if (_constant == null) {
      if (node.isConst) {
        _constant = new Constantifier(elementMap).visit(node.initializer);
      } else {
        throw new SpannableAssertionFailure(
            field,
            "Unexpected field $field in "
            "KernelWorldBuilder._getConstructorConstant");
      }
    }
    return _constant;
  }
}

class KernelElementEnvironment implements ElementEnvironment {
  final KernelToElementMap elementMap;

  KernelElementEnvironment(this.elementMap);

  @override
  DartType get dynamicType => const DynamicType();

  @override
  LibraryEntity get mainLibrary => elementMap._mainLibrary;

  @override
  FunctionEntity get mainFunction => elementMap._mainFunction;

  @override
  Iterable<LibraryEntity> get libraries => elementMap._libraries;

  @override
  InterfaceType getThisType(ClassEntity cls) {
    return elementMap._getThisType(cls);
  }

  @override
  InterfaceType getRawType(ClassEntity cls) {
    return elementMap._getRawType(cls);
  }

  @override
  DartType getTypeVariableBound(TypeVariableEntity typeVariable) {
    throw new UnimplementedError(
        'KernelElementEnvironment.getTypeVariableBound');
  }

  @override
  InterfaceType createInterfaceType(
      ClassEntity cls, List<DartType> typeArguments) {
    return new InterfaceType(cls, typeArguments);
  }

  @override
  bool isSubtype(DartType a, DartType b) {
    return elementMap.types.isSubtype(a, b);
  }

  @override
  FunctionType getFunctionType(KFunction function) {
    return elementMap._getFunctionType(function);
  }

  @override
  FunctionType getLocalFunctionType(KLocalFunction function) {
    return function.functionType;
  }

  @override
  DartType getUnaliasedType(DartType type) => type;

  @override
  ConstructorEntity lookupConstructor(ClassEntity cls, String name,
      {bool required: false}) {
    ConstructorEntity constructor = elementMap.lookupConstructor(cls, name);
    if (constructor == null && required) {
      throw new SpannableAssertionFailure(
          CURRENT_ELEMENT_SPANNABLE,
          "The constructor '$name' was not found in class '${cls.name}' "
          "in library ${cls.library.canonicalUri}.");
    }
    return constructor;
  }

  @override
  MemberEntity lookupClassMember(ClassEntity cls, String name,
      {bool setter: false, bool required: false}) {
    MemberEntity member =
        elementMap.lookupClassMember(cls, name, setter: setter);
    if (member == null && required) {
      throw new SpannableAssertionFailure(CURRENT_ELEMENT_SPANNABLE,
          "The member '$name' was not found in ${cls.name}.");
    }
    return member;
  }

  @override
  ClassEntity getSuperClass(ClassEntity cls) {
    return elementMap._getSuperType(cls)?.element;
  }

  @override
  void forEachSupertype(ClassEntity cls, void f(InterfaceType supertype)) {
    elementMap._forEachSupertype(cls, f);
  }

  @override
  void forEachMixin(ClassEntity cls, void f(ClassEntity mixin)) {
    elementMap._forEachMixin(cls, f);
  }

  @override
  void forEachClassMember(
      ClassEntity cls, void f(ClassEntity declarer, MemberEntity member)) {
    elementMap._forEachClassMember(cls, f);
  }

  @override
  MemberEntity lookupLibraryMember(LibraryEntity library, String name,
      {bool setter: false, bool required: false}) {
    MemberEntity member =
        elementMap.lookupLibraryMember(library, name, setter: setter);
    if (member == null && required) {
      throw new SpannableAssertionFailure(CURRENT_ELEMENT_SPANNABLE,
          "The member '${name}' was not found in library '${library.name}'.");
    }
    return member;
  }

  @override
  ClassEntity lookupClass(LibraryEntity library, String name,
      {bool required: false}) {
    ClassEntity cls = elementMap.lookupClass(library, name);
    if (cls == null && required) {
      throw new SpannableAssertionFailure(CURRENT_ELEMENT_SPANNABLE,
          "The class '$name'  was not found in library '${library.name}'.");
    }
    return cls;
  }

  @override
  void forEachClass(KLibrary library, void f(ClassEntity cls)) {
    elementMap._forEachClass(library, f);
  }

  @override
  LibraryEntity lookupLibrary(Uri uri, {bool required: false}) {
    LibraryEntity library = elementMap.lookupLibrary(uri);
    if (library == null && required) {
      throw new SpannableAssertionFailure(
          CURRENT_ELEMENT_SPANNABLE, "The library '$uri' was not found.");
    }
    return library;
  }

  @override
  CallStructure getCallStructure(KFunction function) {
    _FunctionData data = elementMap._memberList[function.memberIndex];
    return data.callStructure;
  }

  @override
  bool isDeferredLoadLibraryGetter(KMember member) {
    // TODO(johnniwinther): Support these.
    return false;
  }
}

/// Visitor that converts kernel dart types into [DartType].
class DartTypeConverter extends ir.DartTypeVisitor<DartType> {
  final KernelToElementMap elementAdapter;
  bool topLevel = true;

  DartTypeConverter(this.elementAdapter);

  DartType convert(ir.DartType type) {
    topLevel = true;
    return type.accept(this);
  }

  /// Visit a inner type.
  DartType visitType(ir.DartType type) {
    topLevel = false;
    return type.accept(this);
  }

  InterfaceType visitSupertype(ir.Supertype node) {
    ClassEntity cls = elementAdapter.getClass(node.classNode);
    return new InterfaceType(cls, visitTypes(node.typeArguments));
  }

  List<DartType> visitTypes(List<ir.DartType> types) {
    topLevel = false;
    return new List.generate(
        types.length, (int index) => types[index].accept(this));
  }

  @override
  DartType visitTypeParameterType(ir.TypeParameterType node) {
    return new TypeVariableType(elementAdapter.getTypeVariable(node.parameter));
  }

  @override
  DartType visitFunctionType(ir.FunctionType node) {
    return new FunctionType(
        visitType(node.returnType),
        visitTypes(node.positionalParameters
            .take(node.requiredParameterCount)
            .toList()),
        visitTypes(node.positionalParameters
            .skip(node.requiredParameterCount)
            .toList()),
        node.namedParameters.map((n) => n.name).toList(),
        node.namedParameters.map((n) => visitType(n.type)).toList());
  }

  @override
  DartType visitInterfaceType(ir.InterfaceType node) {
    ClassEntity cls = elementAdapter.getClass(node.classNode);
    return new InterfaceType(cls, visitTypes(node.typeArguments));
  }

  @override
  DartType visitVoidType(ir.VoidType node) {
    return const VoidType();
  }

  @override
  DartType visitDynamicType(ir.DynamicType node) {
    return const DynamicType();
  }

  @override
  DartType visitInvalidType(ir.InvalidType node) {
    if (topLevel) {
      throw new UnimplementedError(
          "Outermost invalid types not currently supported");
    }
    // Nested invalid types are treated as `dynamic`.
    return const DynamicType();
  }
}

/// [native.BehaviorBuilder] for kernel based elements.
class KernelBehaviorBuilder extends native.BehaviorBuilder {
  final CommonElements commonElements;
  final ConstantEnvironment constants;

  KernelBehaviorBuilder(
    this.commonElements,
    this.constants,
  );

  @override
  bool get trustJSInteropTypeAnnotations {
    throw new UnimplementedError(
        "KernelNativeBehaviorComputer.trustJSInteropTypeAnnotations");
  }

  @override
  DiagnosticReporter get reporter {
    throw new UnimplementedError("KernelNativeBehaviorComputer.reporter");
  }

  @override
  NativeData get nativeData {
    throw new UnimplementedError("KernelNativeBehaviorComputer.nativeData");
  }
}

/// Constant environment mapping [ConstantExpression]s to [ConstantValue]s using
/// [_EvaluationEnvironment] for the evaluation.
class KernelConstantEnvironment implements ConstantEnvironment {
  KernelToElementMap _worldBuilder;
  Map<ConstantExpression, ConstantValue> _valueMap =
      <ConstantExpression, ConstantValue>{};

  KernelConstantEnvironment(this._worldBuilder);

  @override
  ConstantSystem get constantSystem => const JavaScriptConstantSystem();

  @override
  ConstantValue getConstantValueForVariable(VariableElement element) {
    throw new UnimplementedError(
        "KernelConstantEnvironment.getConstantValueForVariable");
  }

  @override
  ConstantValue getConstantValue(ConstantExpression expression) {
    return _valueMap.putIfAbsent(expression, () {
      return expression.evaluate(
          new _EvaluationEnvironment(_worldBuilder), constantSystem);
    });
  }

  @override
  bool hasConstantValue(ConstantExpression expression) {
    throw new UnimplementedError("KernelConstantEnvironment.hasConstantValue");
  }
}

/// Evaluation environment used for computing [ConstantValue]s for
/// kernel based [ConstantExpression]s.
class _EvaluationEnvironment implements Environment {
  final KernelToElementMap _worldBuilder;

  _EvaluationEnvironment(this._worldBuilder);

  @override
  CommonElements get commonElements {
    throw new UnimplementedError("_EvaluationEnvironment.commonElements");
  }

  @override
  InterfaceType substByContext(InterfaceType base, InterfaceType target) {
    if (base.typeArguments.isNotEmpty) {
      throw new UnimplementedError("_EvaluationEnvironment.substByContext");
    }
    return base;
  }

  @override
  ConstantConstructor getConstructorConstant(ConstructorEntity constructor) {
    return _worldBuilder._getConstructorConstant(constructor);
  }

  @override
  ConstantExpression getFieldConstant(FieldEntity field) {
    return _worldBuilder._getFieldConstant(field);
  }

  @override
  ConstantExpression getLocalConstant(Local local) {
    throw new UnimplementedError("_EvaluationEnvironment.getLocalConstant");
  }

  @override
  String readFromEnvironment(String name) {
    throw new UnimplementedError("_EvaluationEnvironment.readFromEnvironment");
  }
}

class KernelResolutionWorldBuilder extends KernelResolutionWorldBuilderBase {
  final KernelToElementMap elementMap;

  KernelResolutionWorldBuilder(this.elementMap, NativeBasicData nativeBasicData,
      SelectorConstraintsStrategy selectorConstraintsStrategy)
      : super(elementMap.elementEnvironment, elementMap.commonElements,
            nativeBasicData, selectorConstraintsStrategy);

  @override
  Iterable<InterfaceType> getSupertypes(ClassEntity cls) {
    return elementMap._getOrderedTypeSet(cls).supertypes;
  }

  @override
  ClassEntity getSuperClass(ClassEntity cls) {
    return elementMap._getSuperType(cls)?.element;
  }

  @override
  bool implementsFunction(ClassEntity cls) {
    // TODO(johnniwinther): Implement this.
    return false;
  }

  @override
  int getHierarchyDepth(ClassEntity cls) {
    return elementMap._getHierarchyDepth(cls);
  }

  @override
  ClassEntity getAppliedMixin(ClassEntity cls) {
    // TODO(johnniwinther): Implement this.
    return null;
  }

  @override
  bool validateClass(ClassEntity cls) => true;

  @override
  bool checkClass(ClassEntity cls) => true;
}

// Interface for testing equivalence of Kernel-based entities.
class WorldDeconstructionForTesting {
  final KernelToElementMap builder;

  WorldDeconstructionForTesting(this.builder);

  Uri getLibraryUri(KLibrary library) {
    return builder._libraryEnvs[library.libraryIndex].library.importUri;
  }

  KLibrary getLibraryForClass(KClass cls) {
    _KClassEnv env = builder._classEnvs[cls.classIndex];
    return builder.getLibrary(env.cls.enclosingLibrary);
  }

  KLibrary _getLibrary<E>(E member, Map<ir.Member, E> map) {
    ir.Library library;
    map.forEach((ir.Member node, E other) {
      if (library == null && member == other) {
        library = node.enclosingLibrary;
      }
    });
    if (library == null) {
      throw new ArgumentError("No library found for $member");
    }
    return builder._getLibrary(library);
  }

  KLibrary getLibraryForFunction(KFunction function) =>
      _getLibrary(function, builder._methodMap);

  KLibrary getLibraryForField(KField field) =>
      _getLibrary(field, builder._fieldMap);

  KClass getSuperclassForClass(KClass cls) {
    _KClassEnv env = builder._classEnvs[cls.classIndex];
    ir.Supertype supertype = env.cls.supertype;
    if (supertype == null) return null;
    return builder.getClass(supertype.classNode);
  }

  InterfaceType getMixinTypeForClass(KClass cls) {
    _KClassEnv env = builder._classEnvs[cls.classIndex];
    ir.Supertype mixedInType = env.cls.mixedInType;
    if (mixedInType == null) return null;
    return builder.createInterfaceType(
        mixedInType.classNode, mixedInType.typeArguments);
  }
}
