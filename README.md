# zedis

zedis is an in-memory data server written in Zig that speaks the Redis wire
protocol (RESP2 and RESP3). Existing Redis clients, `redis-cli` and
`redis-benchmark` work against it unchanged. It implements the five core data
types, key expiration, pub/sub, transactions with optimistic locking,
blocking list and sorted set pops, and append-only file persistence with
fork-based background rewriting, all on a single-threaded epoll event loop.

It has no dependencies beyond the Zig standard library and talks to the
kernel through raw Linux syscalls, so the release binary is fully static.

## Features

- **Protocol**: RESP2 and RESP3 (negotiated with `HELLO`), inline commands
  with redis-cli quoting rules, pipelining, binary-safe values up to 512 MB,
  and Redis' exact protocol error messages.
- **Strings**: `GET`, `SET` with `NX/XX/GET/EX/PX/EXAT/PXAT/KEEPTTL`,
  `GETEX`, `GETDEL`, `MSET[NX]`, `APPEND`, `GETRANGE`/`SETRANGE`,
  `INCR`/`DECR` families, `INCRBYFLOAT` with long double arithmetic,
  `SETBIT`/`GETBIT`/`BITCOUNT`.
- **Lists**: a ring buffer deque with `LPUSH`/`RPUSH`/`LPOP`/`RPOP` (with
  counts), `LRANGE`, `LINDEX`, `LSET`, `LINSERT`, `LREM`, `LTRIM`, `LPOS`,
  `LMOVE`, and blocking `BLPOP`, `BRPOP`, `BLMOVE`, `BRPOPLPUSH`.
- **Hashes**: `HSET`, `HGET`, `HMGET`, `HDEL`, `HINCRBY[FLOAT]`,
  `HRANDFIELD`, `HSCAN` and friends.
- **Sets**: membership, `SPOP`/`SRANDMEMBER`, `SMOVE`, and the algebra
  `SINTER`/`SUNION`/`SDIFF` with `*STORE` variants and `SINTERCARD`.
- **Sorted sets**: a span-indexed skiplist plus hash index. `ZADD` with
  `NX/XX/GT/LT/CH/INCR`, unified `ZRANGE` with `BYSCORE/BYLEX/REV/LIMIT`,
  the legacy range commands, ranks, lex ranges, `ZUNION`/`ZINTER`/`ZDIFF`
  with `WEIGHTS` and `AGGREGATE`, pops including `BZPOPMIN`/`BZPOPMAX`.
- **Keys and expiry**: `EXPIRE` family with `NX/XX/GT/LT`, `TTL`,
  `EXPIRETIME`, `PERSIST`, `SCAN` with `MATCH/COUNT/TYPE`, `KEYS`,
  `RENAME`, `MOVE`, `COPY`, `RANDOMKEY`, 16 logical databases, `SWAPDB`.
  Expired keys are removed lazily on access and actively by an adaptive
  sampling cycle.
- **Pub/Sub**: channels and glob patterns, RESP3 push frames, and the RESP2
  subscriber-mode command restrictions.
- **Transactions**: `MULTI`/`EXEC`/`DISCARD`, `WATCH`/`UNWATCH` invalidated
  by writes, expiry, `FLUSHDB` and `FLUSHALL`; queue-time errors abort with
  `EXECABORT`.
- **Persistence**: append-only file with `always`, `everysec` and `no`
  fsync policies, deterministic rewriting of non-deterministic commands,
  `BGREWRITEAOF` via `fork()`, automatic rewrite on growth, recovery from a
  torn tail, and `CONFIG SET appendonly` at runtime.
- **Operations**: `INFO`, `CONFIG GET/SET`, `CLIENT LIST/ID/SETNAME/KILL`,
  `COMMAND`, `AUTH`/`requirepass`, `DEBUG RELOAD`, `SHUTDOWN`.

163 commands are implemented in total; `COMMAND LIST` prints them.

## Architecture

