#!/usr/bin/perl
#
#  Script to extract the parameters used in the input files for a PCF.  
#  Mainly used to check consistency.
#  Output parameters in a CSV file format.
#
#  Should be run in the GPSUSER directory.  
#
#  Input is the name of the PCF file
#

use strict;

scalar(@ARGV)==1 || die "Require the name of the PCF file as input";
my $pcf=$ARGV[0];
$pcf .= '.PCF' if $pcf !~ /\.PCF$/i;
$pcf = "PCF/$pcf";

-d 'PCF' || die "PCF directory not found, are you in a GPSUSER directory?\n";
-d 'SCRIPT' || die "SCRIPT directory not found, are you in a GPSUSER directory?\n";
-d 'OPT' || die "OPT directory not found, are you in a GPSUSER directory?\n";

open(my $pcff,"$pcf") || die "Cannot find $pcf\n";

# Process the PCF file to find the list of scripts and options it uses...

my $files={$pcf=>1};

my $scripts=[];
while(my $line=<$pcff>)
{
    last if $line=~/^PID\s+USER/;
    if( $line =~ /^\d+\s+(\w+)\s+(\w+)/ )
    {
        push(@$scripts,{file=>"SCRIPT/$1",optdir=>"OPT/$2"});
    }
}
close($pcff);

my @params=();

foreach my $script (@$scripts)
{
    open(my $scpf,$script->{file}) || die "Cannot open script file $script->{file}\n";
    $files->{$script->{file}}=1;
    my $vars={};
    my $pgms={};
    while(my $line=<$scpf>)
    {
        if( $line =~ /^\s*my\s+\$(\w+)\s*\=\s*(['"])(\w+)\2\;\s*$/ )
        {
            $vars->{$1}=$3;
            next;
        }
        if( $line =~ /^\s*\$bpe\-\>RUN_PGMS\(\$(\w+)\)\;/ )
        {
            $pgms->{$vars->{$1}}=1;
        }
    }
    close($scpf);
    my $optdir=$script->{optdir};
    foreach my $pgm ( sort keys %$pgms )
    {
        my $f="$optdir/$pgm.INP";
        open(my $inpf,"<$f") || die "Cannot open $f\n";
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
                $value=join("\n",@$value);
            }
            $value =~ s/\"/\"\"/g;
            push(@params,"$optdir,$pgm,$param,\"$value\"\n");
        }
    }
}

print "OPT,PGM,PARAM,VALUE\n",@params;
