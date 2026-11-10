import Foundation
import TelemetryCore

/// Read-only snapshot of the two preparation contracts. Never an authorization token.
/// No byte data, image objects, paths, arbitrary messages, persistence or decoder hooks.
struct ThemeImageReviewPresentation {
    static let imageContract = "obd-image-theme"
    static let templateContract = "theme-template-preparation-20261104"

    let phase: ThemeImageImport.Phase
    let generation: UInt64
    let manifest: ThemeImageManifest?

    init(snapshot: ThemeImageImport) {
        phase = snapshot.phase
        generation = snapshot.generation
        manifest = snapshot.candidate
    }

    /// This is deliberately unconditional, even for awaitingUserCommit.
    /// The Core phase cannot prove that the correct image was decoded or shown.
    var applicationBlocked: Bool { true }

    var reviewIntent: ThemeImageReviewIntent? {
        guard phase == .awaitingNativePreview || phase == .awaitingUserCommit,
              let manifest else { return nil }
        return ThemeImageReviewIntent(generation: generation, sha256: manifest.sha256)
    }
}

/// An intent to inspect metadata, NOT acceptance, preview evidence or an apply plan.
struct ThemeImageReviewIntent: Equatable {
    let generation: UInt64
    let sha256: String
}

/// Closed vocabulary means uncontrolled provider errors and file names cannot enter UI.
/// English is AppLocalization's exact lookup key; translations are an uninstalled inventory.
enum ThemeReviewCopy: String, CaseIterable {
    case title = "Theme image review"
    case metadata = "Structural metadata only"
    case noCandidate = "No structurally inspected image candidate is supplied."
    case structureWarning = "PNG structure checks do not decode pixels, remove private content or prove an image is safe."
    case stage = "Reported import stage"
    case idle = "Idle · no candidate staged"
    case selecting = "Selecting · no file access in this view"
    case nativePreview = "Awaiting native preview"
    case reportedCommit = "Awaiting user commit · preview not verified here"
    case generation = "Candidate generation"
    case digest = "Exact-byte SHA-256"
    case dimensions = "Dimensions in pixels (width × height)"
    case bytes = "Encoded byte count"
    case preview = "Native pixel preview required"
    case previewWarning = "No image pixels are shown here. A trusted native adapter must decode and render the exact verified payload before any apply action."
    case blocked = "Apply blocked · native preview unavailable"
    case review = "Review metadata"
    case reviewHint = "Requests metadata review only. Does not verify a preview or apply a theme."
    case cancel = "Cancel review"
    case cancelHint = "Requests cancellation for this candidate generation."
    case template = "Original template geometry"
    case noTemplate = "No original template is supplied."
    case coordinateRule = "Integer pixels; top-left origin; x grows right and y grows down. Right and bottom edges are excluded."
    case schematicWarning = "Reserved geometry is not an image preview or a legibility, contrast or accessibility guarantee."
    case primaryGauge = "Primary gauge reserved area"
    case secondaryGauge = "Secondary gauge reserved area"
    case statusText = "Status text reserved area"
    case footerText = "Footer text reserved area"
    case unknownRegion = "Unknown reserved area"
    case origin = "Origin in pixels (x, y)"
    case size = "Size in pixels (width × height)"
    case instructions = "Template instructions"
    case unavailable = "Unavailable"
    case mismatch = "Template and candidate dimensions differ. Native layout review is required."
    case ownBackground = "Use a background image you own or have permission to use."
    case keepClear = "Keep the reserved gauge and text areas visually quiet. Do not bake gauge values or labels into the background."
    case templatePreview = "Review the actual native preview, legibility and contrast before applying. Geometry alone does not establish accessibility."
    case shareReview = "Review the exact exported content and its destination before sharing. This specification contains no background image."

    static func region(_ role: String) -> Self {
        switch role {
        case "primaryGauge": return .primaryGauge
        case "secondaryGauge": return .secondaryGauge
        case "statusText": return .statusText
        case "footerText": return .footerText
        default: return .unknownRegion
        }
    }

    static func instruction(_ key: String) -> Self? {
        switch key {
        case "theme.template.ownBackground": return .ownBackground
        case "theme.template.keepClear": return .keepClear
        case "theme.template.preview": return .templatePreview
        case "theme.template.shareReview": return .shareReview
        default: return nil
        }
    }
}
