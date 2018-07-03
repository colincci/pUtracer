package uTracerComs;

use strict;
use warnings;

use Exporter qw( import );
use Const::Fast;
use Config::General;
use File::Slurp;
use uTracerConstants;

our @EXPORT    = qw( 
    warmup_tube
    end_measurement
    set_filament
    ping
    send_settings
    do_measurement
    reset_tracer
    abort
  );
  
sub warmup_tube {
  my $opts = shift;

	if ( $opts->{hot} ) {    # {{{
		# "hot" mode - just set it to max
		set_filament( getVf( $opts->{vf}->[-1] ) );
	} else {

		# cold mode - ramp it up slowly
		printf STDERR "Tube heating..\n";
		foreach my $mult ( 1 .. 10 ) {
			my $voltage = $mult * ( $opts->{vf}->[-1] / 10 );
			printf STDERR "Setting fil voltage to %2.1f\n", $voltage if ( $opts->{verbose} );
			set_filament( getVf($voltage) );
			sleep 1;
		}
	}    # }}}

	if ( !$opts->{hot} ) {    # {{{
		printf "Sleeping for %d seconds for tube settle ...\n", $opts->{settle} if ( $opts->{verbose} );
		sleep $opts->{settle};
	}    # }}}
	printf STDERR "Tube heated.\n";
}

sub end_measurement {    # {{{
  my $opts = shift;
	my (%args) = @_;
	my $string = sprintf( "%02X00000000%02X%02X%02X%02X", $CMD_END, 0, 0, 0, 0 );
	print "> $string\n" if ( $opts->{debug} );
	$tracer->write($string);
	my ( $bytes, $response ) = $tracer->read(18);
	print "< $response\n" if ( $opts->{debug} );
	if ( $response ne $string ) { warn "uTracer returned $response, when I expected $string"; }
}    # }}}


sub set_filament {    # {{{
  my $opts = shift;
	my ($voltage) = @_;
	my $string = sprintf( "%02X000000000000%04X", $CMD_FILAMENT, $voltage );
	print "> $string\n" if ( $opts->{debug} );
	$tracer->write($string);
	my ( $bytes, $response ) = $tracer->read(18);
	print "< $response\n" if ( $opts->{debug} );
	if ( $response ne $string ) { warn "uTracer returned $response, when I expected $string"; }
}    # }}}


sub ping {    # {{{
  my $opts = shift;
	my $string = sprintf( "%02X00000000%02X%02X%02X%02X", $CMD_PING, 0, 0, 0, 0 );
	print "> $string\n" if ( $opts->{debug} );
	$tracer->write($string);
	my ( $bytes, $response ) = $tracer->read(18);
	print "< $response\n" if ( $opts->{debug} );
	if ( $response ne $string ) { warn "uTracer returned $response, when I expected $string"; }
	( $bytes, $response ) = $tracer->read(38);
	print "< $response\n" if ( $opts->{debug} );
	my $data = decode_measurement($response);
	@{$data}{qw(Va Vs Vg Vf)} = ( 0, 0, 0, 0 );
	return $data;
}    # }}}


sub send_settings {    # {{{
  my $opts = shift;
	my (%args) = @_;
	my $string = sprintf("%02X00000000%02X%02X%02X%02X",$CMD_START,$compliance_to_tracer{ $args{compliance} },$averaging_to_tracer{ $args{averaging} } || 0,$gain_to_tracer{ $args{gain_is} }        || 0,$gain_to_tracer{ $args{gain_ia} }        || 0,);
	print "> $string\n" if ( $opts->{debug} );
	$tracer->write($string);
	my ( $bytes, $response ) = $tracer->read(18);
	print "< $response\n" if ( $opts->{debug} );
	if ( $response ne $string ) { warn "uTracer returned $response, when I expected $string"; }
}    # }}}


sub do_measurement {    # {{{
  my $opts = shift;
	my (%args) = @_;
	my $string = sprintf("%02X%04X%04X%04X%04X",$CMD_MEASURE,getVa( $args{va} ),getVs( $args{vs} ),getVg( $args{vg} ),getVf( $args{vf} ),);
	print "> $string\n" if ( $opts->{debug} );
	$tracer->write($string);
	my ( $bytes, $response ) = $tracer->read(18);
	print "< $response\n" if ( $opts->{debug} );
	if ( $response ne $string ) { warn "uTracer returned $response, when I expected $string"; }
	( $bytes, $response ) = $tracer->read(38);
	print "< $response\n" if ( $opts->{debug} );
	my $data = decode_measurement($response);
	@{$data}{qw(Va Vs Vg Vf)} = @args{qw(va vs vg vf)};
	return $data;
}    # }}}

# send an escape character, to reset the input buffer of the uTracer.
# This unfortunately, does not actually *reset* the uTracer.
sub reset_tracer {
	$tracer->write("\x1b");
}

sub abort {
  my $opts = shift;
	print "Aborting!\n";

	#reset_tracer();
	end_measurement($opts);
	set_filament($opts,0);
	die "uTracer reports compliance error, current draw is too high.  Test aborted";
}

__PACKAGE__;

__END__
