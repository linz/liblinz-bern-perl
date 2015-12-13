use strict;

package LINZ::BERN::StationFile;

use Carp;
use LINZ::GNSS::Time qw/ymdhms_seconds seconds_ymdhms time_elements/;

=head1 LINZ::BERN::StationFile

Package to handle Bernese Station Information (STA) files

Synopsis:

  use LINZ::BERN::StationFile;
  use LINZ::GNSS::Time qw/datetime_seconds/;

  my $filename = 'STA/EXAMPLE.SES';
  my $sf = new LINZ::BERN::StationFile( $filename );

  # Trim the station information to the specified range
  # (eg for station information extracted from RINEX file)
  $sf->selectDates( $starttime, $endtime );

  # Set station renaming for code to name
  $sf->renameStation($code,$name);

  # Merge station information with data from another file.  
  # Returns a list text strings defining differences between the files
  $sf->mergeStationInformation( $other );

  $sf->write( $filename );

=cut

our $blockFields={
    '001'=>[
    {field=>"name",id=>"STATION NAME"},
    {field=>"flag",id=>"FLG",default=>'001'},
    {field=>"starttime",id=>"FROM"},
    {field=>"endtime",id=>"TO"},
    {field=>"srcname",id=>"OLD STATION NAME"},
    {field=>"remark",id=>"REMARK"},
    ],

    '002'=>[
    {field=>"name",id=>"STATION NAME"},
    {field=>"flag",id=>"FLG"},
    {field=>"starttime",id=>"FROM"},
    {field=>"endtime",id=>"TO"},
    {field=>"rectype",id=>"RECEIVER TYPE",default=>"*** UNDEFINED ***"},
    {field=>"recserno",id=>"RECEIVER SERIAL NBR",default=>"999999"},
    {field=>"recno",id=>"REC #"},
    {field=>"anttype",id=>"ANTENNA TYPE",default=>"*** UNDEFINED ***"},
    {field=>"antserno",id=>"ANTENNA SERIAL NBR",default=>"999999"},
    {field=>"antno",id=>"ANT #"},
    {field=>"ecc_n",id=>"NORTH",default=>"999.9999"},
    {field=>"ecc_e",id=>"EAST",default=>"999.9999"},
    {field=>"ecc_u",id=>"UP",default=>"999.9999"},
    {field=>"description",id=>"DESCRIPTION"},
    {field=>"remark",id=>"REMARK"},
    ],

    '003'=>[
    {field=>"name",id=>"STATION NAME"},
    {field=>"flag",id=>"FLG"},
    {field=>"starttime",id=>"FROM"},
    {field=>"endtime",id=>"TO"},
    {field=>"remark",id=>"REMARK"},
   ],
   };

