# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# No HotKV server needed: a tiny forked RESP3 responder that answers every
# command with a RESP3 push message (a client side caching invalidation)
# followed by +OK. The push is not the reply: it must be skipped and handed
# to the on_push callback, and the command must still return OK.

use strict;
use warnings;
use Test::More;
use IO::Socket::INET;

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
    while (my $c = $listener->accept) {
        my $buf = '';
        while (sysread($c, my $chunk, 4096)) {
            $buf .= $chunk;
            while ($buf =~ s/\A\*(\d+)\r\n//) {
                my $count = $1;
                my @args;
                for (1 .. $count) {
                    if ($buf =~ s/\A\$(\d+)\r\n//) {
                        my $len = $1;
                        push @args, substr($buf, 0, $len, '');
                        $buf =~ s/\A\r\n//;
                    }
                }
                my $cmd = uc($args[0] // '');
                if ($cmd eq 'HELLO') {
                    print $c "%1\r\n+proto\r\n:3\r\n";
                }
                else {
                    print $c ">2\r\n\$10\r\ninvalidate\r\n*1\r\n\$1\r\nk\r\n";
                    print $c "+OK\r\n";
                }
            }
        }
        close $c;
    }
    exit 0;
}
close $listener;

my @pushes;
my $kv = HotKV->new(host => '127.0.0.1', port => $port, pool_size => 1, command_timeout => 2,
    on_push => sub { push @pushes, $_[0] });

is($kv->set('a', 1), 'OK', 'the command returns its reply, not the push that preceded it');
is_deeply([map { [@$_] } @pushes], [['invalidate', ['k']]], 'the push went to on_push');
isa_ok($pushes[0], 'HotKV::Protocol::Push', 'the push');
is($kv->get('a'), 'OK', 'the next command works the same way');
is(scalar(@pushes), 2, 'one push per command');

$kv->close; # the responder serves one connection at a time
my $quiet = HotKV->new(host => '127.0.0.1', port => $port, pool_size => 1, command_timeout => 2);
is($quiet->set('b', 2), 'OK', 'without on_push the push is dropped and the reply is returned');

$quiet->close;
kill 'KILL', $pid;
waitpid($pid, 0);
done_testing;
