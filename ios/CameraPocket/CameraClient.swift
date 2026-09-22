import Foundation

struct CameraPhoto: Identifiable, Hashable {
    let id: String
    let title: String
    let original: URL
    let thumbnail: URL?
    let size: Int64
    let isVideo: Bool
    let mimeType: String
}

struct CameraFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// A small namespace-independent XML tree for UPnP and escaped DIDL-Lite.
final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String: String] = [:]) {
        self.name = name.components(separatedBy: ":").last ?? name
        self.attributes = attributes
    }
    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func value(_ name: String) -> String { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
}

final class CameraXML: NSObject, XMLParserDelegate {
    private var stack: [XMLNode] = []
    private var root: XMLNode?
    static func parse(_ data: Data) throws -> XMLNode {
        let delegate = CameraXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw CameraFailure(message: "The camera returned invalid XML.")
        }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = XMLNode(elementName, attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
}

struct BrowsePage {
    let photos: [CameraPhoto]
    let folders: [String]
    let returned: Int
    let total: Int?
    let signature: String
}

struct CameraClient {
    static let service = "urn:schemas-upnp-org:service:ContentDirectory:1"
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func httpURL(_ value: String, relativeTo base: URL? = nil) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw CameraFailure(message: "The camera rejected the request. Check its Wi-Fi mode and address.")
        }
        return data
    }
    func connect(address: String, directControl: Bool) async throws -> (String, URL) {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let base = Self.httpURL(input.contains("://") ? input : "http://\(input)") else {
            throw CameraFailure(message: "Enter the camera’s IP address or an HTTP URL.")
        }
        if directControl { return ("Samsung camera", base) }
        var candidates: [URL] = []
        if !base.path.isEmpty && base.path != "/" { candidates = [base] }
        else {
            for (port, path) in [(7676, "/smp_6_"), (80, "/description.xml"), (80, "/rootDesc.xml"), (49152, "/description.xml"), (49153, "/description.xml"), (8080, "/description.xml")] {
                var parts = URLComponents(url: base, resolvingAgainstBaseURL: true)!
                parts.port = base.port ?? port
                parts.path = path
                if let url = parts.url, !candidates.contains(url) { candidates.append(url) }
            }
        }
        for url in candidates {
            try Task.checkCancellation()
            do {
                let xml = try CameraXML.parse(await fetch(URLRequest(url: url, timeoutInterval: 5)))
                let urlBase = Self.httpURL(xml.value("URLBase")) ?? url
                for service in xml.descendants("service") where service.value("serviceType").contains("ContentDirectory") {
                    if let control = Self.httpURL(service.value("controlURL"), relativeTo: urlBase) {
                        return (xml.descendants("friendlyName").first?.text ?? "Samsung camera", control)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() } }
        }
        throw CameraFailure(message: "Couldn’t reach the camera. Join the same Wi-Fi, enable the mode that worked on your Mac, and allow Local Network access in Settings. You can also paste the ContentDirectory URL printed by the Mac’s browse command and turn on ‘Use service URL’.")
    }
    static func parsePage(_ data: Data, base: URL) throws -> BrowsePage {
        let envelope = try CameraXML.parse(data)
        if let fault = envelope.descendants("faultstring").first { throw CameraFailure(message: fault.text) }
        guard let result = envelope.descendants("Result").first else { throw CameraFailure(message: "No file listing in the camera response.") }
        let didl = try CameraXML.parse(Data(result.text.utf8))
        var photos: [CameraPhoto] = []
        for item in didl.children where item.name == "item" {
            let resources = item.children.filter { $0.name == "res" }
            let images = resources.filter {
                let parts = ($0.attributes["protocolInfo"] ?? "").components(separatedBy: ":")
                return parts.count >= 3 && parts[2].lowercased().hasPrefix("image/")
            }
            let videos = resources.filter {
                let parts = ($0.attributes["protocolInfo"] ?? "").components(separatedBy: ":")
                return parts.count >= 3 && parts[2].lowercased() == "video/mp4"
            }
            let isVideo = item.value("class").contains("videoItem") || !videos.isEmpty
            func isThumb(_ node: XMLNode) -> Bool {
                let pi = node.attributes["protocolInfo"] ?? ""
                return ["JPEG_TN", "JPEG_SM", "PNG_TN", "PNG_SM", "_TN", "_SM"].contains { pi.contains($0) }
            }
            // Exclude server-transcoded alternatives (DLNA conversion indicator).
            let originals = (isVideo ? videos : images.filter { !isThumb($0) }).filter {
                !($0.attributes["protocolInfo"] ?? "").contains("DLNA.ORG_CI=1")
            }
            guard let best = originals.max(by: { (Int64($0.attributes["size"] ?? "") ?? 0) < (Int64($1.attributes["size"] ?? "") ?? 0) }),
                  let original = httpURL(best.text, relativeTo: base) else { continue }
            let preview = (images.first(where: isThumb) ?? (isVideo ? images.first : nil)).flatMap { httpURL($0.text, relativeTo: base) } ?? (isVideo ? nil : original)
            let mime = (best.attributes["protocolInfo"] ?? "").components(separatedBy: ":")[2]
            photos.append(CameraPhoto(id: original.absoluteString, title: item.value("title").isEmpty ? original.lastPathComponent : item.value("title"), original: original, thumbnail: preview, size: Int64(best.attributes["size"] ?? "") ?? 0, isVideo: isVideo, mimeType: mime))
        }
        return BrowsePage(photos: photos, folders: didl.children.filter { $0.name == "container" }.compactMap { $0.attributes["id"] }, returned: Int(envelope.descendants("NumberReturned").first?.text ?? "") ?? didl.children.count, total: Int(envelope.descendants("TotalMatches").first?.text ?? ""), signature: result.text)
    }
    func browse(control: URL) async throws -> [CameraPhoto] {
        var queue = ["0"], visited = Set<String>(), photos: [CameraPhoto] = [], seen = Set<String>()
        while !queue.isEmpty {
            let folder = queue.removeFirst()
            guard visited.insert(folder).inserted else { continue }
            var start = 0, previous = ""
            while true {
                try Task.checkCancellation()
                let body = """
                <?xml version="1.0" encoding="utf-8"?>
                <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Browse xmlns:u="\(Self.service)"><ObjectID>\(Self.escape(folder))</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>\(start)</StartingIndex><RequestedCount>200</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>
                """
                var request = URLRequest(url: control, timeoutInterval: 20)
                request.httpMethod = "POST"
                request.httpBody = Data(body.utf8)
                request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
                request.setValue("\"\(Self.service)#Browse\"", forHTTPHeaderField: "SOAPAction")
                let page = try Self.parsePage(await fetch(request), base: control)
                if page.returned == 0 { break }
                guard page.signature != previous else { throw CameraFailure(message: "The camera repeated a page of files. Try reconnecting or reducing the number of photos on its card.") }
                previous = page.signature
                photos.append(contentsOf: page.photos.filter { seen.insert($0.id).inserted })
                queue.append(contentsOf: page.folders)
                start += page.returned
                if let total = page.total, start >= total { break }
            }
        }
        return photos
    }
}
