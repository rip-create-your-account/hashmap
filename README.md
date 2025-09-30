![Flag_of_the_United_States](https://github.com/user-attachments/assets/f413f0e4-cba5-469c-9e87-d4de30b4bb0c)

This open addressing hash map provides O(1) worst-case lookups, updates and removes while consistently achieving 100% load factor even for huge hash maps. Filling the map to 100% load factor is worst-case O(N log N) with high probability for success. Filling to 100% load factor can fail.

Please read [the Get() implementation](src/hashmap.zig#155). Please ignore [the Put() implementation](src/hashmap.zig#275).

This hash map combines Robin Hood hashing and 2-choice hashing. Keys are first placed using Robin Hood hashing. If a key can't be placed within 32 slots of its optimal slot then a secondary hash function is used to determine the secondary optimal slot. When keys are placed with the secondary hash function the Robin Hood hashing will always consider their distance from the optimal slot to be higher than that of those placed with the primary hash function. This priority given to the placement with secondary hash function ends up shifting the keys around such that all empty slots are purged.

Removes use tombstones. If there has been any removes then achieving 100% load factor becomes unlikely and usually the map achieves only 99.9% load factor before resize/rehash. Thanks to an optimization we sometimes get away with just marking the slot as empty.

### Performance
```
-- Initialize Map32 to size of 32 with 80% load factor and measure inserting 10000 entries.
result final size: 16384
result final len : 10000
result time      : 2.140ms, avg 21.409ns/insert

-- Initialize Map32 to size of 100000 and measure filling it to 100% load. Must not grow.
result final size: 100000 (no growth)
result final len : 100000 (100% load, 0 empty slots remaining)
result time      : 6.402ms, avg 64.021ns/insert

-- Initialize Map32 to size of 4294967296 and measure filling it to 100% load. Must not grow.
result final size: 4294967296 (no growth)
result final len : 4294967296 (100% load, 0 empty slots remaining)
result time      : 1504247ms, avg 350.235ns/insert

-- Initialize Map32 to size of 2031, fill it to 100% load and then measure doing negative lookups.
result time: avg 6.767ns/lookup

-- Initialize Map32 to size of 203134, fill it to 100% load and then measure doing negative lookups.
result time: avg 11.467ns/lookup
```

### Negative lookups
Consider a hash map with size of 2<sup>20</sup> populated to 75% load. Measuring the performance of negative lookups for it shows a major performance difference between `std.AutoHashMap` and our `Map32`. `std.AutoHashMap` performs at __~24ns/lookup__ and `Map32` at __~6.8ns/lookup__. Thanks to Robin Hood hashing just by inspecting the first location most negative lookups can prove that the key isn't going to be in the secondary location either. This map can be implemented such that you get a single cache-miss in the common case!

In some of our experiments for a map at 100% load we found that ~80% of negative lookups exit after inspecting the 1st location. At 97% load the probability for early exit increased to ~98.4%. At 94% load the probability was up to ~99.9%.

### Filling up to 100% load factor
At 100% load such a map can be used as a Minimal perfect hash function (MPHF) since every key has a unique index in the array and the array has no empty slots. See `map.getIndex(key)`.

### Probe length
In our experiments with probe length of 16 we have been able to consistently insert up to 2<sup>16</sup> keys before the map starts to fail on the 100% load property. With probe length of 32 we have never seen it fail even at 2<sup>32</sup> keys. One can imagine Sisyphus filling a "`Map64`" map with 2<sup>64</sup> keys all the way up to 100% load factor.

We conjencture that a map of size N=2<sup>p</sup> requires a probe length of at least p and at least 2 hash functions to achieve 100% load with high probability. Consider an implementation that starts a hash map of size 1 with probe length of 1 and after every doubling of the size also increases the probe length by 1. We conjencture that such a map achieves 100% load with high-probability while providing guaranteed log(N) worst-case lookups and amortized worst-case log(N) inserts with high probability to fill up to the 100% load. (Using smarter probe sequence allows better results.) Our experiments with the `MapDynamicProbeLength` implementation support this idea. That particular implementation even manages to do it without keeping any metadata beyond a per-entry presence flag!

### Hmm...
AMQ? Compact hashing? History-independence? Time complexity attacks? Smarter probe sequence for possibly worst-case (log log N) whp operations?