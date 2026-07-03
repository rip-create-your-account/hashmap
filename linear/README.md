## Linear hashing

Linear hashing is a technique for enabling incremental adjustements to the capacity of the hash table. It enables each individual `insert()` to also grow the hash table by a little and for each `remove()` to also shrink the hash table by a little. This means:
* No `O(table_size)` grow/resize/shrink operations.
* Ability to maintain the target load factor at ALL times - not just resize at some max load factor.
* Significantly reduced tail latency for all operations.

What we present here is Linear Hashing combined with our algorithm so that we get incremental resizing both in time and in memory use.

Let's look at what memory use looks like for your average open addressing hash table that grows by allocating a new table with 2x capacity and then moves all entries over to it in a big `O(table_size)` operation.

https://github.com/user-attachments/assets/42fe02bd-49b8-497e-87de-98e09f9b04ba

You can see how the each time the unused capacity gets down to ~10% the table grows by 2x. But we can also see how we end up with ~3x more reserved physical memory than what we would strictly need. This is because the table grows by 2x, leading to unused space, and because our `Allocator` decides to never release the memory of the smaller tables back to the OS.

Let's look at how our linear hashing does it.

https://github.com/user-attachments/assets/12f71fa5-bb8f-4b35-87e9-2dff5682ce42

Nice. Observe how the "capacity" of the table is always exactly at 20% unused space. Each `insert()` also does a little resizing work to increase the capacity of the hash table just enough to always remain at the target load factor. And because of the memory-access patterns of linear hashing the OS is able to map in the physical memory very precisely on-demand.

### Shrinking

https://github.com/user-attachments/assets/1b6ec11e-2255-44cf-a91a-175a1724ddd3

Here we insert 2<sup>19</sup> entries to the hash table and then start removing entries. For each remove linear hashing will also shrink the capacity such that it maintains the target of 11.1% unused space in the table. The implementation also occasionally calls `madvise(MADV_DONTNEED)` to release the physical memory back to the OS.

### Cost of lookups

So, with linear hashing we get to maintain some desired load factor at all times precisely. But at what cost? Where in the probe sequence do the entries end up at?

https://github.com/user-attachments/assets/97bc9205-7c8d-40cb-a838-cbcbfbced33f

__NOTE__ that the Y-axis is the **fraction** of the number of active entries in the table. Also the window size is 8 here. Here the four hash tables maintain their declared load factor at all times across the three phases of the test. First some inserts, then removes and then mixed inserts/removes.

Analysis: use 50% load factor so ~70% of your lookups need to test only one slot.

## Conclusion

Is good. But the algorithm is very subtle and it feels like an accident that it works as well as it does.

## Appendix

A "simplified" "reference" "implementation" that uses a data-layout where per-entry metadata is in a separate array from the key-value pair.

