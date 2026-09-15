import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Tray's "Convert to" and "Zip" actions. Results are written to the given folder.
enum FileTools {
    enum ImageFormat: String, CaseIterable {
        case jpeg, png, heic

        var title: String { rawValue.uppercased() }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var type: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .heic: return .heic
            }
        }

        func matches(_ url: URL) -> Bool {
            UTType(filenameExtension: url.pathExtension)?.conforms(to: type) == true
        }
    }

    enum Failure: LocalizedError {
        case unreadable(String), unwritable(String), zip(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Couldn't read \(name) as an image"
            case .unwritable(let name): return "Couldn't save \(name)"
            case .zip(let message): return message
            }
        }
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// Re-encodes the image, keeping its metadata (orientation, colour profile, capture date).
    static func convert(_ url: URL, to format: ImageFormat, in folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destinationURL = unique(in: folder, name: url.deletingPathExtension().lastPathComponent,
                                    ext: format.fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL,
                                                                format.type.identifier as CFString, 1, nil) else {
            throw Failure.unwritable(destinationURL.lastPathComponent)
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImageFromSource(destination, source, 0, options)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable(destinationURL.lastPathComponent) }
        return destinationURL
    }

    /// One file or folder → "Name.zip"; several → "Archive.zip". Made with ditto, like Finder's Compress.
    static func zip(_ urls: [URL], in folder: URL) async throws -> URL {
        guard !urls.isEmpty else { throw Failure.zip("Nothing to zip") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var staging: URL?
                defer { if let staging { try? fm.removeItem(at: staging.deletingLastPathComponent()) } }
                do {
                    let source: URL
                    let name: String
                    if urls.count == 1 {
                        source = urls[0]
                        name = urls[0].deletingPathExtension().lastPathComponent
                    } else {
                        // Gather copies (APFS clones, so no extra space) into one "Archive" folder.
                        let holder = fm.temporaryDirectory.appendingPathComponent("NotchNest-zip-\(UUID().uuidString)")
                        let folder = holder.appendingPathComponent("Archive")
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                        staging = folder
                        for url in urls {
                            try fm.copyItem(at: url, to: unique(in: folder, name: url.deletingPathExtension().lastPathComponent,
                                                                ext: url.pathExtension))
                        }
                        source = folder
                        name = "Archive"
                    }
                    let destination = unique(in: folder, name: name, ext: "zip")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    // A folder goes in under its own name; a single file goes in on its own
                    // (--keepParent on a file would add the folder it sits in).
                    var isFolder: ObjCBool = false
                    fm.fileExists(atPath: source.path, isDirectory: &isFolder)
                    process.arguments = ["-c", "-k", "--sequesterRsrc"] + (isFolder.boolValue ? ["--keepParent"] : [])
                        + [source.path, destination.path]
                    let errors = Pipe()
                    process.standardError = errors
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        throw Failure.zip(message.isEmpty ? "Zip failed" : message)
                    }
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// "Name.ext", or "Name 2.ext" and so on if that's taken.
    static func unique(in folder: URL, name: String, ext: String) -> URL {
        func candidate(_ suffix: String) -> URL {
            let file = name + suffix
            return folder.appendingPathComponent(ext.isEmpty ? file : "\(file).\(ext)")
        }
        var url = candidate("")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate(" \(number)")
            number += 1
        }
        return url
    }
}
