# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();
plan skip_all => 'fork() is required to run the pub/sub tests' unless eval { require POSIX; 1 };

use HotKV;

my $URL = test_url();

sub publish_after_delay {
    my (@commands) = @_; # list of [cmd, args...]
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        select(undef, undef, undef, 0.2);
        my $pub = HotKV->new(url => $URL);
        $pub->command(@$_) for @commands;
        $pub->close;
        POSIX::_exit(0);
    }
    return $pid;
}

# --- SUBSCRIBE / regular PUBLISH -------------------------------------------

{
    my $chan = unique_name('chan');
    my $pid = publish_after_delay(['PUBLISH', $chan, 'hello']);

    my @events;
    my $kv = HotKV->new(url => $URL);
    $kv->subscribe([$chan], sub {
        my ($ev, $ctrl) = @_;
        push @events, $ev;
        $ctrl->stop if $ev->{type} eq 'message';
    });
    waitpid($pid, 0);

    is(scalar(@events), 2, 'received a subscribe confirmation and one message');
    is($events[0]{type}, 'subscribe', 'first event is the subscribe confirmation');
    is($events[0]{channel}, $chan, 'subscribe confirmation names the channel');
    is($events[0]{count}, 1, 'subscribe confirmation counts one active subscription');
    is($events[1]{type}, 'message', 'second event is the message');
    is($events[1]{channel}, $chan, 'message names the channel');
    is($events[1]{data}, 'hello', 'message carries the published payload');
    $kv->close;
}

# --- PSUBSCRIBE --------------------------------------------------------

{
    my $base = unique_name('pat');
    my $chan = "$base.news";
    my $pid = publish_after_delay(['PUBLISH', $chan, 'pattern-hit']);

    my @events;
    my $kv = HotKV->new(url => $URL);
    $kv->psubscribe(["$base.*"], sub {
        my ($ev, $ctrl) = @_;
        push @events, $ev;
        $ctrl->stop if $ev->{type} eq 'pmessage';
    });
    waitpid($pid, 0);

    is($events[-1]{type}, 'pmessage', 'pmessage received for a pattern match');
    is($events[-1]{pattern}, "$base.*", 'pmessage carries the matched pattern');
    is($events[-1]{channel}, $chan, 'pmessage carries the actual channel');
    is($events[-1]{data}, 'pattern-hit', 'pmessage carries the payload');
    $kv->close;
}

# --- SSUBSCRIBE / SPUBLISH ("smessage") ------------------------------------

{
    my $schan = unique_name('schan');
    my $pid = publish_after_delay(['SPUBLISH', $schan, 'shard-hello']);

    my @events;
    my $kv = HotKV->new(url => $URL);
    $kv->ssubscribe([$schan], sub {
        my ($ev, $ctrl) = @_;
        push @events, $ev;
        $ctrl->stop if $ev->{type} eq 'smessage';
    });
    waitpid($pid, 0);

    is($events[0]{type}, 'ssubscribe', 'ssubscribe confirmation received');
    is($events[-1]{type}, 'smessage', 'smessage event type is exactly "smessage"');
    is($events[-1]{channel}, $schan, 'smessage carries the shard channel');
    is($events[-1]{data}, 'shard-hello', 'smessage carries the payload');
    $kv->close;
}

# --- multiple channels and UNSUBSCRIBE via the control object -----------

{
    my $c1 = unique_name('multi1');
    my $c2 = unique_name('multi2');
    my $pid = publish_after_delay(['PUBLISH', $c1, 'one'], ['PUBLISH', $c2, 'two']);

    my @events;
    my $kv = HotKV->new(url => $URL);
    my $messages_seen = 0;
    $kv->subscribe([$c1, $c2], sub {
        my ($ev, $ctrl) = @_;
        push @events, $ev;
        if ($ev->{type} eq 'message') {
            $messages_seen++;
            $ctrl->stop if $messages_seen >= 2;
        }
    });
    waitpid($pid, 0);

    my @sub_confirms = grep { $_->{type} eq 'subscribe' } @events;
    is(scalar(@sub_confirms), 2, 'subscribing to two channels at once yields two confirmations');
    my @messages = grep { $_->{type} eq 'message' } @events;
    is(scalar(@messages), 2, 'received a message on each of the two channels');
    is_deeply([sort map { $_->{channel} } @messages], [sort ($c1, $c2)], 'messages came from both channels');
    $kv->close;
}

done_testing();
