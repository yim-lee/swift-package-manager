# This source file is part of the Swift open source project
#
# Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackageModelSyntax
  AddPackageDependency.swift
  AddProduct.swift
  AddTarget.swift
  ManifestEditError.swift
  ManifestSyntaxRepresentable.swift
  PackageDependency+Syntax.swift
  PackageEditResult.swift
  ProductDescription+Syntax.swift
  SyntaxEditUtils.swift
  TargetDescription+Syntax.swift
)

target_link_libraries(PackageModelSyntax PUBLIC
  Basics
  PackageLoading
  PackageModel

  SwiftBasicFormat
  SwiftDiagnostics
  SwiftIDEUtils
  SwiftParser
  SwiftSyntax
  SwiftSyntaxBuilder
)

# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(PackageModelSyntax PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

install(TARGETS PackageModelSyntax
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS PackageModelSyntax)

set(SWIFT_SYNTAX_MODULES
  SwiftBasicFormat
  SwiftParser
  SwiftParserDiagnostics
  SwiftDiagnostics
  SwiftSyntax
  SwiftSyntaxBuilder
  SwiftIDEUtils
)
export(TARGETS ${SWIFT_SYNTAX_MODULES}
       NAMESPACE SPMSwiftSyntax::
       FILE ${CMAKE_BINARY_DIR}/cmake/modules/SwiftSyntaxConfig.cmake
       EXPORT_LINK_INTERFACE_LIBRARIES)