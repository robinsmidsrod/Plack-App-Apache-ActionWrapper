#!/usr/bin/perl

# ABSTRACT: Wrapper for Apache2 Action directive for running PSGI apps on shared hosting with FastCGI

package Plack::App::Apache::ActionWrapper;

use strict;
use warnings;

use parent qw/Plack::Middleware/;

sub call {
    my ($self, $env) = @_;
    my $app_filename = $self->_resolve_app_filename($env);
    my $app = $self->_get_app($app_filename);
    $app ||= sub {
        my ( $my_env ) = shift;
        return [
            500,
            [ 'Content-Type' => 'text/plain' ],
            [
              "No .psgi file found in PATH_TRANSLATED.\n",
              "You probably forgot to add the following lines to .htaccess:\n",
              "    Action psgi-handler /path/to/psgi.fcgi\n",
              "    AddHandler psgi-handler .psgi\n",
              $self->_get_debug_info($my_env),
            ],
        ];
    };
    return $app->($env);
}

sub enable_debug {
    my ($self) = @_;
    $self->{'debug'} = 1;
    return $self;
}

sub disable_debug {
    my ($self) = @_;
    delete $self->{'debug'};
    return $self;
}

sub is_debug_enabled {
    my ($self) = @_;
    return $self->{'debug'} ? 1 : 0;
}

sub _resolve_app_filename {
    my ($self, $env) = @_;

    my $path_translated = $env->{'PATH_TRANSLATED'} || "";

    # Figure out which part of the path is actually the psgi file
    my @path_parts = split(m{/}, $path_translated);
    while ( ! -r join("/", @path_parts) ) {
        last if @path_parts == 0; # Break out if we're at the end
        pop @path_parts;
    }

    # Return undef (that is, no app) if no path part was a readable file
    return if @path_parts == 0;

    # Execute the contents of the file and return last variable defined in it
    my $psgi_file = join("/", @path_parts );

    # Cache the app to allow persistent running
    return $psgi_file;
}

sub _get_app {
    my ($self, $app_filename) = @_;
    # No string specified, cannot possibly be any app available
    return unless $app_filename;

    # Initialize code/mtime cache if they are not present
    $self->{'code_cache'} = {} unless exists $self->{'code_cache'};
    $self->{'mtime_cache'} = {} unless exists $self->{'mtime_cache'};

    # Fetch current mtime for $app_filename, for checking if it has been changed
    my $mtime_current = (stat($app_filename))[9];

    # App has never been loaded, do initial loading
    unless ( $self->{'code_cache'}->{$app_filename} ) {
        $self->{'code_cache'}->{$app_filename} = do $app_filename;
        $self->{'mtime_cache'}->{$app_filename} = $mtime_current;
    }

    # App on disk is newer than cached version, reload
    if ( $mtime_current > $self->{'mtime_cache'}->{$app_filename} ) {
        $self->{'code_cache'}->{$app_filename} = do $app_filename;
        $self->{'mtime_cache'}->{$app_filename} = $mtime_current;
    }

    # Return cached app
    return $self->{'code_cache'}->{$app_filename};        
}

sub _get_debug_info {
    my ($self, $env) = @_;

    # Don't return debug info unless it has been enabled
    return unless $self->is_debug_enabled();

    my @body = ( "\n", "Debug:\n" );

    # Real and effective UID
    push @body, "UID: " . $< . "\n"; # $UID
    push @body, "EUID: " . $> . "\n"; # $EUID

    # Environment variables
    foreach my $key ( sort keys %{ $env } ) {
        push @body, $key . ' = ' . $env->{$key} . "\n";
    }

    # Returned collected data
    return @body;
}

1;
