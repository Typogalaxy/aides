import AidesCore
import Foundation

enum CloudBoundary {
    static func validate(_ text: String) throws {
        let knownCredentialFormats = [
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"\b(?:sk-(?:proj-|ant-)?|ghp_|github_pat_|xox[baprs]-)[a-zA-Z0-9_-]{20,}\b"#,
            #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#
        ]
        for pattern in knownCredentialFormats {
            if text.range(of: pattern, options: .regularExpression) != nil {
                throw StorageError("Possible credential in the approved material. Remove it or use a local model.")
            }
        }
    }
}
