// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.fasta_accessors;

export 'frontend_accessors.dart' show wrapInvalid;

import 'frontend_accessors.dart' show Accessor, buildIsNull, makeLet;

import 'package:front_end/src/fasta/builder/ast_factory.dart' show AstFactory;

import 'package:front_end/src/fasta/type_inference/type_promotion.dart'
    show TypePromoter;

import 'package:kernel/ast.dart';

import '../errors.dart' show internalError;

import '../scope.dart' show AccessErrorBuilder, ProblemBuilder, Scope;

import 'frontend_accessors.dart' as kernel
    show
        IndexAccessor,
        NullAwarePropertyAccessor,
        PropertyAccessor,
        ReadOnlyAccessor,
        StaticAccessor,
        SuperIndexAccessor,
        SuperPropertyAccessor,
        ThisIndexAccessor,
        ThisPropertyAccessor,
        VariableAccessor;

import 'kernel_builder.dart'
    show Builder, KernelClassBuilder, PrefixBuilder, TypeDeclarationBuilder;

import '../names.dart' show callName;

abstract class BuilderHelper {
  Uri get uri;

  TypePromoter get typePromoter;

  int get functionNestingLevel;

  AstFactory get astFactory;

  Constructor lookupConstructor(Name name, {bool isSuper});

  Expression toSuperMethodInvocation(MethodInvocation node);

  Expression toValue(node);

  Member lookupSuperMember(Name name, {bool isSetter: false});

  scopeLookup(Scope scope, String name, int offset,
      {bool isQualified: false, PrefixBuilder prefix});

  finishSend(Object receiver, Arguments arguments, int offset);

  Expression buildCompileTimeError(error, [int offset]);

  Initializer buildInvalidIntializer(Expression expression, [int offset]);

  Initializer buildSuperInitializer(
      Constructor constructor, Arguments arguments,
      [int offset]);

  Initializer buildRedirectingInitializer(
      Constructor constructor, Arguments arguments,
      [int charOffset = -1]);

  Expression buildStaticInvocation(Procedure target, Arguments arguments);

  Expression buildProblemExpression(ProblemBuilder builder, int offset);

  Expression throwNoSuchMethodError(
      String name, Arguments arguments, int offset,
      {bool isSuper: false, isGetter: false, isSetter: false});

  bool checkArguments(FunctionNode function, Arguments arguments,
      List<TypeParameter> typeParameters);

  StaticGet makeStaticGet(Member readTarget, int offset);
}

abstract class FastaAccessor implements Accessor {
  BuilderHelper get helper;

  String get plainNameForRead;

  Uri get uri => helper.uri;

  String get plainNameForWrite => plainNameForRead;

  bool get isInitializer => false;

  Expression buildForEffect() => buildSimpleRead();

  Initializer buildFieldInitializer(
      Map<String, FieldInitializer> initializers) {
    return helper.buildInvalidIntializer(
        helper.buildCompileTimeError(
            // TODO(ahe): This error message is really bad.
            "Can't use $plainNameForRead here.",
            offset),
        offset);
  }

  Expression makeInvalidRead() {
    return buildThrowNoSuchMethodError(new Arguments.empty(), isGetter: true);
  }

  Expression makeInvalidWrite(Expression value) {
    return buildThrowNoSuchMethodError(new Arguments(<Expression>[value]),
        isSetter: true);
  }

  /* Expression | FastaAccessor | Initializer */ doInvocation(
      int offset, Arguments arguments);

  /* Expression | FastaAccessor */ buildPropertyAccess(
      IncompleteSend send, bool isNullAware) {
    if (send is SendAccessor) {
      return buildMethodInvocation(
          buildSimpleRead(), send.name, send.arguments, send.offset,
          isNullAware: isNullAware);
    } else {
      return PropertyAccessor.make(helper, send.offset, buildSimpleRead(),
          send.name, null, null, isNullAware);
    }
  }

