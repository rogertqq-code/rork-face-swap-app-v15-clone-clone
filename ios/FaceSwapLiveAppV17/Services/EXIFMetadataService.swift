import Foundation
import UIKit
import ImageIO
import CoreLocation

nonisolated final class EXIFMetadataService: @unchecked Sendable {

    /// A re-encoded JPEG with metadata stripped, matching the photo Safari hands
    /// to a file input after a live camera capture: Safari re-encodes the image
    /// and drops EXIF/GPS/camera tags. Pixels are normalized upright first so the
    /// orientation is baked in and no orientation tag is needed. Used for native
    /// camera-capture requests; the full-EXIF path is used for library picks.
    func strippedJPEGData(image: UIImage, compressionQuality: CGFloat = 0.92) -> Data? {
        image.normalizedForInjection().jpegData(compressionQuality: compressionQuality)
    }

    /// A stripped JPEG guaranteed to fit inside `maxBytes`, stepping quality and
    /// then the longest edge down until it does.
    ///
    /// A camera capture must ALWAYS be deliverable as bytes carried inside the
    /// page. Without this, a large photo silently fell back either to the
    /// app-address route a locked-down site refuses, or to the untouched original
    /// still carrying location and camera tags.
    func strippedJPEGData(image: UIImage, maxBytes: Int, compressionQuality: CGFloat = 0.92) -> Data? {
        guard maxBytes > 0 else {
            return strippedJPEGData(image: image, compressionQuality: compressionQuality)
        }
        let upright = image.normalizedForInjection()
        for quality in [compressionQuality, 0.85, 0.75, 0.65, 0.55, 0.45] as [CGFloat] {
            if let data = upright.jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
        }
        // Still too large at the lowest sensible quality: reduce the longest edge
        // and retry, the way a real capture from a smaller sensor would arrive.
        var working = upright
        for _ in 0..<6 {
            let size = working.size
            guard max(size.width, size.height) > 320 else { break }
            let next = CGSize(
                width: max((size.width * 0.75).rounded(), 1),
                height: max((size.height * 0.75).rounded(), 1)
            )
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let source = working
            working = UIGraphicsImageRenderer(size: next, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: next))
            }
            for quality in [CGFloat(0.85), 0.7, 0.6, 0.5] {
                if let data = working.jpegData(compressionQuality: quality), data.count <= maxBytes {
                    return data
                }
            }
        }
        return working.jpegData(compressionQuality: 0.45)
    }

    func jpegDataWithEXIF(
        image: UIImage,
        camera: CameraDeviceSpec?,
        hardware: DeviceHardwareSpec?,
        compressionQuality: CGFloat = 0.92
    ) -> Data? {
        let normalizedImage = image.normalizedForInjection()
        guard let baseData = normalizedImage.jpegData(compressionQuality: compressionQuality) else { return nil }
        guard let source = CGImageSourceCreateWithData(baseData as CFData, nil) else { return nil }

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateString = dateFormatter.string(from: now)

        let subsecFormatter = DateFormatter()
        subsecFormatter.dateFormat = "SSS"
        subsecFormatter.locale = Locale(identifier: "en_US_POSIX")
        let subsec = subsecFormatter.string(from: now)

        // Modern iPhone captures carry the local timezone offset alongside the
        // timestamp (EXIF 2.31 OffsetTime*). Emit the device's real offset.
        let timeZone = TimeZone.current
        let totalOffsetMinutes = timeZone.secondsFromGMT(for: now) / 60
        let offsetSign = totalOffsetMinutes >= 0 ? "+" : "-"
        let absOffsetMinutes = abs(totalOffsetMinutes)
        let offsetString = String(format: "%@%02d:%02d", offsetSign, absOffsetMinutes / 60, absOffsetMinutes % 60)

        // Use the true decoded pixel dimensions so every dimension tag matches
        // the bytes exactly; fall back to points×scale only if there is no CGImage.
        let w = normalizedImage.cgImage?.width ?? Int((normalizedImage.size.width * normalizedImage.scale).rounded())
        let h = normalizedImage.cgImage?.height ?? Int((normalizedImage.size.height * normalizedImage.scale).rounded())

        let isBack = camera?.position == "back"
        let focalLength = camera?.focalLength ?? (isBack ? 6.86 : 2.69)
        let aperture = camera?.lensAperture ?? (isBack ? 1.78 : 2.2)
        let focalLength35mm = isBack ? 26 : 12

        let exposureDuration = camera?.exposureDurationSeconds ?? 0.008333
        let iso: Float = {
            if let cam = camera {
                return (cam.minISO + cam.maxISO) / 4.0
            }
            return isBack ? 50.0 : 64.0
        }()

        var exifDict: [String: Any] = [
            kCGImagePropertyExifDateTimeOriginal as String: dateString,
            kCGImagePropertyExifDateTimeDigitized as String: dateString,
            kCGImagePropertyExifSubsecTime as String: subsec,
            kCGImagePropertyExifSubsecTimeOriginal as String: subsec,
            kCGImagePropertyExifSubsecTimeDigitized as String: subsec,
            kCGImagePropertyExifOffsetTime as String: offsetString,
            kCGImagePropertyExifOffsetTimeOriginal as String: offsetString,
            kCGImagePropertyExifOffsetTimeDigitized as String: offsetString,
            kCGImagePropertyExifLensMake as String: "Apple",
            kCGImagePropertyExifPixelXDimension as String: w,
            kCGImagePropertyExifPixelYDimension as String: h,
            kCGImagePropertyExifColorSpace as String: 65535,
            kCGImagePropertyExifFNumber as String: aperture,
            kCGImagePropertyExifFocalLength as String: focalLength,
            kCGImagePropertyExifFocalLenIn35mmFilm as String: focalLength35mm,
            kCGImagePropertyExifExposureTime as String: exposureDuration,
            kCGImagePropertyExifISOSpeedRatings as String: [Int(iso)],
            kCGImagePropertyExifExposureProgram as String: 2,
            kCGImagePropertyExifExposureMode as String: 0,
            kCGImagePropertyExifWhiteBalance as String: 0,
            kCGImagePropertyExifSceneCaptureType as String: 0,
            kCGImagePropertyExifMeteringMode as String: 5,
            kCGImagePropertyExifFlash as String: isBack ? 16 : 32,
            kCGImagePropertyExifSensingMethod as String: 2,
            kCGImagePropertyExifSceneType as String: 1,
            kCGImagePropertyExifCustomRendered as String: 8,
            kCGImagePropertyExifBrightnessValue as String: 6.5,
            kCGImagePropertyExifShutterSpeedValue as String: log2(1.0 / exposureDuration),
            kCGImagePropertyExifApertureValue as String: 2.0 * log2(Double(aperture)),
            kCGImagePropertyExifExposureBiasValue as String: 0.0,
            kCGImagePropertyExifVersion as String: [2, 3, 2],
            kCGImagePropertyExifFlashPixVersion as String: [1, 0],
            kCGImagePropertyExifComponentsConfiguration as String: [1, 2, 3, 0],
            kCGImagePropertyExifCompressedBitsPerPixel as String: 3.4,
        ]

        let lensSpec: [Double] = [1.54, 6.86, 1.78, 2.8]
        exifDict[kCGImagePropertyExifLensSpecification as String] = lensSpec

        let subjectArea = isBack
            ? [w / 2, h / 2, w / 3, h / 4]
            : [w / 2, h / 2, w / 2, h / 3]
        exifDict[kCGImagePropertyExifSubjectArea as String] = subjectArea

        let modelName = hardware?.modelName ?? "iPhone"
        let modelIdentifier = hardware?.modelIdentifier ?? "iPhone15,2"

        let lensModel: String
        if isBack {
            lensModel = "\(modelName) back triple camera \(String(format: "%.2f", focalLength))mm f/\(String(format: "%.1f", aperture))"
        } else {
            lensModel = "\(modelName) front TrueDepth camera \(String(format: "%.2f", focalLength))mm f/\(String(format: "%.1f", aperture))"
        }

        // Real iPhone photos expose the lens model directly on the EXIF dict.
        exifDict[kCGImagePropertyExifLensModel as String] = lensModel

        let swVersion = hardware?.systemVersion ?? "18.0"
        let tiffDict: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "Apple",
            kCGImagePropertyTIFFModel as String: modelIdentifier,
            kCGImagePropertyTIFFSoftware as String: swVersion,
            kCGImagePropertyTIFFDateTime as String: dateString,
            kCGImagePropertyTIFFXResolution as String: 72,
            kCGImagePropertyTIFFYResolution as String: 72,
            kCGImagePropertyTIFFResolutionUnit as String: 2,
            kCGImagePropertyTIFFOrientation as String: 1,
        ]

        let jfifDict: [String: Any] = [
            kCGImagePropertyJFIFXDensity as String: 72,
            kCGImagePropertyJFIFYDensity as String: 72,
            kCGImagePropertyJFIFDensityUnit as String: 0,
            kCGImagePropertyJFIFVersion as String: [1, 0, 1],
        ]

        var metadata: [String: Any] = [
            kCGImagePropertyExifDictionary as String: exifDict,
            kCGImagePropertyTIFFDictionary as String: tiffDict,
            kCGImagePropertyJFIFDictionary as String: jfifDict,
            kCGImagePropertyOrientation as String: 1,
            kCGImagePropertyDPIWidth as String: 72,
            kCGImagePropertyDPIHeight as String: 72,
            kCGImagePropertyColorModel as String: "RGB",
            kCGImagePropertyDepth as String: 8,
            kCGImagePropertyProfileName as String: "Display P3",
            kCGImagePropertyPixelWidth as String: w,
            kCGImagePropertyPixelHeight as String: h,
        ]

        let exifAux: [String: Any] = [
            "LensModel": lensModel,
            "LensMake": "Apple",
            "LensInfo": lensSpec,
        ]
        metadata[kCGImagePropertyExifAuxDictionary as String] = exifAux

        let outputData = NSMutableData()
        guard let uti = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, uti, 1, nil) else {
            return baseData
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return baseData
        }

        return outputData as Data
    }

    func jpegDataWithEXIFAndGPS(
        image: UIImage,
        camera: CameraDeviceSpec?,
        hardware: DeviceHardwareSpec?,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        compressionQuality: CGFloat = 0.92
    ) -> Data? {
        let normalizedImage = image.normalizedForInjection()
        guard let data = jpegDataWithEXIF(image: normalizedImage, camera: camera, hardware: hardware, compressionQuality: compressionQuality) else {
            return nil
        }

        guard let lat = latitude, let lon = longitude else { return data }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let existingProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return data
        }

        var mutableProps = existingProps

        var gpsDict: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(lat),
            kCGImagePropertyGPSLatitudeRef as String: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(lon),
            kCGImagePropertyGPSLongitudeRef as String: lon >= 0 ? "E" : "W",
            kCGImagePropertyGPSSpeedRef as String: "K",
            kCGImagePropertyGPSSpeed as String: 0.0,
            kCGImagePropertyGPSImgDirectionRef as String: "T",
            kCGImagePropertyGPSImgDirection as String: Double.random(in: 0...360),
            kCGImagePropertyGPSHPositioningError as String: Double.random(in: 3.0...10.0),
        ]

        if let alt = altitude {
            gpsDict[kCGImagePropertyGPSAltitude as String] = abs(alt)
            gpsDict[kCGImagePropertyGPSAltitudeRef as String] = alt >= 0 ? 0 : 1
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy:MM:dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        gpsDict[kCGImagePropertyGPSDateStamp as String] = dateFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        // EXIF GPSTimeStamp is UTC hh:mm:ss with millisecond subseconds.
        timeFormatter.dateFormat = "HH:mm:ss.SSS"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(identifier: "UTC")
        gpsDict[kCGImagePropertyGPSTimeStamp as String] = timeFormatter.string(from: Date())

        mutableProps[kCGImagePropertyGPSDictionary as String] = gpsDict

        let outputData = NSMutableData()
        guard let uti = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, uti, 1, nil) else {
            return data
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, mutableProps as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return data
        }

        return outputData as Data
    }
}

extension UIImage {
    /// Renders orientation metadata into upright pixels before injection or EXIF encoding.
    nonisolated func normalizedForInjection() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
