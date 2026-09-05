+++
id = "WASM.9"
title = "Stream assets and keep them compressed all the way to their destination"
category = "wasm"
status = "draft"
summary = "With no memory mapping and a small contiguous heap, decompress-then-use often does not fit; choose formats whose decode target is the consumer and stream in bounded chunks."
tags = ["asset-streaming", "ktx2", "basis", "asset-bundles", "opfs", "compression"]
+++

## Rationale

Native code memory-maps a large asset and lets the OS page it. WebAssembly has
no equivalent: bytes must land in linear memory, which is a single contiguous
allocation you are trying to keep small (`WASM.1`). "Download, decompress into
memory, then upload" can require several times the asset's final size to be
resident simultaneously, and the peak is what kills the tab.

The technique that survives this is to pick formats whose **decode target is the
consumer**, so the data is never materialised in an intermediate expanded form.
KTX2 with Basis Universal supercompression is the clearest example. One
interchange asset transcodes at load into whichever block-compressed format the
device supports — BC, ASTC or ETC2 — so the texture is GPU-resident in a
compressed form and is never materialised as uncompressed RGBA on either side.
Those block formats run at roughly 4–8 bits per pixel against 32 bpp for
uncompressed RGBA, and Basis's own transmission bitrates are lower still
(ETC1S is documented at roughly 0.3–3 bpp). Unity applies the same principle at
engine scale from the opposite direction: AssetBundles are documented as
downloading *directly into the Unity heap*, which avoids the browser making a
second allocation for the transfer, and they can be loaded and unloaded on
demand.

The transfer buffer is a resident cost that is easy to forget. Where a download
lands outside the engine heap it is invisible to an in-heap allocator profile
while still consuming host memory, which is exactly why Unity routes AssetBundles
into its own heap instead. Persistence is a separate mechanism again: Unity's
Data Caching uses the IndexedDB and Cache APIs to avoid re-downloading, which is
about repeat visits rather than peak residency. (Checked 2026-09-05.)

## Guidance

- **Stream in bounded chunks and release each one.** Peak residency should be a
  function of the chunk size, not of the asset size.
- **Never assume the whole asset is addressable.** Validate every offset and
  length against the authoritative total size, not against whatever window is
  currently mapped.
- **Use checked arithmetic on offsets and sizes.** `offset + length` on a 32-bit
  size type can wrap into an in-range value; treat downloaded data as untrusted.
- **Choose transcodable texture formats.** KTX2/Basis gives one asset per texture
  rather than one per target format, and decodes straight to the block-compressed
  format the device supports — never through an uncompressed intermediate.
- **Do not use LZMA on the web.** Unity documents decompression stalls; LZ4 or
  uncompressed with Brotli at the transport layer is the working combination.
- **Split bundles by use**, so a download spike does not match the whole payload —
  but not so finely that request count dominates.
- **Compress at the transport layer too.** Brotli on the server is free
  bandwidth; it is not a substitute for the format choice above.
- **Split bundles by use, not evenly.** A monolithic bundle spikes memory on
  download; too many bundles makes request count dominate.
- **Cache for repeat visits, separately from residency.** IndexedDB, the Cache
  API or OPFS avoid re-downloading; that is a different problem from peak
  memory, and solving one does not solve the other. OPFS access handles are the closest the web has to memory
  mapping, and are what Photoshop uses to page document data.

## Example

