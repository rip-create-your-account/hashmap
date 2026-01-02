# Robin Hood hashing for modern audiences

👨 35 min read — 🦲 55 min read — 👶 7 min read — ⛄ 613 min melting in the 🌞

Have you ever tried filling your open-addressing hash table of `N` slots all the way up to 100% load factor? Not a single empty slot in sight! Did it accidentally take `O(N * N)` time? Well, with Robin Hood hashing and random probing it would have taken just `O(N log N)` time with high probability. The Greats figured this out already in the 80s. Today we will first empirically validate their claim and then we explore how to make it more than just theoretically interesting.

For the various forms of Robin Hood hashing the unifying idea is to track each entry's `distance` from its ideal slot in the table. The ideal slot is determined by a hash function and a probe sequence algorithm provides us additional slots to try if needed. During insertion we go through the slots as suggested by the probe sequence, trying to find slots where its current `distance` is less than the current probing distance. When we find such a slot we can steal it and the insertion continues with the evicted entry, or stops if the slot was empty.

The reader may be familiar with the linear probe sequence where you just try `ideal_slot+1`, and then `ideal_slot+2` and so on. But today we are focusing on the random probe sequence, where every slot we try is determined by a hash function and thus effectively random.

## A humble beginning

First we need a hash function that combines the key and the current probing `distance`. For 64-bit integer keys we can do the following.

```cpp
hash(key: u64, distance: u64) u64 {
    return hash_u64(key ^ hash_u64(distance));
}
hash_u64(value: u64) u64 { 
    return value * 11400714819323198485;
}
```

Now we can start constructing the hash table. We can keep track of the `distance` for each entry in a `[]u64` array.

```rust
type HashTable {
    distances: []u64, // distance of 0 indicates an empty slot
    entries: []Kv,
    size: u64,
    len: u64,
}
```

And let's then implement the random probing insertion algorithm.

```c++
fn put(table: *HashTable, key: K, value: V) {
    if (table.size == 0) {
        table.grow();
    }

    var distance = 1; // by starting the distance from 1 we can reserve 0 to mark the empty slots
    var slot = hash(key, distance) % table.size;
    while (true) {
        // The key could be in this slot. If it's in this slot then its distance will match too.
        if (table.distances[slot] == distance and table.entries[slot].key == key) {
            table.entries[slot].value = value;
            return;
        }
        
        // Is the stored entry at a smaller distance? Then we can steal its slot for the current key.
        // Also it could be an empty slot since they have distance of 0.
        if (table.distances[slot] < distance) {
            // We now know that 'key' is not currently in the table. We are not updating some existing key to a new value. So check if the target load factor has been reached.
            if (table.len == table.size) { // 100% is our goal
                table.grow();

                distance = 1;
                slot = hash(key, distance) % table.size;
                continue;
            }

            // swap places with the entry currently stored at the slot
            swap(&table.distances[slot], &distance);
            swap(&table.entries[slot].key, &key);
            swap(&table.entries[slot].value, &value);

            // If the evicted distance was 0, we've filled an empty slot.
            if (distance == 0) {
                table.len += 1;
                return;
            }
            
            // Now we find a slot for the evicted entry.
        }

        // Continue to the next slot

        distance += 1;

        // Our next slot is NOT (slot + 1). That would be linear probing.
        // Instead we want a random slot. The magic with random is that
        // if two keys shared the same ideal slot then they are very likely
        // to jump to different locations here. This does wonders to clustering.
        slot = hash(key, distance) % table.size;
    }
}
```

Now, let's try it. We will initialize some hash tables with various sizes such that we can insert 2<sup>16</sup> entries into each of them. The Greats promise us that `distance` for all insertions will remain under `log(N)` with high probability even for the hash table that targets `100%` load factor, so we will keep our eyes on that.

**IMPORTANT NOTE**: In the implementation the `distance`s start counting up from 1 but in all visualizations they will be reported as if they started from 0.

| Entries | Size | Total time | max(distance) |
| --- | --- | --- | --- |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.80 | ~2.0ms | 4 |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.90 | ~2.5ms | 5 |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.99 | ~4.9ms | 7 |
| 2<sup>16</sup> | 2<sup>16</sup> / 1.00 | ~10ms | 14 |

That's pretty good! For the `100%` load factor table the greatest `distance` was just 14! That is less than log2(2<sup>16</sup>) just as promised by the Greats! Also, I find the total time difference between `99%` and `100%` funny - just 1% of extra empty space halves the total time! More on that later.

Anyways, maintaining the `distance` in a `u64` now seems unnecessary. Let's change it to `u8`. If we make assumptions based on our result we can postulate that `u8` is enough to handle tables of size 2<sup>255</sup>.

