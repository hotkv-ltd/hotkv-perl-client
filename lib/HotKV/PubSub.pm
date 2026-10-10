# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::PubSub;

use strict;
use warnings;

use Scalar::Util qw(blessed);

use HotKV::Connection;
use HotKV::Error;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::PubSub - Blocking SUBSCRIBE / PSUBSCRIBE / SSUBSCRIBE loop

=head1 DESCRIPTION

Opens one dedicated connection (never shared with the pool, since a
subscribed connection cannot run ordinary commands) and blocks, delivering
every push message to a callback. RESP3 push frames and RESP2 plain arrays
are both accepted transparently. Construct through L<HotKV/subscribe>,
L<HotKV/psubscribe> or L<HotKV/ssubscribe> rather than directly.

=head1 EVENT SHAPE

Each callback invocation receives C<($event, $control)>. C<$event> is a
hashref with a C<type> key: C<subscribe>, C<unsubscribe>, C<psubscribe>,
C<punsubscribe>, C<ssubscribe>, C<sunsubscribe> (subscription
acknowledgements, carrying C<channel>/C<pattern> and C<count>), or
C<message>, C<pmessage>, C<smessage> (the payloads, carrying
C<channel>/C<pattern> and C<data>). C<$control> supports:

=over 4

=item C<< $control->stop >>

Returns from the blocking call after this event.

=item C<< $control->subscribe(@channels) >> / C<unsubscribe> / C<psubscribe>
/ C<punsubscribe> / C<ssubscribe> / C<sunsubscribe>

Issues another (un)subscribe command on the same connection without
leaving the loop.

=back

=cut

sub new {
    my ($class, $client) = @_;
    return bless { client => $client }, $class;
}

sub subscribe  { my $self = shift; return $self->_run('SUBSCRIBE', @_); }
sub psubscribe { my $self = shift; return $self->_run('PSUBSCRIBE', @_); }
sub ssubscribe { my $self = shift; return $self->_run('SSUBSCRIBE', @_); }

sub _run {
    my ($self, $verb, $names, $cb) = @_;
    $names = [$names] unless ref $names eq 'ARRAY';
    die "hotkv: subscribe needs at least one channel/pattern\n" unless @$names;
    die "hotkv: subscribe needs a callback coderef\n" unless ref $cb eq 'CODE';

    my $conn = HotKV::Connection->new(%{ $self->{client}{conn_opts} }, raw_push => 1);
    $conn->connect;
    my $control = HotKV::PubSub::Control->new($conn);

    my $ok = eval {
        $conn->write_command($verb, @$names);
        while (!$control->{stopped}) {
            my $reply = $conn->read_reply(undef); # block indefinitely for the next push
            if (blessed($reply) && $reply->isa('HotKV::Error')) {
                die $reply;
            }
            my $event = _decode_event($reply);
            $cb->($event, $control);
        }
        1;
    };
    my $err = $@;
    $conn->close;
    die $err unless $ok;
    return;
}

sub _decode_event {
    my ($arr) = @_;
    my $type = lc(defined $arr->[0] ? $arr->[0] : '');
    if ($type eq 'pmessage') {
        return { type => $type, pattern => $arr->[1], channel => $arr->[2], data => $arr->[3] };
    }
    if ($type eq 'psubscribe' || $type eq 'punsubscribe') {
        return { type => $type, pattern => $arr->[1], count => $arr->[2] };
    }
    if ($type =~ /^(?:subscribe|unsubscribe|ssubscribe|sunsubscribe)\z/) {
        return { type => $type, channel => $arr->[1], count => $arr->[2] };
    }
    # message, smessage
    return { type => $type, channel => $arr->[1], data => $arr->[2] };
}

package HotKV::PubSub::Control;

use strict;
use warnings;

our $VERSION = '1.0.0';

sub new { my ($class, $conn) = @_; return bless { conn => $conn, stopped => 0 }, $class; }
sub stop { $_[0]->{stopped} = 1; return; }

sub subscribe    { my $self = shift; $self->{conn}->write_command('SUBSCRIBE', @_); return; }
sub unsubscribe  { my $self = shift; $self->{conn}->write_command('UNSUBSCRIBE', @_); return; }
sub psubscribe   { my $self = shift; $self->{conn}->write_command('PSUBSCRIBE', @_); return; }
sub punsubscribe { my $self = shift; $self->{conn}->write_command('PUNSUBSCRIBE', @_); return; }
sub ssubscribe   { my $self = shift; $self->{conn}->write_command('SSUBSCRIBE', @_); return; }
sub sunsubscribe { my $self = shift; $self->{conn}->write_command('SUNSUBSCRIBE', @_); return; }

1;