sub _headerFormat
{
    my($header,$format)=@_;
    my %found=();
    foreach my $line (@{$header}[0 .. $#$header-1])
    {
        foreach my $f (@{$format})
        {
            next if exists $found{$f->{field}};
            my $pos=index($line,$f->{id});
            $found{$f->{field}}={col=>$pos,default=>$f->{default}} if $pos >= 0;
        }
    }
    my $template=$header->[-1];
    $template=~s/(Y+\s+M+\s+D+\s+H+\s+M+\s+S+)/'*' x length($1)/eig;
    $template=~s/\*\./**/g;
    $template=~s/\s/ /g;
    $template=~s/[^\*\s]/ /g;
    my $end=0;
    foreach my $m ( $template =~ /(\*+|\s+)/g )
    {
        my $start=$end;
        $end += length($m);
        next if $m !~ /\*/;
        foreach my $f (values %found)
        {
            if( $f->{col} >=$start && $f->{col} < $end )
            {
                $f->{col} = $start;
                $f->{len} = $end-$start;
            }
        }
    }
    foreach my $f (@$format )
    {
        $found{$f->{field}}={col=>-1} if ! exists $found{$f->{field}};
    }
    return \%found;
}

sub _readData
{
    my($staf,$format)=@_;
    my @data;
    while (my $line = <$staf> )
    {
        last if $line =~ /^\s*$/;
        my $record={};
        while (my ($field,$pos)=each %$format)
        {
            my $value=$pos->{col} >= 0 ? substr($line,$pos->{col},$pos->{len}) : '';
            $value='' if $value eq $pos->{default};
            $value =~ s/\s+$//;
            $value =~ s/^\s+//;
            $record->{$field}=$value;
        }
        push(@data,$record);
    }
    return \@data;
}

sub _cleanName
{
    my($name)=@_;
    $name =~ s/\s+$//;
    $name =~ s/^\s+//;
    $name = uc($name);
    return $name;
}

sub _offsetTime
{
    my($time,$offset)=@_;
    my($y,$m,$d,$hh,$mm,$ss)=split(' ',$time);
    my $seconds=ymdhms_seconds($y,$m,$d,$hh,$mm,$ss)+$offset;
    return sprintf("%04d %02d %02d %02d %02d %02d",
        seconds_ymdhms($seconds));
}

sub _mergeBlockData
{
    my($self,$blockid,$key)=@_;
    my @errors=();
    $key //= 'name';

    my @data=$self->_blockdata($blockid);
    my %names=();
    foreach my $item (@data)
    {
        my $name=_cleanName($item->{$key});
        $item->{$key}=$name;
        $names{$name}=[] if not exists $names{$name};
        push(@{$names{$name}},$item);
    }
    foreach my $name (keys %names)
    {
        my @data=sort {$a->{starttime} cmp $b->{starttime} || 
            ($a->{endtime} || '2999') cmp ($b->{endtime} || '2999')} 
            @{$names{$name}};
        next if scalar(@data) < 2;
        my @merged=();
        foreach my $i (0 .. $#data-1)
        {
            my $d0=$data[$i];
            my $d1=$data[$i+1];
            if( ($d0->{endtime} || 2999) >= $d1->{starttime} ) 
            {
                my $different=0;
                foreach my $k (keys %$d0)
                {
                    next if $k eq 'starttime' || $k eq 'endtime' || $d0->{$k} eq $d1->{$k};
                    my $error="$k different from ".$d1->{starttime}.
                        " to ".($d0->{endtime} || '2999').": \"".
                        $d0->{$k}."\" vs \"".$d1->{$k}."\"";
                    if( $k eq 'remark' )
                    {
                        $error='Warning: '.$error;
                    }
                    else
                    {
                        $different=1;
                    }
                    if( $different )
                    {
                        $d0->{endtime}=_offsetTime($d1->{starttime},-1);
                        push(@merged,$d0);
                    }
                    else
                    {
                        $d1->{starttime}=$d0->{starttime}
                    }
                    
                }
            }
        }
        push(@merged,$data[$#data]);
        $names{$name}=\@merged;
    }
    my @data=();
    foreach my $name ( sort keys %names )
    {
        push(@data,@{$names{$name}});
    }
    $self->_blockdata($blockid,@data);

    return @errors ? \@errors : undef;
}

sub _copy
{
    my($data)=@_;
    my %copy=%$data;
    return \%copy;
}

sub _applyNameMap
{
    my($self,$data)=@_;
    my $renames=$self->renames;
    my @mapped=();
    my @torename=@$data;
    while my $d (shift @torename)
    {
        my $name=_cleanName($d->{name});
        my $starttime=$d->{starttime};
        my $endtime=$d->{endtime} || '2999';
        my $used=0;
        foreach my $rename (@$renames)
        {
            my $srcname=$rename->{srcname};
            next if $rename->{starttime} > $endtime;
            next if $rename->{endtime} && ($rename->{endtime} < $starttime);
            $matched=$srcname eq $name;
            $matched=1 if ! $matched 
                && $srcname =~ /\*$/ 
                && substr($name,0,length($srcname-1)) eq substr($srcname,0,length($srcname)-1);
            next if ! $matched;

            $used=1;
            if( $rename->{endtime} && ($rename->{endtime} < $endtime) )
            {
                my $after=_copy($d);
                $after->{starttime}=_offsetTime($rename->{endtime},1);
                unshift(@torename,$after);
                $endtime=$rename->{endtime};
            }
            if( $rename->{starttime} > $starttime )
            {
                my $before=_copy($d);
                $before->{endtime}=_offsetTime($rename->{starttime},-1);
                unshift(@torename,$before);
                $starttime=$rename->{starttime};
            }
            my $renamed=_copy($d);
            $renamed->{starttime}=$starttime;
            $renamed->{endtime}=$endtime;
            $renamed->{name}=$rename->{name};
            push(@mapped,$renamed);
            $used=1;
            last;
        }
        push(@mapped,_copy($d)) if ! $used;
    }
    return \@mapped;
}

sub _mergeData
{
    my($self)=@_;
    my @errors=();
    
    foreach my $blockid (keys %$blockFields )
    {
        my $key = $blockid eq '001' ? 'srcname' : 'name';
        my $blockerrors=$self->_mergeBlockData( $blockid, $key );
        push(@errors,@$blockerrors) if $blockerrors;
    }
    return @errors ? \@errors : undef;
}

sub _writeData
{
    my($staf,$format,$data)=@_;
    my $reclen=0;
    foreach my $pos (values %$format)
    {
        my $endcol=$pos->{col}+$pos->{len};
        $reclen = $endcol if $endcol > $reclen;
    }
    foreach my $d (@$data)
    {
        my $line=' 'x$reclen;
        foreach my $field (keys %$format)
        {
            my $pos=$format->{$field};
            next if $pos->{col} < 0;
            my $value=$d->{$field};
            $value=$pos->{default} if $value eq '';
            substr($line,$pos->{col},$pos->{len})=sprintf("%-*.*s",$pos->{len},$pos->{len},$value);
        }
        $line =~ s/\s*$/\n/;
        print $staf $line;
    }
}

sub _readBlock
{
    my($staf,$header,$blockid)=@_;
    my $fields=$blockFields->{$blockid};
    my $format=$fields ? _headerFormat($header,$fields) : undef;
    my $data;
    if( $format )
    {
        $data=_readData($staf,$format)
    }
    else
    {
        $data=[];
        while( my $line = <$staf> )
        {
            last if $line =~ /^\s*$/;
            push(@$data,$line);
        }
    
    }
    my $block={blockid=>$blockid,header=>$header,format=>$format,data=>$data};
    return $block;
}

sub _writeBlock
{
    my($staf,$block)=@_;
    print $staf @{$block->{header}};
    if( $block->{format} )
    {
        _writeData($staf,$block->{format},$block->{data});
    }
    else
    {
        print $staf @{$block->{data}};
    }
    print $staf "\n";
}

sub new
{
    my($class,$filename) = @_;
    my $self=bless
    {
        filename=>$filename,
    }, $class;
    $self->read();
    return $self;
}

sub filename
{
    my($self,$filename) = @_;
    $self->{filename} = $filename if $filename;
    return $self->{filename};
}

sub read
{
    my ($self) = @_;
    open(my $staf,"<", $self->filename) || croak("Cannot open station information file ".$self->filename."\n");
    my @sessdata=();
    
    my $title=<$staf>;
    my $started=0;
    $self->{title}=$title;
    my $header=[];
    my $blocks={};
    $self->{format}='1.00';
    $self->{header}=$header;
    $self->{blocks}=$blocks;
    while( my $line=<$staf> )
    {
        if( $line =~ /^\s*TYPE\s+(\d\d\d)\:.*$/ )
        {
            $started=1;
            my $blockid=$1;
            my $header=[$line];
            while( $line=<$staf> )
            {
                push(@$header,$line);
                last if $line =~ /^\*\*\*\*\*\*\*/;
            }
            $blocks->{$blockid}=_readBlock($staf,$header,$blockid);
        }
        elsif( ! $started )
        { 
            $self->{format}=$1 if $line =~ /^FORMAT\S+VERSION\:\s+(\S+)\s*$/;
            push(@$header,$line);
        }
    }
    close($staf);
}

sub write
{
    my($self,$filename)=@_;
    $filename ||= $self->{filename};
    open( my $staf, ">", $filename ) || croak("Cannot open output station information file $filename\n");
    print $staf $self->{title};
    print $staf @{$self->{header}};
    foreach my $blockid (sort keys %{$self->{blocks}})
    {
        _writeBlock($staf,$self->{blocks}->{$blockid});
    }
    close($staf);
}

sub _blockdata
{
    my($self,$blockid,@data)=@_;
    if( defined($data[0]))
    {
        @data=@{$data[0]} if ref($data[0]) eq 'ARRAY';
        my $update=[];
        foreach my $d (@data)
        {
            push(@$update,$d) if ref($d) eq 'HASH';
        }
        $self->{blocks}->{$blockid}->{data}=$update;
    }
    my $blockdata=$self->{blocks}->{$blockid}->{data};
    return wantarray ? @$blockdata : $blockdata;
}

sub renames
{
    my($self,@data)=@_;
    my $blockdata=$self->_blockdata('001',@data);
    return wantarray ? @$blockdata : $blockdata;
}

sub stationinfo
{
    my($self,@data)=@_;
    my $blockdata=$self->_blockdata('002',@data);
    return wantarray ? @$blockdata : $blockdata;
}

sub problems
{
    my($self,@data)=@_;
    my $blockdata=$self->_blockdata('003',@data);
    return wantarray ? @$blockdata : $blockdata;
}

sub selectDates
{
    my($self,$starttime,$endtime)=@_;
    my $startstr=sprintf("%04d %02d %02d %02d %02d %02d",
        seconds_ymdhms($starttime));
    my $endstr=sprintf("%04d %02d %02d %02d %02d %02d",
        seconds_ymdhms($endtime));
    foreach my $blockid (keys %$blockFields )
    {
        my $updated=[];
        foreach my $bd ($self->_blockdata($blockid))
        {
            next if $bd->{endtime} ne '' && $bd->{endtime} < $startstr;
            next if $bd->{starttime} > $endstr;
            $bd->{endtime}=$endstr if $bd->{endtime} eq '' || $bd->{endtime} > $endstr;
            $bd->{starttime}=$startstr if $bd->{starttime} < $startstr;
            push(@$updated,$bd);
        }
        $self->_blockdata($blockid,$updated);
    }
}

sub updateNames
{
    my($self,@renames)=@_;
    my %name;
    if( ref($renames[0]) eq 'HASH' )
    {
        %name=%{$renames[0]};
    }
    else
    {
        %name=@renames;
    }
    my %cleaned=();
    while( my ($k,$v) = each(%name) )
    {
        $cleaned{_cleanName($k)}=_cleanName($v);
    }

    foreach my $blockid (keys %$blockFields )
    {
        foreach my $bd ($self->_blockdata($blockid))
        {
            my $newname=_cleanName($bd->{name});
            $bd->{name} = $newname if $newname ne '';
        }
    }

    return $self->mergeData();
}

sub setRename
{
    my($self,@renames)=@_
    my %name;
    if( ref($renames[0]) eq 'HASH' )
    {
        %name=%{$renames[0]};
    }
    else
    {
        %name=@renames;
    }
    my @update=();
    foreach my $srcname (sort keys %name)
    {
        push( @update, {
                srcname=>$srcname,
                name=>_cleanName($name{$srcname}),
                starttime=>'1980 01 01 00 00 00',
                endtime=>'',
            });
    }
    $self->renames(\@update);
    foreach my $blockid (keys %$blockFields)
    {
        next if $blockid eq '001';
        my @bd=$self->_blockdata($blockid);
        $self->_blockdata($blockid,\@bd);
    }
    return $self->_mergeData();
}

sub merge
{
    my($self,$other)=@_;
    foreach my $blockid (keys %$blockFields)
    {
        my $bd=$self->_blockdata($blockid);
        my $od=$other->_blockdata($blockid);
        $od=$self->_applyNameMap($od);
        push(@$bd,@$od) if $od;
    }
    return $self->_mergeData();
}
