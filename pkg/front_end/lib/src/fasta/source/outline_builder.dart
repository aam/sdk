// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.outline_builder;

import 'package:kernel/ast.dart' show AsyncMarker, ProcedureKind;

import '../fasta_codes.dart' show FastaMessage, codeExpectedBlockToSkip;

import '../parser/parser.dart' show FormalParameterType, optional;

import '../parser/identifier_context.dart' show IdentifierContext;

import '../scanner/token.dart' show Token;

import '../util/link.dart' show Link;

import '../combinator.dart' show Combinator;

import '../errors.dart' show internalError;

import '../builder/builder.dart';

import '../modifier.dart' show Modifier;

import 'source_library_builder.dart' show SourceLibraryBuilder;

import 'unhandled_listener.dart' show NullValue, Unhandled, UnhandledListener;

import '../parser/dart_vm_native.dart'
    show removeNativeClause, skipNativeClause;

import '../operator.dart'
    show
        Operator,
        operatorFromString,
        operatorToString,
        operatorRequiredArgumentCount;

import '../quote.dart' show unescapeString;

enum MethodBody {
  Abstract,
  Regular,
  RedirectingFactoryBody,
}

AsyncMarker asyncMarkerFromTokens(Token asyncToken, Token starToken) {
  if (asyncToken == null || identical(asyncToken.stringValue, "sync")) {
    if (starToken == null) {
      return AsyncMarker.Sync;
    } else {
      assert(identical(starToken.stringValue, "*"));
      return AsyncMarker.SyncStar;
    }
  } else if (identical(asyncToken.stringValue, "async")) {
    if (starToken == null) {
      return AsyncMarker.Async;
    } else {
      assert(identical(starToken.stringValue, "*"));
      return AsyncMarker.AsyncStar;
    }
  } else {
    return internalError("Unknown async modifier: $asyncToken");
  }
}

class OutlineBuilder extends UnhandledListener {
  final SourceLibraryBuilder library;

  final bool isDartLibrary;

  String nativeMethodName;

  OutlineBuilder(SourceLibraryBuilder library)
      : library = library,
        isDartLibrary = library.uri.scheme == "dart";

  @override
  Uri get uri => library.fileUri;

  @override
  int popCharOffset() => pop();

  List<String> popIdentifierList(int count) {
    if (count == 0) return null;
    List<String> list = new List<String>.filled(count, null, growable: true);
    for (int i = count - 1; i >= 0; i--) {
      popCharOffset();
      list[i] = pop();
    }
    return list;
  }

  @override
  void endMetadata(Token beginToken, Token periodBeforeName, Token endToken) {
    debugEvent("Metadata");
    List arguments = pop();
    popIfNotNull(periodBeforeName); // charOffset.
    String postfix = popIfNotNull(periodBeforeName);
    List<TypeBuilder> typeArguments = pop();
    if (arguments == null) {
      int charOffset = pop();
      String expression = pop();
      push(new MetadataBuilder.fromExpression(
          expression, postfix, library, charOffset));
    } else {
      int charOffset = pop();
      String typeName = pop();
      push(new MetadataBuilder.fromConstructor(
          library.addConstructorReference(
              typeName, typeArguments, postfix, charOffset),
          arguments,
          library,
          beginToken.charOffset));
    }
  }

  @override
  void endHide(Token hideKeyword) {
    debugEvent("Hide");
    List<String> names = pop();
    push(new Combinator.hide(names, hideKeyword.charOffset, library.fileUri));
  }

  @override
  void endShow(Token showKeyword) {
    debugEvent("Show");
    List<String> names = pop();
    push(new Combinator.show(names, showKeyword.charOffset, library.fileUri));
  }

  @override
  void endCombinators(int count) {
    debugEvent("Combinators");
    push(popList(count) ?? NullValue.Combinators);
  }

  @override
  void endExport(Token exportKeyword, Token semicolon) {
    debugEvent("Export");
    List<Combinator> combinators = pop();
    Unhandled conditionalUris = pop();
    popCharOffset();
    String uri = pop();
    List<MetadataBuilder> metadata = pop();
    if (uri != null) {
      library.addExport(metadata, uri, conditionalUris, combinators,
          exportKeyword.charOffset);
    }
    checkEmpty(exportKeyword.charOffset);
  }

