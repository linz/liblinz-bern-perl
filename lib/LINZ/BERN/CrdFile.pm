use strict;

package LINZ::BERN::CrdFile;

=head1 LINZ::BERN::CrdFile

Package to handle Bernese .CRD files.

Synopsis:

  my $fn = 'STA/TEST.CRD';
  my $cf = new LINZ::BERN::CrdFile( $filename );
  foreach my $stn ($cf->stations())
  {
    my $xyz=$stn->xyz();
    my $name=$stn->name();
    my $flag=$stn->flag();
    my $code=$stn->code();
    my $abb2=$stn->abb2();

    $stn->flag('Bad');
    $stn->xyz([-5171804.7406,574169.1541,-3675912.2389]);
  }

  $cf->add('Name of test','TEST',[-5171804.7406,574169.1541,-3675912.2389],'Ok');

  my $name='TEST 05000M0000';
  my $code='TST2';               # 4 letter abbreviation (not written to .CRD file)
  my $new2 = LINZ::BERN::CrdFile::Station($name,$code,[-5171804.7406,574169.1541,-3675912.2389],'Ok');
  $cf->add($new2);

  my $teststn=$cf->station('TEST');

  $cf->filename('STA/UPDATE.CRD');
  $cf->datum('IGb08');
  $cf->epoch($timestamp);
  $cf->write();

  # Note: this creates/updates the code and abb2 members
  $cf->createAbbreviations();
  $cf->writeAbbreviations($filename);

=cut

use Carp;
use LINZ::GNSS::Time qw/datetime_seconds seconds_datetime/;

sub new
{
    my($class,$filename) = @_;
    my $self=bless
    {
        filename=>$filename,
        datum=>'IGb08',
        epoch=>'2005-01-01 00:00:00',
        stations=>[],
        index=>{},
    }, $class;
    if( $filename && -e $filename )
    {
        $self->read();
    }
    return $self;
}

sub filename
{
    my($self,$filename) = @_;
    $self->{filename} = $filename if $filename;
    return $self->{filename};
}

sub datum
{
    my($self,$datum) = @_;
    $self->{datum} = $datum if $datum;
    return $self->{datum};
}

sub epoch
{
    my($self,$epoch) = @_;
    $self->{epoch} = $epoch if $epoch;
    return $self->{epoch};
}

sub stations
{
    my($self)=@_;
    return wantarray ? @{$self->{stations}} : $self->{stations};
}

sub station
{
    my ($self,$code) = @_;
    return $self->{index}->{$code};
}

