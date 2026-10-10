# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# Unit tests for HotKV::Cluster's routing and redirect handling. No live
# cluster is required: HotKV::Connection::connect/command/close are
# replaced with an in-memory mock for the duration of this file so the
# MOVED/ASK/bounded-redirect logic can be exercised deterministically.

use strict;
use warnings;
use Test::More;

use HotKV::Cluster;
use HotKV::Error;

# --- pure parsing / routing helpers, no mocking needed --------------------

{
    my $reply = [
        [0, 8191, ['10.0.0.1', 6379], ['10.0.0.2', 6379]],
        [8192, 16383, ['10.0.0.3', 6379]],
    ];
    my $slots = HotKV::Cluster::_parse_cluster_slots($reply);
    is(scalar(@$slots), 2, '_parse_cluster_slots returns one entry per range');
    is($slots->[0]{start}, 0, 'first range start');
    is($slots->[0]{end}, 8191, 'first range end');
    is($slots->[0]{master}{host}, '10.0.0.1', 'first range master host');
    is($slots->[0]{master}{port}, 6379, 'first range master port');
    is(scalar(@{ $slots->[0]{replicas} }), 1, 'first range has one replica');
    is($slots->[0]{replicas}[0]{host}, '10.0.0.2', 'first range replica host');
    is(scalar(@{ $slots->[1]{replicas} }), 0, 'second range has no replicas');
}

{
    is_deeply(HotKV::Cluster::_parse_cluster_slots([]), [], 'empty CLUSTER SLOTS reply parses to no ranges');
}

{
    my $shards = [
        {
            slots => [0, 8191],
            nodes => [
                { ip => '10.0.0.1', port => 6379, role => 'master' },
                { ip => '10.0.0.2', port => 6379, role => 'replica' },
            ],
        },
    ];
    my $slots = HotKV::Cluster::_parse_cluster_shards($shards);
    is(scalar(@$slots), 1, '_parse_cluster_shards: one range for one shard');
    is($slots->[0]{master}{host}, '10.0.0.1', 'shard master host');
    is($slots->[0]{replicas}[0]{host}, '10.0.0.2', 'shard replica host');
}

{
    my $cluster = HotKV::Cluster->new(nodes => ['seed.example:6379']);
    $cluster->{slots} = [
        { start => 0, end => 8191, master => { host => 'nodeA', port => 1111 }, replicas => [{ host => 'nodeA-r', port => 1112 }] },
        { start => 8192, end => 16383, master => { host => 'nodeB', port => 2222 }, replicas => [] },
    ];
    my $slot_foo = HotKV::CRC16::key_slot('foo'); # 12182, in the second range
    my ($h, $p) = $cluster->_pick_node('foo', 0);
    is("$h:$p", 'nodeB:2222', 'routes a key in the second range to its master');

    my $slot_bar = HotKV::CRC16::key_slot('bar'); # 5061, in the first range
    ($h, $p) = $cluster->_pick_node('bar', 0);
    is("$h:$p", 'nodeA:1111', 'routes a key in the first range to its master');

    ($h, $p) = $cluster->_pick_node(undef, 0);
    is("$h:$p", 'seed.example:6379', 'a key-less command routes to a seed node');

    ($h, $p) = $cluster->_pick_node('bar', 1); # read, but read_from_replicas is off by default
    is("$h:$p", 'nodeA:1111', 'read_from_replicas defaults off: reads still go to the master');
}

{
    my $cluster = HotKV::Cluster->new(nodes => ['seed.example:6379'], read_from_replicas => 1);
    $cluster->{slots} = [
        { start => 0, end => 16383, master => { host => 'nodeA', port => 1111 },
          replicas => [{ host => 'r1', port => 1 }, { host => 'r2', port => 2 }] },
    ];
    my ($h1) = $cluster->_pick_node('bar', 1);
    my ($h2) = $cluster->_pick_node('bar', 1);
    my ($h3) = $cluster->_pick_node('bar', 1);
    is_deeply([$h1, $h2, $h3], ['r1', 'r2', 'r1'], 'read_from_replicas round-robins across known replicas');
}

is_deeply([HotKV::Cluster::_extract_key('PING')], [undef], 'PING has no routing key');
is_deeply([HotKV::Cluster::_extract_key('GET', 'mykey')], ['mykey'], 'GET routes on its first argument');
is_deeply([HotKV::Cluster::_extract_key('SET', 'mykey', 'val')], ['mykey'], 'SET routes on its first argument');

