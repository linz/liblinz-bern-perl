=head1 LINZ::BERN::BernUtil

Package provides utility functions to support bern processing.

=cut

use strict;

package LINZ::BERN::BernUtil;
our $VERSION='1.0';

use LINZ::BERN::SessionFile;
use LINZ::BERN::CrdFile;
use LINZ::GNSS::RinexFile;
use LINZ::GNSS::Time qw/seconds_datetime time_elements year_seconds seconds_julianday/;
use File::Path qw/remove_tree/;
use File::Basename;
use File::Copy;
use Carp;

use JSON::PP;

our $DefaultLoadGps='/opt/bernese52/GPS/EXE/LOADGPS.setvar';
our $AntennaFile='PCV_COD.I08';
our $ReceiverFile='RECEIVER.';

=head2 LINZ::BERN::BernUtil::SetBerneseEnv($loadgps,%override)

Script to read a Bernese LOADGPS.setvar script and set the corresponding
information into the %ENV environment variable.

Takes parameters:

=over

=item $loadgps

The name of the Bernese LOADGPS.setvar file. The default is /opt/bernese52/GPS/EXE/LOADGPS.setvar

=item %overrides

A hash of values to replace, eg P=>'/mycampdir/'

=back

Crudely assumes each variable is defined by a line

 export var="value"
 export var=`value`

Where value may contain ${xxx} that are replaced with environment variables,
`xxx` that are replaced with the output from running the command.

Also expects lines like

 addtopath "value"

The parser does not tolerate whitespace in front of export and addtopath

Returns a hash of the environment that is set.

=cut