  /* Expression | FastaAccessor */ buildThrowNoSuchMethodError(
      Arguments arguments,
      {bool isSuper: false,
      bool isGetter: false,
      bool isSetter: false,
      String name,
      int offset}) {
    return helper.throwNoSuchMethodError(
        name ?? plainNameForWrite, arguments, offset ?? this.offset,
        isGetter: isGetter, isSetter: isSetter, isSuper: isSuper);
  }

  bool get isThisPropertyAccessor => false;
}

abstract class ErrorAccessor implements FastaAccessor {
  @override
  Expression get builtBinary => internalError("Unsupported operation.");

  @override
  void set builtBinary(Expression expression) {
    internalError("Unsupported operation.");
  }

  @override
  Expression get builtGetter => internalError("Unsupported operation.");

  @override
  void set builtGetter(Expression expression) {
    internalError("Unsupported operation.");
  }

  /// Pass [arguments] that must be evaluated before throwing an error.  At
  /// most one of [isGetter] and [isSetter] should be true and they're passed
  /// to [BuilderHelper.buildThrowNoSuchMethodError] if it is used.
  Expression buildError(Arguments arguments,
      {bool isGetter: false, bool isSetter: false, int offset});

  Name get name => internalError("Unsupported operation.");

  @override
  String get plainNameForRead => name.name;

  withReceiver(Object receiver, {bool isNullAware}) => this;

  @override
  Initializer buildFieldInitializer(
      Map<String, FieldInitializer> initializers) {
    return helper.buildInvalidIntializer(
        buildError(new Arguments.empty(), isSetter: true));
  }

  @override
  doInvocation(int offset, Arguments arguments) {
    return buildError(arguments, offset: offset);
  }

  @override
  buildPropertyAccess(IncompleteSend send, bool isNullAware) => this;

  @override
  buildThrowNoSuchMethodError(Arguments arguments,
      {bool isSuper: false,
      isGetter: false,
      isSetter: false,
      String name,
      int offset}) {
    return this;
  }

  @override
  Expression buildAssignment(Expression value, {bool voidContext: false}) {
    return buildError(new Arguments(<Expression>[value]), isSetter: true);
  }

  @override
  Expression buildCompoundAssignment(Name binaryOperator, Expression value,
      {int offset: TreeNode.noOffset,
      bool voidContext: false,
      Procedure interfaceTarget}) {
    return buildError(new Arguments(<Expression>[value]), isGetter: true);
  }

  @override
  Expression buildPrefixIncrement(Name binaryOperator,
      {int offset: TreeNode.noOffset,
      bool voidContext: false,
      Procedure interfaceTarget}) {
    return buildError(new Arguments(<Expression>[new IntLiteral(1)]),
        isGetter: true);
  }

  @override
  Expression buildPostfixIncrement(Name binaryOperator,
      {int offset: TreeNode.noOffset,
      bool voidContext: false,
      Procedure interfaceTarget}) {
    return buildError(new Arguments(<Expression>[new IntLiteral(1)]),
        isGetter: true);
  }

  @override
  Expression buildNullAwareAssignment(Expression value, DartType type,
      {bool voidContext: false}) {
    return buildError(new Arguments(<Expression>[value]), isSetter: true);
  }

  @override
  Expression buildSimpleRead() =>
      buildError(new Arguments.empty(), isGetter: true);

  @override
  Expression makeInvalidRead() =>
      buildError(new Arguments.empty(), isGetter: true);

  @override
  Expression makeInvalidWrite(Expression value) {
    return buildError(new Arguments(<Expression>[value]), isSetter: true);
  }
}

class ThisAccessor extends FastaAccessor {
  final BuilderHelper helper;

  final int offset;

  final bool isInitializer;

  final bool isSuper;

  ThisAccessor(this.helper, this.offset, this.isInitializer,
      {this.isSuper: false});

  @override
  Expression get builtBinary => internalError("Unsupported operation.");

  @override
  void set builtBinary(Expression expression) {
    internalError("Unsupported operation.");
  }

  @override
  Expression get builtGetter => internalError("Unsupported operation.");

  @override
  void set builtGetter(Expression expression) {
    internalError("Unsupported operation.");
  }

