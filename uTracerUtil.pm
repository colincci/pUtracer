## uTracer Utility functions

package uTracerUtil;

use strict;
use warnings;
use v5.10;
our $VERSION = "0.0.1";

use uTracerConstants;

use Exporter qw( import );

our @EXPORT    = qw( 
	decode_measurement
	getVf
	getVa
	getVs
	getVg
  );

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

sub getVa {    # {{{ # getVa is done
	my ($voltage) = @_;

	die "Voltage above 400v is not supported" if ( $voltage > 400 );
	die "Voltage below 2v is not supported"   if ( $voltage < 2 );

	# voltage is in reference to supply voltage, adjust
	$voltage += $VsupSystem;

	my $ret = $voltage * $ENCODE_TRACER * $ENCODE_SCALE_VA * $cal->{CalVar1};

	if ( $ret > 1023 ) {
		warn "Va voltage too high, clamping";
		$ret = 1023;
	}
	return $ret;

}    # }}}


sub getVs {    # {{{ # getVs is done
	my ($voltage) = @_;

	die "Voltage above 400v is not supported" if ( $voltage > 400 );
	die "Voltage below 2v is not supported"   if ( $voltage < 2 );

	# voltage is in reference to supply voltage, adjust
	$voltage += $VsupSystem;
	my $ret = $voltage * $ENCODE_TRACER * $ENCODE_SCALE_VS * $cal->{CalVar2};
	if ( $ret > 1023 ) {
		warn "Vs voltage too high, clamping";
		$ret = 1023;
	}
	return $ret;
}    # }}}

# also PWM, mapping a 0 - 5V to 0 - -50V, referenced from the system supply
sub getVg {    # {{{ # getVg is done
	my ($voltage) = @_;

	my $Vsat = 2 * ( $cal->{CalVar9} - 1 );
	my ( $X1, $Y1, $X2, $Y2 );
	if ( abs($voltage) <= 4 ) {
		$X1 = $Vsat;
		$Y1 = 0;
		$X2 = 4;
		$Y2 = $ENCODE_SCALE_VG * $cal->{CalVar8} * $cal->{CalVar6} * 4;
	} else {
		$X1 = 4;
		$Y1 = $ENCODE_SCALE_VG * $cal->{CalVar8} * $cal->{CalVar6} * 4;
		$X2 = 40;
		$Y2 = $ENCODE_SCALE_VG * $cal->{CalVar6} * 40;
	}

	my $AA  = ( $Y2 - $Y1 ) / ( $X2 - $X1 );
	my $BB  = $Y1 - $AA * $X1;
	my $ret = $AA * abs($voltage) + $BB;

	if ( $voltage > 0 ) {
		die "Positive grid voltages, from the grid terminal are not supported.  Cheat with screen/anode terminal.";
	}

	if ( $ret > 1023 ) {
		warn "Grid voltage too high, clamping to max";
		$ret = 1023;
	}

	if ( $ret < 0 ) {
		warn "Grid voltage too low, clamping to min";
		$ret = 0;
	}

	return $ret;
}    # }}}


sub getVf {    # {{{ # getVf is done
	my ($voltage) = @_;
	my $ret = 1024 * ( $voltage**2 ) / ( $VsupSystem**2 ) * $cal->{CalVar5};
	if ( $ret > 1023 ) {
		warn sprintf( "Requested filament voltage %f > 100%% PWM duty cycle, clamping to 100%%, %f.", $voltage, $VsupSystem );
		$ret = 1023;
	} elsif ( $ret < 0 ) {
		warn sprintf( "Requested filament voltage %f < 0%% PWM duty cycle, clamping to 0%%.", $voltage );
		$ret = 0;
	}
	return $ret;
}    # }}}





__PACKAGE__;

__END__