  @override
  void endImport(Token importKeyword, Token deferredKeyword, Token asKeyword,
      Token semicolon) {
    debugEvent("endImport");
    List<Combinator> combinators = pop();
    int prefixOffset = popIfNotNull(asKeyword) ?? -1;
    String prefix = popIfNotNull(asKeyword);
    Unhandled conditionalUris = pop();
    popCharOffset();
    String uri = pop();
    List<MetadataBuilder> metadata = pop();
    if (uri != null) {
      library.addImport(metadata, uri, conditionalUris, prefix, combinators,
          deferredKeyword != null, importKeyword.charOffset, prefixOffset);
    }
    checkEmpty(importKeyword.charOffset);
  }

  @override
  void handleRecoverExpression(Token token) {
    debugEvent("RecoverExpression");
    push(NullValue.Expression);
    push(token.charOffset);
  }

  @override
  void endPart(Token partKeyword, Token semicolon) {
    debugEvent("Part");
    popCharOffset();
    String uri = pop();
    List<MetadataBuilder> metadata = pop();
    if (uri != null) {
      library.addPart(metadata, uri);
    }
    checkEmpty(partKeyword.charOffset);
  }

  @override
  void handleOperatorName(Token operatorKeyword, Token token) {
    debugEvent("OperatorName");
    push(operatorFromString(token.stringValue));
    push(token.charOffset);
  }

  @override
  void handleIdentifier(Token token, IdentifierContext context) {
    super.handleIdentifier(token, context);
    push(token.charOffset);
  }

  @override
  void handleNoName(Token token) {
    super.handleNoName(token);
    push(token.charOffset);
  }

  @override
  void endLiteralString(int interpolationCount, Token endToken) {
    debugEvent("endLiteralString");
    if (interpolationCount == 0) {
      Token token = pop();
      push(unescapeString(token.lexeme));
      push(token.charOffset);
    } else {
      internalError("String interpolation not implemented.");
    }
  }

  @override
  void handleStringJuxtaposition(int literalCount) {
    debugEvent("StringJuxtaposition");
    List<String> list =
        new List<String>.filled(literalCount, null, growable: false);
    int charOffset = -1;
    for (int i = literalCount - 1; i >= 0; i--) {
      charOffset = pop();
      list[i] = pop();
    }
    push(list.join(""));
    push(charOffset);
  }

  @override
  void endIdentifierList(int count) {
    debugEvent("endIdentifierList");
    push(popIdentifierList(count) ?? NullValue.IdentifierList);
  }

  @override
  void handleQualified(Token period) {
    debugEvent("handleQualified");
    int charOffset = pop();
    String name = pop();
    charOffset = pop(); // We just want the charOffset of receiver.
    String receiver = pop();
    push("$receiver.$name");
    push(charOffset);
  }

  @override
  void endLibraryName(Token libraryKeyword, Token semicolon) {
    debugEvent("endLibraryName");
    popCharOffset();
    String name = pop();
    List<MetadataBuilder> metadata = pop();
    library.name = name;
    library.metadata = metadata;
  }

  @override
  void beginClassDeclaration(Token begin, Token name) {
    library.beginNestedDeclaration(name.lexeme);
  }

  @override
  void endClassDeclaration(
      int interfacesCount,
      Token beginToken,
      Token classKeyword,
      Token extendsKeyword,
      Token implementsKeyword,
      Token endToken) {
    debugEvent("endClassDeclaration");
    List<TypeBuilder> interfaces = popList(interfacesCount);
    TypeBuilder supertype = pop();
    List<TypeVariableBuilder> typeVariables = pop();
    int charOffset = pop();
    String name = pop();
    if (typeVariables != null && supertype is MixinApplicationBuilder) {
      supertype.typeVariables = typeVariables;
      supertype.subclassName = name;
    }
    int modifiers = Modifier.validate(pop());
    List<MetadataBuilder> metadata = pop();
    library.addClass(metadata, modifiers, name, typeVariables, supertype,
        interfaces, charOffset);
    checkEmpty(beginToken.charOffset);
  }

