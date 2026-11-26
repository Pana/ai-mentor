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

    func testExternalCameraPhotoTurnsClockwise() throws {
        // Left half red, right half blue: a quarter turn clockwise puts red on top.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.blue.setFill(); context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        }
        let turned = ImageCropper.rotated(image, clockwise: 90)
        XCTAssertEqual(turned.size, CGSize(width: 200, height: 400))
        let top = try XCTUnwrap(ImageCropper.crop(turned, to: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        XCTAssertGreaterThan(try redness(top), 0.9)
        XCTAssertEqual(ImageCropper.rotated(image, clockwise: 180).size, image.size)
        XCTAssertEqual(ImageCropper.rotated(image, clockwise: 0).size, image.size)
    }

    func testExternalCameraRotationStaysAQuarterTurn() {
        XCTAssertEqual(ExternalCamera.normalized(0), 0)
        XCTAssertEqual(ExternalCamera.normalized(90), 90)
        XCTAssertEqual(ExternalCamera.normalized(360), 0)
        XCTAssertEqual(ExternalCamera.normalized(450), 90)
        XCTAssertEqual(ExternalCamera.normalized(-90), 270)
    }

    /// Share of red in the image's average colour.
    private func redness(_ image: UIImage) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(pixel[0]) / Double(max(1, Int(pixel[0]) + Int(pixel[2])))
    }

    private func solid(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
