# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::AI::PromptCache;

use strict;
use warnings;

use Digest::SHA  ();
use Encode       ();
use Time::HiRes  ();
use Scalar::Util qw(blessed);

use HotKV::TokenUsage;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::AI::PromptCache - Deterministic LLM prompt/response caching helper

=head1 SYNOPSIS

  my $cache = HotKV::AI::PromptCache->new(
      client       => $kv,
      ns           => 'chat-v1',
      stats_bucket => 'chat-v1',   # optional: records usage via LLMSTATS.*
  );

  my $result = $cache->get_or_call(
      provider => 'openai',
      model    => 'gpt-6-sol',
      system   => 'You are a helpful assistant.',
      messages => [ { role => 'user', content => 'What is HotKV?' } ],
      params   => { temperature => '0.7' },
      call     => sub {
          # Only runs on a cache miss.
          my $answer = my_llm_call(...);
          return { response => $answer, input_tokens => 42, output_tokens => 128,
                    cost_usd => '0.0031', latency_ms => 812 };
      },
  );
  print $result->{cached} ? "cache hit\n" : "cache miss, called the LLM\n";
  print $result->{response}, "\n";

=head1 DESCRIPTION

Wraps L<HotKV::Commands::PromptCache> (C<PCACHE.*>, on the C<< $client->pcache >>
accessor) with a deterministic cache key so that logically identical
requests, from any HotKV SDK in any language, produce the identical key:
see C<cache_key> below for the exact canonical form. C<get_or_call> only invokes
the given LLM call on a miss.

=head1 METHODS

=head2 new(%opts)

C<client> (required: a L<HotKV> client, or a L<HotKV::Pipeline> /
L<HotKV::Transaction>), C<ns> (required: the C<PCACHE> namespace; create it
first with C<< $client->pcache->create($ns) >>), C<stats_bucket> (optional:
when set, C<get_or_call> records token usage and cost for each miss via
C<< $client->llmstats->record >>; a C<NOLICENSE> response from that call,
e.g. when the license lacks the C<llm-stats> feature, is swallowed silently since stats recording is
best-effort).

=cut

sub new {
    my ($class, %opts) = @_;
    die "hotkv: HotKV::AI::PromptCache needs client => ...\n" unless $opts{client};
    die "hotkv: HotKV::AI::PromptCache needs ns => ...\n" unless defined $opts{ns} && length $opts{ns};
    return bless {
        client       => $opts{client},
        ns           => $opts{ns},
        stats_bucket => $opts{stats_bucket},
    }, $class;
}

=head2 cache_key(%request)

Callable as a class method (no client or namespace needed) or an instance
method; both compute the same thing. C<%request>: C<provider>, C<model>,
C<system> (string, default C<''>), C<messages> (arrayref of
C<{ role =E<gt> ..., content =E<gt> ... }>, in call order), C<params>
(hashref of caller-supplied generation parameters, default C<{}>; values
must already be strings, e.g. C<"0.7"> not C<0.7>, so numeric formatting
never differs between callers or languages).

Builds exactly this JSON (no insignificant whitespace; top-level keys in
this order: C<provider>, C<model>, C<system>, C<messages>, C<params>; each
message's keys in order C<role>, C<content>; C<params> keys sorted
ascending by byte value; missing C<system>/C<params> still present as
C<""> / C<{}>; C<"> C<\> and control characters below 0x20 escaped as
C<\uXXXX>, non-ASCII left as literal UTF-8) and returns the lowercase hex
SHA-256 digest (64 characters) of its UTF-8 bytes. This exact procedure is
implemented identically in every HotKV SDK.

=cut

sub cache_key {
    my $invocant = shift;
    my (%req) = @_;

    my $provider = defined $req{provider} ? $req{provider} : '';
    my $model    = defined $req{model}    ? $req{model}    : '';
    my $system   = defined $req{system}   ? $req{system}   : '';
    my $messages = $req{messages} || [];
    my $params   = $req{params}   || {};

    my @msg_json;
    for my $m (@$messages) {
        my $role    = defined $m->{role}    ? $m->{role}    : '';
        my $content = defined $m->{content} ? $m->{content} : '';
        push @msg_json, '{"role":' . _jstr($role) . ',"content":' . _jstr($content) . '}';
    }

    my @param_json;
    for my $k (sort { $a cmp $b } CORE::keys %$params) {
        my $v = defined $params->{$k} ? $params->{$k} : '';
        push @param_json, _jstr($k) . ':' . _jstr($v);
    }

    my $json = '{'
        . '"provider":' . _jstr($provider) . ','
        . '"model":' . _jstr($model) . ','
        . '"system":' . _jstr($system) . ','
        . '"messages":[' . join(',', @msg_json) . '],'
        . '"params":{' . join(',', @param_json) . '}'
        . '}';

    my $bytes = Encode::encode('UTF-8', $json);
    return Digest::SHA::sha256_hex($bytes);
}

