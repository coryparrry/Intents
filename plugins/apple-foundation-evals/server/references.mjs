import { mkdir, lstat, readFile, writeFile, rename, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { id } from './validation.mjs';
export const REFERENCE_LIMITS = { maxImageBytes: 10000000, maxTextFileBytes: 5000000, maxAttachments: 20, maxImages: 4, maximumExtractedTextCharacters: 16000 };
const storedName = /^[a-f0-9]{64}\.(pdf|txt|md|csv|json|png|jpg|heic|heif|tiff|gif|webp)$/;
const MAX_FILE_BYTES = REFERENCE_LIMITS.maxImageBytes;
const MAX_ENCODED_REFERENCE_BYTES = 16000000;
const MIME = { 'application/pdf': 'pdf', 'text/plain': 'txt', 'text/markdown': 'md', 'text/csv': 'csv', 'application/json': 'json', 'image/png': 'png', 'image/jpeg': 'jpg', 'image/heic': 'heic', 'image/heif': 'heif', 'image/tiff': 'tiff', 'image/gif': 'gif', 'image/webp': 'webp' };
/** Adds one file's canonical base64 length, including its padding, and enforces the shared import/export reference budget. */
function referenceBundleBytes(encodedBytes, fileBytes) {
  const total = encodedBytes + Math.ceil(fileBytes / 3) * 4;
  if (total > MAX_ENCODED_REFERENCE_BYTES) throw new Error('Portable reference bundle exceeds the 16,000,000-byte base64 limit; include fewer reference files');
  return total;
}
/** Creates the private reference directory and rejects a symlink or non-directory at that path. */
async function directory(app) {
  const path = join(app.store.root, 'references'); await mkdir(path, { recursive: true, mode: 0o700 });
  const stat = await lstat(path); if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Reference directory must not be a symlink'); return path;
}
/** Validates a filename, supported MIME type, canonical base64, and file-size limit; returns bytes and their content-addressed storage name. */
function binaryFile({ name, mimeType, base64 }) {
  if (typeof name !== 'string' || !name.trim() || name.length > 1024 || /[\\/]/.test(name)) throw new Error('Reference name must be a filename');
  if (!MIME[mimeType]) throw new Error('Reference type must be PDF, UTF-8 text, JSON, CSV, or a supported image');
  const maxBytes = mimeType.startsWith('image/') ? REFERENCE_LIMITS.maxImageBytes : REFERENCE_LIMITS.maxTextFileBytes;
  if (typeof base64 !== 'string' || base64.length > Math.ceil(maxBytes / 3) * 4 || base64.length % 4 !== 0 || /[^A-Za-z0-9+/=]/.test(base64) || /=/.test(base64.slice(0, -2))) throw new Error('Reference file must be canonical base64 within the app file size limit');
  const bytes = Buffer.from(base64, 'base64'); if (!bytes.length || bytes.length > maxBytes || bytes.toString('base64') !== base64) throw new Error('Reference file exceeds the app file size limit or is empty');
  const sha256 = createHash('sha256').update(bytes).digest('hex'); return { bytes, sha256, filename: `${sha256}.${MIME[mimeType]}` };
}
/** Reads a regular stored reference and verifies its hash, byte count, and content-addressed filename against attachment metadata. */
async function readReference(app, attachment) {
  if (!storedName.test(attachment.storedFilename || '')) throw new Error('Reference bytes are unavailable; import the portable file bundle before running');
  const path = join(await directory(app), attachment.storedFilename); let stat;
  try { stat = await lstat(path); } catch (error) { if (error.code === 'ENOENT') throw new Error('Reference bytes are unavailable; import the portable file bundle before running'); throw error; }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_FILE_BYTES) throw new Error('Invalid stored reference file');
  const bytes = await readFile(path); const hash = createHash('sha256').update(bytes).digest('hex');
  if (hash !== attachment.sha256 || bytes.length !== attachment.byteCount || !attachment.storedFilename.startsWith(hash + '.')) throw new Error('Stored reference failed its integrity check');
  return { path, bytes };
}
/** Stores validated content-addressed bytes and performs native extraction under a cancellable lease, returning integrity metadata and truncation status. */
export async function addReferenceFile(app, args) {
  const { bytes, sha256, filename } = binaryFile(args); const path = join(await directory(app), filename);
  try {
    const stat = await lstat(path); if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== bytes.length || !bytes.equals(await readFile(path))) throw new Error('Reference storage collision or invalid file');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    const temporary = `${path}.${randomUUID()}.tmp`;
    try { await writeFile(temporary, bytes, { flag: 'wx', mode: 0o600 }); await rename(temporary, path); } finally { await unlink(temporary).catch(() => {}); }
  }
  if (app.active) throw new Error('Wait for the active evaluation before extracting a reference file');
  const lockId = randomUUID(); await app.store.acquireRunLock(lockId);
  let value; const controller = new AbortController(); app.transientController = controller;
  try {
    const binary = await app.resolveBinary({ dataDir: app.store.root, env: app.env, signal: controller.signal });
    value = await app.invoke(binary, { operation: 'extract-reference', fileURL: pathToFileURL(path).href, name: args.name, mimeType: args.mimeType }, { timeoutMs: 60000, signal: controller.signal, lease: app.store.lease(lockId) });
  } finally { await app.store.releaseRunLock(lockId); if (app.transientController === controller) app.transientController = null; }
  const attachment = value?.attachment;
  if (!attachment || !['text', 'image'].includes(attachment.kind) || (attachment.kind === 'text' && typeof attachment.text !== 'string')) throw new Error(value?.error?.message || value?.error || 'Native reference extraction failed');
  return { attachment: { ...attachment, id: randomUUID(), name: args.name, storedFilename: filename, byteCount: bytes.length, sha256 }, truncated: !!value.truncated };
}
/** Exports integrity-checked stored attachments as portable base64 files within the shared encoded-byte budget. */
export async function exportReferences(app, suite) {
  const files = []; let encodedBytes = 0;
  for (const attachment of suite.attachments || []) if (attachment.storedFilename && (attachment.kind === 'image' || storedName.test(attachment.storedFilename))) {
    const { bytes } = await readReference(app, attachment); const extension = attachment.storedFilename.split('.').at(-1); const mimeType = Object.entries(MIME).find(([, ext]) => ext === extension)?.[0];
    encodedBytes = referenceBundleBytes(encodedBytes, bytes.length);
    files.push({ attachmentId: attachment.id, name: attachment.name, mimeType, base64: bytes.toString('base64') });
  }
  return files;
}
/** Checks the encoded-byte budget, distinct attachment identities, and supplied integrity metadata before any extraction or storage writes; preserves attachment IDs. */
export async function importReferences(app, suite, files) {
  if (!Array.isArray(files) || files.length > 20) throw new Error('referenceFiles must be an array of at most 20 files');
  const attachments = [...(suite.attachments || [])];
  const identities = attachments.filter((item) => item.id).map((item) => id(item.id, 'attachment ID'));
  if (new Set(identities).size !== identities.length) throw new Error('Suite attachment IDs must be unique');
  const matched = new Set(); let encodedBytes = 0;
  // Resolve every identity before extraction writes reference bytes. A filename
  // can bridge legacy bundles only when it identifies exactly one attachment.
  const targets = files.map((file) => {
    let index;
    if (file.attachmentId !== undefined) {
      const attachmentID = id(file.attachmentId, 'attachmentId');
      index = attachments.findIndex((item) => item.id?.toLowerCase() === attachmentID);
      if (index === -1) throw new Error('Reference attachment ID is not present in the imported suite');
    } else {
      const candidates = attachments.map((item, index) => ({ item, index })).filter(({ item }) => item.name === file.name);
      if (candidates.length > 1) throw new Error('Legacy reference filename is ambiguous; include attachmentId');
      index = candidates[0]?.index ?? -1;
    }
    const incoming = binaryFile(file);
    encodedBytes = referenceBundleBytes(encodedBytes, incoming.bytes.length);
    if (index !== -1) {
      const original = attachments[index];
      if (original.sha256 && original.sha256 !== incoming.sha256 || original.byteCount !== undefined && original.byteCount !== incoming.bytes.length) throw new Error('Imported reference bytes do not match the suite attachment');
    }
    const identity = index === -1 ? `new:${file.name}` : `existing:${index}`;
    if (matched.has(identity)) throw new Error('Reference files must identify distinct attachments');
    matched.add(identity);
    return index;
  });
  for (const [position, file] of files.entries()) {
    const extracted = await addReferenceFile(app, file);
    const index = targets[position];
    if (index === -1) attachments.push(extracted.attachment);
    else {
      const original = attachments[index];
      if (original.sha256 && original.sha256 !== extracted.attachment.sha256 || original.byteCount !== undefined && original.byteCount !== extracted.attachment.byteCount) throw new Error('Imported reference bytes do not match the suite attachment');
      attachments[index] = { ...extracted.attachment, id: original.id || extracted.attachment.id };
    }
  }
  return { ...suite, attachments };
}
/** Verifies stored attachment bytes and returns file URLs for image references, rejecting unavailable image content. */
export async function imageInputs(app, suite) {
  const images = [];
  for (const attachment of suite.attachments || []) {
    if (attachment.storedFilename && (attachment.kind === 'image' || storedName.test(attachment.storedFilename))) { const { path } = await readReference(app, attachment); if (attachment.kind === 'image') images.push({ label: attachment.name, url: pathToFileURL(path).href }); }
    else if (attachment.kind === 'image') throw new Error('Image reference bytes are unavailable');
  }
  return images;
}
