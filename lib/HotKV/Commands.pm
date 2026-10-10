# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands;

use strict;
use warnings;

use Scalar::Util qw(refaddr);

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands - Typed standard and HotKV command methods

=head1 DESCRIPTION

A mixin (not instantiated directly) providing every typed command method.
It is consumed by L<HotKV> (talks straight to the pool), L<HotKV::Pipeline>
(queues client-side) and L<HotKV::Transaction> (queues server-side inside
MULTI/EXEC): each of those defines its own C<_call(@args)> primitive and
inherits every method here for free, so any command, including the
HotKV and AI families, can be used standalone, pipelined or transacted.

Options are always given as an optional trailing hashref, e.g.
C<< $kv->set($key, $val, { ex => 60, nx => 1 }) >>. Where the server expects
alternating C<name, value> pairs (C<HSET>, C<ZADD>, C<GEOADD>, ...) they are
passed as a flat list.

=cut

sub _opts {
    my ($args) = @_; # arrayref; pops the trailing hashref in place so the
                      # caller's own @_ (or @rest) is correctly shortened.
    return (@$args && ref($args->[-1]) eq 'HASH') ? pop(@$args) : {};
}

# True when $result is $self handed straight back: HotKV::Pipeline and
# HotKV::Transaction's _call() return $self (for chaining) while a command
# is only queued, with the real decoded reply arriving later from
# execute()/exec(). Reply-shape normalization must not run on that
# placeholder; it runs once, when the real reply is decoded.
sub _is_deferred {
    my ($self, $result) = @_;
    return ref($result) && refaddr($result) == refaddr($self);
}

# Normalizes a map-shaped reply to a hashref: a native RESP3 map already
# decodes to one (see HotKV::Protocol::_read_map); a RESP2 (or RESP3
# without a native map for that command) flat array of "name, value, name,
# value, ..." is folded into one. HGETALL, CONFIG GET and XINFO STREAM
# document this shape.
sub _to_hash {
    my ($v) = @_;
    return $v if ref($v) eq 'HASH';
    return {} unless defined $v;
    my %h = @$v;
    return \%h;
}

# Normalizes a "member, value" paired reply to an arrayref of [member,
# value] pairs: RESP3's native array of 2-element pairs (ZRANGE ...
# WITHSCORES, HRANDFIELD ... WITHVALUES, ZRANDMEMBER ... WITHSCORES,
# ZPOPMIN/ZPOPMAX with a count, ...) is already that shape; a RESP2 flat
# "member, value, member, value, ..." array is regrouped into it.
sub _to_pairs {
    my ($v) = @_;
    return [] unless defined $v && @$v;
    return $v if ref($v->[0]) eq 'ARRAY';
    my @out;
    for (my $i = 0; $i + 1 < @$v; $i += 2) {
        push @out, [$v->[$i], $v->[$i + 1]];
    }
    return \@out;
}

# Normalizes XREAD/XREADGROUP's "stream name -> entries" reply to a
# hashref: a native RESP3 map already decodes to one; RESP2 (or RESP3
# without XREAD's own map upgrade) sends an array of [name, entries]
# pairs.
sub _to_stream_hash {
    my ($v) = @_;
    return $v if ref($v) eq 'HASH' || !defined $v;
    my %h = map { $_->[0] => $_->[1] } @$v;
    return \%h;
}

# ---------------------------------------------------------------------------
# Generic escape hatch
# ---------------------------------------------------------------------------

=head2 command(@args) / execute(@args)

Sends any command verbatim and returns the decoded reply. Use this for any
command not covered by a typed method.

=cut

sub command { my $self = shift; return $self->_call(@_); }
sub execute { my $self = shift; return $self->_call(@_); }

# ---------------------------------------------------------------------------
# Strings
# ---------------------------------------------------------------------------

=head2 Strings: get, set, getset, getdel, getex, mget, mset, msetnx, append,
strlen, incr, decr, incrby, decrby, incrbyfloat, setrange, getrange, setnx,
setex, psetex

C<set($key, $value, \%opts)> opts: C<ex>, C<px>, C<exat>, C<pxat>, C<nx>,
C<xx>, C<ifeq>, C<ifne>, C<ifdeq>, C<ifdne>, C<get>, C<keepttl>.

=cut

sub get { my ($self, $key) = @_; return $self->_call('GET', $key); }

sub set {
    my $self = shift;
    my $key  = shift;
    my $val  = shift;
    my $opts = _opts(\@_);
    my @args = ('SET', $key, $val);
    push @args, 'EX',   $opts->{ex}   if defined $opts->{ex};
    push @args, 'PX',   $opts->{px}   if defined $opts->{px};
    push @args, 'EXAT', $opts->{exat} if defined $opts->{exat};
    push @args, 'PXAT', $opts->{pxat} if defined $opts->{pxat};
    push @args, 'NX' if $opts->{nx};
    push @args, 'XX' if $opts->{xx};
    push @args, _condition_args($opts);
    push @args, 'GET' if $opts->{get};
    push @args, 'KEEPTTL' if $opts->{keepttl};
    return $self->_call(@args);
}

sub getset     { my ($self, $k, $v) = @_; return $self->_call('GETSET', $k, $v); }
sub getdel     { my ($self, $k)     = @_; return $self->_call('GETDEL', $k); }

sub getex {
    my $self = shift;
    my $key  = shift;
    my $opts = _opts(\@_);
    my @args = ('GETEX', $key);
    push @args, 'EX',   $opts->{ex}   if defined $opts->{ex};
    push @args, 'PX',   $opts->{px}   if defined $opts->{px};
    push @args, 'EXAT', $opts->{exat} if defined $opts->{exat};
    push @args, 'PXAT', $opts->{pxat} if defined $opts->{pxat};
    push @args, 'PERSIST' if $opts->{persist};
    return $self->_call(@args);
}

sub mget    { my $self = shift; return $self->_call('MGET', @_); }
sub mset    { my $self = shift; return $self->_call('MSET', @_); }
sub msetnx  { my $self = shift; return $self->_call('MSETNX', @_); }
sub append  { my ($self, $k, $v) = @_; return $self->_call('APPEND', $k, $v); }
sub strlen  { my ($self, $k) = @_; return $self->_call('STRLEN', $k); }
sub incr    { my ($self, $k) = @_; return $self->_call('INCR', $k); }
sub decr    { my ($self, $k) = @_; return $self->_call('DECR', $k); }
sub incrby  { my ($self, $k, $n) = @_; return $self->_call('INCRBY', $k, $n); }
sub decrby  { my ($self, $k, $n) = @_; return $self->_call('DECRBY', $k, $n); }
sub incrbyfloat { my ($self, $k, $n) = @_; return $self->_call('INCRBYFLOAT', $k, $n); }
sub setrange { my ($self, $k, $off, $v) = @_; return $self->_call('SETRANGE', $k, $off, $v); }
sub getrange { my ($self, $k, $s, $e) = @_; return $self->_call('GETRANGE', $k, $s, $e); }
sub setnx    { my ($self, $k, $v) = @_; return $self->_call('SETNX', $k, $v); }
sub setex    { my ($self, $k, $s, $v) = @_; return $self->_call('SETEX', $k, $s, $v); }
sub psetex   { my ($self, $k, $ms, $v) = @_; return $self->_call('PSETEX', $k, $ms, $v); }

# ---------------------------------------------------------------------------
# Keys / generic / expiry
# ---------------------------------------------------------------------------

sub del     { my $self = shift; return $self->_call('DEL', @_); }
sub unlink  { my $self = shift; return $self->_call('UNLINK', @_); }
sub exists  { my $self = shift; return $self->_call('EXISTS', @_); }
sub type    { my ($self, $k) = @_; return $self->_call('TYPE', $k); }
sub keys    { my ($self, $pattern) = @_; return $self->_call('KEYS', $pattern); }
sub randomkey { my ($self) = @_; return $self->_call('RANDOMKEY'); }
sub rename    { my ($self, $s, $d) = @_; return $self->_call('RENAME', $s, $d); }
sub renamenx  { my ($self, $s, $d) = @_; return $self->_call('RENAMENX', $s, $d); }
sub touch     { my $self = shift; return $self->_call('TOUCH', @_); }
sub dump      { my ($self, $k) = @_; return $self->_call('DUMP', $k); }

sub copy {
    my $self = shift;
    my ($src, $dst) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('COPY', $src, $dst);
    push @args, 'DB', $opts->{db} if defined $opts->{db};
    push @args, 'REPLACE' if $opts->{replace};
    return $self->_call(@args);
}

sub restore {
    my $self = shift;
    my ($key, $ttl, $blob) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('RESTORE', $key, $ttl, $blob);
    push @args, 'REPLACE' if $opts->{replace};
    push @args, 'ABSTTL' if $opts->{absttl};
    push @args, 'IDLETIME', $opts->{idletime} if defined $opts->{idletime};
    push @args, 'FREQ', $opts->{freq} if defined $opts->{freq};
    return $self->_call(@args);
}

sub object_encoding { my ($self, $k) = @_; return $self->_call('OBJECT', 'ENCODING', $k); }

