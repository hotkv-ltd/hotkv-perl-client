# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# No HotKV server needed: a tiny forked RESP2 responder that closes the first
# connection a moment after answering, like a server with an idle `timeout`.
# The pooled connection must be recognised as dead before the next command
# uses it, so that command succeeds, even though it is a write (which the
# client never retries after a failure in flight).

use strict;
use warnings;
use Test::More;
use IO::Socket::INET;
use IO::Select;

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
    # Responder: answer every command with +OK (HELLO with an error, so the
    # client falls back to RESP2). The first connection is closed 0.3 s
    # after its first command was answered.
    my $n = 0;
    while (my $c = $listener->accept) {
        $n++;
        my $close_at;
        my $sel = IO::Select->new($c);
        my $buf = '';
        while (1) {
            if (defined $close_at && time() >= $close_at) { last; }
            next unless $sel->can_read(0.05);
            my $got = sysread($c, my $chunk, 4096);
            last unless $got;
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
                print $c ($cmd eq 'HELLO' ? "-ERR unknown command 'HELLO'\r\n" : "+OK\r\n");
                $close_at = time() + 0.3 if $n == 1 && $cmd ne 'HELLO' && !defined $close_at;
            }
        }
        close $c;
    }
    exit 0;
}
close $listener;

my $kv = HotKV->new(host => '127.0.0.1', port => $port, pool_size => 1, command_timeout => 2);

is($kv->set('a', 1), 'OK', 'first command on connection 1');
select(undef, undef, undef, 0.9); # the responder closes connection 1 meanwhile
my $r = eval { $kv->set('b', 2) };
is($@, '', 'a write after the server closed the idle pooled connection does not raise');
is($r, 'OK', 'and succeeds on a fresh connection');
is($kv->set('c', 3), 'OK', 'the new connection keeps working');

$kv->close;
kill 'KILL', $pid;
waitpid($pid, 0);
done_testing;
