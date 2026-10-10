import Foundation

/// R2542 (givo-25): a playlist described for the log, and the one-file test.
///
/// The description carries no host, path or query: where a URI points is said as `relative`,
/// `same host` or `other host`, and a segment by its extension. That is enough to tell a playlist
/// AVPlayer refuses (a wrapper around one progressive file, a subtitle rendition on a host the
/// identity headers do not reach, a variant that is not TS) from one it plays.
enum PlaylistShape {

    static func describe(_ playlist: HLSPlaylist, at url: URL, requested: URL, bytes: Int, byteRanges: Bool) -> String {
        let answered = url.host?.lowercased() != requested.host?.lowercased()
            ? " (answered from another host)" : (url != requested ? " (redirected)" : "")
        switch playlist {
        case .master(let master):
            let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth })
            var parts = ["master \(bytes) B\(answered)", "\(master.variants.count) variant(s)"]
            if let best {
                parts.append("best \(best.bandwidth / 1000) kbit/s, audio "
                             + (best.audioGroupID == nil ? "muxed" : "in a group")
                             + ", subtitles " + (best.subtitleGroupID == nil ? "none" : "in a group")
                             + ", URI \(whereIs(best.uri, base: url)) .\(fileExtension(best.uri))")
            }
            parts.append("\(master.audioRenditions.count) audio rendition(s)")
            let subtitles = master.subtitleRenditions.prefix(4).map { rendition in
                "[\(rendition.language ?? "?") .\(fileExtension(rendition.uri)) \(whereIs(rendition.uri, base: url))"
                    + (rendition.isDefault ? " default" : "") + (rendition.isForced ? " forced" : "") + "]"
            }
            parts.append("\(master.subtitleRenditions.count) subtitle rendition(s)"
                         + (subtitles.isEmpty ? "" : " " + subtitles.joined(separator: " ")))
            return parts.joined(separator: ", ")
        case .media(let media):
            let distinct = Set(media.segments.map(\.uri)).count
            let total = media.segments.reduce(0) { $0 + $1.duration }
            let key = media.hasUnsupportedEncryption ? "unsupported" : (media.isEncrypted ? "AES-128" : "none")
            var parts = [
                "media \(bytes) B\(answered)",
                "\(media.segments.count) segment(s) over \(distinct) URI(s)",
                String(format: "%.1f s, target %.0f s", total, media.targetDuration),
                media.hasEndList ? "ENDLIST" : "no ENDLIST",
                media.hasMap ? "MAP" : "no MAP",
                "key \(key)",
                byteRanges ? "byte ranges" : "no byte ranges",
            ]
            if let first = media.segments.first {
                parts.append("first .\(fileExtension(first.uri)) \(whereIs(first.uri, base: url))")
            }
            return parts.joined(separator: ", ")
        }
    }

    /// The one file a finite playlist wraps, or nil: every segment names the same URI, nothing marks
    /// it as HLS media (no map, no key), and that URI is not itself a playlist.
    static func singleFile(_ media: HLSMediaPlaylist, against base: URL) -> URL? {
        guard media.hasEndList, !media.hasMap, !media.isEncrypted, !media.hasUnsupportedEncryption,
              let first = media.segments.first,
              media.segments.allSatisfy({ $0.uri == first.uri }),
              let url = HLSPlaylistParser.resolve(uri: first.uri, against: base),
              !["m3u8", "m3u"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    static func whereIs(_ uri: String, base: URL) -> String {
        guard let url = URL(string: uri), url.scheme != nil else { return "relative" }
        let sameHost = url.host?.lowercased() == base.host?.lowercased() && url.port == base.port
        return sameHost ? "same host" : "other host"
    }

    static func fileExtension(_ uri: String) -> String {
        let path = URLComponents(string: uri)?.path ?? uri
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "none" : ext
    }
}