```
src/
  sys.zig              raw Linux syscalls: sockets, epoll, eventfd, files, fork
  resp.zig             resumable request parser, reply writer, reply decoder
  num.zig              Redis-exact integer parsing and double formatting
  glob.zig             KEYS/SCAN/PSUBSCRIBE pattern matcher
  ds/list.zig          ring buffer deque of owned strings
  ds/skiplist.zig      skiplist with spans for O(log n) rank queries
  ds/zset.zig          sorted set: hash index + skiplist
  value.zig            the per-key value union and helpers
  db.zig               keyspace, expiry index, lazy and active expiry, SCAN
  aof.zig              AOF buffer, snapshot serializer, background rewrite
  server/server.zig    event loop, clients, dispatch, pub/sub, WATCH, blocking
  server/client.zig    per-connection state
  server/config.zig    one table drives CLI flags, CONFIG GET and CONFIG SET
  commands/*.zig       command implementations and the command table
  client.zig           blocking client used by the CLI, tests and benchmark
  cli/main.zig         zedis-cli
tests/compat/          compatibility suite (zedis-compat)
bench/main.zig         zedis-bench load generator
```

A few design points worth calling out:

- **One clock per command.** The server caches the wall clock when a command
  starts and keeps it fixed for the whole command and for an entire
  `MULTI`/`EXEC` block, so TTL decisions inside a transaction are consistent.
- **Acknowledged means written.** Replies are only buffered while commands
  run. Before the loop sleeps it first writes the AOF buffer (and fsyncs
  under `appendfsync always`), and only then flushes client sockets.
- **Deterministic AOF.** Commands are logged after they succeed, and anything
  whose effect depends on time or randomness is rewritten first: relative
  TTLs become `PEXPIREAT`/`SET ... PXAT`, `SPOP` becomes `SREM`,
  `INCRBYFLOAT` becomes `SET ... KEEPTTL`, `ZINCRBY` becomes `ZADD` with the
  resulting score, served blocking pops become `LPOP`/`LMOVE`/`ZPOPMIN`, and
  lazily or actively expired keys produce `DEL`. Writes inside `EXEC` are
  wrapped in `MULTI`/`EXEC`.
- **Fork-based rewrite.** `BGREWRITEAOF` forks; the child serializes a
  copy-on-write snapshot without allocating (safe even when the parent has
  other threads), while the parent keeps serving and records new commands in
  a rewrite buffer that is appended to the new file before the atomic rename.
- **SCAN without misses.** Keys, hashes, sets and sorted set indexes are array
  hash maps. Cursors walk the dense index space from high to low; since
  removal moves the last element into the hole and that element has already
  been visited, an element present for the whole iteration is never skipped.
- **Shared keys.** The expiry index borrows the key slices owned by the main
  dictionary, as Redis does, and active expiry samples it uniformly in O(1).
- **Faithful numbers.** Integer parsing rejects what Redis rejects (`01`,
  `+1`, `-0`, whitespace). Scores use the same shortest round-trip format as
  Redis' `fpconv_dtoa` (`1.1`, `1e+20`), and `INCRBYFLOAT` computes in 80-bit
  extended precision with `%.17Lf`-style trimming, so `0.1 + 0.2` yields
  `0.3` exactly as Redis does.

## Quick start

Requires Zig 0.17.0 on Linux.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zedis-server --port 6379 --appendonly yes --dir /tmp
./zig-out/bin/zedis-cli set greeting hello
./zig-out/bin/zedis-cli get greeting
```

Any Redis client works too:

```sh
redis-cli -p 6379 -3 hello 3
redis-cli -p 6379 zadd board 10 alice 20 bob
redis-cli -p 6379 zrange board 0 -1 withscores
```

Configuration flags mirror `redis.conf` directives: `--bind`, `--port`,
`--dir`, `--appendonly`, `--appendfilename`, `--appendfsync`,
`--requirepass`, `--databases`, `--hz`, `--maxclients`, `--loglevel`,
`--auto-aof-rewrite-percentage`, `--auto-aof-rewrite-min-size`,
`--aof-load-truncated` and `--client-query-buffer-limit`. When `$PORT` is set
it becomes the default port, which is what container platforms expect.

### Docker

```sh
docker build -t zedis .
docker run -p 6379:6379 -e PORT=6379 -v zedis-data:/data zedis
```

The image is built `FROM scratch` with a static binary, listens on
`0.0.0.0:$PORT`, and persists to `/data/appendonly.aof`. Set a password with
`docker run ... zedis --requirepass secret` (extra arguments are appended to
the entrypoint).

## Running the tests

```sh
zig build test      # 76 unit tests: parser, numbers, data structures, keyspace,
                    # AOF, dispatcher and propagation rules
