// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_KERNEL_READER_H_
#define RUNTIME_VM_KERNEL_READER_H_

#if !defined(DART_PRECOMPILED_RUNTIME)
#include <map>

#include "vm/kernel.h"
#include "vm/kernel_to_il.h"
#include "vm/object.h"

namespace dart {
namespace kernel {

class KernelReader;

class BuildingTranslationHelper : public TranslationHelper {
 public:
  BuildingTranslationHelper(KernelReader* reader, dart::Thread* thread)
      : TranslationHelper(thread), reader_(reader) {}
  virtual ~BuildingTranslationHelper() {}

  virtual RawLibrary* LookupLibraryByKernelLibrary(CanonicalName* library);
  virtual RawClass* LookupClassByKernelClass(CanonicalName* klass);

 private:
  KernelReader* reader_;
};

template <typename KernelType, typename VmType>
class Mapping {
 public:
  bool Lookup(KernelType* node, VmType** handle) {
    typename MapType::Pair* pair = map_.LookupPair(node);
    if (pair != NULL) {
      *handle = pair->value;
      return true;
    }
    return false;
  }

  void Insert(KernelType* node, VmType* object) { map_.Insert(node, object); }

 private:
  typedef MallocMap<KernelType, VmType*> MapType;
  MapType map_;
};

class KernelReader {
 public:
  explicit KernelReader(Program* program);

  // Returns the library containing the main procedure, null if there
  // was no main procedure, or a failure object if there was an error.
  dart::Object& ReadProgram();

  static void SetupFunctionParameters(TranslationHelper translation_helper_,
                                      DartTypeTranslator type_translator_,
                                      const dart::Class& owner,
                                      const dart::Function& function,
                                      FunctionNode* kernel_function,
                                      bool is_method,
                                      bool is_closure);

  void ReadLibrary(Library* kernel_library);

  const dart::String& DartSymbol(String* str) {
    return translation_helper_.DartSymbol(str);
  }

  uint8_t CharacterAt(String* str, intptr_t index);

 private:
  friend class BuildingTranslationHelper;

  void ReadPreliminaryClass(dart::Class* klass, Class* kernel_klass);
  dart::Class& ReadClass(const dart::Library& library,
                         const dart::Class& toplevel_class,
                         Class* kernel_klass);
  void ReadProcedure(const dart::Library& library,
                     const dart::Class& owner,
                     Procedure* procedure,
                     Class* kernel_klass = NULL);

  RawArray* MakeFunctionsArray();

  // If klass's script is not the script at the uri index, return a PatchClass
  // for klass whose script corresponds to the uri index.
  // Otherwise return klass.
  const Object& ClassForScriptAt(const dart::Class& klass,
                                 intptr_t source_uri_index);
  Script& ScriptAt(intptr_t source_uri_index, String* import_uri = NULL);

  void GenerateFieldAccessors(const dart::Class& klass,
                              const dart::Field& field,
                              Field* kernel_field);

  void SetupFieldAccessorFunction(const dart::Class& klass,
                                  const dart::Function& function);

  dart::Library& LookupLibrary(CanonicalName* library);
  dart::Class& LookupClass(CanonicalName* klass);

  dart::RawFunction::Kind GetFunctionType(Procedure* kernel_procedure);

  Program* program_;

  dart::Thread* thread_;
  dart::Zone* zone_;
  dart::Isolate* isolate_;
  Array& scripts_;
  ActiveClass active_class_;
  BuildingTranslationHelper translation_helper_;
  DartTypeTranslator type_translator_;

  Mapping<CanonicalName, dart::Library> libraries_;
  Mapping<CanonicalName, dart::Class> classes_;

  GrowableArray<const dart::Function*> functions_;
  GrowableArray<const dart::Field*> fields_;
};

}  // namespace kernel
}  // namespace dart

#endif  // !defined(DART_PRECOMPILED_RUNTIME)
#endif  // RUNTIME_VM_KERNEL_READER_H_