sub expire {
    my $self = shift;
    my ($key, $secs) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('EXPIRE', $key, $secs);
    push @args, uc($opts->{nx} ? 'NX' : $opts->{xx} ? 'XX' : $opts->{gt} ? 'GT' : $opts->{lt} ? 'LT' : ()) if grep { $opts->{$_} } qw(nx xx gt lt);
    return $self->_call(@args);
}
sub pexpire {
    my $self = shift;
    my ($key, $ms) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('PEXPIRE', $key, $ms);
    push @args, uc($opts->{nx} ? 'NX' : $opts->{xx} ? 'XX' : $opts->{gt} ? 'GT' : $opts->{lt} ? 'LT' : ()) if grep { $opts->{$_} } qw(nx xx gt lt);
    return $self->_call(@args);
}
sub expireat {
    my $self = shift;
    my ($key, $ts) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('EXPIREAT', $key, $ts);
    push @args, uc($opts->{nx} ? 'NX' : $opts->{xx} ? 'XX' : $opts->{gt} ? 'GT' : $opts->{lt} ? 'LT' : ()) if grep { $opts->{$_} } qw(nx xx gt lt);
    return $self->_call(@args);
}
sub pexpireat {
    my $self = shift;
    my ($key, $ts) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('PEXPIREAT', $key, $ts);
    push @args, uc($opts->{nx} ? 'NX' : $opts->{xx} ? 'XX' : $opts->{gt} ? 'GT' : $opts->{lt} ? 'LT' : ()) if grep { $opts->{$_} } qw(nx xx gt lt);
    return $self->_call(@args);
}
sub ttl      { my ($self, $k) = @_; return $self->_call('TTL', $k); }
sub pttl     { my ($self, $k) = @_; return $self->_call('PTTL', $k); }
sub persist  { my ($self, $k) = @_; return $self->_call('PERSIST', $k); }

# HotKV-exclusive nanosecond TTL, grouped here with the rest of expiry since
# it is a core (non-licensed) family.
sub nexpire   { my ($self, $k, $ns) = @_; return $self->_call('NEXPIRE', $k, $ns); }
sub nttl      { my ($self, $k) = @_; return $self->_call('NTTL', $k); }
sub nexpireat { my ($self, $k, $ns_ts) = @_; return $self->_call('NEXPIREAT', $k, $ns_ts); }

# HOTKEYS (core/admin).
sub hotkeys_top   { my ($self, $count) = @_; my @a = ('HOTKEYS', 'TOP'); push @a, $count if defined $count; return $self->_call(@a); }
sub hotkeys_reset { my ($self) = @_; return $self->_call('HOTKEYS', 'RESET'); }

# ---------------------------------------------------------------------------
# SCAN family
# ---------------------------------------------------------------------------

sub _scan_args {
    my ($cmd, $cursor_and_key, $opts) = @_;
    my @args = (@$cmd, @$cursor_and_key);
    push @args, 'MATCH', $opts->{match} if defined $opts->{match};
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    push @args, 'TYPE',  $opts->{type}  if defined $opts->{type};
    return @args;
}

