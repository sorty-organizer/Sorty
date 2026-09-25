# Content metadata cache

`SharedContentMetadataCache` reuses extracted text, OCR and document metadata across scans. Keys include the source path, modification date, size and analysis options.

The cache loads lazily on first analysis. Concurrent callers share one disk load and one extraction per key. Clearing it invalidates pending loads and extractions so their results cannot repopulate the cache.

The cache stores LZFSE-compressed JSON at `~/Library/Caches/com.sorty.app/content-metadata-cache.json.lzfse`. It reads the older `.json` file and removes it only after successfully writing the compressed replacement. Corrupt data is treated as a cache miss.

The in-memory budget counts encoded entries, including paths and options, up to 32 MiB and 10,000 entries. This is an accounting budget, not a measurement of Swift heap usage. Eviction removes least recently used entries and trims to 75% of the byte budget. Entries older than 14 days are dropped when loading. Access times update in memory and persist with the next content write; a scan containing only cache hits does not rewrite the file.

Scan-driven writes are debounced for 350 ms. Explicit flushes cancel pending writes. Compression and atomic writes run on the cache actor, away from the main actor. No image quality or extracted text is reduced for compression.