```diff
-distances: []u64,
+distances: []u8,
```

### Improving the random probing

Each of those probes jumping into some random location in memory also means lots of potential for CPU data-cache misses. It would be extremely painful to get a cache-miss for all 1+14 random probes. So let's try to reduce the number of random jumps by trying more than 1 slot in each random location. How about a linear window of 16 (sixteen) slots per random probe location?

```diff
fn put(table: *HashTable, key: K, value: V) {
    // ...
    while (true) {
        // ...

        // Continue to the next slot

        distance += 1;

+       // NOTE: here, distance % 16 = [2, 3, 4, 5, .., 14, 15, 0, 1].
+       if (distance % 16 != 1) {
+           slot = (slot + 1) % table.size;
+           continue;
+       }

        slot = hash(key, distance) % table.size;
    }
}
```

Does increasing the linearly probed window from 1 to 16 slots work? Let's focus just on the higher load factors this time as only they tend to have long probe distances. How many random probes do we need now?

| Entries | Size | `Window size` | Total time | max(distance) | `max(random probes)`
| --- | --- | --- | --- | --- | --- |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.99 | 1 | ~4.9ms | 7 | 8 |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.99 | 16 | ~3.7ms | 17 | 2 |
| 2<sup>16</sup> | 2<sup>16</sup> / 1.00 | 1 | ~10ms | 14 | 15 |
| 2<sup>16</sup> | 2<sup>16</sup> / 1.00 | 16 | ~7.5ms | 31 | 2 |

It worked better than expected. Just 2 random probes is enough now even for the table targeting `100%` load. The initial window and the second window. But the largest recorded `distance` does go from 14 to 31 as a result of this change. So to do a lookup for the unluckiest entry we now need to check 1+31 slots in total. But! We would likely only get ~2 cache-misses during the lookup since there's only two small linear windows of memory to go through. This is so good that I think we can consider the **problem solved**. Now we just need to make sure it's fast. This change already reduced the total time significantly but more on that later.

So, if for the table targeting `100%` load factor the largest recorded `distance` was 31, then where are the other entries at? It's time to find out what various `distances` our entries are placed in. This one I will plot into an image.