  ProcedureKind computeProcedureKind(Token token) {
    if (token == null) return ProcedureKind.Method;
    if (optional("get", token)) return ProcedureKind.Getter;
    if (optional("set", token)) return ProcedureKind.Setter;
    return internalError("Unhandled: ${token.lexeme}");
  }

  @override
  void beginTopLevelMethod(Token token, Token name) {
    library.beginNestedDeclaration(name.lexeme, hasMembers: false);
  }

  @override
  void endTopLevelMethod(Token beginToken, Token getOrSet, Token endToken) {
    debugEvent("endTopLevelMethod");
    MethodBody kind = pop();
    AsyncMarker asyncModifier = pop();
    List<FormalParameterBuilder> formals = pop();
    int formalsOffset = pop();
    List<TypeVariableBuilder> typeVariables = pop();
    int charOffset = pop();
    String name = pop();
    TypeBuilder returnType = pop();
    int modifiers =
        Modifier.validate(pop(), isAbstract: kind == MethodBody.Abstract);
    List<MetadataBuilder> metadata = pop();
    checkEmpty(beginToken.charOffset);
    library.addProcedure(
        metadata,
        modifiers,
        returnType,
        name,
        typeVariables,
        formals,
        asyncModifier,
        computeProcedureKind(getOrSet),
        charOffset,
        formalsOffset,
        endToken.charOffset,
        nativeMethodName,
        isTopLevel: true);
    nativeMethodName = null;
  }

  @override
  void handleNoFunctionBody(Token token) {
    debugEvent("NoFunctionBody");
    push(MethodBody.Abstract);
  }

  @override
  void handleFunctionBodySkipped(Token token, bool isExpressionBody) {
    debugEvent("handleFunctionBodySkipped");
    push(MethodBody.Regular);
  }

  @override
  void beginMethod(Token token, Token name) {
    library.beginNestedDeclaration(name.lexeme, hasMembers: false);
  }

  @override
  void endMethod(Token getOrSet, Token beginToken, Token endToken) {
    debugEvent("Method");
    MethodBody bodyKind = pop();
    if (bodyKind == MethodBody.RedirectingFactoryBody) {
      // This will cause an error later.
      pop();
    }
    AsyncMarker asyncModifier = pop();
    List<FormalParameterBuilder> formals = pop();
    int formalsOffset = pop();
    List<TypeVariableBuilder> typeVariables = pop();
    int charOffset = pop();
    dynamic nameOrOperator = pop();
    if (Operator.subtract == nameOrOperator && formals == null) {
      nameOrOperator = Operator.unaryMinus;
    }
    String name;
    ProcedureKind kind;
    if (nameOrOperator is Operator) {
      name = operatorToString(nameOrOperator);
      kind = ProcedureKind.Operator;
      int requiredArgumentCount = operatorRequiredArgumentCount(nameOrOperator);
      if ((formals?.length ?? 0) != requiredArgumentCount) {
        library.addCompileTimeError(
            charOffset,
            "Operator '$name' must have exactly $requiredArgumentCount "
            "parameters.");
      } else {
        if (formals != null) {
          for (FormalParameterBuilder formal in formals) {
            if (!formal.isRequired) {
              library.addCompileTimeError(formal.charOffset,
                  "An operator can't have optional parameters.");
            }
          }
        }
      }
    } else {
      name = nameOrOperator;
      kind = computeProcedureKind(getOrSet);
    }
    TypeBuilder returnType = pop();
    int modifiers =
        Modifier.validate(pop(), isAbstract: bodyKind == MethodBody.Abstract);
    List<MetadataBuilder> metadata = pop();
    library.addProcedure(
        metadata,
        modifiers,
        returnType,
        name,
        typeVariables,
        formals,
        asyncModifier,
        kind,
        charOffset,
        formalsOffset,
        endToken.charOffset,
        nativeMethodName,
        isTopLevel: false);
    nativeMethodName = null;
  }

  @override
  void endMixinApplication(Token withKeyword) {
    debugEvent("MixinApplication");
    List<TypeBuilder> mixins = pop();
    TypeBuilder supertype = pop();
    push(library.addMixinApplication(supertype, mixins, -1));
  }

  @override
  void beginNamedMixinApplication(Token begin, Token name) {
    library.beginNestedDeclaration(name.lexeme, hasMembers: false);
  }

