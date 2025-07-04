const std = @import("std");
const getAutoHashFn = std.hash_map.getAutoHashFn;
const rotl = std.math.rotl;

// Hash map that combines Robin Hood hashing and 2-choice hashing.
//
// Entries are always placed within 32 slots of their preferred slot. If such placement is not possible then
// a secondary hash function is used to place the key, but again with the same restriction.
// BUT!!! But when placing an entry based on the secondary hash function it's "distance"
// from the optimal spot will be considered larger than that of those placed with
// the primary hash function. This means that those placed with primary hf will likely end up
// getting kicked out and themselves become placed with the 2nd hf.
//
// Lookups/Updates are worst-case O(1). Consistently achieves 100% load before growing
// even up to 2^32 entries.
pub fn Map32(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime growAtPercentage: u64,
) type {
    if (growAtPercentage < 1 or growAtPercentage > 100)
        @compileError("growAtPercentage must be in [1, 100].");
    return struct {
        const Self = @This();

        const Kv = struct {
            key: K,
            value: V,
        };

        const emptyMarker = 0b0000_0000;

        // the tombstone marker is designed such that it is always lesser compared to entries
        // placed with the last hashfn. This design has the nice property that to take
        // tombstoned slots when inserting we don't specifically need to search for them
        // when on the last hashfn. Remember that only when placing with the last hashfn
        // we are allowed to take tombstoned slots.
        const tombstoneMarker = 0b1000_0000;

        // distances from the optimal bucket and some metadata. For distinguishing from empty
        // slots the hash function field starts counting from 1 for present entries.
        //
        // The array is allocated with extra trailing 32 bytes that are maintained such that they repeat
        // the very first 32 bytes. This allows lookups to always do 32-byte reads into this array.
        //
        // NOTE: PACKING:
        //      0b01001101
        //        hhuddddd
        //      h - which hash function was used, hf0..hf1? Conceptually hfN contributes N*32 to the "distance".
        //          hf0 is actually represented as 0b01 so that bit pattern of 0b00000000 can mark empty slots
        //          and hf1 is actually 0b11 so that it's always greater than the tombstoneMarker.
        //      u - unused. Hmm... Perhaps distances should be up to 63? Maybe better for 512-bit vectors
        //      d - the distance [0, 1..30, 31] from the preferred slot for the hfN.
        dsts: [*]u8 = undefined,
        fps: [*]u8 = undefined,
        // dstsandfps: [*]u16 = undefined, // TODO: <-- start doing THIS for 1 less cache-miss
        arr: [*]Kv = undefined,
        size: usize = 0,
        growAt: usize = 0,
        len: usize = 0,
        tombstones: usize = 0,

        allocator: std.mem.Allocator,
        ctx: Context = undefined, // TODO: How should the ctx work?

        // TODO: Consider using a fast and good hash function for hf0 but a secure and Hash DoS resistant
        // hash functions for hf1..hfN. Consider that for small hash tables most of the time is spent hashing
        // the key and with small hash tables there's no risk of DDOS.

        // NOTE: Consider that I created a hash table with size of 1<<32 and populated
        // it to 100% load. At such scenario the largest "distance" seen for hf2 was 21.
        // Please consult the below table.
        // len=4294967296 size=4294967296 350.235ns/insert
        // [hfN] entries    largest_seen_dst
        // [hf0] 1830596255 31
        // [hf1] 2464371041 21

        inline fn hashreduce(hash: u64, size: u64) u64 {
            return @truncate(std.math.mulWide(u64, hash, size) >> 64);
        }

        inline fn slotwrap(slot: u64, size: u64) u64 {
            if (slot >= size) {
                @branchHint(.unlikely);
                std.debug.assert(slot - size < 32);
                return slot - size;
            }
            return slot;
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn initWithSize(allocator: std.mem.Allocator, size: usize) !Self {
            const dstsandfps = try allocator.alloc(u8, (size + 32) * 2);
            errdefer allocator.free(dstsandfps);
            @memset(dstsandfps, 0);

            const arr = try allocator.alloc(Kv, size);
            errdefer allocator.free(arr);

            return .{
                .dsts = dstsandfps[0 .. dstsandfps.len / 2].ptr,
                .fps = dstsandfps[dstsandfps.len / 2 ..].ptr,
                .arr = arr.ptr,
                .allocator = allocator,
                .size = size,
                .growAt = @max(1, (size * growAtPercentage) / 100),
            };
        }

        pub fn initForLen(allocator: std.mem.Allocator, len: usize) !Self {
            const size = (try std.math.mul(usize, len, 100)) / growAtPercentage;
            const plus1 = @intFromBool(size * growAtPercentage < len * 100);
            return initWithSize(allocator, size + plus1);
        }

        pub fn deinit(self: Self) void {
            if (self.size > 0) {
                self.allocator.free(self.arr[0..self.size]);
                self.allocator.free(self.dsts[0 .. (self.size + 32) * 2]);
            }
        }

        pub fn clone(self: *Self, allocator: std.mem.Allocator) !Self {
            const dstsandfps = try allocator.dupe(u8, self.dsts[0 .. (self.size + 32) * 32]);
            errdefer allocator.free(dstsandfps);

            const arr = (try allocator.dupe(Kv, self.arr[0..self.size])).ptr;
            errdefer allocator.free(arr);

            var cloned = self.*;
            cloned.dsts = dstsandfps[0 .. dstsandfps.len / 2].ptr;
            cloned.fps = dstsandfps[dstsandfps.len / 2 ..].ptr;
            cloned.arr = arr;
            cloned.allocator = allocator;
            return cloned;
        }

        pub fn capacity(self: Self) usize {
            return self.size;
        }

        pub fn count(self: Self) usize {
            return self.len;
        }

        const dstsProbeVec = std.simd.iota(u8, 32) << @splat(0); // 0<<0, 1<<0, 2<<0...
        const hfMask: @Vector(32, u8) = @splat(1 << 6);

        pub fn get(self: *Self, k: K) ?V {
            if (self.size == 0) {
                return null;
            }

            const hash = self.ctx.hash(k);

            const dsts = self.dsts;
            const fps = self.fps;
            const arr = self.arr;

            var hashslot = hash;
            var myfps: @Vector(32, u8) = @splat(@truncate(hashslot & 0b1111_1111));
            var mydsts = hfMask | dstsProbeVec;
            for (0..2) |_| {
                const slot = hashreduce(hashslot, self.size);
                const elemdsts: @Vector(32, u8) = dsts[slot..][0..32].*;
                const elemfps: @Vector(32, u8) = fps[slot..][0..32].*;

                var matches: u64 = @as(u32, @bitCast(elemdsts == mydsts));
                matches &= @as(u32, @bitCast(elemfps == myfps));
                while (true) : (matches &= matches - 1) {
                    const slotInBucket = @ctz(matches);
                    if (slotInBucket >= 32) {
                        break;
                    }
                    const entry = &arr[slotwrap(slot + slotInBucket, self.size)];
                    if (self.ctx.eql(k, entry.key)) {
                        return entry.value;
                    }
                }

                // Any lesser dsts?
                if (@reduce(.Or, elemdsts < mydsts)) {
                    return null;
                }

                hashslot = rotl(u64, hashslot, 32);
                myfps = @splat(@truncate(hashslot & 0b1111_1111));
                mydsts +%= (hfMask + hfMask); // increment the hashfn
            }
            return null;
        }

        // returns the unique index for the key in the underlying array. If the hash table
        // is at 100% load this allows us to be a MPHF that also stores the keys.
        pub fn getIndex(self: *Self, k: K) ?usize {
            if (self.size == 0) {
                return null;
            }

            const hash = self.ctx.hash(k);

            const dsts = self.dsts;
            const fps = self.fps;
            const arr = self.arr;

            var hashslot = hash;
            var mydsts = hfMask | dstsProbeVec;
            var myfps: @Vector(32, u8) = @splat(@truncate(hashslot & 0b1111_1111));
            for (0..2) |_| {
                const slot = hashreduce(hashslot, self.size);
                const elemdsts: @Vector(32, u8) = dsts[slot..][0..32].*;
                const elemfps: @Vector(32, u8) = fps[slot..][0..32].*;

                var matches: u64 = @as(u32, @bitCast(elemdsts == mydsts));
                matches &= @as(u32, @bitCast(elemfps == myfps));
                while (true) : (matches &= matches - 1) {
                    const slotInBucket = @ctz(matches);
                    if (slotInBucket >= 32) {
                        break;
                    }
                    const entrySlot = slotwrap(slot + slotInBucket, self.size);
                    const entry = &arr[entrySlot];
                    if (self.ctx.eql(k, entry.key)) {
                        return entrySlot;
                    }
                }

                // Any lesser dsts?
                if (@reduce(.Or, elemdsts < mydsts)) {
                    return null;
                }

                hashslot = rotl(u64, hashslot, 32);
                myfps = @splat(@truncate(hashslot & 0b1111_1111));
                mydsts +%= (hfMask + hfMask); // increment the hashfn
            }
            return null;
        }

        pub fn remove(self: *Self, k: K) bool {
            const entrySlot = self.getIndex(k) orelse return false;

            // Removal primarily works by marking the slot with a tombstone. But as an optimization
            // we can mark the slot as empty if this section of the map has never been
            // full enough to cause entries to move to using hf2. This usually significantly
            // reduces the need for rehash().
            // TODO: There are workloads where this optimization is slower.
            // TODO: This implementation misses out on some opportunities to place emptyMarker

            const elemdsts: @Vector(32, u8) = self.dsts[entrySlot..][0..32].*;
            const maxhf0dst: @Vector(32, u8) = @splat(0b0101_1111);

            var marker: usize = tombstoneMarker;
            if (@reduce(.And, elemdsts < maxhf0dst)) {
                marker = emptyMarker;
            }

            // Mark it
            self.dsts[entrySlot] = @intCast(marker);
            if (entrySlot < 32) { // update the trailing repeat byte
                self.dsts[self.size + entrySlot] = @intCast(marker);
            }
            self.len -= 1;
            self.tombstones += marker >> 7; // marked as tombstone?
            return true;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            var hash = self.ctx.hash(key);

            var dsts = self.dsts;
            var fps = self.fps;
            var arr = self.arr;

            var k = key;
            var v = value;

            var checkeq = true;

            var hashslot = hash;
            var mydsts = hfMask | dstsProbeVec;

            loop: switch (@as(u2, 0)) {
                0 => {
                    // Empty?
                    if (self.size == 0) {
                        continue :loop 1;
                    }

                    var slot = hashreduce(hashslot, self.size);
                    var elemdsts: @Vector(32, u8) = dsts[slot..][0..32].*;

                    if (checkeq) {
                        const elemfps: @Vector(32, u8) = fps[slot..][0..32].*;

                        var matches: u64 = @as(u32, @bitCast(elemdsts == mydsts));
                        matches &= @as(u32, @bitCast(elemfps == @as(@Vector(32, u8), @splat(@truncate(hashslot & 0b1111_1111)))));
                        while (true) : (matches &= matches - 1) {
                            const slotInBucket = @ctz(matches);
                            if (slotInBucket >= 32) {
                                break;
                            }
                            const entry = &arr[slotwrap(slot + slotInBucket, self.size)];
                            if (self.ctx.eql(k, entry.key)) {
                                entry.value = v;
                                return;
                            }
                        }
                    }

                    // Prefer inserting into the first empty slot we see. Consider that lookups always probe the whole window looking for the key.
                    // Only after finding it does it check for "lessers". This means that we can insert the key
                    // into any of the slots in the window. Entries don't actually need to be ordered for lookup
                    // to work. This is a major optimization especially on load factors like 80%.
                    const allZeroes: @Vector(32, u8) = @splat(0);
                    const empties: u64 = @as(u32, @bitCast(elemdsts == allZeroes));
                    var firstLesser: u64 = @ctz(empties);

                    var fingerprint = hashslot & 0b1111_1111;
                    var evicted = false;
                    swaploop: switch (firstLesser) {
                        0...31 => {
                            checkeq = false; // we now know that the key is not in the map

                            // Don't bother evicting the lesser if we are already full
                            if (self.len >= self.growAt) {
                                break :swaploop;
                            }

                            // NOTE: Remind yourself that entries placed with a "higher" hashfn WILL have
                            // a "larger" dst even if they are closer to their preferred slot for that hashfn.
                            // NOTE: Remind yourself that tombstones are 128 and if we are on the last hashfn
                            // they are some of the "lessers".
                            var sslot = slotwrap(slot + firstLesser, self.size);
                            var dst: u64 = mydsts[0] + (firstLesser << 0); // faster than mydsts[firstLesser]
                            while (true) { // NOTE: This is a really really really hot loop if going for 100% load.
                                const elemdst: u64 = dsts[sslot];
                                const elemfp: u64 = fps[sslot];
                                if (elemdst <= dst) { // PERF: (elemdst <= dst) is faster than (elemdst < dst) cuz less branch misses
                                    // NOTE: The fact that the above check ends up pushing the _older_ entries out kind of reminds
                                    // me of LRU caches. Is there something here?
                                    dsts[sslot] = @intCast(dst);
                                    fps[sslot] = @intCast(fingerprint);
                                    if (sslot < 32) { // update the trailing repeat byte
                                        dsts[self.size + sslot] = @intCast(dst);
                                        fps[self.size + sslot] = @intCast(fingerprint);
                                    }

                                    const entry = &arr[sslot];
                                    std.mem.swap(K, &k, &entry.key);
                                    std.mem.swap(V, &v, &entry.value);

                                    fingerprint = elemfp;
                                    dst = elemdst;
                                    if (elemdst & 0b0111_1111 == 0) {
                                        // the slot was empty or a tombstone
                                        self.len += 1;
                                        self.tombstones -= elemdst >> 7;
                                        return;
                                    }
                                }

                                dst += 1 << 0;

                                // Did the above "+=" overflow the dst bits? If so then we are at distance of == 31.
                                // This is somehow the fastest way to check (dst == 31) even if less obvious.
                                if ((dst >> 5) & 0b1 == 0b1) {
                                    dst -= 1 << 0;
                                    break;
                                }

                                sslot = slotwrap(sslot + 1, self.size);
                            }

                            // We have some victim that we evicted.
                            evicted = true;

                            // If it's possible that this entry was placed greedily we should not give up
                            // before we check if there's any lessers for this evicted entry using
                            // its current hashfn.

                            mydsts = @as(@Vector(32, u8), @splat(@truncate(dst & 0b1100_0000))) | dstsProbeVec;

                            const d = (dst >> 0) & 0b1_1111;
                            if (d > sslot) {
                                slot = self.size - (d - sslot);
                            } else {
                                slot = sslot - d;
                            }
                            elemdsts = dsts[slot..][0..32].*;
                            continue :swaploop 32;
                        },
                        else => {
                            // Any lesser dsts whose place we can take?
                            const lessers: u64 = @as(u32, @bitCast(elemdsts < mydsts));
                            firstLesser = @ctz(lessers);
                            if (firstLesser < 32) {
                                continue :swaploop 0;
                            }

                            // ensure that the hash is up to date
                            if (evicted) {
                                hash = self.ctx.hash(k); // TODO: This is kind of sad. Maybe we should just hash the preferred slot idx + fingerprint for hf2?
                            }

                            // Try with the next hash fn?
                            const hfnum = (mydsts[0] >> 6) & 0b11;
                            if (hfnum == 0b01) {
                                hashslot = rotl(u64, hash, 32);
                                mydsts = hfMask + hfMask + hfMask | dstsProbeVec;
                                continue :loop 0;
                            }
                        },
                    }

                    // tombstones? rehash?
                    if (self.tombstones >= self.size / 4) {
                        // std.debug.print("rehash: {} {} {}\n", .{ self.len, self.size, self.tombstones });
                        self.rehash();
                        continue :loop 2;
                    }

                    continue :loop 1;
                },
                1 => {
                    // std.debug.print("grow: {} {} {}\n", .{ self.len, self.size, self.tombstones });
                    try self.grow();

                    continue :loop 2;
                },
                2, 3 => {
                    checkeq = false;

                    dsts = self.dsts;
                    fps = self.fps;
                    arr = self.arr;

                    hashslot = hash;
                    mydsts = hfMask | dstsProbeVec;

                    continue :loop 0;
                },
            }
        }

        // rehash inplace.
        pub fn rehash(self: *Self) void {
            if (self.size == 0) {
                @branchHint(.cold);
                return;
            }

            const size = self.size;

            const dsts = self.dsts;
            const fps = self.fps;
            const arr = self.arr;

            // Mark all present slots with a special value so that we know
            // that they are still "unplaced" so that the loop knows which entries still
            // need to be inspected for moving. We re-use the tombstoneMarker for this.
            // Also set tombstones to empties.
            {
                const allZeroes: @Vector(32, u8) = @splat(0);
                const allTombstones: @Vector(32, u8) = @splat(tombstoneMarker);

                var offset: usize = 0;
                while (offset < size) : (offset += 32) {
                    var gdsts: @Vector(32, u8) = dsts[offset..][0..32].*;
                    gdsts = @select(u8, gdsts == allTombstones, allZeroes, gdsts); // tombies to zeroes
                    gdsts = @select(u8, gdsts != allZeroes, allTombstones, allZeroes); // nonzeroes to tombies
                    dsts[offset..][0..32].* = gdsts;
                }
            }

            // Mark the trailing bytes of old dsts as empties so the below loop
            // doesn't accidentally process them
            @memset(dsts[size..][0..32], 0);

            var offset: usize = 0;
            while (offset < size) : (offset += 32) {
                const gdsts: @Vector(32, u8) = dsts[offset..][0..32].*;

                // Go through all the unplaced entries that we see
                const allTombstones: @Vector(32, u8) = @splat(tombstoneMarker);
                var presents: u64 = @as(u32, @bitCast((gdsts == allTombstones)));
                bigloop: while (true) : (presents &= presents - 1) {
                    const slotInBucket = @ctz(presents);
                    if (slotInBucket >= 32) {
                        break;
                    }

                    // double check that this slot is still "unplaced"
                    if (dsts[offset + slotInBucket] != tombstoneMarker) {
                        continue;
                    }

                    const kv = &arr[offset + slotInBucket];
                    dsts[offset + slotInBucket] = 0; // WE ARE LEAVING.

                    kvloop: while (true) {
                        var hash = self.ctx.hash(kv.key);
                        var hf: usize = 1;
                        while (hf <= 3) {
                            const hashslot = rotl(u64, hash, (hf >> 1) * 32);
                            var slot = hashreduce(hashslot, size);
                            var dst: u64 = (hf << 6) | (0 << 0);
                            var fingerprint: u64 = hashslot & 0b1111_1111;
                            var evicted = false;
                            while (true) {
                                const elemdst: u64 = dsts[slot];
                                const elemfp: u64 = fps[slot];
                                if (elemdst < dst or elemdst == tombstoneMarker) {
                                    dsts[slot] = @intCast(dst);
                                    fps[slot] = @intCast(fingerprint);
                                    if (slot < 32) { // update the trailing repeat byte
                                        dsts[size + slot] = @intCast(dst);
                                        fps[size + slot] = @intCast(fingerprint);
                                    }

                                    const entry = &arr[slot];
                                    std.mem.swap(Kv, kv, entry);

                                    evicted = true;
                                    fingerprint = elemfp;
                                    dst = elemdst;
                                    if (elemdst == 0) {
                                        // the slot was empty
                                        continue :bigloop;
                                    }
                                    if (elemdst == tombstoneMarker) {
                                        // The slot had an "unplaced" entry that we now evicted.
                                        // Now that entry is stored in kv and we need
                                        // to find a slot for it.
                                        continue :kvloop;
                                    }
                                }

                                dst += 1 << 0;

                                // Did the above "+=" overflow the dst bits? If so then we are at distance of == 31.
                                // This is somehow the fastest way to check (dst == 31) even if less obvious.
                                if ((dst >> 5) & 0b1 == 0b1) {
                                    dst -= 1 << 0;
                                    break;
                                }

                                slot = slotwrap(slot + 1, size);
                            }

                            hf = dst >> 6;
                            hf += 2;
                            if (evicted) {
                                hash = self.ctx.hash(kv.key);
                            }
                        }
                        unreachable; // ??? impossibru !!!
                    }
                }
            }

            self.tombstones = 0;
            return;
        }

        fn grow(self: *Self) !void {
            if (self.size == 0) {
                const dstsandfps = try self.allocator.alloc(u8, (32 + 32) * 2);
                errdefer self.allocator.free(dstsandfps);
                @memset(dstsandfps, 0);

                const arr = try self.allocator.alloc(Kv, 32);
                errdefer self.allocator.free(arr);

                self.dsts = dstsandfps[0 .. dstsandfps.len / 2].ptr;
                self.fps = dstsandfps[dstsandfps.len / 2 ..].ptr;
                self.arr = arr.ptr;
                self.size = 32;
                self.growAt = @max(1, (32 * growAtPercentage) / 100);
                return;
            }

            const oldSize = self.size;
            const newSize = oldSize * 2;

            const dstsandfps = try self.allocator.alloc(u8, (newSize + 32) * 2);
            errdefer self.allocator.free(dstsandfps);
            @memset(dstsandfps, 0);
            const dsts = dstsandfps[0 .. dstsandfps.len / 2];
            const fps = dstsandfps[dstsandfps.len / 2 ..];

            const arr = try self.allocator.alloc(Kv, newSize);
            errdefer self.allocator.free(arr);

            // Mark the trailing repeat bytes of old dsts as empties so the below loop
            // doesn't accidentally process them
            @memset(self.dsts[oldSize..][0..32], 0);

            var offset: usize = 0;
            while (offset < oldSize) : (offset += 32) {
                const gdsts: @Vector(32, u8) = self.dsts[offset..][0..32].*;

                const allZeros: @Vector(32, u8) = @splat(0);
                const allTombstones: @Vector(32, u8) = @splat(tombstoneMarker);
                var presents: u64 = @as(u32, @bitCast(gdsts != allZeros)) & @as(u32, @bitCast(gdsts != allTombstones));
                bigloop: while (true) : (presents &= presents - 1) {
                    const slotInBucket = @ctz(presents);
                    if (slotInBucket >= 32) {
                        break;
                    }

                    const kv = &self.arr[offset + slotInBucket];

                    var hash = self.ctx.hash(kv.key);
                    var hf: usize = 1;
                    while (hf <= 3) {
                        const hashslot = rotl(u64, hash, (hf >> 1) * 32);
                        var slot = hashreduce(hashslot, newSize);
                        var dst: u64 = (hf << 6) | (0 << 0);
                        var fingerprint: u64 = hashslot & 0b1111_1111;
                        var evicted = false;
                        while (true) {
                            const elemdst: u64 = dsts[slot];
                            const elemfp: u64 = fps[slot];
                            if (elemdst <= dst) {
                                dsts[slot] = @intCast(dst);
                                fps[slot] = @intCast(fingerprint);
                                if (slot < 32) { // update the trailing repeat byte
                                    dsts[newSize + slot] = @intCast(dst);
                                    fps[newSize + slot] = @intCast(fingerprint);
                                }

                                const entry = &arr[slot];
                                std.mem.swap(Kv, kv, entry);

                                evicted = true;

                                fingerprint = elemfp;
                                dst = elemdst;
                                if (elemdst == 0) {
                                    // the slot was empty
                                    continue :bigloop;
                                }
                            }

                            dst += 1 << 0;

                            // Did the above "+=" overflow the dst bits? If so then we are at distance of == 31.
                            // This is somehow the fastest way to check (dst == 31) even if less obvious.
                            if ((dst >> 5) & 0b1 == 0b1) {
                                dst -= 1 << 0;
                                break;
                            }

                            slot = slotwrap(slot + 1, newSize);
                        }

                        hf = dst >> 6;
                        hf += 2;
                        if (evicted) {
                            hash = self.ctx.hash(kv.key);
                        }
                    }
                    unreachable; // ??? impossibru !!!
                }
            }

            self.allocator.free(self.dsts[0 .. (oldSize + 32) * 2]);
            self.allocator.free(self.arr[0..oldSize]);

            self.dsts = dsts.ptr;
            self.fps = fps.ptr;
            self.arr = arr.ptr;
            self.size = newSize;
            self.growAt = @max(1, (newSize * growAtPercentage) / 100);
            self.tombstones = 0;
            return;
        }

        pub fn allWhenFull(self: *Self, comptime iter: fn (k: K, v: V) bool) void {
            if (growAtPercentage != 100) {
                @compileError("allWhenFull requires that 100% growAtPercentage");
            }
            std.debug.assert(self.len == self.size);
            for (self.arr[0..self.size]) |*kv| {
                const ok = iter(kv.key, kv.value);
                if (!ok) {
                    return;
                }
            }
        }

        pub fn all(self: *Self, comptime iter: fn (k: K, v: V) bool) void {
            // NOTE: If self.len == self.size and self.tombstones == 0 then we can just
            // brrrrt through the array as if it was an array.
            var offset: usize = 0;
            while (offset < self.size) : (offset += 32) {
                const gdsts: @Vector(32, u8) = self.dsts[offset..][0..32].*;

                const allZeros: @Vector(32, u8) = @splat(0);
                const allTombstones: @Vector(32, u8) = @splat(tombstoneMarker);
                var presents: u64 = @as(u32, @bitCast(gdsts != allZeros)) & @as(u32, @bitCast(gdsts != allTombstones));
                while (true) : (presents &= presents - 1) {
                    const slotInBucket = @ctz(presents);
                    if (slotInBucket >= 32) {
                        break;
                    }

                    const slot = offset + slotInBucket;
                    if (slot >= self.size) { // did we hit the trailing bytes when (self.size%32) != 0?
                        break;
                    }

                    const kv = &self.arr[slot];
                    const ok = iter(kv.key, kv.value);
                    if (!ok) {
                        return;
                    }
                }
            }
        }

        pub fn dump(self: *Self) void {
            var offset: usize = 0;
            var hfnuses: [3]usize = @splat(0);
            var maxes: [3]usize = @splat(0);
            while (offset < self.size) : (offset += 32) {
                const gdsts: @Vector(32, u8) = self.dsts[offset..][0..32].*;

                const allZeros: @Vector(32, u8) = @splat(0);
                const allTombstones: @Vector(32, u8) = @splat(tombstoneMarker);
                var presents: u64 = @as(u32, @bitCast(gdsts != allZeros)) & @as(u32, @bitCast(gdsts != allTombstones));
                while (true) : (presents &= presents - 1) {
                    const slotInBucket = @ctz(presents);
                    if (slotInBucket >= 32) {
                        break;
                    }

                    const slot = offset + slotInBucket;
                    if (slot >= self.size) { // did we hit the trailing bytes when (self.size%32) != 0?
                        break;
                    }

                    const elemdst = self.dsts[slot];
                    const hfn = (elemdst >> 6) - 1;
                    const dst = (elemdst & 0b11111);

                    hfnuses[hfn] += 1;
                    maxes[hfn] = @max(maxes[hfn], dst);
                }
            }

            std.debug.print("len={} size={}\n", .{ self.len, self.size });
            for (0.., hfnuses, maxes) |i, uses, max| {
                std.debug.print("[hf{}] {} {}\n", .{ i, uses, max });
            }
        }
    };
}

// Experiment with minimal metadata per entry with dynamically increasing probe length.
pub fn MapDynamicProbeLength(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
) type {
    return struct {
        const Self = @This();

        const Kv = struct {
            key: K,
            value: V,
        };

        // the 1 bit of metadata per entry. NOTE: If we fill the hash table all the way
        // up to 100% load factor then we can free this array as we know that
        // all slots have an entry present there. Truly 0-bits of metadata per entry.
        presents: [*]bool = undefined,
        arr: [*]Kv = undefined,
        size: usize = 0,
        len: usize = 0,
        probeLength: usize = 0,

        allocator: std.mem.Allocator,
        ctx: Context = undefined, // TODO: How should the ctx work?

        inline fn hashreduce(hash: u64, size: u64) u64 {
            return @truncate(std.math.mulWide(u64, hash, size) >> 64);
        }

        inline fn slotwrap(slot: u64, size: u64, probeLength: u64) u64 {
            if (slot >= size) {
                @branchHint(.unlikely);
                std.debug.assert(slot - size < probeLength);
                return slot - size;
            }
            return slot;
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn initWithSize(allocator: std.mem.Allocator, size: usize) !Self {
            const presents = try allocator.alloc(bool, size);
            @memset(presents, false);
            const arr = try allocator.alloc(Kv, size);
            const probeLength: usize = (64 - @clz(size)) + 2;
            return .{
                .presents = presents.ptr,
                .arr = arr.ptr,
                .allocator = allocator,
                .size = size,
                .probeLength = @min(size, probeLength),
            };
        }

        pub fn deinit(self: Self) void {
            if (self.size > 0) {
                self.allocator.free(self.arr[0..self.size]);
                self.allocator.free(self.presents[0..self.size]);
            }
        }

        pub fn get(self: *Self, k: K) ?V {
            if (self.size == 0) {
                return null;
            }

            const hash = self.ctx.hash(k);

            const presents = self.presents;
            const arr = self.arr;

            var hashslot = hash;
            for (0..2) |_| {
                // TODO: What would an actually smart probing strategy be? Consider
                // what .dump teaches us about the distribution...
                var slot = hashreduce(hashslot, self.size);
                for (0..self.probeLength) |_| {
                    if (!presents[slot]) { // if len==size this check is needless
                        return null; // the entry would have been here were it to be in this map
                    }
                    const entry = &arr[slot];
                    if (self.ctx.eql(k, entry.key)) {
                        return entry.value;
                    }
                    slot = slotwrap(slot + 1, self.size, self.probeLength);
                }

                hashslot = rotl(u64, hashslot, 32);
            }
            return null;
        }

        fn hfanddst(self: Self, arr: [*]Kv, currentSlot: usize, size: usize, probeLength: usize) struct { u64, u64 } {
            // Because we don't store the hashfn that was used we just try both and see which
            // one matches well enough. Maybe we could look at the surrounding entries as well
            // to figure out which hf matches better.
            const hash = self.ctx.hash(arr[currentSlot].key);
            var hfnum: usize = 1; // try the last hashfn first.
            while (true) {
                const slot = hashreduce(rotl(u64, hash, hfnum * 32), size);
                const virtualSlot = if (currentSlot < slot and currentSlot < probeLength) currentSlot + size else currentSlot;
                const distance = virtualSlot -% slot;
                if (distance < probeLength) {
                    return .{ hfnum, distance };
                }

                if (hfnum == 0) {
                    break;
                }
                hfnum -= 1;
            }
            unreachable;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.size == 0) {
                try self.grow();
            }

            var k = key;
            var v = value;

            var presents = self.presents;
            var arr = self.arr;

            var checkeq = true; // can we skip the equality check?

            var hash = self.ctx.hash(k);

            var hashslot = hash;
            var hfnum: u64 = 0;
            while (true) {
                var slot = hashreduce(hashslot, self.size);
                var dst: u64 = 0;
                var evicted = false;
                while (true) {
                    const entry = &arr[slot];
                    if (!presents[slot]) {
                        // the slot is empty. The key is not yet in the map.
                        presents[slot] = true;
                        std.mem.swap(K, &k, &entry.key);
                        std.mem.swap(V, &v, &entry.value);
                        self.len += 1;
                        return;
                    }

                    const entryhf, const entrydst = self.hfanddst(arr, slot, self.size, self.probeLength);

                    // key eq
                    if (checkeq and entryhf == hfnum and entrydst == dst and self.ctx.eql(k, arr[slot].key)) {
                        arr[slot].value = v;
                        return;
                    }

                    // swap?
                    // NOTE: Normal RH hashing would just do `if (entrydst < dst) {` but that is a big mistake if you want 100% load!
                    if (entryhf < hfnum or (entryhf == hfnum and entrydst < dst)) {
                        std.mem.swap(K, &k, &entry.key);
                        std.mem.swap(V, &v, &entry.value);
                        hfnum = entryhf;
                        dst = entrydst;
                        checkeq = false;
                        evicted = true;

                        // Useless to find empty slot?
                        if (self.len == self.size) {
                            break;
                        }
                    }

                    // Too far for this hashfn?
                    if (dst == self.probeLength - 1) {
                        break;
                    }

                    dst += 1;
                    slot = slotwrap(slot + 1, self.size, self.probeLength);
                }

                if (evicted) {
                    // We have some victim that we evicted.
                    hash = self.ctx.hash(k); // TODO: This is kind of sad. Maybe we should just hash the preferred slot idx + fingerprint for hf2?
                }

                // TODO: Do we really want to go for ~99.999% load factor? Maybe we should
                // just grow earlier...
                if (checkeq or self.len < self.size) {
                    if (hfnum < 1) {
                        hfnum += 1;
                        hashslot = rotl(u64, hash, hfnum * 32);
                        continue;
                    }

                    checkeq = false; // we now know that the key is not in the map
                }

                // TODO: If len < size we could rehash with +1 probe length or using different
                // hash function.

                // std.debug.print("grow: {} {}\n", .{ self.len, self.size });

                try self.grow();

                arr = self.arr;
                presents = self.presents;
                hfnum = 0;
                hashslot = hash;
            }
        }

        fn grow(self: *Self) !void {
            @branchHint(.cold);
            if (self.size == 0) {
                const presents = try self.allocator.alloc(bool, 32);
                @memset(presents, false);
                const arr = try self.allocator.alloc(Kv, 32);
                self.presents = presents.ptr;
                self.arr = arr.ptr;
                self.size = 32;
                self.probeLength = 5 + 2;
                return;
            }

            const oldSize = self.size;
            const newSize = oldSize * 2;
            const newProbeLength = self.probeLength + 1;

            const presents = try self.allocator.alloc(bool, newSize);
            @memset(presents, false);
            const arr = try self.allocator.alloc(Kv, newSize);

            for (0..self.size) |idx| {
                if (!self.presents[idx]) {
                    continue;
                }

                const kv = &self.arr[idx];

                var hash = self.ctx.hash(kv.key);

                var hashslot = hash;
                var hfnum: u64 = 0;
                insertloop: while (true) {
                    var slot = hashreduce(hashslot, newSize);
                    var dst: u64 = 0;
                    var evicted = false;
                    while (true) {
                        const entry = &arr[slot];
                        if (!presents[slot]) {
                            // the slot is empty. The key is not yet in the map.
                            presents[slot] = true;
                            std.mem.swap(Kv, kv, entry);
                            break :insertloop;
                        }

                        const entryhf, const entrydst = self.hfanddst(arr.ptr, slot, newSize, newProbeLength);

                        // swap?
                        // NOTE: Normal RH hashing would just do `if (entrydst < dst) {` but that is a big mistake if you want 100% load!
                        if (entryhf < hfnum or (entryhf == hfnum and entrydst < dst)) {
                            std.mem.swap(Kv, kv, entry);
                            hfnum = entryhf;
                            dst = entrydst;
                            evicted = true;
                        }

                        // Too far for this hashfn?
                        if (dst == newProbeLength - 1) {
                            break;
                        }

                        dst += 1;
                        slot = slotwrap(slot + 1, newSize, newProbeLength);
                    }

                    if (evicted) {
                        // We have some victim that we evicted.
                        hash = self.ctx.hash(kv.key); // TODO: This is kind of sad. Maybe we should just hash the preferred slot idx + fingerprint for hf2?
                    }
                    if (hfnum < 1) {
                        hfnum += 1;
                        hashslot = rotl(u64, hash, hfnum * 32);
                        continue;
                    }

                    unreachable;
                }
            }

            self.allocator.free(self.presents[0..oldSize]);
            self.allocator.free(self.arr[0..oldSize]);

            self.presents = presents.ptr;
            self.arr = arr.ptr;
            self.size = newSize;
            self.probeLength = newProbeLength;
            return;
        }

        pub fn all(self: *Self, comptime iter: fn (k: K, v: V) bool) void {
            for (0..self.size) |slot| {
                if (!self.presents[slot]) {
                    continue;
                }
                const kv = &self.arr[slot];
                const ok = iter(kv.key, kv.value);
                if (!ok) {
                    return;
                }
            }
        }

        pub fn dump(self: *Self) void {
            var hfnuses: [2]usize = @splat(0);
            var maxes: [2]usize = @splat(0);
            var hfndists: [2][64]usize = @splat(@splat(0));
            for (0..self.size) |slot| {
                if (!self.presents[slot]) {
                    continue;
                }

                const hfn, const dst = self.hfanddst(self.arr, slot, self.size, self.probeLength);

                hfnuses[hfn] += 1;
                maxes[hfn] = @max(maxes[hfn], dst);
                hfndists[hfn][dst] += 1;
            }

            std.debug.print("len={} size={} probel={}\n", .{ self.len, self.size, self.probeLength });
            for (0.., hfnuses, maxes) |i, uses, max| {
                std.debug.print("[hf{}] {} {}\n", .{ i, uses, max });
            }
            std.debug.print("\n", .{});
            for (0.., hfndists) |hfnum, dists| {
                for (0.., dists[0 .. maxes[hfnum] + 1]) |dsti, dst| {
                    std.debug.print("[hf{}] {d:2} {}\n", .{ hfnum, dsti, dst });
                }
            }
        }
    };
}

// Arena allocator friendly hash map with incremental growth.
pub fn Promenade(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        const Bucket = struct {
            // NOTE: Design assumes that 'size(K)+size(V)==16B' for optimality.

            // fingerprints. BUT [15] stores the bucket depth.
            fingerprints: @Vector(16, u8),
            keys: [16 - 1]K,
            values: [16 - 1]V,
        };

        const hasher = getAutoHashFn(K, u0);

        bucket0: ?*Bucket = null,
        arr: [*]*Bucket = undefined, // defined only when "shift < 64"
        shift: usize = 64,

        len: usize = 0,

        allocator: std.mem.Allocator,
        // rng_state: u64 = 0,

        inline fn calchash(_: Self, k: K) u64 {
            return hasher(0, k);
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: Self) void {
            if (self.bucket0) |bucket| {
                self.allocator.destroy(bucket);
            }
            if (self.shift < 64) {
                const globalDepth = 64 - self.shift;
                const size = @as(usize, 1) << @intCast(globalDepth);
                const trie = self.arr[0..size];

                var i: usize = 0;
                while (i < trie.len) {
                    const bucket = trie[i];
                    i += @as(usize, 1) << @intCast(globalDepth - @as(usize, bucket.fingerprints[15]));
                    self.allocator.destroy(bucket);
                }
                self.allocator.free(trie);
            }
        }

        fn ph2(hash: u64, rot: anytype) u64 {
            return rotl(u64, hash, rot);
        }

        fn fixfp(hash: u64) u64 {
            if (hash & 0b1111_1111 == 0) {
                @branchHint(.unpredictable);
                return hash | 1;
            }
            return hash;
        }

        pub fn get(self: *Self, k: K) ?V {
            const hash = self.calchash(k);

            const bucket0, const bucket1 = blk: {
                if (self.shift < 64) {
                    const bucket0 = self.arr[hash >> @intCast(self.shift)];
                    const bucket1 = self.arr[ph2(hash, 32) >> @intCast(self.shift)];
                    break :blk .{ bucket0, bucket1 };
                } else {
                    const bucket0 = self.bucket0 orelse return null;
                    break :blk .{ bucket0, bucket0 };
                }
            };

            const fingerprint = fixfp(hash);
            const probe: @Vector(16, u8) = @splat(@truncate(fingerprint));

            // NOTE: Cast to u64 for better codegen
            var matches0: u64 = @as(u16, @bitCast(bucket0.fingerprints == probe));
            while (true) : (matches0 &= matches0 - 1) {
                const slotInBucket = @ctz(matches0);
                if (slotInBucket >= 16 - 1) {
                    break;
                }
                if (bucket0.keys[slotInBucket] == k) {
                    return bucket0.values[slotInBucket];
                }
            }

            // NOTE: Cast to u64 for better codegen
            var matches1: u64 = @as(u16, @bitCast(bucket1.fingerprints == probe));
            while (true) : (matches1 &= matches1 - 1) {
                const slotInBucket = @ctz(matches1);
                if (slotInBucket >= 16 - 1) {
                    break;
                }
                if (bucket1.keys[slotInBucket] == k) {
                    return bucket1.values[slotInBucket];
                }
            }

            return null;
        }

        pub fn put(self: *Self, k: K, v: V) !void {
            var hash = self.calchash(k);

            var bucket0, var bucket1 = blk: {
                if (self.shift < 64) {
                    const bucket0 = self.arr[hash >> @intCast(self.shift)];
                    const bucket1 = self.arr[ph2(hash, 32) >> @intCast(self.shift)];
                    break :blk .{ bucket0, bucket1 };
                } else {
                    const bucket0 = self.bucket0 orelse blk2: {
                        const bucket = try self.allocator.create(Bucket);
                        bucket.fingerprints = @splat(0);
                        self.bucket0 = bucket;
                        break :blk2 bucket;
                    };
                    break :blk .{ bucket0, bucket0 };
                }
            };

            var fingerprint = fixfp(hash);
            const probe: @Vector(16, u8) = @splat(@truncate(fingerprint));

            // NOTE: Cast to u64 for better codegen
            var matches0: u64 = @as(u16, @bitCast(bucket0.fingerprints == probe));
            while (true) : (matches0 &= matches0 - 1) {
                const slotInBucket = @ctz(matches0);
                if (slotInBucket >= 16 - 1) {
                    break;
                }
                if (bucket0.keys[slotInBucket] == k) {
                    bucket0.values[slotInBucket] = v;
                    return;
                }
            }

            // NOTE: Cast to u64 for better codegen
            var matches1: u64 = @as(u16, @bitCast(bucket1.fingerprints == probe));
            while (true) : (matches1 &= matches1 - 1) {
                const slotInBucket = @ctz(matches1);
                if (slotInBucket >= 16 - 1) {
                    break;
                }
                if (bucket1.keys[slotInBucket] == k) {
                    bucket1.values[slotInBucket] = v;
                    return;
                }
            }

            // Totally new key. Insert it.

            self.len += 1;

            const maxHashrot = 20 * 2;
            const casualHashrot = 2 * 2;
            var hashrot: usize = 0; // hashrot helps us rotate between hf0 and hf1.

            var key = k;
            var value = v;

            inserts: while (true) {
                const allZeros: @Vector(16, u8) = @splat(0);
                const empties0: u64 = @as(u16, @bitCast(bucket0.fingerprints == allZeros));
                const empties1: u64 = @as(u16, @bitCast(bucket1.fingerprints == allZeros));

                // We want to insert to the bucket that is less full.
                var bucketToInsert = bucket0;
                var empties = empties0;
                if (@popCount(empties0) < @popCount(empties1)) {
                    @branchHint(.unpredictable);
                    bucketToInsert = bucket1;
                    empties = empties1;
                }

                const nextFree = @ctz(empties);
                if (nextFree < 16 - 1) {
                    @branchHint(.likely);
                    bucketToInsert.fingerprints[nextFree] = @truncate(fingerprint);
                    bucketToInsert.keys[nextFree] = key;
                    bucketToInsert.values[nextFree] = value;
                    return;
                }

                // Next we try to figure if we should try to grow in some way. Stealing a slot from some random
                // victim in the bucket is more of a last resort thing.

                // NOTE: There's really no need to monomorphize any of this. Especially
                // the trie growth code and bucket splitting code doesn't really
                // benefit from it much in performance and a static dispatch to a shared
                // impl would suffice just fine.

                // Special case for the single bucket mode
                if (self.shift >= 64) {
                    @branchHint(.cold);
                    // Create the trie as [b0, b0]
                    self.arr = (try self.allocator.dupe(*Bucket, &.{ bucket0, bucket0 })).ptr;
                    self.shift = 63;
                    self.bucket0 = null;
                }

                // NOTE: If we wanted to achieve really high load factor we can always just try a few
                // evicts before we try growing. Growing only if "hashrot >= 10" already has significant
                // impact on the load factor.
                while (true) {
                    if (self.shift >= 64) unreachable;

                    const globalDepth = 64 - self.shift;
                    const depth0 = bucket0.fingerprints[15];
                    const depth1 = bucket1.fingerprints[15];

                    const depth = if (depth0 < globalDepth) depth0 else depth1;
                    const bucketToSplit = if (depth == depth0) bucket0 else bucket1;
                    if (depth < globalDepth) {
                        const wantBit = @intFromBool(bucketToSplit == bucket1);
                        const rotatedHash = ph2(hash, 32 * (hashrot & 1));
                        const hashForSplit = ph2(rotatedHash, 32 * @as(u64, wantBit));

                        try self.splitAndStoreInTrie(bucketToSplit, depth, hashForSplit);

                        // Try current hash again
                        bucket0 = self.arr[rotatedHash >> @intCast(self.shift)];
                        bucket1 = self.arr[ph2(rotatedHash, 32) >> @intCast(self.shift)];

                        continue :inserts;
                    }

                    // Good enough load factor to grow the trie early?
                    // Or are we just full?
                    // Or too much hashrots
                    if ((self.len >= (@as(u64, 14) << @intCast(globalDepth)) and hashrot >= casualHashrot) or (self.len > (@as(u64, 15) << @intCast(globalDepth))) or (hashrot >= maxHashrot)) {
                        @branchHint(.cold);
                        try self.growTrie();
                        continue;
                    }

                    break;
                }

                // Steal a spot from a random victim

                //if (self.rng_state == 0) {
                //    self.rng_state = hash;
                //}
                //self.rng_state ^= self.rng_state >> 13;
                //self.rng_state ^= self.rng_state << 7;
                //self.rng_state ^= self.rng_state >> 17;

                //const victimi: u64 = @intCast(std.math.mulWide(u64, self.rng_state, (16-1))>>64);
                const victimi: u64 = @intCast(std.math.mulWide(u64, rotl(u64, hash, hashrot * 21), (16 - 1)) >> 64);

                bucketToInsert.fingerprints[victimi] = @truncate(fingerprint);
                std.mem.swap(K, &bucketToInsert.keys[victimi], &key);
                std.mem.swap(V, &bucketToInsert.values[victimi], &value);

                // Prepare next round of insert
                hash = self.calchash(key);
                fingerprint = fixfp(hash);

                hashrot += 1;

                const rotatedHash = ph2(hash, 32 * (hashrot & 1));
                bucket0 = self.arr[rotatedHash >> @intCast(self.shift)];
                bucket1 = self.arr[ph2(rotatedHash, 32) >> @intCast(self.shift)];
            }
        }

        fn splitAndStoreInTrie(self: *Self, bucket: *Bucket, depth: usize, hash: u64) !void {
            if (depth >= 62) unreachable;

            bucket.fingerprints[15] = @intCast(depth + 1);

            // Create copy of it
            const newBucket = try self.allocator.create(Bucket);
            newBucket.* = bucket.*; // bulk copy

            // Split. Marks the slot as free in the bucket where the key doesn't belong to.
            self.split(bucket, newBucket, hash);

            // Insert into the trie
            const shift = self.shift;
            const globalDepth = 64 - shift;
            const depthDiff = globalDepth - @as(usize, bucket.fingerprints[15] - 1);

            const oldCount = @as(usize, 1) << @intCast(depthDiff);
            const startPos = (hash >> @intCast(shift)) >> @intCast(depthDiff) << @intCast(depthDiff);

            // NOTE: oldCount/2 is usually 1. Pls compiler no bloat codegen...
            @memset(self.arr[startPos..][oldCount / 2 .. oldCount], newBucket);
        }

        fn growTrie(self: *Self) !void {
            if (self.shift >= 64) unreachable;
            if (self.shift == 0) unreachable;

            const globalDepth = 64 - self.shift;
            const oldSize = @as(usize, 1) << @intCast(globalDepth);
            const newSize = oldSize * 2;

            const oldTrie = self.arr[0..oldSize];
            const newTrie = try self.allocator.alloc(*Bucket, newSize);

            // have: [b0 b0 b1 b2]
            // want: [b0 b0 b0 b0 b1 b1 b2 b2]
            for (0..newSize) |i| {
                newTrie[i] = oldTrie[i >> 1];
            }

            self.allocator.free(oldTrie);

            self.arr = newTrie.ptr;
            self.shift -= 1;
        }

        fn split(self: *Self, left: *Bucket, right: *Bucket, forHash: u64) void {
            if (left.fingerprints[15] >= 64) unreachable;
            if (left.fingerprints[15] == 0) unreachable;
            if (std.simd.countElementsWithValue(left.fingerprints, 0) != 0) unreachable;

            const leftDepth = @as(u64, left.fingerprints[15]);
            const splitBit = @as(u64, 1) << @intCast(64 - leftDepth);
            const prefixMask: u64 = splitBit | (splitBit - 1);
            const keys = &left.keys;

            // For each entry figure out which bucket it should continue existing in
            for (keys, 0..15) |*key, slotInBucket| {
                var hash = self.calchash(key.*);
                const hash2 = ph2(hash, 32);

                // Figure out which of h1(hash) or h2(hash) was used to place
                // this key into this bucket. That hash function determines
                // if we go left or right. We do it by comparing the
                // trie indexing bits.
                if ((hash ^ forHash) > prefixMask) {
                    @branchHint(.unpredictable);
                    hash = hash2;
                }

                // NOTE: If we wish for a very high load we could try to move any entries using hf2
                // to their primary bucket to avoid having to split this current bucket. This works
                // surprisingly often.

                const goesRight = (hash & splitBit) == splitBit;
                if (goesRight) {
                    @branchHint(.unpredictable);
                    left.fingerprints[slotInBucket] = 0;
                } else {
                    @branchHint(.unpredictable);
                    right.fingerprints[slotInBucket] = 0;
                }
            }
        }

        pub fn all(self: *Self, comptime iter: fn (k: K, v: V) bool) void {
            const globalDepth = 64 - self.shift;
            const arr: []const *Bucket = blk: {
                if (self.shift < 64) {
                    break :blk self.arr[0..(@as(usize, 1) << @intCast(globalDepth))];
                } else {
                    const bucket0 = self.bucket0 orelse return;
                    break :blk &.{bucket0};
                }
            };

            var i: usize = 0;
            while (i < arr.len) {
                const bucket = arr[i];

                i += @as(usize, 1) << @intCast(globalDepth - @as(usize, bucket.fingerprints[15]));

                const allZeros: @Vector(16, u8) = @splat(0);
                var presents: u64 = @as(u16, @bitCast(bucket.fingerprints != allZeros));
                while (true) {
                    const slotInBucket = @ctz(presents);
                    if (slotInBucket >= 16 - 1) {
                        break;
                    }

                    const ok = iter(bucket.keys[slotInBucket], bucket.values[slotInBucket]);
                    if (!ok) {
                        return;
                    }
                    presents = presents & (presents - 1);
                }
            }
        }
    };
}

