import Foundation

public enum DAVParserError: Error, Equatable {
    case malformedXML
}

/// Parses a WebDAV `207 Multistatus` body into items, in document order
/// (index 0 is the requested resource). Only `propstat` blocks with status 200 are read.
public enum DAVParser {
    public static func parse(_ data: Data) throws -> [RemoteItem] {
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = handler
        guard parser.parse() else { throw parser.parserError ?? DAVParserError.malformedXML }
        return handler.items
    }
}

private final class Handler: NSObject, XMLParserDelegate {
    private static let dav = "DAV:"

    private(set) var items: [RemoteItem] = []

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    // Parser position.
    private var depth = 0
    private var propDepth: Int?          // depth of the <prop> element we are inside
    private var key: String?             // property being read (a direct child of <prop>)
    private var text = ""

    // Current <response>.
    private var href = ""
    private var props: [String: String] = [:]
    private var isFolder = false

    // Current <propstat>, merged into the response only when its status is 200.
    private var stat: [String: String] = [:]
    private var statIsFolder = false
    private var statOK = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        let isDAV = namespaceURI == Self.dav
        switch name {
        case "response" where isDAV:
            href = ""; props = [:]; isFolder = false
        case "propstat" where isDAV:
            stat = [:]; statIsFolder = false; statOK = false
        case "prop" where isDAV && propDepth == nil:
            propDepth = depth
        case "collection" where isDAV && key == "resourcetype":
            statIsFolder = true
        default:
            if let p = propDepth, depth == p + 1 { key = name }
        }
        if key != nil || name == "href" || name == "status" { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        defer { depth -= 1 }
        let isDAV = namespaceURI == Self.dav
        if let p = propDepth, depth == p + 1, let k = key {
            stat[k] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            key = nil
            return
        }
        switch name {
        case "href" where isDAV: href = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "status" where isDAV: statOK = text.contains(" 200")
        case "prop" where isDAV && propDepth == depth: propDepth = nil
        case "propstat" where isDAV && statOK:
            props.merge(stat) { current, _ in current }
            isFolder = isFolder || statIsFolder
        case "response" where isDAV: finishResponse()
        default: break
        }
    }

    private func finishResponse() {
        guard let id = props["fileid"], !id.isEmpty else { return }
        let size = props["size"].flatMap { Int64($0) } ?? props["getcontentlength"].flatMap { Int64($0) } ?? 0
        items.append(RemoteItem(
            id: id,
            parentId: props["file-parent"].flatMap { $0.isEmpty ? nil : $0 },
            name: props["name"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.name(fromHref: href),
            isFolder: isFolder,
            etag: ETag.normalize(props["getetag"] ?? ""),
            size: size,
            modified: props["getlastmodified"].flatMap { dateFormatter.date(from: $0) },
            contentType: props["getcontenttype"].flatMap { $0.isEmpty ? nil : $0 },
            permissions: ItemPermissions(ocString: props["permissions"] ?? "")))
    }

    /// Fallback when the server sends no `oc:name`. An id-addressed resource has the id as its last
    /// path segment, so the href is only a reliable source for path-addressed listings.
    /// Last path segment of the href, percent-decoded. `+` stays a plus.
    private static func name(fromHref href: String) -> String {
        var path = Substring(href)
        while path.hasSuffix("/") { path = path.dropLast() }
        let last = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return last.removingPercentEncoding ?? last
    }
}
