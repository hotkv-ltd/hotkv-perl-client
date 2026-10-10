# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# The test server runs standalone, not as a HotKV Cluster, so this only
# checks the parts of HotKV::Cluster that behave sensibly against a real,
# non-cluster server: CLUSTER SLOTS/SHARDS discovery fails clearly instead
# of hanging or crashing, and, once a slot map is seeded by hand to point
# everywhere at the one real server, ordinary commands are correctly
# proxied end to end over a real socket. MOVED/ASK redirect handling and
# slot routing math are covered without a server at all in
# t/06-cluster-unit.t.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV::Cluster;
use HotKV::Connection;

my $opts = HotKV::Connection::parse_url(test_url());

{
    my $cluster = HotKV::Cluster->new(nodes => ["$opts->{host}:$opts->{port}"]);
    my $err = eval { $cluster->refresh_slots; 1 } ? undef : $@;
    ok($err, 'refresh_slots against a standalone (non-cluster) server fails clearly rather than hanging');
    like("$err", qr/could not discover cluster slots/, 'the error explains why');
    $cluster->close;
}

{
    my $cluster = HotKV::Cluster->new(nodes => ["$opts->{host}:$opts->{port}"], %$opts);
    # Seed the slot map by hand (every slot -> the one real test server) so
    # routing goes over an actual socket instead of exercising CLUSTER
    # SLOTS discovery, which this standalone server cannot answer.
    $cluster->{slots} = [{
        start => 0, end => 16383,
        master => { host => $opts->{host}, port => $opts->{port} },
        replicas => [],
    }];

    my $k1 = unique_name('cluster-a');
    my $k2 = unique_name('cluster-b');
    is($cluster->set($k1, 'v1'), 'OK', 'SET routed through HotKV::Cluster over a real socket');
    is($cluster->get($k1), 'v1', 'GET routed through HotKV::Cluster over a real socket');
    is($cluster->incr($k2), 1, 'a second, differently-slotted key also routes correctly');
    is($cluster->tag->set($k1, 'red'), 1, 'a HotKV family command also routes through the cluster client');
    is($cluster->ping, 'PONG', 'a key-less command (PING) also routes through the cluster client');

    $cluster->del($k1, $k2);
    $cluster->close;
}

done_testing();