const maptype = Map32(u64, u64, std.hash_map.AutoContext(u64), 100);

test "simple map test" {
    var map = maptype.init(std.testing.allocator);
    defer map.deinit();

    for (0..100000) |i| {
        try map.put(@as(u64, i), @as(u64, i));
        try std.testing.expectEqual(@as(u64, i + 1), map.len);
        try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
    }
    for (0..100000) |i| {
        try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
    }
    // false lookups
    for (100000..200000) |i| {
        try std.testing.expectEqual(null, map.get(@as(u64, i)));
    }
    // updates
    for (0..100000) |i| {
        try map.put(@as(u64, i), @as(u64, i + 1111111111111));
        try map.put(@as(u64, i + 33333333), @as(u64, i));
    }
    for (0..100000) |i| {
        try std.testing.expectEqual(@as(u64, i + 1111111111111), map.get(@as(u64, i)));
        try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i + 33333333)));
    }

    // deletes
    for (0..100000) |i| {
        try std.testing.expectEqual(true, map.remove(@as(u64, i)));
        try std.testing.expectEqual(null, map.get(@as(u64, i)));
    }
    for (0..100000) |i| {
        try std.testing.expectEqual(null, map.get(@as(u64, i)));
    }
    for (0..200000) |i| { // rehash?
        try map.put(@as(u64, i), @as(u64, i));
        try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
    }
    for (0..200000) |i| {
        try std.testing.expectEqual(true, map.remove(@as(u64, i)));
    }
    for (0..200000) |i| {
        try map.put(@as(u64, i), @as(u64, i));
        try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
        try std.testing.expectEqual(true, map.remove(@as(u64, i)));
    }
    for (0..300000) |i| {
        try map.put(@as(u64, i), @as(u64, i));
        try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
        try std.testing.expectEqual(true, map.remove(@as(u64, i)));
    }
    for (0..200000) |i| {
        try std.testing.expectEqual(null, map.get(@as(u64, i)));
    }
}

