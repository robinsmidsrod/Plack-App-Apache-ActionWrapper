#!/usr/bin/perl

use strict;
use warnings;

package Plack::App::Apache::ActionWrapper;
use base 'Plack::Component';
use File::Spec;

# ABSTRACT: Wrapper for Apache2 Action directive for running PSGI apps on shared hosting with FastCGI

=method call

The main handler that will be returned by the C<to_app> method inherited from L<Plack::Component>.

=cut

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

=method enable_debug

Mutator to enable debug output if no path was found in PATH_TRANSLATED. Allows chaining.

=cut

sub enable_debug {
    my ($self) = @_;
    $self->{'debug'} = 1;
    return $self;
}

=method disable_debug

Mutator to disable debug output if no path was found in PATH_TRANSLATED. Allows chaining.

=cut

sub disable_debug {
    my ($self) = @_;
    delete $self->{'debug'};
    return $self;
}

=method is_debug_enabled

Accessor to determine if debug is enabled or not. Debug is disabled by default.

=cut

sub is_debug_enabled {
    my ($self) = @_;
    return $self->{'debug'} ? 1 : 0;
}

sub _resolve_app_filename {
    my ($self, $env) = @_;

    my $path_translated = $env->{'PATH_TRANSLATED'} || "";

    # Split path into filesystem parts according to OS specific separator
    my ($vol, $pt_dir) = File::Spec->splitpath($path_translated);
    my @path_parts = File::Spec->splitdir($pt_dir);

    # Figure out which part of the path is actually the psgi file
    while ( not -r $path_translated and @path_parts ) {
        my $f = pop @path_parts;
        $path_translated = File::Spec->catpath(
            $vol, File::Spec->catdir(@path_parts), $f
        );
    }
    return -r $path_translated && $path_translated;
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

__END__

=head1 SYNOPSIS

    ------------- .htaccess -----------------
    AddHandler fcgid-script .fcgi
    # Enable this instead if server is using mod_fastcgi instead of mod_fcgid
    #AddHandler fastcgi-script .fcgi
    Action psgi-script /cgi-bin/psgi.fcgi
    AddHandler psgi-script .psgi

    DirectoryIndex index.psgi

    RewriteEngine On
    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteRule ^(.*)$ index.psgi/$1 [QSA,L]

    ------------- psgi.fcgi -----------------
    #!/usr/bin/env perl

    use strict;
    use warnings;

    # Change this line if you use local::lib or need
    # specific libraries loaded for your application
    use lib '/home/robin/perl5/lib/perl5';

    use Plack::App::Apache::ActionWrapper;
    my $app = Plack::App::Apache::ActionWrapper->new->enable_debug->to_app;

    # Run the actual app
    use Plack::Handler::FCGI;
    Plack::Handler::FCGI->new->run($app);

    1;

    ------------- index.psgi -----------------
    #!/usr/bin/env plackup

    use strict;
    use warnings;

    my $app = sub {
        my $env = shift;
        return [
            200,
            [ 'Content-Type' => 'text/plain' ],
            [
                "This is the index.\n",
                'PATH_INFO=' . $env->{'PATH_INFO'} . "\n",
                'PATH_TRANSLATED=' . $env->{'PATH_TRANSLATED'} . "\n",
            ],
        ];
    };

=head1 DESCRIPTION

The PSGI web application specification is awesome. Plack is awesome as well.
Running PSGI apps using plackup in development is super easy.

But what do you do when you want to deploy your PSGI app on shared hosting?
You can deploy it using traditional CGI, but if you're dealing with
something like Moose or Catalyst-based apps it's bound to be slow.

So your shared hosting provider has provided you with FastCGI support to
mitigate that problem. But because FastCGIExternalServer cannot be defined
in .htaccess you can only run dynamic FastCGI applications.

Your immediate reaction is to define C<AddHandler fcgid-script .psgi> in your
.htaccess and use plackup on the shebang line to run your PSGI app. But that
doesn't work if you use local::lib, because @INC is not setup properly.

By using a wrapper as specified in the synopsis you can avoid having to type
in C<use lib 'XXX'> in every one of your .psgi files. Another benefit is
that you can preload modules to benefit from copy-on-write on operating
systems that provide it to diminish the memory usage.
