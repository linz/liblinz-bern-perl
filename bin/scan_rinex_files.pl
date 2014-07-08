#!/usr/bin/perl
#
# Script to catalog rinex files in a directory tree
#
use strict;
use Archive::Zip;
use File::Find;
use LINZ::GNSS::RinexFile;
use LINZ::Geodetic::Ellipsoid;
use Getopt::Std;

my $opts={};
getopts('r',$opts);
my $recursive=$opts->{r};

my $grs80=new LINZ::Geodetic::Ellipsoid(6378388.0,298.257222101);

my $rinex_re=qr/\.\d\d[od](?:\.(?:z|gz(?:ip)?))?/i;
my $zip_re=qr/\.zip$/i;

sub format_time
{
    my($sec,$min,$hour,$mday,$mon,$year)=gmtime($_[0]);
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",$year+1900,$mon+1,$mday,$hour,$min,$sec);

}

sub scanRinex
{
    my($filename,$source,$filesize,$filedate)=@_;
    my $basename=$source;
    $basename=~s/.*[^\\\/\:]//;
    eval
    {
        my $rf=new LINZ::GNSS::RinexFile($filename);
        my $st=$rf->starttime;
        my $et=$rf->endtime;
        my $types=$rf->obstypes;
        my $llh=$grs80->geog($rf->xyz);
        my $ot=join(":",sort @$types);
        print join("\t",
            $basename,
            $filesize,
            format_time($filedate),
            $rf->markname,
            $rf->marknumber,
            $rf->anttype,
            $rf->rectype,
            format_time($st),
            format_time($et),
            $et-$st,
            $rf->interval,
            $rf->nobs,
            $ot,
            $llh->lon,
            $llh->lat,
            $source
           ),"\n";
    };
    if( $@ )
    {
        print STDERR "$source: $@\n";
    }
}

sub scanFile
{
    my ($file,$source)=@_;
    if( ! -f $file )
    {
        print STDERR "Cannot open file: $file (from $source)\n" if ! -e $file;
        return;
    }
    eval
    {
        my ($filesize,$filedate)=(stat($file))[7,9];
        my $command='';
        my $s1=$source;
        if( $s1 =~ /\.z$/i )
        {
            $command="compress -d < \"$file\"";
            $s1=~ $`;
        }
        elsif( $s1 =~ /\.gz(ip)?$/i )
        {
            $command="gzip -d < \"$file\"";
            $s1=~ $`;
        }
        if( $s1=~ /\.\d\dd$/i )
        {
            $command = $command ? $command . ' | CRX2RNX' : "CRX2RNX < \"$file\"";
        }
        # print "$command\n";
        my $localfile=$file;
        if( $command )
        {
            $localfile ='lrtmpzdc';
            $command=$command." > $localfile";
            system($command);
        }
        scanRinex($localfile,$source,$filesize,$filedate);
        unlink($localfile) if $localfile ne $file;

    };
    if( $@ )
    {
        print STDERR "Error processing $file from $source: $@\n";
    }
}

sub scanZip
{
    my($zipfile)=@_;
    eval
    {
        # print "Processing zip $zipfile\n";
        my $zf=new Archive::Zip($zipfile);
        foreach my $f ($zf->membersMatching($rinex_re))
        {
            my $fn=$f->fileName;
            my $localname='lrtmpzz';
            $f->extractToFileNamed($localname);
            scanFile($localname,"$zipfile:$fn");
            unlink $localname if -e $localname;
        }
    };
    if( $@ )
    {
        print STDERR "zipfile $zipfile: $@\n";
    }
}

sub scanZipOrFile
{
    my ($file)=@_;
    if( $file=~/$zip_re/ )
    {
        scanZip($file);
    }
    elsif( $file =~ /$rinex_re/ )
    {
        scanFile($file,$file);
    }
}

sub scan
{
    my($file)=@_;
    if( -d $file )
    {
        return if ! $recursive;
        find(  {
            wanted=>sub {scanZipOrFile($_) if -f $_},
            no_chdir=>1,
            },
            $file
            );
    }
    else
    {
        scanZipOrFile($file);
    }

}



print "file\tsize\tdate\tmark\tnumber\tantenna\treceiver\tstart_time\tend_time\tduration\tinterval\tnobs\tobstypes\tlon\tlat\tsourcefile\n";

foreach my $f (@ARGV)
{
    scan($f);
}

