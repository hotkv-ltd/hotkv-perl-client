# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Error;

use strict;
use warnings;

use overload
    '""'     => \&message,
    fallback => 1;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Error - Base class for all HotKV client exceptions

=head1 DESCRIPTION

Every exception raised by the HotKV client (via C<die>) is a blessed object
that inherits from C<HotKV::Error>. The hierarchy is:

  HotKV::Error
    HotKV::Error::Connection      -- socket / DNS / connect failures
      HotKV::Error::Timeout       -- connect or command timed out
    HotKV::Error::Protocol        -- malformed RESP data on the wire
    HotKV::Error::Server          -- a "-ERR ..." style reply from the server
      HotKV::Error::Server::NotLicensed -- NOLICENSE reply
      HotKV::Error::Server::Moved       -- MOVED cluster redirect
      HotKV::Error::Server::Ask         -- ASK cluster redirect

All exceptions stringify to a human readable message, so C<warn "$@"> or
C<print "$err"> work without calling any accessor.

=head1 METHODS

=head2 new(%fields)

Constructs an error object. C<message> is required by convention but not
enforced. Subclasses add their own fields.

=head2 throw(%fields)

Convenience class method equivalent to C<die __PACKAGE__-E<gt>new(%fields)>.

=head2 message

Returns the human readable message string.

=cut

sub new {
    my ($class, %args) = @_;
    $args{message} = 'unknown error' unless defined $args{message};
    return bless { %args }, $class;
}

sub throw {
    my ($class, %args) = @_;
    die $class->new(%args);
}

sub message { return $_[0]->{message}; }

package HotKV::Error::Connection;

use strict;
use warnings;
our @ISA = ('HotKV::Error');
our $VERSION = '1.0.0';

package HotKV::Error::Timeout;

use strict;
use warnings;
our @ISA = ('HotKV::Error::Connection');
our $VERSION = '1.0.0';

package HotKV::Error::Protocol;

use strict;
use warnings;
our @ISA = ('HotKV::Error');
our $VERSION = '1.0.0';

package HotKV::Error::Server;

=head1 NAME

HotKV::Error::Server - A "-ERR"/"-WRONGTYPE"/... reply from the server

=head1 FIELDS

=over 4

=item code

The error prefix, e.g. C<ERR>, C<WRONGTYPE>, C<NOAUTH>, C<MOVED>, C<NOLICENSE>.

=item message

The full text of the reply, prefix included (for example C<ERR unknown
command 'FOO'>); the same as C<raw>. Use C<code> for the prefix alone.

=item raw

The complete, unparsed error string exactly as received.

=back

=head2 from_raw($raw)

Parses a raw RESP error payload (the text after the leading C<-> or C<!len\r\n>
framing has already been stripped) and returns the most specific subclass
that applies: L<HotKV::Error::Server::NotLicensed> for a C<NOLICENSE> prefix,
L<HotKV::Error::Server::Moved> / L<HotKV::Error::Server::Ask> for cluster
redirects, or a plain C<HotKV::Error::Server> otherwise.

=cut

use strict;
use warnings;
our @ISA = ('HotKV::Error');
our $VERSION = '1.0.0';

sub from_raw {
    my ($class, $raw) = @_;
    $raw = '' unless defined $raw;
    my ($code, $rest) = split / /, $raw, 2;
    $code = '' unless defined $code;
    $rest = '' unless defined $rest;

    if ($code eq 'NOLICENSE') {
        return HotKV::Error::Server::NotLicensed->new(
            code => $code, message => $raw, raw => $raw,
        );
    }
    if ($code eq 'MOVED' || $code eq 'ASK') {
        my ($slot, $hostport) = split ' ', $rest, 2;
        my ($host, $port) = ('', 0);
        if (defined $hostport && $hostport =~ /^(.*):(\d+)$/) {
            ($host, $port) = ($1, $2);
        }
        my $sub = $code eq 'MOVED' ? 'HotKV::Error::Server::Moved' : 'HotKV::Error::Server::Ask';
        return $sub->new(
            code => $code, message => $raw, raw => $raw,
            slot => (defined $slot ? $slot + 0 : -1), host => $host, port => $port + 0,
        );
    }
    return $class->new(code => $code, message => $raw, raw => $raw);
}

sub code    { return $_[0]->{code}; }
sub message { return $_[0]->{raw} // $_[0]->{message}; }
sub raw     { return $_[0]->{raw}; }

package HotKV::Error::Server::NotLicensed;

use strict;
use warnings;
our @ISA = ('HotKV::Error::Server');
our $VERSION = '1.0.0';

package HotKV::Error::Server::Moved;

use strict;
use warnings;
our @ISA = ('HotKV::Error::Server');
our $VERSION = '1.0.0';

sub slot { return $_[0]->{slot}; }
sub host { return $_[0]->{host}; }
sub port { return $_[0]->{port}; }

package HotKV::Error::Server::Ask;

use strict;
use warnings;
our @ISA = ('HotKV::Error::Server');
our $VERSION = '1.0.0';

sub slot { return $_[0]->{slot}; }
sub host { return $_[0]->{host}; }
sub port { return $_[0]->{port}; }

1;