  String get plainNameForRead => internalError(isSuper ? "super" : "this");

  Expression buildSimpleRead() {
    if (!isSuper) {
      return new ThisExpression();
    } else {
      return helper.buildCompileTimeError(
          "Can't use `super` as an expression.", offset);
    }
  }

  Initializer buildFieldInitializer(
      Map<String, FieldInitializer> initializers) {
    String keyword = isSuper ? "super" : "this";
    return helper.buildInvalidIntializer(
        helper.buildCompileTimeError(
            "Can't use '$keyword' here, did you mean '$keyword()'?", offset),
        offset);
  }

  buildPropertyAccess(IncompleteSend send, bool isNullAware) {
    if (isInitializer && send is SendAccessor) {
      return buildConstructorInitializer(
          send.offset, send.name, send.arguments);
    }
    if (send is SendAccessor) {
      // Notice that 'this' or 'super' can't be null. So we can ignore the
      // value of [isNullAware].
      MethodInvocation result = buildMethodInvocation(
          new ThisExpression(), send.name, send.arguments, offset);
      return isSuper ? helper.toSuperMethodInvocation(result) : result;
    } else {
      if (isSuper) {
        Member getter = helper.lookupSuperMember(send.name);
        Member setter = helper.lookupSuperMember(send.name, isSetter: true);
        return new SuperPropertyAccessor(
            helper, send.offset, send.name, getter, setter);
      } else {
        return new ThisPropertyAccessor(
            helper, send.offset, send.name, null, null);
      }
    }
  }

  doInvocation(int offset, Arguments arguments) {
    if (isInitializer) {
      return buildConstructorInitializer(offset, new Name(""), arguments);
    } else {
      return buildMethodInvocation(
          new ThisExpression(), callName, arguments, offset);
    }
  }

  Initializer buildConstructorInitializer(
      int offset, Name name, Arguments arguments) {
    Constructor constructor = helper.lookupConstructor(name, isSuper: isSuper);
    if (constructor == null ||
        !helper.checkArguments(
            constructor.function, arguments, <TypeParameter>[])) {
      return helper.buildInvalidIntializer(
          buildThrowNoSuchMethodError(arguments,
              isSuper: isSuper, name: name.name, offset: offset),
          offset);
    } else if (isSuper) {
      return helper.buildSuperInitializer(constructor, arguments, offset);
    } else {
      return helper.buildRedirectingInitializer(constructor, arguments, offset);
    }
  }

  Expression buildAssignment(Expression value, {bool voidContext: false}) {
    return buildAssignmentError();
  }

  Expression buildNullAwareAssignment(Expression value, DartType type,
      {bool voidContext: false}) {
    return buildAssignmentError();
  }

  Expression buildCompoundAssignment(Name binaryOperator, Expression value,
      {int offset: TreeNode.noOffset,
      bool voidContext: false,
      Procedure interfaceTarget}) {
    return buildAssignmentError();
  }

  Expression buildPrefixIncrement(Name binaryOperator,
      {int offset: TreeNode.noOffset,
      bool voidContext: false,
      Procedure interfaceTarget}) {
    return buildAssignmentError();
  }

  Expression buildPostfixIncrement(Name binaryOperator,
      {int offset: TreeNode.noOffset,
      bool voidContext: false,
      Procedure interfaceTarget}) {
    return buildAssignmentError();
  }

  Expression buildAssignmentError() {
    String message =
        isSuper ? "Can't assign to 'super'." : "Can't assign to 'this'.";
    return helper.buildCompileTimeError(message, offset);
  }

  toString() => "ThisAccessor($offset${isSuper ? ', super' : ''})";
}

abstract class IncompleteSend extends FastaAccessor {
  final BuilderHelper helper;

  @override
  final int offset;

  final Name name;

  IncompleteSend(this.helper, this.offset, this.name);

  @override
  Expression get builtBinary => internalError("Unsupported operation.");

  @override
  void set builtBinary(Expression expression) {
    internalError("Unsupported operation.");
  }

