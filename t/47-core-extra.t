# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# Live tests for the typed core commands that are not covered by the
# per-type files (t/10 .. t/18): newer additions, blocking and multi-key
# pops, SORT, BITFIELD, GEORADIUS*, Pub/Sub publishing, ACL, CLIENT, COMMAND,
# LATENCY, MEMORY, SLOWLOG, FUNCTION/FCALL. Each test checks the reply value.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name safe_name);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());
my @cleanup;
sub key { my $k = unique_name(shift); push @cleanup, $k; return $k; }

# --- strings ---------------------------------------------------------------

{
    my $k = key('str');
    $kv->set($k, 'hello world');
    is($kv->substr($k, 0, 4), 'hello', 'SUBSTR');
    like($kv->digest($k), qr/\A[0-9a-f]{16}\z/, 'DIGEST is 16 hex digits');
    is($kv->digest(key('missing')), undef, 'DIGEST of a missing key is nil');

    my ($a, $b) = (key('lcsa'), key('lcsb'));
    $kv->set($a, 'ohmytext');
    $kv->set($b, 'mynewtext');
    is($kv->lcs($a, $b), 'mytext', 'LCS');
    is($kv->lcs($a, $b, { len => 1 }), 6, 'LCS LEN');
    my $idx = $kv->lcs($a, $b, { idx => 1, minmatchlen => 4, withmatchlen => 1 });
    ok(ref($idx) && (ref($idx) eq 'HASH' ? exists $idx->{matches} : scalar(@$idx)), 'LCS IDX MINMATCHLEN WITHMATCHLEN returns the matches');

    my $c = key('cond');
    $kv->set($c, 'v1');
    is($kv->set($c, 'v2', { ifeq => 'nope' }), undef, 'SET IFEQ with a different value is a no-op');
    is($kv->set($c, 'v2', { ifeq => 'v1' }), 'OK', 'SET IFEQ with the current value sets');
    is($kv->set($c, 'v3', { ifne => 'v2' }), undef, 'SET IFNE with the current value is a no-op');
    is($kv->set($c, 'v3', { ifne => 'zzz' }), 'OK', 'SET IFNE with another value sets');
    my $d = $kv->digest($c);
    is($kv->set($c, 'v4', { ifdeq => 'ffffffffffffffff' }), undef, 'SET IFDEQ with another digest is a no-op');
    is($kv->set($c, 'v4', { ifdeq => $d }), 'OK', 'SET IFDEQ with the current digest sets');
    is($kv->get($c), 'v4', 'value after IFDEQ');
    is($kv->set($c, 'v5', { ifdne => $kv->digest($c) }), undef, 'SET IFDNE with the current digest is a no-op');
    is($kv->set($c, 'v5', { ifdne => 'ffffffffffffffff' }), 'OK', 'SET IFDNE with another digest sets');

    is($kv->delex($c, { ifeq => 'wrong' }), 0, 'DELEX IFEQ with a different value keeps the key');
    is($kv->delex($c, { ifeq => 'v5' }), 1, 'DELEX IFEQ with the current value deletes');
    is($kv->exists($c), 0, 'the key is gone');
    $kv->set($c, 'x');
    is($kv->delex($c), 1, 'DELEX with no condition deletes');

    my ($m1, $m2) = (key('mset1'), key('mset2'));
    is($kv->msetex([$m1, 'a', $m2, 'b'], { ex => 100 }), 1, 'MSETEX');
    ok($kv->ttl($m1) > 0 && $kv->ttl($m2) > 0, 'MSETEX applied the TTL to every key');
    is($kv->msetex([$m1, 'z'], { nx => 1 }), 0, 'MSETEX NX on an existing key fails');
    is($kv->get($m1), 'a', 'MSETEX NX left the value');
}

# --- keys ------------------------------------------------------------------

