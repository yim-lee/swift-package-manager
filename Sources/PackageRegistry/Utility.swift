/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Dispatch

func makeAsync<T>(_ closure: @escaping (Result<T, Error>) -> Void, on queue: DispatchQueue) -> (Result<T, Error>) -> Void {
    { result in queue.async { closure(result) } }
}
