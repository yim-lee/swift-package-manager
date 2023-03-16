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

import ArgumentParser
import Basics
import CoreCommands
import PackageSigning
import TSCBasic
@_implementationOnly import X509 // FIXME: need this import or else SwiftSigningIdentity init at L139 fails

import struct Foundation.Data

extension SwiftPackageRegistryTool {
    struct Sign: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sign a package source archive"
        )

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        @Argument(help: .init("The path to the package source archive to be signed.", valueName: "archive-path"))
        var sourceArchivePath: AbsolutePath

        @Argument(help: .init(
            "The path the output signature file will be written to.",
            valueName: "signature-output-path"
        ))
        var signaturePath: AbsolutePath

        @Option(help: .hidden) // help: "Signature format identifier. Defaults to 'cms-1.0.0'.
        var signatureFormat: SignatureFormat = .cms_1_0_0

        @Option(
            help: "The label of the signing identity to be retrieved from the system's identity store if supported."
        )
        var signingIdentity: String?

        @Option(help: "The path to the certificate's PKCS#8 private key (DER-encoded).")
        var privateKeyPath: AbsolutePath?

        @Option(
            name: .customLong("cert-chain-paths"),
            parsing: .upToNextOption,
            help: "Path(s) to the signing certificate (DER-encoded) and optionally the rest of the certificate chain. Certificates should be ordered with the leaf first and the root last."
        )
        var certificateChainPaths: [AbsolutePath] = []

        func run(_ swiftTool: SwiftTool) throws {
            // Validate source archive path
            guard localFileSystem.exists(self.sourceArchivePath) else {
                throw StringError("Source archive not found at '\(self.sourceArchivePath)'.")
            }

            // compute signing mode
            let signingMode: PackageArchiveSigner.SigningMode
            switch (self.signingIdentity, self.certificateChainPaths, self.privateKeyPath) {
            case (.none, let certChainPaths, .none) where !certChainPaths.isEmpty:
                throw StringError(
                    "Both 'private-key-path' and 'cert-chain-paths' are required when one of them is set."
                )
            case (.none, let certChainPaths, .some) where certChainPaths.isEmpty:
                throw StringError(
                    "Both 'private-key-path' and 'cert-chain-paths' are required when one of them is set."
                )
            case (.none, let certChainPaths, .some(let privateKeyPath)) where !certChainPaths.isEmpty:
                let certificate = certChainPaths[0]
                let intermediateCertificates = certChainPaths.count > 1 ? Array(certChainPaths[1...]) : []
                signingMode = .certificate(
                    certificate: certificate,
                    intermediateCertificates: intermediateCertificates,
                    privateKey: privateKeyPath
                )
            case (.some(let signingStoreLabel), let certChainPaths, .none) where certChainPaths.isEmpty:
                signingMode = .identityStore(label: signingStoreLabel, intermediateCertificates: certChainPaths)
            default:
                throw StringError(
                    "Either 'signing-identity' or 'private-key-path' (together with 'cert-chain-paths') must be provided."
                )
            }

            swiftTool.observabilityScope.emit(info: "signing the archive at '\(self.sourceArchivePath)'")
            try PackageArchiveSigner.sign(
                archivePath: self.sourceArchivePath,
                signaturePath: self.signaturePath,
                mode: signingMode,
                signatureFormat: self.signatureFormat,
                fileSystem: localFileSystem,
                observabilityScope: swiftTool.observabilityScope
            )
        }
    }
}

extension SignatureFormat: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

public enum PackageArchiveSigner {
    @discardableResult
    public static func sign(
        archivePath: AbsolutePath,
        signaturePath: AbsolutePath,
        mode: SigningMode,
        signatureFormat: SignatureFormat,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> [UInt8] {
        let archive = try fileSystem.readFileContents(archivePath).contents
        return try Self.sign(
            content: archive,
            signaturePath: signaturePath,
            mode: mode,
            signatureFormat: signatureFormat,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
    }
    
    @discardableResult
    public static func sign(
        manifestPath: AbsolutePath,
        signedManifestPath: AbsolutePath,
        mode: SigningMode,
        signatureFormat: SignatureFormat,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> [UInt8] {
        var manifest = try fileSystem.readFileContents(manifestPath).contents
        let signature = try Self.sign(
            content: manifest,
            signaturePath: .none,
            mode: mode,
            signatureFormat: signatureFormat,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope
        )
        manifest.append(contentsOf: Array("\n// signature: \(signatureFormat.rawValue);\(Data(signature).base64EncodedString())".utf8))

        try fileSystem.writeFileContents(signedManifestPath) { stream in
            stream.write(manifest)
        }
        
        return signature
    }

    private static func sign(
        content: [UInt8],
        signaturePath: AbsolutePath?,
        mode: SigningMode,
        signatureFormat: SignatureFormat,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> [UInt8] {
        let signingIdentity: SigningIdentity
        let intermediateCertificates: [[UInt8]]
        switch mode {
        case .identityStore(let label, let intermediateCertPaths):
            let signingIdentityStore = SigningIdentityStore(observabilityScope: observabilityScope)
            let matches = signingIdentityStore.find(by: label)
            guard let identity = matches.first else {
                throw StringError("'\(label)' not found in the system identity store.")
            }
            // TODO: let user choose if there is more than one match?
            signingIdentity = identity
            intermediateCertificates = try intermediateCertPaths.map { try fileSystem.readFileContents($0).contents }
        case .certificate(let certPath, let intermediateCertPaths, let privateKeyPath):
            let certificate = try fileSystem.readFileContents(certPath).contents
            let privateKey = try fileSystem.readFileContents(privateKeyPath).contents
            signingIdentity = try SwiftSigningIdentity(
                derEncodedCertificate: certificate,
                derEncodedPrivateKey: privateKey,
                privateKeyType: signatureFormat.signingKeyType
            )
            intermediateCertificates = try intermediateCertPaths.map { try fileSystem.readFileContents($0).contents }
        }

        let signature = try SignatureProvider.sign(
            content: content,
            identity: signingIdentity,
            intermediateCertificates: intermediateCertificates,
            format: signatureFormat,
            observabilityScope: observabilityScope
        )

        if let signaturePath = signaturePath {
            try fileSystem.writeFileContents(signaturePath) { stream in
                stream.write(signature)
            }
        }

        return signature
    }

    public enum SigningMode {
        case identityStore(label: String, intermediateCertificates: [AbsolutePath])
        case certificate(certificate: AbsolutePath, intermediateCertificates: [AbsolutePath], privateKey: AbsolutePath)
    }
}
