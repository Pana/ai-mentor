import UIKit
import XCTest
@testable import LittleBearTutor

final class ImageCroppingTests: XCTestCase {
    private let start = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)

    func testMoveStaysInsideImage() {
        let moved = CropMath.move(start, by: CGSize(width: 0.1, height: -0.1))
        XCTAssertEqual(moved.minX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(moved.minY, 0.1, accuracy: 1e-9)
        XCTAssertEqual(moved.size, start.size)
        XCTAssertEqual(CropMath.move(start, by: CGSize(width: 2, height: -2)), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    func testResizeKeepsOppositeCornerAndLimits() {
        let grown = CropMath.resize(start, corner: .bottomRight, by: CGSize(width: 0.1, height: 0.2))
        XCTAssertEqual(grown.origin, start.origin)
        XCTAssertEqual(grown.maxX, 0.8, accuracy: 1e-9)
        XCTAssertEqual(grown.maxY, 0.9, accuracy: 1e-9)

        let clamped = CropMath.resize(start, corner: .topLeft, by: CGSize(width: -1, height: -1))
        XCTAssertEqual(clamped, CGRect(x: 0, y: 0, width: 0.7, height: 0.7))

        let tiny = CropMath.resize(start, corner: .topRight, by: CGSize(width: -1, height: 1))
        XCTAssertEqual(tiny.width, CropMath.minSide, accuracy: 1e-9)
        XCTAssertEqual(tiny.height, CropMath.minSide, accuracy: 1e-9)
        XCTAssertEqual(tiny.minX, start.minX, accuracy: 1e-9)
        XCTAssertEqual(tiny.maxY, start.maxY, accuracy: 1e-9)
    }

    func testCropUsesPixelCoordinates() throws {
        let image = solid(CGSize(width: 1000, height: 500))
        let cropped = try XCTUnwrap(ImageCropper.crop(image, to: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)))
        XCTAssertEqual(cropped.cgImage?.width, 500)
        XCTAssertEqual(cropped.cgImage?.height, 250)
        XCTAssertNil(ImageCropper.crop(image, to: CGRect(x: 2, y: 2, width: 0.5, height: 0.5)))
    }

    func testRotatedCameraPhotoIsCroppedUpright() throws {
        // A landscape buffer flagged `.right` displays as portrait 500×1000, like an iPad held upright.
        let base = try XCTUnwrap(solid(CGSize(width: 1000, height: 500)).cgImage)
        let rotated = UIImage(cgImage: base, scale: 1, orientation: .right)
        XCTAssertEqual(rotated.size, CGSize(width: 500, height: 1000))
        let top = try XCTUnwrap(ImageCropper.crop(rotated, to: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        XCTAssertEqual(top.cgImage?.width, 500)
        XCTAssertEqual(top.cgImage?.height, 500)
        XCTAssertEqual(top.imageOrientation, .up)
    }

    private func solid(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
