//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_implementationOnly import struct Foundation.Data

import TSCBasic

public enum ManifestSignatureParser {
    public static func parse(manifestPath: AbsolutePath, fileSystem: FileSystem) throws -> ManifestSignature? {
        let manifestContents: ByteString
        do {
            manifestContents = try fileSystem.readFileContents(manifestPath)
        } catch {
            throw Error.inaccessibleManifest(path: manifestPath, reason: String(describing: error))
        }

        // FIXME: This is doubly inefficient.
        // `contents`'s value comes from `FileSystem.readFileContents(_)`, which is [inefficient](https://github.com/apple/swift-tools-support-core/blob/8f9838e5d4fefa0e12267a1ff87d67c40c6d4214/Sources/TSCBasic/FileSystem.swift#L167). Calling `ByteString.validDescription` on `contents` is also [inefficient, and possibly incorrect](https://github.com/apple/swift-tools-support-core/blob/8f9838e5d4fefa0e12267a1ff87d67c40c6d4214/Sources/TSCBasic/ByteString.swift#L121). However, this is a one-time thing for each package manifest, and almost necessary in order to work with all Unicode line-terminators. We probably can improve its efficiency and correctness by using `URL` for the file's path, and get is content via `Foundation.String(contentsOf:encoding:)`. Swift System's [`FilePath`](https://github.com/apple/swift-system/blob/8ffa04c0a0592e6f4f9c30926dedd8fa1c5371f9/Sources/System/FilePath.swift) and friends might help as well.
        // This is source-breaking.
        // A manifest that has an [invalid byte sequence](https://en.wikipedia.org/wiki/UTF-8#Invalid_sequences_and_error_handling) (such as `0x7F8F`) after the tools version specification line could work in Swift < 5.4, but results in an error since Swift 5.4.
        guard let manifestContentsDecodedWithUTF8 = manifestContents.validDescription else {
            throw Error.nonUTF8EncodedManifest(path: manifestPath)
        }

        guard !manifestContentsDecodedWithUTF8.isEmpty else {
            throw ManifestParseError.emptyManifest(path: manifestPath)
        }

        return try self.parse(utf8String: manifestContentsDecodedWithUTF8)
    }
    
    public static func parse(utf8String: String) throws -> ManifestSignature? {
        let manifestComponents = Self.split(utf8String)

        guard let signatureComponents = manifestComponents.signatureComponents else {
            return .none
        }

        guard let signature = Data(base64Encoded: String(signatureComponents.signatureBase64Encoded)) else {
            throw Error.malformedManifestSignature
        }
        
        return ManifestSignature(
            contents: Array(String(manifestComponents.contentsBeforeSignatureComponents).utf8),
            signatureFormat: String(signatureComponents.signatureFormat),
            signature: Array(signature)
        )
    }
    
