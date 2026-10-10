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
my $z  = unique_name('zset');

is($kv->zadd($z, 1, 'a', 2, 'b', 3, 'c'), 3, 'ZADD');
is($kv->zscore($z, 'b'), 2, 'ZSCORE');
is_deeply($kv->zmscore($z, 'a', 'c', 'missing'), [1, 3, undef], 'ZMSCORE');
is($kv->zcard($z), 3, 'ZCARD');
is($kv->zcount($z, 1, 2), 2, 'ZCOUNT');
is($kv->zincrby($z, 5, 'a'), 6, 'ZINCRBY');
is($kv->zscore($z, 'a'), 6, 'ZSCORE reflects ZINCRBY');
$kv->zadd($z, 1, 'a'); # put it back for the range tests below

# ZADD flags: NX / XX / GT / LT / CH / INCR
is($kv->zadd($z, 100, 'a', { nx => 1 }), 0, 'ZADD NX does not touch an existing member');
is($kv->zscore($z, 'a'), 1, 'score unchanged after ZADD NX on existing member');
is($kv->zadd($z, 100, 'nope', { xx => 1 }), 0, 'ZADD XX does not add a new member');
is($kv->exists($z . ':nope'), 0, 'ZADD XX truly added nothing');
is($kv->zadd($z, 0, 'a', { gt => 1, ch => 1 }), 0, 'ZADD GT refuses to lower the score (CH: 0 changed)');
is($kv->zadd($z, 50, 'a', { gt => 1, ch => 1 }), 1, 'ZADD GT raises the score (CH: 1 changed)');
is($kv->zscore($z, 'a'), 50, 'score raised by ZADD GT');
is($kv->zadd($z, 5, 'a', { incr => 1 }), 55, 'ZADD INCR returns the new score');
$kv->zadd($z, 1, 'a'); # reset for range tests

# --- ZRANGE BYSCORE / BYLEX / REV / LIMIT / WITHSCORES ---------------------

is_deeply($kv->zrange($z, 0, -1), ['a', 'b', 'c'], 'ZRANGE plain index range');
is_deeply(
    $kv->zrange($z, 0, -1, { withscores => 1 }),
    [['a', 1], ['b', 2], ['c', 3]],
    'ZRANGE WITHSCORES (RESP3 array-of-pairs)'
);
is_deeply($kv->zrange($z, 1, 3, { byscore => 1 }), ['a', 'b', 'c'], 'ZRANGE BYSCORE');
is_deeply($kv->zrange($z, '(1', 3, { byscore => 1 }), ['b', 'c'], 'ZRANGE BYSCORE exclusive min');
is_deeply($kv->zrange($z, 3, 1, { byscore => 1, rev => 1 }), ['c', 'b', 'a'], 'ZRANGE BYSCORE REV');
is_deeply($kv->zrange($z, 1, 3, { byscore => 1, limit => [1, 1] }), ['b'], 'ZRANGE BYSCORE LIMIT offset count');
is_deeply($kv->zrangebyscore($z, 1, 2), ['a', 'b'], 'ZRANGEBYSCORE');
is_deeply($kv->zrevrangebyscore($z, 2, 1), ['b', 'a'], 'ZREVRANGEBYSCORE');

my $zl = unique_name('zlex');
$kv->zadd($zl, 0, 'a', 0, 'b', 0, 'c', 0, 'd');
is_deeply($kv->zrange($zl, '[a', '[c', { bylex => 1 }), ['a', 'b', 'c'], 'ZRANGE BYLEX inclusive range');
is_deeply($kv->zrange($zl, '(a', '[c', { bylex => 1 }), ['b', 'c'], 'ZRANGE BYLEX exclusive min');
is_deeply($kv->zrangebylex($zl, '-', '+'), ['a', 'b', 'c', 'd'], 'ZRANGEBYLEX full range');
is_deeply($kv->zrevrangebylex($zl, '+', '-'), ['d', 'c', 'b', 'a'], 'ZREVRANGEBYLEX full range reversed');
is_deeply($kv->zrevrange($z, 0, -1), ['c', 'b', 'a'], 'ZREVRANGE');
is_deeply($kv->zrevrange($z, 0, -1, { withscores => 1 }), [['c', 3], ['b', 2], ['a', 1]], 'ZREVRANGE WITHSCORES');

