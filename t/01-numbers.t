# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# Unit tests (no server): how numbers, strings and wide characters are put
# on the wire, and how long the client waits for a blocking command.

use strict;
use warnings;
use Test::More;

use HotKV::Protocol;
use HotKV::Connection;

sub wire { return HotKV::Protocol::encode_command(@_); }
sub bulk { my $s = shift; return '$' . length($s) . "\r\n$s\r\n"; }

# --- format_double ---------------------------------------------------------

my @double_cases = (
    [ 1e-05,            '0.00001' ],
    [ 1e-07,            '0.0000001' ],
    [ -1.5e-07,         '-0.00000015' ],
    [ 2**-1074,         '0.' . ('0' x 323) . '5' ],
    [ 1e22,             '1' . ('0' x 22) ],
    [ 1e15,             '1000000000000000' ],
    [ 1.5e300,          '15' . ('0' x 299) ],
    [ -2.5e20,          '-25' . ('0' x 19) ],
    [ 5.0,              '5' ],
    [ 0.5,              '0.5' ],
    [ -0.25,            '-0.25' ],
    [ 100,              '100' ],
    [ 0,                '0' ],
    [ -0.0,             '0' ],
    [ 0.1 + 0.2,        '0.30000000000000004' ],
    [ 1 / 3,            ($] >= 5.030 ? '0.3333333333333333' : '0.33333333333333331') ],
    [ 123456.789,       '123456.789' ],
    [ 0.000123456789,   '0.000123456789' ],
    [ 1e21 + 1e5,       '1' . ('0' x 15) . '100000' ],
);
for my $c (@double_cases) {
    my ($n, $want) = @$c;
    my $got = HotKV::Protocol::format_double($n);
    # Perl before 5.30 reads long digit strings back inexactly, so for a
    # denormal it settles on more digits than the shortest; same value.
    if ($] < 5.030 && $want =~ /\A0\.0{300}/) {
        like($got, qr/\A0\.0{300}\d+\z/, 'format_double of the smallest denormal (old Perl: not the shortest form)');
    }
    else {
        is($got, $want, "format_double($want)");
    }
    unlike($got, qr/[eE]/, "  no exponent in $got");
    # Perl before 5.30 converts long digit strings to numbers inexactly; the server's strtod does not.
    cmp_ok($got + 0, '==', $n, '  reads back as the same double') if $] >= 5.030;
}
is(HotKV::Protocol::format_double(9**9**9),  'inf',  'format_double +inf');
is(HotKV::Protocol::format_double(-9**9**9), '-inf', 'format_double -inf');
eval { HotKV::Protocol::format_double(9**9**9 - 9**9**9) };
like($@, qr/NaN/, 'format_double refuses NaN');

# --- format_usd ------------------------------------------------------------

my @usd_cases = (
    [ '0.0031',    '0.0031' ],     # plain decimal string passes through
    [ '12',        '12' ],
    [ '12.500000', '12.500000' ],
    [ 0.00001,     '0.00001' ],
    [ 1e-05,       '0.00001' ],
    [ '1e-05',     '0.00001' ],
    [ 2.6e-06,     '0.000003' ],   # rounded to a micro-dollar
    [ 1e-09,       '0' ],
    [ 1500,        '1500' ],
    [ 1.5e3,       '1500' ],
    [ 12.5,        '12.5' ],
    [ 0.1 + 0.2,   '0.3' ],
    [ 1e12,        '1000000000000' ],
    [ '.5',        '0.5' ],
    [ '12.',       '12' ],
    [ '12.1234567', '12.123457' ],
);
for my $c (@usd_cases) {
    my ($in, $want) = @$c;
    is(HotKV::Protocol::format_usd($in), $want, "format_usd($in) -> $want");
}
for my $bad (-1, '-0.5', 'abc', '', 9**9**9, -9**9**9, 9**9**9 - 9**9**9) {
    eval { HotKV::Protocol::format_usd($bad) };
    ok($@, "format_usd refuses '$bad'");
}
eval { HotKV::Protocol::format_usd(undef) };
ok($@, 'format_usd refuses undef');

