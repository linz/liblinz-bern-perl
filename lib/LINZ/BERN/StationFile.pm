use strict;

package LINZ::BERN::StationFile;

use Carp;
use LINZ::GNSS::Time qw/ymdhms_seconds seconds_ymdhms time_elements/;

=head1 LINZ::BERN::StationFile

Package to handle Bernese Station Information (STA) files.  Currently this module reads and processes
a template file - it cannot create a new station information file.  Also it currently only processes
the 001 (renaming), 002 (station information), and 003 (problem) sections of the file.

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

our $defaultStartTime='1980 01 01 00 00 00';
our $defaultEndTime='2099 12 31 23 59 59';

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

sub _readTime
{
    my($time,$defaultTime)=@_;
    my($y,$m,$d,$hh,$mm,$ss)=split(' ',$time || $defaultTime);
    die if $m < 0;
    return ymdhms_seconds($y,$m,$d,$hh,$mm,$ss);
}

sub _writeTime
{
    my($seconds) = @_;
    return sprintf("%04d %02d %02d %02d %02d %02d",seconds_ymdhms($seconds));
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
            if($field eq 'starttime')
            { 
                $value=_readTime($value,$defaultStartTime) 
            }
            elsif($field eq 'endtime')
            { 
                $value=_readTime($value,$defaultEndTime);
            };
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

sub _setAntennaRadome
{
    my($antenna,$radome) = @_;
    return sprintf("%-16.16s%-4.4s",$antenna,$radome);
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
    foreach my $name (sort keys %names)
    {
        my @data=sort 
            {$a->{starttime} <=> $b->{starttime} || $a->{endtime} <=> $b->{endtime}} 
            @{$names{$name}};
        next if scalar(@data) < 2;
        my @merged=();
        foreach my $i (0 .. $#data-1)
        {
            my $d0=$data[$i];
            my $d1=$data[$i+1];
            my $overlap=$d0->{endtime} > $d1->{starttime};
            my $joinable=! $overlap && $d0->{endtime} >= $d1->{starttime}-30;
            if( $overlap || $joinable )
            {
                my $different=0;
                foreach my $k (sort keys %$d0)
                {
                    next if $k eq 'starttime' || $k eq 'endtime' || $d0->{$k} eq $d1->{$k};
                    # If one or other value is default then overwrite with specified value
                    $d1->{$k} = $d0->{$k} if $d1->{$k} eq '';
                    $d0->{$k} = $d1->{$k} if $d0->{$k} eq '';
                    # If radome missing in one or other then assume specified value
                    # applies.
                    if( $k eq 'anttype' )
                    {
                        my $radome0=substr($d0->{$k},16,4);
                        my $radome1=substr($d1->{$k},16,4);
                        $d1->{anttype} = _setAntennaRadome($d1->{anttype},$radome0)
                            if $radome1 eq '' && $radome0 ne '';
                        $d0->{anttype} = _setAntennaRadome($d0->{anttype},$radome1)
                            if $radome0 eq '' && $radome1 ne '';
                    }
                    next if $d0->{$k} eq $d1->{$k};

                    if( $k ne 'remark' )
                    {
                        $different=1;
                        last if ! $overlap;
                        my $endtime=$d0->{endtime};
                        $endtime=$d1->{endtime} if $d1->{endtime} < $endtime;
                        push( @errors, 
                        "$name $k different from "._writeTime($d1->{starttime}).
                        " to "._writeTime($endtime).": \"".
                        $d0->{$k}."\" vs \"".$d1->{$k}."\"");
                    }
                }
                if( $different )
                {
                    $d0->{endtime}=$d1->{starttime} if $overlap;
                    push(@merged,$d0);
                }
                else
                {
                    $d1->{starttime}=$d0->{starttime}
                }
            }
        }
        push(@merged,$data[$#data]);
        $names{$name}=\@merged;
    }
    @data=();
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
    @errors=sort @errors;
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
            $value=_writeTime($value) if $field eq 'starttime' || $field eq 'endtime';
            $value='' if $field eq 'endtime' && $value >= $defaultEndTime;
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

=head2 $sta=new LINZ::BERN::StationFile( $filename )

Opens and reads a station information file.

=cut

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

=head2 $sta->read( $filename )

Reads the station information file.  Called by new.

=cut

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

=head2 $sta->write( $filename )

Writes the station information to a .STA file.  If $filename is omitted then
the input station information file will be overwritten

=cut

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
    my $nameonly=0;
    if( defined($data[0]))
    {

        if(ref($data[0]) eq 'ARRAY')
        {
            $nameonly=$data[1];
            @data=@{$data[0]} 
        }
        my @update=();
        my %names=();
        foreach my $d (@data)
        {
            next if ref($d) ne 'HASH';
            $names{$d->{name}}=1;
            push(@update,$d);
        }
        if( $nameonly )
        {
            foreach my $d ($self->_blockdata($blockid))
            {
                push(@update,$d) if ! $names{$d->{name}};
            }
        }

        @update = sort 
            {$a->{name} cmp $b->{name} || $a->{starttime} <=> $b->{starttime} || $a->{endtime} <=> $b->{endtime}} 
            @update;
        $self->{blocks}->{$blockid}->{data}=\@update;
    }

    my $blockdata=$self->{blocks}->{$blockid}->{data};
    return wantarray ? @$blockdata : $blockdata;
}

=head2 $sta->renames()

Access the data from the station renaming section (001).  Returns an array
or array ref of hashes of station renaming data with keys:

    name
    flag
    starttime
    endtime
    srcname
    remark

Note that starttime and endtime are converted to epoch seconds

Can also be called with an array of station information data to replace
the existing values.

   $sta->renames(\@updates)

=cut


sub renames
{
    my($self,@data)=@_;
    my $blockdata=$self->_blockdata('001',@data);
    return wantarray ? @$blockdata : $blockdata;
}

=head2 $sta->stationinfo()

Access the data from the station information section (002).  Returns an array
or array ref of hashes of station information data with keys:

    name
    flag
    starttime
    endtime
    rectype
    recserno
    recno
    anttype
    antserno
    antno
    ecc_n
    ecc_e
    ecc_u
    description
    remark

Note that starttime and endtime are converted to epoch seconds

Can also be called with an array or array ref of station information data 
to replace the existing values. An array ref parameter can be followed
by a logical parameter, which if true will only replace data for the 
names used in the update data.

=cut

sub stationinfo
{
    my($self,@data)=@_;
    my $blockdata=$self->_blockdata('002',@data);
    return wantarray ? @$blockdata : $blockdata;
}

=head2 $sta->problems()

Access the data from the problem section (003).  Returns an array
or array ref of hashes of problem data with keys:

    name
    flag
    starttime
    endtime
    remark

Note that starttime and endtime are converted to epoch seconds

Can also be called with an array of problem data to replace
the existing values.

=cut

sub problems
{
    my($self,@data)=@_;
    my $blockdata=$self->_blockdata('003',@data);
    return wantarray ? @$blockdata : $blockdata;
}

=head2 $sta->selectDates( $starttime, $endtime )

Trims station information to only include data from $startime to $endtime

=cut

sub selectDates
{
    my($self,$starttime,$endtime)=@_;
    foreach my $blockid (keys %$blockFields )
    {
        my $updated=[];
        foreach my $bd ($self->_blockdata($blockid))
        {
            next if $bd->{endtime} ne '' && $bd->{endtime} < $starttime;
            next if $bd->{starttime} > $endtime;
            $bd->{endtime}=$endtime if $bd->{endtime} eq '' || $bd->{endtime} > $endtime;
            $bd->{starttime}=$starttime if $bd->{starttime} < $starttime;
            push(@$updated,$bd);
        }
        $self->_blockdata($blockid,$updated);
    }
}

=head2 $sta->updateNames( old=>new, old=>new ... )

Updates station names replacing old names with new name.  This does not
affect station renaming, just the names that are generated by it, and the
names that are used for other station information sections.

=cut

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

=head2 $sta->setRename(code=>value,code=>value,...)

Sets station renaming of code=>value.  Overrides any existing data in 
block 001 (station naming) of the station information file.

Returns a lists of conflicts generated by renaming (eg where incompatible
station information has been generated by renaming other blocks, or where
there was already incompatible information.

=cut

sub setRename
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

=head2 $data=$sta->applyNameMap($data,$mappedonly)

Applies name mapping to data.  The data is assumed to be an array of dictionaries with
fields name, starttime, endtime.  The name map is applied, potentially splitting 
date ranges, or removing data where no mapping is defined in the source data.

If $mappedonly is true then only mapped names are copied.

=cut

sub applyNameMap
{
    my($self,$data,$mappedonly)=@_;
    my $renames=$self->renames;
    my @mapped=();
    my @torename=@$data;
    while (my $d = shift @torename)
    {
        my $name=_cleanName($d->{name});
        my $starttime=$d->{starttime};
        my $endtime=$d->{endtime};
        my $used=0;
        foreach my $rename (@$renames)
        {
            my $srcname=$rename->{srcname};
            next if $rename->{starttime} >= $endtime;
            next if $rename->{endtime} && ($rename->{endtime} <= $starttime);
            my $matched=$srcname eq $name;
            $matched=1 if ! $matched 
                && $srcname =~ /\*$/ 
                && substr($name,0,length($srcname)-1) eq substr($srcname,0,length($srcname)-1);
            next if ! $matched;

            $used=1;
            if( $rename->{endtime} && ($rename->{endtime} < $endtime) )
            {
                my $after=_copy($d);
                $after->{starttime}=$rename->{endtime};
                unshift(@torename,$after);
                $endtime=$rename->{endtime};
            }
            if( $rename->{starttime} > $starttime )
            {
                my $before=_copy($d);
                $before->{endtime}=$rename->{starttime};
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
        push(@mapped,_copy($d)) if ! $used && ! $mappedonly;
    }
    return \@mapped;
}

=head2 $rename=$sta->matchName($srcname,$date)

Find the rename record matching the source name as
defined in the 001 block.  If the date is not specified then just returns the 
first matching name, otherwise returns the name that applies at the date.
The date $date must be supplied as a timestamp (ie epoch seconds).

The rename record is a hash include keys name and flag which define the 
mapped name.

=cut

sub matchName
{
    my($self,$srcname,$date)=@_;
    $srcname=_cleanName($srcname);
    foreach my $rename ($self->renames)
    {
        if( $date )
        {
            next if $rename->{starttime} >= $date;
            next if $rename->{endtime} && $rename->{endtime} <= $date;
        }
        my $rensrc=$rename->{srcname};
        my $matched = $rensrc eq $srcname;
        $matched=1 if ! $matched 
                && $rensrc =~ /\*$/ 
                && substr($srcname,0,length($rensrc)-1) eq substr($rensrc,0,length($rensrc)-1);
        return $rename if $matched;
    }
    return undef;
}

=head2 $sta->merge( $sta2 )

Merge station information from another file into the current file

Returns an array of conflicts (as text strings) or undef if there are 
none.

=cut

sub merge
{
    my($self,$other)=@_;
    foreach my $blockid (keys %$blockFields)
    {
        my $bd=$self->_blockdata($blockid);
        my $od=$other->_blockdata($blockid);
        $od=$self->applyNameMap($od);
        push(@$bd,@$od) if $od;
    }
    return $self->_mergeData();
}

=head2 $sta->setMissingRadome('NONE')

Sets the radome code for antennas for which it is not defined.

=cut

sub setMissingRadome
{
    my($self,$radome)=@_;
    $radome ||= 'NONE';
    foreach my $d ($self->stationinfo())
    {
        my $anttype=$d->{anttype};
        if( substr($anttype,16,4) eq '')
        {
            $d->{anttype} = _setAntennaRadome($d->{anttype},$radome);
        }
    }
}

=head2 $sta->loadIGSSiteLog( $sitelog, %options )

Loads the block 2 (station information) section from an IGS site log
(loaded by LINZ::GNSS::IGSSiteLog).  The data from the log will be 
associated by default with the name taken from the four character
code and domes number.  This can be overridden using the name option

Names are mapped using the data from block 1 of the station information
file.

Existing station information for the name will be replaced.

Options can include

=over

=item name=>$name

Specify the name to use for the mark referenced in the site log.  This will be
mapped using the block 1 name remapping.

=item update=>$update

Specifies whether the station information data is updated, or the function returns
the updates, but doesn't actually apply them.

=back

=cut

sub loadIGSSiteLog
{
    my($self,$sitelog,%options)=@_;
    my $name=$options{name};
    my $doupdate=exists $options{update} ? $options{update} : 1;
    if( ! $name )
    {
        $name=$sitelog->code;
        my $domes=$sitelog->domesNumber;
        $name .= ' '.$domes if $domes;
    }

    # Compile a list of events from the site log, IA,DA (antenna installed, removed)
    # IR,DR (receiver installed, removed), and sort by date

    my @events;
    my $endtime=_readTime($defaultEndTime);
    foreach my $ant ($sitelog->antennaList)
    {
        push(@events,[$ant->{dateInstalled},'IA',$ant]);
        push(@events,[$ant->{dateRemoved} || $endtime,'DA',$ant]);
    }
    foreach my $rec ($sitelog->receiverList)
    {
        push(@events,[$rec->{dateInstalled},'IR',$rec]);
        push(@events,[$rec->{dateRemoved} || $endtime,'DR',$rec]);
    }
    @events=sort {$a->[0] <=> $b->[0] || $a->[1] cmp $b->[1]}  @events;

    # Now compile the Bernese history.  Install events update the
    # name of the antenna or receiver and increment the count,
    # remove events decrement the count.  Only keep data for
    # periods where the count of antenna and receiver is greater
    # than 0.
    
    my $info={
        name => $name,
        flag => '',
        starttime => '',
        endtime => '',
        rectype => '',
        recserno => '',
        recno => '',
        anttype => '',
        antserno => '',
        antno => '',
        ecc_n => '',
        ecc_e => '',
        ecc_u => '',
        description => '',
        remark => $sitelog->source,
    };
    my $nant=0;
    my $nrec=0;

    my @stationinfo=();

    foreach my $event (@events)
    {
        my($date,$type,$antrec)=@$event;
        $info->{endtime}=$date;
        if( $nant > 0 && $nrec > 0 )
        {
            my $infocopy={};
            while( my($k,$v)=each(%$info) ){$infocopy->{$k}=$v;}
            push(@stationinfo,$infocopy);
        }
        $info->{starttime}=$date;
        if( $type eq 'IA' )
        {
            $nant++;
            $info->{anttype}=$antrec->{antennaType};
            $info->{antserno}=$antrec->{serialNumber};
            $info->{antno}='999999';
            $info->{ecc_e}=sprintf("%.4f",$antrec->{offsetENU}->[0]);
            $info->{ecc_n}=sprintf("%.4f",$antrec->{offsetENU}->[1]);
            $info->{ecc_u}=sprintf("%.4f",$antrec->{offsetENU}->[2]);
        }
        elsif( $type eq 'DA')
        {
            $nant--;
        }
        elsif( $type eq 'IR')
        {
            $nrec++;
            $info->{rectype}=$antrec->{receiverType};
            $info->{recserno}=$antrec->{serialNumber};
            $info->{recno}='999999';
        }
        elsif( $type eq 'DR')
        {
            $nrec--;
        }
    }

    # Merge data that hasn't changed..
    my @mergeinfo=();
    my $last=undef;
    my $tolerance=300;
    foreach my $si (@stationinfo)
    {
        if( ! $last || $si->{starttime} > $last->{endtime}+$tolerance )
        {
            push(@mergeinfo,$si);
            $last=$si;
            next;
        }
        my $same=1;
        foreach my $k (keys %$last)
        {
            next if $k eq 'starttime';
            next if $k eq 'endtime';
            next if $si->{$k} eq $last->{$k};
            $same=0;
            last;
        }
        if( $same )
        {
            $last->{endtime}=$si->{endtime};
        }
        else
        {
            push(@mergeinfo,$si);
            $last=$si;
        }
    }
    @stationinfo=@mergeinfo;

    # Apply name mapping to the information
    
    my $mapped=$self->applyNameMap(\@stationinfo,1);

    # Now replace the information in the data...
    
    $self->stationinfo( $mapped, 1 ) if $doupdate;

    return wantarray ? @$mapped : $mapped;
}
