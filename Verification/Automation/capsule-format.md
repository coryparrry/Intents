# Data-only case capsules

In App automation, use **Case capsules** to open a file or legacy directory. A capsule opens as a separate historical preview; it never becomes a runnable saved case, execution approval or live accepted result. To export, choose a saved case, review its frozen definition and exact recorded attempt selection, affirm the synthetic data/metadata review, then choose a new file. Existing destinations cannot be replaced. Native controls compile; rendered behavior remains pending Xcode provider approval.

Exports omit raw artifacts and credentials. Hashes prove internal integrity, not truthful acquisition. Review includes plan inputs, provenance and report observations; the explicit synthetic review is required. Raw artifact export is not qualified.

## File format

The version-one file uses raw DEFLATE and the platform zlib module, without extraction or external package installation. It is not a ZIP archive. Existing directory capsules remain readable.

| Byte range | Meaning |
|---|---|
| 0–7 | ASCII INTCASE1 magic |
| 8–11 | Expanded payload byte count, UInt32 big endian |
| 12–15 | Compressed byte count, UInt32 big endian |
| 16–79 | Lowercase ASCII SHA256 of expanded payload |
| 80 onward | One raw DEFLATE stream; no trailing or concatenated data |

Expanded payload: UInt32 big-endian manifest length, canonical manifest JSON, then each record's bytes in manifest order. Exact total length, file sizes and per-record hashes are required. The manifest schema/trust/artifact policy and frozen-case digest are checked identically for file and directory imports. Reports undergo existing recorded-evidence validation. No Swift, JavaScript, shell, executable entry, symlink or unmanifested data is accepted.

Encoded input and expanded allocation are bounded at48MiB; the manifest is at most128KiB, at most128 unique paths, each record at most2MiB, aggregate records at most32MiB. Duplicate paths are rejected case-insensitively. Path depth is bounded and traversal/absolute/backslash/colon paths rejected. The decoder requires stream-end, exact consumed input and exact declared output; expansion overflow, truncated/corrupt streams, appended data and concatenation fail closed.

File export builds a private staging directory in the destination parent, writes a0600 durable file, publishes through an exclusive hard link, then removes only its staging directory. A filesystem without hard-link support reports failure rather than weakening no-overwrite behavior. Platforms without the zlib module report compressed-format unavailability; legacy directory support remains.

Tests172–174 prove local contracts, including recorded attempts, near-maximum incompressible records, exact review, symlinks, corruption, limits and unchanged native execution authority. Native41/42 compile and private package13 sealing succeeded. These are separate from rendered UI, clean-host, hardware or release qualification.