# --- format_number ---------------------------------------------------------

is(HotKV::Protocol::format_number(1e-05),  '0.00001', 'format_number: float to plain decimal');
is(HotKV::Protocol::format_number('1e-05'), '0.00001', 'format_number: exponent string to plain decimal');
is(HotKV::Protocol::format_number('+0.5'), '0.5', 'format_number: leading + removed');
is(HotKV::Protocol::format_number('0.50'), '0.50', 'format_number: plain decimal string untouched');
is(HotKV::Protocol::format_number('abc'),  'abc', 'format_number: non number untouched');
is(HotKV::Protocol::format_number(7),      '7', 'format_number: integer untouched');
is(HotKV::Protocol::format_number(undef),  undef, 'format_number: undef stays undef');

# --- encode_command: numbers -----------------------------------------------

is(wire('ZADD', 'z', 1e-05, 'm'),
    "*4\r\n" . bulk('ZADD') . bulk('z') . bulk('0.00001') . bulk('m'),
    'a tiny float is sent as plain decimal');
is(wire('INCRBYFLOAT', 'k', -1e22),
    "*3\r\n" . bulk('INCRBYFLOAT') . bulk('k') . bulk('-1' . ('0' x 22)),
    'a huge negative float is sent without exponent');
is(wire('SET', 'k', 5.0), "*3\r\n" . bulk('SET') . bulk('k') . bulk('5'),
    'an integral float gains no decimal point');
is(wire('SET', 'k', 42), "*3\r\n" . bulk('SET') . bulk('k') . bulk('42'), 'an integer is unchanged');
is(wire('SET', 'k', -7), "*3\r\n" . bulk('SET') . bulk('k') . bulk('-7'), 'a negative integer is unchanged');
is(wire('SET', 'k', 18446744073709551615),
    "*3\r\n" . bulk('SET') . bulk('k') . bulk('18446744073709551615'), 'a 64 bit unsigned integer is unchanged');
is(wire('SET', 'k', 0.1 + 0.2), "*3\r\n" . bulk('SET') . bulk('k') . bulk('0.30000000000000004'),
    'a float keeps every digit that matters');
eval { wire('ZADD', 'z', 9**9**9 - 9**9**9, 'm') };
like($@, qr/NaN/, 'NaN is refused at encode time');
is(wire('ZADD', 'z', 9**9**9, 'm'), "*4\r\n" . bulk('ZADD') . bulk('z') . bulk('inf') . bulk('m'),
    'infinity is sent as inf');

# --- encode_command: strings are never reformatted -------------------------

is(wire('SET', 'k', '1e-05'), "*3\r\n" . bulk('SET') . bulk('k') . bulk('1e-05'),
    'the string 1e-05 is stored verbatim');
is(wire('SET', 'k', '0.50'), "*3\r\n" . bulk('SET') . bulk('k') . bulk('0.50'), 'the string 0.50 is stored verbatim');
is(wire('SET', 'k', '007'), "*3\r\n" . bulk('SET') . bulk('k') . bulk('007'), 'the string 007 is stored verbatim');
is(wire('SET', 'k', ''), "*3\r\n" . bulk('SET') . bulk('k') . bulk(''), 'the empty string');
is(wire('SET', 'k', undef), "*3\r\n" . bulk('SET') . bulk('k') . bulk(''), 'undef is sent as the empty string');
{
    my $numeric_string = '1e-05';
    my $used_as_number = $numeric_string + 0; # now also holds an NV
    is(wire('SET', 'k', $numeric_string), "*3\r\n" . bulk('SET') . bulk('k') . bulk('1e-05'),
        'a string that was once used as a number is still a string');
}

# --- encode_command: bytes and characters ----------------------------------

