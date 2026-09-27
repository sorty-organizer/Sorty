//
//  URLFinderComment.swift
//  SortyFileSystem
//
//  Finder comment read from a file's extended attributes. Lives here so AI
//  prompt builders and scanners can include Finder metadata without
//  depending on SortyCore.
//

import Foundation

extension URL {
    public var finderComment: String? {
        let path = path
        let key = "com.apple.metadata:kMDItemFinderComment"

        let size = getxattr(path, key, nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { buf in
            getxattr(path, key, buf.baseAddress, size, 0, 0)
        }
        guard result > 0 else { return nil }

        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? String
    }
}
