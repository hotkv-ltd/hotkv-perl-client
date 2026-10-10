# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Cluster;

use strict;
use warnings;

use Scalar::Util qw(blessed);

use HotKV::Commands;
use HotKV::Connection;
use HotKV::Pool;
use HotKV::CRC16 qw(key_slot);
use HotKV::Error;

our @ISA     = ('HotKV::Commands');
our $VERSION = '1.0.0';

=head1 NAME

HotKV::Cluster - Client for a HotKV Cluster deployment

=head1 SYNOPSIS

  my $cluster = HotKV::Cluster->new(
      nodes => ['10.0.0.1:6379', '10.0.0.2:6379', '10.0.0.3:6379'],
      password => 'secret',
  );
  $cluster->set('{user1000}.name', 'ada');
  print $cluster->get('{user1000}.name'), "\n";

=head1 DESCRIPTION

Builds a slot map from C<CLUSTER SLOTS> (falling back to C<CLUSTER SHARDS>
if that comes back empty), routes each command to the owning node by
hashing its key with L<HotKV::CRC16> (honoring C<{hash tag}>), follows
C<MOVED> redirects by refreshing the slot map and C<ASK> redirects by
sending C<ASKING> first, and bounds the number of redirects it will follow
per command. Every typed method from L<HotKV::Commands> (including the
HotKV and AI family accessors) is available directly.

Key extraction for routing uses the command's first argument after the
command name, which is correct for the overwhelming majority of commands
(C<GET key>, C<SET key val>, C<HSET key field val>, all HotKV and AI
commands, ...). Commands with no key (C<PING>, C<INFO>, ...) are routed to
an arbitrary connected node. Multi-key commands are the caller's
responsibility to keep in one hash slot (via C<{hash tag}>), exactly as
plain HotKV Cluster requires.

=head1 OPTIONS

C<nodes> (required arrayref of C<"host:port"> strings or C<{host,port}>
hashrefs: seed nodes used only to discover the rest of the cluster),
C<max_redirects> (default 5), C<read_from_replicas> (default false: send
read-only commands, per C<%HotKV::Cluster::READONLY_CMD>, to a replica of the owning slot
when one is known, issuing C<READONLY> on that connection), plus every
per-node connection option L<HotKV::Connection/new> accepts (username,
password, tls, ...) and every L<HotKV::Pool/new> option (pool_size,
idle_timeout).

=cut

# Commands with no key at all, or where routing to an arbitrary node is
# correct/harmless (admin and connection level commands).
my %NO_KEY_CMD = map { $_ => 1 } qw(
    PING ECHO INFO DBSIZE TIME SELECT SWAPDB CONFIG CLIENT COMMAND SCRIPT
    SUBSCRIBE UNSUBSCRIBE PSUBSCRIBE PUNSUBSCRIBE SSUBSCRIBE SUNSUBSCRIBE
    CLUSTER FLUSHALL FLUSHDB RANDOMKEY LASTSAVE HOTKEYS OBSERVE ALERTS
    PUBLISH PUBSUB ACL FUNCTION SLOWLOG LATENCY MODULE WAIT WAITAOF ROLE SAVE
    BGSAVE BGREWRITEAOF LOLWUT FAILOVER REPLICAOF
    REPLICATION.INFO TENANT.LIST
);

# Commands eligible for replica routing when read_from_replicas is set.
our %READONLY_CMD = map { $_ => 1 } qw(
    GET MGET STRLEN GETRANGE EXISTS TYPE TTL PTTL DUMP
    LLEN LRANGE LINDEX SCARD SMEMBERS SISMEMBER SMISMEMBER SRANDMEMBER
    HGET HMGET HGETALL HLEN HKEYS HVALS HEXISTS HRANDFIELD HTTL HPTTL
    ZSCORE ZMSCORE ZCARD ZCOUNT ZRANGE ZRANGEBYSCORE ZRANGEBYLEX ZREVRANGE
    ZREVRANGEBYSCORE ZREVRANGEBYLEX ZRANK ZREVRANK ZRANDMEMBER
    XLEN XRANGE XREVRANGE
    GEOPOS GEODIST GEOHASH GEOSEARCH
    GETBIT BITCOUNT BITPOS
    SCAN HSCAN SSCAN ZSCAN
);

sub new {
    my ($class, %opts) = @_;
    my $nodes = delete $opts{nodes};
    HotKV::Error::Connection->throw(message => 'hotkv: HotKV::Cluster requires nodes => [...]')
        unless $nodes && ref $nodes eq 'ARRAY' && @$nodes;

    my $max_redirects      = delete $opts{max_redirects} // 5;
    my $read_from_replicas = delete $opts{read_from_replicas} // 0;

    return bless {
        seed_nodes          => [ map { _normalize_node($_) } @$nodes ],
        conn_opts           => { %opts },
        max_redirects       => $max_redirects,
        read_from_replicas  => $read_from_replicas,
        pools               => {},  # "host:port" => HotKV::Pool
        slots                => [], # sorted arrayref of {start,end,master=>{host,port},replicas=>[...]}
        replica_rr          => {},  # "host:port" (master) => next replica index
    }, $class;
}

