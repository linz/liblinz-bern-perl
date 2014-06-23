=head1 LINZ::BERN::BernUtil

Package provides utility functions to support bern processing.

=cut

use strict;

package LINZ::BERN::BernUtil;
our $VERSION='1.1.0';

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

our $LoadedAntFile='';
our $LoadedAntennae=[];

our $LoadedRecFile='';
our $LoadedReceivers=[];

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

=item FixRinexAntRec=>1

If true then the antenna and receiver types are checked to make sure they are valid,
and if they are not then the values are with best guess values using the FixRinexAntRec 
function.

=item AddNoneRadome=>1

If true then blank radome entries are replaced with NONE (redundant if FixRinexAntRec
option is selected)

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

An array of file definitions, each a hash with elements orig_filename, orig_markname, 
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
        campaigndir=>$jobdir,
        runstatus=>{},
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

                if( ref($options{RenameCodes}) eq 'ARRAY' )
                {
                    $renamecodes{''}=1;
                    foreach my $code (@{$options{RenameCodes}})
                    {
                        $renamecodes{uc($code)} = 1;
                    }
                }

                # If rename specified
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
                }
                # If only have RenameCodes specified, then try replacing characters in current 
                # code starting at the end.
                elsif( $options{RenameCodes} )
                {
                    $nextname=sub
                    {
                        my ($code)=@_;
                        return $code if ! exists $renamecodes{$code};
                        my $newcode='';
                        foreach my $i (3,2,1,0)
                        {
                            my $tmplt=substr($code,0,$i).'%0'.(4-$i).'d';
                            my $max=10**(4-$i)-1;
                            foreach my $j (1..$max)
                            {
                                my $test=sprintf($tmplt,$j);
                                if( ! exists $renamecodes{$test} )
                                {
                                    $newcode=$test;
                                    last;
                                }
                            }
                            last if $newcode ne '';
                        }
                        if( $newcode eq '' )
                        {
                            croak("Cannot generate alternative name for $code\n");
                        }
                        return $newcode;
                    };
                    $rename=1;
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
                        $codemap{$rawcode}=$nextname->($rawcode) if ! exists $codemap{$rawcode};
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

                    my $anttype=sprintf("%-20.20s",$rf->anttype);
                    my $rectype=$rf->rectype;

                    my $srcanttype=$anttype;
                    my $srcrectype=$rectype;

                    if( $options{FixRinexAntRec} )
                    {
                        my $edits=FixRinexAntRec($rf);
                        $anttype=$edits->{antenna}->{to} if exists $edits->{antenna};
                        $rectype=$edits->{receiver}->{to} if exists $edits->{receiver};
                    }
                    elsif( $options{AddNoneRadome} )
                    {
                        substr($anttype,16,4)='NONE' if substr($anttype,16,4) eq '    ';
                        $rf->anttype($anttype);
                    }

                    my $dehn=$rf->delta_hen;
                    my $antheight=0.0;
                    $antheight=$dehn->[0] if ref($dehn);

                    $rf->markname($rawcode);
                    $rf->write("$jobdir/RAW/$rawname");

                    push(@files, {
                        orig_filename=>$srcfile,
                        orig_markname=>$srccode,
                        orig_anttype=>$srcanttype,
                        orig_rectype=>$srcrectype,
                        filename=>$rawname,
                        markname=>$rawcode,
                        anttype=>$anttype,
                        antheight=>$antheight,
                        rectype=>$rectype,
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

This adds two elements to the campaign hash:

=over

=item runstatus

The status returned by LINZ::BERN::RunPcfStatus

=item bernese_status

The status returned by the startBPE object ERROR_STATUS variable

=back

The script returns the bernese error status, which is if the script completes
successfully.

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
    $bpe->{CPU_FILE}=$options{CPU_FILE} || 'USER';
    $bpe->{S_CPU_FILE}=$options{CPU_FILE} || 'USER';
    $bpe->{PCF_FILE}=$pcf;
    $bpe->{SESSION}=$campaign->{SES_INFO};
    $bpe->{YEAR}=$campaign->{YR4_INFO};

    $bpe->{SYSOUT}=$pcf;
    $bpe->{STATUS}=$pcf.'.SUM';

    $bpe->resetCPU();
    $bpe->resetCPU($bpe->{S_CPU_FILE});
    
    $bpe->run();

    $campaign->{bernese_status}=$bpe->{ERROR_STATUS};
    my $result=LINZ::BERN::BernUtil::RunPcfStatus($campaign);
    $campaign->{runstatus}=$result;
    return $campaign->{bernese_status};
}

=head2 $result=LINZ::BERN::BernUtil::RunPcfStatus($campaign)

Attempt to find the information about script failure from the BPE log files

The parameter can be either a campaign returned by LINZ::BERN::BernUtil::CreateCampaign,
or the name of a campaign directory.

Returns a hash with the following possible keys:

=over

=item status

The status of the run, OK or ERROR

=item fail_pid

The pid of the step at which the script failed

=item fail_script

The name of the script in which the failure occured

=item fail_prog

The program in which the failure occurred

=item fail_message

The message returned by the program when it failed.

=back

The fail_prog and fail_message are interpreted from the script log file.

=cut


sub RunPcfStatus
{
    my($campaigndir)=@_;
    if( ref($campaigndir) )
    {
        $campaigndir=$campaigndir->{campaigndir};
    }
    $campaigndir=$ENV{P}."/$campaigndir" if $campaigndir=~/^\w+$/ && exists $ENV{P};
    my $campdirname=$campaigndir;
    $campdirname=~ s/.*[\\\/]//;
    $campdirname='${P}/'.$campdirname;

    my $bpedir=$campaigndir.'/BPE';
    croak("Campaign BPE directory $campdirname/BPE is missing\n") if ! -e $bpedir;

    my %logs=();
    my @out=();
    opendir(my $bd,$bpedir) || return;
    foreach my $f (readdir($bd))
    {
        my $bf=$bpedir.'/'.$f;
        push(@out,$bf) if -f $bf && $f=~/\.OUT$/;
        $logs{$1}=$bf if -f $bf && $f=~ /_(\d\d\d_\d\d\d).LOG$/;
    }
    closedir($bd);
    @out = sort { -M $a <=> -M $b } @out;

    # Read the run output directory

    croak("Cannot find BPE output file in $bpedir\n") if ! @out;

    my $sysout=$out[0];
    open(my $sof,"<$sysout") || croak("Cannot open BPE output file $sysout\n");
    my $header=<$sof>;
    my $spacer=<$sof>;
    croak("$sysout doesn't seem to be a BPE SYSOUT file\n") 
        if $header !~ /^\s*time\s+sess\s+pid\s+script\s+option\s+status\s*$/i;

    my $failrun='';
    my $runstatus='OK';
    while( my $line=<$sof> )
    {
        my ($run,$status) = split(/\s+\:\s+/,$line);
        next if $status !~ /^script\s+finished\s+(\w+)/i;
        $runstatus=$1;
        if( $runstatus ne 'OK')
        {
            $failrun=$run;
            last;
        }
    }
    close($sof);

    my $result={ status=>$runstatus };

    if( $runstatus ne 'OK' )
    {
        my($date,$time,$sess,$pidr,$script,$option)=split(' ',$failrun);
        my $pid=$1 if $pidr=~/^(\d+)/;
        my $lfile=$logs{$pidr};
        my $prog='';
        my $failure='';
        if( $lfile && open( my $lf, "<$lfile"))
        {
            while(my $line=<$lf>)
            {
                $prog=$1 if $line =~ /Call\s+to\s+(\w+)\s+failed\:/i;
                if( $line =~ /^\s*\*\*\*\s.*?\:\s*(.*?)\s*$/ )
                {
                    $failure .= '/ '.$1;
                    while( $line = <$lf> )
                    {
                        last if $line =~ /^\s*$/;
                        $line=~ s/^\s*//;
                        $line=~ s/\s*$//;
                        $failure .= ' '.$line;
                    }
                    last if ! $line;
                }
            }
        }
        $result->{fail_pid}=$pid;
        $result->{fail_script}=$script;
        $result->{fail_prog}=$prog;
        $result->{fail_message}=substr($failure,2);
    }

    return $result;
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
    if( $antfile ne $LoadedAntFile )
    {
        $LoadedAntennae=[];
        open(my $af,"<$antfile") || die "Cannot find antenna file $antfile\n";

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
            push(@$LoadedAntennae,$ant);
        }
        close($af);
    }
    my @antennae=@$LoadedAntennae;

    return wantarray ? @antennae : \@antennae;
}

=head2 $antenna=LINZ::BERN::BernUtil::BestMatchingAntenna($ant)

Return the best matching antenna to the supplied antenna.
The best match is based upon the maximum number of matched leading characters,
and the first in alphabetical order if there is a tie.  The radome
supplied is preferred, otherwise a match with none is used.

=cut

sub BestMatchingAntenna
{
    my($ant)=@_;
    $ant=uc($ant);
    $ant=substr($ant.(' 'x20),0,20);
    my $radome=substr($ant,16);
    $ant=substr($ant,0,16);
    $radome = 'NONE' if $radome eq '    ';

    my %validAnt = map {$_=>1} AntennaList();
    return $ant.$radome if exists $validAnt{$ant.$radome};
    return $ant.'NONE' if exists $validAnt{$ant.'NONE'};

    # Build a regular expression to match as much of
    # the antenna string as possible;

    my $repre='^(';
    my $resuf=')';
    foreach my $c (split(//,$ant))
    {
        $repre .= '(?:'.quotemeta($c);
        $resuf = ')?'.$resuf;
    }
    my $re=$repre.$resuf;

    my $maxmatch=-1;
    my $matchant='';
    foreach my $vldant (sort keys %validAnt)
    {
        $vldant=~/$re/;
        my $nmatch=length($1)*2;
        $nmatch++ if substr($vldant,16) eq $radome;
        if( $nmatch > $maxmatch )
        {
            $maxmatch=$nmatch;
            $matchant=$vldant;
        }
    }
    return $matchant;
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
    if( $recfile ne $LoadedRecFile )
    {
        $LoadedReceivers=[];

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
            $rec =~ s/\s*$//;
            push(@$LoadedReceivers,$rec);
        }
        close($af);
    }

    my @receivers=@$LoadedReceivers;

    return wantarray ? @receivers : \@receivers;
}

=head2 $receiver=LINZ::BERN::BernUtil::BestMatchingReceiver($rec)

Return the best matching receiver to the supplied receiver.
The best match is based upon the maximum number of matched leading characters,
and the first in alphabetical order if there is a tie.  

=cut

sub BestMatchingReceiver
{
    my($rec)=@_;
    $rec=uc($rec);
    $rec=~ s/\s+$//;

    my %validRec = map {$_=>1} ReceiverList();
    return $rec if exists $validRec{$rec};

    # Build a regular expression to match as much of
    # the antenna string as possible;

    my $repre='^(';
    my $resuf=')';
    foreach my $c (split(//,$rec))
    {
        $repre .= '(?:'.quotemeta($c);
        $resuf = ')?'.$resuf;
    }
    my $re=$repre.$resuf;

    my $maxmatch=-1;
    my $matchrec='';
    foreach my $vldrec (sort keys %validRec)
    {
        $vldrec=~s/
        $vldrec=~/$re/;
        my $nmatch=length($1);
        if( $nmatch > $maxmatch )
        {
            $maxmatch=$nmatch;
            $matchrec=$vldrec;
        }
    }
    return $matchrec;
}


=head2 $edits=LINZ::BERN::BernUtil::FixRinexAntRec( $rinexfile )

Fixes a RINEX observation file to ensure that the antenna and receivers
are valid.  $rinexfile may be either a filename, in which case the file 
is overwritten, or a LINZ::GNSS::RinexFile object, in which case the 
receiver and antennae fields are updated.

Returns a hash ref with a list of edits structured as 

   { item=> { from=>'xxx1', to=>'xxx2'}, ...  }

where item is may be "antenna" or "receiver".

=cut

sub FixRinexAntRec
{
    my( $rinexfile) = @_;
    my $edits={};
    my $rx = $rinexfile;

    $rx=new LINZ::GNSS::RinexFile( $rinexfile, skip_obs=>1 ) if ! ref($rinexfile);

    my $rnxant=$rx->anttype;
    my $rnxrec=$rx->rectype;

    my $vldant=BestMatchingAntenna($rnxant);
    my $vldrec=BestMatchingReceiver($rnxrec);
    
    return $edits if $vldant eq $rnxant && $vldrec eq $rnxrec;

    $rx->anttype($vldant);
    $rx->rectype($vldrec);

    $edits->{antenna} = {from=>$rnxant, to=>$vldant} if $rnxant ne $vldant;
    $edits->{receiver} = {from=>$rnxrec, to=>$vldrec} if $rnxrec ne $vldrec;

    if( ! ref($rinexfile) )
    {
        my $tmpfile=$rinexfile.'.rnxtmp';
        $rx->write($tmpfile);
        if( -f $tmpfile )
        {
            unlink($rinexfile) || croak("Cannot replace $rinexfile\n");
            rename($tmpfile,$rinexfile) || croak("Cannot rename $tmpfile to $rinexfile\n");
        }
    }
    return $edits;
}



1;