![Image displaying distribution of distances for different load factors.](https://github.com/user-attachments/assets/b51b65ff-725a-43e9-9042-30a13d1b94cc)

Huh, neat. Remember that there's a window boundary between `distances` 15 and 16. I would like to note that for the blue `80%` load factor table almost all of the 2<sup>16</sup> entries are placed into their first 16-slot window. In fact, there's just 21 entries that slipped into the 2nd window.

But now I really want to see how the placement of entries evolves as the insertion process progresses.

https://github.com/user-attachments/assets/0ffca259-bb89-471e-a924-c5354bd2b80b

Woah! Just look at the `100%` table! Watch how the very last ~10 inserts cause thousands of entries to move to different distances! The whole thing just shifts massively. That's disgusting wtf. That's a lot of moves happening for so little gain. All was good up to 99.999% load and then BAM! This explains why the insertion time for `100%` is 2x of `99%`'s. Well, it is what it is. *Or is it?* More on that later.

## Lookups

The lookups spark joy. The big optimization here is that if during probing we find an entry whose `distance` is less than our current probing distance, we can stop. The key that we are looking for can't be in the table for it would have stolen that slot for itself!

```js
fn get(table: *HashTable, key: K) V {
    if (table.len == 0) {
        return null;
    }

    var distance = 1;
    var slot = hash(key, distance) % table.size;
    while (true) {
        if (table.distances[slot] == distance and table.entries[slot].key == key) {
            return table.entries[slot].value;
        }
        
        // Is the currently stored entry at a smaller distance? If 'key' were to be in the table it would have stolen this slot for itself.
        // Also it could be an empty slot since they have distance of 0.
        if (table.distances[slot] < distance) {
            return null;
        }

        // continue to the next slot
            
        distance += 1;

        // NOTE: here, distance % 16 = [2, 3, 4, 5, .., 14, 15, 0, 1].
        if (distance % 16 != 1) {
            slot = (slot + 1) % table.size;
            continue;
        }
                
        slot = hash(key, distance) % table.size;
    }
}
```

Let's now measure the total time of looking up 2<sup>16</sup> keys. We first look up all the keys that have been inserted (Hits) and then 2<sup>16</sup> keys that don't exist (Misses). And let's put it up against a basic linear probing hash table.

| Entries | Size | All Hits | All Misses | `vs` | All hits | All Misses |
| --- | --- | --- | --- | --- | --- | --- |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.50 | ~0.7ms | ~0.6ms | | ~0.5ms | ~0.9ms |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.80 | ~1.2ms | ~0.9ms | | ~0.8ms | ~1.6ms |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.90 | ~1.4ms | ~1.0ms | | ~1.3ms | ~3.3ms |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.99 | ~1.9ms | ~1.3ms | | ~3.9ms | ~156.2ms |
| 2<sup>16</sup> | 2<sup>16</sup> / 1.00 | ~3.2ms | ~2.2ms | | ~6.4ms | ~2706ms |

Which one is the basic linear probing one? Can you guess? Which one has to probe through the whole table for lookup misses at 100% load factor?

Anyways, for lookups the performance even at `99%` is perfectly practical for both hits and misses now. That's ~30 nanoseconds for the average lookup at `99%` load factor. Nothing too impressive but still pretty good considering the simplicity. Next we will make it impressive.

## SIMD

### Lookups with SIMD

It was no coincidence that I suggested using 16-slot windows and `distances: []u8`. I had SIMD in mind all along! We can use SIMD to match the whole window of `distances` in one go! But let's not distract ourselves with the implementation details and let's instead see how it holds up when it comes to lookups.

| Entries | Size | All Hits | All Misses
| --- | --- | --- | --- |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.50 | ~0.5ms | ~0.3ms |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.80 | ~0.5ms | ~0.3ms |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.90 | ~0.4ms | ~0.2ms |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.99 | ~0.4ms | ~0.3ms |
| 2<sup>16</sup> | 2<sup>16</sup> / 1.00 | ~0.7ms | ~0.6ms |

Woah! That's ~10 nanoseconds[^cpu] for the average lookup at `100%` load factor!!! Also for high load factors SIMD gets us ~4x the lookups. Notice that higher load factors are also slightly faster than lower load factors - and no surprise since there's fewer empty slots taking space in the limited CPU data-cache. And [later](#specializing-for-integer-keys) we will go even further beyond.

[^cpu]: The CPU, Intel i7-4790, with L2 cache of 256KB.

### Insertions with SIMD

Insertions benefit from SIMD just as much as the lookups do. The major optimization is that thanks to SIMD we can actually defer doing the Robin Hood work. We can usually just insert into the first empty slot we see without having to shift entries around. Only when there's no empty slots inside our 16-slot window then do we need to shuffle those entries to make space.

You see, the lookup doesn't really care about how the entries are organized inside the 16-slot window. The lookup will go through all of the matching entries anyways. So during insertion we can place our entry anywhere inside that window and the lookup will find it just according to keikaku[^TNOTE]. The practical consequence is that if our target max load factor is something reasonable like `80%`, then most parts of the table will never get to the point where they need to do any of the Robin Hood work.

[^TNOTE]: Keikaku means "plan".

Let's now re-do the earlier insertion tests but with SIMD.

| Entries | Size | Total time | avg ns/insert
| --- | --- | --- | --- |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.50 | ~0.93ms | ~14.3ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.80 | ~1.08ms | ~16.5ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.90 | ~1.58ms | ~24.2ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.99 | ~3.60ms | ~54.9ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 1.00 | ~6.10ms | ~89.9ns |

The SIMD algorithm also has a large impact on how the placement of entries evolves during the insertion. For the `80%` load factor table now ~50% of entries remain in their ideal slot! Look at this!

https://github.com/user-attachments/assets/320afcb2-52cd-4441-abd5-a233221b992b

Uh... Do you see how the number of entries at distance 0 for `90%` shrinks from 30000 down to 20000? That's 10000 entries being evicted and moved to further distances. That massive amount of moves disgusts me. What if we just tried to initially place entries as close as possible to the location where they usually end up at, which is at the end of the 16-slot window?[^FASTSCALAR]

```diff
fn put(table: *HashTable, key: K, value: V) {
    // ...
+   var distance = 1 + (16 - 1); // We start from the "end" of the window.
    var slot = hash(key, distance) % table.size;
    while (true) {
        // check slot, evict, etc...

        // continue to the next slot

+       distance -= 1; // distance now decreases inside the window.
        
        // NOTE: here, distance % 16 = [15, 14, 13, 12, .., 3, 2, 1, 0].
        if (distance % 16 != 0) {
            slot = (slot + 1) % table.size;
            continue;
        }

        slot = hash(key, distance) % table.size;
+       distance += 2 * 16; // jump to the end of the next window
    }
}
```

[^FASTSCALAR]: This same optimization when done without SIMD provides equally impressive results. In fact, it makes the scalar version sometimes be faster than the SIMD version. Look at the [specializing for integer keys](#specializing-for-integer-keys) for an example of that.

https://github.com/user-attachments/assets/1b7d09ad-ea5e-4f9c-8fa2-aa2167fe5904

Oh, wow! I had concepts of a plan but I wasn't planning for that! Look at how little movement there's for `90%` load factor now! But it seems that for `100%` load factor now some entries are being placed into the third window now. Eh, not my problem.

What does our naive performance evaluation tell us now?

| Entries | Size | Total time | avg ns/insert
| --- | --- | --- | --- |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.50 | ~0.84ms | ~12.8ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.80 | ~0.82ms | ~12.6ns[^cpu] |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.90 | ~0.95ms | ~14.1ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.99 | ~1.41ms | ~21.5ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 1.00 | ~2.73ms | ~41.7ns |

Much better for higher load factors! That's a 2x improvement for the 100% case! But let's also try using 32-slot windows and 256-bit SIMD now.

| Entries | Size | Total time | avg ns/insert
| --- | --- | --- | --- |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.50 | ~0.85ms | ~13.0ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.80 | ~0.80ms | ~12.3ns[^cpu] |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.90 | ~0.87ms | ~13.4ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.99 | ~1.31ms | ~20.0ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 1.00 | ~1.96ms | ~30.0ns |

Insertion times even at extremely high load factors are pretty fast now. And lookups are just as fast, perhaps faster, with 32-slot windows. Our work here is done. **Problem solved.**

And below is how the insertion evolves over time with 32-slot windows.

https://github.com/user-attachments/assets/a2dd4aab-aa73-4b1c-870a-3efb683ee3e0

Notice how for `80%` load factor ~85% of entries are located in distances [31, 30, 29, 28]. This is now almost a dynamic perfect hash table! Does the lookup even need to use SIMD now? I don't know. _[Or do I?](#specializing-for-integer-keys)_

Then back to the overly simple performance evaluation. What if we hint to the insertion that the keys are unique and that there's enough reserved space?

| Entries | Size | Total time | avg ns/insert
| --- | --- | --- | --- |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.50 | ~0.66ms | ~10.1ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.80 | ~0.63ms | ~9.6ns[^cpu] |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.90 | ~0.71ms | ~10.9ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 0.99 | ~1.13ms | ~17.3ns |
| 2<sup>16</sup> | 2<sup>16</sup> / 1.00 | ~1.73ms | ~26.5ns |

And what about a smaller number of entries so that the whole thing actually fits into my L2 data-cache? L3 can be so very slow for random access you know.

| Entries | Size | Total time | avg ns/insert
| --- | --- | --- | --- |
| 2<sup>12</sup> | 2<sup>12</sup> / 0.50 | ~0.023ms | ~5.7ns |
| 2<sup>12</sup> | 2<sup>12</sup> / 0.80 | ~0.024ms | ~5.9ns |
| 2<sup>12</sup> | 2<sup>12</sup> / 0.90 | ~0.027ms | ~6.8ns |
| 2<sup>12</sup> | 2<sup>12</sup> / 0.99 | ~0.048ms | ~11.9ns |
| 2<sup>12</sup> | 2<sup>12</sup> / 1.00 | ~0.084ms | ~20.6ns |

And what if I actually used the hash function that I showed in the very beginning?

| Entries | Size | Total time | avg ns/insert
| --- | --- | --- | --- |
| 2<sup>12</sup> | 2<sup>12</sup> / 0.50 | ~0.021ms | ~5.2ns |
| 2<sup>12</sup> | 2<sup>12</sup> / 0.80 | ~0.021ms | ~5.2ns |
| 2<sup>12</sup> | 2<sup>12</sup> / 0.90 | ~0.021ms | ~5.2ns |
| 2<sup>12</sup> | 2<sup>12</sup> / 0.99 | ~0.021ms | ~5.2ns |
| 2<sup>12</sup> | 2<sup>12</sup> / 1.00 | ~0.028ms | ~6.9ns |

Yeah... What it does to the `100%` case is just nasty. That's why I have actually been secretly using a "real" hash function to get the other results. This hash function gives misleadingly good results, but it works just fine, so uh...

Anyways, I love these visualizations so much, so here's one more where we insert 2<sup>27</sup> entries.

https://github.com/user-attachments/assets/3ae3245a-8381-4f49-bc67-71db6564ffc9

I do wonder if for `100%` target load factor the inserts should always just start from the 2nd window, then work backwards to the 1st window and only then go to the 3rd window.

## Specializing for integer keys

We can go even further by specializing. Are our keys integers and never 0? Check out [this implementation](https://zig.godbolt.org/z/aqxdqPY6f). I designed it with extremely fast lookups in mind since my optimizing compiler does lots and lots of lookups with 32-bit non-zero integer keys.

Let's try it with 32-bit keys and values.

| Entries | Size | lookup hit | lookup miss | insert
| --- | --- | --- | --- | --- |
| 2<sup>12</sup> * 0.50 | 2<sup>12</sup> | ~0.50ns | ~2.50ns | ~2.65ns |
| 2<sup>12</sup> * 0.80 | 2<sup>12</sup> | ~0.56ns | ~2.50ns | ~2.54ns |
| 2<sup>12</sup> * 0.90 | 2<sup>12</sup> | ~0.59ns | ~2.51ns | ~2.56ns |
| 2<sup>12</sup> * 0.99 | 2<sup>12</sup> | ~0.79ns | ~3.93ns | ~3.48ns |
| 2<sup>12</sup> * 1.00 | 2<sup>12</sup> | ~1.77ns | ~3.96ns | ~7.41ns |

Huh. I guess this is what I get for microbenchmarking. I did check the generated code to make sure that the compiler isn't cheating. It's even loading the entry's value from memory into a register! Remembering to load the value in from memory is the one thing that many hash table benchmarks f up, but not here. The compiler didn't even unroll the benchmark loop. It's just the CPU[^cpu] who is cheating here. Consider that for `90%` the lookups are taking ~2.38 cycles per lookup running at ~4.0 instructions per cycle. That's just incredible, but that's what microbenchmarks do. Thougheverbeit for lookups it's expected since ~90% of entries are either in their ideal slot or right next to it. It's almost a dynamic perfect hash table and with that in mind the lookup performance does make sense.

## Deletes

There's multiple approaches here depending on your situation. You can do as [this implementation](https://zig.godbolt.org/z/aqxdqPY6f) does, keep track of the highest distance ever inserted to and make the lookups always probe up to that point. This means no need for tombstones. Somewhat surprisingly this approach doesn't seem to have [issues like this](https://github.com/ziglang/zig/issues/17851). No rehashing needed even after a complicated series of inserts/deletes!

<details>
<summary>Here's me flexing on that issue while staying at ~95% load factor. Not a single rehash necessary.</summary>
<code>3000000 block took 203 ms. 2000000/2097152 largestdst = 9  
4000000 block took 240 ms. 2000000/2097152 largestdst = 9
5000000 block took 282 ms. 2000000/2097152 largestdst = 17
6000000 block took 319 ms. 2000000/2097152 largestdst = 17
7000000 block took 330 ms. 2000000/2097152 largestdst = 17
8000000 block took 334 ms. 2000000/2097152 largestdst = 17
9000000 block took 336 ms. 2000000/2097152 largestdst = 17
10000000 block took 340 ms. 2000000/2097152 largestdst = 17
11000000 block took 339 ms. 2000000/2097152 largestdst = 17
12000000 block took 342 ms. 2000000/2097152 largestdst = 17
13000000 block took 338 ms. 2000000/2097152 largestdst = 17
14000000 block took 342 ms. 2000000/2097152 largestdst = 25
15000000 block took 347 ms. 2000000/2097152 largestdst = 25
16000000 block took 348 ms. 2000000/2097152 largestdst = 25
17000000 block took 346 ms. 2000000/2097152 largestdst = 25
18000000 block took 347 ms. 2000000/2097152 largestdst = 25
19000000 block took 345 ms. 2000000/2097152 largestdst = 25
20000000 block took 348 ms. 2000000/2097152 largestdst = 25
21000000 block took 351 ms. 2000000/2097152 largestdst = 25
22000000 block took 349 ms. 2000000/2097152 largestdst = 25
23000000 block took 349 ms. 2000000/2097152 largestdst = 25
24000000 block took 352 ms. 2000000/2097152 largestdst = 25
25000000 block took 353 ms. 2000000/2097152 largestdst = 25
26000000 block took 345 ms. 2000000/2097152 largestdst = 25
27000000 block took 351 ms. 2000000/2097152 largestdst = 25
28000000 block took 353 ms. 2000000/2097152 largestdst = 25
29000000 block took 349 ms. 2000000/2097152 largestdst = 25
30000000 block took 351 ms. 2000000/2097152 largestdst = 25
31000000 block took 352 ms. 2000000/2097152 largestdst = 25
32000000 block took 347 ms. 2000000/2097152 largestdst = 25
33000000 block took 352 ms. 2000000/2097152 largestdst = 25
34000000 block took 344 ms. 2000000/2097152 largestdst = 25
35000000 block took 350 ms. 2000000/2097152 largestdst = 25
36000000 block took 358 ms. 2000000/2097152 largestdst = 25
37000000 block took 346 ms. 2000000/2097152 largestdst = 25
38000000 block took 347 ms. 2000000/2097152 largestdst = 25
39000000 block took 348 ms. 2000000/2097152 largestdst = 25
40000000 block took 346 ms. 2000000/2097152 largestdst = 25
41000000 block took 346 ms. 2000000/2097152 largestdst = 25
42000000 block took 347 ms. 2000000/2097152 largestdst = 25
43000000 block took 347 ms. 2000000/2097152 largestdst = 25
44000000 block took 351 ms. 2000000/2097152 largestdst = 25
45000000 block took 351 ms. 2000000/2097152 largestdst = 25
46000000 block took 350 ms. 2000000/2097152 largestdst = 25
47000000 block took 351 ms. 2000000/2097152 largestdst = 25
48000000 block took 351 ms. 2000000/2097152 largestdst = 25
49000000 block took 350 ms. 2000000/2097152 largestdst = 25
50000000 block took 351 ms. 2000000/2097152 largestdst = 25
51000000 block took 350 ms. 2000000/2097152 largestdst = 25
52000000 block took 350 ms. 2000000/2097152 largestdst = 25
53000000 block took 350 ms. 2000000/2097152 largestdst = 25
54000000 block took 350 ms. 2000000/2097152 largestdst = 25
55000000 block took 348 ms. 2000000/2097152 largestdst = 25
56000000 block took 350 ms. 2000000/2097152 largestdst = 25
57000000 block took 348 ms. 2000000/2097152 largestdst = 25
58000000 block took 344 ms. 2000000/2097152 largestdst = 25
59000000 block took 345 ms. 2000000/2097152 largestdst = 25
60000000 block took 348 ms. 2000000/2097152 largestdst = 25
61000000 block took 348 ms. 2000000/2097152 largestdst = 25
62000000 block took 345 ms. 2000000/2097152 largestdst = 25
63000000 block took 343 ms. 2000000/2097152 largestdst = 25
64000000 block took 349 ms. 2000000/2097152 largestdst = 25
65000000 block took 348 ms. 2000000/2097152 largestdst = 25
66000000 block took 346 ms. 2000000/2097152 largestdst = 25
67000000 block took 346 ms. 2000000/2097152 largestdst = 25
68000000 block took 345 ms. 2000000/2097152 largestdst = 25
69000000 block took 347 ms. 2000000/2097152 largestdst = 25
70000000 block took 350 ms. 2000000/2097152 largestdst = 25
71000000 block took 347 ms. 2000000/2097152 largestdst = 25
72000000 block took 345 ms. 2000000/2097152 largestdst = 25
73000000 block took 345 ms. 2000000/2097152 largestdst = 25
74000000 block took 350 ms. 2000000/2097152 largestdst = 25
75000000 block took 349 ms. 2000000/2097152 largestdst = 25
76000000 block took 345 ms. 2000000/2097152 largestdst = 25
77000000 block took 348 ms. 2000000/2097152 largestdst = 25
78000000 block took 343 ms. 2000000/2097152 largestdst = 25
79000000 block took 351 ms. 2000000/2097152 largestdst = 25
80000000 block took 349 ms. 2000000/2097152 largestdst = 25
81000000 block took 348 ms. 2000000/2097152 largestdst = 25
82000000 block took 349 ms. 2000000/2097152 largestdst = 25
83000000 block took 343 ms. 2000000/2097152 largestdst = 25
84000000 block took 346 ms. 2000000/2097152 largestdst = 25
85000000 block took 349 ms. 2000000/2097152 largestdst = 25
86000000 block took 350 ms. 2000000/2097152 largestdst = 25
87000000 block took 349 ms. 2000000/2097152 largestdst = 25
88000000 block took 349 ms. 2000000/2097152 largestdst = 25
89000000 block took 344 ms. 2000000/2097152 largestdst = 25
90000000 block took 347 ms. 2000000/2097152 largestdst = 25
91000000 block took 343 ms. 2000000/2097152 largestdst = 25
92000000 block took 349 ms. 2000000/2097152 largestdst = 25
93000000 block took 350 ms. 2000000/2097152 largestdst = 25
94000000 block took 349 ms. 2000000/2097152 largestdst = 25
95000000 block took 347 ms. 2000000/2097152 largestdst = 25
96000000 block took 348 ms. 2000000/2097152 largestdst = 25
97000000 block took 349 ms. 2000000/2097152 largestdst = 25
98000000 block took 347 ms. 2000000/2097152 largestdst = 25
99000000 block took 351 ms. 2000000/2097152 largestdst = 25
100000000 block took 346 ms. 2000000/2097152 largestdst = 25</code>
</details>

The second simple approach is to reserve a `distance` of 255 for tombstones and use it to mark deleted slots. This will allow you to stop lookups on empty slots. Then as the tombstones accumulate you do the occasional rehash. You can then also try to figure out if the deleted slot can instead be marked as empty which happens surprisingly often at reasonable load factors.

### Rehashing with SIMD

The nice thing about rehashing is that we can skip over entries that already are in their 1st window. This can make rehashing extremely fast because for most of our entries we need to just inspect the `distance`, no need to touch the key at all. Very SIMD friendly too.

## The number of evictions/moves during insertion

Robin Hood hash tables can end up spending lots of time evicting/moving/shifting entries around. So how much of it is happening here? The answer seems to greatly depend on the hash function of choice and on the size of the linear window. The below table shows the number of evictions relative to the number of inserted entries for [this](https://zig.godbolt.org/z/aqxdqPY6f) implementation. I did change the hash function to the Wyhash hasher since it has a more modest performance.

Table with the total number of evictions divided by the total number of insertions.

| Entries | Size | Width 4 | Width 8 | Width 16 | Width 32
| --- | --- | --- | --- | --- | --- |
| 2<sup>12</sup> * 0.90 | 2<sup>12</sup> | 0.230 | 0.129 | 0.056 | 0.023 |
| 2<sup>12</sup> * 0.99 | 2<sup>12</sup> | 0.753 | 0.414 | 0.253 | 0.157 |
| 2<sup>12</sup> * 1.00 | 2<sup>12</sup> | 1.849 | 0.869 | 0.714 | 0.406 |
| 2<sup>16</sup> * 0.90 | 2<sup>16</sup> | 0.221 | 0.115 | 0.051 | 0.021 |
| 2<sup>16</sup> * 0.99 | 2<sup>16</sup> | 0.729 | 0.441 | 0.270 | 0.163 |
| 2<sup>16</sup> * 1.00 | 2<sup>16</sup> | 2.709 | 1.354 | 0.840 | 0.494 |
| 2<sup>24</sup> * 0.90 | 2<sup>24</sup> | 0.217 | 0.116 | 0.053 | 0.021 |
| 2<sup>24</sup> * 0.99 | 2<sup>24</sup> | 0.724 | 0.437 | 0.271 | 0.164 |
| 2<sup>24</sup> * 1.00 | 2<sup>24</sup> | 3.749 | 2.068 | 1.283 | 0.670 |

This tells us that if you limit yourself to load factors less than 90% you will not be doing many moves at all. And notice that when the window width is greater than `log2(N)` we end up doing less than 1 moves per insert even when filling up to 100% load factor. This implies implications.

But things could be further improved in this respect. Currently that implementation first tries to take an empty slot but if there's none then it tries to evict the __first__ entry with a lesser `distance`. But it's actually better to always to pick the __smallest__ of the lessers in the window. And you can use the legendary `phminposuw` instruction for it! Sadly it seems to be slightly slower, but it does seem to reduce evictions further by ~20%. It might be faster in practice if the key and value are large structs and "unnecessary" evictions have a real cost to them.

```js
extern fn @"llvm.x86.sse41.phminposuw"(v: @Vector(8, u16)) @Vector(8, u16);

const minpos = @"llvm.x86.sse41.phminposuw"(table.distances[slot..][0..8]);
const min = minpos[0]; // smallest dst value
const pos = minpos[1]; // its index in the vector
```

## Conclusion

Robin Hood hashing with random probing has been neglected for decades. But today we added linearly probed windows to it. Then we reversed the order of `distance` inside the linearly probed windows. The lookups now test such a small number of slots that they are in a practical sense `worst-case O(1)` even at 100% load. And for insertions me, myself and I conjencture that we still maintain that original `O(N log N)` promise for filling the table to 100% load. And since this technique is still at its core just a form of Robin Hood hashing we can enjoy many of its familiar auxiliary properties if we so wish.

[This implementation](https://zig.godbolt.org/z/aqxdqPY6f) works as a great starting point on how to implement this hash table with a specific situation in mind. It includes all of the important lessons learned here and some implementation tricks. Alternatively, [here's](https://zig.godbolt.org/z/Eh39xaMoW) a general-purpose implementation to take inspiration from.

## Bonus content

### History-independence

Consider changing the insertion algorithm as follows:

```diff
-if (table.distances[slot] < distance) {
+if (table.distances[slot] < distance or (table.distances[slot] == distance and key < table.entries[slot].key)) {
   // steal...
}
```

That is, we handle `distance` ties by also comparing the keys. This change ends up guaranteeing that the memory representation of the table is independent of the order we insert our entries! This is called history-independence. So if you want to know if two tables contain exactly the same entries just run `memequal(table0.entries, table1.entries)`. Lookups can take advantage of the key ordering too!

### Deduplicating an array without allocating

Consider a scenario where you have an array of entries that you wish to deduplicate. You can use this hash table to do an in-place deduplication that directly operates on that given array with the help of separately allocated `distances`. Basically just a slightly modified rehash and then a final pass through to pack tightly if there was duplicates. For your average open-addressing hash table the concern would be that when there's 0 duplicates the performance would degrade to `O(N * N)` but as we have today learned we can do better than that.

Is it a good idea? Unlikely. Is it going to be fast? If you have a good % of duplicates. Will it work? Yes.

### Succinct hash table

By trying to avoid excessively high load factors we find ourselves in a situation where 3 bits is enough to store the `distance` for each entry. That's fertile ground for succinct hash tables. So table of size 2<sup>16</sup> storing 32-bit keys can actually store them as (16+3)-bit integers, and table of 2<sup>24</sup> entries stores them as (8+3)-bit integers. Making each window be smaller than the one before did wonders here. Imagine a window size progression of 4 -> 2 -> 1 -> 1.

### Filters / Approximate membership query

By modifying your succinct hash table to throw away some of the quotient bits you can use it as a pretty good resizable filter. How nice.

### Using two probe sequences

What if instead of having just one probe sequence per key we had two? And what if during insertion we used the power of two choices to our advantage? So inspect the 32-slot windows of both sequences and insert into the one that is emptier. Below is what behavior that produces.

https://github.com/user-attachments/assets/84f8b4af-3a5c-46ff-8bd6-237aef517cb4

Kind of interesting result. For `80%` load factor with one probe sequence we got ~40000 entries at `distance` 31 but with two we get ~51000. Similar things are happening for `90%` and `99%`. Most importantly it significantly reduced the number of entries in the 2nd window for load factors less than `100%`.

But doing it with window size of just 1 produces some crazy results.

https://github.com/user-attachments/assets/0997b0ed-0e3f-43da-a865-5836301b9e52

That's 2<sup>27</sup> entries at various hash table sizes. For the one configured for `99%` load factor there's just 2*4 slots that we would need to inspect for 99.999% of lookups. Consider that log2(log2(2<sup>27</sup>)) ~= 4.75. Coincidence? I think not.

### Fingerprints

For each entry take 8-bits of the hash to use as a fingerprint. We will be storing it in a single 16-bit value together with the `distance` of that entry. This will help us reduce branch misses and unnecessary key equality tests during lookup. This is especially relevant for the SIMD implementation to really iron out all branch-misses from it. But, for the SIMD variant you may find it better to maintain the fingerprint in a separate array.

```diff
type HashTable {
-   distances: []u8,
+   distancesAndFingerprints: []u16, // distance is the most significant 8-bits
    // ...
}
```

Now we get to implement the insertion and lookup with minimal changes. Below is what the changes to the lookup could look like. Can you count the number of added instructions for your implementation?

```diff
fn get(table: *HashTable, key: K) V {
    if (table.len == 0) {
        return null;
    }

+   var distance = (1 << 8) | (hash(key) >> (64 - 8)); // combined distance and fingerprint
    var slot = hash(key, distance) % table.size;
    while (true) {
+       if (table.distancesAndFingerprints[slot] == distance and table.entries[slot].key == key) {
            return table.entries[slot].value;
        }
        
        // Is the currently stored entry at a smaller distance? If 'key' were to be in the table it would have stolen this slot for itself.
        // Also it could be an empty slot since they have distance of 0.
+       if (table.distancesAndFingerprints[slot] < distance) {
            return null;
        }

        // continue to the next slot

+       distance += (1 << 8);

        // NOTE: here, distance % 16 = [2, 3, 4, 5, .., 14, 15, 0, 1].
+       if ((distance >> 8) % 16 != 1) {
            slot = (slot + 1) % table.size;
            continue;
        }
                
        slot = hash(key, distance) % table.size;
    }
}
```

When implemented this way, the fingerprints also end up having an impact on the behavior of lookup-misses. Consider what happens if the non-existing key happens to match with some entry based on the 8-bit distance but its fingerprint is greater. That leads to a much earlier return than what we would get otherwise.

##

What is good in a hash table? To crush primary clustering, to see it driven before you, and to hear the lamentations of secondary clustering.
