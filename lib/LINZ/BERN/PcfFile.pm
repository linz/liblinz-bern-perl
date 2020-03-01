use strict;

package LINZ::BERN::PcfFile;

use Carp;

=head1 LINZ::BERN::PcfFile

Package to load a Bernese PCF file

Assumes that the Bernese environment is installed to create the $U
environment variable.  Reads from the /PCF/, /SCRIPT/ or /USERSCPT/,
and /OPT/ directories.  Can provide a search path for reference scripts
as a : separated list.

Synopsis:

  use LINZ::BERN::PcfFile

  my $pcf=LINZ::BERN::PcfFile->new('TEST.PCF');
  my $refscriptdir="$ENV{X}/GPS/USERSCPT";
  my $pcf=LINZ::BERN::PcfFile->new('TEST.PCF',$refscriptdir);

  foreach my $pid ($pcf->pids())
  {
    print $pid->{pid}.'='.$pid->{optdir},':',$pid->{script}."\n";
    my $programs=$pid->{programs};
    print "  uses: ",join(', ',@$programs),"\n";
  }

  $pid=$pcf->pid('100');

=cut

sub new
{
    my($class,$filename,$refscriptdir) = @_;
    $filename .= '.PCF' if $filename !~ /\.PCF$/;

    if( ! -e $filename )
    {
        my $ufile=$ENV{U}.'/PCF/'.$filename;
        $filename=$ufile if -e $ufile;
    }
    my $pcfname=$filename;
    $pcfname=~ s/.*[\\\/]//;
    my $pcfdir=$filename;
    $pcfdir=~s/[\\\/][^\\\/]*$//;
    my $optdir;
    my $scriptdir;
    if( $pcfdir =~ /(^|[\\\/])PCF$/ )
    {
        $optdir=substr($pcfdir,0,-3).'OPT';
        $scriptdir=substr($pcfdir,0,-3).'SCRIPT';
        if( ! -d $scriptdir )
        {
            $scriptdir=substr($pcfdir,0,-3).'USERSCPT';
        }
        $optdir='' if ! -d $optdir;
        $scriptdir='' if ! -d $scriptdir;
    }
    my $scriptdirs=[];
    push(@$scriptdirs,$scriptdir) if -d $scriptdir;
    foreach my $sd (split(':',$refscriptdir))
    {
        next if ! $sd;
        $sd .= '/USERSCPT' if -d $sd.'/USERSCPT';
        $sd .= '/GPS/USERSCPT' if -d $sd.'/GPS/USERSCPT';
        push(@$scriptdirs,$sd) if -d $sd;
    }
    if( ! scalar(@$scriptdirs) )
    {
        carp("Cannot examine scripts as script directory not found\n");
        return;
    }
    my $self=bless
    {
        pcfdir=>$pcfdir,
        optdir=>$optdir,
        scriptdirs=>$scriptdirs,
        filename=>$filename,
        pcfname=>$pcfname,
        scriptfiles=>{},
        pids=>[],

    }, $class;

    $self->read();
    return $self;
}

sub open
{
    return new(@_);
}

sub pcfname { return $_[0]->{pcfname}; }

sub filename { return $_[0]->{filename} }

sub pids
{
    my($self)=@_;
    my @pids = @{$self->{pids}};
    return wantarray ? @pids : \@pids;
}

sub pid
{
    my($self,$wanted) = @_;
    foreach my $pid (@{$self->{pids}})
    {
        return $pid if $pid->{pid} eq $wanted;
    }
    return undef;
}

sub read
{
    my($self)=@_;
    $self->{pids}=[];
    my $pids=$self->{pids};

    CORE::open(my $pcff, $self->{filename}) || croak("Cannot open PCF ".$self->{pcfname}."\n");

    my %optdirs;
    while(my $line=<$pcff>)
    {
        last if $line=~/^PID\s+USER/;
        if( $line =~ /^(\d+)\s+(\w+)\s+(\w+)/ )
        {
            push(@$pids,{pid=>$1,optdir=>$3,script=>$2,programs=>[]});
        }
    }
    close($pcff);

    # Check what programs are used by each script
    
    my $scriptdirs=$self->{scriptdirs};
    my %scripts=();

    foreach my $pid (@$pids)
    {
        my $script=$pid->{script};
        if( ! exists $scripts{$script} )
        {
            my $scriptfile;
            foreach my $sd (@$scriptdirs)
            {
                $scriptfile="$sd/$script";
                last if -e $scriptfile;
            }
            my $pgms={};
            CORE::open(my $scpf,$scriptfile) || carp("Cannot find script $script\n");
            $self->{scriptfiles}->{$script}=$scriptfile;
            if( $scpf )
            {
                my $vars={};
                while(my $line=<$scpf>)
                {
                    if( $line =~ /^\s*(?:my\s+)?\$(\w+)\s*\=\s*(['"])(\w+)\2\s*\;\s*$/ )
                    {
                        $vars->{$1}=$3;
                        next;
                    }
                    if( $line =~ /^\s*\$bpe\-\>RUN_PGMS\(\s*\$(\w+)\s*\)(?:\s|\;)/ )
                    {
                        $pgms->{$vars->{$1}}=1;
                    }
                }
                close($scpf);
            }
            my @pgmlist=sort keys %$pgms;
            $scripts{$script}=\@pgmlist;
        }
        $pid->{programs}=$scripts{$script}
    }
}

1;
