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
my $k  = unique_name('list');

is($kv->rpush($k, 'a', 'b', 'c'), 3, 'RPUSH');
is($kv->lpush($k, 'z'), 4, 'LPUSH');
is($kv->llen($k), 4, 'LLEN');
is_deeply($kv->lrange($k, 0, -1), ['z', 'a', 'b', 'c'], 'LRANGE full');
is($kv->lindex($k, 1), 'a', 'LINDEX');
is($kv->lset($k, 1, 'A'), 'OK', 'LSET');
is($kv->lindex($k, 1), 'A', 'LINDEX after LSET');
is($kv->linsert($k, 'before', 'A', 'PRE'), 5, 'LINSERT BEFORE');
is_deeply($kv->lrange($k, 0, -1), ['z', 'PRE', 'A', 'b', 'c'], 'LRANGE after LINSERT');
is($kv->lrem($k, 1, 'PRE'), 1, 'LREM');
is($kv->ltrim($k, 0, 2), 'OK', 'LTRIM');
is_deeply($kv->lrange($k, 0, -1), ['z', 'A', 'b'], 'LRANGE after LTRIM');

is($kv->lpop($k), 'z', 'LPOP single');
is($kv->rpop($k), 'b', 'RPOP single');
is($kv->lpushx($k, 'x'), 2, 'LPUSHX on an existing key');
$kv->del($k . ':missing');
is($kv->lpushx($k . ':missing', 'x'), 0, 'LPUSHX on a missing key is a no-op');
is($kv->rpushx($k, 'y'), 3, 'RPUSHX on an existing key');
is_deeply($kv->lpop($k, 2), ['x', 'A'], 'LPOP with a count');

$kv->del($k);
$kv->rpush($k, 'a', 'b', 'c', 'b');
is($kv->lpos($k, 'b'), 1, 'LPOS');
is_deeply($kv->lpos($k, 'b', { count => 0 }), [1, 3], 'LPOS with COUNT 0 (all matches)');

# RPOPLPUSH / LMOVE
my $src = unique_name('src');
my $dst = unique_name('dst');
$kv->rpush($src, 'one', 'two', 'three');
is($kv->rpoplpush($src, $dst), 'three', 'RPOPLPUSH');
is_deeply($kv->lrange($dst, 0, -1), ['three'], 'RPOPLPUSH destination');
is($kv->lmove($src, $dst, 'left', 'right'), 'one', 'LMOVE LEFT RIGHT');
is_deeply($kv->lrange($dst, 0, -1), ['three', 'one'], 'LMOVE destination order');

# Blocking pops with an immediately-available element return right away.
$kv->del($src);
$kv->rpush($src, 'ready');
is_deeply($kv->blpop($src, 1), [$src, 'ready'], 'BLPOP returns immediately when data is present');
is($kv->blpop($src . ':empty-' . $$, 1), undef, 'BLPOP times out on an empty list (nil)');

$kv->del($k, $src, $dst, $k . ':missing');
$kv->close;
done_testing();
