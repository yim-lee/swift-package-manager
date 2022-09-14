# This source file is part of the Swift open source project
#
# Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackageCollectionsSigning STATIC
  PackageCollectionSigning.swift)
target_link_libraries(PackageCollectionsSigning PUBLIC
  Basics
  PackageCollectionsModel
  Signing
  $<$<NOT:$<PLATFORM_ID:Darwin>>:dispatch>
  $<$<NOT:$<PLATFORM_ID:Darwin>>:Foundation>)
  
# NOTE(compnerd) workaround for CMake not setting up include flags yet
set_target_properties(PackageCollectionsSigning PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS PackageCollectionsSigning)
