import Foundation

public struct ParseOptions: Sendable, Equatable {
    public var windowSize: Int
    public var parseTags: Bool
    public var strictMode: Bool
    public var maxReadBytes: Int
    public var includeBinaryData: Bool
    public var maxBinaryTagBytes: Int
    public var allowHeuristicFallback: Bool
    public var maxConcurrentTasks: Int

    public init(
        windowSize: Int = 64 * 1024,
        parseTags: Bool = true,
        strictMode: Bool = false,
        maxReadBytes: Int = 16 * 1024 * 1024,
        includeBinaryData: Bool = false,
        maxBinaryTagBytes: Int = 8 * 1024 * 1024,
        allowHeuristicFallback: Bool = true,
        maxConcurrentTasks: Int = min(4, ProcessInfo.processInfo.activeProcessorCount)
    ) {
        self.windowSize = max(4 * 1024, windowSize)
        self.parseTags = parseTags
        self.strictMode = strictMode
        self.maxReadBytes = max(256 * 1024, maxReadBytes)
        self.includeBinaryData = includeBinaryData
        self.maxBinaryTagBytes = max(0, maxBinaryTagBytes)
        self.allowHeuristicFallback = allowHeuristicFallback
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
    }

    public static let `default` = ParseOptions()
}
