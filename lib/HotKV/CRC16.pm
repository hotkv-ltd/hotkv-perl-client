# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::CRC16;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(crc16 key_slot);
our $VERSION   = '1.0.0';

=head1 NAME

HotKV::CRC16 - CRC16/XMODEM checksum and cluster key slot calculation

=head1 SYNOPSIS

  use HotKV::CRC16 qw(crc16 key_slot);
  crc16("123456789");       # 0x31C3
  key_slot("{user1000}.x"); # slot of "user1000"

=head1 FUNCTIONS

=head2 crc16($bytes)

The raw CRC16/XMODEM checksum (polynomial 0x1021, initial value 0, no
reflection) HotKV cluster mode uses.

=head2 key_slot($key)

The cluster hash slot (0..16383) for C<$key>, honoring C<{hash tag}>
substrings exactly like C<CLUSTER KEYSLOT>: when the key contains C<{> and a
C<}> follows it with at least one byte in between, only the bytes between
them are hashed; otherwise the whole key is hashed.

=cut

my @TABLE;

BEGIN {
    for my $byte (0 .. 255) {
        my $crc = $byte << 8;
        for (1 .. 8) {
            $crc = ($crc & 0x8000) ? (($crc << 1) ^ 0x1021) : ($crc << 1);
            $crc &= 0xFFFF;
        }
        $TABLE[$byte] = $crc;
    }
}

sub crc16 {
    my ($data) = @_;
    $data = '' unless defined $data;
    my $crc = 0;
    for my $byte (unpack 'C*', $data) {
        $crc = (($crc << 8) & 0xFFFF) ^ $TABLE[(($crc >> 8) ^ $byte) & 0xFF];
    }
    return $crc;
}

sub key_slot {
    my ($key) = @_;
    $key = '' unless defined $key;
    my $hashed = $key;
    my $open = index($key, '{');
    if ($open >= 0) {
        my $close = index($key, '}', $open + 1);
        if ($close > $open + 1) {
            $hashed = substr($key, $open + 1, $close - $open - 1);
        }
    }
    return crc16($hashed) % 16384;
}

1;
