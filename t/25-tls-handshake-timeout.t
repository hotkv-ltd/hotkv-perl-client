# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# No HotKV server needed: a TCP listener that accepts and then says nothing
# stands in for a server that never completes the TLS handshake. The client
# must give up after connect_timeout, not wait for ever.

use strict;
use warnings;
use Test::More;
use IO::Socket::INET;
use Time::HiRes qw(time);

plan skip_all => 'IO::Socket::SSL is needed for TLS' unless eval { require IO::Socket::SSL; 1 };

use HotKV;

# A hung test must fail, not block the whole run.
$SIG{ALRM} = sub { diag('test timed out'); exit 255; };
alarm 60;

my $listener = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1)
    or plan skip_all => "cannot listen on a local port: $!";
my $port = $listener->sockport;

my $pid = fork();
die "fork: $!" unless defined $pid;
my $parent = $$;
# However this test ends, the responder must not outlive it (it would hold prove's pipe open).
END { kill 'KILL', $pid if defined $pid && $pid && $$ == $parent; }
if (!$pid) {
    $SIG{TERM} = 'DEFAULT';
    alarm 0;
    my @held;
    while (my $c = $listener->accept) { push @held, $c; } # accept, then stay silent
    exit 0;
}
close $listener;

my $kv = HotKV->new(host => '127.0.0.1', port => $port, tls => 1, tls_insecure_skip_verify => 1,
    connect_timeout => 1, command_timeout => 5);
my $t0 = time;
my $err = eval { $kv->ping; 1 } ? undef : $@;
my $took = time - $t0;

ok($err, 'a server that never answers the TLS handshake is an error');
ok($err && ref($err) && $err->isa('HotKV::Error::Connection'), 'a HotKV::Error::Connection');
cmp_ok($took, '<', 4, 'raised after about connect_timeout, not after command_timeout or never');

kill 'KILL', $pid;
waitpid($pid, 0);
done_testing;
