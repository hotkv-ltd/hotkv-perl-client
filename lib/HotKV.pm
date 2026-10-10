# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV;

use strict;
use warnings;

use Scalar::Util qw(blessed);

use HotKV::Commands;
use HotKV::Connection;
use HotKV::Pool;
use HotKV::Error;

our @ISA     = ('HotKV::Commands');
our $VERSION = '1.0.0';

=head1 NAME

HotKV - Official client for the HotKV data store

=head1 SYNOPSIS

  use HotKV;

  my $kv = HotKV->new(url => 'hotkv://127.0.0.1:6379');
  $kv->set('greeting', 'hello');
  print $kv->get('greeting'), "\n";

  # Pipelining
  my $results = $kv->pipeline(sub {
      my $p = shift;
      $p->set('a', 1);
      $p->incr('a');
      $p->get('a');
  });

  # Transactions
  my $results = $kv->multi(sub {
      my $tx = shift;
      $tx->set('a', 1);
      $tx->incr('a');
  });

  # Pub/Sub (blocking)
  $kv->subscribe(['news'], sub {
      my ($event, $control) = @_;
      print "$event->{channel}: $event->{data}\n";
      $control->stop if $event->{data} eq 'bye';
  });

=head1 DESCRIPTION

C<HotKV> is the top level client. It owns a bounded L<HotKV::Pool> of
L<HotKV::Connection>s and mixes in every typed command method from
L<HotKV::Commands>, including the HotKV and AI family accessors
(C<scache>, C<pcache>, C<amem>, C<rag>, C<llmstats>, ...) and the AI caching
helpers under L<HotKV::AI>. For routing across a HotKV Cluster deployment,
see L<HotKV::Cluster> instead.

=head1 CONSTRUCTOR

=head2 new(%options)

C<url> parses a C<hotkv://>/C<hotkvs://>/C<redis://>/C<rediss://> connection
string (see L<HotKV::Connection/parse_url>); any other option given
alongside C<url> overrides the parsed value. Recognized options:

  host, port, path (unix socket), username, password, db,
  client_name, connect_timeout, command_timeout, resp3,
  tls, tls_ca_file, tls_cert_file, tls_key_file, tls_server_name,
  tls_insecure_skip_verify,
  on_push (coderef for RESP3 push messages that arrive between a command and
    its reply, e.g. client side caching invalidations; dropped otherwise),
  pool_size (default 5), idle_timeout (default 300),
  retry_writes (default false: only idempotent reads are retried once
    after a connection loss; set true to also retry writes)

=cut

sub new {
    my ($class, %opts) = @_;
    if (my $url = delete $opts{url}) {
        my $parsed = HotKV::Connection::parse_url($url);
        for my $k (CORE::keys %$parsed) {
            $opts{$k} = $parsed->{$k} unless exists $opts{$k};
        }
    }
    my $retry_writes = delete $opts{retry_writes};
    my $self = bless {
        pool         => HotKV::Pool->new(%opts),
        conn_opts    => { %opts },
        retry_writes => $retry_writes,
    }, $class;
    return $self;
}

# Commands considered safe to retry once, after a fresh reconnect, when the
# connection dies mid-request: read-only / idempotent commands only. Two
# word HotKV commands appear here as the single dotted wire token they
# actually are (e.g. "TAG.GET"), the same way _call() sees them.
my %READONLY_CMD = map { $_ => 1 } qw(
    GET MGET STRLEN GETRANGE EXISTS TYPE TTL PTTL KEYS RANDOMKEY DUMP
    LLEN LRANGE LINDEX LPOS SCARD SMEMBERS SISMEMBER SMISMEMBER SUNION SINTER
    SDIFF SRANDMEMBER SINTERCARD
    HGET HMGET HGETALL HLEN HKEYS HVALS HEXISTS HRANDFIELD HTTL HPTTL
    ZSCORE ZMSCORE ZCARD ZCOUNT ZRANGE ZRANGEBYSCORE ZRANGEBYLEX ZREVRANGE
    ZREVRANGEBYSCORE ZREVRANGEBYLEX ZRANK ZREVRANK ZRANDMEMBER ZDIFF ZUNION
    ZINTER ZINTERCARD
    XLEN XRANGE XREVRANGE XPENDING XINFO
    GEOPOS GEODIST GEOHASH GEOSEARCH
    GETBIT BITCOUNT BITPOS PFCOUNT
    SCAN HSCAN SSCAN ZSCAN
    PING ECHO INFO DBSIZE TIME OBJECT COMMAND CONFIG CLIENT LASTSAVE
    NTTL HOTKEYS TAG.GET TAG.MEMBERS TAG.INTER TAG.COUNT TAG.EXISTS
    VSIM.GET VSIM.SEARCH VSIM.INFO SCACHE.GET SCACHE.STATS SCACHE.LIST
    PCACHE.GET PCACHE.GETEX PCACHE.STATS PCACHE.LIST
);

=head2 command / execute / every typed method

See L<HotKV::Commands> for the full list of standard and HotKV
command methods, all available directly on a C<HotKV> instance.

=cut