  @override
  Expression get builtGetter => internalError("Unsupported operation.");

  @override
  void set builtGetter(Expression expression) {
    internalError("Unsupported operation.");
  }

  withReceiver(Object receiver, {bool isNullAware});
}

class IncompleteError extends IncompleteSend with ErrorAccessor {
  final Object error;

  IncompleteError(BuilderHelper helper, int offset, this.error)
      : super(helper, offset, null);

  @override
  Expression buildError(Arguments arguments,
      {bool isGetter: false, bool isSetter: false, int offset}) {
    return helper.buildCompileTimeError(error, offset ?? this.offset);
  }

  @override
  doInvocation(int offset, Arguments arguments) => this;
}

class SendAccessor extends IncompleteSend {
  final Arguments arguments;

  SendAccessor(BuilderHelper helper, int offset, Name name, this.arguments)
      : super(helper, offset, name) {
    assert(arguments != null);
  }

  String get plainNameForRead => name.name;

  Expression buildSimpleRead() {
    return internalError("Unhandled");
  }

  Expression buildAssignment(Expression value, {bool voidContext: false}) {
    return internalError("Unhandled");
  }

  withReceiver(Object receiver, {bool isNullAware: false}) {
    if (receiver is TypeDeclarationBuilder) {
      /// `SomeType?.toString` is the same as `SomeType.toString`, not
      /// `(SomeType).toString`.
      isNullAware = false;
    }
    if (receiver is FastaAccessor) {
      return receiver.buildPropertyAccess(this, isNullAware);
    }
    if (receiver is PrefixBuilder) {
      PrefixBuilder prefix = receiver;
      receiver = helper.scopeLookup(prefix.exports, name.name, offset,
          isQualified: true, prefix: prefix);
      return helper.finishSend(receiver, arguments, offset);
    }
    Expression result;
    if (receiver is KernelClassBuilder) {
      Builder builder = receiver.findStaticBuilder(name.name, offset, uri);
      if (builder == null || builder is AccessErrorBuilder) {
        return buildThrowNoSuchMethodError(arguments);
      }
      if (builder.hasProblem) {
        result = helper.buildProblemExpression(builder, offset);
      } else {
        Member target = builder.target;
        if (target != null) {
          if (target is Field) {
            result = buildMethodInvocation(new StaticGet(target), callName,
                arguments, offset + (target.name?.name?.length ?? 0),
                isNullAware: isNullAware);
          } else {
            result = helper.buildStaticInvocation(target, arguments)
              ..fileOffset = offset;
          }
        } else {
          result = buildThrowNoSuchMethodError(arguments)..fileOffset = offset;
        }
      }
    } else {
      result = buildMethodInvocation(
          helper.toValue(receiver), name, arguments, offset,
          isNullAware: isNullAware);
    }
    return result;
  }

  Expression buildNullAwareAssignment(Expression value, DartType type,
      {bool voidContext: false}) {
    return internalError("Unhandled");
  }

  Expression buildCompoundAssignment(Name binaryOperator, Expression value,
      {int offset, bool voidContext: false, Procedure interfaceTarget}) {
    return internalError("Unhandled");
  }

  Expression buildPrefixIncrement(Name binaryOperator,
      {int offset, bool voidContext: false, Procedure interfaceTarget}) {
    return internalError("Unhandled");
  }

  Expression buildPostfixIncrement(Name binaryOperator,
      {int offset, bool voidContext: false, Procedure interfaceTarget}) {
    return internalError("Unhandled");
  }

  Expression doInvocation(int offset, Arguments arguments) {
    return internalError("Unhandled");
  }

  toString() => "SendAccessor($offset, $name, $arguments)";
}

class IncompletePropertyAccessor extends IncompleteSend {
  IncompletePropertyAccessor(BuilderHelper helper, int offset, Name name)
      : super(helper, offset, name);

  String get plainNameForRead => name.name;

  Expression buildSimpleRead() => internalError("Unhandled");

  Expression buildAssignment(Expression value, {bool voidContext: false}) {
    return internalError("Unhandled");
  }

