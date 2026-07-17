import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Source metadata

struct SourceInfo {
    var width = 0
    var height = 0
    var fpsNum = 30000
    var fpsDen = 1001
    var frames = 0
    var duration = 0.0
    var codec = ""
    var profile = ""
    var pixFmt = ""
    var fieldOrder = "progressive"
    var timecode: String? = nil
    var colorPrimaries: String? = nil
    var colorTrc: String? = nil
    var colorSpace: String? = nil

    var fpsLabel: String {
        let f = Double(fpsNum) / Double(fpsDen)
        return f == f.rounded() ? String(format: "%.0f", f) : String(format: "%.3f", f)
    }
}

// MARK: - Cadence analysis

struct CadenceResult {
    enum Kind { case clean, skip, dupBlend, irregular }
    var kind: Kind
    var period = 0
    var phase = 0
    var spikes = 0
    var dips = 0
    var periodicity = 0.0   // fraction of gaps equal to the modal period
    var coverage = 0.0      // detected events vs expected for a full-clip cadence
    var meanDiff = 0.0
    var metricFrames = 0
    var note = ""

    init(kind: Kind) { self.kind = kind }
}

enum CadenceAnalyzer {
    /// Per-transition motion metric -> classification.
    /// diffs[i] = mean abs difference between frame i and frame i+1 (0-based).
    static func analyze(_ d: [Double]) -> CadenceResult {
        let n = d.count
        guard n > 20 else {
            var r = CadenceResult(kind: .clean)
            r.metricFrames = n
            r.note = "too short to analyze"
            return r
        }
        let mean = d.reduce(0, +) / Double(n)
        var spikes: [Int] = []
        var dips: [Int] = []
        for i in 2..<(n - 2) {
            let m = (d[i - 2] + d[i - 1] + d[i + 1] + d[i + 2]) / 4
            guard m > 0.2 else { continue }
            if d[i] > 1.45 * m { spikes.append(i) }
            else if d[i] < 0.55 * m { dips.append(i) }
        }

        func periodPhase(_ idx: [Int]) -> (period: Int, phase: Int, frac: Double)? {
            guard idx.count >= 6 else { return nil }
            var gaps: [Int: Int] = [:]
            for k in 1..<idx.count { gaps[idx[k] - idx[k - 1], default: 0] += 1 }
            guard let best = gaps.max(by: { $0.value < $1.value }),
                  best.key >= 2, best.key <= 12 else { return nil }
            let frac = Double(best.value) / Double(idx.count - 1)
            var phases: [Int: Int] = [:]
            for i in idx { phases[i % best.key, default: 0] += 1 }
            let phase = phases.max(by: { $0.value < $1.value })!.key
            return (best.key, phase, frac)
        }

        if let dp = periodPhase(dips), dp.frac >= 0.7 {
            var r = CadenceResult(kind: .dupBlend)
            r.period = dp.period; r.phase = dp.phase
            r.spikes = spikes.count; r.dips = dips.count
            r.periodicity = dp.frac
            r.coverage = Double(dips.count) / (Double(n) / Double(dp.period))
            r.meanDiff = mean; r.metricFrames = n
            r.note = "periodic duplicate/blend frames — use pulldown removal, not rebuild"
            return r
        }
        if let sp = periodPhase(spikes), sp.frac >= 0.7 {
            var r = CadenceResult(kind: .skip)
            r.period = sp.period; r.phase = sp.phase
            r.spikes = spikes.count; r.dips = dips.count
            r.periodicity = sp.frac
            r.coverage = Double(spikes.count) / (Double(n) / Double(sp.period))
            r.meanDiff = mean; r.metricFrames = n
            return r
        }
        if spikes.count >= 8 || dips.count >= 8 {
            var r = CadenceResult(kind: .irregular)
            r.spikes = spikes.count; r.dips = dips.count
            r.meanDiff = mean; r.metricFrames = n
            r.note = "motion irregularities without a fixed period"
            return r
        }
        var r = CadenceResult(kind: .clean)
        r.spikes = spikes.count; r.dips = dips.count
        r.meanDiff = mean; r.metricFrames = n
        if mean < 0.15 { r.note = "very low motion — low confidence" }
        return r
    }
}