# Minimal, exact JSON string encoder for the canonical form above: escapes
# only '"', '\' and control characters below 0x20 (always as \uXXXX, never
# the \n/\t/... short forms), and leaves everything else, including
# non-ASCII characters, untouched.
sub _jstr {
    my ($s) = @_;
    $s = '' unless defined $s;
    my $out = '"';
    for my $ch (split //, $s) {
        my $cp = ord($ch);
        if ($ch eq '"') { $out .= '\\"'; }
        elsif ($ch eq '\\') { $out .= '\\\\'; }
        elsif ($cp < 0x20) { $out .= sprintf('\\u%04x', $cp); }
        else { $out .= $ch; }
    }
    $out .= '"';
    return $out;
}

=head2 get_or_call(%request_and_call)

Same keys as C<cache_key> above (C<provider>, C<model>, C<system>, C<messages>,
C<params>), plus:

=over 4

=item call (required)

A coderef invoked with no arguments only on a cache miss. It may return a
plain scalar (the response text) or a hashref
C<{ response, model, input_tokens, output_tokens, cached_tokens,
cache_write_5m_tokens, cache_write_1h_tokens, cost_usd, latency_ms,
error }>; only C<response> is required. C<input_tokens>, C<output_tokens>,
C<cached_tokens>, C<cost_usd>, C<latency_ms> and C<error> feed
C<stats_bucket> recording when configured (see C<< $client->llmstats->record >>).
When C<model> is also given, a L<HotKV::TokenUsage> is built from these
same fields (C<cached_tokens> becomes its C<cache_read_tokens>) and stored
with the cache entry, so a later hit attributes it, and its cost once the
model is priced, through C<stats>'s C<usage_saved_*> counters; it is also
passed to C<llmstats->record> so the recorded cost is priced from the
C<LLMSTATS.PRICE> table instead of C<cost_usd>.

=item ttl

Optional seconds, forwarded to C<PCACHE.SET>.

=item meta

Optional JSON string, forwarded to C<PCACHE.SET>.

=back

Returns C<{ response, cached, cache_key }> (C<cached> is 1 on a hit, 0 on a
miss).

=cut

sub get_or_call {
    my ($self, %args) = @_;
    my $fn   = delete $args{call};
    my $ttl  = delete $args{ttl};
    my $meta = delete $args{meta};
    die "hotkv: get_or_call needs call => sub { ... }\n" unless ref $fn eq 'CODE';

    my $key    = $self->cache_key(%args);
    my $cached = $self->{client}->pcache->get($self->{ns}, $key);
    if (defined $cached) {
        return { response => $cached, cached => 1, cache_key => $key };
    }

    my $t0     = Time::HiRes::time();
    my $result = $fn->();
    my $elapsed_ms = int((Time::HiRes::time() - $t0) * 1000 + 0.5);

    my ($response, $fields);
    if (ref($result) eq 'HASH' && exists $result->{response}) {
        $response = $result->{response};
        $fields   = $result;
    }
    else {
        $response = $result;
        $fields   = {};
    }

    my $token_usage;
    if (defined $fields->{model}) {
        $token_usage = HotKV::TokenUsage->new(
            model                 => $fields->{model},
            input_tokens          => $fields->{input_tokens}          // 0,
            output_tokens         => $fields->{output_tokens}         // 0,
            cache_read_tokens     => $fields->{cached_tokens}         // 0,
            cache_write_5m_tokens => $fields->{cache_write_5m_tokens} // 0,
            cache_write_1h_tokens => $fields->{cache_write_1h_tokens} // 0,
        );
    }

    my %set_opts;
    $set_opts{ttl}   = $ttl         if defined $ttl;
    $set_opts{meta}  = $meta        if defined $meta;
    $set_opts{usage} = $token_usage if $token_usage;
    $self->{client}->pcache->set($self->{ns}, $key, $response, \%set_opts);

    if ($self->{stats_bucket}) {
        my $ok = eval {
            my %record_opts;
            $record_opts{error}                 = $fields->{error} if defined $fields->{error};
            $record_opts{model}                 = $fields->{model} if defined $fields->{model};
            $record_opts{cache_write_5m_tokens}  = $fields->{cache_write_5m_tokens}
                if defined $fields->{cache_write_5m_tokens};
            $record_opts{cache_write_1h_tokens}  = $fields->{cache_write_1h_tokens}
                if defined $fields->{cache_write_1h_tokens};
            $self->{client}->llmstats->record(
                $self->{stats_bucket},
                $fields->{input_tokens}  // 0,
                $fields->{output_tokens} // 0,
                $fields->{cached_tokens} // 0,
                (defined $fields->{model} ? 0 : $fields->{cost_usd} // 0),
                (defined $fields->{latency_ms} ? $fields->{latency_ms} : $elapsed_ms),
                \%record_opts,
            );
            1;
        };
        if (!$ok) {
            my $err = $@;
            die $err unless blessed($err) && $err->isa('HotKV::Error::Server::NotLicensed');
        }
    }

    return { response => $response, cached => 0, cache_key => $key };
}

1;