# --- ZRANGESTORE (explicitly required to behave like the standard command) ----------

my $zdst = unique_name('zdst');
is($kv->zrangestore($zdst, $z, 1, 2, { byscore => 1 }), 2, 'ZRANGESTORE BYSCORE');
is_deeply($kv->zrange($zdst, 0, -1, { withscores => 1 }), [['a', 1], ['b', 2]], 'ZRANGESTORE BYSCORE result');

my $zldst = unique_name('zldst');
is($kv->zrangestore($zldst, $zl, '[a', '[b', { bylex => 1 }), 2, 'ZRANGESTORE BYLEX');
is_deeply($kv->zrange($zldst, 0, -1), ['a', 'b'], 'ZRANGESTORE BYLEX result');

# --- ZRANK / ZREVRANK / ZPOPMIN / ZPOPMAX / ZRANDMEMBER ---------------------

is($kv->zrank($z, 'b'), 1, 'ZRANK');
is($kv->zrevrank($z, 'b'), 1, 'ZREVRANK');
is_deeply($kv->zrank($z, 'b', { withscore => 1 }), [1, 2], 'ZRANK WITHSCORE');
is_deeply($kv->zpopmin($z), ['a', 1], 'ZPOPMIN');
is_deeply($kv->zpopmax($z), ['c', 3], 'ZPOPMAX');
ok(defined $kv->zrandmember($zl), 'ZRANDMEMBER');

# --- ZREM / ZREMRANGEBY* ----------------------------------------------------

my $zr = unique_name('zrem');
$kv->zadd($zr, 1, 'a', 2, 'b', 3, 'c', 4, 'd', 5, 'e');
is($kv->zrem($zr, 'a'), 1, 'ZREM');
is($kv->zremrangebyscore($zr, 4, 5), 2, 'ZREMRANGEBYSCORE');
is($kv->zremrangebyrank($zr, 0, 0), 1, 'ZREMRANGEBYRANK');
$kv->zadd($zr, 9, 'zz');
is($kv->zremrangebylex($zr, '[zz', '[zz'), 1, 'ZREMRANGEBYLEX');

# --- ZUNIONSTORE / ZINTERSTORE with WEIGHTS and AGGREGATE -----------------

my $za = unique_name('za');
my $zb = unique_name('zb');
$kv->zadd($za, 1, 'x', 2, 'y');
$kv->zadd($zb, 10, 'y', 20, 'z');
my $zu = unique_name('zu');
is($kv->zunionstore($zu, [$za, $zb], { weights => [1, 2], aggregate => 'sum' }), 3, 'ZUNIONSTORE WEIGHTS/AGGREGATE');
is($kv->zscore($zu, 'y'), 2 + 20, 'ZUNIONSTORE weighted sum for a shared member');
is($kv->zscore($zu, 'z'), 40, 'ZUNIONSTORE weighted score for a non-shared member');

my $zi = unique_name('zi');
is($kv->zinterstore($zi, [$za, $zb], { aggregate => 'max' }), 1, 'ZINTERSTORE AGGREGATE MAX');
is($kv->zscore($zi, 'y'), 10, 'ZINTERSTORE max of the two scores');

is_deeply([sort @{ $kv->zunion([$za, $zb]) }], ['x', 'y', 'z'], 'ZUNION (no store)');
is_deeply($kv->zinter([$za, $zb]), ['y'], 'ZINTER (no store)');
is_deeply($kv->zdiff([$za, $zb]), ['x'], 'ZDIFF (no store)');
my $zdiffstore_dst = unique_name('zdiffstore');
is($kv->zdiffstore($zdiffstore_dst, [$za, $zb]), 1, 'ZDIFFSTORE');
is($kv->zintercard([$za, $zb]), 1, 'ZINTERCARD');

# ZSCAN
my $zs = unique_name('zscan');
$kv->zadd($zs, 1, 'p', 2, 'q');
my $reply = $kv->zscan($zs, 0);
is($reply->[0], '0', 'ZSCAN cursor is 0 after a single small collection scan');
my @flat = @{ $reply->[1] };
my %scanned = @flat;
is_deeply(\%scanned, { p => 1, q => 2 }, 'ZSCAN returns flat member/score pairs');

$kv->del($z, $zl, $zdst, $zldst, $zr, $za, $zb, $zu, $zi, $zdiffstore_dst, $zs);
$kv->close;
done_testing();
