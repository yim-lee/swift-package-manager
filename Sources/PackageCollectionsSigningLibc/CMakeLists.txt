# This source file is part of the Swift.org open source project
#
# Copyright (c) 2021 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for Swift project authors

add_library(PackageCollectionsSigningLibc STATIC
)

target_include_directories(PackageCollectionsSigningLibc PUBLIC
  include)

target_compile_definitions(CCryptoBoringSSL PRIVATE
  $<$<PLATFORM_ID:Windows>:WIN32_LEAN_AND_MEAN>)
set_target_properties(PackageCollectionsSigningLibc PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS PackageCollectionsSigningLibc)