sub scan {
    my $self = shift;
    my $cursor = shift // 0;
    my $opts = _opts(\@_);
    return $self->_call(_scan_args(['SCAN'], [$cursor], $opts));
}
sub hscan {
    my $self = shift;
    my ($key, $cursor) = (shift, shift // 0);
    my $opts = _opts(\@_);
    my @args = _scan_args(['HSCAN', $key], [$cursor], $opts);
    push @args, 'NOVALUES' if $opts->{novalues};
    return $self->_call(@args);
}
sub sscan {
    my $self = shift;
    my ($key, $cursor) = (shift, shift // 0);
    my $opts = _opts(\@_);
    return $self->_call(_scan_args(['SSCAN', $key], [$cursor], $opts));
}
sub zscan {
    my $self = shift;
    my ($key, $cursor) = (shift, shift // 0);
    my $opts = _opts(\@_);
    return $self->_call(_scan_args(['ZSCAN', $key], [$cursor], $opts));
}

# Iterators: return a coderef; call repeatedly for each element, undef when done.
sub scan_iterator  { my $self = shift; return $self->_make_iterator('scan',  undef, @_); }
sub hscan_iterator { my $self = shift; my $key = shift; return $self->_make_iterator('hscan', $key, @_); }
sub sscan_iterator { my $self = shift; my $key = shift; return $self->_make_iterator('sscan', $key, @_); }
sub zscan_iterator { my $self = shift; my $key = shift; return $self->_make_iterator('zscan', $key, @_); }

sub _make_iterator {
    my ($self, $method, $key, @opt_args) = @_;
    # scan/hscan/sscan/zscan all want their MATCH/COUNT/TYPE options as one
    # trailing hashref; accept either that or a flat (match => ..., ...)
    # list here, for a nicer *_iterator(...) call site, and normalize.
    my $opts = (@opt_args == 1 && ref $opt_args[0] eq 'HASH') ? $opt_args[0] : { @opt_args };
    my $cursor  = 0;
    my $started = 0;
    my @buffer;
    return sub {
        while (!@buffer) {
            return undef if $started && $cursor eq '0';
            $started = 1;
            my $reply = defined $key
                ? $self->$method($key, $cursor, $opts)
                : $self->$method($cursor, $opts);
            ($cursor, my $items) = @$reply;
            @buffer = @$items;
        }
        return shift @buffer;
    };
}

# ---------------------------------------------------------------------------
# Lists
# ---------------------------------------------------------------------------

sub lpush  { my $self = shift; my $k = shift; return $self->_call('LPUSH', $k, @_); }
sub rpush  { my $self = shift; my $k = shift; return $self->_call('RPUSH', $k, @_); }
sub lpushx { my $self = shift; my $k = shift; return $self->_call('LPUSHX', $k, @_); }
sub rpushx { my $self = shift; my $k = shift; return $self->_call('RPUSHX', $k, @_); }
sub lpop   { my ($self, $k, $count) = @_; my @a = ('LPOP', $k); push @a, $count if defined $count; return $self->_call(@a); }
sub rpop   { my ($self, $k, $count) = @_; my @a = ('RPOP', $k); push @a, $count if defined $count; return $self->_call(@a); }
sub llen   { my ($self, $k) = @_; return $self->_call('LLEN', $k); }
sub lrange { my ($self, $k, $s, $e) = @_; return $self->_call('LRANGE', $k, $s, $e); }
sub lindex { my ($self, $k, $i) = @_; return $self->_call('LINDEX', $k, $i); }
sub lset   { my ($self, $k, $i, $v) = @_; return $self->_call('LSET', $k, $i, $v); }
sub linsert { my ($self, $k, $where, $pivot, $v) = @_; return $self->_call('LINSERT', $k, uc($where), $pivot, $v); }
sub lrem   { my ($self, $k, $count, $v) = @_; return $self->_call('LREM', $k, $count, $v); }
sub ltrim  { my ($self, $k, $s, $e) = @_; return $self->_call('LTRIM', $k, $s, $e); }
sub lpos {
    my $self = shift;
    my ($key, $elem) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('LPOS', $key, $elem);
    push @args, 'RANK', $opts->{rank} if defined $opts->{rank};
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    push @args, 'MAXLEN', $opts->{maxlen} if defined $opts->{maxlen};
    return $self->_call(@args);
}
sub rpoplpush { my ($self, $s, $d) = @_; return $self->_call('RPOPLPUSH', $s, $d); }
sub lmove { my ($self, $s, $d, $from, $to) = @_; return $self->_call('LMOVE', $s, $d, uc($from), uc($to)); }
sub blpop { my $self = shift; my $timeout = pop; return $self->_call('BLPOP', @_, $timeout); }
sub brpop { my $self = shift; my $timeout = pop; return $self->_call('BRPOP', @_, $timeout); }
sub blmove { my ($self, $s, $d, $from, $to, $timeout) = @_; return $self->_call('BLMOVE', $s, $d, uc($from), uc($to), $timeout); }

# ---------------------------------------------------------------------------
# Sets
# ---------------------------------------------------------------------------

sub sadd   { my $self = shift; my $k = shift; return $self->_call('SADD', $k, @_); }
sub srem   { my $self = shift; my $k = shift; return $self->_call('SREM', $k, @_); }
sub smembers { my ($self, $k) = @_; return $self->_call('SMEMBERS', $k); }
sub sismember { my ($self, $k, $m) = @_; return $self->_call('SISMEMBER', $k, $m); }
sub smismember { my $self = shift; my $k = shift; return $self->_call('SMISMEMBER', $k, @_); }
sub scard  { my ($self, $k) = @_; return $self->_call('SCARD', $k); }
sub spop   { my ($self, $k, $count) = @_; my @a = ('SPOP', $k); push @a, $count if defined $count; return $self->_call(@a); }
sub srandmember { my ($self, $k, $count) = @_; my @a = ('SRANDMEMBER', $k); push @a, $count if defined $count; return $self->_call(@a); }
sub sunion { my $self = shift; return $self->_call('SUNION', @_); }
sub sinter { my $self = shift; return $self->_call('SINTER', @_); }
sub sdiff  { my $self = shift; return $self->_call('SDIFF', @_); }
sub sunionstore { my $self = shift; my $d = shift; return $self->_call('SUNIONSTORE', $d, @_); }
sub sinterstore { my $self = shift; my $d = shift; return $self->_call('SINTERSTORE', $d, @_); }
sub sdiffstore  { my $self = shift; my $d = shift; return $self->_call('SDIFFSTORE', $d, @_); }
sub sintercard {
    my $self = shift;
    my $keys = shift;
    my $opts = _opts(\@_);
    my @args = ('SINTERCARD', scalar(@$keys), @$keys);
    push @args, 'LIMIT', $opts->{limit} if defined $opts->{limit};
    return $self->_call(@args);
}
sub smove  { my ($self, $s, $d, $m) = @_; return $self->_call('SMOVE', $s, $d, $m); }

# ---------------------------------------------------------------------------
# Hashes
# ---------------------------------------------------------------------------

sub hset    { my $self = shift; my $k = shift; return $self->_call('HSET', $k, @_); }
sub hsetnx  { my ($self, $k, $f, $v) = @_; return $self->_call('HSETNX', $k, $f, $v); }
sub hget    { my ($self, $k, $f) = @_; return $self->_call('HGET', $k, $f); }
sub hmget   { my $self = shift; my $k = shift; return $self->_call('HMGET', $k, @_); }
sub hmset   { my $self = shift; my $k = shift; return $self->_call('HMSET', $k, @_); }
sub hgetall { my ($self, $k) = @_; my $r = $self->_call('HGETALL', $k); return $self->_is_deferred($r) ? $r : _to_hash($r); }
sub hdel    { my $self = shift; my $k = shift; return $self->_call('HDEL', $k, @_); }
sub hexists { my ($self, $k, $f) = @_; return $self->_call('HEXISTS', $k, $f); }
sub hlen    { my ($self, $k) = @_; return $self->_call('HLEN', $k); }
sub hkeys   { my ($self, $k) = @_; return $self->_call('HKEYS', $k); }
sub hvals   { my ($self, $k) = @_; return $self->_call('HVALS', $k); }
sub hincrby { my ($self, $k, $f, $n) = @_; return $self->_call('HINCRBY', $k, $f, $n); }
sub hincrbyfloat { my ($self, $k, $f, $n) = @_; return $self->_call('HINCRBYFLOAT', $k, $f, $n); }
sub hrandfield {
    my $self = shift;
    my $k = shift;
    my $opts = _opts(\@_);
    my @args = ('HRANDFIELD', $k);
    push @args, $opts->{count} if defined $opts->{count};
    push @args, 'WITHVALUES' if $opts->{withvalues};
    my $r = $self->_call(@args);
    return $r if $self->_is_deferred($r);
    return $opts->{withvalues} ? _to_pairs($r) : $r;
}

sub _hash_field_ttl {
    my ($self, $wire, $key, $ttl, $fields, $opts) = @_;
    my @args = ($wire, $key);
    push @args, $ttl if defined $ttl;
    push @args, uc($opts->{nx} ? 'NX' : $opts->{xx} ? 'XX' : $opts->{gt} ? 'GT' : $opts->{lt} ? 'LT' : ()) if $opts && grep { $opts->{$_} } qw(nx xx gt lt);
    push @args, 'FIELDS', scalar(@$fields), @$fields;
    return $self->_call(@args);
}
sub hexpire    { my $self = shift; my ($k, $s, $f) = (shift, shift, shift); my $o = _opts(\@_); return $self->_hash_field_ttl('HEXPIRE', $k, $s, $f, $o); }
sub hpexpire   { my $self = shift; my ($k, $ms, $f) = (shift, shift, shift); my $o = _opts(\@_); return $self->_hash_field_ttl('HPEXPIRE', $k, $ms, $f, $o); }
sub hexpireat  { my $self = shift; my ($k, $ts, $f) = (shift, shift, shift); my $o = _opts(\@_); return $self->_hash_field_ttl('HEXPIREAT', $k, $ts, $f, $o); }
sub hpexpireat { my $self = shift; my ($k, $ts, $f) = (shift, shift, shift); my $o = _opts(\@_); return $self->_hash_field_ttl('HPEXPIREAT', $k, $ts, $f, $o); }
sub hpersist   { my ($self, $k, $f) = @_; return $self->_hash_field_ttl('HPERSIST', $k, undef, $f, {}); }
sub httl       { my ($self, $k, $f) = @_; return $self->_hash_field_ttl('HTTL', $k, undef, $f, {}); }
sub hpttl      { my ($self, $k, $f) = @_; return $self->_hash_field_ttl('HPTTL', $k, undef, $f, {}); }
sub hscan_novalues { my ($self, $k, $cursor, %o) = @_; return $self->hscan($k, $cursor, { %o, novalues => 1 }); }

# ---------------------------------------------------------------------------
# Sorted sets
# ---------------------------------------------------------------------------

sub zadd {
    my $self = shift;
    my $key  = shift;
    my $opts = _opts(\@_);
    my @pairs = @_;
    my @args = ('ZADD', $key);
    push @args, 'NX' if $opts->{nx};
    push @args, 'XX' if $opts->{xx};
    push @args, 'GT' if $opts->{gt};
    push @args, 'LT' if $opts->{lt};
    push @args, 'CH' if $opts->{ch};
    push @args, 'INCR' if $opts->{incr};
    push @args, @pairs;
    return $self->_call(@args);
}
sub zscore  { my ($self, $k, $m) = @_; return $self->_call('ZSCORE', $k, $m); }
sub zmscore { my $self = shift; my $k = shift; return $self->_call('ZMSCORE', $k, @_); }
sub zincrby { my ($self, $k, $incr, $m) = @_; return $self->_call('ZINCRBY', $k, $incr, $m); }
sub zcard   { my ($self, $k) = @_; return $self->_call('ZCARD', $k); }
sub zcount  { my ($self, $k, $min, $max) = @_; return $self->_call('ZCOUNT', $k, $min, $max); }
sub zrank {
    my $self = shift;
    my ($k, $m) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZRANK', $k, $m);
    push @args, 'WITHSCORE' if $opts->{withscore};
    return $self->_call(@args);
}
sub zrevrank {
    my $self = shift;
    my ($k, $m) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZREVRANK', $k, $m);
    push @args, 'WITHSCORE' if $opts->{withscore};
    return $self->_call(@args);
}
sub zrem { my $self = shift; my $k = shift; return $self->_call('ZREM', $k, @_); }
sub zremrangebyscore { my ($self, $k, $min, $max) = @_; return $self->_call('ZREMRANGEBYSCORE', $k, $min, $max); }
sub zremrangebyrank  { my ($self, $k, $s, $e) = @_; return $self->_call('ZREMRANGEBYRANK', $k, $s, $e); }
sub zremrangebylex   { my ($self, $k, $min, $max) = @_; return $self->_call('ZREMRANGEBYLEX', $k, $min, $max); }
sub zpopmin {
    my ($self, $k, $count) = @_;
    my @a = ('ZPOPMIN', $k);
    push @a, $count if defined $count;
    my $r = $self->_call(@a);
    return $r if $self->_is_deferred($r);
    return defined $count ? _to_pairs($r) : $r;
}
sub zpopmax {
    my ($self, $k, $count) = @_;
    my @a = ('ZPOPMAX', $k);
    push @a, $count if defined $count;
    my $r = $self->_call(@a);
    return $r if $self->_is_deferred($r);
    return defined $count ? _to_pairs($r) : $r;
}
sub zrandmember {
    my $self = shift;
    my $k = shift;
    my $opts = _opts(\@_);
    my @args = ('ZRANDMEMBER', $k);
    push @args, $opts->{count} if defined $opts->{count};
    push @args, 'WITHSCORES' if $opts->{withscores};
    my $r = $self->_call(@args);
    return $r if $self->_is_deferred($r);
    return $opts->{withscores} ? _to_pairs($r) : $r;
}

# Shared builder for ZRANGE / ZRANGEBYSCORE / ZRANGEBYLEX / ZREVRANGE / ZRANGESTORE.
sub zrange {
    my $self = shift;
    my ($key, $start, $stop) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZRANGE', $key, $start, $stop);
    push @args, 'BYSCORE' if $opts->{byscore};
    push @args, 'BYLEX'   if $opts->{bylex};
    push @args, 'REV'     if $opts->{rev};
    push @args, 'LIMIT', $opts->{limit}[0], $opts->{limit}[1] if $opts->{limit};
    push @args, 'WITHSCORES' if $opts->{withscores};
    my $r = $self->_call(@args);
    return $r if $self->_is_deferred($r);
    return $opts->{withscores} ? _to_pairs($r) : $r;
}
sub zrangestore {
    my $self = shift;
    my ($dst, $src, $start, $stop) = (shift, shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZRANGESTORE', $dst, $src, $start, $stop);
    push @args, 'BYSCORE' if $opts->{byscore};
    push @args, 'BYLEX'   if $opts->{bylex};
    push @args, 'REV'     if $opts->{rev};
    push @args, 'LIMIT', $opts->{limit}[0], $opts->{limit}[1] if $opts->{limit};
    return $self->_call(@args);
}
sub zrangebyscore {
    my $self = shift;
    my ($k, $min, $max) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZRANGEBYSCORE', $k, $min, $max);
    push @args, 'WITHSCORES' if $opts->{withscores};
    push @args, 'LIMIT', $opts->{limit}[0], $opts->{limit}[1] if $opts->{limit};
    my $r = $self->_call(@args);
    return $r if $self->_is_deferred($r);
    return $opts->{withscores} ? _to_pairs($r) : $r;
}
sub zrevrangebyscore {
    my $self = shift;
    my ($k, $max, $min) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZREVRANGEBYSCORE', $k, $max, $min);
    push @args, 'WITHSCORES' if $opts->{withscores};
    push @args, 'LIMIT', $opts->{limit}[0], $opts->{limit}[1] if $opts->{limit};
    my $r = $self->_call(@args);
    return $r if $self->_is_deferred($r);
    return $opts->{withscores} ? _to_pairs($r) : $r;
}
sub zrangebylex {
    my $self = shift;
    my ($k, $min, $max) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZRANGEBYLEX', $k, $min, $max);
    push @args, 'LIMIT', $opts->{limit}[0], $opts->{limit}[1] if $opts->{limit};
    return $self->_call(@args);
}
sub zrevrangebylex {
    my $self = shift;
    my ($k, $max, $min) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZREVRANGEBYLEX', $k, $max, $min);
    push @args, 'LIMIT', $opts->{limit}[0], $opts->{limit}[1] if $opts->{limit};
    return $self->_call(@args);
}
sub zrevrange {
    my $self = shift;
    my ($k, $s, $e) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZREVRANGE', $k, $s, $e);
    push @args, 'WITHSCORES' if $opts->{withscores};
    my $r = $self->_call(@args);
    return $r if $self->_is_deferred($r);
    return $opts->{withscores} ? _to_pairs($r) : $r;
}

sub _zsetop {
    my ($self, $wire, $dest_or_undef, $keys, $opts) = @_;
    my @args = ($wire);
    push @args, $dest_or_undef if defined $dest_or_undef;
    push @args, scalar(@$keys), @$keys;
    push @args, 'WEIGHTS', @{ $opts->{weights} } if $opts->{weights};
    push @args, 'AGGREGATE', uc($opts->{aggregate}) if $opts->{aggregate};
    push @args, 'WITHSCORES' if $opts->{withscores};
    my $r = $self->_call(@args);
    return $r if $self->_is_deferred($r) || defined $dest_or_undef;
    return $opts->{withscores} ? _to_pairs($r) : $r;
}
sub zunionstore  { my $self = shift; my $d = shift; my $keys = shift; my $o = _opts(\@_); return $self->_zsetop('ZUNIONSTORE', $d, $keys, $o); }
sub zinterstore  { my $self = shift; my $d = shift; my $keys = shift; my $o = _opts(\@_); return $self->_zsetop('ZINTERSTORE', $d, $keys, $o); }
sub zdiffstore   { my ($self, $d, $keys) = @_; return $self->_call('ZDIFFSTORE', $d, scalar(@$keys), @$keys); }
sub zunion  { my $self = shift; my $keys = shift; my $o = _opts(\@_); return $self->_zsetop('ZUNION', undef, $keys, $o); }
sub zinter  { my $self = shift; my $keys = shift; my $o = _opts(\@_); return $self->_zsetop('ZINTER', undef, $keys, $o); }
sub zdiff {
    my $self = shift;
    my $keys = shift;
    my $o = _opts(\@_);
    my @a = ('ZDIFF', scalar(@$keys), @$keys);
    push @a, 'WITHSCORES' if $o->{withscores};
    my $r = $self->_call(@a);
    return $r if $self->_is_deferred($r);
    return $o->{withscores} ? _to_pairs($r) : $r;
}
sub zintercard {
    my $self = shift;
    my $keys = shift;
    my $opts = _opts(\@_);
    my @args = ('ZINTERCARD', scalar(@$keys), @$keys);
    push @args, 'LIMIT', $opts->{limit} if defined $opts->{limit};
    return $self->_call(@args);
}

# ---------------------------------------------------------------------------
# Streams
# ---------------------------------------------------------------------------

sub xadd {
    my $self = shift;
    my $key  = shift;
    my $id   = shift;
    my $opts = _opts(\@_);
    my @fields = @_;
    my @args = ('XADD', $key);
    push @args, 'NOMKSTREAM' if $opts->{nomkstream};
    if ($opts->{maxlen}) {
        push @args, 'MAXLEN', ($opts->{approx} ? '~' : '='), $opts->{maxlen};
    }
    elsif ($opts->{minid}) {
        push @args, 'MINID', ($opts->{approx} ? '~' : '='), $opts->{minid};
    }
    push @args, 'LIMIT', $opts->{trim_limit} if defined $opts->{trim_limit};
    if ($opts->{idmp}) {
        push @args, 'IDMP', @{ $opts->{idmp} }[0, 1];
    }
    elsif (defined $opts->{idmpauto}) {
        push @args, 'IDMPAUTO', $opts->{idmpauto};
    }
    push @args, $id, @fields;
    return $self->_call(@args);
}
sub xlen   { my ($self, $k) = @_; return $self->_call('XLEN', $k); }
sub xrange {
    my $self = shift;
    my ($k, $s, $e) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('XRANGE', $k, $s, $e);
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    return $self->_call(@args);
}
sub xrevrange {
    my $self = shift;
    my ($k, $e, $s) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('XREVRANGE', $k, $e, $s);
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    return $self->_call(@args);
}
sub xdel { my $self = shift; my $k = shift; return $self->_call('XDEL', $k, @_); }
sub xtrim {
    my $self = shift;
    my $key  = shift;
    my $opts = _opts(\@_);
    my @args = ('XTRIM', $key);
    if ($opts->{maxlen}) {
        push @args, 'MAXLEN', ($opts->{approx} ? '~' : '='), $opts->{maxlen};
    }
    elsif ($opts->{minid}) {
        push @args, 'MINID', ($opts->{approx} ? '~' : '='), $opts->{minid};
    }
    push @args, 'LIMIT', $opts->{trim_limit} if defined $opts->{trim_limit};
    return $self->_call(@args);
}
sub xread {
    my $self = shift;
    my $opts = _opts(\@_);
    my ($streams, $ids) = @_;
    my @args = ('XREAD');
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    push @args, 'BLOCK', $opts->{block} if defined $opts->{block};
    push @args, 'STREAMS', @$streams, @$ids;
    my $r = $self->_call(@args);
    return $self->_is_deferred($r) ? $r : _to_stream_hash($r);
}
sub xreadgroup {
    my $self = shift;
    my ($group, $consumer) = (shift, shift);
    my ($streams, $ids) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('XREADGROUP', 'GROUP', $group, $consumer);
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    push @args, 'BLOCK', $opts->{block} if defined $opts->{block};
    push @args, 'NOACK' if $opts->{noack};
    push @args, 'STREAMS', @$streams, @$ids;
    my $r = $self->_call(@args);
    return $self->_is_deferred($r) ? $r : _to_stream_hash($r);
}
sub xack { my $self = shift; my ($k, $g) = (shift, shift); return $self->_call('XACK', $k, $g, @_); }
sub xgroup_create {
    my $self = shift;
    my ($key, $group, $id) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('XGROUP', 'CREATE', $key, $group, $id // '$');
    push @args, 'MKSTREAM' if $opts->{mkstream};
    return $self->_call(@args);
}
sub xgroup_destroy       { my ($self, $k, $g) = @_; return $self->_call('XGROUP', 'DESTROY', $k, $g); }
sub xgroup_createconsumer{ my ($self, $k, $g, $c) = @_; return $self->_call('XGROUP', 'CREATECONSUMER', $k, $g, $c); }
sub xgroup_delconsumer   { my ($self, $k, $g, $c) = @_; return $self->_call('XGROUP', 'DELCONSUMER', $k, $g, $c); }
sub xgroup_setid         { my ($self, $k, $g, $id) = @_; return $self->_call('XGROUP', 'SETID', $k, $g, $id // '$'); }
sub xpending {
    my $self = shift;
    my ($key, $group) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('XPENDING', $key, $group);
    if ($opts->{start}) {
        push @args, 'IDLE', $opts->{idle} if defined $opts->{idle};
        push @args, $opts->{start}, $opts->{end}, $opts->{count};
        push @args, $opts->{consumer} if defined $opts->{consumer};
    }
    return $self->_call(@args);
}
sub xclaim {
    my $self = shift;
    my ($key, $group, $consumer, $min_idle, $ids) = (shift, shift, shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('XCLAIM', $key, $group, $consumer, $min_idle, @$ids);
    push @args, 'IDLE', $opts->{idle} if defined $opts->{idle};
    push @args, 'TIME', $opts->{time} if defined $opts->{time};
    push @args, 'RETRYCOUNT', $opts->{retrycount} if defined $opts->{retrycount};
    push @args, 'FORCE' if $opts->{force};
    push @args, 'JUSTID' if $opts->{justid};
    return $self->_call(@args);
}
sub xautoclaim {
    my $self = shift;
    my ($key, $group, $consumer, $min_idle, $start) = (shift, shift, shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('XAUTOCLAIM', $key, $group, $consumer, $min_idle, $start);
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    push @args, 'JUSTID' if $opts->{justid};
    return $self->_call(@args);
}
sub xinfo_stream    { my ($self, $k) = @_; my $r = $self->_call('XINFO', 'STREAM', $k); return $self->_is_deferred($r) ? $r : _to_hash($r); }
sub xinfo_groups {
    my ($self, $k) = @_;
    my $r = $self->_call('XINFO', 'GROUPS', $k);
    return $self->_is_deferred($r) ? $r : [map { _to_hash($_) } @$r];
}
sub xinfo_consumers {
    my ($self, $k, $g) = @_;
    my $r = $self->_call('XINFO', 'CONSUMERS', $k, $g);
    return $self->_is_deferred($r) ? $r : [map { _to_hash($_) } @$r];
}

# ---------------------------------------------------------------------------
# Geospatial
# ---------------------------------------------------------------------------

sub geoadd {
    my $self = shift;
    my $key  = shift;
    my $opts = _opts(\@_);
    my @args = ('GEOADD', $key);
    push @args, 'NX' if $opts->{nx};
    push @args, 'XX' if $opts->{xx};
    push @args, 'CH' if $opts->{ch};
    push @args, @_;
    return $self->_call(@args);
}
sub geopos  { my $self = shift; my $k = shift; return $self->_call('GEOPOS', $k, @_); }
sub geodist {
    my $self = shift;
    my ($k, $m1, $m2) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('GEODIST', $k, $m1, $m2);
    push @args, $opts->{unit} if defined $opts->{unit};
    return $self->_call(@args);
}
sub geohash { my $self = shift; my $k = shift; return $self->_call('GEOHASH', $k, @_); }
sub geosearch {
    my $self = shift;
    my $key  = shift;
    my $opts = _opts(\@_);
    my @args = ('GEOSEARCH', $key);
    if ($opts->{frommember}) {
        push @args, 'FROMMEMBER', $opts->{frommember};
    }
    elsif ($opts->{fromlonlat}) {
        push @args, 'FROMLONLAT', @{ $opts->{fromlonlat} };
    }
    if ($opts->{byradius}) {
        push @args, 'BYRADIUS', @{ $opts->{byradius} };
    }
    elsif ($opts->{bybox}) {
        push @args, 'BYBOX', @{ $opts->{bybox} };
    }
    push @args, 'ASC' if $opts->{asc};
    push @args, 'DESC' if $opts->{desc};
    push @args, 'COUNT', $opts->{count}, ($opts->{any} ? 'ANY' : ()) if defined $opts->{count};
    push @args, 'WITHCOORD' if $opts->{withcoord};
    push @args, 'WITHDIST' if $opts->{withdist};
    push @args, 'WITHHASH' if $opts->{withhash};
    return $self->_call(@args);
}

# ---------------------------------------------------------------------------
# Bitmaps / HyperLogLog
# ---------------------------------------------------------------------------

sub setbit { my ($self, $k, $off, $bit) = @_; return $self->_call('SETBIT', $k, $off, $bit); }
sub getbit { my ($self, $k, $off) = @_; return $self->_call('GETBIT', $k, $off); }
sub bitcount {
    my $self = shift;
    my $k = shift;
    my $opts = _opts(\@_);
    my @args = ('BITCOUNT', $k);
    if (defined $opts->{start}) {
        push @args, $opts->{start}, $opts->{end};
        push @args, $opts->{unit} if defined $opts->{unit};
    }
    return $self->_call(@args);
}
sub bitpos {
    my $self = shift;
    my ($k, $bit) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('BITPOS', $k, $bit);
    if (defined $opts->{start}) {
        push @args, $opts->{start};
        push @args, $opts->{end} if defined $opts->{end};
        push @args, $opts->{unit} if defined $opts->{unit};
    }
    return $self->_call(@args);
}
sub bitop { my $self = shift; my ($op, $dest) = (shift, shift); return $self->_call('BITOP', uc($op), $dest, @_); }
sub pfadd   { my $self = shift; my $k = shift; return $self->_call('PFADD', $k, @_); }
sub pfcount { my $self = shift; return $self->_call('PFCOUNT', @_); }
sub pfmerge { my $self = shift; my $dst = shift; return $self->_call('PFMERGE', $dst, @_); }

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

sub ping   { my ($self, $msg) = @_; my @a = ('PING'); push @a, $msg if defined $msg; return $self->_call(@a); }
sub echo   { my ($self, $msg) = @_; return $self->_call('ECHO', $msg); }
sub info   { my ($self, $section) = @_; my @a = ('INFO'); push @a, $section if defined $section; return $self->_call(@a); }
sub dbsize { my ($self) = @_; return $self->_call('DBSIZE'); }
sub flushdb   { my ($self, $mode) = @_; my @a = ('FLUSHDB'); push @a, uc($mode) if defined $mode; return $self->_call(@a); }
sub flushall  { my ($self, $mode) = @_; my @a = ('FLUSHALL'); push @a, uc($mode) if defined $mode; return $self->_call(@a); }
sub time      { my ($self) = @_; return $self->_call('TIME'); }
sub select    { my ($self, $db) = @_; return $self->_call('SELECT', $db); }
sub swapdb    { my ($self, $a, $b) = @_; return $self->_call('SWAPDB', $a, $b); }
sub lastsave  { my ($self) = @_; return $self->_call('LASTSAVE'); }
sub config_get { my $self = shift; my $r = $self->_call('CONFIG', 'GET', @_); return $self->_is_deferred($r) ? $r : _to_hash($r); }
sub config_set { my $self = shift; return $self->_call('CONFIG', 'SET', @_); }
sub client_setname { my ($self, $name) = @_; return $self->_call('CLIENT', 'SETNAME', $name); }
sub client_getname { my ($self) = @_; return $self->_call('CLIENT', 'GETNAME'); }
sub client_id      { my ($self) = @_; return $self->_call('CLIENT', 'ID'); }
sub command_count  { my ($self) = @_; return $self->_call('COMMAND', 'COUNT'); }

# ---------------------------------------------------------------------------
# Scripting
# ---------------------------------------------------------------------------

sub eval_script {
    my $self = shift;
    my ($script, $keys, $args) = @_;
    $keys ||= [];
    $args ||= [];
    return $self->_call('EVAL', $script, scalar(@$keys), @$keys, @$args);
}
sub evalsha {
    my $self = shift;
    my ($sha, $keys, $args) = @_;
    $keys ||= [];
    $args ||= [];
    return $self->_call('EVALSHA', $sha, scalar(@$keys), @$keys, @$args);
}
sub script_load   { my ($self, $script) = @_; return $self->_call('SCRIPT', 'LOAD', $script); }
sub script_exists { my $self = shift; return $self->_call('SCRIPT', 'EXISTS', @_); }
sub script_flush  { my ($self) = @_; return $self->_call('SCRIPT', 'FLUSH'); }

# ---------------------------------------------------------------------------
# Further core commands: newer string/hash additions, blocking and
# multi-key pops, SORT, BITFIELD, GEORADIUS*, Pub/Sub publishing, ACL,
# CLIENT, COMMAND, LATENCY, MEMORY, SLOWLOG, FUNCTION/FCALL and friends.
# ---------------------------------------------------------------------------

=head1 FURTHER CORE COMMANDS

Every method below sends exactly one command and returns the decoded reply
unchanged unless it says otherwise. Anything not listed here (and not in the
sections above) is still reachable with C<command(@args)>.

=head2 Strings

C<substr($key, $start, $end)>, C<lcs($key1, $key2, \%opts)> (opts: C<len>,
C<idx>, C<minmatchlen>, C<withmatchlen>), C<delex($key, \%opts)> (opts: one of
C<ifeq>, C<ifne>, C<ifdeq>, C<ifdne>), C<digest($key)>, C<msetex(\@pairs,
\%opts)> (C<@pairs> is C<key, value, key, value, ...>; opts: C<nx>, C<xx>,
one of C<ex>/C<px>/C<exat>/C<pxat>/C<keepttl>). C<set> also takes C<ifeq>,
C<ifne>, C<ifdeq>, C<ifdne>.

=head2 Keys

C<expiretime>, C<pexpiretime>, C<move($key, $db)>, C<object($subcommand,
$key)> (C<ENCODING>, C<FREQ>, C<IDLETIME>, C<REFCOUNT>), C<sort($key, \%opts)>
and C<sort_ro> (opts: C<by>, C<limit> C<[offset, count]>, C<get> arrayref of
patterns, C<desc>, C<alpha>, C<store> for C<sort> only),
C<wait($numreplicas, $timeout_ms)>, C<waitaof($numlocal, $numreplicas,
$timeout_ms)>.

=head2 Lists, sorted sets and hashes

C<lmpop(\@keys, $direction, \%opts)>, C<blmpop($timeout, \@keys, $direction,
\%opts)>, C<brpoplpush>, C<zlexcount>, C<zmpop(\@keys, $min_or_max, \%opts)>,
C<bzmpop>, C<bzpopmin(@keys, $timeout)>, C<bzpopmax>, C<hstrlen>,
C<hgetdel($key, \@fields)>, C<hgetex($key, \@fields, \%opts)> (opts: C<ex>,
C<px>, C<exat>, C<pxat>, C<persist>), C<hsetex($key, \@pairs, \%opts)> (opts:
C<fnx>, C<fxx>, one of C<ex>/C<px>/C<exat>/C<pxat>/C<keepttl>),
C<hexpiretime($key, \@fields)>, C<hpexpiretime>, and the C<HIMPORT> family
C<himport_prepare($name, @fields)>, C<himport_set($key, $name, @values)>,
C<himport_discard($name)>, C<himport_discardall>. C<HIMPORT PREPARE> is
per connection state, so C<himport_prepare> followed by C<himport_set> is
only meaningful on a single dedicated connection (inside C<pipeline> or
C<multi>/C<watch>).

=head2 Streams and geo

C<xsetid($key, $last_id, \%opts)>, C<xcfgset($key, \%opts)> (opts:
C<idmp_duration>, C<idmp_maxsize>); C<xadd> takes C<idmp =E<gt> [$producer,
$iid]> or C<idmpauto =E<gt> $producer>. C<georadius>, C<georadius_ro>,
C<georadiusbymember>, C<georadiusbymember_ro>, C<geosearchstore>.

=head2 Bitfield

C<bitfield($key, @subcommands)> and C<bitfield_ro>: the sub-commands are the
wire tokens, given flat or as arrayrefs, for example
C<< $kv->bitfield('k', ['SET', 'u8', 0, 255], ['GET', 'u8', 0]) >>.

=head2 Pub/Sub publishing

C<publish($channel, $message)>, C<spublish>, C<pubsub_channels($pattern)>,
C<pubsub_numsub(@channels)> (a hashref), C<pubsub_numpat>,
C<pubsub_shardchannels>, C<pubsub_shardnumsub(@channels)> (a hashref).

=head2 Server, connection and scripting

C<save>, C<bgsave>, C<bgrewriteaof>, C<role>, C<lolwut>, C<replicaof($host,
$port)>, C<replicaof_no_one>, C<failover(\%opts)>, C<slowlog_get($count)>,
C<slowlog_len>, C<slowlog_reset>, C<slowlog_export>, C<module_list>, C<memory_usage($key)>,
C<memory_stats>, C<memory_doctor>, C<memory_purge>, C<memory_malloc_stats>, C<latency_latest>, C<latency_history>,
C<latency_reset>, C<latency_graph>, C<latency_doctor>,
C<latency_histogram>, C<config_resetstat>, C<config_rewrite>,
C<client_list>, C<client_info>, C<client_kill(@args)>, C<client_pause>,
C<client_unpause>, C<client_noevict>, C<client_notouch>, C<client_setinfo>,
C<client_unblock>, C<client_tracking>, C<client_trackinginfo>,
C<client_caching>, C<client_getredir>, C<command_info>, C<command_docs>,
C<command_list>, C<command_getkeys>, C<command_getkeysandflags>, C<eval_ro>, C<evalsha_ro>,
C<script_kill>, C<function_load>, C<function_delete>, C<function_list>,
C<function_stats>, C<function_flush>, C<function_dump>, C<function_restore>,
C<function_kill>, C<fcall>, C<fcall_ro>, C<acl_setuser>, C<acl_getuser>,
C<acl_deluser>, C<acl_list>, C<acl_users>, C<acl_whoami>, C<acl_cat>,
C<acl_dryrun>, C<acl_log>, C<acl_genpass>, C<acl_save>, C<acl_load>, and the
cluster aware C<clusterscan>, C<sflush>, C<trimslots> and the read only
C<cluster_info>, C<cluster_nodes>, C<cluster_slots>, C<cluster_shards>,
C<cluster_myid>, C<cluster_keyslot>, C<cluster_countkeysinslot>,
C<cluster_getkeysinslot>.

The C<bf>, C<cms> and C<topk> accessors return the Bloom filter, Count-Min
sketch and Top-K families (L<HotKV::Commands::Bloom>,
L<HotKV::Commands::CountMin>, L<HotKV::Commands::TopK>); C<tenant>, C<iam>,
C<audit>, C<encryption> and C<replication> return the enterprise
administration families.

The commands that only make sense on one particular connection, not on a
pooled client, are deliberately not exposed: C<AUTH>/C<HELLO>/C<SELECT>-style
handshakes are done by L<HotKV::Connection> from the constructor options,
C<MONITOR>, C<SUBSCRIBE> and friends have their own blocking API
(L<HotKV::PubSub>), and C<CLIENT REPLY>, C<RESET>, C<QUIT>, C<READONLY>,
C<READWRITE> and C<ASKING> would desynchronize a pooled connection. Use
C<command> on a dedicated L<HotKV::Connection> if you need them.
C<SHUTDOWN> and C<DEBUG> are also not wrapped on purpose.

=cut

sub _flat { return map { ref($_) eq 'ARRAY' ? @$_ : $_ } @_; }

# --- strings ---------------------------------------------------------------

sub substr { my ($self, $k, $s, $e) = @_; return $self->_call('SUBSTR', $k, $s, $e); }
sub digest { my ($self, $k) = @_; return $self->_call('DIGEST', $k); }

sub lcs {
    my $self = shift;
    my ($k1, $k2) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('LCS', $k1, $k2);
    push @args, 'LEN' if $opts->{len};
    push @args, 'IDX' if $opts->{idx};
    push @args, 'MINMATCHLEN', $opts->{minmatchlen} if defined $opts->{minmatchlen};
    push @args, 'WITHMATCHLEN' if $opts->{withmatchlen};
    return $self->_call(@args);
}

# IFEQ / IFNE / IFDEQ / IFDNE condition, shared by SET and DELEX.
sub _condition_args {
    my ($opts) = @_;
    my @args;
    for my $name (qw(ifeq ifne ifdeq ifdne)) {
        push @args, uc($name), $opts->{$name} if defined $opts->{$name};
    }
    return @args;
}

sub delex {
    my $self = shift;
    my $key  = shift;
    my $opts = _opts(\@_);
    return $self->_call('DELEX', $key, _condition_args($opts));
}

sub msetex {
    my $self  = shift;
    my $pairs = shift;
    my $opts  = _opts(\@_);
    my @args  = ('MSETEX', scalar(@$pairs) / 2, @$pairs);
    push @args, 'NX' if $opts->{nx};
    push @args, 'XX' if $opts->{xx};
    for my $name (qw(ex px exat pxat)) {
        push @args, uc($name), $opts->{$name} if defined $opts->{$name};
    }
    push @args, 'KEEPTTL' if $opts->{keepttl};
    return $self->_call(@args);
}

# --- keys ------------------------------------------------------------------

sub expiretime  { my ($self, $k) = @_; return $self->_call('EXPIRETIME', $k); }
sub pexpiretime { my ($self, $k) = @_; return $self->_call('PEXPIRETIME', $k); }
sub move        { my ($self, $k, $db) = @_; return $self->_call('MOVE', $k, $db); }
sub object      { my ($self, $sub, $k) = @_; return $self->_call('OBJECT', uc($sub), $k); }
sub object_freq     { my ($self, $k) = @_; return $self->_call('OBJECT', 'FREQ', $k); }
sub object_idletime { my ($self, $k) = @_; return $self->_call('OBJECT', 'IDLETIME', $k); }
sub object_refcount { my ($self, $k) = @_; return $self->_call('OBJECT', 'REFCOUNT', $k); }
sub wait        { my ($self, $n, $ms) = @_; return $self->_call('WAIT', $n, $ms); }
sub waitaof     { my ($self, $local, $replicas, $ms) = @_; return $self->_call('WAITAOF', $local, $replicas, $ms); }

sub _sort_args {
    my ($wire, $key, $opts) = @_;
    my @args = ($wire, $key);
    push @args, 'BY', $opts->{by} if defined $opts->{by};
    push @args, 'LIMIT', @{ $opts->{limit} }[0, 1] if $opts->{limit};
    push @args, map { ('GET', $_) } @{ $opts->{get} || [] };
    push @args, 'ASC'  if $opts->{asc};
    push @args, 'DESC' if $opts->{desc};
    push @args, 'ALPHA' if $opts->{alpha};
    push @args, 'STORE', $opts->{store} if $wire eq 'SORT' && defined $opts->{store};
    return @args;
}
sub sort    { my $self = shift; my $key = shift; my $opts = _opts(\@_); return $self->_call(_sort_args('SORT', $key, $opts)); }
sub sort_ro { my $self = shift; my $key = shift; my $opts = _opts(\@_); return $self->_call(_sort_args('SORT_RO', $key, $opts)); }

# --- lists / zsets / hashes -----------------------------------------------

sub brpoplpush { my ($self, $s, $d, $timeout) = @_; return $self->_call('BRPOPLPUSH', $s, $d, $timeout); }

sub lmpop {
    my $self = shift;
    my ($keys, $dir) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('LMPOP', scalar(@$keys), @$keys, uc($dir));
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    return $self->_call(@args);
}
sub blmpop {
    my $self = shift;
    my ($timeout, $keys, $dir) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('BLMPOP', $timeout, scalar(@$keys), @$keys, uc($dir));
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    return $self->_call(@args);
}
sub zmpop {
    my $self = shift;
    my ($keys, $which) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('ZMPOP', scalar(@$keys), @$keys, uc($which));
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    return $self->_call(@args);
}
sub bzmpop {
    my $self = shift;
    my ($timeout, $keys, $which) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('BZMPOP', $timeout, scalar(@$keys), @$keys, uc($which));
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    return $self->_call(@args);
}
sub bzpopmin { my $self = shift; my $timeout = pop; return $self->_call('BZPOPMIN', @_, $timeout); }
sub bzpopmax { my $self = shift; my $timeout = pop; return $self->_call('BZPOPMAX', @_, $timeout); }
sub zlexcount { my ($self, $k, $min, $max) = @_; return $self->_call('ZLEXCOUNT', $k, $min, $max); }

sub hstrlen { my ($self, $k, $f) = @_; return $self->_call('HSTRLEN', $k, $f); }
sub hgetdel { my ($self, $k, $fields) = @_; return $self->_call('HGETDEL', $k, 'FIELDS', scalar(@$fields), @$fields); }
sub hgetex {
    my $self = shift;
    my ($k, $fields) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('HGETEX', $k);
    for my $name (qw(ex px exat pxat)) {
        push @args, uc($name), $opts->{$name} if defined $opts->{$name};
    }
    push @args, 'PERSIST' if $opts->{persist};
    push @args, 'FIELDS', scalar(@$fields), @$fields;
    return $self->_call(@args);
}
sub hsetex {
    my $self = shift;
    my ($k, $pairs) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('HSETEX', $k);
    push @args, 'FNX' if $opts->{fnx};
    push @args, 'FXX' if $opts->{fxx};
    for my $name (qw(ex px exat pxat)) {
        push @args, uc($name), $opts->{$name} if defined $opts->{$name};
    }
    push @args, 'KEEPTTL' if $opts->{keepttl};
    push @args, 'FIELDS', scalar(@$pairs) / 2, @$pairs;
    return $self->_call(@args);
}
sub hexpiretime  { my ($self, $k, $f) = @_; return $self->_hash_field_ttl('HEXPIRETIME', $k, undef, $f, {}); }
sub hpexpiretime { my ($self, $k, $f) = @_; return $self->_hash_field_ttl('HPEXPIRETIME', $k, undef, $f, {}); }
sub himport_prepare    { my $self = shift; my $name = shift; return $self->_call('HIMPORT', 'PREPARE', $name, @_); }
sub himport_set        { my $self = shift; my ($k, $name) = (shift, shift); return $self->_call('HIMPORT', 'SET', $k, $name, @_); }
sub himport_discard    { my ($self, $name) = @_; return $self->_call('HIMPORT', 'DISCARD', $name); }
sub himport_discardall { my ($self) = @_; return $self->_call('HIMPORT', 'DISCARDALL'); }

# --- streams ---------------------------------------------------------------

sub xsetid {
    my $self = shift;
    my ($k, $id) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('XSETID', $k, $id);
    push @args, 'ENTRIESADDED', $opts->{entries_added} if defined $opts->{entries_added};
    push @args, 'MAXDELETEDID', $opts->{max_deleted_id} if defined $opts->{max_deleted_id};
    return $self->_call(@args);
}
sub xcfgset {
    my $self = shift;
    my $k    = shift;
    my $opts = _opts(\@_);
    my @args = ('XCFGSET', $k);
    push @args, 'IDMP-DURATION', $opts->{idmp_duration} if defined $opts->{idmp_duration};
    push @args, 'IDMP-MAXSIZE',  $opts->{idmp_maxsize}  if defined $opts->{idmp_maxsize};
    return $self->_call(@args);
}

# --- geo -------------------------------------------------------------------

sub _georadius_tail {
    my ($opts, $allow_store) = @_;
    my @args;
    push @args, 'WITHCOORD' if $opts->{withcoord};
    push @args, 'WITHDIST'  if $opts->{withdist};
    push @args, 'WITHHASH'  if $opts->{withhash};
    push @args, 'COUNT', $opts->{count}, ($opts->{any} ? 'ANY' : ()) if defined $opts->{count};
    push @args, 'ASC'  if $opts->{asc};
    push @args, 'DESC' if $opts->{desc};
    if ($allow_store) {
        push @args, 'STORE',     $opts->{store}     if defined $opts->{store};
        push @args, 'STOREDIST', $opts->{storedist} if defined $opts->{storedist};
    }
    return @args;
}
sub georadius {
    my $self = shift;
    my ($k, $lon, $lat, $r, $unit) = (shift, shift, shift, shift, shift);
    my $opts = _opts(\@_);
    return $self->_call('GEORADIUS', $k, $lon, $lat, $r, uc($unit), _georadius_tail($opts, 1));
}
sub georadius_ro {
    my $self = shift;
    my ($k, $lon, $lat, $r, $unit) = (shift, shift, shift, shift, shift);
    my $opts = _opts(\@_);
    return $self->_call('GEORADIUS_RO', $k, $lon, $lat, $r, uc($unit), _georadius_tail($opts, 0));
}
sub georadiusbymember {
    my $self = shift;
    my ($k, $m, $r, $unit) = (shift, shift, shift, shift);
    my $opts = _opts(\@_);
    return $self->_call('GEORADIUSBYMEMBER', $k, $m, $r, uc($unit), _georadius_tail($opts, 1));
}
sub georadiusbymember_ro {
    my $self = shift;
    my ($k, $m, $r, $unit) = (shift, shift, shift, shift);
    my $opts = _opts(\@_);
    return $self->_call('GEORADIUSBYMEMBER_RO', $k, $m, $r, uc($unit), _georadius_tail($opts, 0));
}
sub geosearchstore {
    my $self = shift;
    my ($dest, $src) = (shift, shift);
    my $opts = _opts(\@_);
    my @args = ('GEOSEARCHSTORE', $dest, $src);
    if (defined $opts->{frommember}) { push @args, 'FROMMEMBER', $opts->{frommember}; }
    elsif ($opts->{fromlonlat})     { push @args, 'FROMLONLAT', @{ $opts->{fromlonlat} }; }
    if    ($opts->{byradius}) { push @args, 'BYRADIUS', @{ $opts->{byradius} }; }
    elsif ($opts->{bybox})    { push @args, 'BYBOX', @{ $opts->{bybox} }; }
    push @args, 'ASC'  if $opts->{asc};
    push @args, 'DESC' if $opts->{desc};
    push @args, 'COUNT', $opts->{count}, ($opts->{any} ? 'ANY' : ()) if defined $opts->{count};
    push @args, 'STOREDIST' if $opts->{storedist};
    return $self->_call(@args);
}

# --- bitfield --------------------------------------------------------------

sub bitfield    { my $self = shift; my $k = shift; return $self->_call('BITFIELD', $k, _flat(@_)); }
sub bitfield_ro { my $self = shift; my $k = shift; return $self->_call('BITFIELD_RO', $k, _flat(@_)); }

# --- pub/sub publishing ------------------------------------------------------

sub publish  { my ($self, $ch, $msg) = @_; return $self->_call('PUBLISH', $ch, $msg); }
sub spublish { my ($self, $ch, $msg) = @_; return $self->_call('SPUBLISH', $ch, $msg); }
sub pubsub_channels { my ($self, $pattern) = @_; my @a = ('PUBSUB', 'CHANNELS'); push @a, $pattern if defined $pattern; return $self->_call(@a); }
sub pubsub_numpat   { my ($self) = @_; return $self->_call('PUBSUB', 'NUMPAT'); }
sub pubsub_shardchannels { my ($self, $pattern) = @_; my @a = ('PUBSUB', 'SHARDCHANNELS'); push @a, $pattern if defined $pattern; return $self->_call(@a); }
sub pubsub_numsub {
    my $self = shift;
    my $r = $self->_call('PUBSUB', 'NUMSUB', @_);
    return $self->_is_deferred($r) ? $r : _to_hash($r);
}
sub pubsub_shardnumsub {
    my $self = shift;
    my $r = $self->_call('PUBSUB', 'SHARDNUMSUB', @_);
    return $self->_is_deferred($r) ? $r : _to_hash($r);
}

# --- server ------------------------------------------------------------------

sub save         { my ($self) = @_; return $self->_call('SAVE'); }
sub bgsave       { my ($self, $schedule) = @_; my @a = ('BGSAVE'); push @a, 'SCHEDULE' if $schedule; return $self->_call(@a); }
sub bgrewriteaof { my ($self) = @_; return $self->_call('BGREWRITEAOF'); }
sub role         { my ($self) = @_; return $self->_call('ROLE'); }
sub lolwut       { my ($self, $version) = @_; my @a = ('LOLWUT'); push @a, 'VERSION', $version if defined $version; return $self->_call(@a); }
sub replicaof    { my ($self, $host, $port) = @_; return $self->_call('REPLICAOF', $host, $port); }
sub replicaof_no_one { my ($self) = @_; return $self->_call('REPLICAOF', 'NO', 'ONE'); }
sub failover {
    my $self = shift;
    my $opts = _opts(\@_);
    my @args = ('FAILOVER');
    push @args, 'TO', @{ $opts->{to} }[0, 1], ($opts->{force} ? 'FORCE' : ()) if $opts->{to};
    push @args, 'ABORT' if $opts->{abort};
    push @args, 'TIMEOUT', $opts->{timeout} if defined $opts->{timeout};
    return $self->_call(@args);
}
sub slowlog_get   { my ($self, $count) = @_; my @a = ('SLOWLOG', 'GET'); push @a, $count if defined $count; return $self->_call(@a); }
sub slowlog_len   { my ($self) = @_; return $self->_call('SLOWLOG', 'LEN'); }
sub slowlog_reset { my ($self) = @_; return $self->_call('SLOWLOG', 'RESET'); }
sub memory_usage  { my $self = shift; my $k = shift; my $opts = _opts(\@_); my @a = ('MEMORY', 'USAGE', $k); push @a, 'SAMPLES', $opts->{samples} if defined $opts->{samples}; return $self->_call(@a); }
sub memory_stats  { my ($self) = @_; my $r = $self->_call('MEMORY', 'STATS'); return $self->_is_deferred($r) ? $r : _to_hash($r); }
sub memory_doctor { my ($self) = @_; return $self->_call('MEMORY', 'DOCTOR'); }
sub memory_purge  { my ($self) = @_; return $self->_call('MEMORY', 'PURGE'); }
sub memory_malloc_stats { my ($self) = @_; return $self->_call('MEMORY', 'MALLOC-STATS'); }
sub slowlog_export { my ($self) = @_; return $self->_call('SLOWLOG', 'EXPORT'); }
sub module_list { my ($self) = @_; return $self->_call('MODULE', 'LIST'); }
sub latency_latest    { my ($self) = @_; return $self->_call('LATENCY', 'LATEST'); }
sub latency_history   { my ($self, $event) = @_; return $self->_call('LATENCY', 'HISTORY', $event); }
sub latency_reset     { my $self = shift; return $self->_call('LATENCY', 'RESET', @_); }
sub latency_graph     { my ($self, $event) = @_; return $self->_call('LATENCY', 'GRAPH', $event); }
sub latency_doctor    { my ($self) = @_; return $self->_call('LATENCY', 'DOCTOR'); }
sub latency_histogram { my $self = shift; return $self->_call('LATENCY', 'HISTOGRAM', @_); }
sub config_resetstat  { my ($self) = @_; return $self->_call('CONFIG', 'RESETSTAT'); }
sub config_rewrite    { my ($self) = @_; return $self->_call('CONFIG', 'REWRITE'); }

sub client_list {
    my $self = shift;
    my $opts = _opts(\@_);
    my @args = ('CLIENT', 'LIST');
    push @args, 'TYPE', $opts->{type} if defined $opts->{type};
    push @args, 'ID', @{ $opts->{id} } if $opts->{id} && @{ $opts->{id} };
    return $self->_call(@args);
}
sub client_info      { my ($self) = @_; return $self->_call('CLIENT', 'INFO'); }
sub client_kill      { my $self = shift; return $self->_call('CLIENT', 'KILL', @_); }
sub client_pause     { my $self = shift; my $ms = shift; my $opts = _opts(\@_); my @a = ('CLIENT', 'PAUSE', $ms); push @a, uc($opts->{mode}) if defined $opts->{mode}; return $self->_call(@a); }
sub client_unpause   { my ($self) = @_; return $self->_call('CLIENT', 'UNPAUSE'); }
sub client_noevict   { my ($self, $on) = @_; return $self->_call('CLIENT', 'NO-EVICT', $on ? 'ON' : 'OFF'); }
sub client_notouch   { my ($self, $on) = @_; return $self->_call('CLIENT', 'NO-TOUCH', $on ? 'ON' : 'OFF'); }
sub client_setinfo   { my ($self, $attr, $value) = @_; return $self->_call('CLIENT', 'SETINFO', uc($attr), $value); }
sub client_unblock   { my $self = shift; my $id = shift; my $opts = _opts(\@_); my @a = ('CLIENT', 'UNBLOCK', $id); push @a, 'ERROR' if $opts->{error}; return $self->_call(@a); }
sub client_tracking {
    my $self = shift;
    my $on   = shift;
    my $opts = _opts(\@_);
    my @args = ('CLIENT', 'TRACKING', $on ? 'ON' : 'OFF');
    push @args, 'REDIRECT', $opts->{redirect} if defined $opts->{redirect};
    push @args, map { ('PREFIX', $_) } @{ $opts->{prefix} || [] };
    push @args, 'BCAST'   if $opts->{bcast};
    push @args, 'OPTIN'   if $opts->{optin};
    push @args, 'OPTOUT'  if $opts->{optout};
    push @args, 'NOLOOP'  if $opts->{noloop};
    return $self->_call(@args);
}
sub client_trackinginfo { my ($self) = @_; my $r = $self->_call('CLIENT', 'TRACKINGINFO'); return $self->_is_deferred($r) ? $r : _to_hash($r); }
sub client_caching      { my ($self, $yes) = @_; return $self->_call('CLIENT', 'CACHING', $yes ? 'YES' : 'NO'); }
sub client_getredir     { my ($self) = @_; return $self->_call('CLIENT', 'GETREDIR'); }

sub command_info    { my $self = shift; return $self->_call('COMMAND', 'INFO', @_); }
sub command_docs    { my $self = shift; return $self->_call('COMMAND', 'DOCS', @_); }
sub command_getkeys { my $self = shift; return $self->_call('COMMAND', 'GETKEYS', @_); }
sub command_getkeysandflags { my $self = shift; return $self->_call('COMMAND', 'GETKEYSANDFLAGS', @_); }
sub command_list {
    my $self = shift;
    my $opts = _opts(\@_);
    my @args = ('COMMAND', 'LIST');
    push @args, 'FILTERBY', $opts->{filterby}[0], $opts->{filterby}[1] if $opts->{filterby};
    return $self->_call(@args);
}

# --- scripting / functions ---------------------------------------------------

sub eval_ro {
    my $self = shift;
    my ($script, $keys, $args) = @_;
    return $self->_call('EVAL_RO', $script, scalar(@{ $keys || [] }), @{ $keys || [] }, @{ $args || [] });
}
sub evalsha_ro {
    my $self = shift;
    my ($sha, $keys, $args) = @_;
    return $self->_call('EVALSHA_RO', $sha, scalar(@{ $keys || [] }), @{ $keys || [] }, @{ $args || [] });
}
sub script_kill { my ($self) = @_; return $self->_call('SCRIPT', 'KILL'); }
sub fcall {
    my $self = shift;
    my ($fn, $keys, $args) = @_;
    return $self->_call('FCALL', $fn, scalar(@{ $keys || [] }), @{ $keys || [] }, @{ $args || [] });
}
sub fcall_ro {
    my $self = shift;
    my ($fn, $keys, $args) = @_;
    return $self->_call('FCALL_RO', $fn, scalar(@{ $keys || [] }), @{ $keys || [] }, @{ $args || [] });
}
sub function_load {
    my $self = shift;
    my $code = shift;
    my $opts = _opts(\@_);
    my @args = ('FUNCTION', 'LOAD');
    push @args, 'REPLACE' if $opts->{replace};
    return $self->_call(@args, $code);
}
sub function_delete { my ($self, $lib) = @_; return $self->_call('FUNCTION', 'DELETE', $lib); }
sub function_list {
    my $self = shift;
    my $opts = _opts(\@_);
    my @args = ('FUNCTION', 'LIST');
    push @args, 'LIBRARYNAME', $opts->{libraryname} if defined $opts->{libraryname};
    push @args, 'WITHCODE' if $opts->{withcode};
    return $self->_call(@args);
}
sub function_stats { my ($self) = @_; return $self->_call('FUNCTION', 'STATS'); }
sub function_flush { my ($self, $mode) = @_; my @a = ('FUNCTION', 'FLUSH'); push @a, uc($mode) if defined $mode; return $self->_call(@a); }
sub function_dump  { my ($self) = @_; return $self->_call('FUNCTION', 'DUMP'); }
sub function_kill  { my ($self) = @_; return $self->_call('FUNCTION', 'KILL'); }
sub function_restore {
    my $self = shift;
    my $payload = shift;
    my $opts = _opts(\@_);
    my @args = ('FUNCTION', 'RESTORE', $payload);
    push @args, uc($opts->{policy}) if defined $opts->{policy};
    return $self->_call(@args);
}

# --- ACL ---------------------------------------------------------------------

sub acl_setuser { my $self = shift; my $user = shift; return $self->_call('ACL', 'SETUSER', $user, @_); }
sub acl_getuser { my ($self, $user) = @_; my $r = $self->_call('ACL', 'GETUSER', $user); return $self->_is_deferred($r) ? $r : _to_hash($r); }
sub acl_deluser { my $self = shift; return $self->_call('ACL', 'DELUSER', @_); }
sub acl_list    { my ($self) = @_; return $self->_call('ACL', 'LIST'); }
sub acl_users   { my ($self) = @_; return $self->_call('ACL', 'USERS'); }
sub acl_whoami  { my ($self) = @_; return $self->_call('ACL', 'WHOAMI'); }
sub acl_cat     { my ($self, $category) = @_; my @a = ('ACL', 'CAT'); push @a, $category if defined $category; return $self->_call(@a); }
sub acl_dryrun  { my $self = shift; my $user = shift; return $self->_call('ACL', 'DRYRUN', $user, @_); }
sub acl_log     { my ($self, $arg) = @_; my @a = ('ACL', 'LOG'); push @a, $arg if defined $arg; return $self->_call(@a); }
sub acl_genpass { my ($self, $bits) = @_; my @a = ('ACL', 'GENPASS'); push @a, $bits if defined $bits; return $self->_call(@a); }
sub acl_save    { my ($self) = @_; return $self->_call('ACL', 'SAVE'); }
sub acl_load    { my ($self) = @_; return $self->_call('ACL', 'LOAD'); }

# --- cluster-aware key space commands (single node servers refuse them) --------

sub clusterscan {
    my $self = shift;
    my $cursor = shift // 0;
    my $opts = _opts(\@_);
    my @args = ('CLUSTERSCAN', $cursor);
    push @args, 'MATCH', $opts->{match} if defined $opts->{match};
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    push @args, 'TYPE',  $opts->{type}  if defined $opts->{type};
    push @args, 'SLOT',  $opts->{slot}  if defined $opts->{slot};
    return $self->_call(@args);
}
sub sflush {
    my $self = shift;
    my $ranges = shift;
    my $opts = _opts(\@_);
    my @args = ('SFLUSH', map { @$_ } @$ranges);
    push @args, uc($opts->{mode}) if defined $opts->{mode};
    return $self->_call(@args);
}
sub trimslots {
    my ($self, $ranges) = @_;
    return $self->_call('TRIMSLOTS', 'RANGES', scalar(@$ranges), map { @$_ } @$ranges);
}
sub cluster_info  { my ($self) = @_; return $self->_call('CLUSTER', 'INFO'); }
sub cluster_nodes { my ($self) = @_; return $self->_call('CLUSTER', 'NODES'); }
sub cluster_slots { my ($self) = @_; return $self->_call('CLUSTER', 'SLOTS'); }
sub cluster_shards { my ($self) = @_; return $self->_call('CLUSTER', 'SHARDS'); }
sub cluster_myid  { my ($self) = @_; return $self->_call('CLUSTER', 'MYID'); }
sub cluster_keyslot { my ($self, $key) = @_; return $self->_call('CLUSTER', 'KEYSLOT', $key); }
sub cluster_countkeysinslot { my ($self, $slot) = @_; return $self->_call('CLUSTER', 'COUNTKEYSINSLOT', $slot); }
sub cluster_getkeysinslot   { my ($self, $slot, $count) = @_; return $self->_call('CLUSTER', 'GETKEYSINSLOT', $slot, $count); }

# ---------------------------------------------------------------------------
# HotKV exclusive and AI command family accessors.
#
# Each returns a lightweight object bound to $self (the client, pipeline or
# transaction this was called on), so family methods route through whatever
# _call() that owner implements. See HotKV::Commands::* for each family's
# methods and HotKV::AI::* for the higher level caching helpers.
# ---------------------------------------------------------------------------

sub bf         { require HotKV::Commands::Bloom;         return HotKV::Commands::Bloom->new($_[0]); }
sub cms        { require HotKV::Commands::CountMin;      return HotKV::Commands::CountMin->new($_[0]); }
sub topk       { require HotKV::Commands::TopK;          return HotKV::Commands::TopK->new($_[0]); }
sub tenant     { require HotKV::Commands::Tenant;        return HotKV::Commands::Tenant->new($_[0]); }
sub iam        { require HotKV::Commands::Iam;           return HotKV::Commands::Iam->new($_[0]); }
sub audit      { require HotKV::Commands::Audit;         return HotKV::Commands::Audit->new($_[0]); }
sub encryption { require HotKV::Commands::Encryption;    return HotKV::Commands::Encryption->new($_[0]); }
sub replication { require HotKV::Commands::Replication;  return HotKV::Commands::Replication->new($_[0]); }
sub tag        { require HotKV::Commands::Tag;           return HotKV::Commands::Tag->new($_[0]); }
sub gcra       { require HotKV::Commands::Gcra;          return HotKV::Commands::Gcra->new($_[0]); }
sub vsim       { require HotKV::Commands::Vsim;          return HotKV::Commands::Vsim->new($_[0]); }
sub scache     { require HotKV::Commands::SemanticCache; return HotKV::Commands::SemanticCache->new($_[0]); }
sub pcache     { require HotKV::Commands::PromptCache;   return HotKV::Commands::PromptCache->new($_[0]); }
sub toolcache  { require HotKV::Commands::ToolCache;     return HotKV::Commands::ToolCache->new($_[0]); }
sub ncache     { require HotKV::Commands::NegativeCache; return HotKV::Commands::NegativeCache->new($_[0]); }
sub guard      { require HotKV::Commands::GuardCache;    return HotKV::Commands::GuardCache->new($_[0]); }
sub rerank     { require HotKV::Commands::RerankCache;   return HotKV::Commands::RerankCache->new($_[0]); }
sub llmstats   { require HotKV::Commands::LLMStats;      return HotKV::Commands::LLMStats->new($_[0]); }
sub llmbudget  { require HotKV::Commands::LLMBudget;     return HotKV::Commands::LLMBudget->new($_[0]); }
sub prompt     { require HotKV::Commands::Prompt;        return HotKV::Commands::Prompt->new($_[0]); }
sub embeddedup { require HotKV::Commands::EmbedDedup;    return HotKV::Commands::EmbedDedup->new($_[0]); }
sub amem       { require HotKV::Commands::AgentMemory;   return HotKV::Commands::AgentMemory->new($_[0]); }
sub rag        { require HotKV::Commands::Rag;           return HotKV::Commands::Rag->new($_[0]); }
sub ratelimit  { require HotKV::Commands::RateLimit;     return HotKV::Commands::RateLimit->new($_[0]); }
sub ts         { require HotKV::Commands::TimeSeries;    return HotKV::Commands::TimeSeries->new($_[0]); }
sub feature    { require HotKV::Commands::FeatureStore;  return HotKV::Commands::FeatureStore->new($_[0]); }
sub observe    { require HotKV::Commands::Observe;       return HotKV::Commands::Observe->new($_[0]); }

1;
