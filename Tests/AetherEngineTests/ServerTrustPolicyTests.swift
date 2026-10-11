// givo-31 / givo-33: a load's own trust policy, through real hops and against a self-signed origin.
// The origins are Python subprocesses (see `SelfSignedTLSOrigin`), so this suite is macOS only.
#if os(macOS)

    import Foundation
    import Testing

    @testable import AetherEngine

    /// A policy over host ports that learns the hops its own requests follow, as a host scoped to one
    /// source and its redirects would. Both origins listen on 127.0.0.1, so the port is the origin.
    final class PortTrust: @unchecked Sendable {
        private let lock = NSLock()
        private var ports: Set<Int>
        private var rejected: Set<Int>
        private(set) var hops: [(original: URL?, target: URL)] = []

        init(accepting ports: [Int], rejecting rejected: [Int] = []) {
            self.ports = Set(ports)
            self.rejected = Set(rejected)
        }

        func accepts(_ port: Int) -> Bool { lock.withLock { ports.contains(port) } }

        var hopTargets: [Int] { lock.withLock { hops.compactMap { $0.target.port } } }

        func policy(identity: String? = nil) -> ServerTrustPolicy {
            ServerTrustPolicy(
                decide: { [self] space in
                    lock.withLock {
                        if rejected.contains(space.port) { return .reject }
                        return ports.contains(space.port) ? .accept : .systemDefault
                    }
                },
                onRedirect: { [self] original, target in
                    lock.withLock {
                        hops.append((original, target))
                        if let from = original?.port, ports.contains(from), let to = target.port {
                            ports.insert(to)
                        }
                    }
                },
                identity: identity)
        }
    }

    /// A self-signed origin that answers every GET with a 302 to the same path on `target`.
    final class SelfSignedRedirectOrigin {
        let port: UInt16
        private let process: Process
        private let workDir: URL

        var requestsServed: Int {
            let log = workDir.appendingPathComponent("requests.log")
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return 0 }
            return text.split(separator: "\n").count
        }

        init?(redirectingTo target: UInt16) async {
            guard let launched = await PythonOrigin.launch(
                prefix: "aether-tls-redirect", script: Self.script(target: target),
                files: ["cert.pem": SelfSignedTLSOrigin.certPEM, "key.pem": SelfSignedTLSOrigin.keyPEM])
            else { return nil }
            process = launched.process
            port = launched.port
            workDir = launched.workDir
        }

        func stop() {
            process.terminate()
            try? FileManager.default.removeItem(at: workDir)
        }

        private static func script(target: UInt16) -> String {
            """
            import http.server, ssl

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *args):
                    pass

                def do_GET(self):
                    with open("requests.log", "a") as f:
                        f.write(self.path + "\\n")
                    self.send_response(302)
                    self.send_header("Location", "https://127.0.0.1:\(target)" + self.path)
                    self.send_header("Content-Length", "0")
                    self.end_headers()

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain("cert.pem", "key.pem")
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            print("READY", server.server_address[1], flush=True)
            server.serve_forever()
            """
        }
    }

    /// Reads `count` bytes from an opened reader; returns what arrived.
    func readBytes(_ reader: AVIOReader, count: Int) -> [UInt8] {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buf.deallocate() }
        var got = 0
        while got < count {
            let n = reader.read(into: buf + got, size: Int32(count - got))
            if n <= 0 { break }
            got += Int(n)
        }
        return Array(UnsafeBufferPointer(start: buf, count: got))
    }

    @Suite("givo-31 / givo-33: a load's trust policy through real hops", .timeLimit(.minutes(3)))
    struct ServerTrustPolicyReaderTests {

        @Test("A 302 a reader follows is reported to the reader's own policy, which then serves the target")
        func readerHopReachesItsPolicy() async throws {
            let target = try #require(await SelfSignedTLSOrigin())
            defer { target.stop() }
            let front = try #require(await SelfSignedRedirectOrigin(redirectingTo: target.port))
            defer { front.stop() }
            let trust = PortTrust(accepting: [Int(front.port)])

            let reader = AVIOReader(
                url: URL(string: "https://127.0.0.1:\(front.port)/hop.bin")!,
                chunkRequestTimeout: 10, chunkMaxRetries: 2, serverTrust: trust.policy())
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            let bytes = readBytes(reader, count: 64 * 1024)
            #expect(bytes.count == 64 * 1024)
            #expect(bytes.first == 0xA7)
            #expect(trust.hopTargets.contains(Int(target.port)), "the hop never reached the load's policy")
            #expect(target.requestsServed > 0)
        }

        @Test("A 302 the held connection follows itself is reported to the load's own policy")
        func heldConnectionHopReachesItsPolicy() async throws {
            let target = try #require(await SelfSignedTLSOrigin())
            defer { target.stop() }
            let front = try #require(await SelfSignedRedirectOrigin(redirectingTo: target.port))
            defer { front.stop() }
            let trust = PortTrust(accepting: [Int(front.port)])

            let reader = AVIOReader(
                url: URL(string: "https://127.0.0.1:\(front.port)/held-hop.bin")!,
                chunkRequestTimeout: 10, chunkMaxRetries: 2, heldConnection: true,
                serverTrust: trust.policy())
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            let bytes = readBytes(reader, count: 64 * 1024)
            #expect(bytes.count == 64 * 1024)
            #expect(bytes.first == 0xA7)
            #expect(trust.hopTargets.contains(Int(target.port)), "the held connection's hop never reached the policy")
        }

        /// The DVR-pin shape: a policy that refuses one origin's certificate outright.
        @Test("A load's .reject is refused at the handshake and reads as a trust refusal")
        func policyRejectRefuses() async throws {
            let server = try #require(await SelfSignedTLSOrigin())
            defer { server.stop() }
            let trust = PortTrust(accepting: [], rejecting: [Int(server.port)])

            let reader = AVIOReader(
                url: URL(string: "https://127.0.0.1:\(server.port)/pinned.bin")!,
                chunkRequestTimeout: 5, chunkMaxRetries: 1, serverTrust: trust.policy())
            defer { reader.markClosed(); reader.close() }
            var refusal: Error?
            do { try reader.open() } catch { refusal = error }
            try await Task.sleep(for: .seconds(1))
            #expect(server.requestsServed == 0, "a request crossed a handshake the load's policy rejected")
            if case .transportSecurityFailed = refusal as? AVIOReaderError {} else {
                Issue.record("open failed as \(String(describing: refusal)), not a trust refusal")
            }
        }

        /// A policy no load holds any more goes, and its URL sessions with it.
        @Test("A released policy is deallocated once its load is closed")
        func releasedPolicyDeinits() async throws {
            let server = try #require(await SelfSignedTLSOrigin())
            defer { server.stop() }
            weak var released: ServerTrustPolicy?
            do {
                let trust = PortTrust(accepting: [Int(server.port)])
                var options = LoadOptions()
                options.serverTrust = trust.policy()
                released = options.serverTrust
                let reader = AVIOReader(
                    url: URL(string: "https://127.0.0.1:\(server.port)/release.bin")!,
                    chunkRequestTimeout: 10, chunkMaxRetries: 2, serverTrust: options.serverTrust)
                try reader.open()
                #expect(readBytes(reader, count: 16 * 1024).count == 16 * 1024)
                reader.markClosed()
                reader.close()
                options.serverTrust = nil
            }
            try await waitFor { released == nil }
            #expect(released == nil)
        }

        @Test("Warm bytes match a load only under a policy that answers alike")
        func warmTrustMatching() {
            let a = ServerTrustPolicy(decide: { _ in .systemDefault }, identity: "lab")
            let b = ServerTrustPolicy(decide: { _ in .systemDefault }, identity: "lab")
            let c = ServerTrustPolicy(decide: { _ in .systemDefault })
            let d = ServerTrustPolicy(decide: { _ in .systemDefault })
            #expect(ServerTrustPolicy.answersAlike(nil, nil))
            #expect(!ServerTrustPolicy.answersAlike(a.stamp, nil))
            #expect(!ServerTrustPolicy.answersAlike(nil, a))
            #expect(ServerTrustPolicy.answersAlike(a.stamp, b))
            #expect(ServerTrustPolicy.answersAlike(c.stamp, c))
            #expect(!ServerTrustPolicy.answersAlike(c.stamp, d))
            #expect(!ServerTrustPolicy.answersAlike(a.stamp, c))

            let store = SourcePrewarmStore()
            let url = URL(string: "https://127.0.0.1:1/disc.iso")!
            let warm = PrewarmedSource(head: ResidentSpan(start: 0, data: Data(count: 1000)), tail: nil,
                                       contentLength: 5000, requestHeaders: [:], resolvedURL: nil,
                                       trust: a.stamp)
            #expect(store.store(warm, for: url))
            #expect(HTTPDiscIOReader.takePrewarm(for: url, extraHeaders: [:], serverTrust: nil, store: store) == nil,
                    "a load under no policy adopted bytes fetched under one")
            #expect(store.store(warm, for: url))
            #expect(HTTPDiscIOReader.takePrewarm(for: url, extraHeaders: [:], serverTrust: b, store: store) != nil)
        }
    }

    extension PrewarmStoreSuites {
        @Suite("givo-33: an adopted warm's hop reaches the load's own policy", .timeLimit(.minutes(3)))
        struct WarmHopUnderTrustPolicyTests {

            /// The warm resolved the 302 under its own policy and pinned the target; the load adopts
            /// the pin. Its policy has to learn the hop before the load's first request reaches the
            /// target, or the target's certificate is refused for a source the host already allowed.
            @Test("A load that adopts a redirected warm learns the warm's hop and reads past the head")
            func adoptedWarmHopReachesTheLoadsPolicy() async throws {
                let target = try #require(await SelfSignedTLSOrigin())
                defer { target.stop() }
                let front = try #require(await SelfSignedRedirectOrigin(redirectingTo: target.port))
                defer { front.stop() }
                let warmTrust = PortTrust(accepting: [Int(front.port)])
                let loadTrust = PortTrust(accepting: [Int(front.port)])
                let url = URL(string: "https://127.0.0.1:\(front.port)/warm-hop.bin")!

                SourcePrewarmStore.shared.clear()
                defer { SourcePrewarmStore.shared.clear() }
                let report = await SourcePrewarmFetcher.warm(
                    url: url, extraHeaders: [:], byteBudget: 64 * 1024,
                    serverTrust: warmTrust.policy(identity: "lab-33"), into: .shared)
                #expect(report.isWarm, "the warm under its own policy was declined: \(report.declined ?? "-")")
                let frontAfterWarm = front.requestsServed

                let reader = AVIOReader(url: url, chunkRequestTimeout: 10, chunkMaxRetries: 2,
                                        serverTrust: loadTrust.policy(identity: "lab-33"))
                defer { reader.markClosed(); reader.close() }
                try reader.open()
                let bytes = readBytes(reader, count: 256 * 1024)
                #expect(bytes.count == 256 * 1024, "read \(bytes.count) bytes past a 64 KiB warm head")
                #expect(bytes.last == 0xA7)
                #expect(loadTrust.accepts(Int(target.port)), "the adopted hop never reached the load's policy")
                #expect(front.requestsServed == frontAfterWarm,
                        "the load re-resolved through the front instead of riding the adopted pin")
            }
        }
    }

#endif