sub _normalize_node {
    my ($n) = @_;
    return { %$n } if ref $n eq 'HASH';
    my ($host, $port) = split /:/, $n, 2;
    return { host => $host, port => $port + 0 };
}

=head2 refresh_slots

Connects to the first reachable seed (or already known) node, runs
C<CLUSTER SLOTS>, and rebuilds the internal slot map. Called automatically
before the first command and after a C<MOVED> redirect; safe to call
manually after a known topology change.

=cut

sub refresh_slots {
    my ($self) = @_;
    my @candidates = @{ $self->{seed_nodes} };
    push @candidates, map { { host => $_->{master}{host}, port => $_->{master}{port} } } @{ $self->{slots} };

    my $last_err;
    for my $node (@candidates) {
        my $conn = eval { $self->_connect_to($node->{host}, $node->{port}) };
        if (!$conn) { $last_err = $@; next; }
        my $reply = eval { $conn->command('CLUSTER', 'SLOTS') };
        if ($@) { $last_err = $@; $conn->close; next; }
        my $slots = _parse_cluster_slots($reply);
        if (!@$slots) {
            my $shards_reply = eval { $conn->command('CLUSTER', 'SHARDS') };
            $slots = _parse_cluster_shards($shards_reply) unless $@;
        }
        $conn->close;
        if (@$slots) {
            $self->{slots} = [ sort { $a->{start} <=> $b->{start} } @$slots ];
            return 1;
        }
    }
    HotKV::Error::Connection->throw(
        message => 'hotkv: could not discover cluster slots from any seed node'
            . ($last_err ? ": $last_err" : ''));
}

sub _connect_to {
    my ($self, $host, $port) = @_;
    my $conn = HotKV::Connection->new(%{ $self->{conn_opts} }, host => $host, port => $port);
    $conn->connect;
    return $conn;
}

# Parses a CLUSTER SLOTS reply: array of
# [start, end, [master_ip, master_port, id, ...], [replica_ip, replica_port, ...], ...]
sub _parse_cluster_slots {
    my ($reply) = @_;
    my @slots;
    for my $range (@{ $reply || [] }) {
        my ($start, $end, $master, @replicas) = @$range;
        push @slots, {
            start    => $start,
            end      => $end,
            master   => { host => $master->[0], port => $master->[1] },
            replicas => [ map { { host => $_->[0], port => $_->[1] } } @replicas ],
        };
    }
    return \@slots;
}

