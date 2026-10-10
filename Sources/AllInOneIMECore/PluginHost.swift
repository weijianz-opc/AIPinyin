import Foundation

/// `AllInOneIME --run-plugin <folder>`: the child process a script plugin runs in. The text comes on
/// standard input; the result goes to standard output, an error message to standard error (exit 1).
public enum PluginHost {
    public static func run(directory path: String, appVersion: String = AppVersion.string) -> Int32 {
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return 1
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("plugin.json")),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            return fail("The plugin has no readable plugin.json")
        }
        if let problem = manifest.problem(appVersion: appVersion) { return fail("Plugin \(manifest.name): \(problem)") }
        guard manifest.type == .script, let script = manifest.script,
              let source = try? Data(contentsOf: directory.appendingPathComponent(script)),
              source.count <= PluginManifest.maxScriptBytes else {
            return fail("Plugin \(manifest.name): no script, or larger than \(PluginManifest.maxScriptBytes / 1024) KB")
        }
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let text = try PluginScript.evaluate(source: String(decoding: source, as: UTF8.self), input: input,
                                                 fetcher: URLSessionFetcher(hosts: manifest.hosts))
            FileHandle.standardOutput.write(Data(text.utf8))
            return 0
        } catch {
            return fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}

/// Runs a script plugin: `<executable> --run-plugin <folder>` through `CommandRunner` (timeout, output
/// limit, Esc), with the text on standard input.
public enum PluginRunner {
    /// The program run for `plugin`, as a `run` command.
    public static func command(for plugin: InstalledPlugin, executable: String) -> CustomCommand {
        CustomCommand(name: plugin.name, type: .run, argv: [executable, "--run-plugin", plugin.directory.path],
                      stdin: CustomCommand.placeholder, ascii: plugin.manifest.typesLatin,
                      timeoutSeconds: plugin.manifest.timeout)
    }

    public static func run(_ plugin: InstalledPlugin, input: String,
                           executable: String = Bundle.main.executablePath ?? CommandLine.arguments[0])
        -> AsyncThrowingStream<ConversionUpdate, Error> {
        CommandRunner.run(command(for: plugin, executable: executable), input: input)
    }
}