// MARK: - Verification

struct VerifyResult {
    var frames = 0
    var expected = 0
    var residualPeriodic = false
    var residualSpikes = 0
    var ok = false
    var outPath = ""
}

// MARK: - Job

enum JobState: Equatable {
    case queued, probing, scanning, analyzed, waitingRepair, repairing, verifying, fixed, failed
}

struct ClipJob: Identifiable {
    let id = UUID()
    let url: URL
    var state: JobState = .queued
    var info: SourceInfo? = nil
    var analysis: CadenceResult? = nil
    var verify: VerifyResult? = nil
    var errorMessage = ""
    var progressFrame = 0
    var expectedOut = 0

    var isRepairable: Bool {
        state == .analyzed && analysis?.kind == .skip
    }
}

// MARK: - Settings

enum TargetRate: String, CaseIterable, Identifiable {
    case r2398 = "23.976p"
    case r25 = "25p"
    case r2997 = "29.97p"
    var id: String { rawValue }
    var fraction: (Int, Int) {
        switch self {
        case .r2398: return (24000, 1001)
        case .r25: return (25, 1)
        case .r2997: return (30000, 1001)
        }
    }
    var suffix: String {
        switch self {
        case .r2398: return "_2398p"
        case .r25: return "_25p"
        case .r2997: return "_2997p"
        }
    }
}

enum ProResProfile: Int, CaseIterable, Identifiable {
    case lt = 1, standard = 2, hq = 3
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .lt: return "ProRes LT"
        case .standard: return "ProRes 422"
        case .hq: return "ProRes HQ"
        }
    }
}

// MARK: - Process runner

enum ProcError: LocalizedError {
    case toolMissing(String)
    case failed(Int32, String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .toolMissing(let t): return "\(t) not found — install with: brew install ffmpeg"
        case .failed(let code, let tail): return "exit \(code): \(tail)"
        case .cancelled: return "cancelled"
        }
    }
}

enum FF {
    static let ffmpeg = find("ffmpeg")
    static let ffprobe = find("ffprobe")
    static func find(_ name: String) -> String? {
        // Bundled copy first (Contents/Helpers), then common system locations.
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(name)").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let candidates = ["/opt/homebrew/bin/", "/usr/local/bin/", "/opt/local/bin/", "/usr/bin/"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c + name) {
            return c + name
        }
        return nil
    }
    static var isBundled: Bool { ffmpeg?.contains("Contents/Helpers") == true }
}

