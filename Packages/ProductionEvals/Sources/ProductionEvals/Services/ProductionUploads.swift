import CryptoKit
import Foundation

public struct ProductionUpload: Codable, Sendable, Equatable {
  public var id: UUID
  public var name: String
  public var version: String
  public var sampling: ProductionSampling
  public var productionData: Bool
  public var expectedChunks: Int
  public var expectedBytes: Int
  public var expectedDigest: String
  public var previewed = false
  public var datasetRevision: String?
  public init(
    id: UUID, name: String, version: String, sampling: ProductionSampling = .curated,
    productionData: Bool = false, expectedChunks: Int, expectedBytes: Int, expectedDigest: String
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.sampling = sampling
    self.productionData = productionData
    self.expectedChunks = expectedChunks
    self.expectedBytes = expectedBytes
    self.expectedDigest = expectedDigest
  }
}
private struct ProductionUploadChunk: Codable {
  var bytes: Int
  var digest: String
}

extension ProductionStorage {
  public func beginUpload(_ upload: ProductionUpload) throws -> ProductionUpload {
    guard !upload.name.isEmpty, upload.name.count <= 200, !upload.version.isEmpty,
      upload.version.count <= 100,
      (1...1024).contains(upload.expectedChunks),
      (1...1_000_000_000).contains(upload.expectedBytes),
      upload.expectedDigest.count == 64,
      upload.expectedDigest.allSatisfy({ "0123456789abcdef".contains($0) }),
      !upload.previewed, upload.datasetRevision == nil
    else { throw ProductionFailure.invalid("Invalid upload contract.") }
    return try transaction {
      let folder = uploadDirectory(upload.id)
      let manifest = folder.appendingPathComponent("upload.json")
      guard !FileManager.default.fileExists(atPath: discardMarker(upload.id).path) else {
        throw ProductionFailure.invalid(
          "This upload ID was discarded. Use a new ID for new source data.")
      }
      if FileManager.default.fileExists(atPath: manifest.path) {
        var existing = try self.upload(upload.id)
        existing.previewed = false
        existing.datasetRevision = nil
        guard existing == upload else {
          throw ProductionFailure.invalid("Upload ID belongs to different source data.")
        }
        return try self.upload(upload.id)
      }
      let uploads = root.appendingPathComponent("Uploads")
      try FileManager.default.createDirectory(
        at: uploads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let pending = try FileManager.default.contentsOfDirectory(
        at: uploads, includingPropertiesForKeys: nil
      ).filter { folder in
        guard !folder.lastPathComponent.hasPrefix(".") else { return false }
        return
          (try? ProductionCodec.read(
            ProductionUpload.self, from: folder.appendingPathComponent("upload.json"),
            maximumBytes: 4096))?.datasetRevision == nil
      }
      guard pending.count < 10 else {
        throw ProductionFailure.invalid(
          "Ten pending uploads are already retained. Finish or explicitly discard one first.")
      }
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try ProductionCodec.write(upload, to: manifest)
      return upload
    }
  }
  public func upload(_ id: UUID) throws -> ProductionUpload {
    try ProductionCodec.read(
      ProductionUpload.self, from: uploadDirectory(id).appendingPathComponent("upload.json"),
      maximumBytes: 4096)
  }
  public func uploadStatus(_ id: UUID) throws -> [Int] {
    let value = try upload(id)
    return (0..<value.expectedChunks).filter {
      FileManager.default.fileExists(
        atPath: uploadDirectory(id).appendingPathComponent("\($0).meta").path)
    }
  }
  public func appendUpload(_ id: UUID, index: Int, data: Data) throws {
    try transaction {
      let value = try upload(id)
      guard !value.previewed, value.datasetRevision == nil,
        (0..<value.expectedChunks).contains(index), !data.isEmpty, data.count <= 1_048_576
      else {
        throw ProductionFailure.invalid("Chunk is invalid or upload is sealed.")
      }
      let folder = uploadDirectory(id)
      let file = folder.appendingPathComponent("\(index).chunk")
      let metadata = folder.appendingPathComponent("\(index).meta")
      let receipt = ProductionUploadChunk(bytes: data.count, digest: ProductionCodec.digest(data))
      if FileManager.default.fileExists(atPath: file.path) {
        guard try ProductionCodec.fileSize(file) <= 1_048_576, try Data(contentsOf: file) == data
        else { throw ProductionFailure.invalid("Chunk index already contains different bytes.") }
      } else {
        let bytes = try (0..<value.expectedChunks).reduce(0) { count, i in
          let file = folder.appendingPathComponent("\(i).chunk")
          return count
            + (FileManager.default.fileExists(atPath: file.path)
              ? try ProductionCodec.fileSize(file) : 0)
        }
        guard bytes + data.count <= value.expectedBytes else {
          throw ProductionFailure.invalid("Upload exceeds its declared byte count.")
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
      try ProductionCodec.write(receipt, to: metadata)
    }
  }
  public func previewUpload(_ id: UUID) throws -> [ProductionExample] {
    let source = try sealUpload(id)
    let preview = try Self.previewExamples(from: source, limit: 3)
    try transaction {
      var value = try upload(id)
      value.previewed = true
      try ProductionCodec.write(
        value, to: uploadDirectory(id).appendingPathComponent("upload.json"))
    }
    return preview
  }
  public func finishUpload(_ id: UUID, previewDigest: String, redactionConfirmed: Bool) throws
    -> ProductionDataset
  {
    let value = try upload(id)
    guard value.previewed, previewDigest == value.expectedDigest else {
      throw ProductionFailure.invalid("Preview this exact complete source before importing it.")
    }
    if let revision = value.datasetRevision { return try loadDataset(revision) }
    let source = try sealUpload(id, expected: value)
    let dataset = try importDataset(
      from: source, name: value.name, version: value.version, sampling: value.sampling,
      productionData: value.productionData, redactionConfirmed: redactionConfirmed)
    try transaction {
      var current = try upload(id)
      guard current == value else {
        throw ProductionFailure.invalid(
          "Upload state changed during import. Inspect the immutable dataset before retrying.")
      }
      current.datasetRevision = dataset.revision
      try ProductionCodec.write(
        current, to: uploadDirectory(id).appendingPathComponent("upload.json"))
    }
    return dataset
  }
  public func discardUpload(_ id: UUID) throws {
    try transaction {
      _ = try upload(id)
      try Data(id.uuidString.utf8).write(to: discardMarker(id), options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: discardMarker(id).path)
      try FileManager.default.removeItem(at: uploadDirectory(id))
    }
  }
  private func discardMarker(_ id: UUID) -> URL {
    root.appendingPathComponent("Uploads/.discarded-\(id)")
  }
  private func uploadDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent("Uploads/\(id.uuidString)")
  }
  private func sealUpload(_ id: UUID, expected: ProductionUpload? = nil) throws -> URL {
    try transaction {
      let value = try upload(id)
      let folder = uploadDirectory(id)
      let assembled = folder.appendingPathComponent("assembled.jsonl")
      if let expected, expected != value {
        throw ProductionFailure.invalid("Upload contract changed after preview.")
      }
      let temporary = folder.appendingPathComponent(".assembling-\(UUID())")
      defer { try? FileManager.default.removeItem(at: temporary) }
      FileManager.default.createFile(
        atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let handle = try FileHandle(forWritingTo: temporary)
      defer { try? handle.close() }
      var digest = SHA256()
      var bytes = 0
      for index in 0..<value.expectedChunks {
        let receipt = try ProductionCodec.read(
          ProductionUploadChunk.self, from: folder.appendingPathComponent("\(index).meta"),
          maximumBytes: 4096)
        let chunkURL = folder.appendingPathComponent("\(index).chunk")
        guard try ProductionCodec.fileSize(chunkURL) <= 1_048_576 else {
          throw ProductionFailure.invalid("Chunk exceeds its bound.")
        }
        let chunk = try Data(contentsOf: chunkURL)
        guard chunk.count <= 1_048_576, chunk.count == receipt.bytes,
          ProductionCodec.digest(chunk) == receipt.digest
        else { throw ProductionFailure.invalid("Uploaded chunk changed or exceeds its bound.") }
        bytes += chunk.count
        guard bytes <= value.expectedBytes else {
          throw ProductionFailure.invalid("Upload exceeds declared bytes.")
        }
        digest.update(data: chunk)
        try handle.write(contentsOf: chunk)
      }
      let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
      guard bytes == value.expectedBytes, hash == value.expectedDigest else {
        throw ProductionFailure.invalid(
          "Complete upload does not match its declared digest and bytes.")
      }
      try handle.synchronize()
      if FileManager.default.fileExists(atPath: assembled.path) {
        try FileManager.default.removeItem(at: assembled)
      }
      try FileManager.default.moveItem(at: temporary, to: assembled)
      return assembled
    }
  }
}
