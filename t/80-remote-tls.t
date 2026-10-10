# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# A customer's view: connect to a remote HotKV server over the network with
# TLS and a password, and use it. Skipped unless HOTKV_REMOTE_HOST is set.
#
#   HOTKV_REMOTE_HOST      host or IP of the server (required)
#   HOTKV_REMOTE_PORT      TLS port (default 6379)
#   HOTKV_REMOTE_PASSWORD  the password; read from the environment only
#   HOTKV_REMOTE_CA        path of the CA (or self-signed server) certificate
#
# The password is never printed, written to a file or put on a command line
# by this test. The server may be shared: everything is created under a
# random prefix (remote-perl-<hex>) and removed at the end; nothing global
# (FLUSHALL, CONFIG SET, ACL, ...) is touched.

use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time sleep);
use Scalar::Util qw(blessed);

plan skip_all => 'set HOTKV_REMOTE_HOST (and HOTKV_REMOTE_PASSWORD, HOTKV_REMOTE_CA) to run the remote TLS tests'
    unless $ENV{HOTKV_REMOTE_HOST};

use HotKV;
use HotKV::TokenUsage;

my $host = $ENV{HOTKV_REMOTE_HOST};
my $port = $ENV{HOTKV_REMOTE_PORT} || 6379;
my $pass = $ENV{HOTKV_REMOTE_PASSWORD};
my $ca   = $ENV{HOTKV_REMOTE_CA};

plan skip_all => 'set HOTKV_REMOTE_CA to the certificate file of the server' unless $ca && -r $ca;
plan skip_all => 'IO::Socket::SSL is needed for TLS' unless eval { require IO::Socket::SSL; 1 };

sub urlesc { my $s = shift; $s =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord $1)/ge; return $s; }

my $prefix = sprintf('remote-perl-%08x', int(rand(0xffffffff)));
my @cleanup_keys;      # keys to DEL
my @cleanup_code;      # coderefs run at the end (drop namespaces and the like)

sub new_client {
    my (%o) = @_;
    return HotKV->new(
        host => $host, port => $port, tls => 1, tls_ca_file => $ca,
        (defined $pass ? (password => $pass) : ()),
        command_timeout => 30, connect_timeout => 15,
        %o,
    );
}
sub key { my $k = "$prefix:" . shift; push @cleanup_keys, $k; return $k; }
sub name { return "$prefix-" . shift; }

# --- connect: URL form and options form ------------------------------------

my $kv = new_client();
is($kv->ping, 'PONG', 'PING over TLS with the options form');
my $kv_url = HotKV->new(
    url => 'hotkvs://' . (defined $pass ? ':' . urlesc($pass) . '@' : '') . "$host:$port",
    tls_ca_file => $ca, command_timeout => 30, connect_timeout => 15,
);
is($kv_url->ping, 'PONG', 'PING over TLS with the hotkvs:// URL form (password in the URL)');
is($kv_url->echo('héllo'), 'h' . "\xc3\xa9" . 'llo', 'ECHO of a wide character string is sent as UTF-8');
$kv_url->close;

# --- authentication failures fail cleanly ------------------------------------

