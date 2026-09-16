import Foundation

// ponytail: 两个各约 1 MiB 的本地日志轮转，足够追溯近期故障，无需数据库或常驻服务。
final class DiagnosticLog {
    let directory: URL
    let sizeLimit: Int
    private let dateFormatter = ISO8601DateFormatter()
    var current: URL { directory.appendingPathComponent("运行记录.jsonl") }
    var previous: URL { directory.appendingPathComponent("上次运行记录.jsonl") }

    init(directory: URL, sizeLimit: Int = 1_048_576) {
        self.directory = directory
        self.sizeLimit = sizeLimit
    }

    func append(_ event: RuntimeEvent) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let line = try JSONSerialization.data(withJSONObject: ["时间": dateFormatter.string(from: event.date), "事件": event.message], options: [.sortedKeys]) + Data([10])
        if manager.fileExists(atPath: current.path) {
            let attributes = try manager.attributesOfItem(atPath: current.path)
            if (attributes[.size] as? Int ?? 0) + line.count > sizeLimit {
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: current, to: previous)
            }
        }
        if !manager.fileExists(atPath: current.path) {
            guard manager.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "AutoLock", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建诊断日志文件"])
            }
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func recentEvents(limit: Int = 100) throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for file in [previous, current] where FileManager.default.fileExists(atPath: file.path) {
            let data = try String(contentsOf: file, encoding: .utf8)
            for line in data.split(separator: "\n") {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                      let text = record["事件"], let stamp = record["时间"],
                      let date = dateFormatter.date(from: stamp) else { continue }
                events.append(.init(message: text, date: date))
            }
        }
        return Array(events.suffix(limit).reversed())
    }

    func clear() throws {
        for file in [current, previous] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func export(to destination: URL, summary: [String: Any], events: [RuntimeEvent]) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("AutoLock-诊断-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: staging.appendingPathComponent("版本与状态.json"))
        let text = events.reversed().map { "\(dateFormatter.string(from: $0.date))  \($0.message)" }.joined(separator: "\n")
        try text.write(to: staging.appendingPathComponent("最近事件.txt"), atomically: true, encoding: .utf8)
        for file in [previous, current] where manager.fileExists(atPath: file.path) {
            try manager.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
        }
        let explanation = "这是 AutoLock 本地诊断包，包含版本、系统、功能设置和运行记录，不包含登录密码。设备名称可能出现在事件中。你可以把本包交给维护者或带回 Codex 任务，结合记录中的源码版本继续排查。文件不会自动上传。\n"
        try explanation.write(to: staging.appendingPathComponent("请先阅读.txt"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", staging.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AutoLock", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "诊断包压缩失败，请检查保存位置是否可写"])
        }
    }
}
