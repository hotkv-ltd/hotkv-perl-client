# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;

use HotKV::Protocol;

# --- encode_command -------------------------------------------------------

is(
    HotKV::Protocol::encode_command('SET', 'foo', 'bar'),
    "*3\r\n\$3\r\nSET\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n",
    'encode_command builds a RESP array of bulk strings'
);

is(HotKV::Protocol::encode_command(), "*0\r\n", 'encode_command with no args');

my $binary = "a\x00b\r\nc"; # 6 bytes: a NUL b CR LF c
is(
    HotKV::Protocol::encode_command('SET', 'k', $binary),
    "*3\r\n\$3\r\nSET\r\n\$1\r\nk\r\n\$" . length($binary) . "\r\n$binary\r\n",
    'encode_command is binary safe (embedded NUL and CRLF)'
);

# --- decoding: RESP2 core types --------------------------------------------

sub reader_for { return HotKV::Protocol::Reader->new(buffer => $_[0]); }

is(reader_for("+OK\r\n")->read_reply, 'OK', 'simple string');
is(reader_for(":1000\r\n")->read_reply, 1000, 'integer');
is(reader_for(":-7\r\n")->read_reply, -7, 'negative integer');
is(reader_for("\$5\r\nhello\r\n")->read_reply, 'hello', 'bulk string');
is(reader_for("\$0\r\n\r\n")->read_reply, '', 'empty bulk string');
is(reader_for("\$-1\r\n")->read_reply, undef, 'null bulk string is undef');
is(reader_for("*-1\r\n")->read_reply, undef, 'null array is undef');
is_deeply(reader_for("*0\r\n")->read_reply, [], 'empty array');
is_deeply(
    reader_for("*3\r\n:1\r\n:2\r\n:3\r\n")->read_reply,
    [1, 2, 3],
    'array of integers'
);
is_deeply(
    reader_for("*2\r\n\$3\r\nfoo\r\n*2\r\n:1\r\n:2\r\n")->read_reply,
    ['foo', [1, 2]],
    'nested array'
);

{
    my $binary_reply = "a\x00b\r\nc";
    is(
        reader_for("\$" . length($binary_reply) . "\r\n$binary_reply\r\n")->read_reply,
        $binary_reply,
        'bulk string is binary safe (embedded NUL and CRLF)'
    );
}

# --- decoding: RESP2/RESP3 errors ------------------------------------------

{
    my $err = reader_for("-ERR something bad\r\n")->read_reply;
    isa_ok($err, 'HotKV::Error::Server');
    is($err->code, 'ERR', 'plain error code');
    is("$err", 'ERR something bad', 'error stringifies to the raw message');
}
{
    my $err = reader_for("-WRONGTYPE Operation against a wrong kind of value\r\n")->read_reply;
    is($err->code, 'WRONGTYPE', 'WRONGTYPE error code');
}
{
    my $err = reader_for("-NOLICENSE enterprise feature 'prompt-cache' requires a valid license\r\n")->read_reply;
    isa_ok($err, 'HotKV::Error::Server::NotLicensed');
    is($err->code, 'NOLICENSE', 'NOLICENSE error code');
}
{
    my $err = reader_for("-MOVED 1234 127.0.0.1:6400\r\n")->read_reply;
    isa_ok($err, 'HotKV::Error::Server::Moved');
    is($err->slot, 1234, 'MOVED slot parsed');
    is($err->host, '127.0.0.1', 'MOVED host parsed');
    is($err->port, 6400, 'MOVED port parsed');
}
{
    my $err = reader_for("-ASK 5061 10.0.0.9:6379\r\n")->read_reply;
    isa_ok($err, 'HotKV::Error::Server::Ask');
    is($err->slot, 5061, 'ASK slot parsed');
    is($err->host, '10.0.0.9', 'ASK host parsed');
    is($err->port, 6379, 'ASK port parsed');
}
{
    my $msg = 'SYNTAX invalid arg';
    my $err = reader_for('!' . length($msg) . "\r\n$msg\r\n")->read_reply;
    isa_ok($err, 'HotKV::Error::Server', 'RESP3 blob error decodes the same as a simple error');
    is($err->code, 'SYNTAX', 'blob error code');
}

# --- decoding: RESP3 types ---------------------------------------------

is(reader_for("_\r\n")->read_reply, undef, 'RESP3 null');
is(reader_for(",3.14\r\n")->read_reply, 3.14, 'RESP3 double');
is(reader_for(",10\r\n")->read_reply, 10, 'RESP3 double, integral value');
cmp_ok(reader_for(",inf\r\n")->read_reply, '>', 1e300, 'RESP3 double +inf');
cmp_ok(reader_for(",-inf\r\n")->read_reply, '<', -1e300, 'RESP3 double -inf');
is(reader_for("#t\r\n")->read_reply, 1, 'RESP3 boolean true');
is(reader_for("#f\r\n")->read_reply, 0, 'RESP3 boolean false');
is(reader_for("(12345678901234567890\r\n")->read_reply, '12345678901234567890', 'RESP3 big number (as string)');
is(reader_for("=9\r\ntxt:hello\r\n")->read_reply, 'hello', 'RESP3 verbatim string strips the txt: prefix');
is(reader_for("=10\r\nmkd:*bold*\r\n")->read_reply, '*bold*', 'RESP3 verbatim string strips the mkd: prefix');

is_deeply(
    reader_for("%2\r\n\$1\r\na\r\n:1\r\n\$1\r\nb\r\n:2\r\n")->read_reply,
    { a => 1, b => 2 },
    'RESP3 map decodes to a hashref'
);
is_deeply(
    reader_for("~3\r\n:1\r\n:2\r\n:3\r\n")->read_reply,
    [1, 2, 3],
    'RESP3 set decodes to an arrayref'
);
is_deeply(
    reader_for(">3\r\n\$7\r\nmessage\r\n\$4\r\nchan\r\n\$5\r\nhello\r\n")->read_reply,
    ['message', 'chan', 'hello'],
    'RESP3 push decodes to an arrayref, same shape as a RESP2 pub/sub array'
);

# Attribute: discarded, the value that follows is what is returned.
is(
    reader_for("|1\r\n\$8\r\nkeyspace\r\n\$2\r\nhi\r\n+OK\r\n")->read_reply,
    'OK',
    'RESP3 attribute is discarded; the following value is returned'
);

# --- streaming / partial reads --------------------------------------------

{
    # A "fill" callback that trickles the bytes in one at a time, to prove
    # the reader copes with a value that arrives split across many reads.
    my $whole = "*2\r\n\$5\r\nhello\r\n\$5\r\nworld\r\n";
    my @chunks = split //, $whole;
    my $r = HotKV::Protocol::Reader->new(fill => sub {
        return @chunks ? shift(@chunks) : undef;
    });
    is_deeply($r->read_reply, ['hello', 'world'], 'reader reassembles a value delivered one byte at a time');
}

{
    # Two replies back to back in one buffer: the reader must leave the
    # second one untouched after decoding the first.
    my $r = reader_for("+OK\r\n:42\r\n");
    is($r->read_reply, 'OK', 'first of two pipelined replies');
    is($r->read_reply, 42, 'second of two pipelined replies, from the same buffer');
}

{
    # EOF while a value is incomplete: connection-loss style error, not a
    # silent truncation.
    my $r = HotKV::Protocol::Reader->new(fill => sub { return undef; });
    my $err = eval { $r->read_reply; 1 } ? undef : $@;
    ok($err, 'EOF mid-value raises');
    isa_ok($err, 'HotKV::Error::Connection');
}

done_testing();