{
    my $bad = new_client(password => 'definitely-not-the-password');
    my $err = eval { $bad->ping; 1 } ? undef : $@;
    ok($err && blessed($err) && $err->isa('HotKV::Error::Server'), 'a wrong password is a HotKV::Error::Server');
    like($err ? $err->code : '', qr/\A(?:WRONGPASS|NOAUTH|ERR)\z/, 'with an authentication error code');
    unlike("$err" . ($err ? $err->message : ''), qr/definitely-not-the-password/, 'the error does not repeat the password');
    $bad->close;

    my $nopass = HotKV->new(host => $host, port => $port, tls => 1, tls_ca_file => $ca, command_timeout => 30, connect_timeout => 15);
    my $err2 = eval { $nopass->set(key('noauth'), 'x'); 1 } ? undef : $@;
    ok($err2 && blessed($err2) && $err2->isa('HotKV::Error::Server'), 'no password at all is refused with a server error')
        or diag('got: ' . ($err2 // 'success'));
    $nopass->close;
}

# --- TLS verification ----------------------------------------------------------

{
    # The server certificate is self-signed: without the CA the handshake must fail cleanly, not hang.
    my $t0 = time;
    my $noca = HotKV->new(host => $host, port => $port, tls => 1, (defined $pass ? (password => $pass) : ()),
        connect_timeout => 15, command_timeout => 15);
    my $err = eval { $noca->ping; 1 } ? undef : $@;
    ok($err && blessed($err) && $err->isa('HotKV::Error::Connection'), 'a certificate the client does not trust is a HotKV::Error::Connection')
        or diag('got: ' . ($err // 'success'));
    like($err ? $err->message : '', qr/TLS|handshake|certificate|verify/i, 'and the message says it is a TLS problem');
    cmp_ok(time - $t0, '<', 20, 'and it fails promptly');

    # Exactly one test that skips verification.
    my $insecure = new_client(tls_ca_file => undef, tls_insecure_skip_verify => 1);
    is($insecure->ping, 'PONG', 'tls_insecure_skip_verify connects without the CA');
    $insecure->close;

    my $wrong_name = new_client(tls_server_name => 'not-the-certificate-name.invalid');
    my $err3 = eval { $wrong_name->ping; 1 } ? undef : $@;
    ok($err3, 'a server name that does not match the certificate is refused') or diag('connected anyway');
    $wrong_name->close;
}

# --- core data types ---------------------------------------------------------

{
    my $k = key('str');
    is($kv->set($k, 'hello'), 'OK', 'SET');
    is($kv->get($k), 'hello', 'GET');
    is($kv->append($k, ' world'), 11, 'APPEND');
    is($kv->incrby(key('n'), 5), 5, 'INCRBY');
    cmp_ok($kv->incrbyfloat(key('f'), 1e-05), '==', 0.00001, 'INCRBYFLOAT with a tiny float');
    is($kv->mset(key('m1'), 'a', key('m2'), 'b'), 'OK', 'MSET');
    is_deeply($kv->mget("$prefix:m1", "$prefix:m2", "$prefix:missing"), ['a', 'b', undef], 'MGET with a missing key');

    my $h = key('hash');
    is($kv->hset($h, 'name', 'Ada', 'role', 'engineer'), 2, 'HSET');
    is_deeply($kv->hgetall($h), { name => 'Ada', role => 'engineer' }, 'HGETALL');
    is($kv->hincrby($h, 'visits', 3), 3, 'HINCRBY');

    my $l = key('list');
    is($kv->rpush($l, 'a', 'b', 'c'), 3, 'RPUSH');
    is_deeply($kv->lrange($l, 0, -1), ['a', 'b', 'c'], 'LRANGE');
    is($kv->lpop($l), 'a', 'LPOP');

    my $s = key('set');
    is($kv->sadd($s, 'x', 'y', 'z'), 3, 'SADD');
    is($kv->sismember($s, 'y'), 1, 'SISMEMBER');
    is_deeply([sort @{ $kv->smembers($s) }], ['x', 'y', 'z'], 'SMEMBERS');

    my $z = key('zset');
    is($kv->zadd($z, 1.5, 'one', 2.5, 'two', 1e-05, 'tiny'), 3, 'ZADD with floats, one in exponent range');
    is_deeply($kv->zrange($z, 0, -1), ['tiny', 'one', 'two'], 'ZRANGE order');
    is_deeply($kv->zrange($z, 0, 0, { withscores => 1 })->[0][0], 'tiny', 'ZRANGE WITHSCORES');
    cmp_ok($kv->zscore($z, 'tiny'), '==', 0.00001, 'ZSCORE of the tiny float');

    my $st = key('stream');
    my $id = $kv->xadd($st, '*', 'f', 'v');
    like($id, qr/\A\d+-\d+\z/, 'XADD');
    is($kv->xlen($st), 1, 'XLEN');
    is_deeply($kv->xrange($st, '-', '+')->[0][1], ['f', 'v'], 'XRANGE');
    is($kv->xgroup_create($st, 'g', '0'), 'OK', 'XGROUP CREATE');
    my $read = $kv->xreadgroup('g', 'c1', [$st], ['>'], { count => 1 });
    is($read->{$st}[0][1][1], 'v', 'XREADGROUP delivers the entry');
    is($kv->xack($st, 'g', $id), 1, 'XACK');

    my $e = key('expire');
    $kv->set($e, 'x', { px => 400 });
    ok($kv->pttl($e) > 0 && $kv->pttl($e) <= 400, 'PTTL after SET PX');
    sleep(0.8);
    is($kv->get($e), undef, 'the key expired');
    is($kv->exists($e), 0, 'EXISTS is 0 after expiry');
}

# --- pipeline, MULTI/EXEC, WATCH -------------------------------------------------

{
    my $k = key('pipe');
    my $r = $kv->pipeline(sub {
        my $p = shift;
        $p->set($k, 1);
        $p->incr($k);
        $p->get($k);
        $p->lpush("$k:l", 'a');          # wrong type later
        $p->get("$k:l");                 # WRONGTYPE
    });
    push @cleanup_keys, "$k:l";
    is_deeply([@$r[0, 1, 2]], ['OK', 2, 2], 'pipeline replies in order');
    ok(blessed($r->[4]) && $r->[4]->isa('HotKV::Error::Server') && $r->[4]->code eq 'WRONGTYPE', 'a failing command inside a pipeline is an error object in its slot');

    my $big = $kv->pipeline(sub { $_[0]->incr(key('pipecount')) for 1 .. 2000; });
    is($big->[-1], 2000, 'a pipeline of 2000 commands round trips');

    my $t = key('tx');
    my $res = $kv->multi(sub { my $tx = shift; $tx->set($t, 10); $tx->incrby($t, 5); $tx->get($t); });
    is_deeply($res, ['OK', 15, 15], 'MULTI/EXEC');

    my $w = key('watched');
    $kv->set($w, 1);
    my $tx = $kv->watch($w);
    my $other = new_client();
    $other->set($w, 2);
    $other->close;
    my $aborted = $tx->multi(sub { $_[0]->set($w, 3) });
    is($aborted, undef, 'EXEC returns nil when a watched key changed on another connection');
    is($kv->get($w), 2, 'and the queued write did not happen');
}

# --- pub/sub on separate connections ----------------------------------------------

{
    my $chan = name('chan');
    my $pub = new_client();
    my @got;
    $kv->subscribe([$chan], sub {
        my ($ev, $ctl) = @_;
        if ($ev->{type} eq 'subscribe') {
            $pub->publish($chan, 'first');
            $pub->publish($chan, "second\r\n\0bin");
        }
        elsif ($ev->{type} eq 'message') {
            push @got, $ev->{data};
            $ctl->stop if @got == 2;
        }
    });
    is_deeply(\@got, ['first', "second\r\n\0bin"], 'SUBSCRIBE receives what another connection PUBLISHes, binary safe');
    $pub->close;
}

# --- large values -------------------------------------------------------------------

{
    my $k = key('big');
    my $mb = join('', map { chr(($_ * 7 + 3) % 256) } 0 .. 1024 * 1024 - 1);
    my $t0 = time;
    is($kv->set($k, $mb), 'OK', 'SET of a 1 MB binary value');
    my $back = $kv->get($k);
    ok(defined $back && length($back) == 1024 * 1024 && $back eq $mb, 'GET returns the same 1 MB byte for byte');
    cmp_ok(time - $t0, '<', 60, 'in reasonable time');
    is($kv->strlen($k), 1024 * 1024, 'STRLEN');
    my $sixteen = 'z' x (16 * 1024 * 1024);
    $kv->set($k, $sixteen);
    my $b16 = $kv->get($k);
    ok(defined $b16 && length($b16) == length($sixteen) && $b16 eq $sixteen, 'a 16 MB value round trips too');
}

# --- the server closes our connection: reconnect -----------------------------------------

{
    my $one = new_client(pool_size => 1);
    my $id = $one->client_id;
    ok($id > 0, 'CLIENT ID');
    my $killer = new_client();
    is($killer->client_kill('ID', $id), 1, 'another connection kills it with CLIENT KILL ID');
    $killer->close;
    sleep(0.3);
    my $r = eval { $one->set(key('afterkill'), 'ok') };
    is($@, '', 'the next command after the server closed the pooled connection does not raise');
    is($r, 'OK', 'and succeeds on a new connection');
    $one->close;
}

# --- concurrent use --------------------------------------------------------------------------

SKIP: {
    skip 'fork based concurrency test is not run on Windows', 3 if $^O eq 'MSWin32';
    my $counter = key('counter');
    my @pids;
    for my $worker (1 .. 4) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            my $c = new_client();
            my $ok = eval { $c->incr($counter) for 1 .. 100; 1 };
            $c->close;
            exit($ok ? 0 : 1);
        }
        push @pids, $pid;
    }
    my $failed = 0;
    for my $pid (@pids) { waitpid($pid, 0); $failed++ if $? != 0; }
    is($failed, 0, 'four forked workers, each with its own TLS connection, all finished');
    is($kv->get($counter), 400, 'and their 400 INCRs all arrived');
    # one client shared between interleaved pipelines on a pool of connections
    my $shared = new_client(pool_size => 3);
    my @conns = map { $shared->pipeline(sub { $_[0]->incr($counter) for 1 .. 10 }) } 1 .. 5;
    is($kv->get($counter), 450, 'five more pipelines through one pooled client');
    $shared->close;
}

# --- the AI features, through the typed API ---------------------------------------------------

# The first licensed command doubles as the probe: a server without the AI
# features answers NOLICENSE, which skips the rest of this section.
my $sc = name('scache');
push @cleanup_code, sub { $kv->scache->drop($sc) };
my $sc_created = eval { $kv->scache->create($sc, 3, { metric => 'cosine', threshold => 0.8 }) };
my $sc_err = $@;
my $not_licensed = !defined $sc_created && blessed($sc_err) && $sc_err->isa('HotKV::Error::Server::NotLicensed');
ok(defined $sc_created || $not_licensed, 'SCACHE.CREATE is accepted or reports NotLicensed') or diag($sc_err);

SKIP: {
    skip 'the remote server is not licensed for the AI features', 100 unless defined $sc_created;
    is($sc_created, 'OK', 'SCACHE.CREATE');

    # semantic cache
    my $usage = HotKV::TokenUsage->new(model => 'claude-sonnet-5', input_tokens => 120, output_tokens => 40);
    is($kv->scache->set($sc, 'what is hotkv', 'a fast kv store', [1, 0, 0], { usage => $usage }), 'OK', 'SCACHE.SET with an embedding');
    my $hit = $kv->scache->get($sc, [0.95, 0.05, 0]);
    is($hit->[0], 'a fast kv store', 'SCACHE.GET with a similar embedding hits');
    ok($hit->[1] > 0.9 && $hit->[1] <= 1.0001, 'with a similarity close to 1');
    is($kv->scache->get($sc, [0, 0, 1]), undef, 'an orthogonal embedding misses');
    my $scs = $kv->scache->stats($sc);
    is($scs->{entries}, 1, 'SCACHE.STATS entries');
    ok($scs->{hits} >= 1 && $scs->{misses} >= 1, 'SCACHE.STATS hits and misses');
    is($kv->scache->drop($sc), 1, 'SCACHE.DROP');

    # prompt cache
    my $pc = name('pcache');
    push @cleanup_code, sub { $kv->pcache->drop($pc) };
    is($kv->pcache->create($pc, { max_entries => 100, ttl => 60, cost_per_hit => 0.002 }), 'OK', 'PCACHE.CREATE with a float cost');
    is($kv->pcache->set($pc, 'prompt', 'answer', { usage => $usage }), 'OK', 'PCACHE.SET');
    is($kv->pcache->get($pc, 'prompt'), 'answer', 'PCACHE.GET');
    is($kv->pcache->stats($pc)->{hits}, 1, 'PCACHE.STATS hits');
    is($kv->pcache->drop($pc), 1, 'PCACHE.DROP');

    # keyed caches
    for my $f (['toolcache', 'tool'], ['ncache', 'neg'], ['guard', 'guard'], ['rerank', 'rerank']) {
        my ($accessor, $label) = @$f;
        my $ns = name($label);
        my $h = $kv->$accessor;
        push @cleanup_code, sub { $h->drop($ns) };
        is($h->create($ns, { max_entries => 50, ttl => 60 }), 'OK', "$accessor create");
        is($h->set($ns, 'k', 'v'), 'OK', "$accessor set");
        is($h->get($ns, 'k'), 'v', "$accessor get");
        is($h->drop($ns), 1, "$accessor drop");
    }

    # LLM budget with float limits, LLM stats
    my $b = name('budget');
    push @cleanup_code, sub { $kv->llmbudget->drop($b) };
    is($kv->llmbudget->set($b, 1_000_000, 1e-05, 3600), 'OK', 'LLMBUDGET.SET with the float 1e-05');
    cmp_ok($kv->llmbudget->status($b)->{cost_limit_usd}, '==', 0.00001, 'LLMBUDGET.STATUS shows 0.00001');
    is($kv->llmbudget->set($b, 1_000_000, 12.5, 3600), 'OK', 'LLMBUDGET.SET with 12.5');
    is($kv->llmbudget->consume($b, 100, 0.25), 1, 'LLMBUDGET.CONSUME within the budget');
    is($kv->llmbudget->consume($b, 100, 13.0), 0, 'LLMBUDGET.CONSUME over the cost limit is refused (0)');
    is($kv->llmbudget->drop($b), 1, 'LLMBUDGET.DROP');
    my $bucket = name('bucket');
    push @cleanup_code, sub { $kv->llmstats->drop($bucket) };
    is($kv->llmstats->bucket($bucket), 'OK', 'LLMSTATS.BUCKET');
    is($kv->llmstats->record($bucket, 100, 50, 0, 1e-05, 120), 'OK', 'LLMSTATS.RECORD with a tiny float cost');
    is($kv->llmstats->get($bucket)->{requests}, 1, 'LLMSTATS.GET requests');
    is($kv->llmstats->drop($bucket), 1, 'LLMSTATS.DROP');

    # prompt registry
    my $pr = name('prompt');
    push @cleanup_code, sub { $kv->prompt->drop($pr) };
    is($kv->prompt->put($pr, 'You are helpful.'), 1, 'PROMPT.PUT');
    is($kv->prompt->put($pr, 'You are very helpful.'), 2, 'PROMPT.PUT version 2');
    is($kv->prompt->latest($pr)->[1], 'You are very helpful.', 'PROMPT.LATEST');
    is_deeply($kv->prompt->versions($pr), [1, 2], 'PROMPT.VERSIONS');
    is($kv->prompt->drop($pr), 1, 'PROMPT.DROP');

    # embedding dedup
    my $ed = name('dedup');
    push @cleanup_code, sub { $kv->embeddedup->drop($ed) };
    is($kv->embeddedup->put($ed, 'h1', 'text-embedding-3', '0.1,0.2,0.3'), 1, 'EMBED.DEDUP.PUT');
    is($kv->embeddedup->get($ed, 'h1'), '0.1,0.2,0.3', 'EMBED.DEDUP.GET');
    is($kv->embeddedup->drop($ed), 1, 'EMBED.DEDUP.DROP');

    # agent memory
    my $conv = name('conv');
    push @cleanup_code, sub { $kv->amem->conv_drop($conv) };
    is($kv->amem->conv_create($conv, { window => 10 }), 'OK', 'AMEM.CONV.CREATE');
    is($kv->amem->conv_append($conv, 'user', 'hello'), 'OK', 'AMEM.CONV.APPEND');
    is($kv->amem->conv_get($conv)->[0][3], 'hello', 'AMEM.CONV.GET');
    is($kv->amem->conv_drop($conv), 1, 'AMEM.CONV.DROP');
    my $agent = name('agent');
    push @cleanup_code, sub { $kv->amem->sem_forget($agent, 'f1') };
    is($kv->amem->sem_create($agent, 3), 'OK', 'AMEM.SEM.CREATE');
    is($kv->amem->sem_store($agent, 'f1', 'the sky is blue', [1, 0, 0]), 'OK', 'AMEM.SEM.STORE');
    is($kv->amem->sem_recall($agent, 1, [1, 0, 0])->[0][3], 'the sky is blue', 'AMEM.SEM.RECALL');
    $kv->amem->sem_forget($agent, 'f1');

    # RAG
    my $rag = name('rag');
    push @cleanup_code, sub { $kv->rag->drop($rag) };
    is($kv->rag->create($rag, 3, { strategy => 'fixed', chunk_size => 100 }), 'OK', 'RAG.CREATE');
    is($kv->rag->ingest($rag, 'doc1', 'HotKV is a fast in-memory data store.', { vectors => [[1, 0, 0]] }), 1, 'RAG.INGEST');
    my $found = $kv->rag->search($rag, 'fast store', { k => 3, vector => [1, 0, 0] });
    is($found->[0][1], 'doc1', 'RAG.SEARCH finds the document');
    is($kv->rag->drop($rag), 'OK', 'RAG.DROP');

    # rate limiting
    my $rl = name('limiter');
    push @cleanup_code, sub { $kv->ratelimit->drop($rl) };
    is($kv->ratelimit->create($rl, 2, 60_000, { algo => 'sliding_window' }), 'OK', 'RATELIMIT.CREATE');
    is($kv->ratelimit->check($rl, 'u')->[0], 1, 'RATELIMIT.CHECK allowed');
    $kv->ratelimit->check($rl, 'u');
    is($kv->ratelimit->check($rl, 'u')->[0], 0, 'RATELIMIT.CHECK denied after the limit');
    is($kv->ratelimit->drop($rl), 'OK', 'RATELIMIT.DROP');
    my $g = key('gcra');
    my $gr = $kv->gcra->limit($g, 1000, 5);
    is($gr->[0], 0, 'GCRA.LIMIT allows the first request');
    is($kv->gcra->reset($g), 1, 'GCRA.RESET');

    # time series
    my $ts = name('ts');
    push @cleanup_code, sub { $kv->ts->delete($ts) };
    is($kv->ts->create($ts, { retention => 0 }), 'OK', 'TS.CREATE');
    is($kv->ts->add($ts, 1000, 1.5), 1000, 'TS.ADD');
    $kv->ts->add($ts, 2000, 2.5);
    is(scalar(@{ $kv->ts->range($ts, '-', '+') }), 2, 'TS.RANGE');
    is($kv->ts->agg($ts, '-', '+', 10000, 'sum')->[0][1] + 0, 4, 'TS.AGG sum');
    is($kv->ts->delete($ts), 'OK', 'TS.DELETE');

    # feature store
    my $fg = name('features');
    push @cleanup_code, sub { $kv->feature->drop($fg) };
    is($kv->feature->create($fg, 'users', ['age', 'int64', 'score', 'double']), 'OK', 'FEATURE.CREATE');
    is($kv->feature->set($fg, 'u1', 'age', 30, 'score', '4.5'), 'OK', 'FEATURE.SET');
    my %f = @{ $kv->feature->get($fg, 'u1')->[0] };
    is($f{age}, 30, 'FEATURE.GET');
    is($kv->feature->drop($fg), 'OK', 'FEATURE.DROP');

    # vector similarity
    my $vi = name('vsim');
    push @cleanup_code, sub { $kv->vsim->dropindex($vi) };
    is($kv->vsim->createindex($vi, 3, { metric => 'cosine' }), 'OK', 'VSIM.CREATEINDEX');
    is($kv->vsim->set($vi, 'a', [1, 0, 0]), 1, 'VSIM.SET');
    $kv->vsim->set($vi, 'b', [0, 1, 0]);
    my $nn = $kv->vsim->search($vi, 1, [0.9, 0.1, 0]);
    is($nn->[0], 'a', 'VSIM.SEARCH nearest neighbour');
    is($kv->vsim->dropindex($vi), 'OK', 'VSIM.DROPINDEX');

    # tags
    my $tk = key('tagged');
    $kv->set($tk, 'v');
    is($kv->tag->set($tk, "$prefix-red", "$prefix-big"), 2, 'TAG.SET');
    is_deeply($kv->tag->members("$prefix-red"), [$tk], 'TAG.MEMBERS');
    $kv->tag->rem($tk, "$prefix-red", "$prefix-big");

    # newer typed commands
    my $ch = name('pubsubchan');
    is($kv->publish($ch, 'x'), 0, 'PUBLISH with no subscriber');
    is($kv->bitfield(key('bf'), ['SET', 'u8', 0, 200], ['GET', 'u8', 0])->[1], 200, 'BITFIELD');
    ok(scalar(@{ $kv->latency_latest }) >= 0, 'LATENCY LATEST');
    my $lib = 'remoteperl' . substr($prefix, -8);
    my $fcode = "#!lua name=$lib\nredis.register_function('${lib}_echo', function(keys, args) return args[1] end)\n";
    push @cleanup_code, sub { $kv->function_delete($lib) };
    is($kv->function_load($fcode), $lib, 'FUNCTION LOAD');
    is($kv->fcall("${lib}_echo", [], ['pong']), 'pong', 'FCALL');
    is($kv->function_delete($lib), 'OK', 'FUNCTION DELETE');
}

# --- cleanup -----------------------------------------------------------------------------------------

for my $code (@cleanup_code) { eval { $code->() }; }
$kv->del(@cleanup_keys) if @cleanup_keys;
my $left = $kv->keys("$prefix:*");
is_deeply($left, [], 'nothing of this test is left behind');
$kv->close;
done_testing;