```zig
const std = @import("std");

export fn example(num: u64) usize {
    const Map = HashMapUnmanaged(u64, u64, .{ .window_size = 4 });
    const inf = InfAllocator.allocate(1 << 42) catch unreachable;
    const dsts = std.mem.bytesAsSlice(u8, inf[0 .. 1 << 32]);
    const entries = std.mem.bytesAsSlice(Map.Entry, inf[1 << 32 ..])[0 .. 1 << 32];

    var map = Map.initBuffer(dsts, entries, 16);
    for (0..num) |i| {
        const key: u64 = @intCast(i);
        if (map.get(key) == null) map.putNoClobber(key, key);
    }
    for (0..num/2) |i| {
        const key: u64 = @intCast(i);
        _ = map.remove(key);
    }
    return map.len;
}

pub fn HashMapUnmanaged(
    comptime K: type,
    comptime V: type,
    comptime options: struct { window_size: usize },
) type {
        return struct {
        const Self = @This();
        const W = options.window_size;

        const Entry = struct { key: K, val: V };

        dsts: [*]u8 = undefined,
        entries: []Entry = undefined,
        mask: u64 = 0,
        split: u64 = 0,
        largestdst: usize = 0,
        len: usize = 0,
        size: usize = 0,

        pub fn get(table: *const Self, k: K) ?V {
            var slothash = hash0(k);
            var dst: usize = 1;
            while (true) {
                if (dst > table.largestdst) {
                    return null;
                }

                const curdst = dst + (W - 1);
                for (0..W) |idxInWindow| {
                    var slot = (slothash +% idxInWindow) & table.mask;
                    if (slot >= table.split) slot -= table.size / 2;

                    const mydst = curdst - idxInWindow;
                    if (table.dsts[slot] == mydst and table.entries[slot].key == k) {
                        return table.entries[slot].val;
                    }
                }

                slothash = hashN(k, dst);
                dst += W;
            }
        }

        pub fn putNoClobber(table: *Self, k: K, v: V) void {
            // Do the linear hashing thing first
            const load = ((table.len * 7) / 4) + 1;
            if (load >= table.split) {
                // TODO: Move entries in large batches and use SIMD to do it faster.
                const numInserts = 1 + (load - table.split);
                const reinsertStart = table.split - (table.size / 2);
                var reinsertEnd = reinsertStart + numInserts;

                table.split += numInserts;
                if (table.split >= table.size) {
                    table.split = table.size;
                    reinsertEnd = @max(reinsertStart, table.size / 2);
                    table.size = table.size * 2;
                    table.mask = table.size - 1;
                    if (table.size > table.entries.len) @panic("table out of capacity");
                }

                for (reinsertStart..reinsertEnd) |slot| {
                    if (table.dsts[slot] == 0) continue;
                    table.dsts[slot] = 0;

                    const entry = table.entries[slot];
                    table.len -= 1;
                    table.putInternal(entry.key, entry.val);
                }
            }

            table.putInternal(k, v);
        }

        fn putInternal(table: *Self, k: K, v: V) void {
            std.debug.assert(table.len < table.size);

            var entry: Entry = .{ .key = k, .val = v };

            from1loop: while (true) {
                var slothash = hash0(entry.key);
                var dst: usize = 1;
                while (true) {
                    // Find the smallest-dst slot inside the window (or the first empty slot)
                    var smallestDst: usize = std.math.maxInt(usize);
                    var smallestIdx: usize = 0;
                    for (0..W) |idxInWindow| {
                        var slot = (slothash +% idxInWindow) & table.mask;
                        if (slot >= table.split) slot -= table.size / 2;

                        const elemdst = table.dsts[slot];
                        if (elemdst < smallestDst) {
                            smallestDst = elemdst;
                            smallestIdx = idxInWindow;
                        }
                        if (smallestDst == 0) break;
                    }

                    // Take it
                    const curdst = dst + (W - 1);
                    const mydst = curdst - smallestIdx;
                    if (smallestDst < mydst) {
                        if (mydst > table.largestdst) {
                            table.largestdst = mydst;
                        }

                        var slot = (slothash +% smallestIdx) & table.mask;
                        if (slot >= table.split) slot -= table.size / 2;

                        table.dsts[slot] = @intCast(mydst);
                        if (smallestDst == 0) {
                            table.entries[slot] = entry;
                            table.len += 1;
                            return;
                        }

                        const oldentry = table.entries[slot];
                        table.entries[slot] = entry;
                        entry = oldentry;

                        // Continue with the evicted key. Restart from distance 1 so
                        // we can try taking slots that have become free due to reinserts
                        // moving entries from them.
                        continue :from1loop;
                    }

                    slothash = hashN(entry.key, dst);
                    dst += W;
                    if (dst > 128) {
                        @panic("TODO: use a hash function that sucks less");
                    }
                }
            }
        }

        pub fn remove(table: *Self, k: K) bool {
            var slothash = hash0(k);
            var dst: usize = 1;
            while (true) {
                if (dst > table.largestdst) {
                    return false;
                }

                const curdst = dst + (W - 1);
                for (0..W) |idxInWindow| {
                    var slot = (slothash +% idxInWindow) & table.mask;
                    if (slot >= table.split) slot -= table.size / 2;

                    const mydst = curdst - idxInWindow;
                    if (table.dsts[slot] == mydst and table.entries[slot].key == k) {
                        table.dsts[slot] = 0;
                        table.len -= 1;

                        // Maintain the desired load factor.
                        const load = ((table.len * 7) / 4) + 1;
                        if (load < table.split) {
                            const numMoves = 1 + (table.split - load);
                            var reinsertStart = table.split - numMoves;
                            const reinsertEnd = table.split;

                            table.split -= numMoves;
                            if (table.split < table.size / 2) {
                                table.split = table.size / 2;
                                reinsertStart = table.size / 2;
                                table.size = table.size / 2;
                                table.mask = table.size - 1;
                            }

                            for (reinsertStart..reinsertEnd) |reslot| {
                                if (table.dsts[reslot] == 0) continue;
                                table.dsts[reslot] = 0;

                                const entry = table.entries[reslot];
                                table.len -= 1;
                                table.putInternal(entry.key, entry.val);
                            }

                            // TODO: madvise(FREE)
                        }
                        return true;
                    }
                }

                slothash = hashN(k, dst);
                dst += W;
            }
        }

        pub fn clearRetainingCapacity(table: *Self) void {
            if (table.size == 0) return;
            @memset(table.dsts[0..table.split], 0);
            table.largestdst = 0;
            table.len = 0;
        }

        // Init with existing buffers. "dsts" must be all zeroes.
        pub fn initBuffer(dsts: []u8, slice: []Entry, initialSize: usize) Self {
            std.debug.assert(std.math.isPowerOfTwo(initialSize));
            std.debug.assert(initialSize <= slice.len);
            std.debug.assert(dsts.len >= slice.len);

            // quick check that at least the first 64 dsts are zeroes.
            std.debug.assert(@reduce(.Or, @as(@Vector(64, u8), dsts[0..64].*)) == 0);

            return .{
                .dsts = dsts.ptr,
                .entries = slice,
                .size = initialSize,
                .mask = initialSize - 1,
                .split = initialSize,
            };
        }

        fn hash0(key: K) u64 {
            return std.hash.int(key);
        }

        fn hashN(key: K, seed: usize) u64 {
            const mul = 11400714819323198485;
            return std.hash.int(key ^ (seed *% mul));
        }
    };
}

const InfAllocator = struct {
    fn allocate(sizeInBytes: usize) ![]align(std.heap.page_size_min) u8 {
        std.debug.assert(sizeInBytes >= std.heap.page_size_min); // at least one page
        std.debug.assert(sizeInBytes & (std.heap.page_size_min - 1) == 0);

        // TODO: On-demand paging for Windows
        const slice = try std.posix.mmap(
            null,
            sizeInBytes,
            .{ .READ = true, .WRITE = true },
            .{
                .TYPE = .PRIVATE,
                .ANONYMOUS = true,
                // NOTE: NORESERVE for no swap space reservation. This makes Linux let us do
                // gigantic reservations that have nothing do to with the physical capabilities
                // of the physical system.
                .NORESERVE = true,
            },
            -1,
            0,
        );
        errdefer destroy(slice);

        if (sizeInBytes >= 1 << 21) {
            // Tell OS to prefer HUGEPAGES (2MB) for the whole thing
            _ = std.os.linux.madvise(slice.ptr, slice.len, std.os.linux.MADV.HUGEPAGE);

            // Just make it give us the first 2MB asap
            const MADV_POPULATE_WRITE = 23;
            _ = std.os.linux.madvise(slice.ptr, 1 << 21, MADV_POPULATE_WRITE);
        }

        // Install a guard page in the end so we crash when we get close.
        // TODO: Use madvise MADV_INSTALL_GUARD
        // TODO: Make it larger?
        try std.process.protectMemory(@alignCast(slice[slice.len - std.heap.page_size_min ..]), .{
            .read = false,
            .write = false,
            .execute = false,
        });

        return slice;
    }
    fn destroy(slice: []align(std.heap.page_size_min) u8) void {
        std.posix.munmap(slice);
    }
};
```
