import XCTest
import AppKit
import ImageIO
import PDFKit
@testable import SortyLib

final class ImageVisionAnalyzerTests: XCTestCase {
    private var tempDirectory: URL!

    func testVisionPayloadBudgetUsesEncodedSize() {
        let image = Data(repeating: 0, count: 3)
        let payload = ["a": image, "b": image]

        XCTAssertEqual(VisionPayloadBudget.totalBase64Bytes(for: payload), 8)
        XCTAssertEqual(VisionPayloadBudget.clamped(payload, cap: 7), ["a": image])
    }

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        ImageVisionAnalyzer.clearSharedCache()
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        ImageVisionAnalyzer.clearSharedCache()
    }

    func testPrepareImageForVisionResizesLargeImage() async throws {
        let imageURL = tempDirectory.appendingPathComponent("large.png")
        try createPNG(at: imageURL, width: 2000, height: 1000)

        let analyzer = ImageVisionAnalyzer()
        let data = await analyzer.prepareImageForVision(at: imageURL)

        XCTAssertNotNil(data)
        let dimensions = imageDimensions(from: data)
        XCTAssertEqual(dimensions?.width, 1024)
        XCTAssertEqual(dimensions?.height, 512)
    }

    func testPrepareImageForVisionKeepsSmallImageSize() async throws {
        let imageURL = tempDirectory.appendingPathComponent("small.png")
        try createPNG(at: imageURL, width: 100, height: 100)

        let analyzer = ImageVisionAnalyzer()
        let data = await analyzer.prepareImageForVision(at: imageURL)

        XCTAssertNotNil(data)
        let dimensions = imageDimensions(from: data)
        XCTAssertEqual(dimensions?.width, 100)
        XCTAssertEqual(dimensions?.height, 100)
    }

    func testPrepareImagesForVisionProcessesMultipleImages() async throws {
        let urls = [
            tempDirectory.appendingPathComponent("a.png"),
            tempDirectory.appendingPathComponent("b.png"),
            tempDirectory.appendingPathComponent("c.png")
        ]
        try createPNG(at: urls[0], width: 120, height: 120)
        try createPNG(at: urls[1], width: 200, height: 100)
        try createPNG(at: urls[2], width: 80, height: 180)

        let analyzer = ImageVisionAnalyzer()
        let result = await analyzer.prepareImagesForVision(urls: urls)

        XCTAssertEqual(result.count, 3)
        XCTAssertNotNil(result[urls[0]])
        XCTAssertNotNil(result[urls[1]])
        XCTAssertNotNil(result[urls[2]])
    }

    func testPrepareImagesForVisionReportsCompletedAttempts() async throws {
        let urls = [
            tempDirectory.appendingPathComponent("a.png"),
            tempDirectory.appendingPathComponent("b.png"),
            tempDirectory.appendingPathComponent("corrupted.png")
        ]
        try createPNG(at: urls[0], width: 120, height: 120)
        try createPNG(at: urls[1], width: 200, height: 100)
        try Data("not-an-image".utf8).write(to: urls[2])
        let progress = VisionPreparationProgressRecorder()

        let analyzer = ImageVisionAnalyzer()
        let result = await analyzer.prepareImagesForVision(urls: urls) { completed, total in
            await progress.record(completed: completed, total: total)
        }

        XCTAssertEqual(result.count, 2)
        let updates = await progress.updates
        XCTAssertEqual(updates.map(\.completed), [1, 2, 3])
        XCTAssertEqual(updates.map(\.total), [3, 3, 3])
    }

    func testPrepareImageForVisionHandlesMissingAndCorruptedFile() async throws {
        let analyzer = ImageVisionAnalyzer()

        let missingURL = tempDirectory.appendingPathComponent("missing.jpg")
        let missingResult = await analyzer.prepareImageForVision(at: missingURL)
        XCTAssertNil(missingResult)

        let corruptedURL = tempDirectory.appendingPathComponent("corrupted.jpg")
        try Data("not-an-image".utf8).write(to: corruptedURL)
        let corruptedResult = await analyzer.prepareImageForVision(at: corruptedURL)
        XCTAssertNil(corruptedResult)
    }

    func testPrepareImageForVisionCachesAndClearCacheRemovesFiles() async throws {
        let imageURL = tempDirectory.appendingPathComponent("cache.png")
        try createPNG(at: imageURL, width: 256, height: 256)

        let analyzer = ImageVisionAnalyzer()
        let first = await analyzer.prepareImageForVision(at: imageURL)
        XCTAssertNotNil(first)

        ImageVisionAnalyzer.clearSharedCache()

        let second = await analyzer.prepareImageForVision(at: imageURL)
        XCTAssertNotNil(second)
        XCTAssertEqual(imageDimensions(from: first)?.width, imageDimensions(from: second)?.width)
    }

    func testPrepareFilesForVisionRendersPDFPages() async throws {
        let pdfURL = tempDirectory.appendingPathComponent("report.pdf")
        try createPDF(at: pdfURL, pageCount: 2)

        let analyzer = ImageVisionAnalyzer()
        let result = await analyzer.prepareFilesForVision(files: [
            FileItem(path: pdfURL.path, name: "report", extension: "pdf", size: 0)
        ])

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.keys.contains("report.pdf [Page 1]"))
        XCTAssertTrue(result.keys.contains("report.pdf [Page 2]"))
        XCTAssertNotNil(imageDimensions(from: result["report.pdf [Page 1]"]))
    }

    func testPrepareFilesForVisionUsesRelativeAttachmentNamesWhenBaseDirectoryProvided() async throws {
        let nestedDirectory = tempDirectory.appendingPathComponent("Invoices")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let imageURL = nestedDirectory.appendingPathComponent("receipt.png")
        try createPNG(at: imageURL, width: 120, height: 120)

        let analyzer = ImageVisionAnalyzer()
        let result = await analyzer.prepareFilesForVision(
            files: [
                FileItem(path: imageURL.path, name: "receipt", extension: "png", size: 0)
            ],
            baseDirectoryURL: tempDirectory
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertNotNil(result["Invoices/receipt.png"])
    }

    func testPrepareFilesForVisionRespectsPDFPageLimit() async throws {
        let pdfURL = tempDirectory.appendingPathComponent("booklet.pdf")
        try createPDF(at: pdfURL, pageCount: 4)

        let analyzer = ImageVisionAnalyzer()
        let result = await analyzer.prepareFilesForVision(
            files: [
                FileItem(path: pdfURL.path, name: "booklet", extension: "pdf", size: 0)
            ],
            pdfPageLimit: 2
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.keys.contains("booklet.pdf [Page 1]"))
        XCTAssertTrue(result.keys.contains("booklet.pdf [Page 2]"))
        XCTAssertFalse(result.keys.contains("booklet.pdf [Page 3]"))
    }

    func testPrepareFilesForVisionIgnoresUnsupportedTypes() async throws {
        let textURL = tempDirectory.appendingPathComponent("notes.txt")
        try "hello".write(to: textURL, atomically: true, encoding: .utf8)

        let analyzer = ImageVisionAnalyzer()
        let result = await analyzer.prepareFilesForVision(
            files: [
                FileItem(path: textURL.path, name: "notes", extension: "txt", size: 5)
            ]
        )

        XCTAssertTrue(result.isEmpty)
    }

    private func createPNG(at url: URL, width: Int, height: Int) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap = rep else {
            XCTFail("Failed to create bitmap")
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to create PNG representation")
            return
        }
        try data.write(to: url)
    }

    private func createPDF(at url: URL, pageCount: Int) throws {
        let document = PDFDocument()

        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 600, height: 800))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 800)).fill()
            let text = NSString(string: "Page \(index + 1)")
            text.draw(
                at: NSPoint(x: 40, y: 400),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 48),
                    .foregroundColor: NSColor.black
                ]
            )
            image.unlockFocus()

            guard let page = PDFPage(image: image) else {
                XCTFail("Failed to create PDF page")
                return
            }
            document.insert(page, at: index)
        }

        guard let data = document.dataRepresentation() else {
            XCTFail("Failed to create PDF data")
            return
        }
        try data.write(to: url)
    }

    private func imageDimensions(from data: Data?) -> (width: Int, height: Int)? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        return (width, height)
    }

}

private actor VisionPreparationProgressRecorder {
    private(set) var updates: [(completed: Int, total: Int)] = []

    func record(completed: Int, total: Int) {
        updates.append((completed, total))
    }
}
