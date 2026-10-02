import AppKit
import Foundation

enum TroubleCodePDFExporter {
    struct Report {
        let createdAt: Date
        let vehicleProfile: VehicleProfile?
        let moduleIdentification: ModuleIdentification?
        let entries: [Entry]
        let fordModules: [FordModuleIdentity]

        init(createdAt: Date, vehicleProfile: VehicleProfile?, moduleIdentification: ModuleIdentification?, entries: [Entry], fordModules: [FordModuleIdentity] = []) {
            self.createdAt = createdAt
            self.vehicleProfile = vehicleProfile
            self.moduleIdentification = moduleIdentification
            self.entries = entries
            self.fordModules = fordModules
        }
    }

    struct Entry {
        let code: DiagnosticCode
        let details: DTCDetails
    }

    static func export(_ report: Report, to url: URL) throws {
        let pageSize = CGSize(width: 612, height: 792) // US Letter at 72 pt/in
        let margin: CGFloat = 48
        let headerHeight: CGFloat = 34
        let footerHeight: CGFloat = 28
        let contentRect = CGRect(x: margin, y: margin + headerHeight, width: pageSize.width - (margin * 2), height: pageSize.height - (margin * 2) - headerHeight - footerHeight)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw OBDClientError.adapter("Could not create the PDF export file.")
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw OBDClientError.adapter("Could not initialize the PDF export.")
        }

        let storage = NSTextStorage(attributedString: makeContent(report))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var page = 0
        var lastGlyph = 0

        repeat {
            let container = NSTextContainer(size: contentRect.size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphRange = layout.glyphRange(for: container)
            guard glyphRange.length > 0 else { break }
            page += 1
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext

            drawHeader(page: page, in: CGRect(x: margin, y: margin, width: contentRect.width, height: headerHeight))
            layout.drawBackground(forGlyphRange: glyphRange, at: contentRect.origin)
            layout.drawGlyphs(forGlyphRange: glyphRange, at: contentRect.origin)
            drawFooter(page: page, in: CGRect(x: margin, y: pageSize.height - margin - footerHeight, width: contentRect.width, height: footerHeight))

            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            lastGlyph = NSMaxRange(glyphRange)
        } while lastGlyph < layout.numberOfGlyphs
        context.closePDF()
    }

