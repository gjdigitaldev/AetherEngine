import Testing
import Foundation
@testable import AetherEngine

/// R2542 (givo-25): the playlist shape line and the native host's hand-off rule.
struct PlaylistShapeTests {

    @Test("the shape line names where a URI points, never the host")
    func shapeHidesTheHost() throws {
        let master = try HLSPlaylistParser.parse("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="https://subs.example.net/en.m3u8?token=abc"
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,SUBTITLES="s"
        video/index.m3u8
        """)
        let base = try #require(URL(string: "https://media.example.org/vod/master.m3u8"))
        let line = PlaylistShape.describe(master, at: base, requested: base, bytes: 366, byteRanges: false)
        #expect(!line.contains("example"))
        #expect(!line.contains("token"))
        #expect(line.contains("[en .m3u8 other host default]"))
        #expect(line.contains("URI relative .m3u8"))
    }

    @Test("one file behind every segment is a wrapper; a map, a key or two files are not")
    func singleFileRule() throws {
        let base = try #require(URL(string: "https://vod.test/list.m3u8"))
        func media(_ body: String) throws -> HLSMediaPlaylist {
            guard case .media(let value) = try HLSPlaylistParser.parse(body) else { throw URLError(.badURL) }
            return value
        }
        let wrapped = try media("#EXTM3U\n#EXT-X-TARGETDURATION:9000\n#EXTINF:5400,\nmovie.mp4\n#EXT-X-ENDLIST")
        #expect(PlaylistShape.singleFile(wrapped, against: base)?.lastPathComponent == "movie.mp4")
        let two = try media("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\na.ts\n#EXTINF:6,\nb.ts\n#EXT-X-ENDLIST")
        #expect(PlaylistShape.singleFile(two, against: base) == nil)
        let mapped = try media("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\nmovie.mp4\n#EXT-X-ENDLIST")
        #expect(PlaylistShape.singleFile(mapped, against: base) == nil)
        let nested = try media("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nother.m3u8\n#EXT-X-ENDLIST")
        #expect(PlaylistShape.singleFile(nested, against: base) == nil)
        let open = try media("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nmovie.mp4")
        #expect(PlaylistShape.singleFile(open, against: base) == nil)
    }

    @Test("only a CoreMedia refusal with no media delivered goes to the ingest, and only when armed")
    func handOffRule() {
        let media = SoftwarePathEscalation.mediaErrorDomain
        #expect(NativeAVPlayerHost.handsRefusalToVODIngest(armed: true, errorDomain: media, mediaBytesArrived: false))
        #expect(!NativeAVPlayerHost.handsRefusalToVODIngest(armed: false, errorDomain: media, mediaBytesArrived: false))
        #expect(!NativeAVPlayerHost.handsRefusalToVODIngest(armed: true, errorDomain: media, mediaBytesArrived: true))
        #expect(!NativeAVPlayerHost.handsRefusalToVODIngest(armed: true, errorDomain: NSURLErrorDomain,
                                                              mediaBytesArrived: false))
    }
}