sub SetBerneseEnv
{
    my ($loadfile,%override) = @_;
    $loadfile ||= $LINZ::BERN::BernUtil::DefaultLoadGps;

    open( my $lf, "<$loadfile" ) 
        || croak("Cannot open Bernese enviroment file $loadfile\n");
    my @paths=();
    my $bernenv={};
    while(my $line=<$lf>)
    {
        if( $line=~/^export\s+(\w+)=\"([^\"]*)\"\s*$/ ||
            $line=~/^export\s+(\w+)=(\`[^\`]*\`)\s*$/ )
        {
            my($var,$value)=($1,$2);
            $value =~ s/\$\{(\w+)\}/$ENV{$1}/eg;
            $value =~ s/\$(\w+)/$ENV{$1}/eg;
            $value =~ s/\`([^\`]*)\`/`$1`/eg; 
            $value =~ s/\s*$//; # To remove new lines from command expansion
            $value=$override{$var} if exists $override{$var};
            $bernenv->{$var}=$value;
            $ENV{$var}=$value;
        }
        elsif( $line=~/^addtopath\s+\"([^\"]*)\"\s*$/ )
        {
            my($path)=$1;
            $path =~ s/\$\{(\w+)\}/$ENV{$1}/eg;
            $path =~ s/\$(\w+)/$ENV{$1}/eg;
            push(@paths,$path);
        }
    }
    my @envpaths=split(/\:/,$ENV{PATH});
    my %gotpath= map {$_=>1} @envpaths;
    foreach my $p (@paths){ unshift(@envpaths,$p) if ! exists $ENV{$p}; }
    my $newpath=join(":",@envpaths);
    $bernenv->{PATH}=join(':',@paths,'${PATH}');
    $ENV{PATH}=$newpath;

    return $bernenv;
}


=head2 $campaign = LINZ::BERN::BernUtil::CreateCampaign($jobid,%options)

Create the campaign directories for a new job.  If the job id includes a string
of hash characters ### then the job will be created in the first non-existing 
directory replacing ### with number 001, 002, ...

The script returns a hash defining the campaign, which can be submitted 
to LINZ::BERN::BernUtil::RunPcf to run the job.

Options can include

=over

=item RinexFiles=>[file1,file2]

Adds specified files to the RAW directory

=item MakeSessionFile=>1

Creates a session file 

=item UseStandardSessions=>0,1,2

Creates a fixed session file for the time span of the rinex files if 0, 
a daily session file if 1, or an hourly session file if 2.

=item CrdFile=>filename

Creates a coordinate file named filename.CRD

=item AbbFile=>filename

Creates an abbreviations file filename.ABB.  Only applicable if CrdFile is also defined

=item AddNoneRadome=>1

If true then blank radome entries are replaced with NONE

=item SetupUserMenu=>1

Updates the users MENU.INP to use this job if defined

=item UpdateCampaignList=>1

Updates the MENU_CMP.INP file if it is defined

=item RenameRinex=>xxxx

Provides the option of renaming RinexFiles to replace the
code part of the name with sequential codes.  The value xxxx
must contain one or more # characters which are replaced with
a sequential ID.  This can be used to avoid names clashing with 
ids of (for example) reference stations.

=item RenameCodes=>codelist

Provides a list of codes for which the Rinex files are renamed.
codelist is an array ref of codes for which the renaming is applied.
If RenameCodes is specified then the RenameRinex option will only 
apply to files and mark names which match the listed codes. This option
has no effect if RenameRinex is not specified.

=item SettingsFile=>0

Creates a file called SETTINGS.JSON in the OUT directory which contains
the campaign information in JSON information.  This can be used 
by the SetUserCampaign function to restore the environment.

=item CanOverwrite=>1

Allows overwriting an existing campaign with the same name.

=back

The campaign hash contains the following values

=over

=item JOBID

The campaign name

=item CAMPAIGN

The campaign directory (${P}/$job)

=item YR4_INFO

The four digit year (only if the session file is created)

=item SES_INFO

The session id (only if the session file is created)

=item variables

An empty hash for holding user variables.  This can be populated before calling RunPcf.
=item marks

An array of mark codes

=item files

An array of file definitions, each a hash with elements srcfilename, srcmarkname, 
filename, markname defining the input file and mark id, and the possibly renamed 
values used in the campaign directories.

=item createtime

The date/time when the job was created

=back

=cut

sub CreateCampaign
{
    my( $job, %options ) = @_;
    my $campdir=$ENV{P};
    croak("Bernese campaign directory \$P not set\n") if ! -d $campdir;

    # If automatically allocating a new job then do so now...
    if( $job=~ /^(\w+)(\#+)(\w*)$/ )
    {
        my ($prefix,$ndigit,$suffix) = ($1,length($2),$3);
        my $format="%0".$ndigit."d";
        my $nextid=1;
        while(1)
        {
            $job=$prefix.sprintf($format,$nextid++).$suffix;
            last if ! -e "$campdir/$job";
        }
    }

    my $jobdir="$campdir/$job";

    my $now=seconds_datetime(time(),1);
    my $campaign=
    { 
        JOBID=>$job, 
        CAMPAIGN=>"\${P}/$job", 
        variables=>{}, 
        createtime=>$now, 
        campaigndir=>$jobdir 
    }; 
    my $existing = -d $jobdir;

    my $files=();

    eval
    {
        remove_tree($jobdir) if -d $jobdir && $options{CanOverwrite};
        croak("Job $job already exists\n") if -d $jobdir;
        $existing=0;
        mkdir($jobdir) || croak("Cannot create campaign directory $jobdir\n");
        for my $subdir (qw/ATM BPE GRD OBS ORB ORX OUT RAW SOL STA/)
        {
            mkdir("$jobdir/$subdir") || croak("Cannot create campaign directory $jobdir/$subdir\n");
        }
        my @files=();
        my @marks=();
        my $start=0;
        my $end=0;
        my $sessid='';
        my $crdfile;

        if( $options{RinexFiles} )
        {
            my $rinexfiles=$options{RinexFiles};
            $rinexfiles=[$rinexfiles] if ! ref $rinexfiles;

            if( @$rinexfiles )
            {
                my $letters='ABCDEFGHIJKLMNOPQRSTUVWXYZ';
                my %usedfile=();
                my %codemap=();
                my $rename=0;
                my %renamecodes=();
                my $nextname=0;
                if( $options{RenameRinex} ne '' )
                {
                    my $newname=$options{RenameRinex};
                    croak("Invalid RenameRinex code $newname\n") 
                        if length($newname) != 4 || $newname !~ /^(\w*)(\#*)(\w*)$/;
                    my ($prefix,$ndigit,$suffix)=($1,length($2),$3);
                    my $nextid=1;
                    my $maxid=10**$ndigit-1;
                    my $format="%0".$ndigit."d";
                    $nextname=sub
                    {
                        croak("Too many RINEX files to rename sequentially\n") if $nextid >= $maxid;
                        return $prefix.sprintf($format,$nextid++).$suffix;
                    };
                    $rename=1;
                    if( ref($options{RenameCodes}) eq 'ARRAY' )
                    {
                        $renamecodes{''}=1;
                        foreach my $code (@{$options{RenameCodes}})
                        {
                            $renamecodes{uc($code)} = 1;
                        }
                    }
                }
                my %rnxfiles=();

                foreach my $rnxfile (@$rinexfiles)
                {
                    my $rf=new LINZ::GNSS::RinexFile($rnxfile);

                    my $srcfile=basename($rnxfile);
                    my $srccode=$rf->markname;

                    my $rawname=uc($srcfile);
                    my $rawcode=uc($srccode) . $rawname .'0000';
                    $rawcode =~ s/\W//g;
                    $rawcode = substr($rawcode,0,4);

                    my $renamefile=$rename;
                    $renamefile=0 if %renamecodes && ! $renamecodes{$rawcode};

                    if( $renamefile )
                    {
                        $codemap{$rawcode}=$nextname->() if ! exists $codemap{$rawcode};
                        $rawcode=$codemap{$rawcode};
                        $rawname=$rawcode.substr($rawname,4);
                    }

                    my $rstart=$rf->starttime;
                    my $rend=$rf->endtime;
                    $start=$rstart if $start==0 || $rstart < $start;
                    $end=$rend if $end==0 || $rend > $end;

                    my ($year,$doy,$hour) = (time_elements($rstart))[0,2,4];
                    $doy=sprintf("%03d",$doy);
                    $year=substr(sprintf("%04d",$year),2,2);

                    my $validre="^$rawcode$doy.\\.${year}O\$";

                    if( $rawname !~ /$validre/ || $usedfile{$rawname} )
                    {
                        my $hcode=substr($letters,$hour,1);
                        if( $hour == 0 && $rend-$rstart > (3600*23.0) )
                        {
                            $hcode='0';
                        }

                        my $ic=0;
                        $rawname='';
                        while( $hcode ne '' )
                        {
                            my $name="$rawcode$doy$hcode.${year}O";
                            if( ! exists($usedfile{$name}) )
                            {
                                $rawname=$name;
                                last;
                            }
                            $hcode=substr($letters,$ic++,1);
                        }
                        if( ! $rawname )
                        {
                            croak("Cannot build a unique valid name for file $srcfile\n");
                        }
                    }

                    if( $options{AddNoneRadome} )
                    {
                        my $anttype=sprintf("%-20.20s",$rf->anttype);
                        substr($anttype,16,4)='NONE' if substr($anttype,16,4) eq '    ';
                        $rf->anttype($anttype);
                    }

                    $rf->markname($rawcode);
                    $rf->write("$jobdir/RAW/$rawname");

                    push(@files, {
                        srcfilename=>$srcfile,
                        srcmarkname=>$srccode,
                        filename=>$rawname,
                        markname=>$rawcode
                        }
                        );
                    push(@marks,$rf->markname);
                }
            }
            $campaign->{marks}=\@marks;
            $campaign->{files}=\@files;
            $campaign->{session_start}=$start;
            $campaign->{session_end}=$end;
            if( $options{MakeSessionFile} && @files )
            {
                my $sfn="$jobdir/STA/SESSIONS.SES";
                my $sf=new LINZ::BERN::SessionFile($sfn);
                if( ! $options{UseStandardSessions} )
                {
                    $sessid=$sf->addSession($start,$end);
                }
                else
                {
                    my $hourly=$options{UseStandardSessions} == 2;
                    $sf->resetDefault($hourly);
                    $sessid=$sf->getSession($start);
                }
                $sf->write();
                $campaign->{SES_INFO}=$sessid;
                $campaign->{YR4_INFO}=(time_elements($start))[0];
            }
        }
        if( $options{CrdFile} )
        {
            my $cfn=$options{CrdFile};
            $cfn=~ s/\$S\+0/$sessid/g;
            my $crdfilename="$jobdir/STA/$cfn.CRD";
            eval
            {
                # Note - currently not adding stations to coordinate file
                # as Bernese software can do this on RINEX import.
                $crdfile=new LINZ::BERN::CrdFile($crdfilename);
                if( $start ) { $crdfile->epoch($start); }
                $crdfile->write();
                if ( $options{AbbFile} )
                {
                    my $abbfilename="$jobdir/STA/".$options{AbbFile}.".ABB";
                    $crdfile->writeAbbreviationFile($abbfilename);
                }
            };
            if( $@ )
            {
                croak("Cannot create coordinate file $crdfilename\n");
            }
        }

        if( $options{SettingsFile} )
        {
            if( open(my $of,">$jobdir/OUT/SETTINGS.JSON") )
            {
                print $of JSON::PP->new->pretty->utf8->encode($campaign);
                close($of);
            }
        }

        if( $options{SetupUserMenu} )
        {
            my ($year) = (time_elements($start))[0];
            SetUserCampaign($job,$campaign);
        }

        if( $options{UpdateCampaignList} )
        {
            UpdateCampaignList();
        }
    };
    if( $@ )
    {
        my $error=$@;
        if( -d $jobdir && ! $existing )
        {
            remove_tree($jobdir);
        }
        croak($@);
    }
    
    return $campaign;
}

=head2 $status=LINZ::BERN::BernUtil::RunPcf($pcf,$campaign,%options)

Runs a Bernese script (PCF) on the campaign as created by CreateCampaign.

Parameters are:

=over

=item $pcf

The name of the PCF file to run

=item $campaign

The campaign - a hash ref as returned by CreateCampaign

=item %options

Additional options.  Currently supported are:

=over 

=item CLIENT_ENV=>$client_env_filename

=item CPU_FILE=>$cpu_file

=back

=back

=cut

sub RunPcf
{
    my( $campaign, $pcf, %options )=@_;

    # Check that the PCF file exists
    #
    my $userdir=$ENV{U};
    croak("Bernese user directory \$U not set\n") if ! -d $userdir;
    my $bpedir=$ENV{BPE};
    croak("Bernese BPE not set\n") if ! -e $bpedir;
    @INC=grep { $_ ne $bpedir } @INC;
    unshift(@INC,$bpedir);
    require startBPE;

    my $pcffile="$userdir/PCF/$pcf.PCF";
    croak("Cannot find PCF file $pcf\n") if ! -e $pcffile;

    # Set up user variables

    # Create the processing task
    my $bpe=new startBPE(%{$campaign->{variables}});
    $bpe->{BPE_CAMPAIGN}=$campaign->{CAMPAIGN};
    $bpe->{CLIENT_ENV}=$options{CLIENT_ENV} if exists $options{CLIENT_ENV};
    $bpe->{CPU_FILE}=$options{CPU_FILE} if exists $options{CPU_FILE};
    $bpe->{S_CPU_FILE}=$options{CPU_FILE} if exists $options{CPU_FILE};
    $bpe->{PCF_FILE}=$pcf;
    $bpe->{SESSION}=$campaign->{SES_INFO};
    $bpe->{YEAR}=$campaign->{YR4_INFO};

    $bpe->{SYSOUT}=$pcf;
    $bpe->{STATUS}=$pcf.'.SUM';

    $bpe->resetCPU();
    $bpe->resetCPU($bpe->{S_CPU_FILE});
    
    $bpe->run();

    $campaign->{bernese_status}=$bpe->{ERROR_STATUS};
    return $campaign->{bernese_status};
}

=head2 LINZ::BERN::BernUtil::SetUserCampaign($job,$campaign)

Setup the user environment for the specified campaign.  Can take
session and year information from a campaign hash as SES_INFO and YR4_INFO,
or if not defined there will try a SETTINGS.JSON file.

=cut

sub SetUserCampaign
{
    my( $job, $campaign ) = @_;
    $campaign ||= {};
    my $campdir=$ENV{P};
    croak("Bernese environment \$P not set\n") if ! -d $campdir;
    my $jobdir="$campdir/$job";
    croak("Campaign $job does not exist\n") if ! -d $jobdir;
    my $settingsfile="$jobdir/OUT/SETTINGS.JSON";
    my $settings={};
    if( -e $settingsfile )
    {
        eval
        {
            if( open(my $sf,"<$settingsfile") )
            {
                my $sfdata=join('',<$sf>);
                close($sf);
                $settings=JSON::PP->new->utf8->decode($sfdata);
            }
        };
    }
    my $sessid=$campaign->{SES_INFO} || $settings->{SES_INFO};
    my $year=$campaign->{YR4_INFO} || $settings->{YR4_INFO};

    my $doy=substr($sessid,0,3);
    my $sesschar=substr($sessid,3,1);
    my $julday=
        $year ne '' && $sessid ne '' ?
            seconds_julianday(year_seconds($year))+($doy-1) :
            0;
    my $menufile=$ENV{U}.'/PAN/MENU.INP';
    croak("\$U/PAN/MENU.INP does not exists or is not writeable\n")
        if ! -r $menufile || ! -w $menufile;
    my @menudata=();
    open(my $mf,"<$menufile") || croak("Cannot open $menufile for input\n");
    while( my $line=<$mf> )
    {
        if( $line =~ /^(\s*ACTIVE_CAMPAIGN\s+1\s+)/ )
        {
            $line=$1."\"\${P}/$job\"\n";
        }
        elsif( $line =~ /^(\s*SESSION_TABLE\s+1\s+)/ )
        {
            $line=$1."\"\${P}/$job/STA/SESSIONS.SES\"\n";
        }
        elsif( $line =~ /^(\s*MODJULDATE\s+1\s+)/ && $julday )
        {
            $line=$1.sprintf("\"%d.000000\"\n",$julday);
        }
        elsif( $line =~ /^(\s*SESSION_CHAR\s+1\s+)/ && $sessid ne '' )
        {
            $line=$1."\"$sesschar\"\n";
        }
        push(@menudata,$line);
    }
    close($mf);
    open($mf,">$menufile") || croak("Cannot open $menufile for output\n");
    print $mf @menudata;
    close($mf);
}

=head2 LINZ::BERN::BernUtil::UpdateCampaignList

Updates the MENU_CMP.INP with the current list of campaigns

=cut

sub UpdateCampaignList
{
    my $menufile=$ENV{U}.'/PAN/MENU.INP';
    open(my $mf,"<$menufile") || croak("Cannot open \${U}/PAN/MENU.INP\n");
    my $campfile;
    while( my $line=<$mf> )
    {
        if( $line =~ /^\s*MENU_CMP_INP\s+1\s+\"([^\"]*)\"\s*$/ )
        {
            $campfile=$1;
            last;
        }
    }
    croak("MENU_CMP_INP not defined in \${U}/PAN/MENU.INP\n")
        if ! $campfile;
    my $campdef=$campfile;
    $campfile =~ s/\$\{(\w+)\}/$ENV{$1}/eg;
    croak("Campaign menu $campdef doesn't exist\n") if ! -f $campfile;

    my @camplist=();
    my $campdir=$ENV{P};
    opendir(my $cdir,$campdir) || croak("Cannot open campaign directory \${P}\n");
    while( my $cmpn=readdir($cdir) )
    {
        next if $cmpn !~ /^\w+$/;
        next if ! -d "$campdir/$cmpn";
        next if ! -d "$campdir/$cmpn/OUT";
        my $cmpns=$cmpn;
        $cmpns =~ s/(\d+)/sprintf("%05d",$1)/eg;
        $cmpns = $cmpns.":\"\${P}/$cmpn\"";
        push(@camplist,$cmpns);
    }
    @camplist = map {s/.*\://; $_} sort @camplist;

    open( my $cf,"<$campfile" ) || croak("Cannot open campaign file $campdef\n");
    my @mcamp=<$cf>;
    close($cf);

    my ($ncmp,$nlin)=(-1,-1);
    foreach my $i (0 ..$#mcamp)
    {
        if( $mcamp[$i] =~ /^\s*CAMPAIGN\s+(\d+)/ )
        {
            $ncmp=$1;
            $nlin=$i;
            last;
        }
    }
    croak("Campaign menu $campdef missing CAMPAIGN\n") if $nlin < 0;

    my $newncmp=scalar(@camplist);
    my $newcamp="CAMPAIGN $newncmp";
    $newcamp .= "\n  " if $newncmp > 1;
    $newcamp .= join("\n  ",@camplist);
    $newcamp .= "\n";
    $ncmp += 1 if $ncmp != 1;
    splice(@mcamp,$nlin,$ncmp,$newcamp);

    open( $cf, ">$campfile") || croak("Cannot update campaign file $campdef\n");
    print $cf @mcamp;
    close($cf);
    return $newncmp;
}

=head2 $antennae=LINZ::BERN::BernUtil::AntennaList;

Returns an array or array hash of valid antenna names.

=cut

sub AntennaList
{
    my $brndir=$ENV{X};
    my $gendir=$brndir.'/GEN';
    die "BERN environment not set\n" if ! $brndir || ! -d $gendir;

    my $antfile=$gendir.'/'.$AntennaFile;

    open(my $af,"<$antfile") || die "Cannot find antenna file $antfile\n";

    my $antennae=[];
    while(my $line=<$af>)
    {
        next if $line !~ /^ANTENNA\/RADOME\s+TYPE\s+NUMBER/;
        $line=<$af>;
        $line=<$af> if $line;
        last if ! $line;
        my $ant=substr($line,0,20);
        next if $ant !~ /\S/;
        next if $ant =~ /^MW\s+BLOCK/;
        next if $ant =~ /^MW\s+GEO/;
        next if $ant =~ /^MW\s+GLONASS/;
        next if $ant =~ /^SLR\s+REFL/;
        push(@$antennae,$ant);
    }
    close($af);

    return wantarray ? @$antennae : $antennae;
}

=head2 $receivers=LINZ::BERN::BernUtil::ReceiverList;

Returns an array or array hash of valid receiver names.

=cut

sub ReceiverList
{
    my $brndir=$ENV{X};
    my $gendir=$brndir.'/GEN';
    die "BERN environment not set\n" if ! $brndir || ! -d $gendir;

    my $recfile=$gendir.'/'.$ReceiverFile;

    open(my $af,"<$recfile") || die "Cannot find receiver file $recfile\n";

    my $receivers=[];
    my $nskip=6;
    my $line;
    while( $nskip-- && ($line=<$af>)){};

    while($line=<$af>)
    {
        last if $line=~/^REMARK\:/;
        my $rec=substr($line,0,20);
        next if $rec !~ /\S/;
        $rec =~ /\s*$/;
        push(@$receivers,$rec);
    }
    close($af);

    return wantarray ? @$receivers : $receivers;
}





1;
