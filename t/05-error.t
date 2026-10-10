# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;

use HotKV::Error;

# --- hierarchy ---------------------------------------------------------

ok(HotKV::Error::Connection->new->isa('HotKV::Error'), 'Connection isa Error');
ok(HotKV::Error::Timeout->new->isa('HotKV::Error::Connection'), 'Timeout isa Connection');
ok(HotKV::Error::Timeout->new->isa('HotKV::Error'), 'Timeout isa Error');
ok(HotKV::Error::Protocol->new->isa('HotKV::Error'), 'Protocol isa Error');
ok(HotKV::Error::Server->new->isa('HotKV::Error'), 'Server isa Error');
ok(HotKV::Error::Server::NotLicensed->new->isa('HotKV::Error::Server'), 'NotLicensed isa Server');
ok(HotKV::Error::Server::Moved->new->isa('HotKV::Error::Server'), 'Moved isa Server');
ok(HotKV::Error::Server::Ask->new->isa('HotKV::Error::Server'), 'Ask isa Server');

# --- construction / throw / stringification -----------------------------

{
    my $err = eval { HotKV::Error::Connection->throw(message => 'boom'); 1 } ? undef : $@;
    ok($err, 'throw() dies');
    isa_ok($err, 'HotKV::Error::Connection');
    is("$err", 'boom', 'stringification overload uses message()');
    is($err->message, 'boom', 'message accessor');
}

# --- HotKV::Error::Server::from_raw parsing --------------------------------

{
    my $e = HotKV::Error::Server->from_raw('ERR wrong number of arguments');
    isa_ok($e, 'HotKV::Error::Server');
    ok(!$e->isa('HotKV::Error::Server::NotLicensed'), 'plain ERR is not NotLicensed');
    is($e->code, 'ERR', 'code is the prefix');
    is($e->raw, 'ERR wrong number of arguments', 'raw is the full text');
}

{
    my $e = HotKV::Error::Server->from_raw("NOLICENSE enterprise feature 'prompt-cache' requires a valid license");
    isa_ok($e, 'HotKV::Error::Server::NotLicensed');
    is($e->code, 'NOLICENSE', 'NOLICENSE code');
}

{
    my $e = HotKV::Error::Server->from_raw('MOVED 3999 192.168.1.10:6381');
    isa_ok($e, 'HotKV::Error::Server::Moved');
    is($e->code, 'MOVED', 'MOVED code');
    is($e->slot, 3999, 'MOVED slot');
    is($e->host, '192.168.1.10', 'MOVED host');
    is($e->port, 6381, 'MOVED port');
}

{
    my $e = HotKV::Error::Server->from_raw('ASK 3999 192.168.1.11:6381');
    isa_ok($e, 'HotKV::Error::Server::Ask');
    is($e->slot, 3999, 'ASK slot');
    is($e->host, '192.168.1.11', 'ASK host');
    is($e->port, 6381, 'ASK port');
}

{
    # A code-only error with no message text still parses cleanly.
    my $e = HotKV::Error::Server->from_raw('NOAUTH');
    is($e->code, 'NOAUTH', 'code-only error (no trailing message)');
}

done_testing();