```cpp
// The shape that does not fit: three copies of the asset resident at the peak
// -- the download buffer, the decompressed staging copy, and the GPU upload.
// On a 256 MB heap a 60 MB texture pack fails here, not at the upload.
void load_textures_bad(const std::vector<std::byte>& downloaded) {
    std::vector<std::byte> decompressed = inflate(downloaded);   // copy 2
    for (const TextureRegion& r : parse_regions(decompressed)) {
        upload_to_gpu(decompressed.data() + r.offset, r.size);   // copy 3
    }
}   // peak = downloaded + decompressed + driver-side staging

// The shape that does: a bounded window over an incremental source, validated
// against the authoritative total length rather than against the window.
class ByteSource {
public:
    virtual ~ByteSource() = default;

    // Total size of the underlying resource, known from the transfer metadata
    // before any bytes arrive. This is what offsets are validated against --
    // a span over a prefix cannot validate a region near the end.
    [[nodiscard]] virtual std::uint64_t total_size() const noexcept = 0;

    // Fills `into` from `offset`. Returns false rather than throwing so the
    // caller sees truncation as a value, not as an exception from a hot path.
    [[nodiscard]] virtual bool read(std::uint64_t offset,
                                    std::span<std::byte> into) noexcept = 0;
};

// Checked arithmetic: on wasm32 a size_t is 32 bits, so offset + length can
// wrap to a small in-range value. An unchecked bounds test would then pass.
[[nodiscard]] inline bool region_fits(std::uint64_t offset, std::uint64_t length,
                                      std::uint64_t total) noexcept {
    if (length > total) {
        return false;                       // cannot fit regardless of offset
    }
    return offset <= total - length;        // no addition, so no overflow
}

class StreamingTextureLoader {
public:
    // Peak residency is one chunk, whatever the asset size. The chunk buffer is
    // allocated once and reused; growing it per texture would defeat the point.
    explicit StreamingTextureLoader(std::size_t chunk_bytes)
        : chunk_(chunk_bytes) {}

    [[nodiscard]] bool load(ByteSource& source,
                            std::span<const TextureRegion> regions) noexcept {
        const std::uint64_t total = source.total_size();

        for (const TextureRegion& r : regions) {
            if (!region_fits(r.offset, r.size, total)) {
                return false;               // named failure, reads nothing
            }

            // Transcode directly into the device's native GPU format. The
            // expanded RGBA form is never materialised on the CPU at all --
            // that is the whole point of a supercompressed container.
            if (!transcode_and_upload(source, r, chunk_)) {
                return false;
            }
        }
        return true;
    }

private:
    [[nodiscard]] static bool transcode_and_upload(ByteSource& source,
                                                   const TextureRegion& region,
                                                   std::span<std::byte> scratch) noexcept;

    std::vector<std::byte> chunk_;          // the only large allocation
};

// Assert the invariant rather than hoping for it. A fixture-sized test proves
// nothing about the streaming path; this must run against a realistic asset.
struct ResidencyAssertion {
    std::size_t asset_bytes;         // e.g. 400 MB
    std::size_t peak_heap_bytes;     // must stay near chunk size, not asset size
    std::size_t chunk_bytes;
};
```

## Caveats

- **Chunking costs locality and bookkeeping.** It wins because the alternative is
  failure, not because it is faster.
- **Transcoding is CPU work at load time.** Basis transcode is fast but not free;
  it trades startup CPU for memory and download size. Measure it into your
  startup budget (`WASM.7`).
- **Supercompressed formats are lossy.** KTX2/Basis targets GPU block formats;
  it is not the right container for data that must round-trip exactly.
- **A sampled verification proves very little.** Checking one block of a
  streamed upload passes while another chunk is truncated or written to the
  wrong offset. Verify every byte, in a diagnostic pass, or do not claim
  integrity.
- **OPFS is not universally available** and behaves differently in private
  browsing. Treat the cache as an optimisation with a working cold path.
- **Brotli at the transport layer costs server CPU** and needs precompression for
  large static assets, or the first request pays for it.

## References

- [Khronos — KTX GPU texture container format](https://www.khronos.org/ktx/)
- [Binomial LLC — Basis Universal](https://github.com/BinomialLLC/basis_universal)
- [Unity — Memory in Unity Web](https://docs.unity3d.com/Manual/webgl-memory.html)
- [Kongregate — Unity WebGL memory optimization](https://blog.kongregate.com/unity-webgl-memory-optimization-part-deux/)
- [Chrome/Adobe — Photoshop's journey to the web](https://web.dev/articles/ps-on-the-web)
- Cross-reference: `WASM.1` (the heap this protects), `WASM.7` (transcode cost in
  the startup budget), `WASM.14` (weakest-device budget), `MEM.9` (allocate at init,
  not in steady state).