  @override
  void endNamedMixinApplication(Token beginToken, Token classKeyword,
      Token equals, Token implementsKeyword, Token endToken) {
    debugEvent("endNamedMixinApplication");
    List<TypeBuilder> interfaces = popIfNotNull(implementsKeyword);
    TypeBuilder mixinApplication = pop();
    List<TypeVariableBuilder> typeVariables = pop();
    int charOffset = pop();
    String name = pop();
    if (typeVariables != null && mixinApplication is MixinApplicationBuilder) {
      mixinApplication.typeVariables = typeVariables;
      mixinApplication.subclassName = name;
    }
    int modifiers = Modifier.validate(pop());
    List<MetadataBuilder> metadata = pop();
    library.addNamedMixinApplication(metadata, name, typeVariables, modifiers,
        mixinApplication, interfaces, charOffset);
    checkEmpty(beginToken.charOffset);
  }

  @override
  void endTypeArguments(int count, Token beginToken, Token endToken) {
    debugEvent("TypeArguments");
    push(popList(count) ?? NullValue.TypeArguments);
  }

  @override
  void handleScript(Token token) {
    debugEvent("Script");
  }

  @override
  void handleType(Token beginToken, Token endToken) {
    debugEvent("Type");
    List<TypeBuilder> arguments = pop();
    int charOffset = pop();
    String name = pop();
    push(library.addNamedType(name, arguments, charOffset));
  }

  @override
  void endTypeList(int count) {
    debugEvent("TypeList");
    push(popList(count) ?? NullValue.TypeList);
  }

  @override
  void endTypeVariables(int count, Token beginToken, Token endToken) {
    debugEvent("TypeVariables");
    push(popList(count) ?? NullValue.TypeVariables);
  }

  @override
  void handleVoidKeyword(Token token) {
    debugEvent("VoidKeyword");
    push(library.addVoidType(token.charOffset));
  }

  @override
  void endFormalParameter(Token covariantKeyword, Token thisKeyword,
      Token nameToken, FormalParameterType kind) {
    debugEvent("FormalParameter");
    int charOffset = pop();
    String name = pop();
    TypeBuilder type = pop();
    int modifiers = Modifier.validate(pop());
    List<MetadataBuilder> metadata = pop();
    push(library.addFormalParameter(
        metadata, modifiers, type, name, thisKeyword != null, charOffset));
  }

  @override
  void handleValuedFormalParameter(Token equals, Token token) {
    debugEvent("ValuedFormalParameter");
    // Ignored for now.
  }

  @override
  void handleFormalParameterWithoutValue(Token token) {
    debugEvent("FormalParameterWithoutValue");
    // Ignored for now.
  }

  @override
  void endFunctionTypedFormalParameter(
      Token covariantKeyword, Token thisKeyword, FormalParameterType kind) {
    debugEvent("FunctionTypedFormalParameter");
    pop(); // Function type parameters.
    pop(); // Formals offset
    pop(); // Type variables.
    int charOffset = pop();
    String name = pop();
    pop(); // Return type.
    push(NullValue.Type);
    push(name);
    push(charOffset);
  }

  @override
  void endOptionalFormalParameters(
      int count, Token beginToken, Token endToken) {
    debugEvent("OptionalFormalParameters");
    FormalParameterType kind = optional("{", beginToken)
        ? FormalParameterType.NAMED
        : FormalParameterType.POSITIONAL;
    // When recovering from an empty list of optional arguments, count may be
    // 0. It might be simpler if the parser didn't call this method in that
    // case, however, then [beginOptionalFormalParameters] wouldn't always be
    // matched by this method.
    List parameters = popList(count) ?? [];
    for (FormalParameterBuilder parameter in parameters) {
      parameter.kind = kind;
    }
    push(parameters);
  }

