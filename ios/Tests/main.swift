import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let base = URL(string: "http://192.168.0.1:7676/services/content")!
let didl = """
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
<container id="folder&amp;1"><dc:title>Photos</dc:title></container>
<item id="1"><dc:title>A &amp; B.jpg</dc:title><upnp:class>object.item.imageItem.photo</upnp:class>
<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN" size="20000">/thumb.jpg</res>
<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG" size="5000000">/original.jpg</res></item>
<item id="2"><dc:title>Movie.mp4</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG">/video-preview.jpg</res></item>
<item id="3"><dc:title>Only thumbnail</dc:title><res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN">/small.jpg</res></item>
</DIDL-Lite>
"""
let soap = "<s:Envelope xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'><s:Body><BrowseResponse><Result>\(CameraClient.escape(didl))</Result><NumberReturned>4</NumberReturned><TotalMatches>405</TotalMatches></BrowseResponse></s:Body></s:Envelope>"
let page = try CameraClient.parsePage(Data(soap.utf8), base: base)
check(page.photos.count == 1, "Exclude videos and thumbnail-only items")
check(page.photos[0].title == "A & B.jpg", "Decode escaped titles")
check(page.photos[0].original.absoluteString == "http://192.168.0.1:7676/original.jpg", "Resolve original URL")
check(page.photos[0].thumbnail?.lastPathComponent == "thumb.jpg", "Use thumbnail for grid")
check(page.photos[0].size == 5000000, "Keep original byte size")
check(page.returned == 4 && page.total == 405, "Keep pagination counts including non-photo entries")
check(page.folders == ["folder&1"], "Decode folder IDs")
check(CameraClient.escape("folder&<1>") == "folder&amp;&lt;1&gt;", "Escape SOAP IDs")
check(CameraClient.httpURL("file:///etc/passwd") == nil, "Reject non-HTTP resources")
do {
    _ = try CameraXML.parse(Data("<broken>".utf8))
    fatalError("Malformed XML should fail")
} catch {}
let movieDIDL = """
<DIDL-Lite><item><title>Original.mp4</title><class>object.item.videoItem</class>
<res protocolInfo="http-get:*:video/mp4:DLNA.ORG_CI=1" size="9000000">/converted.mp4</res>
<res protocolInfo="http-get:*:video/mp4:*" size="7000000">/original.mp4</res>
<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN">/preview.jpg</res></item>
<item><title>No preview.mp4</title><class>object.item.videoItem</class>
<res protocolInfo="http-get:*:video/mp4:*">/second.mp4</res></item></DIDL-Lite>
"""
let movieSOAP = "<Envelope><Result>\(CameraClient.escape(movieDIDL))</Result></Envelope>"
let movies = try CameraClient.parsePage(Data(movieSOAP.utf8), base: base).photos
check(movies.count == 2, "Include MP4 videos with and without previews")
check(movies[0].isVideo && movies[0].mimeType == "video/mp4", "Classify video imports")
check(movies[0].original.lastPathComponent == "original.mp4", "Reject transcoded resource even when larger")
check(movies[0].thumbnail?.lastPathComponent == "preview.jpg", "Keep video thumbnail separate from original")
check(movies[1].thumbnail == nil, "Never download full video for grid preview")
check(!page.photos[0].isVideo, "Preserve photo classification")
print("Camera protocol fixture checks passed")