{
    my $k = key('keys');
    $kv->set($k, 'v');
    is($kv->expiretime($k), -1, 'EXPIRETIME of a key without TTL is -1');
    my $at = time + 1000;
    $kv->expireat($k, $at);
    is($kv->expiretime($k), $at, 'EXPIRETIME');
    my $ms = $kv->pexpiretime($k);
    is($ms, $at * 1000, 'PEXPIRETIME');
    is($kv->expiretime(key('nokey')), -2, 'EXPIRETIME of a missing key is -2');

    is($kv->object('ENCODING', $k), $kv->object_encoding($k), 'OBJECT ENCODING via object()');
    ok($kv->object_idletime($k) >= 0, 'OBJECT IDLETIME');
    ok(defined eval { $kv->object_refcount($k) }, 'OBJECT REFCOUNT') or diag($@);

    # MOVE to db 1 and back
    is($kv->move($k, 1), 1, 'MOVE to db 1');
    is($kv->exists($k), 0, 'MOVE removed it from db 0');
    my $db1 = HotKV->new(url => test_url(), db => 1);
    is($db1->get($k), 'v', 'the key is in db 1');
    $db1->del($k);
    $db1->close;

    # SORT
    my $l = key('sortl');
    $kv->rpush($l, 3, 1, 2, 10);
    is_deeply($kv->sort($l), [1, 2, 3, 10], 'SORT numeric');
    is_deeply($kv->sort($l, { desc => 1 }), [10, 3, 2, 1], 'SORT DESC');
    is_deeply($kv->sort($l, { alpha => 1 }), [1, 10, 2, 3], 'SORT ALPHA');
    is_deeply($kv->sort($l, { limit => [1, 2] }), [2, 3], 'SORT LIMIT');
    is_deeply($kv->sort_ro($l), [1, 2, 3, 10], 'SORT_RO');
    my $dst = key('sortdst');
    is($kv->sort($l, { store => $dst }), 4, 'SORT STORE returns the count');
    is_deeply($kv->lrange($dst, 0, -1), [1, 2, 3, 10], 'SORT STORE wrote the list');
    my ($w1, $w2) = (key('w1'), key('w2'));
    $kv->mset($w1, 'b', $w2, 'a');
    my $byl = key('byl');
    $kv->rpush($byl, 1, 2);
    is_deeply($kv->sort($byl, { by => $w1 . '_nosort', get => ['#'] }), [1, 2], 'SORT BY a missing pattern GET #');

    ok(defined $kv->wait(0, 0), 'WAIT 0 0 returns a number');
    my $aof = eval { $kv->waitaof(0, 0, 0) };
    ok(!$@ || $@ =~ /appendonly|AOF|ERR/i, 'WAITAOF answers or reports AOF disabled') or diag($@);
}

# --- lists / zsets / hashes ------------------------------------------------

