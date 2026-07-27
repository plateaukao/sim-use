// SPDX-License-Identifier: Apache-2.0
import Foundation
import UIKit
import XCTest

/// `/screenshot` — base64 PNG of the whole screen, same envelope shape
/// as the Android bridge's `CaptureHandler`.
///
/// `XCUIScreen.main.screenshot()` captures the composited display, so
/// unlike an app-scoped screenshot it includes the status bar, system
/// alerts, and the keyboard — which is what an agent inspecting "what is
/// on screen" needs.
final class CaptureHandler {

    func screenshot(params: [String: String]) -> HTTPResponse {
        let image = XCUIScreen.main.screenshot()
        var data = image.pngRepresentation

        // Full-resolution PNGs off a 3x phone screen run 4–8 MB, which
        // is slow over usbmux and larger than most agent pipelines want
        // to hold. `scale` downsamples on device, before the wire.
        if let scale = params["scale"].flatMap(Double.init), scale > 0, scale < 1 {
            data = Self.downsample(data, scale: scale) ?? data
        }

        return HTTPResponse(status: 200, json: Envelope.success(
            data.base64EncodedString(),
            extra: ["encoding": "png-base64", "bytes": data.count]
        ))
    }

    private static func downsample(_ png: Data, scale: Double) -> Data? {
        guard let source = UIImage(data: png) else { return nil }
        let target = CGSize(
            width: (source.size.width * scale).rounded(),
            height: (source.size.height * scale).rounded()
        )
        guard target.width >= 1, target.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        // The source image already carries the device scale; render at
        // 1x so `target` is in pixels and the caller gets exactly the
        // reduction they asked for.
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }.pngData()
    }
}
