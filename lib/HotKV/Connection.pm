# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Connection;

use strict;
use warnings;

use IO::Socket::INET;
use IO::Select;
use Scalar::Util qw(blessed);

use HotKV::Error;
use HotKV::Protocol;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Connection - A single physical connection to a HotKV server

=head1 DESCRIPTION

Owns one TCP, unix domain, or TLS socket, performs C<HELLO 3> protocol
negotiation (falling back to RESP2 automatically when the server does not
understand C<HELLO>), C<AUTH> and C<SELECT>, and exposes a minimal
synchronous request/response and pipelining API. Higher level concerns
(pooling, retry, pipelining batches, transactions, pub/sub) live in
L<HotKV::Pool>, L<HotKV::Pipeline>, L<HotKV::Transaction> and
L<HotKV::PubSub>.

=head1 OPTIONS

host, port, path (unix socket path; mutually exclusive with host/port),
username, password, db, client_name, connect_timeout (seconds, default 5),
command_timeout (seconds, default 5, undef means wait forever), resp3
(default true), tls (bool), tls_ca_file, tls_cert_file, tls_key_file,
tls_server_name, tls_insecure_skip_verify, on_push (a coderef called with each
RESP3 push message that arrives while a command waits for its reply, such as
an invalidation after C<CLIENT TRACKING>; pushes are dropped when it is not
given).

=cut

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        host              => $opts{host} // '127.0.0.1',
        port              => $opts{port} // 6379,
        path              => $opts{path},
        username          => $opts{username},
        password          => $opts{password},
        db                => $opts{db} // 0,
        client_name       => $opts{client_name},
        connect_timeout   => exists $opts{connect_timeout} ? $opts{connect_timeout} : 5,
        command_timeout   => exists $opts{command_timeout} ? $opts{command_timeout} : 5,
        resp3             => exists $opts{resp3} ? $opts{resp3} : 1,
        tls               => $opts{tls} // 0,
        tls_ca_file       => $opts{tls_ca_file},
        tls_cert_file     => $opts{tls_cert_file},
        tls_key_file      => $opts{tls_key_file},
        tls_server_name   => $opts{tls_server_name},
        tls_insecure_skip_verify => $opts{tls_insecure_skip_verify} // 0,
        on_push           => $opts{on_push},
        raw_push          => $opts{raw_push},
        sock              => undef,
        reader            => undef,
        proto             => 2,
        pid               => undef,
    }, $class;
    return $self;
}

=head2 connect

Opens the socket, negotiates the protocol, authenticates and selects the
database. Idempotent: a second call on an already-connected instance is a
no-op.

=cut

sub connect {
    my ($self) = @_;
    return if $self->{sock};

    my $sock;
    if ($self->{path}) {
        require IO::Socket::UNIX;
        $sock = IO::Socket::UNIX->new(
            Peer    => $self->{path},
            Type    => IO::Socket::UNIX::SOCK_STREAM(),
            Timeout => $self->{connect_timeout},
        );
        unless ($sock) {
            HotKV::Error::Connection->throw(
                message => "hotkv: cannot connect to unix socket $self->{path}: $!");
        }
    }
    else {
        $sock = IO::Socket::INET->new(
            PeerAddr => $self->{host},
            PeerPort => $self->{port},
            Proto    => 'tcp',
            Timeout  => $self->{connect_timeout},
        );
        unless ($sock) {
            HotKV::Error::Connection->throw(
                message => "hotkv: cannot connect to $self->{host}:$self->{port}: $!");
        }
        $sock->setsockopt(&Socket::IPPROTO_TCP, &Socket::TCP_NODELAY, 1) if eval { require Socket; 1 };
    }

    if ($self->{tls}) {
        require IO::Socket::SSL;
        my %ssl_opts = (
            SSL_verify_mode => $self->{tls_insecure_skip_verify}
                ? IO::Socket::SSL::SSL_VERIFY_NONE()
                : IO::Socket::SSL::SSL_VERIFY_PEER(),
        );
        $ssl_opts{SSL_ca_file}       = $self->{tls_ca_file}   if $self->{tls_ca_file};
        $ssl_opts{SSL_cert_file}     = $self->{tls_cert_file} if $self->{tls_cert_file};
        $ssl_opts{SSL_key_file}      = $self->{tls_key_file}  if $self->{tls_key_file};
        $ssl_opts{Timeout}           = $self->{connect_timeout} if defined $self->{connect_timeout};
        $ssl_opts{SSL_hostname}      = $self->{tls_server_name} // $self->{host};
        $ssl_opts{SSL_verifycn_name} = $self->{tls_server_name} // $self->{host};
        IO::Socket::SSL->start_SSL($sock, %ssl_opts)
            or HotKV::Error::Connection->throw(
                message => 'hotkv: TLS handshake failed: ' . IO::Socket::SSL::errstr());
    }

    $sock->autoflush(1);
    binmode $sock;
    $self->{sock}   = $sock;
    $self->{pid}    = $$;
    $self->{select} = IO::Select->new($sock);
    $self->{reader} = HotKV::Protocol::Reader->new(fill => sub {
        my (undef, $timeout) = @_;
        return $self->_fill($timeout);
    });

    eval {
        $self->_negotiate;
        1;
    } or do {
        my $err = $@;
        $self->close;
        die $err;
    };
    return;
}

