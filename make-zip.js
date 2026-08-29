#!/usr/bin/env node
// Minimal ZIP archive creator (no external deps) for packaging a Factorio mod.
// Usage: node make-zip.js <source-dir> <output.zip>
// Packs all files under <source-dir> into the zip, preserving relative paths.
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

function walk(dir, base = dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...walk(full, base));
    } else if (entry.isFile()) {
      out.push({ abs: full, rel: path.relative(base, full) });
    }
  }
  return out;
}

// CRC32 table
const crcTable = (() => {
  const t = new Int32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function u16(n) { const b = Buffer.alloc(2); b.writeUInt16LE(n, 0); return b; }
function u32(n) { const b = Buffer.alloc(4); b.writeUInt32LE(n, 0); return b; }

const srcDir = process.argv[2];
const outFile = process.argv[3];
// Optional prefix prepended to every stored path (e.g. "ai-player-v3" so
// the zip contains ai-player-v3/info.json — what Factorio expects).
const prefix = process.argv[4] ? process.argv[4].replace(/\/+$/, "") : "";
if (!srcDir || !outFile) {
  console.error("Usage: node make-zip.js <source-dir> <output.zip> [path-prefix]");
  process.exit(1);
}

const files = walk(srcDir).sort((a, b) => a.rel.localeCompare(b.rel));
const chunks = [];
const central = [];
let offset = 0;

for (const f of files) {
  const data = fs.readFileSync(f.abs);
  const crc = crc32(data);
  // Use forward slashes in zip paths; prepend optional prefix for the
  // top-level mod folder Factorio expects inside the archive.
  const storedName = (prefix ? prefix + "/" : "") + f.rel.split(path.sep).join("/");
  const nameBuf = Buffer.from(storedName, "utf8");
  const compressed = zlib.deflateRawSync(data, { level: 9 });

  // Local file header
  const localHeader = Buffer.concat([
    u32(0x04034b50),       // signature
    u16(20),               // version needed to extract (2.0)
    u16(0),                // general purpose bit flag
    u16(8),                // compression method: deflate
    u16(0),                // mod time
    u16(0),                // mod date
    u32(crc),              // crc-32
    u32(compressed.length),// compressed size
    u32(data.length),      // uncompressed size
    u16(nameBuf.length),   // file name length
    u16(0),                // extra field length
    nameBuf,               // file name
  ]);
  chunks.push(localHeader, compressed);

  // Central directory record (deferred)
  central.push(Buffer.concat([
    u32(0x02014b50),       // signature
    u16(20),               // version made by
    u16(20),               // version needed to extract
    u16(0),                // general purpose bit flag
    u16(8),                // compression method: deflate
    u16(0),                // mod time
    u16(0),                // mod date
    u32(crc),
    u32(compressed.length),
    u32(data.length),
    u16(nameBuf.length),
    u16(0),                // extra field length
    u16(0),                // file comment length
    u16(0),                // disk number start
    u16(0),                // internal file attributes
    u32(0),                // external file attributes
    u32(offset),           // offset of local header
    nameBuf,
  ]));

  offset += localHeader.length + compressed.length;
}

// Central directory
const cdStart = offset;
let cdSize = 0;
for (const c of central) { chunks.push(c); cdSize += c.length; }

// End of central directory record
const eocd = Buffer.concat([
  u32(0x06054b50),         // signature
  u16(0),                  // disk number
  u16(0),                  // disk with central dir
  u16(files.length),       // entries on this disk
  u16(files.length),       // total entries
  u32(cdSize),             // central directory size
  u32(cdStart),            // offset of central dir
  u16(0),                  // comment length
]);
chunks.push(eocd);

fs.writeFileSync(outFile, Buffer.concat(chunks));
console.log(`Created ${outFile} with ${files.length} files (${(fs.statSync(outFile).size / 1024).toFixed(1)} KB)`);
for (const f of files) console.log(`  ${f.rel}`);
