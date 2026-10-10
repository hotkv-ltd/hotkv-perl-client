# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Prompt;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Prompt - PROMPT.* versioned prompt/template registry

Needs a server license that includes the C<prompt-registry> feature.
Reachable as C<< $client->prompt >>.

=head2 put($name, $content, \%opts)

C<PROMPT.PUT name content [META json]> -> integer, the new version number
(versions start at 1 and increment).

=head2 get($name, $version = latest)

C<PROMPT.GET name [version]> -> arrayref C<[version, content, metadata,
created_unix]>, or C<undef>. Omit C<$version> (or pass 0) for the latest.

=head2 latest($name)

C<PROMPT.LATEST name> -> same shape as C<get> above.

=head2 setactive($name, $version)

C<PROMPT.SETACTIVE name version> -> C<OK>.

=head2 versions($name)

C<PROMPT.VERSIONS name> -> arrayref of integers.

=head2 drop($name)

C<PROMPT.DROP name> -> 1/0.

=head2 list

C<PROMPT.LIST> -> arrayref of names.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub put {
    my ($self, $name, $content, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('PROMPT.PUT', $name, $content);
    push @args, 'META', $opts->{meta} if defined $opts->{meta};
    return $self->{ex}->_call(@args);
}

sub get {
    my ($self, $name, $version) = @_;
    my @args = ('PROMPT.GET', $name);
    push @args, $version if defined $version;
    return $self->{ex}->_call(@args);
}

sub latest     { my ($self, $name) = @_; return $self->{ex}->_call('PROMPT.LATEST', $name); }
sub setactive  { my ($self, $name, $version) = @_; return $self->{ex}->_call('PROMPT.SETACTIVE', $name, $version); }
sub versions   { my ($self, $name) = @_; return $self->{ex}->_call('PROMPT.VERSIONS', $name); }
sub drop       { my ($self, $name) = @_; return $self->{ex}->_call('PROMPT.DROP', $name); }
sub list       { my ($self) = @_; return $self->{ex}->_call('PROMPT.LIST'); }

1;