my $binary = "a\x00b\r\n\xff";
is(wire('SET', 'k', $binary), "*3\r\n" . bulk('SET') . bulk('k') . bulk($binary), 'binary data with high bytes');
{
    my $wide = "caf\x{e9} \x{263a}";           # e-acute and a smiley
    my $utf8 = "caf\xc3\xa9 \xe2\x98\xba";
    is(wire('SET', 'k', $wide), "*3\r\n" . bulk('SET') . bulk('k') . bulk($utf8),
        'a string with wide characters is sent as UTF-8 and the bulk length counts bytes');
    my $latin = "caf\x{e9}";
    utf8::upgrade($latin);
    is(wire('SET', 'k', $latin), "*3\r\n" . bulk('SET') . bulk('k') . bulk("caf\xe9"),
        'a flagged string with only latin-1 characters is sent as those bytes, like the unflagged form');
}

# --- encode_command does not touch the caller's variables ------------------

{
    my $n = 1e-05;
    wire('SET', 'k', $n);
    ok(!HotKV::Protocol::_is_pure_number('' . $n) , 'sanity: a string is not a pure number');
    is($n, 1e-05, 'the caller number is unchanged');
}

# --- locale independence ---------------------------------------------------

SKIP: {
    require POSIX;
    my $set;
    for my $loc (qw(de_DE.UTF-8 de_DE.utf8 fr_FR.UTF-8 fr_FR.utf8 de_DE)) {
        if (POSIX::setlocale(POSIX::LC_NUMERIC(), $loc)) { $set = $loc; last; }
    }
    skip 'no comma-decimal locale installed', 3 unless $set;
    is(HotKV::Protocol::format_double(1.5), '1.5', "format_double ignores the $set locale");
    is(HotKV::Protocol::format_usd(0.25 + 0.5), '0.75', "format_usd ignores the $set locale");
    is(HotKV::Protocol::encode_command('ZADD', 'z', 1.5e-05, 'm'), "*4\r\n" . bulk('ZADD') . bulk('z') . bulk('0.000015') . bulk('m'), "encode_command ignores the $set locale");
    POSIX::setlocale(POSIX::LC_NUMERIC(), 'C');
}

# --- server_wait / timeout_for ---------------------------------------------

my %wait = (
    'BLPOP a b 10'            => 10,
    'BRPOP a 0'               => 0,
    'BRPOPLPUSH a b 2.5'      => 2.5,
    'BLMOVE a b LEFT RIGHT 3' => 3,
    'BZPOPMIN z 7'            => 7,
    'BZPOPMAX z 1'            => 1,
    'BLMPOP 5 1 k LEFT'       => 5,
    'BZMPOP 0 1 z MIN'        => 0,
    'XREAD BLOCK 2500 STREAMS s $'  => 2.5,
    'XREAD COUNT 1 block 0 STREAMS s $' => 0,
    'XREADGROUP GROUP g c BLOCK 1000 STREAMS s >' => 1,
    'WAIT 1 3000'             => 3,
    'WAITAOF 1 0 2000'        => 2,
);
for my $cmd (sort keys %wait) {
    is(HotKV::Connection::server_wait(split ' ', $cmd), $wait{$cmd}, "server_wait: $cmd");
}
for my $cmd ('GET k', 'SET k v', 'XREAD STREAMS s 0', 'XREAD COUNT 1 STREAMS BLOCK 5', 'LPOP k', 'PING') {
    is(HotKV::Connection::server_wait(split ' ', $cmd), undef, "server_wait: $cmd does not block");
}

my $c = HotKV::Connection->new(command_timeout => 5);
is($c->timeout_for('GET', 'k'), 5, 'an ordinary command waits command_timeout');
is($c->timeout_for('BLPOP', 'k', 10), 15, 'BLPOP waits its own timeout plus command_timeout');
is($c->timeout_for('BLPOP', 'k', 0), undef, 'BLPOP with timeout 0 waits forever');
my $c2 = HotKV::Connection->new(command_timeout => undef);
is($c2->timeout_for('GET', 'k'), undef, 'command_timeout undef waits forever');

done_testing;
