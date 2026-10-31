import AppKit
import Testing
@testable import AudioPin

@Suite("BrandMark")
struct BrandMarkTests {
    @Test func parsesTheSmallMarkIntoItsSVGBounds() {
        let box = BrandMark.path(BrandMark.smallPath).boundingBoxOfPath
        // logo-mark-small.svg: bars span x 5…27, pin head top y 5, needle tip ≈ y 28
        #expect(abs(box.minX - 5) < 0.01)
        #expect(abs(box.maxX - 27) < 0.01)
        #expect(abs(box.minY - 5) < 0.01)
        #expect(box.maxY > 27.4 && box.maxY < 28.5)
    }

    @Test func arcsBecomeCircles() {
        // Two half-arcs of radius 5 around (16, 10) form a full circle.
        let box = BrandMark.path("M16 5A5 5 0 1 1 16 15A5 5 0 1 1 16 5Z").boundingBoxOfPath
        #expect(abs(box.width - 10) < 0.01 && abs(box.height - 10) < 0.01)
        #expect(abs(box.midX - 16) < 0.01 && abs(box.midY - 10) < 0.01)
    }

    @Test func stopsAtMalformedInput() {
        #expect(BrandMark.path("").isEmpty)
        let path = BrandMark.path("M0 0H10V10X5 5")
        #expect(path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(BrandMark.path("M0 0L5").boundingBoxOfPath == .zero)
    }

    @MainActor @Test func menuBarImagesAreStatusItemSizedTemplates() {
        for image in [BrandMark.active, BrandMark.paused] {
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
        }
    }
}