test "iter map" {
    for (0..100) |iter| {
        const size = iter * 10;
        var map = maptype.init(std.testing.allocator);
        defer map.deinit();

        for (0..size) |i| {
            try map.put(@as(u64, i), @as(u64, i));
        }

        const fs = struct {
            fn f(_: u64, _: u64) bool {
                return true;
            }
        };

        map.all(fs.f);
    }
}

test "full map at any size" {
    for (69..2000) |size| {
        var map = try Map32(u64, u64, std.hash_map.AutoContext(u64), 100).initWithSize(std.testing.allocator, size);
        defer map.deinit();

        for (0..size) |i| {
            try map.put(@as(u64, i), @as(u64, i));
        }
        for (0..size) |i| {
            try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
        }
        try std.testing.expectEqual(map.len, size);
        try std.testing.expectEqual(map.size, size);
    }
}

test "full map at rand size" {
    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var rng = std.Random.DefaultPrng.init(seed);
    var random = rng.random();
    const targetSize = random.intRangeAtMost(usize, 1 << 17, 1 << 19);

    var map = try Map32(u64, u64, std.hash_map.AutoContext(u64), 99).initWithSize(std.testing.allocator, targetSize);
    defer map.deinit();

    for (0..targetSize) |i| {
        try map.put(@as(u64, i), @as(u64, i));
    }

    // map.dump();
}

