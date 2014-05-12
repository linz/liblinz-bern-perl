use strict;

package LINZ::BERN::SessionFile;

use Carp;
use LINZ::GNSS::Time qw/datetime_seconds seconds_datetime time_elements/;

our $session_panel=<<EOD;
  ## widget = uniline; check_strlen.1 = 4; check_type.3 = time
  ## check_type.5 = time

# BEGIN_PANEL NO_CONDITION #####################################################
# SESSION TABLE                                                                #
#                                                                              #
#    SESSION                START EPOCH                  END EPOCH             #
#   IDENTIFIER         yyyy mm dd  hh mm ss        yyyy mm dd  hh mm ss        #
#    > %%%%            %%%%%%%%%%  %%%%%%%%        %%%%%%%%%%  %%%%%%%% <      # LIST_OF_SESSIONS
#                                                                              #
# END_PANEL ###################################################################

EOD

=head1 LINZ::BERN::SessionFile

Package to handle Bernese SESSIONS.SES file.

Synopsis:

  use LINZ::GNSS::Time qw/datetime_seconds/;

  my $filename = 'STA/SESSIONS.SES';
  my $sf = new LINZ::BERN::SessionFile( $filename );
  my $fn=$sf->filename;

  my $start=datetime_seconds('2014-02-15 23:04:00');
  my $end=datetime_seconds('2014-02-16 01:17:59');

  my ($start,$end)=$sf->sessionStartEnd($sessid,$year);

  # Create a fixed session - removes open sessions
  $sessid=$sf->addSession($start,$end,$sessflag); 

  # Get the session for a start time
  $sessid=$sf->getSession($start,$end)

  # Resets to open sessions - removes any fixed sessions
  $sf->resetDefault( $hourly ); # Sets default daily or hourly

  $sf->filename('SESSTEMP.SES');
  $sf->write();

=cut

sub new
{
    my($class,$filename) = @_;
    my $self=bless
    {
        filename=>$filename,
        sessions=>[],
    }, $class;
    if( $filename && -e $filename )
    {
        $self->read();
    }
    else
    {
        $self->resetDefault();
    }
    return $self;
}

sub filename
{
    my($self,$filename) = @_;
    $self->{filename} = $filename if $filename;
    return $self->{filename};
}

sub _parseSession
{
    my ($sessdata,$filename)=@_;
    die("Invalid session data :".$sessdata)
      if $sessdata !~ /^\s*
            \"(\?\?\?|\d\d\d)([A-Z0-9])\"
            \s+\"(\d\d\d\d\s+\d\d\s+\d\d)?\"
            \s+\"(\d\d\s+\d\d\s+\d\d)\"
            \s+\"(\d\d\d\d\s+\d\d\s+\d\d)?\"
            \s+\"(\d\d\s+\d\d\s+\d\d)\"
            \s*$/x;
    my($dayno,$flag,$startdate,$starttime,$enddate,$endtime)=($1,$2,$3,$4,$5,$6);
    die("Open session cannot have date defined\n")
        if $dayno eq '???' && ($startdate ne '' || $enddate ne '');
    die("Fixed session must have start and end date defined\n")
        if $dayno ne '???' && ($startdate eq '' || $enddate eq '');
    return {
        dayno=>$dayno,
        flag=>$flag,
        startdate=>$startdate,
        starttime=>$starttime,
        enddate=>$enddate,
        endtime=>$endtime,
    };
}

sub read
{
    my ($self) = @_;
    open(my $sessf,"<", $self->filename) || croak("Cannot open session file ".$self->filename."\n");
    my @sessdata=();
    while( my $line=<$sessf> )
    {
        next if $line !~ /^\s*LIST_OF_SESSIONS\s+(\d+)\s+(.*?)\s*$/;
        eval
        {
            if( $1 eq '1' )
            {
                push(@sessdata,_parseSession($2));
            }
            else
            {
                my $nsess=$1;
                foreach my $i (0..$1-1)
                {
                    my $data=<$sessf>;
                    $data =~ s/^\s+//;
                    $data =~ s/\s+$//;
                    push(@sessdata,_parseSession($data));
                }
            }
        };
        if( $@ )
        {
            croak($@."\nin line $. of ".$self->filename,"\n");
        }
        $self->{sessions}=\@sessdata;
    }
}

sub sessions
{
    my ($self,$sessions)=@_;
    my @sessions=@{$self->{sessions}};
    return wantarray ? @sessions : \@sessions;
}

sub _startendtime
{
    my($epoch)=@_;
    my $dstr=seconds_datetime($epoch);
    $dstr =~ s/[\-\:]/ /g;
    return (substr($dstr,0,10),substr($dstr,11,8));
}