  @override
  void endFormalParameters(int count, Token beginToken, Token endToken) {
    debugEvent("FormalParameters");
    List formals = popList(count);
    if (formals != null && formals.isNotEmpty) {
      var last = formals.last;
      if (last is List) {
        // TODO(sigmund): change `List newList` back to `var` (this is a
        // workaround for issue #28651). Eventually, make optional
        // formals a separate stack entry (#28673).
        List newList =
            new List<FormalParameterBuilder>(formals.length - 1 + last.length);
        newList.setRange(0, formals.length - 1, formals);
        newList.setRange(formals.length - 1, newList.length, last);
        for (int i = 0; i < last.length; i++) {
          newList[i + formals.length - 1] = last[i];
        }
        formals = newList;
      }
    }
    if (formals != null) {
      for (var formal in formals) {
        if (formal is! FormalParameterBuilder) {
          internalError(formals);
        }
      }
      formals = new List<FormalParameterBuilder>.from(formals);
    }
    push(beginToken.charOffset);
    push(formals ?? NullValue.FormalParameters);
  }

  @override
  void handleNoFormalParameters(Token token) {
    push(token.charOffset);
    super.handleNoFormalParameters(token);
  }

  @override
  void endEnum(Token enumKeyword, Token endBrace, int count) {
    List constantNamesAndOffsets = popList(count * 2);
    int charOffset = pop();
    String name = pop();
    List<MetadataBuilder> metadata = pop();
    library.addEnum(metadata, name, constantNamesAndOffsets, charOffset,
        endBrace.charOffset);
    checkEmpty(enumKeyword.charOffset);
  }

  @override
  void beginFunctionTypeAlias(Token token) {
    library.beginNestedDeclaration(null, hasMembers: false);
  }

  @override
  void handleFunctionType(Token functionToken, Token endToken) {
    debugEvent("FunctionType");
    List<FormalParameterBuilder> formals = pop();
    pop(); // formals offset
    List<TypeVariableBuilder> typeVariables = pop();
    TypeBuilder returnType = pop();
    push(library.addFunctionType(
        returnType, typeVariables, formals, functionToken.charOffset));
  }

  @override
  void endFunctionTypeAlias(
      Token typedefKeyword, Token equals, Token endToken) {
    debugEvent("endFunctionTypeAlias");
    List<FormalParameterBuilder> formals;
    List<TypeVariableBuilder> typeVariables;
    String name;
    TypeBuilder returnType;
    int charOffset;
    if (equals == null) {
      formals = pop();
      pop(); // formals offset
      typeVariables = pop();
      charOffset = pop();
      name = pop();
      returnType = pop();
    } else {
      var type = pop();
      typeVariables = pop();
      charOffset = pop();
      name = pop();
      if (type is FunctionTypeBuilder) {
        // TODO(ahe): We need to start a nested declaration when parsing the
        // formals and return type so we can correctly bind
        // `type.typeVariables`. A typedef can have type variables, and a new
        // function type can also have type variables (representing the type of
        // a generic function).
        formals = type.formals;
        returnType = type.returnType;
      } else {
        // TODO(ahe): Improve this error message.
        library.addCompileTimeError(
            equals.charOffset, "Can't create typedef from non-function type.");
      }
    }
    List<MetadataBuilder> metadata = pop();
    library.addFunctionTypeAlias(
        metadata, returnType, name, typeVariables, formals, charOffset);
    checkEmpty(typedefKeyword.charOffset);
  }

  @override
  void endTopLevelFields(int count, Token beginToken, Token endToken) {
    debugEvent("endTopLevelFields");
    List namesOffsetsAndInitializers = popList(count * 4);
    TypeBuilder type = pop();
    int modifiers = Modifier.validate(pop());
    List<MetadataBuilder> metadata = pop();
    library.addFields(metadata, modifiers, type, namesOffsetsAndInitializers);
    checkEmpty(beginToken.charOffset);
  }

  @override
  void endFields(
      int count, Token covariantToken, Token beginToken, Token endToken) {
    debugEvent("Fields");
    List namesOffsetsAndInitializers = popList(count * 4);
    TypeBuilder type = pop();
    int modifiers = Modifier.validate(pop());
    List<MetadataBuilder> metadata = pop();
    library.addFields(metadata, modifiers, type, namesOffsetsAndInitializers);
  }

  @override
  void endTypeVariable(Token token, Token extendsOrSuper) {
    debugEvent("endTypeVariable");
    TypeBuilder bound = pop();
    int charOffset = pop();
    String name = pop();
    // TODO(paulberry): type variable metadata should not be ignored.  See
    // dartbug.com/28981.
    /* List<MetadataBuilder> metadata = */ pop();
    push(library.addTypeVariable(name, bound, charOffset));
  }