sub add
{
    my($self,@stndata) = @_;
    my $stn;
    if( ref($stndata[0]) eq 'LINZ::BERN::CrdFile::Station' )
    {
        $stn=$stndata[0];
    }
    else
    {
        $stn = LINZ::BERN::CrdFile::Station->new(@stndata);
    }

    my $stns=$self->{stations};
    my $name=$stn->{name};

    if( exists($self->{index}->{$name}) )
    {
        foreach my $i (0 .. $#$stns)
        {
            next if $stns->[$i]->name ne $name;
            $stns->[$i] = $stn;
            last;
        }
    }
    else
    {
        push(@$stns,$stn);
    }
    $self->{index}->{$name}=$stn;
}
    

sub read
{
    my($self,$filename) = @_;
    $filename ||= $self->{filename};
    open(my $f, $filename) || croak("Cannot open BERN coordinate file $filename");
    my $line=<$f>;
    $line=<$f>;
    $line=<$f>;
    $line=~ /^\s*LOCAL\s+GEODETIC\s+DATUM\:\s+(\w.*?)\s+EPOCH\:\s+(\d\d\d\d\-\d\d\-\d\d\s+\d\d\:\d\d\:\d\d)\s*$/i
        || croak("Invalid datum line $line in BERN CRD file $filename");
    my ($datum,$epoch)=($1,$2);
    $self->{filename} = $filename;
    $self->{datum} = $datum;
    $self->{epoch} = datetime_seconds($epoch);
    $self->{stations} = [];
    $self->{index} = {};

    $line=<$f>;
    $line=<$f>;
    $line=<$f>;
    my $nline=6;
    while($line=<$f>)
    {
        last if $line =~ /^\s*$/;
        $nline++;
        $line =~ /^(.{0,3})\s\s(.{0,16})(.{0,15})(.{0,15})(.{0,15})\s{1,4}([^\s]*)?\s*$/
            || croak("Invalid coordinate data $line in BERN CRD file $filename:$nline");
        my($id,$name,$x,$y,$z,$flag) = ($1,$2,$3,$4,$5,$6);
        $name=~ s/^\s+//;
        $name=~ s/\s+$//;
        my $code;
        if( $name=~/^(\w{4})(?:\s|$)/ )
        {
            $code=uc($1);
        }
        else
        {
            carp("Station name does not start with code in file $filename:$nline");
            $code=$name;
            $code =~ s/\s//g;
            $code = uc(substr($code.'0000',0,4));
        }
        my $xyz=[];
        foreach my $ord ($x,$y,$z)
        {
            $ord=~/^\s*(\-?\d+\.\d+)\s*$/
              || croak("Invalid coordinate $ord in BERN CRD file $filename:$nline");
            push(@$xyz,$ord);
        }
        $self->add($name,$code,$xyz,$flag);
    }
}


sub _fileDate
{
    my @months=qw/JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC/;
    my ($d,$m,$y) = (localtime())[3,4,5];
    my $date=sprintf("%02d-%s-%04d",$d,$months[$m],$y+1900);
    return $date;
}

sub write
{
    my($self,$filename) = @_;
    $filename ||= $self->{filename};
    open(my $f, ">$filename" ) || croak("Cannot open output BERN coordinate file $filename");
    printf $f "%-68.68s %s\n",$self->{datum}." coordinates",_fileDate();
    print $f "-"x80,"\n";
    my $dts=seconds_datetime($self->{epoch});
    printf $f "LOCAL GEODETIC DATUM: %-17.17s EPOCH: %s\n",$self->{datum},$dts;
    print $f "\nNUM  STATION NAME           X (M)          Y (M)          Z (M)     FLAG\n\n";
    my $ns=0;
    foreach my $s (@{$self->{stations}})
    {
        $ns++;
        my $xyz=$s->xyz;
        printf $f "%.3d  %-15.15s %15.5f%15.5f%15.5f    %s\n",
            $ns,$s->name,$xyz->[0],$xyz->[1],$xyz->[2],$s->{flag};
    }
}

sub createAbbreviations
{
    my($self)=@_;
    # Ensure codes are unique

    my @chars=qw(0 1 2 3 4 5 6 7 8 9 A B C D E F G H I J K L M N O P Q R S T U V W X Y Z);
    my %scodes=();
    my @bcodes=();

    foreach my $s (@{$self->stations})
    {
        my $code=$s->code;
        if( exists($scodes{$code}) )
        {
            push(@bcodes,$s);
        }
        else
        {
            $scodes{$code}=1;
        }
    }

    foreach my $s (@bcodes)
    {
        my $codebase=substr($s->code,0,2);
        my $code='';
        foreach my $c1 (@chars)
        {
            foreach my $c2 (@chars)
            {
                $code=$codebase.$c1.$c2;
                last if ! exists($scodes{$code});
                $code='';
            }
            last if $code ne '';
        }
        my $name=$s->name;
        croak("Cannot find unique 4 char code for station $name\n") if $code eq '';
        $scodes{$code}=1;
        $s->code($code);
    }


    # Codes is lookup code->abbreviation
    # cabb is restructured code to select preferred characters for abbreviations
    # abb2s tracks abbreviations already used
    my %codes=();
    my %cabb=();
    my %abb2s=();
    my $missing=0;
    foreach my $s (@{$self->{stations}})
    {
        my $code=$s->code;
        my $abb2=$s->abb2;
        $abb2='' if exists $abb2s{$abb2};
        $codes{$code}=$abb2;
        $abb2s{$abb2}=1 if $abb2 ne '';
        next if $abb2 ne '';
        $missing++;

        # Order characters after the first in preference for creating abbreviations,
        # consonants, vowels, numberic (without leading zeroes)
        my $c1=substr($code,1);
        my $c2=$c1;
        $c2=~s/[^BCDFGHJ-NP-TV-Z]//g;
        my $c3=$c1;
        $c3=~s/[^AEIOU]//g;
        my $c4=$c1;
        $c4=~s/[A-Z]//g;
        $c4=~s/^(0+)([1-9]\d*)/$2$1/;
        $cabb{$code}=substr($code,0,1).$c2.$c3.$c4;
    }
    return if ! $missing;

    # Try and assign using the first letter and another letter from the code

    foreach my $i (1..3)
    {
        foreach my $code (sort keys %codes)
        {
            next if $codes{$code} ne '';
            my $abb2=substr($code,0,1).substr($cabb{$code},$i,1);
            next if exists($abb2s{$abb2});
            $codes{$code}=$abb2;
            $abb2s{$abb2}=1;
            $missing--;
        }
        last if ! $missing;
    }

    # Try the first letter and anything

    if( $missing )
    {
        foreach my $code (sort keys %codes)
        {
            next if $codes{$code} ne '';
            my $c1=substr($code,0,1);
            foreach my $c2 (@chars)
            {
                my $abb2=$c1.$c2;
                next if exists $abb2s{$abb2};
                $codes{$code}=$abb2;
                $abb2s{$abb2}=1;
                $missing--;
                last;
            }
        }
    }

    # Now try any combination of character and digit

    if( $missing )
    {
        my @newabb=();
        foreach my $c2 (@chars)
        {
            foreach my $c1 (@chars)
            {
                my $abb2=$c1.$c2;
                next if exists($abb2s{$abb2});
                push(@newabb,$abb2);
                $missing--;
                last if ! $missing;
            }
            last if ! $missing;
        }
        foreach my $code (sort keys %codes)
        {
            next if $codes{$code} ne '';
            my $abb2=shift(@newabb);
            $missing++ if $abb2 eq '';
            $codes{$code}=$abb2;
            $abb2s{$abb2}=1;
        }
    }

    foreach my $s (@{$self->{stations}})
    {
        $s->abb2($codes{$s->code});
    }

    croak("Unable to generate unique 2 char abbreviations\n") if $missing;
}

sub writeAbbreviationFile
{
    my($self,$filename) = @_;
    $self->createAbbreviations();
    open( my $f, ">$filename") || croak("Cannot create abbreviation file $filename\n");
    printf $f "Station abbreviation file                                        %s\n",_fileDate();
    print $f "--------------------------------------------------------------------------------\n";
    print $f "\n";
    print $f "Station name             4-ID    2-ID    Remark                                 \n";
    print $f "****************         ****     **     ***************************************\n";
    foreach my $s ($self->stations)
    {
        printf $f "%-16.16s         %-4.4s     %-2.2s\n",$s->name,$s->code,$s->abb2;
    }
    close($f);
}

package LINZ::BERN::CrdFile::Station;

use Carp;
use fields qw( code name xyz flag abb2 );

sub new
{
    my ($self,$name,$code,$xyz,$flag) = @_;
    $name =~ s/^\s+//;
    $name =~ s/\s+$//;
    croak("Invalid name in LINZ::Bern::CrdFile::Station::new") if $name eq '';
    croak("Invalid coordinate in LINZ::Bern::CrdFile::Station::new") if ! ref($xyz);
    $self=fields::new($self) unless ref $self;
    $self->name($name);
    $self->code($code);
    $self->xyz($xyz);
    $self->flag($flag);
    $self->abb2('');
    return $self;
}

sub code
{
    my($self,$code) = @_;
    if( defined($code) )
    {
        $code =~ s/^\s+//;
        $code =~ s/\s+$//;
        $code = uc($code);
        croak("Invalid code in LINZ::Bern::CrdFile::Station::new") if 
           $code !~ /^(\w\w\w\w)?$/;
        $self->{code} = $code;
    }
    return $self->{code};
}

sub abb2
{
    my($self,$abb2) = @_;
    if( defined($abb2) )
    {
        $abb2 =~ s/^\s+//;
        $abb2 =~ s/\s+$//;
        $abb2 = uc($abb2);
        croak("Invalid short code in LINZ::Bern::CrdFile::Station::new") if 
           $abb2 !~ /^(\w\w)?$/;
        $self->{abb2} = $abb2;
    }
    return $self->{abb2};
}

sub name
{
    my($self,$name) = @_;
    if( defined($name) )
    {
        $name =~ s/^\s+//;
        $name =~ s/\s+$//;
        $self->{name} = $name;
    }
    return $self->{name};
}

sub xyz
{
    my($self,$xyz) = @_;
    if( defined($xyz) )
    {
        croak("Invalid coordinate in LINZ::Bern::CrdFile::Station::new") if ! ref($xyz);
        $self->{xyz} = $xyz;
    };
    return $self->{xyz};
}

sub flag
{
    my($self,$flag) = @_;
    $self->{flag} = $flag if defined($flag);
    return $self->{flag};
}


1;

