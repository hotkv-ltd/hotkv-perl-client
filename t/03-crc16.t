# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;

use HotKV::CRC16 qw(crc16 key_slot);

is(crc16('123456789'), 0x31C3, 'raw CRC16/XMODEM of "123456789" is 0x31C3');

my %vectors = (
    'foo'                   => 12182,
    'bar'                   => 5061,
    'hello'                 => 866,
    '{user1000}.following'  => 3443,
    '{user1000}.followers'  => 3443,
    '{}foo'                 => 9500,
    'foo{}{bar}'            => 8363,
    'foo{{bar}}zap'         => 4015,
    'foo{bar}{zap}'         => 5061,
);

for my $key (sort keys %vectors) {
    is(key_slot($key), $vectors{$key}, "key_slot('$key') == $vectors{$key}");
}

is(key_slot('{user1000}.following'), key_slot('{user1000}.followers'),
    'two keys sharing a hash tag land on the same slot');

ok(key_slot('anything') >= 0 && key_slot('anything') <= 16383, 'slot is always in range 0..16383');

done_testing();