  withReceiver(Object receiver, {bool isNullAware: false}) {
    if (receiver is TypeDeclarationBuilder) {
      /// For reasons beyond comprehension, `SomeType?.toString` is the same as
      /// `SomeType.toString`, not `(SomeType).toString`. WTAF!?!
      //
      isNullAware = false;
    }
    if (receiver is FastaAccessor) {
      return receiver.buildPropertyAccess(this, isNullAware);
    }
    if (receiver is PrefixBuilder) {
      PrefixBuilder prefix = receiver;
      return helper.scopeLookup(prefix.exports, name.name, offset,
          isQualified: true, prefix: prefix);
    }
    if (receiver is KernelClassBuilder) {
      Builder builder = receiver.findStaticBuilder(name.name, offset, uri);
      if (builder == null) {
        // If we find a setter, [builder] is an [AccessErrorBuilder], not null.
        return buildThrowNoSuchMethodError(new Arguments.empty(),
            isGetter: true);
      }
      Builder setter;
      if (builder.isSetter) {
        setter = builder;
      } else if (builder.isGetter) {
        setter =
            receiver.findStaticBuilder(name.name, offset, uri, isSetter: true);
      } else if (builder.isField && !builder.isFinal) {
        setter = builder;
      }
      return new StaticAccessor.fromBuilder(helper, builder, offset, setter);
    }
    return PropertyAccessor.make(helper, offset, helper.toValue(receiver), name,
        null, null, isNullAware);
  }

  Expression buildNullAwareAssignment(Expression value, DartType type,
      {bool voidContext: false}) {
    return internalError("Unhandled");
  }

  Expression buildCompoundAssignment(Name binaryOperator, Expression value,
      {int offset, bool voidContext: false, Procedure interfaceTarget}) {
    return internalError("Unhandled");
  }

  Expression buildPrefixIncrement(Name binaryOperator,
      {int offset, bool voidContext: false, Procedure interfaceTarget}) {
    return internalError("Unhandled");
  }

  Expression buildPostfixIncrement(Name binaryOperator,
      {int offset, bool voidContext: false, Procedure interfaceTarget}) {
    return internalError("Unhandled");
  }

  Expression doInvocation(int offset, Arguments arguments) {
    return internalError("Unhandled");
  }

  toString() => "IncompletePropertyAccessor($offset, $name)";
}

class IndexAccessor extends kernel.IndexAccessor with FastaAccessor {
  final BuilderHelper helper;

  IndexAccessor.internal(this.helper, int offset, Expression receiver,
      Expression index, Procedure getter, Procedure setter)
      : super.internal(receiver, index, getter, setter, offset);

  String get plainNameForRead => "[]";

  String get plainNameForWrite => "[]=";

  Expression doInvocation(int offset, Arguments arguments) {
    return buildMethodInvocation(
        buildSimpleRead(), callName, arguments, offset);
  }

  toString() => "IndexAccessor()";

  static FastaAccessor make(
      BuilderHelper helper,
      int offset,
      Expression receiver,
      Expression index,
      Procedure getter,
      Procedure setter) {
    if (receiver is ThisExpression) {
      return new ThisIndexAccessor(helper, offset, index, getter, setter);
    } else {
      return new IndexAccessor.internal(
          helper, offset, receiver, index, getter, setter);
    }
  }
}

class PropertyAccessor extends kernel.PropertyAccessor with FastaAccessor {
  final BuilderHelper helper;

  PropertyAccessor.internal(this.helper, int offset, Expression receiver,
      Name name, Member getter, Member setter)
      : super.internal(receiver, name, getter, setter, offset);

  String get plainNameForRead => name.name;

  bool get isThisPropertyAccessor => receiver is ThisExpression;

  Expression doInvocation(int offset, Arguments arguments) {
    return buildMethodInvocation(receiver, name, arguments, offset);
  }

  toString() => "PropertyAccessor()";

