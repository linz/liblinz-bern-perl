use strict;

package LINZ::BERN::StationFile;

use Carp;
use LINZ::GNSS::Time qw/ymdhms_seconds seconds_ymdhms time_elements/;

=head1 LINZ::BERN::StationFile

Package to handle Bernese Station Information (STA) files.  Currently this module reads and processes
a template file - it cannot create a new station information file.  Also it currently only processes
the 001 (renaming), 002 (station information), and 003 (problem) sections of the file.

=cut

# Code compatibility mapping of field names.
# Default is lower case field name

our $fieldmap={
    'station name'=>'name',
    'flg'=>'flag',
    'from'=>'starttime',
    'to'=>'endtime',
    'old station name'=>'srcname',
    'receiver type'=>'rectype',
    'receiver serial nbr'=>'recserno',
    'rec #'=>'recno',
    'antenna type'=>'anttype',
    'antenna serial nbr'=>'antserno',
    'ant #'=>'antno',
    'north'=>'_n',
    'east'=>'_e',
    'up'=>'_u',
    'station name 1'=>'name1',
    'station name 2'=>'name2',
    'marker type'=>'marktype'
};

# North, East, Up fields are ambiguous.  This tries to fix it...
our $offsettype={
    '002'=> ['ecc'],
    '003'=> ['offset','velocity']
};

our $defaults={
    'flag'=>'001',
    'rectype'=>'*** UNDEFINED ***',
    'recserno'=>'999999',
    'rectype'=>'*** UNDEFINED ***',
    'recserno'=>'999999',    
};

our $defaultStartTime='1980 01 01 00 00 00';
our $defaultEndTime='2099 12 31 23 59 59';

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
    my $time='';
    if( $seconds )
    {
        $time=sprintf("%04d %02d %02d %02d %02d %02d",seconds_ymdhms($seconds));
        $time='' if $time ge $defaultEndTime; 
    }
    return $time;
}


sub _readBlockHeader
{
    my ($staf,$blockline)=@_;
    my $line=$blockline || <$staf>;
    my ($blkid,$blkname);
    while($line)
    {
        if($line =~ /^TYPE\s+(\d\d\d)\:\s+(.*?)\s*$/)
        {
            ($blkid,$blkname)=($1,$2);
            last;
        }
        croak("Unrecognized line in station information file: ".$line)
            if $line =~ /\S/;
        $line=<$staf>;
    }
    return undef if ! defined $blkid;
    my $skip=<$staf>;
    my $nameheader=<$staf>;
    my $nameline=<$staf>;
    my $formatline=<$staf>;
    my @headers=($line,$skip,$nameheader,$nameline,$formatline);
    my @parts=$formatline=~/(\s+|\*+(?:\.\*+)?|YYYY[^S]+SS)/g;
    my $col=0;
    my @fields=();
    my $ncol=0;
    my $offsettypes=$offsettype->{$blkid} || [];
    foreach my $format (@parts)
    {
        if( $format !~ /^\s+$/ )
        {
            my $flen=length($format);
            my $fldid=substr($nameline,$ncol,$flen);
            my $name=lc($fldid);
            $name=~ s/^\s+//;
            $name =~ s/\s+$//;
            $name=$fieldmap->{$name} if exists $fieldmap->{$name};
            if( $name =~ /^_[neu]/)
            {
                my $offset=$offsettypes->[0] || 'ecc';
                shift(@$offsettypes) if $name eq '_u';
                $name=$offset.$name;
            }
            push(@fields,
                {
                    field=>$name,
                    id=>$fldid,
                    col=>$ncol,
                    length=>$flen,
                    format=>$format,
                });
        }
        $ncol += length($format);
    }
    my $blockdef={
        id=>$blkid,
        name=>$blkname,
        headers=>\@headers,
        fields=>\@fields,
    };
    return $blockdef;
}