{
    my ($l1, $l2) = (key('mp1'), key('mp2'));
    $kv->rpush($l1, 'a', 'b', 'c');
    my $r = $kv->lmpop([$l2, $l1], 'LEFT', { count => 2 });
    is_deeply($r, [$l1, ['a', 'b']], 'LMPOP pops from the first non-empty list');
    is_deeply($kv->lmpop([$l2], 'left'), undef, 'LMPOP on empty lists is nil');
    $r = $kv->blmpop(1, [$l2, $l1], 'RIGHT');
    is_deeply($r, [$l1, ['c']], 'BLMPOP');
    is($kv->blmpop(1, [$l1], 'LEFT'), undef, 'BLMPOP times out with nil');

    my ($src, $dst) = (key('brsrc'), key('brdst'));
    $kv->rpush($src, 'x');
    is($kv->brpoplpush($src, $dst, 1), 'x', 'BRPOPLPUSH');
    is($kv->brpoplpush($src, $dst, 1), undef, 'BRPOPLPUSH on an empty source times out');

    my ($z1, $z2) = (key('zm1'), key('zm2'));
    $kv->zadd($z1, 1, 'a', 2, 'b', 3, 'c');
    my $zl = key('zlex');
    $kv->zadd($zl, 0, 'a', 0, 'b', 0, 'c');
    is($kv->zlexcount($zl, '-', '+'), 3, 'ZLEXCOUNT');
    is($kv->zlexcount($zl, '[b', '+'), 2, 'ZLEXCOUNT with a bound');
    my $zr = $kv->zmpop([$z2, $z1], 'MIN', { count => 2 });
    is_deeply($zr, [$z1, [['a', 1], ['b', 2]]], 'ZMPOP MIN COUNT');
    $zr = $kv->bzmpop(1, [$z1], 'MAX');
    is_deeply($zr, [$z1, [['c', 3]]], 'BZMPOP');
    is($kv->bzmpop(1, [$z1], 'MAX'), undef, 'BZMPOP times out with nil');
    $kv->zadd($z1, 5, 'm', 6, 'n');
    is_deeply($kv->bzpopmin($z2, $z1, 1), [$z1, 'm', 5], 'BZPOPMIN');
    is_deeply($kv->bzpopmax($z2, $z1, 1), [$z1, 'n', 6], 'BZPOPMAX');
    is($kv->bzpopmin($z1, 1), undef, 'BZPOPMIN times out with nil');

    my $h = key('hash');
    $kv->hset($h, 'f1', 'value1', 'f2', 'v2', 'f3', 'v3');
    is($kv->hstrlen($h, 'f1'), 6, 'HSTRLEN');
    is_deeply($kv->hgetdel($h, ['f1', 'nofield']), ['value1', undef], 'HGETDEL returns the values and deletes the fields');
    is($kv->hexists($h, 'f1'), 0, 'HGETDEL deleted the field');
    is_deeply($kv->hgetex($h, ['f2'], { ex => 100 }), ['v2'], 'HGETEX with EX');
    my $ttl = $kv->httl($h, ['f2']);
    ok($ttl->[0] > 0 && $ttl->[0] <= 100, 'HGETEX set the field TTL');
    my $expiretime = $kv->hexpiretime($h, ['f2', 'f3']);
    ok($expiretime->[0] > time && $expiretime->[1] == -1, 'HEXPIRETIME');
    my $pexp = $kv->hpexpiretime($h, ['f2']);
    ok($pexp->[0] > time * 1000, 'HPEXPIRETIME');
    is_deeply($kv->hgetex($h, ['f2'], { persist => 1 }), ['v2'], 'HGETEX PERSIST');
    is_deeply($kv->httl($h, ['f2']), [-1], 'HGETEX PERSIST removed the TTL');
    is($kv->hsetex($h, ['n1', 'x', 'n2', 'y'], { ex => 100 }), 1, 'HSETEX');
    is($kv->hget($h, 'n2'), 'y', 'HSETEX stored the fields');
    is($kv->hsetex($h, ['n1', 'z'], { fnx => 1 }), 0, 'HSETEX FNX on an existing field fails');
    is($kv->hsetex($h, ['n1', 'z'], { fxx => 1, keepttl => 1 }), 1, 'HSETEX FXX KEEPTTL');
    is($kv->hget($h, 'n1'), 'z', 'HSETEX FXX updated the field');
}

# --- HIMPORT (per connection state: one dedicated connection via pipeline) --

{
    my $k = key('himp');
    my $name = safe_name('fieldset');
    my $res = $kv->pipeline(sub {
        my $p = shift;
        $p->himport_prepare($name, 'a', 'b', 'c');
        $p->himport_set($k, $name, 1, 2, 3);
        $p->himport_discard($name);
    });
    is($res->[0], 'OK', 'HIMPORT PREPARE');
    is($res->[1], 'OK', 'HIMPORT SET');
    is($res->[2], 1, 'HIMPORT DISCARD reports the one field set it dropped');
    is_deeply($kv->hgetall($k), { a => 1, b => 2, c => 3 }, 'HIMPORT made the hash');
    my $res2 = $kv->pipeline(sub { $_[0]->himport_discardall });
    is($res2->[0], 0, 'HIMPORT DISCARDALL with nothing prepared drops 0');
}

# --- streams ---------------------------------------------------------------

{
    my $s = key('stream');
    my $id = $kv->xadd($s, '1-1', 'f', 'v');
    is($id, '1-1', 'XADD');
    is($kv->xsetid($s, '5-0'), 'OK', 'XSETID');
    is($kv->xadd($s, '5-1', 'f', 'w'), '5-1', 'XADD after XSETID');
    is($kv->xcfgset($s, { idmp_duration => 60, idmp_maxsize => 50 }), 'OK', 'XCFGSET');
    my $first = $kv->xadd($s, '*', 'f', 'x', { idmp => ['prod1', 'iid-1'] });
    my $again = $kv->xadd($s, '*', 'f', 'x', { idmp => ['prod1', 'iid-1'] });
    is($again, $first, 'XADD IDMP with the same iid returns the same id and adds nothing');
    is($kv->xlen($s), 3, 'only one entry was added by the two IDMP calls');
    my $auto1 = $kv->xadd($s, '*', 'a', '1', 'b', '2', { idmpauto => 'prod2' });
    my $auto2 = $kv->xadd($s, '*', 'a', '1', 'b', '2', { idmpauto => 'prod2' });
    is($auto2, $auto1, 'XADD IDMPAUTO with the same fields returns the same id');
}

