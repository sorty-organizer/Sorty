import XCTest
@testable import SortyLib
@testable import SortyCore

final class FilenameNormalizerTests: XCTestCase {
    func testSpacesArePreservedWhenSelected() {
        let options = RenameNamingOptions(separator: .spaces, caseStyle: .natural)

        let result = FilenameNormalizer.normalize(
            "2026-03-19 Signed Service Agreement.pdf",
            originalFilename: "scan_001.pdf",
            options: options
        )

        XCTAssertEqual(result, "2026-03-19 Signed Service Agreement.pdf")
    }

    func testSnakeAndKebabCaseConversion() {
        let snake = RenameNamingOptions(separator: .underscore, caseStyle: .snake)
        let kebab = RenameNamingOptions(separator: .hyphen, caseStyle: .kebab)

        XCTAssertEqual(
            FilenameNormalizer.normalize("Signed Service Agreement.pdf", originalFilename: "scan.pdf", options: snake),
            "signed_service_agreement.pdf"
        )
        XCTAssertEqual(
            FilenameNormalizer.normalize("Signed Service Agreement.pdf", originalFilename: "scan.pdf", options: kebab),
            "signed-service-agreement.pdf"
        )
    }

    func testPascalAndCamelCaseConversion() {
        XCTAssertEqual(
            FilenameNormalizer.normalize(
                "signed service agreement.pdf",
                originalFilename: "scan.pdf",
                options: RenameNamingOptions(caseStyle: .pascal)
            ),
            "SignedServiceAgreement.pdf"
        )
        XCTAssertEqual(
            FilenameNormalizer.normalize(
                "signed service agreement.pdf",
                originalFilename: "scan.pdf",
                options: RenameNamingOptions(caseStyle: .camel)
            ),
            "signedServiceAgreement.pdf"
        )
    }

    func testMaxLengthKeepsExtension() {
        let options = RenameNamingOptions(maxFilenameLength: 24)
        let result = FilenameNormalizer.normalize(
            "Very Long Signed Service Agreement For Acme Corporation.pdf",
            originalFilename: "scan.pdf",
            options: options
        )

        XCTAssertEqual(result, "Very Long Signed Ser.pdf")
    }

    func testIllegalCharactersAreRemoved() {
        let result = FilenameNormalizer.normalize(
            "Invoice: Acme/April\\2026.pdf",
            originalFilename: "scan.pdf",
            options: .default
        )

        XCTAssertEqual(result, "Invoice Acme April 2026.pdf")
    }

    func testDuplicateNamesBecomeUnique() {
        var names: Set<String> = ["Invoice.pdf"]

        let result = FilenameNormalizer.uniqued("Invoice.pdf", against: &names)

        XCTAssertEqual(result, "Invoice_1.pdf")
        XCTAssertTrue(names.contains("Invoice_1.pdf"))
    }

    func testProtectedNamesAreNotRenamed() {
        XCTAssertNil(
            FilenameNormalizer.normalize(
                "Environment Settings.env",
                originalFilename: ".env",
                options: .default
            )
        )
        XCTAssertNil(
            FilenameNormalizer.normalize(
                "Version 1.2.3.txt",
                originalFilename: "v1.2.3.txt",
                options: .default
            )
        )
    }
}
