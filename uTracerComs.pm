package uTracerComs;

use strict;
use warnings;
use v5.10;

use Exporter qw( import );
use Const::Fast;
use Config::General;
use File::Slurp;
use Device::SerialPort;
use uTracerConstants;

our @EXPORT    = qw( 
		init_utracer
    warmup_tube
    end_measurement
    set_filament
    ping
    send_settings
    do_measurement
    reset_tracer
    abort
		decode_measurement
  );

sub init_utracer {
	my $opts = shift;
	# connect to uTracer
	my $comport = $opts->{device};
	say "Connecting to dev:'$comport'";
	my $tracer = Device::SerialPort->new($comport) || die "Can't open $comport: $!\n";
	$tracer->baudrate(9600);
	$tracer->parity("none");
	$tracer->databits(8);
	$tracer->stopbits(1);

  # wait this long for reads to timeout.  This is in miliseconds.
  # this is stupid high so that I can simulate the uTracer with another terminal by hand.
  $tracer->read_const_time(10_000);

  return $tracer;
}

 sub warmup_tube {
	 my $tracer = shift;
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
			set_filament( $tracer, $opts, getVf($voltage) );
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
	my $tracer = shift;
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
	my $tracer = shift;
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
	my $tracer = shift;
  my $opts = shift;
	my $string = sprintf( "%02X00000000%02X%02X%02X%02X", $CMD_PING, 0, 0, 0, 0 );
	print "> $string\n" if ( $opts->{debug} );
	$tracer->write($string);
	my ( $bytes, $response ) = $tracer->read(18);
	print "< $response\n" if ( $opts->{debug} );
	if ( $response ne $string ) { warn "uTracer returned $response, when I expected $string"; }
	( $bytes, $response ) = $tracer->read(38);
	print "< $response\n" if ( $opts->{debug} );
	my $data = decode_measurement($opts, $response);

	@{$data}{qw(Va Vs Vg Vf)} = ( 0, 0, 0, 0 );
	return $data;
}    # }}}


sub send_settings {    # {{{
	my $tracer = shift;
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
	my $tracer = shift;
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
	my $tracer = shift;
	$tracer->write("\x1b");
}

sub abort {
	my $tracer = shift;
  my $opts = shift;
	print "Aborting!\n";

	#reset_tracer();
	end_measurement($tracer,$opts);
	set_filament($tracer,$opts,0);
	die "uTracer reports compliance error, current draw is too high.  Test aborted";
}

sub decode_measurement {    # {{{
	my $opts = shift;
	my ($str) = @_;
	$str =~ s/ //g;
	my $data = {};
	@{$data}{@measurement_fields} = map { hex($_) } unpack( "A2 A4 A4 A4 A4 A4 A4 A4 A4 A2 A2", $str );

	# status byte = 10 - all good.
	# status byte = 11 - compliance error
	if ( $data->{Status} == 0x11 ) {
		warn "uTracer reports overcurrent!";
		abort();
	}

	$data->{Vpsu} *= $DECODE_TRACER * $SCALE_VSU * $cal->{CalVar5};

	# update PSU voltage global
	$VsupSystem = $data->{Vpsu};

	$data->{Va_Meas} *= $DECODE_TRACER * $DECODE_SCALE_VA;    # * CalVar1;
	# Va is in reference to PSU, adjust
	$data->{Va_Meas} -= $data->{Vpsu};

	$data->{Vs_Meas} *= $DECODE_TRACER * $DECODE_SCALE_VS;    # * CalVar2;
	# Vs is in reference to PSU, adjust
	$data->{Vs_Meas} -= $data->{Vpsu};

	$data->{Ia} *= $DECODE_TRACER * $DECODE_SCALE_IA * $cal->{CalVar3};
	$data->{Is} *= $DECODE_TRACER * $DECODE_SCALE_IS * $cal->{CalVar4};

	$data->{Ia_Raw} *= $DECODE_TRACER * $DECODE_SCALE_IA * $cal->{CalVar3};
	$data->{Is_Raw} *= $DECODE_TRACER * $DECODE_SCALE_IS * $cal->{CalVar4};

	$data->{Vmin} = 5 * ( ( $VminR1 + $VminR2 ) / $VminR1 ) * ( ( $data->{Vmin} / 1024 ) - 1 );
	$data->{Vmin} += 5;

	# decode gain
	@{$data}{qw(Gain_Ia Gain_Is)} = map { $gain_from_tracer{$_} } @{$data}{qw(Gain_Ia Gain_Is)};

	# undo gain amplification
	# XXX NOTE: the uTracer can and will use different PGA gains for Ia and Is!
	$data->{Ia} = $data->{Ia} / $data->{Gain_Ia};
	$data->{Is} = $data->{Is} / $data->{Gain_Is};

	# average
	# XXX NOTE: the uTracer can and will use different PGA gains for Ia and Is!  Averaging is global though.
	my $averaging =
	    $gain_to_average{ $data->{Gain_Ia} } > $gain_to_average{ $data->{Gain_Is} }
	  ? $gain_to_average{ $data->{Gain_Ia} }
	  : $gain_to_average{ $data->{Gain_Is} };
	$data->{Ia} /= $averaging;
	$data->{Is} /= $averaging;

	if ( $opts->{correction} ) {
		$data->{Va_Meas} = $data->{Va_Meas} - ( ( $data->{Ia} ) / 1000 ) * $AnodeRs -  ( 0.6 * $cal->{CalVar7} );
		$data->{Vs_Meas} = $data->{Vs_Meas} - ( ( $data->{Is} ) / 1000 ) * $ScreenRs - ( 0.6 * $cal->{CalVar7} );
	}

	if ( $opts->{verbose} ) {
		printf "\nstat ____ia iacmp ____is _is_comp ____va ____vs _vPSU _vneg ia_gain is_gain\n";
		printf "% 4x % 6.1f % 5.1f % 6.1f % 8.1f % 6.1f % 6.1f % 2.1f % 2.1f % 7d % 7d\n", @{$data}{@measurement_fields};
	}

	return $data;
}    # }}}


__PACKAGE__;

__END__
