import Foundation
import IlmekKit

enum AppLinks {
    static let privacy = URL(string: "https://sites.google.com/view/ilmek-app")!
    static let contactEmail = "ilmek.uygulama@gmail.com"
    /// Pre-filled email reporting a group member (guideline 1.2). Includes what we show of them.
    static func report(_ status: FriendStatus, groupCode: String?) -> URL? {
        var body = "Bildirilen kişi / Reported user: \(status.nickname)\nID: \(status.userID)\n"
        if let groupCode { body += "Grup / Group: \(GroupCode.display(groupCode))\n" }
        body += "Alışkanlıklar / Habits: \(status.habits.map(\.name).joined(separator: ", "))\n\n"
        body += "Neden / Reason:\n"
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = contactEmail
        c.queryItems = [URLQueryItem(name: "subject", value: "İlmek: kullanıcı bildirimi / user report"),
                        URLQueryItem(name: "body", value: body)]
        return c.url
    }

    static var feedback: URL {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let subject = "İlmek \(v) (\(b))".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(contactEmail)?subject=\(subject)") ?? URL(string: "mailto:\(contactEmail)")!
    }
}