test "random operations" {
    for (0..10) |_| {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        var rng = std.Random.DefaultPrng.init(seed);
        var random = rng.random();
        const initSize = random.intRangeAtMost(usize, 1 << 6, 1 << 9);

        var map = try maptype.initWithSize(std.testing.allocator, initSize);
        defer map.deinit();

        var reference = std.AutoHashMap(u64, u64).init(std.testing.allocator);
        defer reference.deinit();

        for (0..100 * 1000) |_| {
            const k = random.intRangeAtMost(u64, 0, 1 << 18);
            try std.testing.expectEqual(reference.get(k), map.get(k));

            // do the op
            switch (random.intRangeAtMost(u1, 0, 1)) {
                0 => {
                    try map.put(k, k);
                    try reference.put(k, k);
                    try std.testing.expectEqual(reference.count(), map.len);
                },
                1 => {
                    const mok = map.remove(k);
                    const rok = reference.remove(k);
                    try std.testing.expectEqual(rok, mok);
                    try std.testing.expectEqual(reference.count(), map.len);
                },
            }

            try std.testing.expectEqual(reference.get(k), map.get(k));
        }
    }
}

test "repeated delete re-insertion" {
    for (0..10) |_| {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        var rng = std.Random.DefaultPrng.init(seed);
        var random = rng.random();
        const targetSize = random.intRangeAtMost(usize, 1 << 14, 1 << 17);

        var map = try maptype.initWithSize(std.testing.allocator, targetSize);
        defer map.deinit();

        for (0..targetSize) |k| {
            try map.put(k, k);
        }
        try std.testing.expectEqual(targetSize, map.len);

        // spam delete/reinsert in random order
        for (0..targetSize / 100) |_| {
            const k = random.intRangeLessThan(usize, 0, targetSize);
            for (0..100) |_| {
                try std.testing.expectEqual(true, map.remove(k));
                try map.put(k, k);
            }
        }

        if (map.size > targetSize * 2) { // Don't allow more than 1 growth
            try std.testing.expectEqual(false, true);
        }
        try std.testing.expectEqual(targetSize, map.len);
    }
}