enum Runner {
    /// Runs a process, returns stdout. onLine receives stdout lines as they arrive.
    @discardableResult
    static func run(_ exe: String,
                    _ args: [String],
                    onLine: ((String) -> Void)? = nil,
                    register: ((Process) -> Void)? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            let lock = NSLock()
            var outData = Data()
            var errData = Data()
            var lineBuf = ""
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                lock.lock()
                outData.append(d)
                var pending: [String] = []
                if let s = String(data: d, encoding: .utf8) {
                    lineBuf += s
                    var parts = lineBuf.components(separatedBy: "\n")
                    lineBuf = parts.removeLast()
                    pending = parts
                }
                lock.unlock()
                if let cb = onLine { for l in pending { cb(l) } }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                lock.lock(); errData.append(d); lock.unlock()
            }
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                lock.unlock()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: stdout)
                } else if proc.terminationStatus == 15 || proc.terminationReason == .uncaughtSignal {
                    cont.resume(throwing: ProcError.cancelled)
                } else {
                    cont.resume(throwing: ProcError.failed(proc.terminationStatus, String(stderr.suffix(600))))
                }
            }
            do {
                try p.run()
                register?(p)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

// MARK: - Media engine

enum MediaEngine {
    static func probe(_ path: String) async throws -> SourceInfo {
        guard let ffprobe = FF.ffprobe else { throw ProcError.toolMissing("ffprobe") }
        let out = try await Runner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries",
            "stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,nb_frames,duration,field_order,color_primaries,color_transfer,color_space:stream_tags=timecode",
            "-of", "json", path
        ])
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = obj["streams"] as? [[String: Any]],
              let s = streams.first else {
            throw ProcError.failed(-1, "no video stream found")
        }
        var info = SourceInfo()
        info.width = s["width"] as? Int ?? 0
        info.height = s["height"] as? Int ?? 0
        info.codec = s["codec_name"] as? String ?? "?"
        info.profile = s["profile"] as? String ?? ""
        info.pixFmt = s["pix_fmt"] as? String ?? ""
        info.fieldOrder = s["field_order"] as? String ?? "progressive"
        info.colorPrimaries = s["color_primaries"] as? String
        info.colorTrc = s["color_transfer"] as? String
        info.colorSpace = s["color_space"] as? String
        if let r = s["r_frame_rate"] as? String {
            let parts = r.split(separator: "/")
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > 0 {
                info.fpsNum = a; info.fpsDen = b
            }
        }
        info.frames = Int(s["nb_frames"] as? String ?? "") ?? 0
        info.duration = Double(s["duration"] as? String ?? "") ?? 0
        if let tags = s["tags"] as? [String: Any], let tc = tags["timecode"] as? String {
            info.timecode = tc.replacingOccurrences(of: ";", with: ":")
        }
        return info
    }

    /// Low-res grayscale consecutive-frame difference scan. Returns one YAVG per transition.
    static func scanDiffs(_ path: String, register: ((Process) -> Void)? = nil) async throws -> [Double] {
        guard let ffmpeg = FF.ffmpeg else { throw ProcError.toolMissing("ffmpeg") }
        let tmp = NSTemporaryDirectory() + "cadscan_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        _ = try await Runner.run(ffmpeg, [
            "-hide_banner", "-nostats", "-loglevel", "error",
            "-i", path,
            "-vf", "scale=480:270,format=gray,tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=\(tmp)",
            "-f", "null", "-"
        ], register: register)
        var vals: [Double] = []
        if let content = try? String(contentsOfFile: tmp, encoding: .utf8) {
            for line in content.split(separator: "\n") where line.contains("YAVG=") {
                if let r = line.range(of: "YAVG=") {
                    vals.append(Double(line[r.upperBound...]) ?? 0)
                }
            }
        }
        return vals
    }
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    @Published var jobs: [ClipJob] = []
    @Published var outputDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/CADENCE_FIXED")
    @Published var targetRate: TargetRate = .r2398
    @Published var proresProfile: ProResProfile = .hq
    @Published var toolsMissing = (FF.ffmpeg == nil || FF.ffprobe == nil)

    private var running: [UUID: Process] = [:]
    private var repairQueue: [UUID] = []
    private var repairWorkerActive = false
    private var scansActive = 0
    private var scanWaitQueue: [UUID] = []

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mkv"]

    // MARK: intake

    func addURLs(_ urls: [URL]) {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let en = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                          options: [.skipsHiddenFiles]) {
                    for case let f as URL in en
                    where Self.videoExtensions.contains(f.pathExtension.lowercased()) {
                        files.append(f)
                    }
                }
            } else if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        let existing = Set(jobs.map { $0.url.path })
        for f in files.sorted(by: { $0.path < $1.path }) where !existing.contains(f.path) {
            let job = ClipJob(url: f)
            jobs.append(job)
            scheduleScan(job.id)
        }
    }

    // MARK: helpers

    private func update(_ id: UUID, _ mutate: (inout ClipJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[i])
    }

    private func job(_ id: UUID) -> ClipJob? { jobs.first(where: { $0.id == id }) }

    // MARK: scanning (max 2 concurrent)

    private func scheduleScan(_ id: UUID) {
        if scansActive < 2 {
            scansActive += 1
            Task { await self.scan(id) }
        } else {
            scanWaitQueue.append(id)
        }
    }

    private func scanFinished() {
        scansActive -= 1
        if !scanWaitQueue.isEmpty {
            let next = scanWaitQueue.removeFirst()
            scansActive += 1
            Task { await self.scan(next) }
        }
    }

    private func scan(_ id: UUID) async {
        defer { scanFinished() }
        guard let j = job(id) else { return }
        do {
            update(id) { $0.state = .probing }
            let info = try await MediaEngine.probe(j.url.path)
            update(id) { $0.info = info }
            if info.fieldOrder != "progressive" && !info.fieldOrder.isEmpty && info.fieldOrder != "unknown" {
                update(id) {
                    $0.state = .analyzed
                    var r = CadenceResult(kind: .irregular)
                    r.note = "flagged \(info.fieldOrder) — deinterlace workflow needed"
                    $0.analysis = r
                }
                return
            }
            update(id) { $0.state = .scanning }
            let diffs = try await MediaEngine.scanDiffs(j.url.path) { [weak self] p in
                Task { @MainActor in self?.running[id] = p }
            }
            running[id] = nil
            var result = CadenceAnalyzer.analyze(diffs)
            if result.kind == .skip {
                result.note = "1 frame dropped every \(result.period + 1) — rebuild will restore true motion"
            }
            update(id) {
                $0.analysis = result
                $0.state = .analyzed
                if $0.info?.frames == 0 { $0.info?.frames = diffs.count + 1 }
            }
        } catch {
            running[id] = nil
            update(id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
        }
    }

    // MARK: repairing (serial)

    func enqueueRepair(_ ids: [UUID]) {
        for id in ids where job(id)?.isRepairable == true && !repairQueue.contains(id) {
            repairQueue.append(id)
            update(id) { $0.state = .waitingRepair }
        }
        if !repairWorkerActive && !repairQueue.isEmpty {
            repairWorkerActive = true
            Task { await self.repairWorker() }
        }
    }

    func repairAll() {
        enqueueRepair(jobs.filter { $0.isRepairable }.map { $0.id })
    }

    private func repairWorker() async {
        while !repairQueue.isEmpty {
            let id = repairQueue.removeFirst()
            await repair(id)
        }
        repairWorkerActive = false
    }

    func cancel(_ id: UUID) {
        repairQueue.removeAll { $0 == id }
        if let p = running[id] { p.terminate() }
        else { update(id) { if $0.state == .waitingRepair { $0.state = .analyzed } } }
    }

    private func repair(_ id: UUID) async {
        guard let ffmpeg = FF.ffmpeg,
              let j = job(id), j.state == .waitingRepair,
              let info = j.info, let a = j.analysis, a.kind == .skip else { return }

        let frames = a.metricFrames + 1
        let period = a.period
        let offset = period - 1 - a.phase
        let lastPos = (frames - 1) + ((frames - 1) + offset) / period
        let trueDuration = Double(lastPos) * Double(info.fpsDen) / Double(info.fpsNum)
        let (tn, td) = targetRate.fraction
        let expected = Int(trueDuration * Double(tn) / Double(td)) + 1

        let base = j.url.deletingPathExtension().lastPathComponent
        let outURL = outputDir.appendingPathComponent(base + targetRate.suffix + ".mov")

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            update(id) { $0.state = .failed; $0.errorMessage = "cannot create output folder" }
            return
        }

        let vf = "setpts='((N+floor((N+\(offset))/\(period)))*\(info.fpsDen)/\(info.fpsNum))/TB',"
               + "minterpolate=fps=\(tn)/\(td):mi_mode=mci:mc_mode=aobmc:me_mode=bidir"

        var args: [String] = [
            "-hide_banner", "-nostats", "-loglevel", "error",
            "-progress", "pipe:1", "-y",
            "-i", j.url.path,
            "-map", "0:v:0", "-an",
            "-vf", vf,
            "-c:v", "prores_ks", "-profile:v", "\(proresProfile.rawValue)",
            "-pix_fmt", "yuv422p10le", "-vendor", "apl0"
        ]
        if let p = info.colorPrimaries { args += ["-color_primaries", p] }
        if let t = info.colorTrc { args += ["-color_trc", t] }
        if let c = info.colorSpace { args += ["-colorspace", c] }
        if let tc = info.timecode { args += ["-timecode", tc] }
        args.append(outURL.path)

        update(id) { $0.state = .repairing; $0.progressFrame = 0; $0.expectedOut = expected }

        do {
            _ = try await Runner.run(ffmpeg, args, onLine: { [weak self] line in
                guard line.hasPrefix("frame="),
                      let f = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) else { return }
                Task { @MainActor in self?.update(id) { $0.progressFrame = f } }
            }, register: { [weak self] p in
                Task { @MainActor in self?.running[id] = p }
            })
            running[id] = nil
            update(id) { $0.state = .verifying }
            await verify(id, outURL: outURL, expected: expected)
        } catch {
            running[id] = nil
            try? FileManager.default.removeItem(at: outURL)
            update(id) {
                $0.state = .failed
                $0.errorMessage = (error as? ProcError).map { $0.localizedDescription } ?? error.localizedDescription
            }
        }
    }

    private func verify(_ id: UUID, outURL: URL, expected: Int) async {
        do {
            let outInfo = try await MediaEngine.probe(outURL.path)
            let diffs = try await MediaEngine.scanDiffs(outURL.path)
            let res = CadenceAnalyzer.analyze(diffs)
            var v = VerifyResult()
            v.frames = outInfo.frames > 0 ? outInfo.frames : diffs.count + 1
            v.expected = expected
            v.residualPeriodic = (res.kind == .skip || res.kind == .dupBlend)
            v.residualSpikes = res.spikes
            v.outPath = outURL.path
            v.ok = abs(v.frames - expected) <= 3 && !v.residualPeriodic
            update(id) { $0.verify = v; $0.state = .fixed }
        } catch {
            update(id) { $0.state = .failed; $0.errorMessage = "verify failed: \(error.localizedDescription)" }
        }
    }

    // MARK: pickers

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose clips or folders to scan for cadence damage"
        if panel.runModal() == .OK { addURLs(panel.urls) }
    }

    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder for repaired clips"
        if panel.runModal() == .OK, let url = panel.urls.first { outputDir = url }
    }

    var summary: String {
        let analyzed = jobs.filter { $0.state == .analyzed || $0.state == .fixed }
        let repairable = jobs.filter { $0.isRepairable }.count
        let fixed = jobs.filter { $0.state == .fixed }.count
        let clean = analyzed.filter { $0.analysis?.kind == .clean }.count
        var parts: [String] = []
        if !jobs.isEmpty { parts.append("\(jobs.count) clip\(jobs.count == 1 ? "" : "s")") }
        if clean > 0 { parts.append("\(clean) clean") }
        if repairable > 0 { parts.append("\(repairable) repairable") }
        if fixed > 0 { parts.append("\(fixed) fixed") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Palette

enum Palette {
    static let bg = Color(red: 0.078, green: 0.086, blue: 0.106)
    static let card = Color(red: 0.118, green: 0.129, blue: 0.157)
    static let cardBorder = Color.white.opacity(0.07)
    static let accent = Color(red: 0.38, green: 0.72, blue: 0.98)
    static let good = Color(red: 0.36, green: 0.80, blue: 0.52)
    static let warn = Color(red: 0.98, green: 0.72, blue: 0.28)
    static let bad = Color(red: 0.95, green: 0.42, blue: 0.42)
    static let dim = Color.white.opacity(0.55)
}

// MARK: - Views

struct StatusChip: View {
    let text: String
    let color: Color
    var pulsing = false
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
            .foregroundStyle(color)
    }
}

struct JobRow: View {
    let job: ClipJob
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            statusIcon
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.url.path)
                Text(metaLine)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
                if !detailLine.isEmpty {
                    Text(detailLine)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(detailColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.card)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.cardBorder))
        )
    }

    private var metaLine: String {
        guard let i = job.info else { return job.url.deletingLastPathComponent().path }
        var s = "\(i.width)×\(i.height) · \(i.fpsLabel) fps · \(i.frames) frames · \(String(format: "%.2f", i.duration))s · \(i.codec.uppercased()) \(i.profile)"
        if let tc = i.timecode { s += " · TC \(tc)" }
        return s
    }

    private var detailLine: String {
        switch job.state {
        case .analyzed, .waitingRepair, .repairing, .verifying:
            guard let a = job.analysis else { return "" }
            switch a.kind {
            case .skip:
                return "Skip cadence · period \(a.period), phase \(a.phase) · \(a.spikes) events · periodicity \(Int(a.periodicity * 100))% · \(a.note)"
            case .dupBlend:
                return "Dup/blend cadence · period \(a.period) · \(a.dips) events · \(a.note)"
            case .irregular:
                return "Irregular · \(a.spikes) spikes, \(a.dips) dips · \(a.note)"
            case .clean:
                return a.note.isEmpty ? "" : a.note
            }
        case .fixed:
            guard let v = job.verify else { return "" }
            let name = (v.outPath as NSString).lastPathComponent
            return "\(name) · \(v.frames) frames (expected \(v.expected)) · residual cadence: \(v.residualPeriodic ? "FOUND" : "none")"
        case .failed:
            return job.errorMessage
        default:
            return ""
        }
    }

    private var detailColor: Color {
        switch job.state {
        case .failed: return Palette.bad
        case .fixed: return (job.verify?.ok == true) ? Palette.good : Palette.warn
        default:
            switch job.analysis?.kind {
            case .skip: return Palette.warn
            case .dupBlend: return Palette.warn
            default: return Palette.dim
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .queued, .probing, .scanning:
            ProgressView().controlSize(.small)
        case .analyzed, .waitingRepair:
            switch job.analysis?.kind {
            case .clean: Image(systemName: "checkmark.circle").foregroundStyle(Palette.good).font(.system(size: 16))
            case .skip: Image(systemName: "waveform.path.badge.minus").foregroundStyle(Palette.warn).font(.system(size: 15))
            case .dupBlend: Image(systemName: "square.on.square").foregroundStyle(Palette.warn).font(.system(size: 15))
            default: Image(systemName: "questionmark.circle").foregroundStyle(Palette.dim).font(.system(size: 16))
            }
        case .repairing, .verifying:
            ProgressView().controlSize(.small)
        case .fixed:
            Image(systemName: (job.verify?.ok == true) ? "checkmark.seal.fill" : "checkmark.seal")
                .foregroundStyle((job.verify?.ok == true) ? Palette.good : Palette.warn)
                .font(.system(size: 16))
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.bad).font(.system(size: 16))
        }
    }

    @ViewBuilder private var trailing: some View {
        switch job.state {
        case .queued:
            StatusChip(text: "QUEUED", color: Palette.dim)
        case .probing:
            StatusChip(text: "PROBING", color: Palette.accent)
        case .scanning:
            StatusChip(text: "SCANNING", color: Palette.accent)
        case .analyzed:
            HStack(spacing: 8) {
                switch job.analysis?.kind {
                case .clean: StatusChip(text: "CLEAN", color: Palette.good)
                case .skip:
                    StatusChip(text: "SKIP CADENCE", color: Palette.warn)
                    Button("Repair") { model.enqueueRepair([job.id]) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Palette.accent)
                case .dupBlend: StatusChip(text: "NEEDS REVIEW", color: Palette.warn)
                case .irregular: StatusChip(text: "IRREGULAR", color: Palette.dim)
                case .none: StatusChip(text: "—", color: Palette.dim)
                }
            }
        case .waitingRepair:
            HStack(spacing: 8) {
                StatusChip(text: "WAITING", color: Palette.accent)
                Button { model.cancel(job.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim)
            }
        case .repairing:
            HStack(spacing: 10) {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 150)
                    .tint(Palette.accent)
                Text("\(Int(progressFraction * 100))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.accent)
                    .frame(width: 36, alignment: .trailing)
                Button { model.cancel(job.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim)
                    .help("Cancel repair")
            }
        case .verifying:
            StatusChip(text: "VERIFYING", color: Palette.accent)
        case .fixed:
            HStack(spacing: 8) {
                StatusChip(text: (job.verify?.ok == true) ? "FIXED ✓ VERIFIED" : "FIXED — CHECK",
                           color: (job.verify?.ok == true) ? Palette.good : Palette.warn)
                Button {
                    if let v = job.verify {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: v.outPath)])
                    }
                } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim)
                    .help("Reveal in Finder")
            }
        case .failed:
            StatusChip(text: "FAILED", color: Palette.bad)
        }
    }

    private var progressFraction: Double {
        guard job.expectedOut > 0 else { return 0 }
        return min(1, Double(job.progressFrame) / Double(job.expectedOut))
    }
}

