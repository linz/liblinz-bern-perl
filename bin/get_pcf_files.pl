#!/usr/bin/perl
#
#  Script to extract the files belonging to a PCF.  Processes the PCF file
#  to identify the scripts and options, the process each script to identify
#  the panels it uses
#
#  Prints the list of files to stdout for use as input to, eg, tar
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
my %optdirs;
while(my $line=<$pcff>)
{
    last if $line=~/^PID\s+USER/;
    if( $line =~ /^\d+\s+(\w+)\s+(\w+)/ )
    {
        push(@$scripts,{file=>"SCRIPT/$1",optdir=>"OPT/$2"});
        $optdirs{"OPT/$2"}=1;
        
    }
}
close($pcff);

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
        die "$pgm.INP in $optdir is missing\n" if ! -e $f;
        $files->{$f} = 1;
    }
}

foreach my $optdir (sort keys %optdirs)
{
    foreach my $f (glob "$optdir/MENU*.INP")
    {
        $files->{$f}=1;
    }
}

# If we've got to here then all looks OK and we should have the complete set of files...

foreach my $f (sort keys %$files )
{
    print "$f\n";
}