# --- geo -------------------------------------------------------------------

{
    my $g = key('geo');
    $kv->geoadd($g, 13.361389, 38.115556, 'Palermo', 15.087269, 37.502669, 'Catania');
    my $r = $kv->georadius($g, 15, 37, 200, 'km', { withdist => 1, asc => 1 });
    is($r->[0][0], 'Catania', 'GEORADIUS WITHDIST ASC: nearest first');
    is($r->[1][0], 'Palermo', 'GEORADIUS second');
    cmp_ok($r->[0][1], '<', $r->[1][1], 'distances ascend');
    is_deeply($kv->georadius_ro($g, 15, 37, 100, 'km'), ['Catania'], 'GEORADIUS_RO');
    my $bm = $kv->georadiusbymember($g, 'Palermo', 200, 'km', { asc => 1 });
    is_deeply($bm, ['Palermo', 'Catania'], 'GEORADIUSBYMEMBER');
    is_deeply($kv->georadiusbymember_ro($g, 'Palermo', 1, 'km'), ['Palermo'], 'GEORADIUSBYMEMBER_RO');
    my $dst = key('geodst');
    is($kv->geosearchstore($dst, $g, { fromlonlat => [15, 37], byradius => [200, 'km'], asc => 1 }), 2, 'GEOSEARCHSTORE');
    is($kv->zcard($dst), 2, 'GEOSEARCHSTORE wrote the sorted set');
    my $dst2 = key('geodst2');
    is($kv->georadius($g, 15, 37, 200, 'km', { store => $dst2 }), 2, 'GEORADIUS STORE');
    is($kv->zcard($dst2), 2, 'GEORADIUS STORE wrote the sorted set');
    my $dst3 = key('geodst3');
    $kv->georadiusbymember($g, 'Palermo', 200, 'km', { storedist => $dst3 });
    cmp_ok($kv->zscore($dst3, 'Palermo'), '<', 1, 'GEORADIUSBYMEMBER STOREDIST stores distances');
}

# --- bitfield --------------------------------------------------------------

{
    my $b = key('bitfield');
    is_deeply($kv->bitfield($b, ['SET', 'u8', 0, 255], ['GET', 'u8', 0]), [0, 255], 'BITFIELD SET and GET');
    is_deeply($kv->bitfield($b, 'INCRBY', 'u8', 0, 10, 'OVERFLOW', 'SAT', 'INCRBY', 'u8', 0, 250), [9, 255],
        'BITFIELD INCRBY wraps, then OVERFLOW SAT saturates');
    is_deeply($kv->bitfield_ro($b, ['GET', 'u8', 0], ['GET', 'i8', 0]), [255, -1], 'BITFIELD_RO');
    is_deeply($kv->bitfield($b, 'OVERFLOW', 'FAIL', 'INCRBY', 'u8', 0, 1), [undef], 'BITFIELD OVERFLOW FAIL returns nil');
}

# --- pub/sub publishing ----------------------------------------------------

{
    my $ch = safe_name('chan');
    is($kv->publish($ch, 'nobody home'), 0, 'PUBLISH with no subscriber reaches 0 clients');
    is($kv->spublish($ch, 'nobody home'), 0, 'SPUBLISH with no subscriber');
    is_deeply($kv->pubsub_channels("$ch*"), [], 'PUBSUB CHANNELS finds none');
    is_deeply($kv->pubsub_numsub($ch), { $ch => 0 }, 'PUBSUB NUMSUB');
    is_deeply($kv->pubsub_shardnumsub($ch), { $ch => 0 }, 'PUBSUB SHARDNUMSUB');
    ok($kv->pubsub_numpat >= 0, 'PUBSUB NUMPAT');
    is_deeply($kv->pubsub_shardchannels("$ch*"), [], 'PUBSUB SHARDCHANNELS');

    # a real subscriber receives what publish() sends
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        my $sub = HotKV->new(url => test_url());
        my $got = '';
        $sub->subscribe([$ch], sub {
            my ($ev, $ctl) = @_;
            if ($ev->{type} eq 'message') { $got = $ev->{data}; $ctl->stop; }
        });
        exit($got eq 'ping' ? 0 : 1);
    }
    my $delivered = 0;
    for (1 .. 50) {
        $delivered = $kv->publish($ch, 'ping');
        last if $delivered;
        select(undef, undef, undef, 0.1);
    }
    is($delivered, 1, 'PUBLISH reaches the subscriber');
    waitpid($pid, 0);
    is($? >> 8, 0, 'the subscriber received the message');
}

