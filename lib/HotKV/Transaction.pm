# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Transaction;

use strict;
use warnings;

use Scalar::Util qw(blessed);

use HotKV::Commands;

our @ISA     = ('HotKV::Commands');
our $VERSION = '1.0.0';

=head1 NAME

HotKV::Transaction - MULTI/EXEC/DISCARD and WATCH/UNWATCH

=head1 DESCRIPTION

Returned by C<< $kv->watch(@keys) >> and passed to the block given to
C<< $kv->multi(sub { ... }) >>. Before C<multi> is called (i.e. right after
C<watch>), typed command methods run immediately on the dedicated,
watching connection, which is the usual read-modify-write pattern: watch a
key, read its current value, decide what to write. Once C<multi> has been
called, every typed method instead sends its command and waits for the
server's C<+QUEUED> acknowledgement, so a bad command is caught eagerly
rather than only surfacing inside the C<EXEC> results.

Do not construct directly; use C<< HotKV->watch >> or C<< HotKV->multi >>.

=cut

sub new {
    my ($class, $client) = @_;
    return bless {
        client   => $client,
        conn     => undef,
        in_multi => 0,
        queued   => 0,
    }, $class;
}

sub _ensure_conn {
    my ($self) = @_;
    $self->{conn} ||= $self->{client}->_pool->get;
    return $self->{conn};
}

=head2 watch(@keys)

Sends C<WATCH> for the given keys on this transaction's dedicated
connection (borrowing one on first use). Returns C<$self> for chaining.

=cut

sub watch {
    my ($self, @keys) = @_;
    return $self unless @keys;
    $self->_ensure_conn->command('WATCH', @keys);
    return $self;
}

=head2 unwatch

Sends C<UNWATCH> and releases the dedicated connection back to the pool.

=cut

sub unwatch {
    my ($self) = @_;
    if ($self->{conn}) {
        eval { $self->{conn}->command('UNWATCH') };
        my $err = $@;
        $self->_release;
        die $err if $err;
    }
    return;
}

sub _start_multi {
    my ($self) = @_;
    $self->_ensure_conn->command('MULTI');
    $self->{in_multi} = 1;
    $self->{queued}   = 0;
    return;
}

sub _call {
    my ($self, @args) = @_;
    my $conn = $self->_ensure_conn;
    if (!$self->{in_multi}) {
        # Not transacting yet (e.g. right after watch()): run immediately.
        return $conn->command(@args);
    }
    $conn->write_command(@args);
    my $reply = $conn->read_reply;
    if (blessed($reply) && $reply->isa('HotKV::Error')) {
        die $reply;
    }
    $self->{queued}++;
    return $self; # queued; the real reply comes back from exec()
}

=head2 multi(\&block)

Sends C<MULTI>, runs C<&block> with C<$self>, then C<EXEC>s and returns the
results (see L</exec>). On an exception from C<&block> or from queuing a
command, the transaction is discarded and the connection released before
the exception is re-raised.

=cut

sub multi {
    my ($self, $block) = @_;
    $self->_start_multi;
    my $ok = eval { $block->($self); 1 };
    if (!$ok) {
        my $err = $@;
        eval { $self->discard };
        $self->_release;
        die $err;
    }
    return $self->exec;
}

=head2 exec

Sends C<EXEC>. Returns an arrayref of decoded results in call order (an
individual failed queued command is a L<HotKV::Error::Server> object in
that slot, not an exception), or C<undef> if the transaction was aborted
because a watched key changed. Releases the dedicated connection.

=cut

sub exec {
    my ($self) = @_;
    die "hotkv: exec() called without multi()\n" unless $self->{in_multi};
    my $conn = $self->{conn};
    $conn->write_command('EXEC');
    my $reply = $conn->read_reply;
    $self->{in_multi} = 0;
    $self->_release;
    if (blessed($reply) && $reply->isa('HotKV::Error')) {
        die $reply;
    }
    return $reply;
}

=head2 discard

Sends C<DISCARD>, canceling a transaction that is mid-C<multi>. Does not
release the connection; call C<unwatch> or let C<multi> finish to do that.

=cut

sub discard {
    my ($self) = @_;
    if ($self->{in_multi} && $self->{conn}) {
        $self->{conn}->command('DISCARD');
        $self->{in_multi} = 0;
    }
    return;
}

sub _release {
    my ($self) = @_;
    if ($self->{conn}) {
        $self->{client}->_pool->put($self->{conn});
        $self->{conn} = undef;
    }
    return;
}

1;