sub _fill {
    my ($self, $timeout) = @_;
    my $sock = $self->{sock};
    # A TLS socket may hold decrypted bytes the kernel socket no longer
    # signals as readable, so look at the TLS layer's own buffer first.
    my $buffered = $self->{tls} && $sock->can('pending') && $sock->pending;
    if (defined $timeout && !$buffered) {
        my @ready = $self->{select}->can_read($timeout);
        unless (@ready) {
            HotKV::Error::Timeout->throw(message => 'hotkv: command timed out waiting for a reply');
        }
    }
    my $n = sysread($sock, my $chunk, 65536);
    if (!defined $n) {
        return '' if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
        HotKV::Error::Connection->throw(message => "hotkv: read error: $!");
    }
    return undef if $n == 0; # EOF
    return $chunk;
}

sub _negotiate {
    my ($self) = @_;

    if ($self->{resp3}) {
        my @args = ('HELLO', '3');
        if (defined $self->{password}) {
            push @args, 'AUTH', (defined $self->{username} && length $self->{username} ? $self->{username} : 'default'), $self->{password};
        }
        push @args, 'SETNAME', $self->{client_name} if defined $self->{client_name};

        my $reply = eval { $self->_raw_command(@args) };
        if (!$@) {
            $self->{proto}       = 3;
            $self->{server_info} = $reply;
        }
        else {
            my $err = $@;
            die $err unless blessed($err) && $err->isa('HotKV::Error::Server');
            # Older/plain-RESP2 server: fall back and authenticate explicitly.
            $self->{proto} = 2;
            $self->_auth_and_setname_resp2;
        }
    }
    else {
        $self->{proto} = 2;
        $self->_auth_and_setname_resp2;
    }

    if ($self->{db}) {
        $self->_raw_command('SELECT', $self->{db});
    }
    return;
}

sub _auth_and_setname_resp2 {
    my ($self) = @_;
    if (defined $self->{password}) {
        if (defined $self->{username} && length $self->{username}) {
            $self->_raw_command('AUTH', $self->{username}, $self->{password});
        }
        else {
            $self->_raw_command('AUTH', $self->{password});
        }
    }
    if (defined $self->{client_name}) {
        $self->_raw_command('CLIENT', 'SETNAME', $self->{client_name});
    }
    return;
}

# Sends a command and reads exactly one reply, raising a HotKV::Error on a
# server error reply. Used internally (handshake) and by the public command().
sub _raw_command {
    my ($self, @args) = @_;
    $self->write_command(@args);
    my $reply = $self->read_reply($self->timeout_for(@args));
    if (blessed($reply) && $reply->isa('HotKV::Error')) {
        die $reply;
    }
    return $reply;
}

=head2 timeout_for(@args)

The number of seconds to wait for the reply to the command C<@args>
(C<undef> waits forever). It is C<command_timeout> for an ordinary command.
A blocking command may legitimately hold its reply for as long as its own
timeout argument says, so for C<BLPOP>, C<BRPOP>, C<BRPOPLPUSH>, C<BLMOVE>,
C<BLMPOP>, C<BZPOPMIN>, C<BZPOPMAX>, C<BZMPOP>, C<XREAD ... BLOCK ms>,
C<XREADGROUP ... BLOCK ms>, C<WAIT> and C<WAITAOF> it is that wait plus
C<command_timeout> of slack, and with a wait of C<0> (block forever) it is
C<undef>. Without this a C<BLPOP key 10> would die after C<command_timeout>
seconds with a client side timeout while the server is still, correctly,
waiting.

=cut

sub timeout_for {
    my ($self, @args) = @_;
    my $base = $self->{command_timeout};
    return undef unless defined $base;
    my $wait = server_wait(@args);
    return $base unless defined $wait;
    return $wait == 0 ? undef : $wait + $base;
}

