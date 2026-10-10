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
my $s  = unique_name('stream');

my $id1 = $kv->xadd($s, '*', 'field1', 'a');
like($id1, qr/^\d+-\d+$/, 'XADD returns a stream id');
my $id2 = $kv->xadd($s, '*', 'field1', 'b');
is($kv->xlen($s), 2, 'XLEN');

my $range = $kv->xrange($s, '-', '+');
is(scalar(@$range), 2, 'XRANGE full range returns both entries');
is($range->[0][0], $id1, 'XRANGE first entry id matches insertion order');

my $rev = $kv->xrevrange($s, '+', '-');
is($rev->[0][0], $id2, 'XREVRANGE starts with the newest entry');

is($kv->xrange($s, '-', '+', { count => 1 })->[0][0], $id1, 'XRANGE COUNT limits results');

# XREAD: under the negotiated RESP3 protocol the server replies with a map
# of stream name -> entries (RESP2 would instead be an array of
# [name, entries] pairs; HotKV::Protocol::Reader decodes whichever the wire
# actually sends, see HotKV::Protocol).
my $read = $kv->xread([$s], ['0']);
is(ref($read), 'HASH', 'XREAD returns a hashref of stream name to entries (RESP3 map)');
ok(exists $read->{$s}, 'XREAD result is keyed by the stream name');
is(scalar(@{ $read->{$s} }), 2, 'XREAD from 0 returns all entries');

# Consumer groups: XGROUP / XREADGROUP / XACK / XPENDING / XCLAIM / XAUTOCLAIM
is($kv->xgroup_create($s, 'g1', '0'), 'OK', 'XGROUP CREATE');
my $gread = $kv->xreadgroup('g1', 'consumer1', [$s], ['>']);
is(scalar(@{ $gread->{$s} }), 2, 'XREADGROUP delivers all pending entries to the first consumer');

my $pending = $kv->xpending($s, 'g1');
is($pending->[0], 2, 'XPENDING summary: 2 pending entries');

is($kv->xack($s, 'g1', $id1), 1, 'XACK acknowledges one entry');
$pending = $kv->xpending($s, 'g1');
is($pending->[0], 1, 'XPENDING summary reflects the ack');

my $detailed = $kv->xpending($s, 'g1', { start => '-', end => '+', count => 10 });
is(scalar(@$detailed), 1, 'XPENDING extended form lists the one still-pending entry');

my $claimed = $kv->xclaim($s, 'g1', 'consumer2', 0, [$id2]);
is(scalar(@$claimed), 1, 'XCLAIM claims the pending entry for another consumer');
is($claimed->[0][0], $id2, 'XCLAIM returns the claimed entry id');

is($kv->xgroup_createconsumer($s, 'g1', 'consumer3'), 1, 'XGROUP CREATECONSUMER');
is($kv->xgroup_delconsumer($s, 'g1', 'consumer3'), 0, 'XGROUP DELCONSUMER on an idle consumer');

my $auto = $kv->xautoclaim($s, 'g1', 'consumer1', 0, '0');
is(ref($auto), 'ARRAY', 'XAUTOCLAIM returns an arrayref');

my $info = $kv->xinfo_stream($s);
is(ref($info), 'HASH', 'XINFO STREAM returns a hashref (RESP3 map)');
my $groups = $kv->xinfo_groups($s);
is(scalar(@$groups), 1, 'XINFO GROUPS lists the one group');
my $consumers = $kv->xinfo_consumers($s, 'g1');
ok(scalar(@$consumers) >= 1, 'XINFO CONSUMERS lists at least one consumer');

is($kv->xgroup_setid($s, 'g1', '0'), 'OK', 'XGROUP SETID');
is($kv->xack($s, 'g1', $id2), 1, 'XACK the second entry too');

# XDEL / XTRIM
my $id3 = $kv->xadd($s, '*', 'field1', 'c');
is($kv->xdel($s, $id3), 1, 'XDEL');
is($kv->xlen($s), 2, 'XLEN reflects the XDEL (back down to 2: id1 and id2)');
$kv->xadd($s, '*', 'f', $_) for (1 .. 5);
is($kv->xlen($s), 7, 'XLEN after adding 5 more entries');
is($kv->xtrim($s, { maxlen => 2 }), 5, 'XTRIM MAXLEN trims 7 entries down to 2 (5 removed)');
is($kv->xlen($s), 2, 'XLEN reflects the trim');

is($kv->xgroup_destroy($s, 'g1'), 1, 'XGROUP DESTROY');

$kv->del($s);
$kv->close;
done_testing();