test "repeated delete re-insertion 2" {
    for (0..10) |_| {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        var rng = std.Random.DefaultPrng.init(seed);
        var random = rng.random();
        const targetSize = random.intRangeAtMost(usize, 1 << 11, 1 << 14);

        var map = try maptype.initWithSize(std.testing.allocator, targetSize);
        defer map.deinit();

        for (0..targetSize) |k| {
            try map.put(k, k);
        }
        try std.testing.expectEqual(targetSize, map.len);

        // spam delete/reinsert
        for (0..20) |_| {
            for (0..targetSize) |k| {
                try std.testing.expectEqual(true, map.remove(k));
            }
            for (0..targetSize) |k| {
                try map.put(k, k);
            }
        }

        if (map.size > targetSize * 2) { // Don't allow more than 1 growth
            try std.testing.expectEqual(false, true);
        }
        try std.testing.expectEqual(targetSize, map.len);
    }
}

// test "tardmap" {
//     const size = 126179;

//     var map = try MapDynamicProbeLength(u64, u64, std.hash_map.AutoContext(u64)).initWithSize(std.testing.allocator, size);
//     defer map.deinit();

//     for (0..size) |i| {
//         try map.put(@as(u64, i), @as(u64, i));
//     }
//     for (0..size) |i| {
//         try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
//     }
//     try std.testing.expectEqual(map.len, size);
//     try std.testing.expectEqual(map.size, size);
// }

