use strict;

package LINZ::BERN::PcfFile;

use Carp;

=head1 LINZ::BERN::PcfFile

Package to handle Bernese SESSIONS.SES file.

Synopsis:

  use LINZ::BERN::PcfFile

  my $pcf=LINZ::BERN::PcfFile->new('TEST.PCF')

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
    my($class,$filename) = @_;
    if( ! -e $filename )
    {
        my $ufile=$ENV{U}.'/PCF/'.$filename;
        $ufile.='.PCF' if ! -e $ufile && $ufile !~ /\.PCF$/i;
        $filename=$ufile if -e $ufile;
    }
    my $pcfname=$filename;
    $pcfname=~ s/.*[\\\/]//;
    my $self=bless
    {
        filename=>$filename,
        pcfname=>$pcfname,
        pids=>[],

    }, $class;

    $self->read();
    return $self;
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

    open(my $pcff, $self->{filename}) || croak("Cannot open PCF ".$self->{pcfname}."\n");

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
    
    my %scripts=();
    foreach my $pid (@$pids)
    {
        my $script=$pid->{script};
        if( ! exists $scripts{$script} )
        {
            my $scriptfile=$ENV{U}.'/SCRIPT/'.$script;
            my $pgms={};
            open(my $scpf,$scriptfile) || carp("Cannot open script file $scriptfile\n");
            if( $scpf )
            {
                my $vars={};
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
            }
            my @pgmlist=sort keys %$pgms;
            $scripts{$script}=\@pgmlist;
        }
        $pid->{programs}=$scripts{$script}
    }
}

1;