  static FastaAccessor make(
      BuilderHelper helper,
      int offset,
      Expression receiver,
      Name name,
      Member getter,
      Member setter,
      bool isNullAware) {
    if (receiver is ThisExpression) {
      return new ThisPropertyAccessor(helper, offset, name, getter, setter);
    } else {
      return isNullAware
          ? new NullAwarePropertyAccessor(
              helper, offset, receiver, name, getter, setter, null)
          : new PropertyAccessor.internal(
              helper, offset, receiver, name, getter, setter);
    }
  }
}

class StaticAccessor extends kernel.StaticAccessor with FastaAccessor {
  StaticAccessor(
      BuilderHelper helper, int offset, Member readTarget, Member writeTarget)
      : super(helper, readTarget, writeTarget, offset) {
    assert(readTarget != null || writeTarget != null);
  }

  factory StaticAccessor.fromBuilder(BuilderHelper helper, Builder builder,
      int offset, Builder builderSetter) {
    if (builder is AccessErrorBuilder) {
      AccessErrorBuilder error = builder;
      builder = error.builder;
      // We should only see an access error here if we've looked up a setter
      // when not explicitly looking for a setter.
      assert(builder.isSetter);
    } else if (builder.target == null) {
      return internalError("Unhandled: ${builder}");
    }
    Member getter = builder.target.hasGetter ? builder.target : null;
    Member setter = builder.target.hasSetter ? builder.target : null;
    if (setter == null) {
      if (builderSetter?.target?.hasSetter ?? false) {
        setter = builderSetter.target;
      }
    }
    return new StaticAccessor(helper, offset, getter, setter);
  }

  String get plainNameForRead => (readTarget ?? writeTarget).name.name;

  Expression doInvocation(int offset, Arguments arguments) {
    if (readTarget == null || isFieldOrGetter(readTarget)) {
      return buildMethodInvocation(buildSimpleRead(), callName, arguments,
          offset + (readTarget?.name?.name?.length ?? 0));
    } else {
      return helper.buildStaticInvocation(readTarget, arguments)
        ..fileOffset = offset;
    }
  }

  toString() => "StaticAccessor()";
}

class SuperPropertyAccessor extends kernel.SuperPropertyAccessor
    with FastaAccessor {
  final BuilderHelper helper;

  SuperPropertyAccessor(
      this.helper, int offset, Name name, Member getter, Member setter)
      : super(name, getter, setter, offset);

  String get plainNameForRead => name.name;

  Expression doInvocation(int offset, Arguments arguments) {
    if (getter == null || isFieldOrGetter(getter)) {
      return buildMethodInvocation(
          buildSimpleRead(), callName, arguments, offset);
    } else {
      return new DirectMethodInvocation(new ThisExpression(), getter, arguments)
        ..fileOffset = offset;
    }
  }

  toString() => "SuperPropertyAccessor()";
}

class ThisIndexAccessor extends kernel.ThisIndexAccessor with FastaAccessor {
  final BuilderHelper helper;

  ThisIndexAccessor(this.helper, int offset, Expression index, Procedure getter,
      Procedure setter)
      : super(index, getter, setter, offset);

  String get plainNameForRead => "[]";

  String get plainNameForWrite => "[]=";

  Expression doInvocation(int offset, Arguments arguments) {
    return buildMethodInvocation(
        buildSimpleRead(), callName, arguments, offset);
  }

  toString() => "ThisIndexAccessor()";
}

class SuperIndexAccessor extends kernel.SuperIndexAccessor with FastaAccessor {
  final BuilderHelper helper;

  SuperIndexAccessor(
      this.helper, int offset, Expression index, Member getter, Member setter)
      : super(index, getter, setter, offset);

  String get plainNameForRead => "[]";

  String get plainNameForWrite => "[]=";

  Expression doInvocation(int offset, Arguments arguments) {
    return buildMethodInvocation(
        buildSimpleRead(), callName, arguments, offset);
  }

  toString() => "SuperIndexAccessor()";
}

