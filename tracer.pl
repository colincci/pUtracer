#!/usr/bin/env perl
# vim: foldmethod=marker ts=4 sw=2 commentstring=\ #\ %s
$| = 1;                    # Force flush stdout.
use strict;
use v5.10;
use warnings;
use Getopt::Long;
use Data::Dumper;
use Pod::Usage;
#use Device::SerialPort;
use List::Util qw(max first);
use POSIX qw(strftime);
my $VERSION = "0.0.1";
use Carp::Always;
use Config::General;
use File::Slurp;
use File::Basename;
use lib dirname(__FILE__);
use uTracerConstants;
use uTracerComs;
use uTracerMeasure;
use TubeDatabase;

#########--Set some global variables
use vars qw { $Debug $ConfigFile };
$Debug      = 0;           # default to no debugging
$ConfigFile = 'app.ini';

#####################################
# BEGIN SUBROUTINES
#####################################

## sub get_commandline()
#
#  purpose:  process the current command line arguments
#  expects:  nothing
#  returns:  nothing - sets the global variables according to the command line arguments
#
##
sub get_commandline {
    my $cfg    = Config::General->new("app.ini");
    my %config = $cfg->getall();
    
    my $opts  = $config{options};
    $opts->{'cal'} = get_cal();
    
    my $tubes = $config{tubes};

    $opts->{preset} = sub {
            $_[1]                = lc $_[1];
            $opts->{preset_name} = $_[1];
            $_[1]                = "$_[1]-quick" if ( !exists $tubes->{ $_[1] } );
            if ( exists $tubes->{ $_[1] } ) {
                map { $opts->{$_} ||= $tubes->{ $_[1] }->{$_} } keys %{ $tubes->{ $_[1] } };
            } else {
                die "Don't know tube type $_[1].  Specify vf, vg, va, vs on the command line.";
            }
        };


	
	my @usage = (
		"configfile=s",                         # Path to the config file, defaults to app.ini in the current directory
		"log=s",                                # Path to the log file

		"hot!",                                 # expect filiments to be hot already
		"warm!",                                # leave filiments on or not
		"debug",                                # protocol-level debugging
		"verbose",                              # print measurement requests, and responses.
		"device=s",                             # serial device
		"preset=s",                             # preset trace settings
		"name=s",                               # name to put in log
		"tube=s",                               # tube type
		"interactive!",                         # prompt to store current quicktest entry in the database
		"store",                                # automatically store the current quicktest in the database
		"vg=s", "va=s", "vs=s", "rp=f", "ia=f", # measurement value override
		"gm=f", "mu=f", "vf=s",                 # measurement value override
		"compliance=i",                         # miliamps
		"settle=i",                             # settle delay after slow heating tube
		"averaging=i",                          # averaging
		"gain=i",                               # gain
		"correction!",                          # low voltage correction
		"quicktest|quicktest-triode|qtt",       # do quicktest of triodes to a log file, rather than a sweep.
		"quicktest-pentode|qtp",                # do quicktest of pentodes to a log file, rather than a sweep.
		"offset=i",                             # quicktest offset percentage
		"calm=i",                               # delay this long before the next command after a "end measurement"
	);

	GetOptions( $opts, @usage ) || pod2usage(2);

	$Getopt::Long::autoabbrev = 1;
    $Getopt::Long::bundling   = 1;
    
	# Copy in tube name from preset, if not specified on the command line.
	$opts->{tube} ||= $opts->{preset_name};
	return $opts;

}

#===========
# Begin Subs
#===========

####################################
# Main
####################################


initdb();
my $opts = get_commandline();

my $tracer = init_utracer($opts);


# append log, no overwrite
open( my $log, ">>", $opts->{log} );

# turn args into measurement steps.
# This takes start-end/steps(logarithm) and makes it a list of values for each.
# ... Yes it supports fil voltage.
foreach my $arg (qw(vg va vs vf)) {    # {{{
	my ( $range, $steps ) = split( m/\//, $opts->{$arg}, 2 );
	my ($log_mode) = 0;

	# steps may not exist, default to 0
	$steps = defined($steps) ? $steps : 0;

	if ( rindex( $steps, "l" ) + 1 == length($steps) ) {
		$log_mode++;
		chop $steps;
	}

	my ( $range_start, $range_end ) = ( $range =~ m/(-?[\d\.]+)(?:-(-??[\d\.]+))?/ );

	# range end may not exist, default to range start.
	$range_end = defined($range_end) ? $range_end : $range_start;

	my $sweep_width = $range_end - $range_start;
	my $step_size = $steps == 0 ? 0 : $sweep_width / $steps;

	# overwrite argument in $opts
	$opts->{$arg} = [];

	# add our stuff in.
	if ( !$log_mode ) {
		push @{ $opts->{$arg} }, $range_start + $step_size * $_ for ( 0 .. $steps );
	} else {
		push @{ $opts->{$arg} }, $range_start;
		push @{ $opts->{$arg} }, ( $sweep_width**( $_ * ( 1 / $steps ) ) ) + $range_start for ( 0 .. $steps );
	}
}    # }}}

# rough guess as to what the system supply is supposed to be
my $VsupSystem = 19.5;

# "main"
if ( !( $opts->{quicktest} || $opts->{"quicktest-pentode"} ) ) {
	do_curve( $tracer, $opts, $log );
} elsif ( $opts->{quicktest} ) {
	quicktest_triode( $tracer, $opts, $log );
} elsif ( $opts->{"quicktest-pentode"} ) {
	quicktest_pentode( $tracer, $opts, $log);
} else {
	die "lolwat";
}

$log->close();
##END MAIN


__END__

=head1 NAME

puTracer - command line quick test

=head1 SYNOPSIS

tracer.pl [options] --tube 12AU7

    Options:
        --hot                             # expect filiments to be hot already
        --warm                            # leave filiments on or not
        --debug                           # protocol-level debugging
        --interactive                     # prompt to store current quicktest in the database
        --store                           # automatically store the current quicktest in the database  
        --verbose                         # print measurement requests, and responses.
        --device=s                        # serial device
        --preset=s                        # preset trace settings
        --name=s                          # name to put in log
        --tube=s                          # tube type
        --vg=sva=svs=srp=fia=fgm=fmu=fvf=s # measurement value override
        --compliance=i                    # miliamps 
        --settle=i                        # settle delay after slow heating tube 
        --averaging=i                     # averaging 
        --gain=i                          # gain 
        --correction!                     # low voltage correction
        --log=s                           # path to the logfile
        --quicktest|quicktest-triode|qtt  # do quicktest of triodes to a log file, rather than a sweep.
        --quicktest-pentode|qtp           # do quicktest of pentodes to a log file, rather than a sweep.
        --offset=i                        # quicktest offset percentage
        --calm=i                          # delay this long before the next command after a end measurement

