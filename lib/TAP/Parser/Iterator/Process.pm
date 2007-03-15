package TAP::Parser::Iterator::Process;

use strict;
use TAP::Parser::Iterator;
use vars qw($VERSION @ISA);
@ISA = 'TAP::Parser::Iterator';

use IPC::Open3;
use IO::Select;
use IO::Handle;

use constant IS_WIN32 => ( $^O =~ /^(MS)?Win32$/ );
use constant IS_MACOS => ( $^O eq 'MacOS' );
use constant IS_VMS   => ( $^O eq 'VMS' );

=head1 NAME

TAP::Parser::Iterator::Process - Internal TAP::Parser Iterator

=head1 VERSION

Version 0.52

=cut

$VERSION = '0.52';

=head1 SYNOPSIS

  use TAP::Parser::Iterator;
  my $it = TAP::Parser::Iterator::Process->new(@args);

  my $line = $it->next;

Originally ripped off from C<Test::Harness>.

=head1 DESCRIPTION

B<FOR INTERNAL USE ONLY!>

This is a simple iterator wrapper for processes.

=head2 new()

Create an iterator.

=head2 next()

Iterate through it, of course.

=head2 next_raw()

Iterate raw input without applying any fixes for quirky input syntax.

=head2 wait()

Get the wait status for this iterator's process.

=head2 exit()

Get the exit status for this iterator's process.

=cut

eval { require POSIX; &POSIX::WEXITSTATUS(0) };
if ($@) {
    *_wait2exit = sub { $_[1] >> 8 };
}
else {
    *_wait2exit = sub { POSIX::WEXITSTATUS( $_[1] ) }
}

sub new {
    my $class = shift;
    my $args  = shift;

    my @command = @{ delete $args->{command} }
      or die "Must supply a command to execute";
    my $merge = delete $args->{merge};
    my ($pid, $err, $sel);

    my $out = IO::Handle->new;

	if (IS_WIN32) {
	    eval { $pid = open3( undef, $out, $merge ? undef : '>&STDERR', @command ); };
        die "Could not execute (@command): $@" if $@;
    	binmode $out, ':crlf';
	} else {
	    $err = $merge ? undef : IO::Handle->new;
	    eval { $pid = open3( undef, $out, $err, @command ); };
        die "Could not execute (@command): $@" if $@;
	    $sel = $merge ? undef : IO::Select->new( $out, $err );
	}	

    return bless {
        out  => $out,
        err  => $err,
        sel  => $sel,
        pid  => $pid,
        exit => undef
    }, $class;
}

##############################################################################

sub wait { $_[0]->{wait} }
sub exit { $_[0]->{exit} }

sub next_raw {
    my $self = shift;

    if ( my $out = $self->{out} ) {
        # If we also have an error handle we need to do the while
        # select dance.
        if ( my $err = $self->{err} ) {
            my $sel = $self->{sel};
            my $flip = 0;

            # Loops forever while we're reading from STDERR
            while ( my @ready = $sel->can_read ) {
                # Load balancing :)
                @ready = reverse @ready if $flip;
                $flip = !$flip;
                
                for my $fh (@ready) {
                    if ( defined( my $line = <$fh> ) ) {
                        if ( $fh == $err ) {
                            warn $line;
                        }
                        else {
                            chomp $line;
                            return $line;
                        }
                    }
                    else {
                        $sel->remove($fh);
                    }
                }
            }
        }
        else {

            # Only one handle: just a simple read
            if ( defined( my $line = <$out> ) ) {
                chomp $line;
                return $line;
            }
        }
    }

    # We only get here when the stream(s) is/are exhausted
    $self->_finish;

    return;
}

sub next {
    my $self = shift;
    my $line = $self->next_raw;

    # vms nit:  When encountering 'not ok', vms often has the 'not' on a line
    # by itself:
    #   not
    #   ok 1 - 'I hate VMS'
    if ( defined $line && $line =~ /^\s*not\s*$/ ) {
        $line .= ( $self->next_raw || '' );
    }
    return $line;
}

sub _finish {
    my $self = shift;

    my $status = $?;

    # If we have a subprocess we need to wait for it to terminate
    if ( defined $self->{pid} ) {
        if ( $self->{pid} == waitpid( $self->{pid}, 0 ) ) {
            $status = $?;
        }
    }

    (delete $self->{out})->close if $self->{out};
    (delete $self->{err})->close if $self->{err};
    delete $self->{sel} if $self->{sel};

    $self->{wait} = $status;
    $self->{exit} = $self->_wait2exit($status);
    
    return $self;
}

1;
