import Foundation

struct ProbeOptions {
    let help: Bool
    let run: Bool
    let profiles: Bool
    let suppression: Bool
    let inputID: UInt32?
    let outputID: UInt32?
    let seconds: Double
    let cycles: Int
    let frames: UInt32
    let gainDB: Float
    let logPath: String?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var arguments = arguments.makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--help", "--run", "--profiles", "--suppression":
                flags.insert(argument)
            case "--input", "--output", "--seconds", "--cycles", "--frames", "--gain", "--log":
                guard let value = arguments.next(), !value.hasPrefix("--") else {
                    throw ArgumentError(message: "Supply a value for \(argument).")
                }
                values[argument] = value
            default:
                throw ArgumentError(message: "Unknown option: \(argument). Use --help for usage.")
            }
        }
        func number<Value: LosslessStringConvertible>(_ option: String, as: Value.Type) throws
            -> Value?
        {
            guard let text = values[option] else { return nil }
            guard let value = Value(text) else {
                throw ArgumentError(message: "Invalid value for \(option): \(text).")
            }
            return value
        }
        let seconds = try number("--seconds", as: Double.self) ?? 10
        let gain = try number("--gain", as: Float.self) ?? -60
        let frames = try number("--frames", as: UInt32.self) ?? 64
        guard seconds.isFinite, gain.isFinite, frames > 0 else {
            throw ArgumentError(message: "Use finite seconds and gain, and a positive frame count.")
        }
        help = flags.contains("--help")
        run = flags.contains("--run")
        profiles = flags.contains("--profiles")
        suppression = flags.contains("--suppression")
        inputID = try number("--input", as: UInt32.self)
        outputID = try number("--output", as: UInt32.self)
        self.seconds = min(max(seconds, 1), 86400)
        cycles = min(max(try number("--cycles", as: Int.self) ?? 1, 1), 1000)
        self.frames = frames
        gainDB = min(max(gain, -60), -12)
        logPath = values["--log"]
    }

    private struct ArgumentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
