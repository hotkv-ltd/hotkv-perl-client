# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());

# --- server ----------------------------------------------------------------

is($kv->ping, 'PONG', 'PING');
is($kv->ping('hello'), 'hello', 'PING with a message echoes it');
is($kv->echo('hi there'), 'hi there', 'ECHO');
my $info = $kv->info;
like($info, qr/redis_version|hotkv_version/, 'INFO returns a text blob (RESP3 verbatim string decoded to plain text)');
ok($kv->dbsize >= 0, 'DBSIZE');
my $time = $kv->time;
is(scalar(@$time), 2, 'TIME returns [seconds, microseconds]');
ok($time->[0] > 1_700_000_000, 'TIME seconds looks like a real unix timestamp');

my $cfg = $kv->config_get('maxmemory');
is(ref($cfg), 'HASH', 'CONFIG GET returns a hashref (RESP3 map)');

is($kv->client_setname('perl-sdk-test'), 'OK', 'CLIENT SETNAME');
is($kv->client_getname, 'perl-sdk-test', 'CLIENT GETNAME reflects it');
ok($kv->client_id > 0, 'CLIENT ID is a positive integer');
ok($kv->command_count > 0, 'COMMAND COUNT is positive');

# --- SCAN family -------------------------------------------------------

my $prefix = unique_name('scan');
$kv->set("$prefix:$_", $_) for (1 .. 5);
my %found;
my $cursor = 0;
do {
    my $reply = $kv->scan($cursor, { match => "$prefix:*", count => 100 });
    $cursor = $reply->[0];
    $found{$_} = 1 for @{ $reply->[1] };
} while ($cursor ne '0');
is(scalar(CORE::keys %found), 5, 'SCAN with MATCH finds all 5 keys eventually');

my $it = $kv->scan_iterator(match => "$prefix:*", count => 100);
my @iterated;
while (defined(my $k = $it->())) { push @iterated, $k; }
is(scalar(@iterated), 5, 'scan_iterator visits every matching key exactly once overall');

$kv->sadd("$prefix:set", 'x', 'y', 'z');
my $sit = $kv->sscan_iterator("$prefix:set");
my @smembers_seen;
while (defined(my $m = $sit->())) { push @smembers_seen, $m; }
is_deeply([sort @smembers_seen], ['x', 'y', 'z'], 'sscan_iterator visits every member');

$kv->zadd("$prefix:zset", 1, 'p', 2, 'q');
my $zit = $kv->zscan_iterator("$prefix:zset");
my %zseen;
while (defined(my $m = $zit->())) { $zseen{$m} = $zit->(); } # member, then score
is_deeply(\%zseen, { p => 1, q => 2 }, 'zscan_iterator visits every member/score pair');

$kv->del("$prefix:$_") for (1 .. 5);
$kv->del("$prefix:set", "$prefix:zset");

# --- scripting -----------------------------------------------------------

my $eval_ok = eval { $kv->eval_script('return 1', [], []); 1 };
SKIP: {
    skip 'EVAL/scripting not available on this server build', 5 unless $eval_ok;

    is($kv->eval_script('return 1', [], []), 1, 'EVAL trivial script');
    is($kv->eval_script('return ARGV[1]', [], ['hello']), 'hello', 'EVAL with ARGV');
    my $ek = unique_name('evalkey');
    is($kv->eval_script('return redis.call("SET", KEYS[1], ARGV[1])', [$ek], ['via-eval']), 'OK', 'EVAL calling redis.call with KEYS');
    is($kv->get($ek), 'via-eval', 'EVAL script actually wrote the key');

    my $sha = $kv->script_load('return 2');
    is($kv->evalsha($sha, [], []), 2, 'SCRIPT LOAD + EVALSHA');
    $kv->del($ek);
}

$kv->close;
done_testing();