# Parses a CLUSTER SHARDS reply (each shard: a map/flat-array with "slots"
# as [start,end,start,end,...] and "nodes" as a list of node maps carrying
# at least ip/port/role). Accepts either RESP3 map or RESP2 flat-array shape.
sub _parse_cluster_shards {
    my ($reply) = @_;
    my @slots;
    for my $shard (@{ $reply || [] }) {
        my %s = (ref $shard eq 'HASH') ? %$shard : @$shard;
        my @ranges = @{ $s{slots} || [] };
        my @nodes  = @{ $s{nodes} || [] };
        my (@masters, @replicas);
        for my $node (@nodes) {
            my %n = (ref $node eq 'HASH') ? %$node : @$node;
            my $entry = { host => $n{ip} || $n{endpoint}, port => $n{port} };
            if (lc($n{role} // '') eq 'master') { push @masters, $entry; }
            else { push @replicas, $entry; }
        }
        next unless @masters;
        while (@ranges >= 2) {
            my ($start, $end) = splice(@ranges, 0, 2);
            push @slots, { start => $start, end => $end, master => $masters[0], replicas => \@replicas };
        }
    }
    return \@slots;
}

sub _find_slot {
    my ($self, $slot) = @_;
    for my $range (@{ $self->{slots} }) {
        return $range if $slot >= $range->{start} && $slot <= $range->{end};
    }
    return undef;
}

sub _pool_for {
    my ($self, $host, $port) = @_;
    my $key = "$host:$port";
    return $self->{pools}{$key} ||= HotKV::Pool->new(%{ $self->{conn_opts} }, host => $host, port => $port);
}

sub _pick_node {
    my ($self, $key, $is_read) = @_;
    $self->refresh_slots unless @{ $self->{slots} };
    return @{ $self->{seed_nodes}[0] }{qw(host port)} unless defined $key;

    my $slot  = key_slot($key);
    my $range = $self->_find_slot($slot);
    HotKV::Error::Connection->throw(message => "hotkv: no cluster node owns slot $slot")
        unless $range;

    if ($is_read && $self->{read_from_replicas} && @{ $range->{replicas} }) {
        my $mkey = "$range->{master}{host}:$range->{master}{port}";
        my $idx  = ($self->{replica_rr}{$mkey} //= 0) % scalar(@{ $range->{replicas} });
        $self->{replica_rr}{$mkey} = $idx + 1;
        my $r = $range->{replicas}[$idx];
        return ($r->{host}, $r->{port});
    }
    return ($range->{master}{host}, $range->{master}{port});
}

# The key used for slot routing, or undef for a command that has no key (or
# whose first argument is a name, not a key) and may go to any node.
#
# Most commands take their key as the first argument. The exceptions are
# routed by the position the server's key specification gives:
#   * numkeys first: ZUNION/ZINTER/ZDIFF/SINTERCARD/ZINTERCARD/LMPOP/ZMPOP
#     (key at 2), BLMPOP/BZMPOP (key at 3), MSETEX (key at 2);
#   * script and function calls: EVAL/EVALSHA/EVAL_RO/EVALSHA_RO/FCALL/
#     FCALL_RO name numkeys key ... (key at 3, none when numkeys is 0);
#   * BITOP op dest key ...  (key at 2); OBJECT/XINFO/XGROUP/MEMORY USAGE
#     subcommand key (key at 2);
#   * XREAD/XREADGROUP: the first key after STREAMS.
sub _extract_key {
    my (@args) = @_;
    my $cmd = defined $args[0] ? uc($args[0]) : '';
    return undef if exists $NO_KEY_CMD{$cmd};

    if ($cmd =~ /\A(?:EVAL|EVALSHA|EVAL_RO|EVALSHA_RO|FCALL|FCALL_RO)\z/) {
        return (defined $args[2] && $args[2] =~ /\A[0-9]+\z/ && $args[2] > 0) ? $args[3] : undef;
    }
    if ($cmd =~ /\A(?:ZUNION|ZINTER|ZDIFF|SINTERCARD|ZINTERCARD|LMPOP|ZMPOP|MSETEX)\z/) {
        return (defined $args[1] && $args[1] =~ /\A[0-9]+\z/ && $args[1] > 0) ? $args[2] : undef;
    }
    if ($cmd eq 'BLMPOP' || $cmd eq 'BZMPOP') {
        return (defined $args[2] && $args[2] =~ /\A[0-9]+\z/ && $args[2] > 0) ? $args[3] : undef;
    }
    if ($cmd eq 'BITOP') {
        return $args[2];
    }
    if ($cmd =~ /\A(?:OBJECT|XINFO|XGROUP)\z/ || ($cmd eq 'MEMORY' && defined $args[1] && uc($args[1]) eq 'USAGE')) {
        return $args[2];
    }
    if ($cmd eq 'MEMORY') {
        return undef;
    }
    if ($cmd eq 'XREAD' || $cmd eq 'XREADGROUP') {
        for my $i (1 .. $#args) {
            return $args[$i + 1] if defined $args[$i] && uc($args[$i]) eq 'STREAMS';
        }
        return undef;
    }
    return $args[1];
}

sub _call {
    my ($self, @args) = @_;
    my $cmd     = defined $args[0] ? uc($args[0]) : '';
    my $key     = _extract_key(@args);
    my $is_read = exists $READONLY_CMD{$cmd};

    my ($host, $port) = $self->_pick_node($key, $is_read);
    my $asking  = 0;
    my $tries   = 0;

    while (1) {
        $tries++;
        HotKV::Error::Connection->throw(message => 'hotkv: too many cluster redirects')
            if $tries > $self->{max_redirects} + 1;

        my $pool = $self->_pool_for($host, $port);
        my $conn = $pool->get;
        my $result = eval {
            $conn->command('ASKING') if $asking;
            $conn->command('READONLY') if $is_read && $self->{read_from_replicas} && !$asking;
            $conn->command(@args);
        };
        $asking = 0;

        if (!$@) {
            $pool->put($conn);
            return $result;
        }

        my $err = $@;
        if (blessed($err) && $err->isa('HotKV::Error::Connection')) {
            $pool->discard($conn);
            die $err;
        }
        $pool->put($conn);

        if (blessed($err) && $err->isa('HotKV::Error::Server::Moved')) {
            $self->refresh_slots;
            ($host, $port) = ($err->host, $err->port);
            next;
        }
        if (blessed($err) && $err->isa('HotKV::Error::Server::Ask')) {
            ($host, $port) = ($err->host, $err->port);
            $asking = 1;
            next;
        }
        die $err;
    }
}

=head2 close

Closes every pooled connection to every known node.

=cut

sub close {
    my ($self) = @_;
    $_->close_all for CORE::values %{ $self->{pools} };
    return;
}

sub DESTROY {
    my ($self) = @_;
    local ($@, $!, $?);
    eval { $self->close };
    return;
}

1;
