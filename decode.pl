#!/usr/bin/perl
# vim: foldmethod=marker commentstring=\ #\ %s
use strict;
use warnings;
use Data::Dumper;
use List::Util qw(max);

# Resistors in voltage dividers, 400V version
use constant {   # {{{
  AnodeR1 => 5_230,   # R32
  AnodeR2 => 470_000, # R33
  AnodeRs => 17.8,    # R45 ... actually 18 ohm, but we cheat w/ 17.8 for correction http://dos4ever.com/uTracerlog/tubetester2.html#examples
  #
  ScreenR1 => 5_230,   # R18
  ScreenR2 => 470_000, # R19
  ScreenRs => 17.8,    # R20 ... actually 18 ohm, but we cheat w/ 17.8 for correction http://dos4ever.com/uTracerlog/tubetester2.html#examples
  #
  VsupR1 => 1_800, # R44
  VsupR2 => 6_800, # R43
  #
  VminR1 => 2_000, # R3 (-15v supply)
  VminR2 => 47_000 # R4 (-15v supply)
}; # }}}

# XXX factor these aliases out?
use constant { # {{{
  AnodeDivR1 => AnodeR1,
  AnodeDivR2 => AnodeR2,
  ScreenDivR1 => ScreenR1,
  ScreenDivR2 => ScreenR2,
}; # }}}

# calibration
use constant { # {{{
  CalVar1  => 1018/1000, # Va Gain
  CalVar2  => 1008/1000, # Vs Gain
  CalVar3  =>  990/1000, # Ia Gain
  CalVar4  =>  985/1000, # Is Gain
  CalVar5  => 1011/1000, # VsupSystem
  CalVar6  => 1014/1000, # Vgrid(40V)
  CalVar7  => 1000/1000, # VglowA, unused?
  CalVar8  => 1018/1000, # Vgrid(4V)
  CalVar9  =>  996/1000, # Vgrid(sat)
  CalVar10 => 1000/1000, # VglowB, unused?
}; # }}}

# scale constants
use constant { # {{{
  SCALE_IA     =>  5 / 1024 * 1000 / AnodeRs,
  SCALE_IA_RAW =>  5 / 1024 * 1000 / AnodeRs,
  #
  SCALE_IS     =>  5 / 1024 * 1000 / ScreenRs,
  SCALE_IS_RAW =>  5 / 1024 * 1000 / ScreenRs,
  #
  SCALE_VA => 5 / 1024 * ((AnodeDivR1 + AnodeDivR2) / AnodeDivR1),
  SCALE_VS => 5 / 1024 * ((ScreenDivR1 + ScreenDivR2) / ScreenDivR1),

  SCALE_VSU    => ( 5 / 1024 ) * (VsupR1+VsupR2)/VsupR1, # needs calibration scale
  SCALE_VN     => 49.0/2.0, # this is confusing.
  HEAT_CNT_MAX => 20,
}; # }}}

my @measurement_fields = qw(
    status_byte

    Ia
    Ia_Raw

    Is
    Is_Raw

    Va
    Vs
    Vpsu
    Vmin

    Gain_A
    Gain_S
);

my $gain_to_average = { # {{{
  7 => 8,
  6 => 4,
  5 => 2,
  4 => 2,
  3 => 1,
  2 => 1,
  1 => 1,
  1 => 1,
}; # }}}

my $gain_from_tracer = {
  0 => 1,
  1 => 2,
  2 => 5,
  3 => 10,
  4 => 20,
  5 => 50,
  6 => 100,
  7 => 200,
};

#my $data = decode_measurement("10 077A 0000 0724 0001 0034 0033 0338 0288 0707"); # from utracer
my $data = decode_measurement("10 02B0 0043 02B4 0044 01DB 01DA 033A 0287 0303"); # from utracer

sub decode_measurement {
  my ($str) = @_;
  $str =~ s/ //g;
  my $data = {};
  @{$data}{@measurement_fields} = map {hex($_) } unpack("A2 A4 A4 A4 A4 A4 A4 A4 A4 A2 A2",$str);

  # status byte = 10 - all good.
  # status byte = 11 - compliance error
  # $compliance_error = $status_byte & 0x1 == 1;

  # find max gain
  my $gain = max @{$data}{qw(Gain_A Gain_S)};

  $data->{Vpsu} *= SCALE_VSU;
  $data->{Vpsu} *= CalVar5;

  $data->{Va} = $data->{Va} * (5 / 1024) * ((AnodeDivR1 + AnodeDivR2) / (AnodeDivR1 * CalVar1)) - $data->{Vpsu};
  $data->{Vs} = $data->{Vs} * (5 / 1024) * ((ScreenDivR1 + ScreenDivR2) / (ScreenDivR1 * CalVar2)) - $data->{Vpsu};

  $data->{Ia} *= SCALE_IA;
  $data->{Ia} *= CalVar3;

  $data->{Is} *= SCALE_IS;
  $data->{Is} *= CalVar4;

  $data->{Ia_Raw} *= SCALE_IA;
  $data->{Ia_Raw} *= CalVar3;

  $data->{Is_Raw} *= SCALE_IS;
  $data->{Is_Raw} *= CalVar4;

  $data->{Vmin} = 5 * ((VminR1 + VminR2) / VminR1) * (( $data->{Vmin} / 1024) - 1);
  $data->{Vmin} += 5;

  # decode gain
  @{$data}{qw(Gain_A Gain_S)} = map { $gain_from_tracer->{$_} } @{$data}{qw(Gain_A Gain_S)};

  $data->{Ia} /= $gain_to_average->{$gain};
  $data->{Is} /= $gain_to_average->{$gain};

  # correction - this appears to be backwards?
  if (0) {
    #$data->{Va} -= (($data->{Ia}) / 1000) * AnodeRs - (0.6 * CalVar7);
    #$data->{Vs} -= (($data->{Is}) / 1000) * ScreenRs - (0.6 * CalVar7);
    
    $data->{Va} = $data->{Va} - (($data->{Ia}) / 1000) * AnodeRs - (0.6 * CalVar7);
    $data->{Vs} = $data->{Vs} - (($data->{Is}) / 1000) * ScreenRs - (0.6 * CalVar7);
  }

print "\nAfter scale:\n";
printf "stat   ia iacmp   is  is_comp    va   vs vPSU vneg  ia_gain is_gain\n";
printf "%04x %2.1f % 5.1f %2.1f      %2.1f   %2.1f  %2.1f %2.1f %2.1f  %04d    %04d\n",
        @{$data}{@measurement_fields};

printf "\nShould be:\n";
printf "stat   ia iacmp   is  is_comp    va   vs vPSU vneg  ia_gain is_gain\n";
printf "%04x %2.1f % 5.1f %2.1f      %2.1f   %2.1f  %2.1f %2.1f %2.1f  %04d    %04d\n",
       0x10,65,0,61.7,0.3,3.2,3,19.4,-40,200,200;
return $data;
}