//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");

const hashmap = @import("hashmap.zig");
const maptype = hashmap.Map32(u64, u64, std.hash_map.AutoContext(u64), 80);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Memory leak has occurred!\n");
    };

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    // warmup for 0.5s
    var s = try std.time.Instant.now();
    while (true) {
        for (0..10000000) |i| {
            std.mem.doNotOptimizeAway(i);
        }
        const d = (try std.time.Instant.now()).since(s);
        if (d >= 500 * 1000 * 1000) {
            break;
        }
    }

    s = try std.time.Instant.now();
    var ops: usize = 0;
    if (false) {
        // try to find hashtable that grows beyond the expected size (we never find one)
        var seed: u64 = 0;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        var rng = std.Random.DefaultPrng.init(seed);
        var random = rng.random();
        for (0..1 * 10000) |attempt| {
            _ = arena.reset(.retain_capacity);

            const startSize = random.intRangeAtMost(usize, 1 << 8, 1 << 14);
            const targetSize = startSize * 8;
            if (attempt % 64 == 0) {
                std.debug.print("attempt #{} with starting size:{}\n", .{ attempt, startSize });
            }

            var origRng = rng; // copy the rng state for later

            var map = try hashmap.Map32(u64, u0, std.hash_map.AutoContext(u64), 100).initWithSize(allocator, startSize);
            defer map.deinit();
            var numPuts: usize = 0;
            while (map.len < targetSize) {
                try map.put(random.int(u64), 0);
                numPuts += 1;
                ops += 1;
            }
            if (map.size != targetSize) {
                std.debug.print("{} {}\n", .{ map.size, targetSize });
                @panic("bad");
            }

            // check that all are reachable
            var random2 = origRng.random();
            for (0..numPuts) |_| {
                if (map.get(random2.int(u64)) == null) {
                    std.debug.print("{} {}\n", .{ map.size, targetSize });
                    @panic("oops");
                }
            }
        }
    } else if (true) {
        // insert benchmark
        for (0..10 * 1000) |_| {
            _ = arena.reset(.retain_capacity);

            var map = maptype.init(allocator);
            var rng = std.Random.DefaultPrng.init(1);
            for (0..10 * 1000) |_| {
                const k = rng.next();
                std.mem.doNotOptimizeAway(try map.put(k, k));
                ops += 1;
            }
        }
    } else if (false) {
        // insert strings benchmark
        const stringmap = hashmap.Map32([]const u8, u64, std.hash_map.StringContext, 80);
        //const stringmap = std.StringHashMap(u64);

        for (0..1 * 10) |_| {
            _ = arena.reset(.retain_capacity);

            var map = stringmap.init(allocator);
            var rng = std.Random.DefaultPrng.init(1);
            for (0..1 * 1000 * 1000) |k| {
                const k0 = rng.next();
                const k1 = rng.next();
                var strk = try allocator.create([16]u8);
                std.mem.writeInt(u64, strk[0..8], k0, .little);
                std.mem.writeInt(u64, strk[8..16], k1, .little);
                std.mem.doNotOptimizeAway(try map.put(strk[0 .. 8 + (k1 & 0b111)], k));
                ops += 1;
            }
        }
    } else if (false) {
        // lookup strings benchmark
        const stringmap = hashmap.Map32([]const u8, u64, std.hash_map.StringContext, 80);
        //const stringmap = std.StringHashMap(u64);
        _ = arena.reset(.retain_capacity);

        var map = stringmap.init(allocator);

        var rng = std.Random.DefaultPrng.init(1);
        const rngcpy = rng;
        for (0..1 * 1000 * 1000) |k| {
            const k0 = rng.next();
            const k1 = rng.next();
            var strk = try allocator.create([16]u8);
            std.mem.writeInt(u64, strk[0..8], k0, .little);
            std.mem.writeInt(u64, strk[8..16], k1, .little);
            std.mem.doNotOptimizeAway(try map.put(strk[0 .. 8 + (k1 & 0b111)], k));
        }

        s = try std.time.Instant.now();
        for (0..1 * 10) |_| {
            var rngcpy2 = rngcpy;
            for (0..1 * 1000 * 1000) |k| {
                const k0 = rngcpy2.next();
                const k1 = rngcpy2.next();
                var strk = try allocator.create([16]u8);
                std.mem.writeInt(u64, strk[0..8], k0, .little);
                std.mem.writeInt(u64, strk[8..16], k1, .little);
                if (map.get(strk[0 .. 8 + (k1 & 0b111)]) != k) {
                    @panic("bad");
                }
                ops += 1;
            }
        }
    } else if (false) {
        // sized insert to 2^32 benchmark
        const Ctx = struct {
            pub fn hash(_: anytype, k: u32) u64 {
                return @as(u64, @intCast(k)) *% 11400714819323198487;
            }
            pub fn eql(_: anytype, k0: u32, k1: u32) bool {
                return k0 == k1;
            }
        };

        var map = try hashmap.Map32(u32, void, Ctx, 100).initWithSize(allocator, 1 << 32);
        for (0..map.size) |k| {
            try map.put(@intCast(k), undefined);
        }
        // 1500 seconds later...
        map.dump();
        ops += map.len;
    } else if (false) {
        // sized insert benchmark
        for (0..1 * 1000) |_| {
            _ = arena.reset(.retain_capacity);

            var map = try maptype.initForLen(allocator, 100 * 1000);
            // var map = std.AutoHashMap(u64, u64).init(allocator);
            // try map.ensureTotalCapacity(100 * 1000);

            var rng = std.Random.DefaultPrng.init(1);
            for (0..100 * 1000) |_| {
                const k = rng.next();
                std.mem.doNotOptimizeAway(try map.put(k, k));
                ops += 1;
            }
        }
    } else if (false) {
        // update benchmark
        var map = maptype.init(allocator);
        {
            var rng = std.Random.DefaultPrng.init(1);
            for (0..10 * 1000) |_| {
                const k = rng.next();
                try map.put(k, k);
            }
        }

        s = try std.time.Instant.now();
        for (0..10 * 1000) |j| {
            var rng = std.Random.DefaultPrng.init(1);
            for (0..10 * 1000) |_| {
                const k = rng.next();
                try map.put(k, k + j);
                ops += 1;
            }
        }
    } else if (false) {
        // update by delete/put benchmark
        var map = maptype.init(allocator);
        {
            var rng = std.Random.DefaultPrng.init(1);
            for (0..5 * 1000) |_| {
                const k = rng.next();
                try map.put(k, k);
            }
        }

        s = try std.time.Instant.now();
        for (0..10 * 1000) |j| {
            var rng = std.Random.DefaultPrng.init(1);
            for (0..5 * 1000) |_| {
                const k = rng.next();
                _ = map.remove(k);
                try map.put(k, k + j);
                ops += 1;
            }
        }
    } else if (false) {
        // rehash benchmark
        const targetLen = 1 * 1000 * 1000;
        var refmap = try maptype.initForLen(gpa.allocator(), targetLen);
        defer refmap.deinit();

        {
            for (0..targetLen) |k| {
                try refmap.put(k, k);
            }
            for (0..targetLen / 2) |k| {
                _ = refmap.remove(k);
            }
        }

        s = try std.time.Instant.now();
        for (0..100) |_| {
            _ = arena.reset(.retain_capacity);

            var map = try refmap.clone(allocator);
            map.rehash();
            ops += map.size;
        }
    } else if (false) {
        // negative lookups benchmark
        var map = try maptype.initForLen(allocator, 10 * 1000);
        {
            for (0..10 * 1000) |k| {
                try map.put(k, k);
            }
        }

        s = try std.time.Instant.now();
        for (0..1000) |_| {
            for (0..10 * 1000) |k| {
                std.mem.doNotOptimizeAway(map.get(map.len + k));
                ops += 1;
            }
        }
    } else {
        // positive lookups benchmark
        var map = try maptype.initForLen(allocator, 2031);
        //var map = std.hash_map.HashMap(u64, u64, Ctx, 80).init(allocator);
        //try map.ensureTotalCapacity(2031);
        {
            var rng = std.Random.DefaultPrng.init(1);
            for (0..2031) |_| {
                const k = rng.next();
                try map.put(k, k);
            }
        }

        s = try std.time.Instant.now();
        for (0..100 * 1000) |_| {
            var rng = std.Random.DefaultPrng.init(1);
            for (0..2031) |_| {
                const k = rng.next();
                std.mem.doNotOptimizeAway(map.get(k));
                ops += 1;
            }
        }
    }

    const d = (try std.time.Instant.now()).since(s);

    const nse0: f64 = @floatFromInt(d);
    const nse1: f64 = @floatFromInt(ops);

    std.debug.print("time: {}ns\n", .{d});
    std.debug.print("time: {d:.3}ns/elem\n", .{nse0 / nse1});
    std.debug.print("time: {}ms\n", .{d / (1000 * 1000)});

    std.debug.print("allocated: {d:0.3}KB\n", .{@as(f64, @floatFromInt(arena.queryCapacity())) / 1024});
    std.debug.print("allocated: {d:0.3}MB\n", .{@as(f64, @floatFromInt(arena.queryCapacity())) / (1024 * 1024)});
}