=head2 HotKV::Connection::server_wait(@args)

How many seconds the server may hold the reply to the command C<@args>:
C<undef> for a command that does not block, C<0> for a blocking command
asked to wait forever, else the wait in seconds.

=cut

sub server_wait {
    my @a = @_;
    my $cmd = defined $a[0] ? uc($a[0]) : '';
    my $num = sub {
        my $v = shift;
        return undef unless defined $v && $v =~ /\A\s*[0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?\s*\z/;
        return $v + 0;
    };
    if ($cmd =~ /\A(?:BLPOP|BRPOP|BRPOPLPUSH|BLMOVE|BZPOPMIN|BZPOPMAX)\z/) {
        return $num->($a[-1]);
    }
    if ($cmd eq 'BLMPOP' || $cmd eq 'BZMPOP') {
        return $num->($a[1]);
    }
    if ($cmd eq 'XREAD' || $cmd eq 'XREADGROUP') {
        for my $i (1 .. $#a - 1) {
            last if defined $a[$i] && uc($a[$i]) eq 'STREAMS';
            if (defined $a[$i] && uc($a[$i]) eq 'BLOCK') {
                my $ms = $num->($a[$i + 1]);
                return defined $ms ? $ms / 1000 : undef;
            }
        }
        return undef;
    }
    if ($cmd eq 'WAIT') {
        my $ms = $num->($a[2]);
        return defined $ms ? $ms / 1000 : undef;
    }
    if ($cmd eq 'WAITAOF') {
        my $ms = $num->($a[3]);
        return defined $ms ? $ms / 1000 : undef;
    }
    return undef;
}

=head2 command(@args)

Sends one command and waits for its reply, dying with a L<HotKV::Error> on
any error (connection, timeout, protocol or server reply error). The reply
timeout is C<timeout_for>.

=cut

sub command {
    my ($self, @args) = @_;
    return $self->_raw_command(@args);
}

=head2 write_command(@args)

Encodes and writes one command without reading a reply. Used for
pipelining; pair with C<read_reply>.

=cut

sub write_command {
    my ($self, @args) = @_;
    my $sock = $self->{sock}
        or HotKV::Error::Connection->throw(message => 'hotkv: not connected');
    my $bytes = HotKV::Protocol::encode_command(@args);
    my $len   = length $bytes;
    my $off   = 0;
    local $SIG{PIPE} = 'IGNORE';
    while ($off < $len) {
        my $n = syswrite($sock, $bytes, $len - $off, $off);
        if (!defined $n) {
            next if $!{EINTR};
            HotKV::Error::Connection->throw(message => "hotkv: write error: $!");
        }
        $off += $n;
    }
    return;
}

=head2 read_reply([$timeout])

Reads and decodes exactly one reply, skipping RESP3 push messages
(see the C<on_push> option; Pub/Sub sets C<raw_push> to receive them) (does not throw on a server error reply;
returns the L<HotKV::Error::Server> object instead, so pipelines can surface
per-command errors without aborting the batch). Defaults to this
connection's configured C<command_timeout>.

=cut

sub read_reply {
    my ($self, $timeout) = @_;
    $timeout = $self->{command_timeout} unless @_ > 1;
    while (1) {
        my $reply = $self->{reader}->read_reply($timeout);
        # A RESP3 push (for example a client side caching invalidation) can
        # arrive between a command and its reply. It is not the reply: hand
        # it to on_push and keep reading. Pub/Sub reads the pushes itself.
        if (blessed($reply) && $reply->isa('HotKV::Protocol::Push') && !$self->{raw_push}) {
            $self->{on_push}->($reply) if $self->{on_push};
            next;
        }
        return $reply;
    }
}

=head2 is_stale

True when the server has closed this connection (or sent bytes nobody asked
for) while it sat idle: the socket is readable when no reply is outstanding.
A pooled connection is checked with this before it is handed out, so a
server side idle timeout does not turn the next command into an error.

=cut

sub is_stale {
    my ($self) = @_;
    return 1 unless $self->{sock};
    my $sel = $self->{select} or return 1;
    return 1 if $sel->can_read(0);
    return 0;
}

=head2 is_connected

True once C<connect> has succeeded and C<close> has not been called since.

=cut

sub is_connected { return defined $_[0]->{sock}; }

=head2 owner_pid

The PID that created this connection's socket, for fork-safety checks.

=cut

sub owner_pid { return $_[0]->{pid}; }

=head2 protocol_version

2 or 3, whichever was actually negotiated.

=cut

sub protocol_version { return $_[0]->{proto}; }

=head2 ping

Sends C<PING> and returns true, dying on failure. Used as the pool's
borrow-time health check.

=cut

sub ping {
    my ($self) = @_;
    my $reply = $self->_raw_command('PING');
    return 1;
}

=head2 close

Closes the socket. Safe to call multiple times.

=cut

sub close {
    my ($self) = @_;
    if ($self->{sock}) {
        close $self->{sock};
        $self->{sock}   = undef;
        $self->{select} = undef;
    }
    return;
}

sub DESTROY {
    my ($self) = @_;
    local ($@, $!, $?);
    $self->close if $self->{sock};
    return;
}

# ---------------------------------------------------------------------------
# URL parsing
# ---------------------------------------------------------------------------

=head2 HotKV::Connection::parse_url($url)

Parses a C<hotkv://>, C<hotkvs://> (TLS), C<redis://> or C<rediss://> (TLS)
connection URL of the form
C<scheme://[user[:password]@]host[:port][/db][?options]> into an options hash
suitable for C<new>. Returns a hashref. The optional query string takes
C<resp3=0|1>, C<client_name>, C<connect_timeout>, C<command_timeout>,
C<pool_size> and C<idle_timeout>; other keys are ignored.

=cut

sub parse_url {
    my ($url) = @_;
    HotKV::Error::Protocol->throw(message => 'hotkv: empty connection URL') unless defined $url && length $url;

    unless ($url =~ m{ \A ([a-zA-Z][a-zA-Z0-9+.-]*) :// (?: ([^@/]*) @ )? ([^/?\#]*) (?: / ([^?\#]*) )? (?: \? ([^\#]*) )? }x) {
        HotKV::Error::Protocol->throw(message => "hotkv: cannot parse URL: $url");
    }
    my ($scheme, $userinfo, $hostport, $dbpath, $query) = (lc($1), $2, $3, $4, $5);

    my %opts;
    if ($scheme eq 'hotkv' || $scheme eq 'redis') {
        $opts{tls} = 0;
    }
    elsif ($scheme eq 'hotkvs' || $scheme eq 'rediss') {
        $opts{tls} = 1;
    }
    else {
        HotKV::Error::Protocol->throw(message => "hotkv: unsupported URL scheme '$scheme'");
    }

    if (defined $userinfo && length $userinfo) {
        if ($userinfo =~ /^([^:]*):(.*)$/) {
            $opts{username} = _url_unescape($1) if length $1;
            $opts{password} = _url_unescape($2);
        }
        else {
            $opts{password} = _url_unescape($userinfo);
        }
    }

    $hostport = '' unless defined $hostport;
    if ($hostport =~ /^\[([^\]]*)\](?::(\d+))?$/) {
        $opts{host} = $1;
        $opts{port} = $2 + 0 if defined $2;
    }
    elsif ($hostport =~ /^([^:]*)(?::(\d+))?$/) {
        $opts{host} = length($1) ? $1 : '127.0.0.1';
        $opts{port} = $2 + 0 if defined $2;
    }
    else {
        $opts{host} = $hostport;
    }
    $opts{port} = 6379 unless defined $opts{port};

    if (defined $dbpath && length $dbpath) {
        HotKV::Error::Protocol->throw(message => "hotkv: invalid database index in URL: $dbpath")
            unless $dbpath =~ /^\d+$/;
        $opts{db} = $dbpath + 0;
    }

    # Optional query string: ?resp3=0&connect_timeout=2&command_timeout=10&client_name=x
    # &pool_size=8&idle_timeout=60. Unknown keys are ignored.
    if (defined $query && length $query) {
        my %numeric = map { $_ => 1 } qw(connect_timeout command_timeout pool_size idle_timeout);
        for my $pair (split /&/, $query) {
            my ($k, $v) = split /=/, $pair, 2;
            next unless defined $k && length $k;
            $v = '' unless defined $v;
            $k = _url_unescape($k);
            $v = _url_unescape($v);
            if ($k eq 'resp3') {
                $opts{resp3} = ($v =~ /\A(?:0|false|no|off)\z/i) ? 0 : 1;
            }
            elsif ($k eq 'client_name') {
                $opts{client_name} = $v;
            }
            elsif ($numeric{$k}) {
                HotKV::Error::Protocol->throw(message => "hotkv: invalid $k in URL: $v")
                    unless $v =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
                $opts{$k} = $v + 0;
            }
        }
    }

    return \%opts;
}

sub _url_unescape {
    my ($s) = @_;
    $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $s;
}

1;
