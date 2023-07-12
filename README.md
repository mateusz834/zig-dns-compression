# zig-dns-compression
A unique way of compressing DNS names with the use of zig std HashMap

The implementation uses the *Adapted hash map API, so that there is no need
to allocate a new byte slice for each name (that is beeing added to the compression hash map),
instead it only stores an u14 integer reference to a (possibly compressed) name.
