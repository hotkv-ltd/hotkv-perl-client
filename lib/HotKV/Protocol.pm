# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Protocol;

use strict;
use warnings;

use Carp qw(croak);
use B ();
use Scalar::Util ();
use HotKV::Error;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Protocol - RESP2/RESP3 wire encoding and decoding

=head1 DESCRIPTION

Pure, socket-free RESP2/RESP3 implementation. C<encode_command> turns a list
of arguments into the bulk-string array HotKV expects on the wire.
L<HotKV::Protocol::Reader> decodes a byte stream (from a real socket, or from
an in-memory buffer for unit tests) into Perl data structures.

Decoding maps RESP types to native Perl values as follows:

  simple string, bulk string, verbatim string  -> plain scalar (bytes)
  integer, big number                          -> plain scalar (number/string)
  double                                       -> plain scalar (number)
  boolean                                      -> 1 or 0
  null bulk/array/RESP3 null                   -> undef
  array                                        -> arrayref
  push (RESP3 out of band message)             -> arrayref blessed into HotKV::Protocol::Push
  set                                          -> arrayref (unique members)
  map                                          -> hashref
  attribute                                    -> discarded; the value that
                                                   follows it is returned
  error, blob error                            -> HotKV::Error::Server object

The RESP3 verbatim string's 3-byte type prefix (e.g. C<txt:>) is stripped;
only the content is returned.

=cut

our $MAX_BULK_LEN   = 512 * 1024 * 1024;
our $MAX_ARRAY_ELEM = 1024 * 1024;

# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

=head2 encode_command(@args)

Encodes C<@args> as a RESP array-of-bulk-strings command and returns the
wire bytes. Every argument is converted to bytes first, so the bulk length
is always a byte count:

=over 4

=item *

A byte string (the normal case, including binary data) is sent as is.

=item *

A character string that holds only characters below 256 is sent as those
bytes (latin-1), exactly like the same text without the UTF-8 flag. A
character string with wide characters is sent as UTF-8. Replies are never
decoded: decode them yourself with L<Encode> if you stored text.

=item *

A Perl number (a scalar that holds a number and was never used as a string)
is sent in plain decimal form: integers as digits, floating point values in
the shortest decimal text that reads back as the same double, never in
exponent form (C<1e-05>), because the server's fixed-point parsers
(C<LLMBUDGET.SET> and the C<LLMSTATS.PRICE> prices) reject an exponent. See
C<format_double>. NaN is refused with an exception.

=item *

A string is never reformatted, even if it looks like a number: C<'1e-05'>
stored with C<SET> reads back as C<1e-05>. (A number that has already been
interpolated into a string counts as a string on Perl older than 5.36.)

=back

=cut

sub encode_command {
    my (@args) = @_;
    my $out = '*' . scalar(@args) . "\r\n";
    for my $arg (@args) {
        my $s;
        if (!defined $arg) {
            $s = '';
        }
        elsif (!ref($arg) && _is_pure_number($arg)) {
            $s = _number_text($arg);
        }
        else {
            $s = "$arg";
        }
        if (utf8::is_utf8($s) && !utf8::downgrade($s, 1)) {
            utf8::encode($s);
        }
        $out .= '$' . length($s) . "\r\n" . $s . "\r\n";
    }
    return $out;
}

# True for a scalar that was created as a number and has never been used as
# a string: the integer or floating point flag is set and the string flag is
# not. This is what builtin::created_as_number() reports on Perl 5.36 and
# later (there, interpolating a number does not set the public string flag).
# A string that was merely used in arithmetic keeps its string flag and is
# therefore still a string.
sub _is_pure_number {
    my $flags = B::svref_2object(\$_[0])->FLAGS;
    return (($flags & (B::SVf_IOK() | B::SVf_NOK())) && !($flags & B::SVf_POK())) ? 1 : 0;
}

# Text of a pure number: the Perl default text when it is already plain
# decimal and exact, else the plain decimal form of the double.
sub _number_text {
    my ($n) = @_;
    my $s = "$n";
    return $s if $s =~ /\A-?[0-9]+(?:\.[0-9]+)?\z/ && $s ne '-0' && $s == $n;
    return format_double($n + 0);
}

=head2 format_double($number)

