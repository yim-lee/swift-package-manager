/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Foundation

@testable import PackageCollectionsSigning
import TSCBasic

func readPEM(path: AbsolutePath) throws -> String {
    let data = try localFileSystem.readFileContents(path).contents
    return String(decoding: data, as: UTF8.self)
}

struct TestCertificatePolicy: CertificatePolicy {
    static let testCertValidDate: Date = {
        var dateComponents = DateComponents()
        dateComponents.year = 2020
        dateComponents.month = 11
        dateComponents.day = 16
        return Calendar.current.date(from: dateComponents)!
    }()

    static let testCertInvalidDate: Date = {
        var dateComponents = DateComponents()
        dateComponents.year = 2000
        dateComponents.month = 11
        dateComponents.day = 16
        return Calendar.current.date(from: dateComponents)!
    }()

    let anchorCerts: [Certificate]?
    let verifyDate: Date

    let queue: DispatchQueue

    init(anchorCerts: [Certificate]? = nil, verifyDate: Date = Self.testCertValidDate, queue: DispatchQueue = DispatchQueue.global()) {
        self.anchorCerts = anchorCerts
        self.verifyDate = verifyDate
        self.queue = queue
    }

    func validate(certChain: [Certificate], callback: @escaping (Result<Bool, Error>) -> Void) {
        do {
            guard try self.hasExtendedKeyUsage(.codeSigning, in: certChain[0]) else {
                return callback(.success(false))
            }
            self.verify(certChain: certChain, anchorCerts: self.anchorCerts, verifyDate: self.verifyDate, queue: self.queue, callback: callback)
        } catch {
            return callback(.failure(error))
        }
    }
}