  @override
  void endPartOf(Token partKeyword, Token semicolon, bool hasName) {
    debugEvent("endPartOf");
    popCharOffset();
    String containingLibrary = pop();
    List<MetadataBuilder> metadata = pop();
    if (hasName) {
      library.addPartOf(metadata, containingLibrary, null);
    } else {
      library.addPartOf(metadata, null, containingLibrary);
    }
  }

  @override
  void endConstructorReference(
      Token start, Token periodBeforeName, Token endToken) {
    debugEvent("ConstructorReference");
    popIfNotNull(periodBeforeName); // charOffset.
    String suffix = popIfNotNull(periodBeforeName);
    List<TypeBuilder> typeArguments = pop();
    int charOffset = pop();
    String name = pop();
    push(library.addConstructorReference(
        name, typeArguments, suffix, charOffset));
  }

  @override
  void beginFactoryMethod(Token token) {
    library.beginNestedDeclaration(null, hasMembers: false);
  }

  @override
  void endFactoryMethod(
      Token beginToken, Token factoryKeyword, Token endToken) {
    debugEvent("FactoryMethod");
    MethodBody kind = pop();
    ConstructorReferenceBuilder redirectionTarget;
    if (kind == MethodBody.RedirectingFactoryBody) {
      redirectionTarget = pop();
    }
    AsyncMarker asyncModifier = pop();
    List<FormalParameterBuilder> formals = pop();
    int formalsOffset = pop();
    var name = pop();
    int modifiers = Modifier.validate(pop());
    List<MetadataBuilder> metadata = pop();
    library.addFactoryMethod(
        metadata,
        modifiers,
        name,
        formals,
        asyncModifier,
        redirectionTarget,
        factoryKeyword.next.charOffset,
        formalsOffset,
        endToken.charOffset,
        nativeMethodName);
    nativeMethodName = null;
  }

  @override
  void endRedirectingFactoryBody(Token beginToken, Token endToken) {
    debugEvent("RedirectingFactoryBody");
    push(MethodBody.RedirectingFactoryBody);
  }

  @override
  void endFieldInitializer(Token assignmentOperator, Token token) {
    debugEvent("FieldInitializer");
    push(assignmentOperator.next);
    push(token);
  }

  @override
  void handleNoFieldInitializer(Token token) {
    debugEvent("NoFieldInitializer");
    push(NullValue.FieldInitializer);
    push(NullValue.FieldInitializer);
  }

  @override
  void endInitializers(int count, Token beginToken, Token endToken) {
    debugEvent("Initializers");
    // Ignored for now.
  }

  @override
  void handleNoInitializers() {
    debugEvent("NoInitializers");
    // This is a constructor initializer and it's ignored for now.
  }

  @override
  void endMember() {
    debugEvent("Member");
    assert(nativeMethodName == null);
  }

  @override
  void endClassBody(int memberCount, Token beginToken, Token endToken) {
    debugEvent("ClassBody");
  }

  @override
  void handleAsyncModifier(Token asyncToken, Token starToken) {
    debugEvent("AsyncModifier");
    push(asyncMarkerFromTokens(asyncToken, starToken));
  }

  @override
  void handleModifier(Token token) {
    debugEvent("Modifier");
    push(new Modifier.fromString(token.stringValue));
  }

  @override
  void handleModifiers(int count) {
    debugEvent("Modifiers");
    push(popList(count) ?? NullValue.Modifiers);
  }

  @override
  Token handleUnrecoverableError(Token token, FastaMessage message) {
    if (isDartLibrary && message.code == codeExpectedBlockToSkip) {
      Token recover = skipNativeClause(token);
      if (recover != null) {
        nativeMethodName = unescapeString(token.next.lexeme);
        return recover;
      }
    }
    return super.handleUnrecoverableError(token, message);
  }

  @override
  Link<Token> handleMemberName(Link<Token> identifiers) {
    if (!isDartLibrary || identifiers.isEmpty) return identifiers;
    return removeNativeClause(identifiers);
  }

  @override
  void debugEvent(String name) {
    // printEvent(name);
  }
}