Returns C<$number> as plain decimal text that the server's numeric parsers
accept: the shortest digit string that reads back as exactly the same
double (up to 17 significant digits), written without an exponent, with no
locale dependent decimal separator, no C<+> sign, no trailing zeros and no
decimal point for a whole value (C<5>, not C<5.0>). Positive and negative
infinity come out as C<inf> and C<-inf>, which standard commands such as
C<ZADD> and C<ZRANGEBYSCORE> accept. NaN raises an exception: no HotKV
command takes it.

  format_double(1e-05)   # 0.00001
  format_double(1e22)    # 10000000000000000000000
  format_double(-1.5e-7) # -0.00000015
  format_double(0.1+0.2) # 0.30000000000000004
  format_double(5)       # 5

=cut

sub format_double {
    my ($n) = @_;
    return _in_c_locale(\&_format_double, $n);
}

# Runs the code with LC_NUMERIC set to "C" when the process is in a locale
# whose decimal separator is not a point (older Perls apply such a locale to
# sprintf and to string to number conversion even without "use locale").
sub _in_c_locale {
    my ($code, @args) = @_;
    my $half = 0.5 + @args * 0; # not a constant, so sprintf is not folded at compile time
    return $code->(@args) if sprintf('%.1f', $half) eq '0.5';
    require POSIX;
    my $old = POSIX::setlocale(POSIX::LC_NUMERIC());
    POSIX::setlocale(POSIX::LC_NUMERIC(), 'C');
    my $r = eval { $code->(@args) };
    my $err = $@;
    POSIX::setlocale(POSIX::LC_NUMERIC(), $old) if defined $old;
    die $err if $err;
    return $r;
}

sub _format_double {
    my ($n) = @_;
    croak 'hotkv: undefined number' unless defined $n;
    $n += 0;
    croak 'hotkv: NaN is not a valid numeric argument' if $n != $n;
    return 'inf'  if $n == 9**9**9;
    return '-inf' if $n == -9**9**9;
    return '0' if $n == 0;

    my $e;
    for my $prec (0 .. 16) {
        $e = sprintf('%.*e', $prec, $n);
        last if $e + 0 == $n;
    }
    $e =~ /\A(-?)([0-9])(?:\.([0-9]+))?e([+-][0-9]+)\z/
        or croak "hotkv: cannot format number $n";
    my ($sign, $digits, $exp) = ($1, $2 . (defined $3 ? $3 : ''), $4 + 0);
    $digits =~ s/0+\z//;
    $digits = '0' if $digits eq '';
    my $point = $exp + 1; # digits before the decimal point
    my $len   = length $digits;
    my $text;
    if ($point <= 0) {
        $text = '0.' . ('0' x -$point) . $digits;
    }
    elsif ($point >= $len) {
        $text = $digits . ('0' x ($point - $len));
    }
    else {
        $text = substr($digits, 0, $point) . '.' . substr($digits, $point);
    }
    return $sign . $text;
}

=head2 format_usd($amount)

Returns C<$amount> (US dollars) in the fixed-point text the server's money
parsers accept (C<LLMBUDGET.SET>'s cost limit and every C<LLMSTATS.PRICE
SET> price): non-negative plain decimal, a digit before the point, at most
six fractional digits (micro-dollars), no sign, no exponent. A value that
is already in that form is returned unchanged (C<'0.0031'>, C<'12'>);
anything else is rounded to the nearest micro-dollar and written without
trailing zeros. Raises an exception for a negative, NaN, infinite or
non-numeric amount.

=cut

sub format_usd {
    my ($v) = @_;
    return _in_c_locale(\&_format_usd, $v);
}

sub _format_usd {
    my ($v) = @_;
    croak 'hotkv: undefined USD amount' unless defined $v;
    return "$v" if !ref($v) && "$v" =~ /\A[0-9]+(?:\.[0-9]{1,6})?\z/;
    croak "hotkv: not a valid USD amount: $v"
        unless !ref($v) && Scalar::Util::looks_like_number($v);
    my $n = $v + 0;
    croak "hotkv: not a valid USD amount: $v"
        if $n != $n || $n == 9**9**9 || $n == -9**9**9 || $n < 0;
    my $s = sprintf('%.6f', $n);
    $s =~ s/(\.[0-9]*?)0+\z/$1/;
    $s =~ s/\.\z//;
    return $s;
}