struct DropZone: View {
    @Binding var targeted: Bool
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(targeted ? Palette.accent : Palette.dim)
            Text("Drop clips or folders to scan")
                .font(.system(size: 15, weight: .medium))
            Text("Detects baked-in cadence damage — dropped-frame judder, duplicate/blend pulldown,\ninterlacing — then rebuilds clean ProRes at your target rate with motion-compensated interpolation.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundStyle(targeted ? Palette.accent : Color.white.opacity(0.14))
                .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Palette.accent.opacity(0.06) : .clear))
        )
        .padding(22)
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.06))
            if model.toolsMissing {
                missingToolsBanner
            }
            if model.jobs.isEmpty {
                DropZone(targeted: $dropTargeted)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.jobs) { job in
                            JobRow(job: job)
                        }
                    }
                    .padding(14)
                }
            }
            Divider().overlay(Color.white.opacity(0.06))
            footer
        }
        .frame(minWidth: 940, minHeight: 580)
        .background(Palette.bg)
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in model.addURLs([url]) }
                }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Palette.accent.opacity(0.85), Palette.accent.opacity(0.35)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Cadence Doctor")
                    .font(.system(size: 16, weight: .semibold))
                Text("Frame-cadence QC & repair · motion-compensated rebuild")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.dim)
            }
            Spacer()
            HStack(spacing: 10) {
                Picker("", selection: $model.targetRate) {
                    ForEach(TargetRate.allCases) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
                .help("Target frame rate for repaired output")

                Picker("", selection: $model.proresProfile) {
                    ForEach(ProResProfile.allCases) { p in Text(p.label).tag(p) }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                .help("Output codec profile")

                Button {
                    model.pickOutputDir()
                } label: {
                    Label(model.outputDir.lastPathComponent, systemImage: "folder")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .help("Output folder: \(model.outputDir.path)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var missingToolsBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn)
            Text("ffmpeg / ffprobe not found. Install with:  brew install ffmpeg   — then relaunch.")
                .font(.system(size: 11.5, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.warn.opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.summary)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Palette.dim)
            Spacer()
            Button("Add Files…") { model.pickFiles() }
                .controlSize(.regular)
            Button("Repair All Repairable") { model.repairAll() }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.regular)
                .disabled(!model.jobs.contains { $0.isRepairable })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - App

@main
struct CadenceDoctorApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Cadence Doctor") {
            ContentView()
                .environmentObject(model)
        }
    }
}
