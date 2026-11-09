import Foundation

/// One <d:response> from a WebDAV multistatus, with only the 200-OK props.
struct DAVResponse {
    var href: String
    var props: [String: String] = [:]
    var isCollection = false
}

/// Minimal namespace-aware multistatus parser.
final class DAVParser: NSObject, XMLParserDelegate {
    private var responses: [DAVResponse] = []
    private var current: DAVResponse?
    private var pendingProps: [String: String] = [:]
    private var pendingCollection = false
    private var text = ""
    private var inProp = false
    private var inResourceType = false
    private var status = ""

    static func parse(_ data: Data) -> [DAVResponse] {
        let p = DAVParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = p
        xml.parse()
        return p.responses
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "response": current = DAVResponse(href: "")
        case "propstat": pendingProps = [:]; pendingCollection = false; status = ""
        case "prop": inProp = true
        case "resourcetype": inResourceType = true
        case "collection" where inResourceType: pendingCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "href" where !inProp:
            current?.href = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "status":
            status = text
        case "resourcetype":
            inResourceType = false
        case "prop":
            inProp = false
        case "propstat":
            if status.contains(" 200") {
                current?.props.merge(pendingProps) { $1 }
                if pendingCollection { current?.isCollection = true }
            }
        case "response":
            if let c = current { responses.append(c) }
            current = nil
        default:
            if inProp && !inResourceType {
                pendingProps[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        text = ""
    }
}

enum HTTPDate {
    private static let formatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z"].map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = $0
            return f
        }
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return ISO8601DateFormatter().date(from: s)
    }
}
