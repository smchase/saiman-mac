import Foundation

final class Config {
    static let shared = Config()

    // Cached AWS credentials from ~/.aws/credentials
    private let awsFileCredentials: AWSCredentials
    private let awsFileRegion: String?

    private init() {
        awsFileCredentials = Self.loadAWSCredentials()
        awsFileRegion = Self.loadAWSConfigRegion()
    }

    // MARK: - AWS Credentials File Parsing

    private struct AWSCredentials {
        let accessKeyId: String?
        let secretAccessKey: String?
        let sessionToken: String?
    }

    private static func loadAWSCredentials(profile: String = "default") -> AWSCredentials {
        let credentialsPath = NSHomeDirectory() + "/.aws/credentials"
        guard let contents = try? String(contentsOfFile: credentialsPath, encoding: .utf8) else {
            return AWSCredentials(accessKeyId: nil, secretAccessKey: nil, sessionToken: nil)
        }

        var accessKey: String?
        var secretKey: String?
        var sessionToken: String?
        var inProfile = false
        let targetProfile = "[\(profile)]"

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") {
                inProfile = trimmed == targetProfile
                continue
            }

            if inProfile {
                let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    switch parts[0] {
                    case "aws_access_key_id": accessKey = parts[1]
                    case "aws_secret_access_key": secretKey = parts[1]
                    case "aws_session_token": sessionToken = parts[1]
                    default: break
                    }
                }
            }
        }

        return AWSCredentials(accessKeyId: accessKey, secretAccessKey: secretKey, sessionToken: sessionToken)
    }

    private static func loadAWSConfigRegion(profile: String = "default") -> String? {
        let configPath = NSHomeDirectory() + "/.aws/config"
        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }

        var region: String?
        var inProfile = false
        let targetProfile = profile == "default" ? "[default]" : "[profile \(profile)]"

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") {
                inProfile = trimmed == targetProfile
                continue
            }

            if inProfile {
                let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 && parts[0] == "region" {
                    region = parts[1]
                }
            }
        }

        return region
    }

    // MARK: - AWS Bedrock Configuration

    var awsAccessKeyId: String {
        ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"]
            ?? awsFileCredentials.accessKeyId
            ?? ""
    }

    var awsSecretAccessKey: String {
        ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"]
            ?? awsFileCredentials.secretAccessKey
            ?? ""
    }

    var awsSessionToken: String? {
        ProcessInfo.processInfo.environment["AWS_SESSION_TOKEN"]
            ?? awsFileCredentials.sessionToken
    }

    var awsRegion: String {
        ProcessInfo.processInfo.environment["AWS_REGION"]
            ?? ProcessInfo.processInfo.environment["AWS_DEFAULT_REGION"]
            ?? awsFileRegion
            ?? "us-east-1"
    }

    var bedrockModelId: String {
        ProcessInfo.processInfo.environment["SAIMAN_BEDROCK_MODEL"]
            ?? "us.anthropic.claude-opus-4-6-v1"
    }

    var bedrockHaikuModelId: String {
        ProcessInfo.processInfo.environment["SAIMAN_BEDROCK_HAIKU_MODEL"]
            ?? "us.anthropic.claude-haiku-4-5-20251001-v1:0"
    }

    // MARK: - Exa Configuration

    var exaApiKey: String {
        ProcessInfo.processInfo.environment["EXA_API_KEY"] ?? ""
    }

    // MARK: - App Configuration

    var staleTimeoutMinutes: Int {
        if let value = ProcessInfo.processInfo.environment["SAIMAN_STALE_TIMEOUT_MINUTES"],
           let minutes = Int(value) {
            return minutes
        }
        return 15
    }

    var maxToolCalls: Int {
        20
    }

    // MARK: - System Prompt

    private lazy var baseSystemPrompt: String = {
        // Try Bundle first (for app)
        if let path = Bundle.main.path(forResource: "system_prompt", ofType: "txt"),
           let content = try? String(contentsOfFile: path, encoding: .utf8) {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try project directory (for CLI tool / tests)
        let projectPaths = [
            FileManager.default.currentDirectoryPath + "/Saiman/Resources/system_prompt.txt",
            FileManager.default.currentDirectoryPath + "/../Saiman/Resources/system_prompt.txt"
        ]
        for path in projectPaths {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        fatalError("system_prompt.txt not found! Ensure it's added to the Xcode project and Copy Bundle Resources phase.")
    }()

    // Cached location from IP lookup
    private(set) var userLocation: String = "Unknown"

    func fetchUserLocation() {
        guard let url = URL(string: "http://ip-api.com/json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let city = json["city"] as? String,
                  let region = json["regionName"] as? String,
                  let country = json["country"] as? String else { return }
            self?.userLocation = "\(city), \(region), \(country)"
        }.resume()
    }

    /// Static system prompt for caching — no dynamic content.
    /// Dynamic context (date/time/location) is prepended to the user's message instead,
    /// so the system prompt prefix stays identical across requests for cache hits.
    var systemPrompt: String {
        baseSystemPrompt
    }

    /// Dynamic context string to prepend to the latest user message.
    func dynamicContext() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let dateTime = formatter.string(from: Date())
        return "[Current date: \(dateTime) | Location: \(userLocation)]"
    }

    // MARK: - Validation

    var isConfigured: Bool {
        !awsAccessKeyId.isEmpty && !awsSecretAccessKey.isEmpty && !exaApiKey.isEmpty
    }

    var missingConfiguration: [String] {
        var missing: [String] = []
        if awsAccessKeyId.isEmpty { missing.append("AWS_ACCESS_KEY_ID (or ~/.aws/credentials)") }
        if awsSecretAccessKey.isEmpty { missing.append("AWS_SECRET_ACCESS_KEY (or ~/.aws/credentials)") }
        if exaApiKey.isEmpty { missing.append("EXA_API_KEY") }
        return missing
    }
}
