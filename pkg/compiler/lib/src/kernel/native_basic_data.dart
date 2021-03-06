// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// TODO(johnniwinther): Make this a separate library.
part of dart2js.kernel.element_map;

class KernelAnnotationProcessor implements AnnotationProcessor {
  final KernelToElementMap elementMap;

  KernelAnnotationProcessor(this.elementMap);

  void extractNativeAnnotations(
      LibraryEntity library, NativeBasicDataBuilder nativeBasicDataBuilder) {
    ElementEnvironment elementEnvironment = elementMap.elementEnvironment;
    CommonElements commonElements = elementMap.commonElements;

    elementEnvironment.forEachClass(library, (ClassEntity cls) {
      String annotationName;
      // TODO(johnniwinther): Make [_getClassMetadata] public and at test to
      // guard against misuse.
      for (ConstantExpression annotation in elementMap._getClassMetadata(cls)) {
        ConstantValue value =
            elementMap.constantEnvironment.getConstantValue(annotation);
        String name = readAnnotationName(
            cls, value, commonElements.nativeAnnotationClass);
        if (annotationName == null) {
          annotationName = name;
        } else if (name != null) {
          throw new SpannableAssertionFailure(
              cls, 'Too many name annotations.');
        }
      }
      if (annotationName != null) {
        nativeBasicDataBuilder.setNativeClassTagInfo(cls, annotationName);
      }
    });
  }

  void extractJsInteropAnnotations(
      LibraryEntity library, NativeBasicDataBuilder nativeBasicDataBuilder) {
    throw new UnimplementedError(
        'KernelAnnotationProcessor.extractJsInteropAnnotations');
  }
}