sub addSession
{
    my($self,$starttime,$endtime,$flag)=@_;
    my($year,$gnss_week,$doy,$wday,$hour) = time_elements($starttime);
    $doy=sprintf("%03d",$doy);
    $flag=uc(substr($flag,0,1));
    my @sessdata;
    my %used={};
    foreach my $session (@{$self->{sessions}})
    {
        next if $session->{dayno} eq '???';
        push(@sessdata,$session) if $session->{dayno} ne $doy || $session->{flag} ne $flag;
        $used{$session->{flag}}=1 if $session->{dayno} eq $doy;
    }
    if( $flag eq '' )
    {
        foreach my $ff (split(//,'YZ123456789ABCDEFGHIJKLMNOPQRSTUVWX0'))
        {
            next if $used{$ff};
            $flag=$ff;
            last;
        }
    }
    croak("No session flag available for new session\n") if $flag eq '';
    my ($startdt,$starttm)=_startendtime($starttime);
    my ($enddt,$endtm)=_startendtime($endtime);
    push(@sessdata,{
            dayno=>$doy,
            flag=>$flag,
            startdate=>$startdt,
            starttime=>$starttm,
            enddate=>$enddt,
            endtime=>$endtm,
        });
    $self->{sessions}=\@sessdata;
    return $doy.$flag;
}

sub getSession
{
    my($self,$starttime)=@_;
    my($year,$gnss_week,$doy,$wday,$hour) = time_elements($starttime);
    my ($startdt,$starttm)=_startendtime($starttime);

    $doy=sprintf("%03d",$doy);
    my $sessid;
    foreach my $sess (@{$self->{sessions}})
    {
        next if $sess->{dayno} ne '???' && $sess->{dayno} ne $doy;
        next if $sess->{starttime} > $starttm;
        next if $sess->{endtime} < $starttm && $sess->{startdate} eq $sess->{enddate};
        $sessid=$doy.$sess->{flag};
    }
    return $sessid;
}

sub resetDefault
{
    my($self,$hourly)=@_;
    my $inc=$hourly ? 1 : 24;
    my $flags=$hourly ? "ABCDEFGHIJKLMNOPQRSTUVWX" : "0";
    my @sessdata=();
    my $dayno='???';
    my $hour=0;
    foreach my $flag (split(//,$flags))
    {
        my $starttime=sprintf("%02d 00 00",$hour);
        $hour += $inc;
        my $endtime=sprintf("%02d 59 59",$hour-1);
        push(@sessdata,{
            dayno=>$dayno,
            flag=>$flag,
            startdate=>'',
            starttime=>$starttime,
            enddate=>'',
            endtime=>$endtime,
        });
    }
    $self->{sessions}=\@sessdata;
}

sub sessionStartEnd
{
    my ($self,$sessid,$year) = @_;

    croak("Invalid session id $sessid passed to LINZ::GNSS::SessionFile::sessionStartEnd\n")
       if $sessid !~ /^(\d\d\d)([A-Z0-9])$/ || $1 < 1 || $1 > 366; 
    my ($dayno,$flag) = ($1,$2);
    croak("Invalid year $year passed to LINZ::GNSS::SessionFile::sessionStartEnd\n")
       if $year !~ /^\d\d\d\d$/ || $year < 1900 || $year > 2100; 

    # Look for session starting 
    foreach my $session (@{$self->{sessions}})
    {
        next if $session->{flag} ne $flag;
        if($session->{dayno} eq '???')
        {
            my $starttime=datetime_seconds("$year $dayno ".$session->{starttime});
            my $endtime=datetime_seconds("$year $dayno ".$session->{endtime});
            return ($starttime,$endtime);
        }
        elsif( $session->{dayno} eq $dayno )
        {
            my $starttime=datetime_seconds($session->{startdate}." ".$session->{starttime});
            my $endtime=datetime_seconds($session->{enddate}." ".$session->{endtime});
            return ($starttime,$endtime);
        }
    }
    croak("Session $sessid not defined in session table ".$self->filename."\n");
}

sub write
{
    my($self)=@_;
    my $count=scalar(@{$self->{sessions}});
    open(my $f,">",$self->filename) || croak("Cannot open session file ".$self->filename." for writing");
    printf $f "\nLIST_OF_SESSIONS %5d",$count;
    my $prefix=$count > 1 ? "\n    " : "  ";
    foreach my $session (@{$self->{sessions}})
    {
        print $f $prefix;
        printf $f "\"%s%s\" \"%s\" \"%s\" \"%s\" \"%s\"",
            $session->{dayno},
            $session->{flag},
            $session->{startdate},
            $session->{starttime},
            $session->{enddate},
            $session->{endtime};
    }
    print $f "\n";
    print $f $session_panel;
    close($f);
}


1;

