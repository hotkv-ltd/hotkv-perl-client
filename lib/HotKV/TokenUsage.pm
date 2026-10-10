# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::TokenUsage;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::TokenUsage - One model call's token usage (the shared usage group)

=head1 SYNOPSIS

  my $usage = HotKV::TokenUsage->new(
      model         => 'claude-sonnet-5',
      input_tokens  => 120,
      output_tokens => 40,
  );
  $kv->pcache->set($ns, $prompt, $response, { usage => $usage });

=head1 DESCRIPTION

The token usage group shared by C<PCACHE.SET>, C<SCACHE.SET>, every keyed
cache C<SET> (C<TOOL.CACHE>/C<NCACHE>/C<GUARD>/C<RERANK>) and
C<LLMBUDGET.CONSUME>. Recording a C<HotKV::TokenUsage> with a cache entry
lets a later cache hit attribute its tokens, and once the model is priced
its exact cost, to the namespace's C<usage_saved_*> stats fields.

C<model> is required; every count defaults to 0 and is left off the wire
when zero (C<MODEL> itself is always sent once a C<HotKV::TokenUsage> is
given).

=head1 METHODS

=head2 new(%fields)

C<model> (required), C<input_tokens>, C<output_tokens>,
C<cache_read_tokens>, C<cache_write_5m_tokens>, C<cache_write_1h_tokens>
(all optional, default 0).

=cut

sub new {
    my ($class, %args) = @_;
    die "hotkv: HotKV::TokenUsage needs model => ...\n" unless defined $args{model} && length $args{model};
    return bless {
        model                 => $args{model},
        input_tokens          => $args{input_tokens}          || 0,
        output_tokens         => $args{output_tokens}         || 0,
        cache_read_tokens     => $args{cache_read_tokens}     || 0,
        cache_write_5m_tokens => $args{cache_write_5m_tokens} || 0,
        cache_write_1h_tokens => $args{cache_write_1h_tokens} || 0,
    }, $class;
}

=head2 model / input_tokens / output_tokens / cache_read_tokens / cache_write_5m_tokens / cache_write_1h_tokens

Plain accessors.

=cut

sub model                 { return $_[0]->{model}; }
sub input_tokens          { return $_[0]->{input_tokens}; }
sub output_tokens         { return $_[0]->{output_tokens}; }
sub cache_read_tokens     { return $_[0]->{cache_read_tokens}; }
sub cache_write_5m_tokens { return $_[0]->{cache_write_5m_tokens}; }
sub cache_write_1h_tokens { return $_[0]->{cache_write_1h_tokens}; }

=head2 wire_args

Returns the C<MODEL model [INPUT n] [OUTPUT n] [CACHEREAD n] [CACHEWRITE5M
n] [CACHEWRITE1H n]> list this usage adds to a command's trailing options
(a plain list, ready to C<push> onto an argument array). A zero count is
left off the wire; C<MODEL> is always included.

=cut

sub wire_args {
    my ($self) = @_;
    my @args = ('MODEL', $self->{model});
    push @args, 'INPUT', $self->{input_tokens} if $self->{input_tokens};
    push @args, 'OUTPUT', $self->{output_tokens} if $self->{output_tokens};
    push @args, 'CACHEREAD', $self->{cache_read_tokens} if $self->{cache_read_tokens};
    push @args, 'CACHEWRITE5M', $self->{cache_write_5m_tokens} if $self->{cache_write_5m_tokens};
    push @args, 'CACHEWRITE1H', $self->{cache_write_1h_tokens} if $self->{cache_write_1h_tokens};
    return @args;
}

1;