=head2 format_number($value)

For a numeric parameter of a typed method: a Perl number goes through
C<format_double> (a whole number stays a plain integer), a string that
holds a number in exponent form or with a leading C<+> (C<'1e-05'>) is
rewritten to plain decimal, and every other value, in particular a plain
decimal string such as C<'0.50'>, is returned untouched. C<undef> stays
C<undef>.

=cut

sub format_number {
    my ($v) = @_;
    return $v unless defined $v && !ref($v);
    return _number_text($v) if _is_pure_number($v);
    if ($v =~ /\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)[eE][+-]?[0-9]+\z/ || $v =~ /\A\+[0-9.]/) {
        return Scalar::Util::looks_like_number($v) ? format_double($v) : $v;
    }
    return $v;
}

# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------

package HotKV::Protocol::Reader;

use strict;
use warnings;
use Carp qw(croak);

=head1 NAME

HotKV::Protocol::Reader - Streaming RESP2/RESP3 decoder

=head1 SYNOPSIS

  # Backed by a live socket:
  my $r = HotKV::Protocol::Reader->new(fh => $socket, fill => sub {
      my ($sock, $timeout) = @_;
      ...  # return a chunk of bytes read from $sock, or '' on timeout, or
           # undef on EOF/error
  });

  # Backed by an in-memory buffer (unit tests, no server needed):
  my $r = HotKV::Protocol::Reader->new(buffer => $bytes);

  my $value = $r->read_reply;

=head1 METHODS

=head2 new(%opts)

C<buffer> seeds the internal buffer directly (used by unit tests). C<fill> is
a coderef invoked as C<< $fill->($fh, $timeout) >> whenever more bytes are
needed; it must return a (possibly empty) chunk of newly read bytes, or
C<undef> at EOF. C<fh> is passed through to C<fill> and is otherwise opaque
to the reader.

=head2 read_reply([$timeout])

Reads and decodes exactly one RESP value, returning the native Perl
representation described in L<HotKV::Protocol>. C<$timeout> (seconds) is
forwarded to the C<fill> callback for the first chunk only; once a reply has
started arriving it is read to completion without re-timing out, matching
common client behavior (a slow-arriving multi-bulk does not fail partway).

=cut

sub new {
    my ($class, %opts) = @_;
    return bless {
        buf   => (defined $opts{buffer} ? $opts{buffer} : ''),
        pos   => 0,
        fh    => $opts{fh},
        fill  => $opts{fill},
    }, $class;
}

sub _need {
    my ($self, $n, $timeout) = @_;
    while (length($self->{buf}) - $self->{pos} < $n) {
        if (!$self->{fill}) {
            HotKV::Error::Protocol->throw(message => 'hotkv: unexpected end of data');
        }
        my $chunk = $self->{fill}->($self->{fh}, $timeout);
        $timeout = undef; # only the first fill honors the caller's timeout
        if (!defined $chunk) {
            HotKV::Error::Connection->throw(message => 'hotkv: connection closed by server');
        }
        next if $chunk eq '';
        # Keep the buffer from growing unboundedly by compacting periodically.
        if ($self->{pos} > 65536) {
            $self->{buf} = substr($self->{buf}, $self->{pos});
            $self->{pos} = 0;
        }
        $self->{buf} .= $chunk;
    }
    return;
}

sub _read_line {
    my ($self, $timeout) = @_;
    # $scanned is a byte count relative to $self->{pos} (not an absolute
    # buffer index), so it stays correct across the buffer-compaction that
    # _need() may perform. It is left one byte short of the scanned region
    # so a lone trailing \r is re-examined once the next chunk's leading
    # byte (possibly \n) arrives, instead of being skipped over.
    my $scanned = 0;
    while (1) {
        my $idx = index($self->{buf}, "\r\n", $self->{pos} + $scanned);
        if ($idx >= 0) {
            my $line = substr($self->{buf}, $self->{pos}, $idx - $self->{pos});
            $self->{pos} = $idx + 2;
            return $line;
        }
        my $avail = length($self->{buf}) - $self->{pos};
        $scanned = $avail > 0 ? $avail - 1 : 0;
        $self->_need($avail + 1, $timeout);
        $timeout = undef;
    }
}

