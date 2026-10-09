#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacOwnedDaemonSessionTests: XCTestCase {
    private actor Captured {
        var values: [AutomationProcessIdentity] = []
        func add(_ value: AutomationProcessIdentity) { values.append(value) }
        func identities() -> [AutomationProcessIdentity] { values }
    }
    private actor Subject: AutomationSubjectVerifier {
        let fail: Bool
        let suspendAt: Int?
        var verifications = 0
        var entered = false
        var waiter: CheckedContinuation<Void, Never>?
        init(fail: Bool, suspendAt: Int?) { self.fail = fail; self.suspendAt = suspendAt }
        func verify(app: AppIdentity, target: TargetIdentity) async throws {
            verifications += 1
            if verifications == suspendAt { entered = true; await withCheckedContinuation { waiter = $0 } }
            if fail { throw AutomationContractError.conflictingOperation }
        }
        func hasEntered() -> Bool { entered }
        func resume() { waiter?.resume(); waiter = nil }
    }
    private actor Release: AutomationDeviceReleaseVerifier {
        let absent: Bool
        var prepared = 0, inspected = 0
        init(absent: Bool) { self.absent = absent }
        func prepare(target: TargetIdentity, controllerBundleIDs: [String]) async throws { prepared += 1 }
        func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) async -> Bool { inspected += 1; return absent }
        func counts() -> (Int, Int) { (prepared, inspected) }
    }
    private actor WorkerReview {
        var identities: [AutomationProcessIdentity] = []
        let suspend: Bool
        var entered = false
        var waiter: CheckedContinuation<Void, Never>?
        init(suspend: Bool) { self.suspend = suspend }
        func record(_ identity: AutomationProcessIdentity) async {
            identities.append(identity); entered = true
            if suspend { await withCheckedContinuation { waiter = $0 } }
        }
        func hasEntered() -> Bool { entered }
        func resume() { waiter?.resume(); waiter = nil }
        func captured() -> [AutomationProcessIdentity] { identities }
    }
    private actor WorkerBarrier {
        let enabled: Bool
        var arrivals = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        init(enabled: Bool) { self.enabled = enabled }
        func arrive() async {
            guard enabled else { return }
            arrivals += 1
            if arrivals >= 2 { finish(); return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func finish() { for waiter in waiters { waiter.resume() }; waiters = [] }
    }
    private struct Fixture {
        let root: URL, marker: URL
        let session: AutomationMacOwnedDaemonSession
        let leases: AutomationDeviceLeaseManager
        let lease: AutomationDeviceLeaseManager.Lease
        let release: Release
        let subject: Subject
        let captured: Captured
        let workerReview: WorkerReview
    }
    private func fixture(mode: String = "valid", absent: Bool = true, subjectFails: Bool = false, suspendSubject: Bool = false, suspendVerification: Int? = nil, suspendWorkerReview: Bool = false) async throws -> Fixture {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let node = repository.appendingPathComponent("Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node")
        guard FileManager.default.isExecutableFile(atPath: node.path) else { throw XCTSkip("Requires the provisioned private Node fixture runtime") }
        let workerModule = repository.appendingPathComponent("Tools/IntentsAutomation/dist/src/ownedUIWorker.js")
        if mode.hasPrefix("program-") && !FileManager.default.fileExists(atPath: workerModule.path) { throw XCTSkip("Requires the built owned worker fixture module") }
        let root = URL(fileURLWithPath: "/private/tmp/intents-native-daemon-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app"), marker = root.appendingPathComponent("marker"), ready = root.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let helper = root.appendingPathComponent("helper.mjs"), entry = root.appendingPathComponent("entry.mjs")
        let helperSource = #"""
        import fs from 'node:fs';import {setTimeout as sleep} from 'node:timers/promises';
        const [readyPath,marker,mode,bundlePath,...args]=process.argv.slice(2);
        while(!fs.existsSync(readyPath))await sleep(5);
        const ready=JSON.parse(fs.readFileSync(readyPath));
        if(ready.nonce!==process.env.INTENTS_MAC_HELPER_OWNERSHIP_NONCE || ready.identity.pid!==process.pid)process.exit(2);
        process.stdout.write(fs.readFileSync(readyPath));let input='';for await(const bytes of process.stdin)input+=bytes;
        const ack=JSON.parse(input);if(ack.kind!=='ack' || ack.nonce!==ready.nonce || ack.identity.pid!==process.pid)process.exit(3);
        fs.appendFileSync(marker,args[0]+'\n');
        const applicationTarget={bundleId:'example.Fixture',canonicalBundlePath:bundlePath,pid:123,processStartIdentity:'100:0'};
        let data=applicationTarget;
        if(args[0]==='snapshot'){
          if(mode==='hang')await sleep(60000);
          data={applicationTarget:mode==='changed-instance'?{...applicationTarget,pid:124}:applicationTarget,nodes:[],surface:'frontmost-app',backend:'macos-helper',truncated:false};
        }
        if(args[0]==='press')data={applicationTarget,x:10,y:20,disposition:'submittedUnconfirmed',releaseSubmitted:mode!=='uncertain'};
        process.stdout.write(JSON.stringify({ok:true,data}));
        """#
        try Data(helperSource.utf8).write(to: helper)
        // Synthetic protocol owner only. No claim that this script is the SDK.
        let entrySource = #"""
        import {randomUUID} from 'node:crypto';import fs from 'node:fs';
        const mode=fs.readFileSync(process.argv[process.argv.indexOf('--state-dir')+1]+'/fixture-mode','utf8');
        let frame='',scope,target,authentication,instance=null,ordinal=0,workerController,activeWorker,workerDrained=true;const pending=new Map();
        function send(value){process.stdout.write(JSON.stringify(value)+'\n');}
        function reverse(method,params){return new Promise((resolve,reject)=>{const id='reverse-'+(++ordinal);pending.set(id,{resolve,reject});send({jsonrpc:'2.0',id,method,params});});}
        async function native(action){
          const proof=await reverse('mac.helper.run',{authentication,request:{requestId:randomUUID(),scope,selection:{bundleId:target.bundleId,canonicalBundlePath:target.bundlePath},action,timeoutMs:60000}});
          if(!proof.startupAcknowledged || !proof.directChildReaped || !proof.pipesDrained || !proof.callbacksDrained)throw new Error('Synthetic command not drained');
          return JSON.parse(proof.stdout).data;
        }
        async function run(method,input){
          if(method==='hello'){({scope,target,authentication}=input);return {protocolVersion:1,artifactVariant:'private-owned-mac-daemon-integration',customerRuntimeEnabled:false,hardwareQualified:false};}
          if(method==='ui.acquire'){instance=await native({kind:'acquire'});return {applicationTarget:instance};}
          if(method==='ui.runSegment'){
            if(mode.startsWith('program-')){
              const {runOwnedUIWorker}=await import('\#(workerModule.absoluteString)');
              const state=process.argv[process.argv.indexOf('--state-dir')+1],entry=state+'/worker.mjs';
              fs.writeFileSync(entry,`import fs from 'node:fs';fs.writeFileSync(${JSON.stringify(state+'/worker-imported')},String(process.pid));`);
              workerController=new AbortController();
              const workerPIDs=[];
              const launch=()=>runOwnedUIWorker(entry,[],state,{PATH:'/usr/bin:/bin'},workerController.signal,10000,async pid=>{
                workerPIDs.push(pid);
                const result=await reverse('ui.workerStarted',{...scope,pid:mode==='program-foreign-parent'?process.pid:pid});
                if(!result.allowed)throw new Error('Worker denied');
                const policy=await reverse('policy.reviewAction',{...scope,action:{kind:'tap'}});
                if(!policy.allowed)throw new Error('Policy denied');
              });
              activeWorker=mode==='program-concurrent'?Promise.allSettled([launch(),launch()]).then(results=>{
                fs.writeFileSync(state+'/worker-results',JSON.stringify({statuses:results.map(result=>result.status),pids:workerPIDs}));
                if(results.filter(result=>result.status==='fulfilled').length!==1 || results.some(result=>result.status==='rejected' && result.reason.commandsDrained!==true))
                  throw new Error('Concurrent workers not fenced or drained');
              }):launch();
              try{
                await activeWorker;
                return {applicationTarget:instance,receipt:{schemaVersion:1,scope,operationId:input.operationId,complete:true,outputs:{}}};
              }catch(error){workerDrained=error.commandsDrained===true;throw error;}finally{activeWorker=undefined;}
            }
            if(!input.applicationTarget || Object.keys(instance).some(key=>input.applicationTarget[key]!==instance[key]))throw new Error('Wrong instance');
            if(input.operation==='capture'){const data=await native({kind:'snapshot',instance});return {...data,appBundleId:target.bundleId,identifiers:{session:`intents-${scope.runId}-${scope.leaseGeneration}`},refsGeneration:1};}
            const result=await native({kind:'press',instance,x:input.x,y:input.y});return mode==='wrong-point'?{...result,x:11}:result;
          }
          if(method==='shutdown'){
            workerController?.abort();try{await activeWorker;}catch{}
            const proof=await reverse('mac.helper.stop',{authentication,scope,applicationTarget:instance});
            return {...proof,commandsDrained:proof.commandsDrained && workerDrained,daemonStopped:true,subjectTerminated:false,resourcesReleased:proof.commandsDrained && workerDrained && proof.ownedHelperReaped};
          }
          throw new Error('Unsupported synthetic method');
        }
        process.stdin.on('data',bytes=>{frame+=bytes;while(frame.includes('\n')){
          const index=frame.indexOf('\n'),message=JSON.parse(frame.slice(0,index));frame=frame.slice(index+1);
          if(!message.method){const waiter=pending.get(message.id);pending.delete(message.id);message.error?waiter?.reject(new Error(message.error.message)):waiter?.resolve(message.result);continue;}
          void run(message.method,message.params).then(result=>send({jsonrpc:'2.0',id:message.id,result}),error=>send({jsonrpc:'2.0',id:message.id,error:{code:-32000,message:String(error)}}));
        }});
        process.stdin.on('end',()=>{for(const value of pending.values())value.reject(new Error('Pipe closed'));pending.clear();});
        """#
        try Data(entrySource.utf8).write(to: entry)
        try Data(mode.utf8).write(to: root.appendingPathComponent("fixture-mode"))
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login")
        var selected = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture", platform: "macos", productDigest: String(repeating: "a", count: 64))
        selected.canonicalBundlePath = app.path; selected.architecture = "arm64"; selected.configuration = "Debug"
        let identity = selected
        let leases = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "segment", leaseGeneration: lease.generation)
        let evidence = AutomationPrivateMacDaemonUnit.Evidence(receiptSHA256: String(repeating: "a", count: 64),
            checkpointSHA256: String(repeating: "b", count: 64), fileCount: 0, customerRuntimeEnabled: false, hardwareQualified: false, developerIDSigned: false)
        let loaded = AutomationPrivateMacDaemonUnit.Loaded(evidence: evidence, root: root, node: node, entry: entry, helper: helper)
        let release = Release(absent: absent)
        let subject = Subject(fail: subjectFails, suspendAt: suspendVerification ?? (suspendSubject ? 1 : nil))
        let captured = Captured()
        let workerReview = WorkerReview(suspend: suspendWorkerReview)
        let workerBarrier = WorkerBarrier(enabled: mode == "program-concurrent")
        addTeardownBlock { await workerBarrier.finish() }
        let dependencies = AutomationMacOwnedDaemonSession.Dependencies(unit: { _ in loaded }, bridge: { context in
            try AutomationMacNativeHelperBridge(executable: node, prefix: [helper.path, ready.path, marker.path, mode, app.path],
                directory: root, bundleID: identity.bundleID, bundlePath: app, scope: context.scope, lease: context.lease,
                leases: context.leases, authorize: { _ in try? FileManager.default.removeItem(at: ready) }, didCapture: { process, nonce in
                    let record = try await context.leases.currentRecord(context.lease)
                    guard record.runners.contains(where: { $0.process == process && $0.scope == context.scope && $0.role == .nativeCommand }) else { throw AutomationContractError.invalidIdentity }
                    await captured.add(process)
                    try AutomationMacHelperHandshake.ready(nonce: nonce, identity: process).write(to: ready, options: .atomic)
                })
        }, release: { _, _ in release }, subject: subject, beforeWorkerAdmission: { await workerBarrier.arrive() })
        let session = try await AutomationMacOwnedDaemonSession(unitRoot: root, app: identity, target: target, scope: scope,
            lease: lease, leases: leases, state: root, authorize: { _ in }, dependencies: dependencies, review: { method, _ in
                guard method == "policy.reviewAction" else { throw AutomationRPCError.invalidFrame }
                let record = try await leases.currentRecord(lease)
                let worker = try XCTUnwrap(record.runners.first(where: { $0.role == .uiWorker }))
                guard worker.scope == scope, worker.process.presence() == .matching,
                      !FileManager.default.fileExists(atPath: root.appendingPathComponent("worker-imported").path) else { throw AutomationContractError.invalidIdentity }
                await workerReview.record(worker.process)
                return .object(["allowed": .bool(true)])
            })
        addTeardownBlock { _ = await session.close() }
        return .init(root: root, marker: marker, session: session, leases: leases, lease: lease, release: release, subject: subject, captured: captured, workerReview: workerReview)
    }
    func testOwnedSyntheticChannelCapturesExactInstanceAndReleasesItsChildren() async throws {
        let fixture = try await fixture(), instance = try await fixture.session.open()
        let capture = try await fixture.session.capture(), press = try await fixture.session.press(x: 10, y: 20)
        XCTAssertEqual(capture.object?["applicationTarget"], instance); XCTAssertEqual(press.object?["applicationTarget"], instance)
        let record = try await fixture.leases.currentRecord(fixture.lease)
        XCTAssertEqual(record.runners.filter { $0.role == .sidecar }.count, 1)
        XCTAssertEqual(record.runners.filter { $0.role == .nativeCommand }.count, 0)
        let captured = await fixture.captured.identities(); XCTAssertEqual(captured.count, 3)
        let proof = await fixture.session.close()
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
        let again = await fixture.session.close(); XCTAssertTrue(again.runnerTerminated)
        for process in captured + record.runners.map(\.process) { XCTAssertNotEqual(process.presence(), .matching) }
        do { _ = try await fixture.session.capture(); XCTFail("Closed client captured") } catch {}
        try await fixture.leases.release(fixture.lease, commandsDrained: proof.commandsDrained, ownedRunnerTerminated: proof.runnerTerminated)
        XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), "app\nsnapshot\npress\n")
    }
    func testUncertainInputCannotSubmitAgain() async throws {
        let fixture = try await fixture(mode: "uncertain"); _ = try await fixture.session.open()
        do { _ = try await fixture.session.press(x: 10, y: 20); XCTFail("Uncertain input accepted") } catch {}
        do { _ = try await fixture.session.press(x: 10, y: 20); XCTFail("Uncertain input retried") } catch {}
        let proof = await fixture.session.close(); XCTAssertTrue(proof.runnerTerminated)
        XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), "app\npress\n")
    }
    func testDifferentAcknowledgedPointCannotAcceptOrRetryInput() async throws {
        let fixture = try await fixture(mode: "wrong-point"); _ = try await fixture.session.open()
        do { _ = try await fixture.session.press(x: 10, y: 20); XCTFail("Wrong input point accepted") } catch {}
        do { _ = try await fixture.session.press(x: 10, y: 20); XCTFail("Wrong input point retried") } catch {}
        _ = await fixture.session.close()
        XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), "app\npress\n")
    }
    func testChangedInstanceAndUnprovedAbsenceCannotBecomePositiveEvidence() async throws {
        let fixture = try await fixture(mode: "changed-instance", absent: false); _ = try await fixture.session.open()
        do { _ = try await fixture.session.capture(); XCTFail("Changed instance accepted") } catch {}
        let proof = await fixture.session.close(); XCTAssertTrue(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
        do { try await fixture.leases.release(fixture.lease, commandsDrained: proof.commandsDrained, ownedRunnerTerminated: proof.runnerTerminated); XCTFail("Unknown ownership released") } catch {}
        let retained = try await fixture.leases.currentRecord(fixture.lease); XCTAssertEqual(retained.control, .ui)
    }
    func testPreflightFailureCreatesNoOwnedProcessOrStrandedLease() async throws {
        let fixture = try await fixture(subjectFails: true)
        do { _ = try await fixture.session.open(); XCTFail("Wrong subject opened") } catch {}
        let proof = await fixture.session.close(); XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        let counts = await fixture.release.counts(); XCTAssertEqual(counts.0, 0)
        try await fixture.leases.release(fixture.lease, commandsDrained: proof.commandsDrained, ownedRunnerTerminated: proof.runnerTerminated)
    }
    func testConcurrentCancelledCloseDrainsPendingCaptureAndRetainsNegativeLease() async throws {
        let fixture = try await fixture(mode: "hang", absent: false); _ = try await fixture.session.open()
        let capture = Task { try await fixture.session.capture(timeoutMilliseconds: 60_000) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(try String(contentsOf: fixture.marker, encoding: .utf8)).contains("snapshot") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try String(contentsOf: fixture.marker, encoding: .utf8).contains("snapshot"))
        let first = Task { await fixture.session.close() }; first.cancel()
        let second = Task { await fixture.session.close() }
        let proof = await first.value, joined = await second.value
        XCTAssertTrue(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
        XCTAssertEqual(proof.commandsDrained, joined.commandsDrained); XCTAssertEqual(proof.runnerTerminated, joined.runnerTerminated)
        do { _ = try await capture.value; XCTFail("Revoked capture completed") } catch {}
        let counts = await fixture.release.counts(); XCTAssertEqual(counts.1, 1)
        let retained = try await fixture.leases.currentRecord(fixture.lease); XCTAssertEqual(retained.control, .ui)
        for runner in retained.runners { XCTAssertNotEqual(runner.process.presence(), .matching) }
        for process in await fixture.captured.identities() { XCTAssertNotEqual(process.presence(), .matching) }
    }
    func testProgramWorkerIsDurablyRecordedBeforeRuntimeImportAndReapedAfterwards() async throws {
        let fixture = try await fixture(mode: "program-valid")
        _ = try await fixture.session.open(programMode: true)
        let program = AutomationUIProgram(operations: [.init(id: "endpoint", kind: .assertEndpoint, locator: .init(.testId, "done"))])
        let receipt = try await fixture.session.runProgram(program, phase: .subject, operationID: "operation")
        XCTAssertEqual(receipt.object?["complete"], .bool(true))
        let workers = await fixture.workerReview.captured(); XCTAssertEqual(workers.count, 1)
        let imported = try String(contentsOf: fixture.root.appendingPathComponent("worker-imported"), encoding: .utf8)
        XCTAssertEqual(imported, String(try XCTUnwrap(workers.first).pid))
        let record = try await fixture.leases.currentRecord(fixture.lease)
        XCTAssertEqual(record.runners.filter { $0.role == .uiWorker }.map(\.process), workers)
        let proof = await fixture.session.close(); XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
        for worker in workers { XCTAssertNotEqual(worker.presence(), .matching) }
        do { _ = try await fixture.session.press(x: 10, y: 20); XCTFail("Program mode admitted raw input") } catch {}
    }
    func testConcurrentDifferentProgramWorkersCannotBothAcquireOneLease() async throws {
        let fixture = try await fixture(mode: "program-concurrent")
        _ = try await fixture.session.open(programMode: true)
        let program = AutomationUIProgram(operations: [.init(id: "endpoint", kind: .assertEndpoint, locator: .init(.testId, "done"))])
        _ = try await fixture.session.runProgram(program, phase: .subject, operationID: "operation")
        let record = try await fixture.leases.currentRecord(fixture.lease)
        XCTAssertEqual(record.runners.filter { $0.role == .uiWorker }.count, 1)
        let data = try Data(contentsOf: fixture.root.appendingPathComponent("worker-results"))
        let result = try JSONDecoder().decode(AutomationJSON.self, from: data)
        guard case .array(let statuses) = result.object?["statuses"], case .array(let pids) = result.object?["pids"] else { return XCTFail("Missing concurrent worker evidence") }
        XCTAssertEqual(statuses.filter { $0 == .string("fulfilled") }.count, 1)
        XCTAssertEqual(statuses.filter { $0 == .string("rejected") }.count, 1)
        XCTAssertEqual(pids.count, 2)
        for pid in pids { guard case .number(let value) = pid else { return XCTFail("Malformed worker PID") }; XCTAssertNil(AutomationProcessIdentity.inspect(pid: Int32(value))) }
        let proof = await fixture.session.close(); XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
    }
    func testProgramCannotRecordSidecarAsItsOwnWorkerOrImportAfterRejection() async throws {
        let fixture = try await fixture(mode: "program-foreign-parent")
        _ = try await fixture.session.open(programMode: true)
        let program = AutomationUIProgram(operations: [.init(id: "endpoint", kind: .assertEndpoint, locator: .init(.testId, "done"))])
        do { _ = try await fixture.session.runProgram(program, phase: .subject, operationID: "operation"); XCTFail("Wrong worker parent accepted") } catch {}
        let record = try await fixture.leases.currentRecord(fixture.lease)
        XCTAssertTrue(record.runners.filter { $0.role == .uiWorker }.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("worker-imported").path))
        let proof = await fixture.session.close(); XCTAssertTrue(proof.commandsDrained)
    }
    func testCloseDuringProgramPolicySuspensionCannotAcknowledgeLateWorkerImport() async throws {
        let fixture = try await fixture(mode: "program-valid", suspendWorkerReview: true)
        _ = try await fixture.session.open(programMode: true)
        let program = AutomationUIProgram(operations: [.init(id: "endpoint", kind: .assertEndpoint, locator: .init(.testId, "done"))])
        let running = Task { try await fixture.session.runProgram(program, phase: .subject, operationID: "operation") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await fixture.workerReview.hasEntered()) && ContinuousClock.now < deadline { await Task.yield() }
        let entered = await fixture.workerReview.hasEntered(); XCTAssertTrue(entered)
        let closing = Task { await fixture.session.close() }; closing.cancel()
        while await fixture.session.admitsWork(), ContinuousClock.now < deadline { await Task.yield() }
        await fixture.workerReview.resume()
        do { _ = try await running.value; XCTFail("Revoked program completed") } catch {}
        let proof = await closing.value; XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("worker-imported").path))
        for worker in await fixture.workerReview.captured() { XCTAssertNotEqual(worker.presence(), .matching) }
    }
    func testCloseDuringFinalSubjectCheckRejectsCaptureAndPress() async throws {
        for operation in ["capture", "press"] {
            let fixture = try await fixture(suspendVerification: 4)
            _ = try await fixture.session.open()
            let request = Task {
                if operation == "capture" { return try await fixture.session.capture() }
                return try await fixture.session.press(x: 10, y: 20)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await fixture.subject.hasEntered()) && ContinuousClock.now < deadline { await Task.yield() }
            let entered = await fixture.subject.hasEntered(); XCTAssertTrue(entered)
            let closing = Task { await fixture.session.close() }
            while await fixture.session.admitsWork(), ContinuousClock.now < deadline { await Task.yield() }
            await fixture.subject.resume()
            do { _ = try await request.value; XCTFail("Closed operation accepted after final subject suspension") } catch {}
            let proof = await closing.value
            XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
            for process in await fixture.captured.identities() { XCTAssertNotEqual(process.presence(), .matching) }
            XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), "app\n" + (operation == "capture" ? "snapshot\n" : "press\n"))
        }
    }
    func testCloseDuringSuspendedOpenCannotLaunchLateChild() async throws {
        let fixture = try await fixture(suspendSubject: true)
        let open = Task { try await fixture.session.open() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await fixture.subject.hasEntered()) && ContinuousClock.now < deadline { await Task.yield() }
        let entered = await fixture.subject.hasEntered(); XCTAssertTrue(entered)
        let closing = Task { await fixture.session.close() }; closing.cancel()
        while await fixture.session.admitsWork(), ContinuousClock.now < deadline { await Task.yield() }
        await fixture.subject.resume()
        let proof = await closing.value
        do { _ = try await open.value; XCTFail("Revoked startup completed") } catch {}
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
        let counts = await fixture.release.counts(); XCTAssertEqual(counts.0, 0)
        let record = try await fixture.leases.currentRecord(fixture.lease); XCTAssertTrue(record.runners.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
    }
}
#endif