sub _readBlockData
{
    my($staf,$blockdef)=@_;
    my @data;
    while (my $line = <$staf> )
    {
        last if $line =~ /^\s*$/;
        my $record={};
        foreach my $fielddef (@{$blockdef->{fields}})
        {
            my $field=$fielddef->{field};
            my $col=$fielddef->{col};
            my $len=$fielddef->{length};
            
            my $value=substr($line,$col,$len) ;
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
    $blockdef->{data}=\@data;
    return \@data;
}


sub _writeBlockData
{
    my($staf,$fields,$data)=@_;
    my $reclen=0;
    foreach my $fielddef (@$fields)
    {
        my $endcol=$fielddef->{col}+$fielddef->{length};
        $reclen = $endcol if $endcol > $reclen;
    }
    foreach my $d (@$data)
    {
        my $line=' 'x$reclen;
        foreach my $fielddef (@$fields)
        {
            my $field=$fielddef->{field};
            my $col=$fielddef->{col};
            my $length=$fielddef->{length};
            my $value=$d->{$field};
            if( $field eq 'starttime' || $field eq 'endtime')
            {
               $value=_writeTime($value);
               $value=$defaultStartTime if $field eq 'starttime' && $value eq '';
            }
            $value=$defaults->{$field} if $value eq '';
            substr($line,$col,$length)=sprintf("%-*.*s",$length,$length,$value);
        }
        $line =~ s/\s*$/\n/;
        print $staf $line;
    }
}

sub _writeBlock
{
    my($staf,$blockdef)=@_;
    print $staf @{$blockdef->{headers}};
    _writeBlockData($staf,$blockdef->{fields},$blockdef->{data});
    print $staf "\n";
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
    
    foreach my $blockid ($self->_blockids)
    {
        my $key = $blockid eq '001' ? 'srcname' : 'name';
        my $blockerrors=$self->_mergeBlockData( $blockid, $key );
        push(@errors,@$blockerrors) if $blockerrors;
    }
    @errors=sort @errors;
    return @errors ? \@errors : undef;
}

=head2 $sta=new LINZ::BERN::StationFile( $filename )

Opens and reads a station information file.

=cut

sub new
{
    my($class,$filename,%options) = @_;
    my $self=bless
    {
        filename=>$filename,
    }, $class;
    if( $options{readformat} )
    {
        $self->readFormat();
    }
    if( $filename && ! $options{newfile})
    {
        $self->read();
    }
    else
    {
        my $template=_template();
        open( my $fh, "<", \$template);
        $self->_readf($fh);
    }
    return $self;
}

sub filename
{
    my($self,$filename) = @_;
    $self->{filename} = $filename if $filename;
    return $self->{filename};
}

sub _readf
{
    my($self,$fh)=@_;
    $self->{version}='1.00';
    $self->{technique}='GNSS';
    # Read two header lines
    my $title=<$fh>;
    chomp($title);
    my $line=<$fh>;
    my @headers=();
    my $blockline='';
    while($line = <$fh>)
    {
        if($line =~ /^FORMAT\s+VERSION\:\s+(\S+)\s*$/)
        {
            $self->{version}=$1;
        } 
        elsif( $line =~ /^TECHNIQUE\:\s+(\S+)\s*$/ )
        {
            $self->{technique}=$1;
        }
        elsif( $line =~ /^TYPE\s+\d\d\d\:/)
        {
            $blockline=$line;
            last;
        }
        elsif( $line =~ /\S/ )
        {
            croak("Invalid line in station information file: ".$line)
        }
        push(@headers,$line);
    }
    croak("Missing data in station information file") if ! $blockline;
    my $blocks=[];
    my $blockidx={};
    while( 1 )
    {
        my $blockdef=_readBlockHeader($fh, $blockline);
        $blockline='';
        last if ! defined $blockdef;
        _readBlockData($fh,$blockdef);
        push(@$blocks,$blockdef);
        $blockidx->{$blockdef->{id}}=$blockdef;
    }
    $self->{title}=$title;
    $self->{headers}=\@headers;
    $self->{blocks}=$blocks;
    $self->{blockids}=$blockidx;
}


=head2 $sta->read( $filename )

Reads the station information file.  Called by new.

=cut

sub read
{
    my ($self) = @_;
    open(my $staf,"<", $self->filename) || croak("Cannot open station information file ".$self->filename."\n");
    $self->_readf($staf);
    close($staf);
}

=head2 $sta->write( $filename )

Writes the station information to a .STA file.  If $filename is omitted then
the input station information file will be overwritten

=cut

sub write
{
    my ($self,$filename) = @_;
    $filename ||= $self->{filename};
    open( my $staf, ">", $filename ) || croak("Cannot open output station information file $filename\n");
    my $header="STATION INFORMATION FILE                     "._writeTime(time());
    my $line=$header;
    $line =~ s/./-/g;
    print $staf "$header\n$line\n";
    print $staf @{$self->{headers}};
    foreach my $blockdef (@{$self->{blocks}})
    {
        _writeBlock($staf,$blockdef);
    }
    close($staf);
}

sub _blockids
{
    my ($self)=@_;
    my $ids=[];
    foreach my $blockdef (@{$self->{blocks}})
    {
        push(@$ids,$blockdef->{id});
    }
    return wantarray ? @$ids : $ids;
}

sub _getblock
{
    my ($self,$blockid)=@_;
    foreach my $blockdef (@{$self->{blocks}})
    {
        return $blockdef if $blockdef->{id} eq $blockid;
    }
    return;
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
        $self->_getblock($blockid)->{data}=\@update;
    }

    my $blockdata=$self->_getblock($blockid)->{data};
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
    foreach my $blockid ($self->_blockids)
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

    foreach my $blockid ($self->_blockids)
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
    foreach my $blockid ($self->_blockids)
    {
        next if $blockid eq '001';
        my @bd=$self->_blockdata($blockid);
        $self->_blockdata($blockid,\@bd);
    }
    return $self->_mergeData();
}

=head2 $data=$sta->addRename($name,$srcname,$starttime,$endtime,$remark)

Adds a station rename to the type 001 block

=cut

sub addRename

{
    my($self,$name,$srcname,$starttime,$endtime,$remark)=@_;
    my $blockdata=$self->_blockdata('001');
    push(@$blockdata,{
        name=>$name,
        srcname=>$srcname,
        starttime=>$starttime,
        endtime=>$endtime,
        remark=>$remark,
    });
}

=head2 $sta->mergeRenames()

Simplifies renaming where multiple renames of a source name are provided
with the same target name.

=cut

sub  mergeRenames
{
    my($self)=@_;
    my $renameblock=$self->_getblock('001');
    my $blockdata=$renameblock->{data};
    my @rawdata = sort {$a->{srcname} cmp $b->{srcname} || $a->{starttime} <=> $b->{starttime}}  @$blockdata;
    my @merged=();
    my $last=undef;
    foreach my $rename (@rawdata)
    {
        if( $last && $last->{srcname} eq $rename->{srcname} && $last->{name} eq $rename->{name} )
        {
            if( $last->{endtime} && (! $rename->{endtime} || $rename->{endtime} > $last->{endtime}))
            {
                $last->{endtime} = $rename->{endtime};
            }
        }
        else
        {
            push(@merged,$rename);
            $last=$rename;
        }
    }
    $renameblock->{data}=\@merged;
}

=head2 $data=$sta->applyNameMap($data,mappedonly=0/1,addnames=>0/1)

Applies name mapping to data.  The data is assumed to be an array of dictionaries with
fields name, starttime, endtime.  The name map is applied, potentially splitting 
date ranges, or removing data where no mapping is defined in the source data.

If mappedonly is true then only mapped names are copied.
If addnames is true then unmapped names are added to the name list

Where names are added and the name looks like a station code (4 alphanumerics followd by a 
blank) then original station name is set to the code followed by '*'.

=cut

sub applyNameMap
{
    my($self,$data,%options)=@_;
    my $mappedonly=$options{mappedonly};
    my $addnames=$options{addnames};
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
            $renamed->{flag}=$rename->{flag};
            push(@mapped,$renamed);
            $used=1;
            last;
        }
        push(@mapped,_copy($d)) if ! $used && (! $mappedonly || $addnames);
        if( $addnames && ! $used )
        {
            my $srcname=$name =~ /^\w{4}(\s|$)/ ? substr($name,0,4).'*' : $name;
            $self->addRename($name,$srcname,$starttime,$endtime,"From site log");
        }
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
    foreach my $blockid ($self->_blockids)
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
        $anttype=~s/\s+$//;
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

Existing station information for the name will be replaced.

Options can include

=over

=item name=>$name

Specify the name to use for the mark referenced in the site log.  This will be
mapped using the block 1 name remapping.

=item update=>$update

Specifies whether the station information data is updated, or the function returns
the updates, but doesn't actually apply them.

=item addnames=>$addnames

If true then names are added to the type 001 block if nothing there matches them.  

=back

=cut

sub loadIGSSiteLog
{
    my($self,$sitelog,%options)=@_;
    my $name=$options{name};
    my $doupdate=exists $options{update} ? $options{update} : 1;
    my $addnames=$options{addnames};
    if( ! $name )
    {
        $name=$sitelog->code;
        my $domes=$sitelog->domesNumber;
        $name .= ' '.$domes if $domes;
    }
    $name=_cleanName($name);

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
            my $anttype=$antrec->{antennaType};
            my $radtype=$antrec->{antennaRadomeType};
            $anttype =~ s/\s+$//;
            $radtype = uc($radtype);            

            if( length($anttype) < 17 && ($radtype eq '' || $radtype eq 'NONE'))
            {
                $anttype = _setAntennaRadome($anttype,'NONE');
            }
            elsif( length($anttype) < 17 && length($radtype) == 4 )
            {
                $anttype = _setAntennaRadome($anttype,$radtype);
            }
            $info->{anttype}=$anttype;
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
    
    my $mapped=$self->applyNameMap(\@stationinfo,mappedonly=>1,addnames=>$addnames);

    # Now replace the information in the data...
    
    $self->stationinfo( $mapped, 1 ) if $doupdate;

    return wantarray ? @$mapped : $mapped;
}

sub _template
{
return <<EOD;
STATION INFORMATION FILE                                         20-AUG-19 15:06
--------------------------------------------------------------------------------

FORMAT VERSION: 1.01
TECHNIQUE:      GNSS

TYPE 001: RENAMING OF STATIONS
------------------------------

STATION NAME          FLG          FROM                   TO         OLD STATION NAME      REMARK
****************      ***  YYYY MM DD HH MM SS  YYYY MM DD HH MM SS  ********************  ************************


TYPE 002: STATION INFORMATION
-----------------------------

STATION NAME          FLG          FROM                   TO         RECEIVER TYPE         RECEIVER SERIAL NBR   REC #   ANTENNA TYPE          ANTENNA SERIAL NBR    ANT #    NORTH      EAST      UP      DESCRIPTION             REMARK
****************      ***  YYYY MM DD HH MM SS  YYYY MM DD HH MM SS  ********************  ********************  ******  ********************  ********************  ******  ***.****  ***.****  ***.****  **********************  ************************

TYPE 003: HANDLING OF STATION PROBLEMS
--------------------------------------

STATION NAME          FLG          FROM                   TO         REMARK
****************      ***  YYYY MM DD HH MM SS  YYYY MM DD HH MM SS  ************************************************************

TYPE 004: STATION COORDINATES AND VELOCITIES (ADDNEQ)
-----------------------------------------------------
                                            RELATIVE CONSTR. POSITION     RELATIVE CONSTR. VELOCITY
STATION NAME 1        STATION NAME 2        NORTH     EAST      UP        NORTH     EAST      UP
****************      ****************      **.*****  **.*****  **.*****  **.*****  **.*****  **.*****

TYPE 005: HANDLING STATION TYPES
--------------------------------

STATION NAME          FLG  FROM                 TO                   MARKER TYPE           REMARK
****************      ***  YYYY MM DD HH MM SS  YYYY MM DD HH MM SS  ********************  ************************

EOD
}

1;

