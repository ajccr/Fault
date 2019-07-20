import Foundation

extension String {
    func sh() -> Int {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["sh", "-c", self]
        task.launch()
        task.waitUntilExit()
        return Int(task.terminationStatus)
    }
    
    func shOutput() -> (terminationStatus: Int32, output: String) {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["sh", "-c", self]

        let pipe = Pipe()
        task.standardOutput = pipe

        task.launch()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)

        return (terminationStatus: task.terminationStatus, output: output!)
    }

    func uniqueName(_ number: Int) -> String {
        return "__" + self + "_" + String(describing: number) + "__"
    }
}

extension String: Error {}

extension Encodable {
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(self)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

extension String {
    static var boilerplate: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = Date()
        let dateString = dateFormatter.string(from: date)

        return  """
        /*
            Automatically generated by Fault
            Do not modify.
            Generated on: \(dateString)
        */
        """;
    }
}