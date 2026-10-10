# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Pipeline;

use strict;
use warnings;

use Scalar::Util qw(blessed);

use HotKV::Commands;

our @ISA     = ('HotKV::Commands');
our $VERSION = '1.0.0';

=head1 NAME

HotKV::Pipeline - Client-side command batching, one round trip

=head1 DESCRIPTION

Returned to the block passed to C<< $kv->pipeline(sub { ... }) >>. Every
typed method inherited from L<HotKV::Commands> queues its command instead of
sending it immediately; C<execute> (called automatically at the end of
C<< HotKV->pipeline >>) writes every queued command back to back on one
dedicated connection, then reads all the replies, in order. A per-command
server error is returned in place in the result list rather than raising an
exception, so one bad command does not lose the rest of the batch; a
connection-level failure raises for the whole pipeline (nothing after that
point could have been executed).

Do not construct directly; use C<< $kv->pipeline(sub { ... }) >>.

=cut

sub new {
    my ($class, $client) = @_;
    return bless { client => $client, queue => [] }, $class;
}

sub _call {
    my ($self, @args) = @_;
    push @{ $self->{queue} }, [@args];
    return $self;
}

sub _abort {
    my ($self) = @_;
    $self->{queue} = [];
    return;
}

=head2 execute

Sends every queued command and returns an arrayref of decoded replies in
call order. Called automatically by C<< HotKV->pipeline >>; only call this
directly if you built a L<HotKV::Pipeline> yourself.

=cut

sub execute {
    my ($self) = @_;
    my @queue = @{ $self->{queue} };
    $self->{queue} = [];
    return [] unless @queue;

    my $pool = $self->{client}->_pool;
    my $conn = $pool->get;
    my @results;
    my $ok = eval {
        $conn->write_command(@$_) for @queue;
        push @results, $conn->read_reply($conn->timeout_for(@$_)) for @queue;
        1;
    };
    if (!$ok) {
        my $err = $@;
        if (blessed($err) && $err->isa('HotKV::Error::Connection')) {
            $pool->discard($conn);
        }
        else {
            $pool->put($conn);
        }
        die $err;
    }
    $pool->put($conn);
    return \@results;
}

1;
