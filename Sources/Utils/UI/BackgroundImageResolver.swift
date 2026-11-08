// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objcMembers
class BackgroundImageResolver : NSObject {
    static let maxBackgroundImageWidth = 240
    static let defaultAspectRatio = 16.0 / 9.0

    // Static helper function for resizing the image
    private static func resizeToFit(_ image: NSImage) -> NSImage {

        // Check if the image size is already acceptable
        let size = image.size
        guard size.width > CGFloat(Self.maxBackgroundImageWidth) else {
            return image
        }

        // --- Calculate New Size ---
        var newSize = size

        // newHeight = oldHeight * (MAX_WIDTH / oldWidth)  <- Preserves Aspect Ratio
        let aspectRatio = CGFloat(Self.maxBackgroundImageWidth) / size.width

        newSize.height *= aspectRatio
        newSize.width = CGFloat(Self.maxBackgroundImageWidth)

        // --- Perform Resizing ---

        // 1. Create a new NSImage with the target size
        let backgroundImage = NSImage(size: newSize)

        // 2. Begin drawing into the new image context
        backgroundImage.lockFocus()

        // Set high quality interpolation (equivalent to [NSGraphicsContext currentContext] setImageInterpolation:...)
        NSGraphicsContext.current?.imageInterpolation = .high

        // Define the drawing rectangle
        let destinationRect = NSRect(origin: .zero, size: newSize)

        // Draw the source image into the destination rectangle
        image.draw(
            in: destinationRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0)

        // 3. End drawing
        backgroundImage.unlockFocus()

        return backgroundImage
    }

    // Instance method to get the OS-appropriate default background image
    static func defaultBackgroundImage(of osVersion: Int) -> NSImage {
        // Define possible default paths
        var defaultDesktopImage = "/System/Library/CoreServices/DefaultDesktop.jpg"
        let defaultBackgroundPath = "/System/Library/CoreServices/DefaultBackground.jpg"

        let fileManager = FileManager.default

        // Check for the first path
        if !fileManager.fileExists(atPath: defaultDesktopImage) {
            // Check for the second path (e.g., used in Mojave/newer systems)
            defaultDesktopImage = defaultBackgroundPath
        }

        // Final check before trying to load
        if fileManager.fileExists(atPath: defaultDesktopImage) {
            // Load the full image from the file path
            let fullImage = NSImage(contentsOfFile: defaultDesktopImage)

            // If the image loaded, call the static resizing helper
            if let fullImage = fullImage {
                return resizeToFit(fullImage)
            }
        } else {
            debugLog("Error: Unable to find default desktop image. Path: \(defaultDesktopImage)")
        }

        return NSImage(
            size: NSSize(
                width: self.maxBackgroundImageWidth,
                height: Int(Double(self.maxBackgroundImageWidth) * self.defaultAspectRatio)), flipped: false
        ) { drawingRect in
            NSColor.systemBlue.setFill()
            drawingRect.fill()
            return true
        }
    }
	
	static func desktopImageUrl(for screen: Screen) -> URL? {
		if let screen = screen.toNSScreen() {
			if let imageUrl = NSWorkspace.shared.desktopImageURL(for: screen) {
				if FileManager.default.fileExists(atPath: imageUrl.absoluteString) {
					return imageUrl
				}
			}
		}
		return nil
	}

    static func desktopImage(for screen: Screen) -> NSImage {
        if let imageUrl = desktopImageUrl(for: screen) {
            do {
                let imageData = try Data(contentsOf: imageUrl)
                if let image = NSImage(data: imageData) {
                    return resizeToFit(image)
                }
            } catch {
                debugLog("Error loading image from URL \(imageUrl): \(error.localizedDescription)")
            }
        }
        return defaultBackgroundImage(of: 0)
    }

    static func defaultBackgroundImage() -> NSImage {
        NSImage(
            size: NSSize(
                width: self.maxBackgroundImageWidth,
                height: Int(Double(self.maxBackgroundImageWidth) * self.defaultAspectRatio)), flipped: false
        ) { drawingRect in
            NSColor.systemBlue.setFill()
            drawingRect.fill()
            return true
        }
    }
}
