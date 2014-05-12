#!/usr/bin/perl
use strict;

package LINZ::BERN::Environment;

use Carp;
use LINZ::GNSS::Time qw/datetime_seconds seconds_datetime seconds_julianday year_seconds time_elements/;
use LINZ::BERN::SessionFile;

=head1 LINZ::BERN::Environment

Package for providing access to components of the BERN runtime environment

=cut

our ($outf,$errf,$params);

$params = {};

=head2 $env = new LINZ::BERN::Environment

Create the environment object

=cut

sub new
{
    my($class) = @_;
    my $inp=<STDIN>;
    chomp($inp);
    open(my $inpf,"<$inp") || croak("Cannot open input file $inp\n");
    while( my $l = <$inpf> )
    {
        next if $l =~ /^\s*(\#|\!|$)/;
        next if $l =~ /^\s*DESCR_/;
        next if $l =~ /^\s*MSG_/;
        if($l =~ /^\s*ENVIRONMENT\s+(\d+)\s*$/)
        {
            my $nenv=$1;
            while($nenv--)
            {
                my $nextline=<$inpf>;
                if( $nextline =~ /^\s*\"(\w+)\"\s+\"([^\"]*)\"\s*$/ )
                {
                    $ENV{$1} = $2;
                }
            }
            next;
        }
        next if $l !~ /^\s*(\w+)\s+(\d+)(?:\s+\"([^\"]*)\")?\s*$/;
        my ($param,$count,$value)=($1,$2,$3);
        if( $count > 1 )
        {
            $value=[];
            while($count--)
            {
                $l = <$inpf>;
                push(@$value,$1) if $l =~ /^\s*\"([^\"]*)\"\s*$/;
            }
        }
        $params->{$param} = $value;
    }

    my $sysout=expandValue($params->{SYSOUT});
    open($outf,">",$sysout);
    *STDOUT = $outf;
    if( $params->{ERRMRG} )
    {
        $errf = $outf;
    }
    else
    {
        my $syserr=expandValue($params->{SYSERR});
        open($errf,">",$syserr);
    }
    *STDERR = $errf;

    return bless {}, $class;
}

=head2  $v = LINZ::BERN::Envorinment::expandValue($value)

Expand ${xxx} with the value of $ENV{xxx} in a string

=cut

sub expandValue
{
    my($value) = @_;
    $value =~ s/\$\{(\w+)\}/$ENV{$1}/eg;
    return $value;
}

=head2 $v = $env->param('PARAM',$expand)

Return the value of a parameter from the Bern environment (eg a menu variable).
If the $expand parameter evaluates to true, then the environment string expansion is
applied to the parameter.

=cut

sub param
{
    shift if ref($_[0]);
    my($param,$expand) = @_;
    my $value=$params->{$param};
    $value=expandValue($value) if $expand;
    return $value;
}

=head2 $v = $env->params

Return the dictionary of parameters

=cut

sub params
{
    return $params;
}

=head2 $v = $env->session_startend

Determine the session start and end time, based on the SES_INOF and YR4_INFO 
values and the SESSION_TABLE parameters. Returns the start and end times as 
timestamps.

=cut

sub session_startend
{
    my( $self ) = @_;
    my $sessfn=$self->param('SESSION_TABLE',1);
    my $sessid=$self->param('SES_INFO');
    my $year=$self->param('YR4_INFO');
    my $sf=new LINZ::BERN::SessionFile($sessfn);
    return $sf->sessionStartEnd($sessid,$year);
}

1;
