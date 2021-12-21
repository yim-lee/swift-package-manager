/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import TSCBasic
import TSCUtility

/// Helper for shelling out to `git`
public struct GitShellHelper {
    /// Reference to process set, if installed.
    private let processSet: ProcessSet?

    public init(processSet: ProcessSet? = nil) {
        self.processSet = processSet
    }

    /// Invokes the Git tool with its default environment and given set of arguments. The specified
    /// failure message is used only in case of error. This function waits for the invocation to finish
    /// and returns the output as a string.
    public func run(_ args: [String], environment: EnvironmentVariables = Git.environment, outputRedirection: Process.OutputRedirection = .collect) throws -> String {
        let process = Process(arguments: [Git.tool] + args, environment: environment, outputRedirection: outputRedirection)
        let result: ProcessResult
        do {
            try self.processSet?.add(process)
            try process.launch()
            result = try process.waitUntilExit()
            guard result.exitStatus == .terminated(code: 0) else {
                throw GitShellError(result: result)
            }
            return try result.utf8Output().spm_chomp()
        } catch let error as GitShellError {
            throw error
        } catch {
            // Handle a failure to even launch the Git tool by synthesizing a result that we can wrap an error around.
            let result = ProcessResult(arguments: process.arguments,
                                       environment: process.environment,
                                       exitStatus: .terminated(code: -1),
                                       output: .failure(error),
                                       stderrOutput: .failure(error))
            throw GitShellError(result: result)
        }
    }
}

public struct GitShellError: Error {
    public let result: ProcessResult
}
