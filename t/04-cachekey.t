# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use utf8;
use Test::More;

use Digest::SHA qw(sha256_hex);
use Encode qw(encode);

use HotKV::AI::PromptCache;

sub key { return HotKV::AI::PromptCache->cache_key(@_); }

# --- exact canonical form, cross-checked against a hand-built JSON string --

{
    my $json = '{"provider":"openai","model":"gpt-6-sol","system":"","messages":'
        . '[{"role":"user","content":"Hello"}],"params":{"temperature":"0.7","top_p":"0.9"}}';
    my $expect = sha256_hex(encode('UTF-8', $json));

    my $got = key(
        provider => 'openai',
        model    => 'gpt-6-sol',
        messages => [{ role => 'user', content => 'Hello' }],
        params   => { temperature => '0.7', top_p => '0.9' },
    );
    is($got, $expect, 'cache_key matches an independently hand-built canonical JSON string');
    like($got, qr/^[0-9a-f]{64}\z/, 'cache_key is a 64-char lowercase hex string');
}

# --- determinism: hash iteration order must not matter --------------------

{
    my $a = key(
        provider => 'p', model => 'm', messages => [],
        params   => { zeta => '1', alpha => '2', mid => '3' },
    );
    my $b = key(
        provider => 'p', model => 'm', messages => [],
        params   => { mid => '3', alpha => '2', zeta => '1' },
    );
    is($a, $b, 'params key order in the caller-supplied hash does not affect the key');
}

# --- missing optional fields are present as "" / {}, never omitted --------

{
    my $with_empty = key(provider => 'p', model => 'm', system => '', messages => [], params => {});
    my $omitted    = key(provider => 'p', model => 'm', messages => []);
    is($with_empty, $omitted, 'omitting system/params is identical to passing "" and {}');

    my $expect = sha256_hex(encode('UTF-8', '{"provider":"p","model":"m","system":"","messages":[],"params":{}}'));
    is($omitted, $expect, 'empty system/params/messages produce the exact expected JSON');
}

# --- message order is preserved, not sorted --------------------------------

{
    my $a = key(provider => 'p', model => 'm', messages => [
        { role => 'system', content => 'first' },
        { role => 'user',   content => 'second' },
    ]);
    my $b = key(provider => 'p', model => 'm', messages => [
        { role => 'user',   content => 'second' },
        { role => 'system', content => 'first' },
    ]);
    isnt($a, $b, 'message order matters (it is not sorted)');
}

# --- escaping: quotes, backslashes, control chars as \uXXXX, non-ASCII literal --

{
    my $content = "line1\nline2\ttab\"quote\\slash";
    my $expect  = sha256_hex(encode('UTF-8',
        '{"provider":"p","model":"m","system":"","messages":[{"role":"user","content":"'
        . 'line1\u000aline2\u0009tab\"quote\\\\slash'
        . '"}],"params":{}}'
    ));
    my $got = key(provider => 'p', model => 'm', messages => [{ role => 'user', content => $content }]);
    is($got, $expect, 'control characters escape as \uXXXX, quote and backslash are escaped');
}

{
    # Non-ASCII stays as literal UTF-8 bytes, not \uXXXX.
    my $content = "caf\x{e9} \x{4e2d}\x{6587}"; # "café 中文"
    my $expect  = sha256_hex(encode('UTF-8',
        '{"provider":"p","model":"m","system":"","messages":[{"role":"user","content":"'
        . $content
        . '"}],"params":{}}'
    ));
    my $got = key(provider => 'p', model => 'm', messages => [{ role => 'user', content => $content }]);
    is($got, $expect, 'non-ASCII characters are left as literal UTF-8, not \uXXXX-escaped');
}

# --- different logical input -> different key ------------------------------

{
    my $a = key(provider => 'openai', model => 'gpt-6-sol', messages => [{role=>'user',content=>'x'}]);
    my $b = key(provider => 'cohere', model => 'gpt-6-sol', messages => [{role=>'user',content=>'x'}]);
    isnt($a, $b, 'different provider changes the key');
}

done_testing();