    /// Splits the given manifest into its constituent components.
    ///
    /// A **signed** manifest consists of the following parts:
    ///
    ///                                                    ⎫
    ///                                                    ┇
    ///                                                    ⎬ manifest's contents, including Swift tools version specification
    ///                                                    ┇
    ///                                                    ⎭
    ///       ┌ manifest signature
    ///       ⌄~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ///       //  signature:  cms-1.0.0;MIIFujCCBKKgAw...  } the manifest signature line
    ///     ⌃~⌃~⌃~⌃~~~~~~~~~⌃~⌃~~~~~~~~^^~~~~~~~~~~~~~~~~
    ///     | | | |         | |        |└ signature base64-encoded
    ///     | │ │ └ label   │ |        └ signature format terminator (not returned by this function)
    ///     | | |           | └ signature format
    ///     | │ └ spacing   └ spacing
    ///     | └ comment marker
    ///     └ additional leading whitespace
    ///
    /// - Note: The splitting mostly assumes that the manifest is well-formed. A malformed component may lead to incorrect identification of other components.
    /// - Parameter manifest: The UTF-8-encoded content of the manifest.
    /// - Returns: The components of the given manifest.
    public static func split(_ manifest: String) -> ManifestComponents {
        // The signature, if any, is the last line in the manifest.
        let endIndexOfSignatureLine = manifest.lastIndex(where: { !$0.isWhitespace }) ?? manifest.endIndex
        let endIndexOfManifestContents = manifest[..<endIndexOfSignatureLine].lastIndex(where: { $0.isNewline }) ?? manifest.endIndex
        let startIndexOfCommentMarker = manifest[endIndexOfManifestContents...].firstIndex(where: { $0 == "/" }) ?? manifest.endIndex
        
        // There doesn't seem to be a signature, return manifest as-is.
        guard startIndexOfCommentMarker < endIndexOfSignatureLine else {
            return ManifestComponents(contentsBeforeSignatureComponents: manifest[...], signatureComponents: .none)
        }

        let endIndexOfCommentMarker = manifest[startIndexOfCommentMarker...].firstIndex(where: { $0 != "/" }) ?? manifest.endIndex
        
        let startIndexOfLabel = manifest[endIndexOfCommentMarker...].firstIndex(where: { !$0.isWhitespace }) ?? manifest.endIndex
        let endIndexOfLabel = manifest[startIndexOfLabel...].firstIndex(where: { $0 == ":" }) ?? manifest.endIndex
        
        // Missing "signature:" label, assume there is no signature.
        guard startIndexOfLabel < endIndexOfLabel,
              String(manifest[startIndexOfLabel..<endIndexOfLabel]).lowercased() == "signature" else {
            return ManifestComponents(contentsBeforeSignatureComponents: manifest[...], signatureComponents: .none)
        }

        let startIndexOfSignatureFormat = manifest[endIndexOfLabel...].firstIndex(where: { $0 != ":" && !$0.isWhitespace }) ?? manifest.endIndex
        let endIndexOfSignatureFormat = manifest[startIndexOfSignatureFormat...].firstIndex(where: { $0 == ";" }) ?? manifest.endIndex
        
        // Missing signature format, assume there is no signature.
        guard startIndexOfSignatureFormat < endIndexOfSignatureFormat else {
            return ManifestComponents(contentsBeforeSignatureComponents: manifest[...], signatureComponents: .none)
        }
        
        let startIndexOfSignatureBase64Encoded = manifest[endIndexOfSignatureFormat...].firstIndex(where: { $0 != ";" }) ?? manifest.endIndex

        // Missing base64-encoded signature, assume there is no signature.
        guard startIndexOfSignatureBase64Encoded < endIndexOfSignatureLine else {
            return ManifestComponents(contentsBeforeSignatureComponents: manifest[...], signatureComponents: .none)
        }

        return ManifestComponents(
            contentsBeforeSignatureComponents: manifest[..<endIndexOfManifestContents],
            signatureComponents: SignatureComponents(
                signatureFormat: manifest[startIndexOfSignatureFormat..<endIndexOfSignatureFormat],
                signatureBase64Encoded: manifest[startIndexOfSignatureBase64Encoded...endIndexOfSignatureLine]
            )
        )
    }
    
    public struct ManifestSignature {
        public let contents: [UInt8]
        public let signatureFormat: String
        public let signature: [UInt8]
    }
    
    public enum Error: Swift.Error {
        /// Package manifest file is inaccessible (missing, unreadable, etc).
        case inaccessibleManifest(path: AbsolutePath, reason: String)
        /// Package manifest file's content can not be decoded as a UTF-8 string.
        case nonUTF8EncodedManifest(path: AbsolutePath)
        /// Malformed manifest signature.
        case malformedManifestSignature
    }
}

extension ManifestSignatureParser {
    /// A representation of a manifest in its constituent parts.
    public struct ManifestComponents {
        /// The contents of the manifest up to the signature line.
        /// A manifest doesn't have to be signed so this can be the entire manifest contents.
        public let contentsBeforeSignatureComponents: Substring
        /// The manifest signature (if any) represented in its constituent parts.
        public let signatureComponents: SignatureComponents?

    }

    /// A representation of manifest signature in its constituent parts.
    ///
    /// A manifest signature consists of the following parts:
    ///
    ///     //  signature:  cms-1.0.0;MIIFujCCBKKgAwIBAgIBATANBgkqhkiG9w0BAQUFAD...
    ///     ⌃~⌃~⌃~~~~~~~~~⌃~⌃~~~~~~~~^^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ///     | | |         | |        |└ signature base64-encoded
    ///     │ │ └ label   │ |        └ signature format terminator (not returned by this function)
    ///     | |           | └ signature format
    ///     │ └ spacing   └ spacing
    ///     └ comment marker
    ///
    public struct SignatureComponents {
        /*
        /// The comment marker.
        ///
        /// In a well-formed manifest signature, the comment marker is `"//"`.
        public let commentMarker: Substring

        /// The spacing after the comment marker.
        ///
        /// In a well-formed manifest signature, the spacing after the comment marker is a continuous sequence of horizontal whitespace characters.
        public let spacingAfterCommentMarker: Substring

        /// The label part of the manifest signature.
        ///
        /// In a well-formed manifest signature, the label is `"signature:"`
        public let label: Substring

        /// The spacing between the label part and the signature part of the manifest signature.
        ///
        /// In a well-formed manifest signature, the spacing after the label is a continuous sequence of horizontal whitespace characters.
        public let spacingAfterLabel: Substring
         */

        /// The signature format.
        public let signatureFormat: Substring
        
        /// The base64-encoded signature.
        public let signatureBase64Encoded: Substring
    }
}