sub _call {
    my ($self, @args) = @_;
    my $cmd     = defined $args[0] ? uc($args[0]) : '';
    my $is_read = exists $READONLY_CMD{$cmd};

    my $conn   = $self->{pool}->get;
    my $result = eval { $conn->command(@args) };
    my $err    = $@;

    if (!$err) {
        $self->{pool}->put($conn);
        return $result;
    }

    if (blessed($err) && $err->isa('HotKV::Error::Connection')) {
        $self->{pool}->discard($conn);

        if ($is_read || $self->{retry_writes}) {
            my $conn2 = eval { $self->{pool}->get };
            if ($conn2) {
                my $result2 = eval { $conn2->command(@args) };
                my $err2    = $@;
                if (!$err2) {
                    $self->{pool}->put($conn2);
                    return $result2;
                }
                if (blessed($err2) && $err2->isa('HotKV::Error::Connection')) {
                    $self->{pool}->discard($conn2);
                }
                else {
                    $self->{pool}->put($conn2);
                }
                die $err2;
            }
        }
        die $err;
    }

    # Server / protocol error: the connection itself is fine, reuse it.
    $self->{pool}->put($conn);
    die $err;
}

sub close {
    my ($self) = @_;
    $self->{pool}->close_all;
    return;
}

=head2 pipeline(\&block)

Runs C<&block> with a L<HotKV::Pipeline> as its only argument; every command
called on it is queued and sent in a single round trip when the block
returns. Returns an arrayref of decoded replies in call order; a reply for
an individual failed command is a L<HotKV::Error::Server> object rather than
raising an exception, so one bad command does not lose the rest of the
batch.

=cut

sub pipeline {
    my ($self, $block) = @_;
    require HotKV::Pipeline;
    my $pipe = HotKV::Pipeline->new($self);
    my $ok = eval { $block->($pipe); 1 };
    if (!$ok) {
        my $err = $@;
        $pipe->_abort;
        die $err;
    }
    return $pipe->execute;
}

=head2 multi(\&block, %opts)

Runs a C<MULTI> / C<EXEC> transaction. C<&block> is called with a
L<HotKV::Transaction> as its only argument; commands called on it are queued
server-side. C<watch =E<gt> [keys]> issues C<WATCH> on those keys first, on
the same connection, before C<MULTI>. Returns an arrayref of results in call
order (mirroring C<pipeline> above), or C<undef> if the transaction was aborted
because a watched key changed.

=cut

sub multi {
    my ($self, $block, %opts) = @_;
    require HotKV::Transaction;
    my $tx = HotKV::Transaction->new($self);
    $tx->watch(@{ $opts{watch} }) if $opts{watch} && @{ $opts{watch} };
    return $tx->multi($block);
}

=head2 watch(@keys)

Issues C<WATCH> on a fresh dedicated connection and returns a
L<HotKV::Transaction> handle. Useful for the read-modify-write pattern:
read the watched keys (plain, immediate reads on the returned handle),
decide what to write, then call C<< $tx->multi(sub { ... }) >>. Call
C<< $tx->unwatch >> to release the connection without transacting.

=cut

sub watch {
    my ($self, @keys) = @_;
    require HotKV::Transaction;
    my $tx = HotKV::Transaction->new($self);
    $tx->watch(@keys);
    return $tx;
}

=head2 subscribe / psubscribe / ssubscribe

=over 4

=item subscribe(\@channels, \&callback)

=item psubscribe(\@patterns, \&callback)

=item ssubscribe(\@shard_channels, \&callback)

=back

Opens a dedicated connection, subscribes, and blocks, invoking
C<< $callback->($event, $control) >> for every message and subscription
confirmation. C<$event> is a hashref with at least a C<type> key (one of
C<message>, C<pmessage>, C<smessage>, C<subscribe>, C<unsubscribe>,
C<psubscribe>, C<punsubscribe>, C<ssubscribe>, C<sunsubscribe>), plus
C<channel>/C<pattern>/C<data>/C<count> as appropriate. Call
C<< $control->stop >> from the callback to return from the call; see
L<HotKV::PubSub>.

=cut

sub subscribe  { my $self = shift; require HotKV::PubSub; return HotKV::PubSub->new($self)->subscribe(@_); }
sub psubscribe { my $self = shift; require HotKV::PubSub; return HotKV::PubSub->new($self)->psubscribe(@_); }
sub ssubscribe { my $self = shift; require HotKV::PubSub; return HotKV::PubSub->new($self)->ssubscribe(@_); }

=head2 _pool

Internal: the underlying L<HotKV::Pool>. Used by L<HotKV::Pipeline> and
L<HotKV::Transaction>; not part of the public API.

=cut

sub _pool { return $_[0]->{pool}; }

sub DESTROY {
    my ($self) = @_;
    local ($@, $!, $?);
    eval { $self->close };
    return;
}

1;

=head1 SEE ALSO

L<HotKV::Commands>, L<HotKV::Pipeline>, L<HotKV::Transaction>,
L<HotKV::PubSub>, L<HotKV::Cluster>, L<HotKV::Error>, L<HotKV::AI::PromptCache>,
L<HotKV::AI::SemanticCache>.

=head1 SUPPORT

support@hotkv.com

=head1 LICENSE

Apache License, Version 2.0; see the LICENSE file.

=cut
