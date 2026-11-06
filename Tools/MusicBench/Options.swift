import Foundation

nonisolated struct Options {
    var dir = ""
    var set = "dev"
    var sweep = ""
    var json: String?

    var validationError: String? {
        guard ["dev", "test", "all"].contains(set) else { return "--set must be dev, test, or all" }
        guard ["", "notes", "voices", "all"].contains(sweep) else { return "--sweep must be notes, voices, or all" }
        if !sweep.isEmpty, set != "dev" {
            return "Parameter sweeps require --set dev; test and all include held-out songs."
        }
        return nil
    }

    var evaluationKind: String {
        switch set {
        case "dev": "development"
        case "test": "held_out"
        default: "exploratory"
        }
    }
}

nonisolated enum OptionsError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let message): message }
    }
}

func parseOptions(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws -> Options {
    var options = Options()
    var args = arguments
    while !args.isEmpty {
        let argument = args.removeFirst()
        switch argument {
        case "--set", "--sweep", "--json":
            guard let value = args.first, !value.hasPrefix("--") else {
                throw OptionsError.invalid("Missing value for \(argument)")
            }
            args.removeFirst()
            switch argument {
            case "--set": options.set = value
            case "--sweep": options.sweep = value
            default: options.json = value
            }
        default:
            guard !argument.hasPrefix("-"), options.dir.isEmpty else {
                throw OptionsError.invalid("Unexpected argument: \(argument)")
            }
            options.dir = argument
        }
    }
    if let error = options.validationError { throw OptionsError.invalid(error) }
    return options
}