    private static func makeContent(_ report: Report) -> NSAttributedString {
        let output = NSMutableAttributedString()
        func add(_ text: String, font: NSFont, color: NSColor = .black, after: String = "") {
            output.append(NSAttributedString(string: text + after, attributes: [.font: font, .foregroundColor: color]))
        }
        func list(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            add(title + "\n", font: .boldSystemFont(ofSize: 10))
            for item in items { add("- \(item)\n", font: .systemFont(ofSize: 10), color: .darkGray) }
            add("\n", font: .systemFont(ofSize: 3))
        }

        add("Ford Edge Diagnostic Report\n", font: .boldSystemFont(ofSize: 22))
        add("Generated \(report.createdAt.formatted(date: .long, time: .shortened))\n\n", font: .systemFont(ofSize: 10), color: .darkGray)

        add("Vehicle context\n", font: .boldSystemFont(ofSize: 14))
        if let profile = report.vehicleProfile {
            add("Vehicle: \(profile.summary.isEmpty ? "VIN decoded" : profile.summary)\n", font: .systemFont(ofSize: 10))
            if let powertrain = profile.powertrainSummary { add("Powertrain: \(powertrain)\n", font: .systemFont(ofSize: 10)) }
        }
        if let vin = report.moduleIdentification?.vin { add("VIN: \(vin)\n", font: .monospacedSystemFont(ofSize: 10, weight: .regular)) }
        if let calibration = report.moduleIdentification?.calibrationID { add("Calibration ID: \(calibration)\n", font: .monospacedSystemFont(ofSize: 10, weight: .regular)) }
        if let ecu = report.moduleIdentification?.ecuName { add("ECU name: \(ecu)\n", font: .monospacedSystemFont(ofSize: 10, weight: .regular)) }
        if !report.fordModules.isEmpty {
            add("Responding Ford modules\n", font: .boldSystemFont(ofSize: 11))
            for module in report.fordModules {
                add("\(module.name) | \(module.network) | request 0x\(module.requestHeader)\(module.softwareIdentifier.map { " | F187 identifier \($0)" } ?? "")\n", font: .monospacedSystemFont(ofSize: 9, weight: .regular), color: .darkGray)
            }
        }
        add("\n", font: .systemFont(ofSize: 4))

        let findings = DiagnosticTriage.findings(codes: report.entries.map(\.code), moduleVoltage: nil)
        if !findings.isEmpty {
            add("Diagnostic priorities\n", font: .boldSystemFont(ofSize: 14))
            for finding in findings {
                add("\(finding.severity.label): \(finding.title)\n", font: .boldSystemFont(ofSize: 10))
                add("\(finding.explanation)\n", font: .systemFont(ofSize: 10), color: .darkGray)
                list("Next steps", finding.nextSteps)
            }
        }

        let bulletins = FordServiceBulletinCatalog.matching(codes: report.entries.map(\.code), vehicle: report.vehicleProfile)
        if !bulletins.isEmpty {
            add("Applicable public Ford service notices\n", font: .boldSystemFont(ofSize: 14))
            for bulletin in bulletins {
                add("TSB \(bulletin.number): \(bulletin.title)\n", font: .boldSystemFont(ofSize: 10))
                add("\(bulletin.applicability)\n\(bulletin.repairSummary)\nPublic copy: \(bulletin.url.absoluteString)\n\n", font: .systemFont(ofSize: 9), color: .darkGray)
            }
        }

        for (index, entry) in report.entries.enumerated() {
            let details = entry.details
            add("\(entry.code.displayIdentifier) - \(details.title)\n", font: .boldSystemFont(ofSize: 15))
            add("\(entry.code.source) | \(details.system) | \(details.urgency.rawValue)\n", font: .systemFont(ofSize: 10), color: .darkGray)
            add("Guidance confidence: \(details.confidence.rawValue)\n", font: .systemFont(ofSize: 9), color: .darkGray)
            if let module = entry.code.module {
                let label = entry.code.hasEnhancedModuleContext ? "Reporting module" : "Addressed responder"
                add("\(label): \(module)\(entry.code.network.map { " (\($0))" } ?? "")\n", font: .systemFont(ofSize: 10), color: .darkGray)
            }
            if let status = entry.code.statusByte {
                let failureType = entry.code.failureTypeByte.map { " | Additional DTC byte: 0x\(String(format: "%02X", $0))" } ?? ""
                add("UDS status: 0x\(String(format: "%02X", status)) — \(entry.code.udsStatusSummary ?? "not decoded")\(failureType)\n", font: .monospacedSystemFont(ofSize: 9, weight: .regular), color: .darkGray)
            }
            if let source = details.source { add("Data source: \(source)\n", font: .systemFont(ofSize: 9), color: .darkGray) }
            add("\n\(details.description)\n", font: .systemFont(ofSize: 10))
            add("Safety guidance: \(details.urgency.advice)\n\n", font: .systemFont(ofSize: 10), color: .darkGray)
            list("Common causes", details.commonCauses)
            list("Typical symptoms", details.symptoms)
            list("How to confirm", details.diagnosticSteps)
            list("Repair path", details.repairGuidance)
            if index < report.entries.count - 1 { add("\n", font: .systemFont(ofSize: 8)) }
        }
        add("This report is diagnostic guidance, not a substitute for vehicle-specific Ford service procedures. Do not replace parts until the fault has been confirmed.\n", font: .systemFont(ofSize: 9), color: .darkGray)
        return output
    }

    private static func drawHeader(page: Int, in rect: CGRect) {
        let text = NSAttributedString(string: "Edge Diagnostics - Trouble-code report", attributes: [.font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: NSColor.darkGray])
        text.draw(at: rect.origin)
        let pageText = NSAttributedString(string: "Page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray])
        pageText.draw(at: CGPoint(x: rect.maxX - pageText.size().width, y: rect.minY))
    }

    private static func drawFooter(page: Int, in rect: CGRect) {
        let text = NSAttributedString(string: "Read-only OBD-II report - retain with service records", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.darkGray])
        text.draw(at: rect.origin)
    }
}
