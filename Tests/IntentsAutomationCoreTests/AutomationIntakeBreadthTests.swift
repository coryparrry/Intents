#if os(macOS)
import XCTest
import Darwin
@testable import IntentsAutomationCore

final class AutomationIntakeBreadthTests: XCTestCase {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/intents-intake-breadth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func profile() -> AutomationServedJavaScriptProfile {
        .init(schemaVersion: 1, executablePath: "/missing/node", executableSHA256: String(repeating: "a", count: 64),
            scriptRelativePath: "server.js", scriptSHA256: String(repeating: "b", count: 64), arguments: [],
            bundleURL: "http://127.0.0.1:8081/index.bundle?platform=ios&dev=true", bundleSHA256: AutomationArtifactRegistry.digest(Data("bundle".utf8)),
            nativeBindingRelativePath: "runtime-binding.json", qualificationEvidence: "Existing native bridge and Metro recipe qualification",
            recipeRelativePath: "server.json", recipeSHA256: String(repeating: "c", count: 64))
    }
    func testMissingNodeAndWrongEndpointCannotBeApproved() throws {
        let value = profile()
        XCTAssertThrowsError(try value.verifyExecutable())
        for endpoint in ["http://localhost:8081/index.bundle", "https://127.0.0.1:8081/index.bundle", "http://192.168.1.2:8081/index.bundle", "http://127.0.0.1/index.bundle", "http://127.0.0.1:8081/index.bundle#other"] {
            var changed = value; changed.bundleURL = endpoint
            XCTAssertThrowsError(try changed.validate(), endpoint)
        }
    }
    func testSourceAndProfileRevisionInvalidateManifestAndIdentity() throws {
        let root = try root(), source = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let script = Data("server".utf8)
        var value = profile(); value.scriptSHA256 = AutomationArtifactRegistry.digest(script); value.recipeSHA256 = nil
        let recipe = try JSONEncoder().encode(value)
        try script.write(to: source.appendingPathComponent("server.js")); try recipe.write(to: source.appendingPathComponent("server.json"))
        let capture = root.appendingPathComponent("capture")
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: capture)
        value.recipeSHA256 = AutomationArtifactRegistry.digest(recipe)
        XCTAssertNoThrow(try value.validateCapture(manifest))
        _ = try value.verifyFrozenInputs(manifest: manifest, frozenRoot: capture.appendingPathComponent("source"))
        try Data("different".utf8).write(to: capture.appendingPathComponent("source/server.js"))
        XCTAssertThrowsError(try value.verifyFrozenInputs(manifest: manifest, frozenRoot: capture.appendingPathComponent("source")))
        var changed = value; changed.bundleSHA256 = String(repeating: "0", count: 64)
        XCTAssertNotEqual(try value.digest, try changed.digest)
        let first = AutomationServedJavaScriptIdentity(profileDigest: try value.digest, sourceManifestDigest: try manifest.digest,
            nativeProductDigest: "native", bundleURL: value.bundleURL, bundleSHA256: value.bundleSHA256)
        let second = AutomationServedJavaScriptIdentity(profileDigest: try changed.digest, sourceManifestDigest: try manifest.digest,
            nativeProductDigest: "native", bundleURL: value.bundleURL, bundleSHA256: changed.bundleSHA256)
        var app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: "native")
        app.servedJavaScriptDigest = try first.digest
        var other = app; other.servedJavaScriptDigest = try second.digest
        XCTAssertNotEqual(app, other)
    }
    func testEndpointRaceWildcardAndStalePIDAreRejected() throws {
        let identity = AutomationProcessIdentity(pid: 42, startIdentity: "123:0")
        let good = try AutomationServedJavaScriptSupervisor.parseListeners(Data("p42\nf19\nn127.0.0.1:8081\n".utf8))
        XCTAssertNoThrow(try AutomationServedJavaScriptSupervisor.validateListener(good, identity: identity, port: 8081))
        for output in ["p43\nf19\nn127.0.0.1:8081\n", "p42\nf19\nn*:8081\n", "p42\nf19\nn127.0.0.1:8081\np43\nf20\nn127.0.0.1:8081\n", "p42\nf19\nn127.0.0.1:8081\nf20\nn127.0.0.1:8081\n", ""] {
            let owners = try AutomationServedJavaScriptSupervisor.parseListeners(Data(output.utf8))
            XCTAssertThrowsError(try AutomationServedJavaScriptSupervisor.validateListener(owners, identity: identity, port: 8081))
        }
        XCTAssertThrowsError(try AutomationServedJavaScriptSupervisor.parseListeners(Data("n127.0.0.1:8081\n".utf8)))
        for malformed in ["p42\nn127.0.0.1:8081\n", "p42\nftxt\nn127.0.0.1:8081\n", "p42\nf-1\nn127.0.0.1:8081\n", "p42\nf019\nn127.0.0.1:8081\n", "f19\nn127.0.0.1:8081\n", "p42\nf19\n", "p42\nf19\nf20\nn127.0.0.1:8081\n"] {
            XCTAssertThrowsError(try AutomationServedJavaScriptSupervisor.parseListeners(Data(malformed.utf8)), malformed)
        }
    }
    func testWrongBytesRedirectAndNonSuccessNeverBecomeSubjectIdentity() throws {
        let value = profile(), endpoint = URL(string: value.bundleURL)!
        let response = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: [:])!
        XCTAssertNoThrow(try AutomationServedJavaScriptSupervisor.validateResponse(profile: value, response: response, bytes: Data("bundle".utf8)))
        XCTAssertThrowsError(try AutomationServedJavaScriptSupervisor.validateResponse(profile: value, response: response, bytes: Data("stale bundle".utf8)))
        let redirected = HTTPURLResponse(url: URL(string: "http://127.0.0.1:8081/other.bundle")!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        XCTAssertThrowsError(try AutomationServedJavaScriptSupervisor.validateResponse(profile: value, response: redirected, bytes: Data("bundle".utf8)))
        let error = HTTPURLResponse(url: endpoint, statusCode: 500, httpVersion: nil, headerFields: [:])!
        XCTAssertThrowsError(try AutomationServedJavaScriptSupervisor.validateResponse(profile: value, response: error, bytes: Data("bundle".utf8)))
    }
    func testNativeEndpointBindingMustMatchActualProduct() throws {
        let root = try root(); var value = profile()
        var app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: "native")
        app.canonicalBundlePath = root.path
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "mode": "served", "bundleID": app.bundleID, "bundleURL": value.bundleURL])
        try data.write(to: root.appendingPathComponent(value.nativeBindingRelativePath))
        XCTAssertNoThrow(try value.validateNativeProduct(app: app))
        value.bundleURL = "http://127.0.0.1:8081/another.bundle"
        XCTAssertThrowsError(try value.validateNativeProduct(app: app))
    }
    func testTuistRequiresProjectAndExistingPinnedTool() throws {
        let root = try root(), pin = root.appendingPathComponent("tuist.json")
        let value = AutomationTuistRecipePin(schemaVersion: 1, version: "4.30.0", executablePath: "/missing/tuist",
            executableSHA256: String(repeating: "a", count: 64), toolchainSHA256: ["swiftc": String(repeating: "b", count: 64), "xcodeVersion": String(repeating: "c", count: 64)],
            qualificationEvidence: "Qualified local project recipe", recipePath: "tuist.json")
        try JSONEncoder().encode(value).write(to: pin)
        XCTAssertThrowsError(try AutomationSourceRecipe.tuist(source: root, pin: pin))
        try Data("import ProjectDescription".utf8).write(to: root.appendingPathComponent("Project.swift"))
        XCTAssertThrowsError(try AutomationSourceRecipe.tuist(source: root, pin: pin))
        XCTAssertThrowsError(try AutomationTuistRecipePin.generatedProjects(root: root))
    }
    func testSandboxDeniesForksAndExternalNetworkAndOriginalWrites() {
        let value = profile()
        let sandbox = AutomationServedJavaScriptSupervisor.sandbox(profile: value, root: URL(fileURLWithPath: "/owned/source"), temporary: URL(fileURLWithPath: "/owned/temp"))
        XCTAssertTrue(sandbox.contains("(deny process-fork)"))
        XCTAssertTrue(sandbox.contains("(local ip \"localhost:8081\")"))
        XCTAssertFalse(sandbox.contains("(local ip \"*:"))
        XCTAssertFalse(sandbox.contains("network-outbound"))
        XCTAssertFalse(sandbox.contains("(allow process*)"))
        XCTAssertFalse(sandbox.contains("(allow file-write* (subpath \"/owned/source\")"))
        XCTAssertTrue(sandbox.contains("(deny file-write* (literal \"/owned/temp/openssl.cnf\"))"))
    }
    func testOccupiedEndpointIsNeverAdoptedAndReservationReleases() throws {
        let socket = try AutomationServedJavaScriptSupervisor.reserve(port: 0)
        var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        XCTAssertEqual(status, 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertThrowsError(try AutomationServedJavaScriptSupervisor.reserve(port: port))
        Darwin.close(socket)
        let replacement = try AutomationServedJavaScriptSupervisor.reserve(port: port)
        Darwin.close(replacement)
    }
    func testOwnedOpenSSLConfigurationIsPinnedAndEnvironmentExcludesGlobalOptions() throws {
        let session = try root()
        let configuration = try AutomationServedJavaScriptSupervisor.writeNodeConfiguration(session: session)
        let environment = AutomationServedJavaScriptSupervisor.childEnvironment(profile: profile(), session: session,
            developerDirectory: URL(fileURLWithPath: "/usr"), configuration: configuration)
        XCTAssertEqual(environment["OPENSSL_CONF"], configuration.path)
        XCTAssertNil(environment["OPENSSL_MODULES"])
        XCTAssertNil(environment["NODE_OPTIONS"])
        XCTAssertEqual(AutomationArtifactRegistry.digest(try Data(contentsOf: configuration)), AutomationServedJavaScriptSupervisor.nodeConfigurationSHA256)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        try Data("openssl_conf = unsafe_global_provider\n".utf8).write(to: configuration)
        XCTAssertThrowsError(try AutomationServedJavaScriptSupervisor.verifyNodeConfiguration(configuration)) {
            XCTAssertEqual($0 as? AutomationContractError, .conflictingOperation)
        }
        let first = AutomationServedJavaScriptIdentity(profileDigest: "profile", sourceManifestDigest: "source", nativeProductDigest: "native",
            bundleURL: "http://127.0.0.1:8081/index.bundle", bundleSHA256: "bundle", nodeConfigurationSHA256: AutomationServedJavaScriptSupervisor.nodeConfigurationSHA256)
        var changed = first; changed.nodeConfigurationSHA256 = AutomationArtifactRegistry.digest(Data("changed".utf8))
        XCTAssertNotEqual(try first.digest, try changed.digest)
    }
    func testActualOwnedServerDisposalAfterOperationFailureAndWrongBytes() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_SERVED_JS_LIVE"] == "1" else {
            throw XCTSkip("Opt-in sealed Node 24 supervision qualification; no app launch or native-consumption claim")
        }
        let fixtureRoot = try root()
        do { try await qualifyActualOwnedServer(root: fixtureRoot) }
        catch {
            let original = error
            let selected = ProcessInfo.processInfo.environment["INTENTS_SERVED_JS_EVIDENCE_ROOT"] ?? "/private/tmp/intents-served-js-evidence"
            do {
                let evidence = try AutomationServedJavaScriptTestEvidence.retain(root: fixtureRoot,
                    evidenceRoot: URL(fileURLWithPath: selected), error: original)
                print("Retained served-JavaScript failure evidence: " + evidence.path)
            } catch { print("Served-JavaScript evidence retention failed: " + String(String(describing: error).prefix(2048))) }
            throw original
        }
    }
    private func qualifyActualOwnedServer(root: URL) async throws {
        let inputs = ProcessInfo.processInfo.environment
        guard let nodePath = inputs["INTENTS_SERVED_JS_NODE"] else {
            throw AutomationContractError.missingEvidence("Live supervision requires an explicit installed Node executable")
        }
        let source = root.appendingPathComponent("input"), product = root.appendingPathComponent("product.app")
        let node = try AutomationPath.canonical(URL(fileURLWithPath: nodePath))
        guard node.lastPathComponent == "node", FileManager.default.isExecutableFile(atPath: node.path) else {
            throw AutomationContractError.invalidIdentity
        }
        let nodeSHA256 = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(node, maximumBytes: 128 * 1024 * 1024))
        XCTAssertFalse(try AutomationMacExecutableCodeIdentity.helperHashes([node.path]).isEmpty,
            "The installed Node supports the kernel code-identity census used before owned-listener admission")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
        let fd = try AutomationServedJavaScriptSupervisor.reserve(port: 0)
        var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port)); Darwin.close(fd)
        let globalConfiguration = root.appendingPathComponent("unrelated-global-openssl.cnf")
        try Data("openssl_conf = deliberately_invalid_global_configuration\n".utf8).write(to: globalConfiguration)
        let globalJSON = String(decoding: try JSONEncoder().encode(globalConfiguration.path), as: UTF8.self)
        let configurationJSON = String(decoding: try JSONEncoder().encode(String(decoding: AutomationServedJavaScriptSupervisor.nodeConfigurationBytes, as: UTF8.self)), as: UTF8.self)
        let script = Data(("const fs=require('node:fs');if(fs.readFileSync(process.env.OPENSSL_CONF,'utf8')!==" + configurationJSON + ")throw Error('unowned OpenSSL configuration');" +
            "let denied=false;try{fs.readFileSync(" + globalJSON + ")}catch(e){denied=e.code==='EPERM'||e.code==='EACCES'}if(!denied)throw Error('global configuration readable');" +
            "process.on('SIGTERM',()=>{let denied=false;try{fs.chmodSync(process.env.OPENSSL_CONF,0o600);fs.writeFileSync(process.env.OPENSSL_CONF,'tampered')}catch(e){denied=e.code==='EPERM'||e.code==='EACCES'}console.log(denied?'configuration-tamper-denied':'configuration-tamper-allowed');process.exit(0)});" +
            "const http=require('node:http');http.createServer((q,r)=>{r.end('bundle')}).listen(Number(process.argv[2]),'127.0.0.1');").utf8)
        try script.write(to: source.appendingPathComponent("server.js"))
        var value = profile(); value.executablePath = node.path
        value.executableSHA256 = nodeSHA256
        value.scriptSHA256 = AutomationArtifactRegistry.digest(script); value.arguments = [String(port)]
        value.bundleURL = "http://127.0.0.1:" + String(port) + "/index.bundle"
        value.recipeSHA256 = nil
        try JSONEncoder().encode(value).write(to: source.appendingPathComponent("server.json"))
        value = try .load(source: source, url: source.appendingPathComponent("server.json"))
        let binding = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "mode": "served", "bundleID": "example.App", "bundleURL": value.bundleURL])
        try binding.write(to: product.appendingPathComponent(value.nativeBindingRelativePath))
        let capture = root.appendingPathComponent("capture")
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: capture)
        var app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: "test-native-product")
        app.canonicalBundlePath = product.path; app.sourceManifestDigest = try manifest.digest
        let supervisor = AutomationServedJavaScriptSupervisor()
        let firstIdentity = try await supervisor.withSession(profile: value, manifest: manifest, app: app,
            target: .init(id: "simulator", kind: .simulator), frozenRoot: capture.appendingPathComponent("source"),
            developerDirectory: URL(fileURLWithPath: "/usr"), supportRoot: root) { $0 }
        try Data("openssl_conf = another_unrelated_global_configuration\n".utf8).write(to: globalConfiguration)
        let secondIdentity = try await supervisor.withSession(profile: value, manifest: manifest, app: app,
            target: .init(id: "simulator", kind: .simulator), frozenRoot: capture.appendingPathComponent("source"),
            developerDirectory: URL(fileURLWithPath: "/usr"), supportRoot: root) { $0 }
        XCTAssertEqual(firstIdentity, secondIdentity)
        let completedSessions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("served-js-") }
        XCTAssertEqual(completedSessions.count, 2)
        for session in completedSessions {
            let logs = try String(contentsOf: session.appendingPathComponent("server.log"), encoding: .utf8)
            XCTAssertTrue(logs.contains("configuration-tamper-denied"), logs)
            try AutomationServedJavaScriptSupervisor.verifyNodeConfiguration(session.appendingPathComponent("openssl.cnf"))
        }
        enum Marker: Error { case operationFailed }
        do {
            let _: Bool = try await supervisor.withSession(profile: value, manifest: manifest, app: app,
                target: .init(id: "simulator", kind: .simulator), frozenRoot: capture.appendingPathComponent("source"),
                developerDirectory: URL(fileURLWithPath: "/usr"), supportRoot: root) { identity in
                    XCTAssertEqual(identity.nodeConfigurationSHA256, AutomationServedJavaScriptSupervisor.nodeConfigurationSHA256)
                    throw Marker.operationFailed
                }
            XCTFail("The failing operation returned success")
        } catch is Marker { }
        let available = try AutomationServedJavaScriptSupervisor.reserve(port: port); Darwin.close(available)
        var wrong = value; wrong.bundleSHA256 = String(repeating: "0", count: 64)
        wrong.recipeSHA256 = nil
        try JSONEncoder().encode(wrong).write(to: source.appendingPathComponent("server.json"))
        wrong = try .load(source: source, url: source.appendingPathComponent("server.json"))
        let secondCapture = root.appendingPathComponent("capture-wrong")
        let secondManifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: secondCapture)
        app.sourceManifestDigest = try secondManifest.digest
        do {
            let _: Bool = try await supervisor.withSession(profile: wrong, manifest: secondManifest, app: app,
                target: .init(id: "simulator", kind: .simulator), frozenRoot: secondCapture.appendingPathComponent("source"),
                developerDirectory: URL(fileURLWithPath: "/usr"), supportRoot: root) { _ in XCTFail("Wrong bytes reached operation"); return true }
            XCTFail("Wrong bytes became an identity")
        } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        let released = try AutomationServedJavaScriptSupervisor.reserve(port: port); Darwin.close(released)
    }
}
#endif