zig build compat    # 1,698 end-to-end checks over TCP against an embedded server
```

`zig build compat` starts zedis on a background thread with a leak-checking
allocator, runs every case through the bundled Zig client, then restarts the
server several times to verify AOF recovery, background rewrite, torn-tail
truncation and runtime `CONFIG SET appendonly`. It fails if any allocation
leaks.

The same suite can target any server. Running it against a real Redis is how
the expectations themselves are kept honest; CI does this with Redis 7.2.5
built from source:

```sh
redis-server --port 7790 --save "" &
zig build compat -- --port 7790   # 1,109 protocol-level checks, persistence cases skipped
```

## Benchmarks

Measured on one machine (AMD Ryzen 7 7800X3D, 14 vCPUs visible to WSL2 on
Windows 11), client and server on the same host, `redis-benchmark` from Redis
7.2.5 with 50 clients. zedis was built with `-Doptimize=ReleaseFast` and
compared with Redis 7.2.5 (`MALLOC=libc`, persistence off) on the same box.
Each figure is the median of three alternating runs in requests per second.
The environment is noisy (individual zedis runs varied by up to 2x on
pipelined tests), so treat the ratios as indicative.

| Command | zedis, no pipeline | Redis, no pipeline | zedis, `-P 16` | Redis, `-P 16` |
|---------|-------------------:|-------------------:|---------------:|---------------:|
| SET     |  77,160 |  88,613 | 1,366,120 | 1,582,278 |
| GET     |  76,746 |  90,621 | 1,259,446 | 1,531,394 |
| INCR    |  75,500 |  88,183 | 1,226,994 | 1,577,287 |
| LPUSH   |  77,190 |  90,090 | 1,362,398 | 1,483,680 |
| RPOP    |  76,453 |  88,067 | 1,305,483 | 1,501,502 |
| SADD    |  78,431 |  82,001 | 1,388,889 | 1,288,660 |
| HSET    |  78,616 |  87,758 | 1,305,483 | 1,228,501 |
| ZADD    |  78,247 |  92,464 | 1,262,626 | 1,141,552 |

In short, zedis lands at roughly 80 to 110 percent of Redis' throughput on
these simple commands. Reproduce with:

```sh
redis-benchmark -p 6379 -q -n 1000000 -c 50 -P 16 -t set,get,incr,lpush,rpop,sadd,hset,zadd
```

`zig build bench -- -p 6379 -c 50 -n 200000 -P 16` runs the bundled Zig load
generator, which also reports p50/p99 latency per pipeline batch.

## Differences from Redis and roadmap

These are honest gaps, roughly in the order they would be tackled:

- **No RDB snapshots.** Persistence is AOF only; `SAVE`/`BGSAVE` and the RDB
  preamble are not implemented. The AOF is a single file in the pre-7.0
  format rather than Redis 7's multi-part manifest.
- **`everysec` fsync runs on the event loop thread** once per second instead
  of a background thread, so a slow disk can stall the loop briefly.
- **No compact encodings.** Small hashes, sets and sorted sets use the same
  hash map and skiplist structures as large ones, so per-element memory is
  higher than Redis' listpack encodings. `OBJECT ENCODING` reports Redis'
  names for compatibility only.
- **Missing data types and commands**: streams, HyperLogLog, geo, `BITOP`,
  `BITFIELD`, `SORT`, `LMPOP`/`BLMPOP`/`ZMPOP`, `DUMP`/`RESTORE`, Lua
  scripting and functions, keyspace notifications, client-side caching.
- **No maxmemory or eviction policies**, and normal client output buffers
  are unbounded (only pub/sub subscribers have a hard limit).
- **Single default user.** `requirepass` and `AUTH` are supported; ACLs are
  not.
- **Networking**: IPv4 TCP only. No IPv6, Unix sockets, TLS, replication or
  cluster mode.
- **Hash seeding**: the hash maps use a fixed Wyhash seed, so hostile key
  sets could degrade them; a per-process random seed is the fix.
- `INFO`, `CLIENT` and `DEBUG` expose a useful subset of their Redis
  counterparts rather than every field and subcommand.

## License

MIT, see [LICENSE](LICENSE).