{
    my %route = (
        'EVAL "return 1" 2 k1 k2 a1'    => 'k1',
        'EVAL "return 1" 0 a1'          => undef,
        'EVALSHA abc 1 {t}k a'          => '{t}k',
        'FCALL fn 1 fk'                 => 'fk',
        'FCALL_RO fn 0'                 => undef,
        'ZUNION 2 z1 z2 WITHSCORES'     => 'z1',
        'SINTERCARD 2 s1 s2'            => 's1',
        'LMPOP 2 l1 l2 LEFT'            => 'l1',
        'ZMPOP 1 z MIN'                 => 'z',
        'MSETEX 2 a 1 b 2 EX 10'        => 'a',
        'BLMPOP 5 1 l LEFT'             => 'l',
        'BZMPOP 5 2 z1 z2 MIN'          => 'z1',
        'BITOP AND dest src1 src2'      => 'dest',
        'OBJECT ENCODING ok'            => 'ok',
        'XINFO STREAM xs'               => 'xs',
        'XGROUP CREATE xs g $'          => 'xs',
        'MEMORY USAGE mk'               => 'mk',
        'MEMORY STATS'                  => undef,
        'XREAD COUNT 1 BLOCK 10 STREAMS s1 s2 0 0' => 's1',
        'XREADGROUP GROUP g c STREAMS s1 >' => 's1',
        'PUBLISH chan msg'              => undef,
        'FUNCTION LIST'                 => undef,
        'ACL WHOAMI'                    => undef,
        'ZUNIONSTORE dst 2 a b'         => 'dst',
        'GET k'                         => 'k',
    );
    for my $cmd (sort keys %route) {
        my @args = $cmd =~ /"[^"]*"|\S+/g;
        s/\A"|"\z//g for @args;
        is_deeply([HotKV::Cluster::_extract_key(@args)], [$route{$cmd}], "_extract_key: $cmd");
    }
}

# --- MOVED / ASK / bounded redirects, with a mocked connection ------------

{
    no warnings 'redefine';
    my @get_script;
    my $slots_reply = [[0, 16383, ['nodeA', 1111]]];
    my @seen;

    local *HotKV::Connection::connect = sub { my $self = shift; $self->{sock} = 1; $self->{pid} = $$; return; };
    local *HotKV::Connection::close   = sub { return; };
    local *HotKV::Connection::command = sub {
        my ($self, @args) = @_;
        push @seen, [$self->{host}, $self->{port}, @args];
        my $cmd = defined $args[0] ? uc($args[0]) : '';
        if ($cmd eq 'CLUSTER' && uc($args[1] // '') eq 'SLOTS') {
            return $slots_reply;
        }
        return 'OK' if $cmd eq 'ASKING' || $cmd eq 'READONLY';
        my $step = shift @get_script;
        die "test error: unscripted command @args" unless $step;
        return ref($step) eq 'CODE' ? $step->() : $step;
    };

    # --- MOVED: refreshes the slot map and retries against the new node ---
    {
        @get_script = (
            sub { die HotKV::Error::Server::Moved->new(code => 'MOVED', slot => 12182, host => 'nodeB', port => 2222); },
            'bar-value',
        );
        @seen = ();
        my $cluster = HotKV::Cluster->new(nodes => ['nodeA:1111']);
        $cluster->{slots} = [{ start => 0, end => 16383, master => { host => 'nodeA', port => 1111 }, replicas => [] }];
        my $result = $cluster->get('foo');
        is($result, 'bar-value', 'MOVED is followed transparently and the retried GET succeeds');
        is(scalar(@seen), 3, 'exactly 3 wire calls: GET, CLUSTER SLOTS (refresh), retried GET');
        is($seen[0][0] . ':' . $seen[0][1], 'nodeA:1111', 'first attempt went to the originally routed node');
        is($seen[2][0] . ':' . $seen[2][1], 'nodeB:2222', 'retry went to the MOVED target');
    }

    # --- ASK: sends ASKING first, does not permanently update routing -----
    {
        @get_script = (
            sub { die HotKV::Error::Server::Ask->new(code => 'ASK', slot => 12182, host => 'nodeC', port => 3333); },
            'ask-value',
        );
        @seen = ();
        my $cluster = HotKV::Cluster->new(nodes => ['nodeA:1111']);
        $cluster->{slots} = [{ start => 0, end => 16383, master => { host => 'nodeA', port => 1111 }, replicas => [] }];
        my $result = $cluster->get('foo');
        is($result, 'ask-value', 'ASK is followed with an ASKING prefix and the retried GET succeeds');
        is(scalar(@seen), 3, 'exactly 3 wire calls: GET, ASKING, retried GET (no slot refresh for ASK)');
        is(uc($seen[1][2]), 'ASKING', 'ASKING is sent immediately before the retried command');
        is($seen[2][0] . ':' . $seen[2][1], 'nodeC:3333', 'retry went to the ASK target');
    }

    # --- bounded redirect count -------------------------------------------
    {
        my $moved_forever = sub { die HotKV::Error::Server::Moved->new(code => 'MOVED', slot => 12182, host => 'nodeA', port => 1111); };
        @get_script = ($moved_forever, $moved_forever, $moved_forever, $moved_forever, $moved_forever);
        @seen = ();
        my $cluster = HotKV::Cluster->new(nodes => ['nodeA:1111'], max_redirects => 2);
        $cluster->{slots} = [{ start => 0, end => 16383, master => { host => 'nodeA', port => 1111 }, replicas => [] }];
        my $err = eval { $cluster->get('foo'); 1 } ? undef : $@;
        ok($err, 'gives up eventually instead of redirecting forever');
        isa_ok($err, 'HotKV::Error::Connection');
        like("$err", qr/too many cluster redirects/, 'error explains why');
        my $get_calls = grep { uc($_->[2]) eq 'GET' } @seen;
        is($get_calls, 3, 'max_redirects => 2 allows the initial attempt plus 2 retries (3 GETs total)');
    }
}

done_testing();
