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
my $k1 = unique_name('t1');
my $k2 = unique_name('t2');

# --- basic MULTI/EXEC ----------------------------------------------------

my $results = $kv->multi(sub {
    my $tx = shift;
    $tx->set($k1, 'a');
    $tx->incr($k2);
    $tx->incr($k2);
});
is_deeply($results, ['OK', 1, 2], 'multi() returns results for every queued command, in order');
is($kv->get($k1), 'a', 'the transaction actually committed');

# --- DISCARD: an exception inside the block aborts the transaction --------

$kv->set($k1, 'before-discard');
my $err = eval {
    $kv->multi(sub {
        my $tx = shift;
        $tx->set($k1, 'should-not-stick');
        die "boom mid-transaction\n";
    });
    1;
} ? undef : $@;
ok($err, 'an exception inside the block propagates');
like("$err", qr/boom mid-transaction/, 'the original exception text is preserved');
is($kv->get($k1), 'before-discard', 'the transaction was discarded, not committed');

# --- WATCH / UNWATCH: unrelated write does not abort -----------------------

$kv->set($k1, 'watched-value');
{
    my $tx = $kv->watch($k1);
    is($tx->get($k1), 'watched-value', 'reads on a watching transaction run immediately, not queued');
    my $r = $tx->multi(sub {
        my $t = shift;
        $t->set($k1, 'updated-by-tx');
    });
    is_deeply($r, ['OK'], 'multi() after watch() commits normally when the watched key is untouched');
}
is($kv->get($k1), 'updated-by-tx', 'the watched-and-committed value stuck');

# --- WATCH: a concurrent write to the watched key aborts EXEC (returns undef) --

$kv->set($k1, 'v0');
{
    my $tx = $kv->watch($k1);
    # Simulate another client modifying the watched key between WATCH and EXEC.
    my $other = HotKV->new(url => test_url());
    $other->set($k1, 'changed-by-someone-else');
    $other->close;

    my $r = $tx->multi(sub {
        my $t = shift;
        $t->set($k1, 'should-not-apply');
    });
    is($r, undef, 'EXEC returns undef (nil) when a watched key changed');
}
is($kv->get($k1), 'changed-by-someone-else', 'the aborted transaction did not overwrite the concurrent change');

# --- unwatch releases without transacting -----------------------------

{
    my $tx = $kv->watch($k1);
    $tx->unwatch;
    pass('unwatch() completes without error');
}

$kv->del($k1, $k2);
$kv->close;
done_testing();
