import AppKit

/// `Chipng --cli <input.png> <output.png> [--no-compress]`
///
/// Headless processing, handy for scripts and for testing the pipeline.
enum CommandLineMode {
    static func run(_ arguments: [String]) -> Never {
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: Chipng --cli <input.png> <output.png> [--no-compress]\n".utf8))
            exit(64)
        }
        let compress = !arguments.contains("--no-compress")

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let source = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
                let start = Date()
                let result = try await ImageProcessor.process(source, compress: compress)
                try result.data.write(to: URL(fileURLWithPath: arguments[1]))
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                print("\(arguments[0]): \(source.count) -> \(result.data.count) bytes, \(result.width)x\(result.height), \(result.method), \(ms) ms")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        app.run()
        exit(0)
    }
}