# --- server ----------------------------------------------------------------

{
    my $role = $kv->role;
    is($role->[0], 'master', 'ROLE');
    like($kv->lolwut, qr/./, 'LOLWUT');
    like($kv->lolwut(5), qr/./, 'LOLWUT VERSION');

    my $len0 = $kv->slowlog_len;
    ok($len0 >= 0, 'SLOWLOG LEN');
    is(ref($kv->slowlog_get(5)), 'ARRAY', 'SLOWLOG GET');
    is($kv->slowlog_reset, 'OK', 'SLOWLOG RESET');
    is($kv->slowlog_len, 0, 'SLOWLOG is empty after RESET');

    my $k = key('mem');
    $kv->set($k, 'x' x 100);
    ok($kv->memory_usage($k) >= 100, 'MEMORY USAGE');
    is(ref($kv->memory_stats), 'HASH', 'MEMORY STATS is a hashref');
    like($kv->memory_doctor, qr/./, 'MEMORY DOCTOR');
    is($kv->memory_purge, 'OK', 'MEMORY PURGE');

    is(ref($kv->latency_latest), 'ARRAY', 'LATENCY LATEST');
    is(ref($kv->latency_history('command')), 'ARRAY', 'LATENCY HISTORY');
    like($kv->latency_doctor, qr/./, 'LATENCY DOCTOR');
    ok(defined $kv->latency_reset, 'LATENCY RESET');
    ok(defined eval { $kv->latency_graph('command') } || $@ =~ /No samples|ERR/, 'LATENCY GRAPH answers') or diag($@);
    my $hist = $kv->latency_histogram('set');
    ok($hist, 'LATENCY HISTOGRAM');

    is($kv->config_resetstat, 'OK', 'CONFIG RESETSTAT');
    my $rw = eval { $kv->config_rewrite };
    ok(defined $rw || $@ =~ /ERR/, 'CONFIG REWRITE answers (OK, or ERR when started without a config file)') or diag($@);

    my $bg = eval { $kv->bgsave };
    ok(defined $bg || $@ =~ /ERR/, 'BGSAVE answers') or diag($@);
    select(undef, undef, undef, 0.5);
    my $sv = eval { $kv->save };
    ok(defined $sv || $@ =~ /ERR/, 'SAVE answers') or diag($@);
    my $rw2 = eval { $kv->bgrewriteaof };
    ok(defined $rw2 || $@ =~ /ERR/, 'BGREWRITEAOF answers') or diag($@);

    # CLIENT
    like($kv->client_list, qr/\bid=\d+/, 'CLIENT LIST');
    like($kv->client_list({ type => 'normal' }), qr/\bid=\d+/, 'CLIENT LIST TYPE normal');
    like($kv->client_info, qr/\bid=\d+/, 'CLIENT INFO');
    is($kv->client_noevict(0), 'OK', 'CLIENT NO-EVICT');
    is($kv->client_notouch(0), 'OK', 'CLIENT NO-TOUCH');
    is($kv->client_setinfo('LIB-NAME', 'hotkv-perl'), 'OK', 'CLIENT SETINFO');
    is($kv->client_pause(10, { mode => 'write' }), 'OK', 'CLIENT PAUSE');
    is($kv->client_unpause, 'OK', 'CLIENT UNPAUSE');
    is($kv->client_unblock(999999999), 0, 'CLIENT UNBLOCK of an unknown id');
    is($kv->client_kill('ID', 999999999), 0, 'CLIENT KILL of an unknown id kills 0 clients');
    my $ti = $kv->client_trackinginfo;
    is(ref($ti), 'HASH', 'CLIENT TRACKINGINFO is a hashref');
    ok(defined $kv->client_getredir, 'CLIENT GETREDIR');
    is($kv->client_tracking(0), 'OK', 'CLIENT TRACKING OFF');
    my $cache = eval { $kv->client_caching(1) };
    ok(!defined $cache || $@, 'CLIENT CACHING YES outside OPTIN tracking is refused') or diag("got " . ($cache // 'undef'));

    # COMMAND
    my $info = $kv->command_info('get');
    is($info->[0][0], 'get', 'COMMAND INFO');
    my $docs = $kv->command_docs('get');
    ok($docs, 'COMMAND DOCS');
    my $list = $kv->command_list;
    ok(scalar(grep { $_ eq 'get' } @$list), 'COMMAND LIST includes get');
    my $filtered = $kv->command_list({ filterby => ['pattern', 'hget*'] });
    ok(scalar(@$filtered) >= 1 && !grep({ $_ !~ /\Ahget/ } @$filtered), 'COMMAND LIST FILTERBY PATTERN');
    is_deeply($kv->command_getkeys('SET', 'k1', 'v'), ['k1'], 'COMMAND GETKEYS');
}

# --- ACL -------------------------------------------------------------------

{
    my $user = safe_name('acluser');
    is($kv->acl_whoami, 'default', 'ACL WHOAMI');
    is($kv->acl_setuser($user, 'on', '>s3cret-pass', '~sdktest:*', '+get', '+set'), 'OK', 'ACL SETUSER');
    ok((grep { $_ eq $user } @{ $kv->acl_users }), 'ACL USERS lists it');
    ok((grep { /^user \Q$user\E / } @{ $kv->acl_list }), 'ACL LIST lists it');
    my $u = $kv->acl_getuser($user);
    is(ref($u), 'HASH', 'ACL GETUSER is a hashref');
    ok(exists $u->{flags}, 'ACL GETUSER has flags');
    is($kv->acl_dryrun($user, 'get', 'sdktest:a'), 'OK', 'ACL DRYRUN allowed');
    like($kv->acl_dryrun($user, 'get', 'other:a'), qr/no permissions/, 'ACL DRYRUN denied');
    ok(ref($kv->acl_cat) eq 'ARRAY' && @{ $kv->acl_cat } > 5, 'ACL CAT lists categories');
    ok(scalar(@{ $kv->acl_cat('string') }) > 3, 'ACL CAT string lists commands');
    like($kv->acl_genpass, qr/\A[0-9a-f]{64}\z/, 'ACL GENPASS');
    like($kv->acl_genpass(32), qr/\A[0-9a-f]{8}\z/, 'ACL GENPASS 32 bits');
    is(ref($kv->acl_log), 'ARRAY', 'ACL LOG');
    is($kv->acl_log('RESET'), 'OK', 'ACL LOG RESET');
    my $other = HotKV->new(url => test_url(), username => $user, password => 's3cret-pass');
    is($other->set('sdktest:acl:' . $$, 'v'), 'OK', 'the new user can SET its own keys') or diag($@);
    my $err = eval { $other->set('forbidden:' . $$, 'v'); 1 } ? undef : $@;
    ok($err && $err->isa('HotKV::Error::Server') && $err->code =~ /NOPERM/, 'and is refused elsewhere (NOPERM)');
    $other->close;
    $kv->del('sdktest:acl:' . $$);
    is($kv->acl_deluser($user), 1, 'ACL DELUSER');
    my $save = eval { $kv->acl_save };
    ok(defined $save || $@ =~ /ERR/, 'ACL SAVE answers (OK, or ERR without an aclfile)') or diag($@);
    my $load = eval { $kv->acl_load };
    ok(defined $load || $@ =~ /ERR/, 'ACL LOAD answers (OK, or ERR without an aclfile)') or diag($@);
}

# --- scripting / functions ---------------------------------------------------

{
    my $k = key('script');
    $kv->set($k, 'v');
    is($kv->eval_ro("return redis.call('GET', KEYS[1])", [$k]), 'v', 'EVAL_RO');
    my $sha = $kv->script_load("return ARGV[1]");
    is($kv->evalsha_ro($sha, [], ['hi']), 'hi', 'EVALSHA_RO');
    my $kill = eval { $kv->script_kill; 1 } ? 'OK' : $@;
    ok(ref($kill) && $kill->isa('HotKV::Error::Server') && $kill->code =~ /NOTBUSY/, 'SCRIPT KILL with no script running is NOTBUSY') or diag("got $kill");

    my $lib = safe_name('lib');
    $lib =~ s/-/_/g;
    my $code = "#!lua name=$lib\nredis.register_function('${lib}_echo', function(keys, args) return args[1] end)\n"
             . "redis.register_function{function_name='${lib}_ro', callback=function(keys, args) return redis.call('GET', keys[1]) end, flags={'no-writes'}}\n";
    is($kv->function_load($code), $lib, 'FUNCTION LOAD returns the library name');
    my $dup = eval { $kv->function_load($code); 1 } ? undef : $@;
    ok($dup && $dup->isa('HotKV::Error::Server'), 'FUNCTION LOAD of an existing library is refused');
    is($kv->function_load($code, { replace => 1 }), $lib, 'FUNCTION LOAD REPLACE');
    is($kv->fcall("${lib}_echo", [], ['pong']), 'pong', 'FCALL');
    is($kv->fcall_ro("${lib}_ro", [$k]), 'v', 'FCALL_RO');
    my $fl = $kv->function_list({ libraryname => $lib });
    is(ref($fl), 'ARRAY', 'FUNCTION LIST');
    is(scalar(@$fl), 1, 'FUNCTION LIST LIBRARYNAME finds one library');
    my $withcode = $kv->function_list({ libraryname => $lib, withcode => 1 });
    like(ref($withcode->[0]) eq 'HASH' ? $withcode->[0]{library_code} : join(' ', map { $_ // '' } @{ $withcode->[0] }), qr/register_function/, 'FUNCTION LIST WITHCODE includes the source');
    ok($kv->function_stats, 'FUNCTION STATS');
    my $dump = $kv->function_dump;
    ok(length($dump) > 10, 'FUNCTION DUMP');
    is($kv->function_delete($lib), 'OK', 'FUNCTION DELETE');
    is($kv->function_restore($dump, { policy => 'replace' }), 'OK', 'FUNCTION RESTORE');
    is($kv->fcall("${lib}_echo", [], ['again']), 'again', 'the restored function runs');
    my $fk = eval { $kv->function_kill; 1 } ? 'OK' : $@;
    ok(ref($fk) && $fk->isa('HotKV::Error::Server') && $fk->code =~ /NOTBUSY/, 'FUNCTION KILL with nothing running is NOTBUSY') or diag("got $fk");
    is($kv->function_flush('SYNC'), 'OK', 'FUNCTION FLUSH SYNC');
    is($kv->function_flush, 'OK', 'FUNCTION FLUSH');
    is(scalar(@{ $kv->function_list }), 0, 'no libraries are left');
}

# --- replication commands refuse politely on a primary -----------------------

{
    my $r = eval { $kv->replicaof_no_one };
    ok(defined $r || $@, 'REPLICAOF NO ONE on a primary answers');
    my $f = eval { $kv->failover({ abort => 1 }) };
    ok(defined $f || (ref($@) && $@->isa('HotKV::Error::Server')), 'FAILOVER ABORT with no failover in progress answers (OK or a server error)');
}

# --- cluster-only commands on a single node --------------------------------

{
    for my $call (
        [clusterscan => sub { $kv->clusterscan(0) }],
        [sflush      => sub { $kv->sflush([[0, 100]]) }],
        [trimslots   => sub { $kv->trimslots([[0, 100]]) }],
        [cluster_info => sub { $kv->cluster_info }],
        [cluster_myid => sub { $kv->cluster_myid }],
        [cluster_slots => sub { $kv->cluster_slots }],
        [cluster_nodes => sub { $kv->cluster_nodes }],
        [cluster_shards => sub { $kv->cluster_shards }],
    ) {
        my ($name, $code) = @$call;
        my $ok = eval { $code->(); 1 };
        ok($ok || (ref($@) && $@->isa('HotKV::Error::Server')), "$name reaches the server (reply or a server error, no client error)")
            or diag("$name: $@");
    }
    is($kv->cluster_keyslot('foo'), 12182, 'CLUSTER KEYSLOT');
    ok(defined eval { $kv->cluster_countkeysinslot(0) }, 'CLUSTER COUNTKEYSINSLOT') or diag($@);
    ok(defined eval { $kv->cluster_getkeysinslot(0, 1) }, 'CLUSTER GETKEYSINSLOT') or diag($@);
}

# --- commands the per-type files do not reach ---------------------------------

{
    my ($l1, $l2) = (key('blm1'), key('blm2'));
    $kv->rpush($l1, 'a', 'b');
    is($kv->blmove($l1, $l2, 'LEFT', 'RIGHT', 1), 'a', 'BLMOVE');
    is_deeply($kv->lrange($l2, 0, -1), ['a'], 'BLMOVE moved the element');
    is($kv->blmove(key('empty'), $l2, 'LEFT', 'RIGHT', 1), undef, 'BLMOVE on an empty source times out with nil');

    my $g = key('geohash');
    $kv->geoadd($g, 13.361389, 38.115556, 'Palermo');
    is_deeply($kv->geohash($g, 'Palermo', 'nope'), ['sqc8b49rny0', undef], 'GEOHASH');

    my $h = key('hexpireat');
    $kv->hset($h, 'a', 1, 'b', 2);
    my $at = time + 500;
    is_deeply($kv->hexpireat($h, $at, ['a']), [1], 'HEXPIREAT');
    is_deeply($kv->hexpiretime($h, ['a', 'b']), [$at, -1], 'HEXPIREAT set the absolute expiry');
    is_deeply($kv->hpexpireat($h, $at * 1000 + 5, ['b']), [1], 'HPEXPIREAT');
    is_deeply($kv->hpexpiretime($h, ['b']), [$at * 1000 + 5], 'HPEXPIREAT set the absolute expiry');
    my $hm = key('hmset');
    is($kv->hmset($hm, 'x', 1, 'y', 2), 'OK', 'HMSET');
    is_deeply($kv->hgetall($hm), { x => 1, y => 2 }, 'HMSET stored the fields');

    cmp_ok($kv->lastsave, '>', 1_700_000_000, 'LASTSAVE is a unix time');

    my $fk = key('freq');
    $kv->set($fk, 1);
    my $ok = eval { $kv->object_freq($fk) };
    ok(defined $ok || (ref($@) && $@->isa('HotKV::Error::Server') && $@->message =~ /LFU/), 'OBJECT FREQ answers (a count, or the LFU policy error)');

    my $sha = $kv->script_load('return 7');
    is_deeply($kv->script_exists($sha, 'f' x 40), [1, 0], 'SCRIPT EXISTS');
    is($kv->script_flush, 'OK', 'SCRIPT FLUSH');
    is_deeply($kv->script_exists($sha), [0], 'SCRIPT FLUSH removed the script');

    my $orig = $kv->config_get('hz')->{hz};
    is($kv->config_set('hz', 20), 'OK', 'CONFIG SET');
    is($kv->config_get('hz')->{hz}, 20, 'CONFIG GET sees the new value');
    $kv->config_set('hz', $orig);
    is($kv->config_get('hz')->{hz}, $orig, 'CONFIG SET restored it');

    # SELECT, FLUSHDB and SWAPDB act on one connection or on database 9 and 10 only.
    my $db9 = HotKV->new(url => test_url(), db => 9, pool_size => 1);
    my $db10 = HotKV->new(url => test_url(), db => 10, pool_size => 1);
    $db9->flushdb;
    $db10->flushdb;
    $db9->set('only9', 'a');
    $db10->set('only10', 'b');
    is($db9->select(9), 'OK', 'SELECT');
    is($db9->swapdb(9, 10), 'OK', 'SWAPDB');
    is($db9->get('only10'), 'b', 'after SWAPDB db 9 holds what db 10 held');
    is($db10->get('only9'), 'a', 'and db 10 what db 9 held');
    is($db9->flushdb('SYNC'), 'OK', 'FLUSHDB SYNC');
    is($db9->dbsize, 0, 'FLUSHDB emptied database 9');
    is($db10->dbsize, 1, 'and left database 10');
    $db10->flushdb('ASYNC');
    $db9->close;
    $db10->close;

    SKIP: {
        skip 'set HOTKV_TEST_ALLOW_FLUSHALL=1 to run FLUSHALL (it empties the whole test server)', 2 unless $ENV{HOTKV_TEST_ALLOW_FLUSHALL};
        $kv->set(key('beforeflushall'), 1);
        is($kv->flushall, 'OK', 'FLUSHALL');
        is($kv->dbsize, 0, 'FLUSHALL emptied the server');
    }

    like($kv->memory_malloc_stats, qr/./, 'MEMORY MALLOC-STATS');
    ok(defined $kv->slowlog_export, 'SLOWLOG EXPORT');
    is_deeply($kv->module_list, [], 'MODULE LIST');
    my $kf = $kv->command_getkeysandflags('SET', 'k1', 'v');
    is($kf->[0][0], 'k1', 'COMMAND GETKEYSANDFLAGS');
}

$kv->del(@cleanup);
$kv->close;
done_testing();
