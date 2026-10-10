# HotKV Perl Client

[![CI](https://github.com/hotkv-ltd/hotkv-perl-client/actions/workflows/ci.yml/badge.svg)](https://github.com/hotkv-ltd/hotkv-perl-client/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A high-performance Perl client for [HotKV](https://hotkv.com), a RESP2/RESP3-compatible
in-memory data store with built-in AI and LLM-serving features (semantic and prompt
caching, agent memory, RAG, feature store, rate limiting, time series and more).

## Install

From a checkout or an unpacked distribution tarball:

```
perl Makefile.PL
make
make test
make install
```

(`cpanm HotKV` works once a release has been uploaded to PAUSE; until then
install from the tarball: `cpanm HotKV-1.0.0.tar.gz`.)

Tested with HotKV server v0.3.0. Perl 5.16 or newer.

The SDK has no mandatory runtime dependencies beyond core Perl 5.16+
modules (`IO::Socket::INET`, `IO::Select`, `Digest::SHA`,
`Time::HiRes`, `Scalar::Util`, ...). `IO::Socket::SSL` is only required if
you connect with TLS.

## Quick start

```perl
use HotKV;

my $kv = HotKV->new(url => 'hotkv://127.0.0.1:6379');

$kv->set('greeting', 'hello world');
print $kv->get('greeting'), "\n";

$kv->hset('user:1', 'name', 'Ada', 'role', 'engineer');
print $kv->hget('user:1', 'name'), "\n";

$kv->close;
```

## Connecting

```perl
# From a URL: hotkv:// (plain), hotkvs:// (TLS). redis:// and rediss://
# are accepted too, for drop-in migration. A query string takes resp3=0|1,
# client_name, connect_timeout, command_timeout, pool_size and idle_timeout.
my $kv = HotKV->new(url => 'hotkv://user:password@10.0.0.5:6379/2?command_timeout=10');

# Or with explicit options:
my $kv = HotKV->new(
    host            => '10.0.0.5',
    port            => 6379,
    username        => 'user',
    password        => 'secret',
    db              => 2,
    client_name     => 'my-app',
    connect_timeout => 5,     # seconds
    command_timeout => 5,     # seconds; undef waits forever
    resp3           => 1,     # HELLO 3 by default, falls back to RESP2 automatically
);
```

### TLS

```perl
my $kv = HotKV->new(
    url                       => 'hotkvs://10.0.0.5:6380',
    tls_ca_file               => '/etc/ssl/hotkv-ca.pem',
    tls_cert_file             => '/etc/ssl/client.pem',   # optional client cert
    tls_key_file              => '/etc/ssl/client.key',
    tls_server_name           => 'hotkv.internal',        # SNI / hostname verification
    tls_insecure_skip_verify  => 0,                        # true only for local testing
);
```

### Unix sockets

```perl
my $kv = HotKV->new(path => '/var/run/hotkv/hotkv.sock');
```

### Connection pooling

Every `HotKV` instance owns a bounded pool of connections (`pool_size`,
default 5; `idle_timeout`, default 300 seconds, after which a pooled
connection is health-checked with `PING` before reuse). Bursts beyond
`pool_size` simply open additional, non-pooled connections rather than
blocking the caller:

```perl
my $kv = HotKV->new(url => $url, pool_size => 20, idle_timeout => 60);
```

A pooled connection the server closed while it sat idle (a server side
`timeout`) is noticed before the next command and replaced, so that command
does not fail. A connection lost mid-command is retried once, automatically,
for idempotent reads (`GET`, `HGETALL`, `ZRANGE`, ...); writes are never
retried unless you opt in with `retry_writes => 1`.

## Pipelines

Queue several commands and send them in a single round trip:

```perl
my $results = $kv->pipeline(sub {
    my $p = shift;
    $p->set('a', 1);
    $p->incr('a');
    $p->get('a');
});
# $results = ['OK', 2, '2'], in call order.
```

A failing command inside a pipeline does not abort the batch: its slot in
the result list holds a `HotKV::Error::Server` object instead of the usual
value, so you can inspect it with `->code`.

## Transactions

```perl
my $results = $kv->multi(sub {
    my $tx = shift;
    $tx->incr('visits');
    $tx->set('last_visit', time());
});
# undef instead of an arrayref means the transaction was aborted (see WATCH below).
```

`WATCH` / `UNWATCH`, with the classic read-then-decide pattern:

```perl
my $tx = $kv->watch('balance');
my $balance = $tx->get('balance');           # runs immediately, not queued
if ($balance >= 100) {
    my $result = $tx->multi(sub {
        my $t = shift;
        $t->decrby('balance', 100);
    });
    print "committed\n" if $result;
    print "aborted, balance changed concurrently\n" unless $result;
}
else {
    $tx->unwatch;
}
```

## Numbers, text and binary data

A Perl **number** is sent as plain decimal text, never in exponent form, so
`1e-05` goes out as `0.00001`, `1e22` as `10000000000000000000000` and `5.0`
as `5`; the shortest text that reads back as the same double is used and
NaN is refused (`HotKV::Protocol::format_double`). That matters because the
server's money fields (`LLMBUDGET.SET`, `LLMSTATS.PRICE SET`) reject an
exponent. Money arguments are written as exact micro-dollars
(`HotKV::Protocol::format_usd`: non-negative, at most six decimals).

A **string** is never reformatted, even if it looks like a number: storing
`'1e-05'` reads back as `1e-05`. (On Perl older than 5.36 a number that has
already been interpolated into a string counts as a string.)

Replies are byte strings and are not decoded. A string with wide characters
is sent as UTF-8; decode what you read back yourself (`utf8::decode`).
Binary data (NUL bytes, CRLF, all 256 byte values) round trips.

Blocking commands (`blpop`, `brpop`, `blmove`, `bzpopmin`, `xread` with
`block`, `wait`, ...) wait for the server for as long as their own timeout
says plus `command_timeout`, and for ever when the timeout is `0`.

## Pub/Sub

Blocking, callback driven, on its own dedicated connection:

```perl
$kv->subscribe(['news', 'alerts'], sub {
    my ($event, $control) = @_;
    if ($event->{type} eq 'message') {
        print "$event->{channel}: $event->{data}\n";
    }
    $control->stop if $event->{data} eq 'bye';
});

# Also available: psubscribe (pattern subscriptions, "pmessage" events) and
# ssubscribe (cluster shard channels, SPUBLISH / "smessage" events).
```

## Cluster

```perl
use HotKV::Cluster;

my $cluster = HotKV::Cluster->new(
    nodes    => ['10.0.0.1:6379', '10.0.0.2:6379', '10.0.0.3:6379'],
    password => 'secret',
    read_from_replicas => 1,   # optional: route read-only commands to a replica
);

$cluster->set('{user1000}.name', 'ada');
print $cluster->get('{user1000}.name'), "\n";
```

`HotKV::Cluster` discovers the slot map from `CLUSTER SLOTS` (or
`CLUSTER SHARDS`), routes each command by hashing its key with CRC16
(honoring `{hash tag}`), and follows `MOVED` (refreshing the slot map) and
`ASK` (sending `ASKING` first) redirects automatically, up to
`max_redirects` (default 5).

## HotKV commands

The HotKV-exclusive and AI command families have typed wrappers, grouped by
family and reachable straight off the client (or a pipeline/transaction).
The accessors are `tag`, `gcra`, `vsim`, `bf`, `cms`, `topk` (core, no
license), and, with the matching license feature, `scache`, `pcache`,
`toolcache`, `ncache`, `guard`, `rerank`, `llmstats`, `llmbudget`, `prompt`,
`embeddedup`, `amem`, `rag`, `ratelimit`, `ts`, `feature`,
`observe`, `tenant`, `iam`, `audit`, `encryption` and `replication`:

```perl
$kv->tag->set('product:42', 'sale', 'featured');
$kv->tag->members('sale');                      # keys carrying the "sale" tag

$kv->nexpire('product:42', 60_000_000_000);      # nanosecond-resolution TTL
$kv->hotkeys_top(10);

$kv->gcra->limit('api:client9', 1000, 10);        # generic cell rate limiter

$kv->vsim->createindex('docs', 384);
$kv->vsim->set('docs', 'doc1', \@embedding);
$kv->vsim->search('docs', 5, \@query_embedding);

$kv->scache->create('faq', 384, { threshold => 0.85 });
$kv->pcache->create('chat-v1');
$kv->amem->conv_append('session1', 'user', 'hello');
$kv->rag->create('kb', 384);
$kv->ratelimit->create('api', 100, 60_000);
$kv->ts->create('cpu.load', { retention => 86_400_000 });
$kv->feature->create('users', 'user features', ['age', 'int64']);
$kv->observe->info;
```

See `perldoc HotKV::Commands` and each `HotKV::Commands::*` module for the
full method list and exact wire syntax.

### Command coverage

Against HotKV v0.3.0, most core commands and nearly all enterprise commands
have a typed method, and all but one of those are called live by the test suite
(`ENCRYPTION.ROTATE` changes global server state; its arguments are checked
in `t/45-admin-wire-args.t`).

Commands **without** a typed method, which you reach with the generic
`command` method:

* connection level commands: `AUTH`, `HELLO`, `QUIT`, `RESET`, `MONITOR`,
  `READONLY`, `READWRITE`, `ASKING`, `CLIENT REPLY` (the connection layer does
  `AUTH`/`HELLO`/`SELECT`; the others would desynchronize a pooled
  connection), and the `SUBSCRIBE` family (use `subscribe`, `psubscribe`,
  `ssubscribe`);
* cluster administration: `CLUSTER` subcommands that change topology
  (`ADDSLOTS`, `MEET`, `SETSLOT`, `FAILOVER`, ...), `MIGRATE`; only the
  read only `cluster_*` helpers, `clusterscan`, `sflush` and `trimslots` are
  typed;
* `DEBUG`, `SHUTDOWN`, `MODULE LOAD/UNLOAD`, `PFDEBUG`, `PFSELFTEST`,
  `PSYNC`, `SLAVEOF`, the `*.HELP` subcommands, and the internal replication
  commands `LLMBUDGET.SYNC`, `LLMSTATS.SYNC`, `RATELIMIT.SYNC`.

```perl
$kv->command('OBJECT', 'ENCODING', 'mykey');
$kv->command('CLUSTER', 'COUNT-FAILURE-REPORTS', $node_id);
```

`CLIENT TRACKING`, `CLIENT CACHING`, `CLIENT GETREDIR` and `CLIENT
TRACKINGINFO` are typed (`client_tracking`, ...), but server-assisted
client-side caching needs a RESP3 connection that receives invalidation
pushes; this SDK does not subscribe to or process those pushes, so use
tracking with `redirect` to a second connection you subscribe to
`__redis__:invalidate` yourself.

Enterprise/AI commands need a licensed server; a command whose feature the
server is not licensed for raises a `HotKV::Error::Server::NotLicensed`
(see below).

## AI caching

### Prompt cache: skip the LLM call on a hit

`HotKV::AI::PromptCache` builds a deterministic cache key from the
provider, model, messages, system prompt and generation parameters (the
exact key derivation is documented in `perldoc HotKV::AI::PromptCache` and
is identical across every HotKV SDK), so identical requests from any
language hit the same cache entry:

```perl
use HotKV::AI::PromptCache;

my $cache = HotKV::AI::PromptCache->new(
    client       => $kv,
    ns           => 'chat-v1',      # create once: $kv->pcache->create('chat-v1')
    stats_bucket => 'chat-v1',      # optional: records usage via LLMSTATS.*
);

my $result = $cache->get_or_call(
    provider => 'openai',
    model    => 'gpt-6-sol',
    system   => 'You are a helpful assistant.',
    messages => [ { role => 'user', content => $user_question } ],
    params   => { temperature => '0.2' },   # values are strings you format yourself
    call     => sub {
        # This block only runs on a cache miss.
        my $response = My::LLM::Client->new->chat(
            model    => 'gpt-6-sol',
            messages => [ { role => 'user', content => $user_question } ],
        );
        return {
            response      => $response->text,
            input_tokens  => $response->usage->{input_tokens},
            output_tokens => $response->usage->{output_tokens},
            cost_usd      => $response->usage->{cost_usd},
        };
    },
);

print $result->{cached} ? "served from cache\n" : "called the LLM\n";
print $result->{response}, "\n";
```

### Semantic cache: nearest-neighbor answers

`HotKV::AI::SemanticCache` never calls any particular embedding provider
for you; hand it whatever vector your own embedding model produced:

```perl
use HotKV::AI::SemanticCache;

my $cache = HotKV::AI::SemanticCache->new(client => $kv, ns => 'faq-v1');
$cache->create(384, { threshold => 0.86 });

my $result = $cache->get_or_call(
    query  => $user_question,
    vector => $my_embedding_client->embed($user_question),
    call   => sub { My::LLM::Client->new->chat(...)->text }, # only runs on a miss
);
```

## LLM cost tracking

A `HotKV::TokenUsage` records one model call's tokens; pass it (as
`usage => ...`) to `PCACHE.SET`, `SCACHE.SET`, any keyed cache `SET` or
`LLMBUDGET.CONSUME`, and a later cache hit attributes the tokens, and
once the model is priced its exact cost, to that namespace's
`usage_saved_*` stats:

```perl
use HotKV::TokenUsage;

my $usage = HotKV::TokenUsage->new(
    model         => 'claude-sonnet-5',
    input_tokens  => 120,
    output_tokens => 40,
);
$kv->pcache->set('chat-v1', $prompt, $response, { usage => $usage });

# ... later, on a cache hit:
my $stats = $kv->pcache->stats('chat-v1');
print "saved $stats->{usage_saved_requests} calls, ",
      "\$$stats->{usage_saved_cost_usd} once the model is priced\n";
```

`LLMSTATS.RECORD` accepts the same `model` option so its cost is computed
from the price table instead of a manually tracked `cost_usd`:

```perl
$kv->llmstats->bucket('chat-v1');
$kv->llmstats->record('chat-v1', 120, 40, 0, 0, 812, { model => 'claude-sonnet-5' });
```

Custom models (or a price override for a built-in one) go through
`LLMSTATS.PRICE SET`, USD per 1,000,000 tokens:

```perl
$kv->llmstats->price_set('my-finetuned-model', 2, 10);   # input, output
my $price = $kv->llmstats->price_get('my-finetuned-model');
print $price->source, "\n";   # "custom"
```

`LLMBUDGET.CONSUME` takes the same `usage` option so a budget's token
count and cost are both derived from the price table:

```perl
my $allowed = $kv->llmbudget->consume('team-a', { usage => $usage });
```

## Error handling

Every failure is a `die`-thrown object under `HotKV::Error`:

```perl
use Scalar::Util qw(blessed);

eval {
    $kv->pcache->get('chat-v1', $key);
};
if (my $err = $@) {
    if (blessed($err) && $err->isa('HotKV::Error::Server::NotLicensed')) {
        # feature not covered by the current license; fall back
    }
    elsif (blessed($err) && $err->isa('HotKV::Error::Server')) {
        warn "server error [", $err->code, "]: ", $err->message, "\n";
    }
    elsif (blessed($err) && $err->isa('HotKV::Error::Connection')) {
        warn "connection problem: $err\n";
    }
    else {
        die $err;
    }
}
```

`HotKV::Error::Server::Moved` and `::Ask` (cluster redirects) and
`HotKV::Error::Timeout` (a `HotKV::Error::Connection` subclass) round out
the hierarchy; see `perldoc HotKV::Error`.

## Testing

Unit tests need no server (this includes cluster routing and redirects
against fake servers, number formatting, and the pool against a forked
responder):

```
prove -Ilib t/
```

Integration tests run against a real HotKV server when `HOTKV_TEST_URL` is
set (and are skipped otherwise). The suite was run against HotKV v0.3.0 over
both RESP3 and RESP2 (`?resp3=0`):

```
HOTKV_TEST_URL=hotkv://127.0.0.1:6379 prove -Ilib t/
HOTKV_TEST_URL='hotkv://127.0.0.1:6379?resp3=0' prove -Ilib t/
```

Enterprise and AI commands need a licensed server; on an unlicensed one the
tests that need a license feature skip themselves (they detect `NOLICENSE`).
They create their own uniquely named keys and namespaces and use databases
9 and 10 for `SWAPDB`/`FLUSHDB`; do not point them at a server whose
databases 9 and 10 matter. Further switches:

* `HOTKV_TEST_ALLOW_FLUSHALL=1` also runs `FLUSHALL` (it empties the server);
* `HOTKV_REMOTE_HOST`, `HOTKV_REMOTE_PORT`, `HOTKV_REMOTE_PASSWORD` and
  `HOTKV_REMOTE_CA` run `t/80-remote-tls.t`, which connects over the network
  with TLS and a password like a customer would (never put the password in a
  file; pass it through the environment).

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Support

- Bugs and feature requests: [GitHub issues](https://github.com/hotkv-ltd/hotkv-perl-client/issues)
- Questions and commercial support: support@hotkv.com
- Security vulnerabilities: see [SECURITY.md](SECURITY.md)

## License

Licensed under the Apache License, Version 2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Trademarks and affiliation

"HotKV" is a trademark of HotKV Ltd; the license does not grant rights to use it.
The HotKV server is a separate commercial product, and its enterprise commands need a HotKV license.

HotKV is an independent product of HotKV Ltd. It speaks the RESP protocol and implements
many Redis commands so that existing tools and client habits carry over, but it is not Redis,
Valkey, Dragonfly or KeyDB, and this SDK is built for and tested against HotKV. HotKV Ltd is not
affiliated with, endorsed by or sponsored by Redis Ltd., the Valkey project, DragonflyDB or KeyDB.
Redis is a registered trademark of Redis Ltd. Valkey, Dragonfly, KeyDB and all other product and
company names are trademarks of their respective owners; they are used here only to describe
protocol and command compatibility.
