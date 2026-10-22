import Foundation

enum ProductionStorageLimits {
    static let chunkRecords = 100
    static let encodedExampleBytes = 262_144
    static let encodedWorkerBytes = 20_000
    static let outputBytes = 64_000
    static let explanationBytes = 8_000
    static let artifactBytes = 262_144

    // JSON can expand each UTF-8 input byte to a six-byte escape. Data uses
    // base64. Fixed-size keys, UUIDs, bounded numbers and dates fit in 1 KiB.
    private static let encodedResponseBytes = 6 * (outputBytes + explanationBytes)
        + 4 * ((artifactBytes + 2) / 3) + 1_024
    // Source IDs, partition and metadata are a subset of the bounded example.
    // Each record and attempt also embeds one independently bounded worker.
    static let encodedChunkBytes = chunkRecords
        * (encodedExampleBytes + encodedResponseBytes + encodedWorkerBytes + 1_024
           + encodedWorkerBytes + 1_024)
        + encodedWorkerBytes + 4_096 // Lease worker ID and chunk/dictionary framing.
}