// test "tardmap2" {
//     const initSize = 1;
//     const targetSize = 1 << 17;
//     var map = try MapDynamicProbeLength(u64, u64, std.hash_map.AutoContext(u64)).initWithSize(std.testing.allocator, initSize);
//     defer map.deinit();

//     var seed: u64 = undefined;
//     try std.posix.getrandom(std.mem.asBytes(&seed));
//     var rng = std.Random.DefaultPrng.init(seed);
//     var origRng = rng; // copy for later
//     var random = rng.random();
//     var ops: usize = 0;
//     while (map.len < targetSize) {
//         const i = random.int(usize);
//         try map.put(@as(u64, i), @as(u64, i));
//         try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
//         ops += 1;

//         // did we achieve 100% load?
//         // if (@popCount(map.len) == 1) {
//         //     try std.testing.expectEqual(map.len, map.size);
//         // }
//     }

//     random = origRng.random();
//     for (0..ops) |_| {
//         const i = random.int(usize);
//         try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
//     }
//     try std.testing.expectEqual(map.len, targetSize);
//     try std.testing.expectEqual(map.size, targetSize);

//     // map.dump();
// }

// test "full tardmap at any size" {
//     for (1..2000) |size| {
//         var map = try MapDynamicProbeLength(u64, u64, std.hash_map.AutoContext(u64)).initWithSize(std.testing.allocator, size);
//         defer map.deinit();

//         for (0..size) |i| {
//             try map.put(@as(u64, i), @as(u64, i));
//         }
//         for (0..size) |i| {
//             try std.testing.expectEqual(@as(u64, i), map.get(@as(u64, i)));
//         }
//         try std.testing.expectEqual(map.len, size);
//         try std.testing.expectEqual(map.size, size);
//     }
// }