class ThisPropertyAccessor extends kernel.ThisPropertyAccessor
    with FastaAccessor {
  final BuilderHelper helper;

  ThisPropertyAccessor(
      this.helper, int offset, Name name, Member getter, Member setter)
      : super(name, getter, setter, offset);

  String get plainNameForRead => name.name;

  bool get isThisPropertyAccessor => true;

  Expression doInvocation(int offset, Arguments arguments) {
    Member interfaceTarget = getter;
    if (interfaceTarget is Field) {
      // TODO(ahe): In strong mode we should probably rewrite this to
      // `this.name.call(arguments)`.
      interfaceTarget = null;
    }
    return buildMethodInvocation(new ThisExpression(), name, arguments, offset);
  }

  toString() => "ThisPropertyAccessor()";
}

class NullAwarePropertyAccessor extends kernel.NullAwarePropertyAccessor
    with FastaAccessor {
  final BuilderHelper helper;

  NullAwarePropertyAccessor(this.helper, int offset, Expression receiver,
      Name name, Member getter, Member setter, DartType type)
      : super(receiver, name, getter, setter, type, offset);

  String get plainNameForRead => name.name;

  Expression doInvocation(int offset, Arguments arguments) {
    return internalError("Not implemented yet.");
  }

  toString() => "NullAwarePropertyAccessor()";
}

class VariableAccessor extends kernel.VariableAccessor with FastaAccessor {
  @override
  final BuilderHelper helper;

  VariableAccessor(this.helper, int offset, VariableDeclaration variable,
      [DartType promotedType])
      : super(variable, promotedType, offset);

  String get plainNameForRead => variable.name;

  Expression doInvocation(int offset, Arguments arguments) {
    // Normally the offset is at the start of the token, but in this case,
    // because we insert a '.call', we want it at the end instead.
    return buildMethodInvocation(buildSimpleRead(), callName, arguments,
        offset + (variable.name?.length ?? 0));
  }

  toString() => "VariableAccessor()";
}

class ReadOnlyAccessor extends kernel.ReadOnlyAccessor with FastaAccessor {
  final BuilderHelper helper;

  final String plainNameForRead;

  ReadOnlyAccessor(
      this.helper, Expression expression, this.plainNameForRead, int offset)
      : super(expression, offset);

  Expression doInvocation(int offset, Arguments arguments) {
    return buildMethodInvocation(
        buildSimpleRead(), callName, arguments, offset);
  }
}

class ParenthesizedExpression extends ReadOnlyAccessor {
  ParenthesizedExpression(
      BuilderHelper helper, Expression expression, int offset)
      : super(helper, expression, "<a parenthesized expression>", offset);

  Expression makeInvalidWrite(Expression value) {
    return helper.buildCompileTimeError(
        "Can't assign to a parenthesized expression.", offset);
  }
}

class UnresolvedAccessor extends FastaAccessor with ErrorAccessor {
  @override
  final int offset;

  @override
  final BuilderHelper helper;

  @override
  final Name name;

  UnresolvedAccessor(this.helper, this.name, this.offset);

  Expression doInvocation(int charOffset, Arguments arguments) {
    return buildError(arguments, offset: charOffset);
  }

  @override
  Expression buildError(Arguments arguments,
      {bool isGetter: false, bool isSetter: false, int offset}) {
    return helper.throwNoSuchMethodError(
        plainNameForRead, arguments, offset ?? this.offset,
        isGetter: isGetter, isSetter: isSetter);
  }
}

bool isFieldOrGetter(Member member) {
  return member is Field || (member is Procedure && member.isGetter);
}

Expression buildMethodInvocation(
    Expression receiver, Name name, Arguments arguments, int offset,
    {bool isNullAware: false}) {
  if (isNullAware) {
    VariableDeclaration variable = new VariableDeclaration.forValue(receiver);
    return makeLet(
        variable,
        new ConditionalExpression(
            buildIsNull(new VariableGet(variable)),
            new NullLiteral(),
            new MethodInvocation(new VariableGet(variable), name, arguments)
              ..fileOffset = offset,
            const DynamicType()));
  } else {
    return new MethodInvocation(receiver, name, arguments)..fileOffset = offset;
  }
}
