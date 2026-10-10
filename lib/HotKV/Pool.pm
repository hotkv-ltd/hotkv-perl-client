# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Pool;

use strict;
use warnings;

use Time::HiRes qw(time);

use HotKV::Connection;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Pool - A bounded pool of idle HotKV connections

=head1 DESCRIPTION

Keeps up to C<pool_size> idle, already-negotiated connections around so
sequential commands do not pay reconnect/HELLO overhead. A connection idle
longer than C<idle_timeout> seconds is health-checked with C<PING> before
reuse and discarded (transparently replaced) if that fails. Bursts of
concurrent borrows beyond C<pool_size> simply open additional connections
rather than blocking a caller; those extra connections are closed (not
pooled) on release once the pool is back at capacity. This matches Perl's
usual concurrency model (synchronous code, optionally forked workers) rather
than assuming native shared-memory threads.

The pool is fork-safe: connections created by the parent process are never
handed to, or accepted back from, a child, since sockets must not be shared
across C<fork>.

=head1 METHODS

=head2 new(%opts)

C<pool_size> (default 5), C<idle_timeout> (seconds, default 300), plus every
option L<HotKV::Connection/new> accepts (host, port, tls, ...).

=cut

sub new {
    my ($class, %opts) = @_;
    my $pool_size    = delete $opts{pool_size}    // 5;
    my $idle_timeout = delete $opts{idle_timeout} // 300;
    return bless {
        conn_opts    => \%opts,
        pool_size    => $pool_size,
        idle_timeout => $idle_timeout,
        free         => [],   # [{conn => $c, since => $t}, ...]
        pid          => $$,
        closed       => 0,
    }, $class;
}

sub _reset_if_forked {
    my ($self) = @_;
    if ($self->{pid} != $$) {
        # Sockets belong to the parent; do not close them here (that would
        # send RST/close bytes the parent's process still owns), just drop
        # our references so this process opens fresh connections.
        $self->{free} = [];
        $self->{pid}  = $$;
    }
    return;
}

=head2 get

Returns a live, negotiated L<HotKV::Connection>, borrowed from the idle
list when possible.

=cut

sub get {
    my ($self) = @_;
    $self->_reset_if_forked;

    while (@{ $self->{free} }) {
        my $entry = pop @{ $self->{free} };
        my $conn  = $entry->{conn};
        if ($conn->is_stale) {
            # The server closed it while idle: drop it and try the next one.
            $conn->close;
            next;
        }
        if (time() - $entry->{since} > $self->{idle_timeout}) {
            my $ok = eval { $conn->ping; 1 };
            if (!$ok) {
                $conn->close;
                next;
            }
        }
        return $conn;
    }

    my $conn = HotKV::Connection->new(%{ $self->{conn_opts} });
    $conn->connect;
    return $conn;
}

=head2 put($conn)

Returns a connection to the pool, or closes it if the pool is full, the
connection is dead, or it belongs to another process (post-fork).

=cut

sub put {
    my ($self, $conn) = @_;
    return unless $conn;
    $self->_reset_if_forked;

    if ($self->{closed} || !$conn->is_connected || $conn->owner_pid != $$
        || @{ $self->{free} } >= $self->{pool_size}) {
        $conn->close;
        return;
    }
    push @{ $self->{free} }, { conn => $conn, since => time() };
    return;
}

=head2 discard($conn)

Closes a connection instead of returning it to the pool (used after a
connection-level error, when the socket is known to be unusable).

=cut

sub discard {
    my ($self, $conn) = @_;
    $conn->close if $conn;
    return;
}

=head2 close_all

Closes every idle pooled connection.

=cut

sub close_all {
    my ($self) = @_;
    for my $entry (@{ $self->{free} }) {
        $entry->{conn}->close;
    }
    $self->{free}   = [];
    $self->{closed} = 1;
    return;
}

sub size { return scalar @{ $_[0]->{free} }; }

sub DESTROY {
    my ($self) = @_;
    local ($@, $!, $?);
    $self->close_all if $self->{pid} == $$;
    return;
}

1;