sub _read_bytes {
    my ($self, $n, $timeout) = @_;
    $self->_need($n, $timeout);
    my $bytes = substr($self->{buf}, $self->{pos}, $n);
    $self->{pos} += $n;
    return $bytes;
}

sub read_reply {
    my ($self, $timeout) = @_;
    return $self->_read_value(0, $timeout);
}

sub _read_value {
    my ($self, $depth, $timeout) = @_;
    if ($depth > 64) {
        HotKV::Error::Protocol->throw(message => 'hotkv: RESP nesting too deep');
    }
    my $type = $self->_read_bytes(1, $timeout);
    if ($type eq '+') {
        return $self->_read_line;
    }
    elsif ($type eq '-') {
        return HotKV::Error::Server->from_raw($self->_read_line);
    }
    elsif ($type eq ':') {
        return $self->_read_line + 0;
    }
    elsif ($type eq '$') {
        return $self->_read_bulk;
    }
    elsif ($type eq '*') {
        return $self->_read_array($depth);
    }
    elsif ($type eq '_') {
        $self->_read_line;
        return undef;
    }
    elsif ($type eq ',') {
        my $line = $self->_read_line;
        return $line eq 'inf'  ? 9**9**9
             : $line eq '-inf' ? -9**9**9
             : $line eq 'nan'  ? 'nan'
             : $line + 0;
    }
    elsif ($type eq '#') {
        my $line = $self->_read_line;
        return $line eq 't' ? 1 : 0;
    }
    elsif ($type eq '!') {
        my $len = $self->_read_line + 0;
        my $bytes = $self->_read_bytes($len + 2);
        return HotKV::Error::Server->from_raw(substr($bytes, 0, $len));
    }
    elsif ($type eq '=') {
        my $len = $self->_read_line + 0;
        my $bytes = substr($self->_read_bytes($len + 2), 0, $len);
        # Strip the 3-byte type prefix + ':' (e.g. "txt:") when present.
        if (length($bytes) >= 4 && substr($bytes, 3, 1) eq ':') {
            return substr($bytes, 4);
        }
        return $bytes;
    }
    elsif ($type eq '(') {
        return $self->_read_line;
    }
    elsif ($type eq '%') {
        return $self->_read_map($depth);
    }
    elsif ($type eq '~') {
        my $v = $self->_read_array($depth);
        return $v;
    }
    elsif ($type eq '|') {
        $self->_read_map($depth); # attributes are discarded
        return $self->_read_value($depth, $timeout);
    }
    elsif ($type eq '>') {
        my $push = $self->_read_array($depth);
        return defined $push ? bless($push, 'HotKV::Protocol::Push') : $push;
    }
    else {
        HotKV::Error::Protocol->throw(message => "hotkv: unknown RESP type byte '$type'");
    }
}

sub _read_bulk {
    my ($self) = @_;
    my $len = $self->_read_line;
    return undef if $len eq '-1';
    $len += 0;
    if ($len < 0 || $len > $HotKV::Protocol::MAX_BULK_LEN) {
        HotKV::Error::Protocol->throw(message => "hotkv: bulk length $len out of range");
    }
    my $bytes = $self->_read_bytes($len + 2);
    return substr($bytes, 0, $len);
}

sub _read_array {
    my ($self, $depth) = @_;
    my $count = $self->_read_line;
    return undef if $count eq '-1';
    $count += 0;
    if ($count < 0 || $count > $HotKV::Protocol::MAX_ARRAY_ELEM) {
        HotKV::Error::Protocol->throw(message => "hotkv: array length $count out of range");
    }
    my @elems;
    for (1 .. $count) {
        push @elems, $self->_read_value($depth + 1);
    }
    return \@elems;
}

sub _read_map {
    my ($self, $depth) = @_;
    my $count = $self->_read_line + 0;
    if ($count < 0 || $count > $HotKV::Protocol::MAX_ARRAY_ELEM) {
        HotKV::Error::Protocol->throw(message => "hotkv: map length $count out of range");
    }
    my %map;
    for (1 .. $count) {
        my $k = $self->_read_value($depth + 1);
        my $v = $self->_read_value($depth + 1);
        $map{$k} = $v;
    }
    return \%map;
}

1;
