import Foundation

public struct NoteEvent: Equatable, Sendable {
    public var onset: Double
    public var offset: Double
    public var midi: Int
    public init(onset: Double, offset: Double, midi: Int) {
        self.onset = onset
        self.offset = offset
        self.midi = midi
    }
}

public enum HearSheet {
    public static let bundleIdentifier = "com.ragnus.earsheet"
    public static let modelName = "BasicPitchPoly"
}
