
=head1 LINZ::BERN::BernUtil

Package provides utility functions to support bern processing.

The main function of this module is to allow creating and running PCF files, and in 
particular creating an environment that allows multiple scripts to be running simultaneously
without conflict.  This is done using following steps:

   my $environment=LINZ::BERN::BernUtil::CreateRuntimeEnvironment();
   my $campaign=LINZ::BERN::BernUtil::CreateCampaign(...);
   my $result=LINZ::BERN::BernUtil::RunPcf($pcf,$campaign,$environment);
   my $status=LINZ::BERN::BernUtil::RunPcfStatus($campaign);
   LINZ::BERN::BernUtil::DeleteRuntimeEnvironment();

=cut

use strict;

package LINZ::BERN::BernUtil;
our $VERSION = '1.1.0';

use English;
use LINZ::BERN::SessionFile;
use LINZ::BERN::CrdFile;
use LINZ::GNSS::RinexFile;
use LINZ::GNSS::Time
  qw/seconds_datetime time_elements year_seconds seconds_julianday parse_gnss_date/;
use Archive::Zip qw/ :ERROR_CODES /;
use File::Path qw/make_path remove_tree/;
use File::Basename;
use File::Copy;
use File::Copy::Recursive qw/dircopy/;
use File::Which;
use Carp;

use JSON::PP;

our $LoadGpsEnvVar = 'BERNESE_ENV_FILE';
our $ClientEnvVar = 'CLIENT_ENV';
our $DefaultLoadGps = '/opt/bernese52/GPS/EXE/LOADGPS.setvar';
our $BerneseTimeoutVar = 'BERNESE_BPE_TIMEOUT';
our $AntennaFile    = 'PCV_COD.I08';
our $ReceiverFile   = 'RECEIVER.';

our $LoadedAntFile  = '';
our $LoadedAntennae = [];

our $LoadedRecFile   = '';
our $LoadedReceivers = [];

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

sub SetBerneseEnv {
    my ( $loadfile, %override ) = @_;
    $loadfile = $ENV{$LINZ::BERN::BernUtil::LoadGpsEnvVar} if ! $loadfile;
    $loadfile = $ENV{$LINZ::BERN::BernUtil::ClientEnvVar} if ! $loadfile;
    $loadfile = $LINZ::BERN::BernUtil::DefaultLoadGps if ! $loadfile;

    open( my $lf, "<$loadfile" )
      || croak("Cannot open Bernese enviroment file $loadfile\n");
    my @paths   = ();
    my $bernenv = {};
    while ( my $line = <$lf> ) {
        if (   $line =~ /^export\s+(\w+)=\"([^\"]*)\"\s*$/
            || $line =~ /^export\s+(\w+)=(\`[^\`]*\`)\s*$/
            || $line =~ /^export\s+(\w+)=(\S*?)\s*$/ )
        {
            my ( $var, $value ) = ( $1, $2 );
            $value =~ s/\$\{(\w+)\}/$ENV{$1}/eg;
            $value =~ s/\$(\w+)/$ENV{$1}/eg;
            $value =~ s/\`([^\`]*)\`/`$1`/eg;
            $value =~ s/\s*$//;    # To remove new lines from command expansion
            $value = $override{$var} if exists $override{$var};
            $bernenv->{$var} = $value;
            $ENV{$var} = $value;
        }
        elsif ( $line =~ /^addtopath\s+\"([^\"]*)\"\s*$/ ) {
            my ($path) = $1;
            $path =~ s/\$\{(\w+)\}/$ENV{$1}/eg;
            $path =~ s/\$(\w+)/$ENV{$1}/eg;
            push( @paths, $path );
        }
    }
    my @envpaths = split( /\:/, $ENV{PATH} );
    my %gotpath = map { $_ => 1 } @envpaths;
    foreach my $p (@paths) { unshift( @envpaths, $p ) if !exists $ENV{$p}; }
    my $newpath = join( ":", @envpaths );
    $bernenv->{PATH} = join( ':', @paths, '${PATH}' );
    $ENV{PATH} = $newpath;

    return $bernenv;
}

=head2 $environment=LINZ::BERN::BernUtil::CreateRuntimeEnvironment( %options )

This script creates a run-time user environment for Bernese scripts.  It creates 
default minimal user and campaign directories for running a PCF in specified locations 
as well setting the corresponding environment variables.  The $environment 
created contains CLIENT_ENV and CPU_FILE entries that can be passed in 
to the RunPcf function.  

The main purpose in creating these directories is to allow the PCF to run without a risk
of conflicting with other enviroments.

The options can include:

=over

=item CanOverwrite=>1  

Allows replacing an existing user environment. If this is not set then script will die 
if there is already a user directory in the specified location.

=item UserDirectory 

The location in which the user environment will be created.  The default is /tmp/bernese_${user}/user$$

=item UserDirectorySettings=>string

A new line delimited string of settings, as per default settings example below.  These are 
used to construct the user environment

=item CustomUserFiles=>zipfilename

If the default user settings are used then these can either include links to the 
system PCF and options (ie in the bernese installation), or have blank directories
defined for installing a custom PCF.  This can be the name of a zip file in which
case the contents of the file will be installed into the user directory.  (The
zip file could be created using get_pcf_files ...).  The file can specify a number
of space separated zip files.  (File names cannot include whitespace).

A filename of "empty" creates a user directory without any PCF files.

=item SourceUserDirectory

Location from which user files are copied or to which symbolic links are created.  The 
default is ${X}.

=item DataDirectory

The location in which the data directory will be created.  The default is /tmp/bernese_${user}/data$$

=item DataDirectorySettings=>string

A new line delimited string of settings, as per default settings example below.  These are 
used to construct the user environment

=item TemplateDirectory=dirname

A directory that is copied to the target. The directory is expected to include a file 
"settings" from which settings (for symbolic links etc) are copied in place of the 
settings string.  Overrides "user_directory_settings=" and the default settings.

=item AlternativeGenDir=>dirname

Defines an alternative GEN directory to the default implemented by the 
Bernese software (${X}/GEN).  This can be used to reference an independently maintained 
directory in a shared location for example.  
(Note: To do this it also creates a custom ${X} directory in ${U}/BERN52.  
The custom directories contain symlinks to all the files in the original directories.
It then resets X to point to ${U}/BERN52.)

=item CustomGenDir=>1

If true then the script will create a user customisable copy of ${X}/GEN in ${U}/GEN.
This allows installing custom files into GEN when the user does not have permission to
install into the system file, for example SINEX file headers.  


=item DatapoolDir=>dirname

Overrides the default datapool directory

=item SaveDir=>dirname

Overrides the default save directory

=item CpuFile=>cpufile

Overrides the default CPU file

=item EnvironmentVariables

An optional hash of Bernese environment variables that will override the default values (for
example resetting the SAVEDISK area or CPU_FILE.)

=back

The files installed into the environment are defined by a settings string, which
is a new line separated string. This defines the following entities:

=over

=item CLIENT_ENV     

The location into which the client enviroment is written for subsequent loading by the Bernese scripts

=item CPU_FILE

The name of the CPU file

=item PCF_FILE

The name of a PCF file from the settings.  This is not used anywhere, but allows the settings
specfication to include a PCF file.

=item makedir $dir

A directory to be created

=item symlink option1 option2 ... linkname

Creates a symbolic link at linkname to the first of option1 option2 ... that exists

=item copy source target

Copies the specified file
   
=back

The user directory settings define how the user directory is constructed, by copying or 
linking selected files from a selected environment, or unzipping a file into the 
user directory.  It can also define the CLIENT_ENV and CPU_FILE settings that will be used 
to run jobs in the constructed enviroment.  

The default settings are as follows:

  CLIENT_ENV ${U}/LOADGPS.setvar
  symlink ${SRC}/OPT ${U}/OPT
  symlink ${SRC}/PCF ${U}/PCF
  symlink ${SRC}/USERSCPT ${SRC}/SCRIPT ${U}/SCRIPT
  makedir ${U}/WORK
  makedir ${U}/PAN
  copy ${SRC}/PAN/EDITPCF.INP ${U}/PAN/EDITPCF.INP
  copy ${SRC}/PAN/MENU_CMP.INP ${U}/PAN/MENU_CMP.INP
  copy ${SRC}/PAN/MENU_EXT.INP ${U}/PAN/MENU_EXT.INP
  copy ${SRC}/PAN/MENU.INP ${U}/PAN/MENU.INP
  copy ${SRC}/PAN/MENU_PGM.INP ${U}/PAN/MENU_PGM.INP
  copy ${SRC}/PAN/MENU_VAR.INP ${U}/PAN/MENU_VAR.INP
  copy ${SRC}/PAN/NEWCAMP.INP ${U}/PAN/NEWCAMP.INP
  copy ${SRC}/PAN/RUNBPE.INP ${U}/PAN/RUNBPE.INP
  copy ${SRC}/PAN/${CPU_FILE}.CPU ${U}/PAN/${CPU_FILE}.CPU

To install a zip file use the command

  unzip zip_file-name

For the data directory settings the default is 

  copy ${SRC}/PAN/MENU_CMP.INP ${P}/MENU_CMP.INP

=cut

our $DefaultBernUserSettings = <<'EOD';
CLIENT_ENV ${U}/LOADGPS.setvar
makedir ${U}/WORK
makedir ${U}/PAN
copy ${SRC}/PAN/EDITPCF.INP ${U}/PAN/EDITPCF.INP
copy ${SRC}/PAN/MENU_CMP.INP ${U}/PAN/MENU_CMP.INP
copy ${SRC}/PAN/MENU_EXT.INP ${U}/PAN/MENU_EXT.INP
copy ${SRC}/PAN/MENU.INP ${U}/PAN/MENU.INP
copy ${SRC}/PAN/MENU_PGM.INP ${U}/PAN/MENU_PGM.INP
copy ${SRC}/PAN/MENU_VAR.INP ${U}/PAN/MENU_VAR.INP
copy ${SRC}/PAN/NEWCAMP.INP ${U}/PAN/NEWCAMP.INP
copy ${SRC}/PAN/RUNBPE.INP ${U}/PAN/RUNBPE.INP
copy ${SRC}/PAN/${CPU_FILE}.CPU ${U}/PAN/${CPU_FILE}.CPU
EOD

our $DefaultBernUserSettingsSystemPCF = <<'EOD';
symlink ${SRC}/OPT ${U}/OPT
symlink ${SRC}/PCF ${U}/PCF
symlink ${SRC}/USERSCPT ${SRC}/SCRIPT ${U}/SCRIPT
EOD

our $DefaultBernUserSettingsUserPCF = <<'EOD';
makedir ${U}/OPT
makedir ${U}/PCF
makedir ${U}/SCRIPT
EOD

# Custom Gen Dir settings are required if script requires a custom
# file in the GEN directory (eg SINEX template).  Need to create copy
# of ${X} and ${X}/GEN as user may not have right to install files in
# GEN.

our $AlternativeGenDirSettings = <<'EOD';
makedir ${U}/BERN
symlink ${GEN} ${U}/BERN/GEN
symlink ${X} ${U}/BERN/*
setenv X ${U}/BERN
EOD

our $CustomGenDirSettings = <<'EOD';
makedir ${U}/GEN
symlink ${GEN} ${U}/GEN/*
makedir ${U}/BERN
symlink ${U}/GEN ${U}/BERN/GEN
symlink ${X} ${U}/BERN/*
setenv X ${U}/BERN
EOD

our $DefaultBernDataSettings = <<'EOD';
copy ${SRC}/PAN/MENU_CMP.INP ${P}/MENU_CMP.INP
EOD

sub CreateRuntimeEnvironment {
    my (%options) = @_;
    my $patherror;

    my $userdir    = $options{UserDirectory};
    my $datadir    = $options{DataDirectory};
    my $overwrite  = $options{CanOverwrite} || !$userdir;
    my $altgen     = $options{AlternativeGenDir} || $ENV{BERNESE_GENDIR};
    my $customgen  = $options{CustomGenDir};
    my $customdp   = $options{DatapoolDir} || $ENV{BERNESE_DATAPOOL};
    my $customsave = $options{SaveDir};
    my $customcpu  = $options{CpuFile};
    my $user       = ( getpwuid($REAL_USER_ID) )[0];
    if( ! $userdir || ! $datadir )
    {
        my $envbase=$ENV{BERNESE_JOBDIR} || "/tmp/bernese_$user";
        $userdir ||= "$envbase/$$/user";
        $datadir ||= "$envbase/$$/data";
    }
    my $bernserver = $ENV{BERNESE_SERVER_HOST};

    if ( -e $userdir ) {
        if ($overwrite) {
            remove_tree( $userdir, { error => \$patherror } );
        }
        croak(
"Cannot create Bernese user directory at $userdir - already in use\n"
        ) if -e $userdir;
    }

    my $data_exists = -d $datadir;

    my $env = {
        CLIENT_ENV => "$userdir/LOADGPS.setvar",
        CPU_FILE   => $options{'CpuFile'} || 'UNIX',
    };

    eval {

        #  Create the user and data environments if they don't already exist
        make_path( $datadir, { error => \$patherror } ) if !-d $datadir;
        die "Cannot create Bernese campaign directory at $datadir\n"
          if !-d $datadir;

        make_path( $userdir, { error => \$patherror } );
        die "Cannot create Bernese user directory at $userdir\n"
          if !-d $userdir;

        my $envvars = $options{'EnvironmentVariables'} || {};
        $envvars->{U} = $userdir;
        $envvars->{P} = $datadir;
        $envvars->{D} = $customdp if $customdp;
        $envvars->{S} = $customsave if $customsave;
        $envvars->{CPU_FILE} = $customcpu if $customcpu;
        $envvars->{BPE_SERVER_HOST} = $bernserver if $bernserver;
        $envvars->{F_VERS} = 'GNUc' if $ENV{BERNESE_DEBUG} eq 'debug';

        my $bernenv = SetBerneseEnv( '', %$envvars );

        my $src = $options{SourceUserDirectory} || $ENV{X};
        die "Source for Bern user environment $src missing\n" if !-d $src;

        my $settings = $options{UserDirectorySettings};
        if ( !$settings ) {
            $settings = $DefaultBernUserSettings;
            my $customzip = $options{CustomUserFiles};
            if ($customzip) {
                $settings .= $DefaultBernUserSettingsUserPCF;
                if ( lc($customzip) ne 'empty' ) {
                    $settings .= "\nunzip $customzip";
                }
            }
            else {
                $settings .= $DefaultBernUserSettingsSystemPCF;
            }
        }

        if ( !$data_exists ) {
            $settings .= "\n"
              . ( $options{DataDirectorySettings} || $DefaultBernDataSettings );
        }

        my $templatedir = $options{TemplateDirectory};

        my $settingssrc = "bern user environment settings";

        if ($templatedir) {
            -d $templatedir
              || die "Bern user template $templatedir not defined\n";
            -f "$userdir/settings"
              || die
"Bern user template $templatedir doesn't include \"settings\" file\n";
            dircopy( $templatedir, $userdir );
            open( my $sf, "<$userdir/settings" )
              || die "Cannot open $userdir/settings file\n";
            $settings = join( '', <$sf> );
            $settingssrc = "$userdir/settings";
        }

        # Handle GEN dir settings
        my $gendir = $altgen || $bernenv->{X} . "/GEN";
        if ($customgen) {
            $settings = $CustomGenDirSettings . "\n" . $settings if $customgen;
        }
        elsif ($altgen) {
            $settings = $AlternativeGenDirSettings . "\n" . $settings
              if $customgen;
        }

        # Process the settings

        foreach my $line ( split( /\n/, $settings ) ) {
            next if $line =~ /^\s*(#|$)/;
            $line =~ s/\s*$//;
            my ( $key, @values ) = split( ' ', $line );
            foreach my $v (@values) {
                $v =~ s/\$\{SRC\}/$src/eg;
                $v =~ s/\$\{GEN\}/$gendir/eg;
                $v =~ s/\$\{(\w+)\}/$ENV{$1} || $env->{$1}/eg;
            }
            if ( $key =~ /^(CLIENT_ENV|CPU_FILE|PCF_FILE)$/ && @values == 1 ) {
                $env->{$key} = $values[0];
            }
            elsif ( $key eq 'makedir' && @values == 1 ) {
                make_path( $values[0] );
            }
            elsif ( $key eq 'symlink' && @values >= 2 ) {
                my $target = pop(@values);
                my $source;
                foreach my $v (@values) {
                    next if !-e $v;
                    $source = $v;
                    last;
                }
                die
"Cannot create bernese environment - cannot find source for $target\n"
                  if !$source;

                # If the target is a directory then copying a directory
                if ( $target =~ /^(.*)\/\*$/ ) {
                    if ( !-d $source ) {
                        die
"Cannot create bernese environment - $source is not a directory\n";
                    }
                    my $targetdir = $1;
                    make_path($targetdir) if !-d $targetdir;
                    opendir( my $sh, $source )
                      || die
                      "Cannot open bernese env source directory $source\n";
                    while ( my $file = readdir($sh) ) {
                        next if $file eq '.' || $file eq '..';
                        my $sf = "$source/$file";
                        my $tf = "$targetdir/$file";

                        # Don't overwrite existing files/dirs
                        next if -e $tf;
                        symlink( $sf, $tf )
                          || die
                          "Cannot create symbolic link from $sf to $tf\n";
                    }
                }
                else {
                    symlink( $source, $target )
                      || die
                      "Cannot create symbolic link from $source to $target\n";
                }

            }
            elsif ( $key eq 'copy' && @values == 2 ) {
                copy( $values[0], $values[1] )
                  || die "Cannot copy $values[0] to $values[1]\n";
            }
            elsif ( $key eq 'unzip' ) {
                foreach my $zipfile (@values) {
                    my $userdir = $ENV{U};
                    my $zip     = Archive::Zip->new();
                    if ( $zip->read($zipfile) != AZ_OK ) {
                        die "Cannot open GPSUSER zip file $zipfile\n";
                    }

                    foreach my $m ( $zip->members() ) {
                        if ( $m->isTextFile() || $m->isBinaryFile() ) {
                            my $filename = $m->fileName();
                            my $extname  = $userdir;
                            $extname .= '/' if $filename !~ /^\//;
                            $extname .= $filename;
                            if ( $m->extractToFileNamed($extname) != AZ_OK ) {
                                die "Cannot extract $filename from $zipfile\n";
                            }
                        }
                    }
                }
            }
            elsif ( $key eq 'setenv' ) {
                my $envvar = $values[0];
                my $envval = $values[1];
                die
"Bernese environment setting setenv requires an environment variable name and value\n"
                  if $envvar eq '' || $envval eq '';
                die
"Bernese environment setting setenv has invalid variable name $envvar\n"
                  if !exists $bernenv->{$envvar};
                $bernenv->{$envvar} = $envval;
                $ENV->{$envvar}     = $envval;
            }
            else {
                die "Invalid data in $settingssrc: $line\n";
            }
        }

        # Check the CPU file exists

        my $cpufile = $env->{CPU_FILE};
        die "CPU file $cpufile is missing\n"
          if !-f "$userdir/PAN/$cpufile.CPU";

        # Create the settings file

        my $settingsfile = $env->{CLIENT_ENV};
        open( my $svf, ">$settingsfile" )
          || die "Cannot create Bernese environment file $settingsfile\n";
        print $svf "# PositioNZ-PP Bernese client settings\n";
        foreach my $key ( sort keys %$bernenv ) {
            printf $svf "export %s=\"%s\"\n", $key, $bernenv->{$key};
        }
        my $timeout=$ENV{$LINZ::BERN::BernUtil::BerneseTimeoutVar};
        if( $timeout )
        {
            print $svf "export TIMEOUT=\"$timeout\"\n";
        }
        close($svf);
    };
    if ($@) {
        my $error = $@;
        remove_tree( $userdir, { error => \$patherror } );
        remove_tree( $datadir, { error => \$patherror } ) if !$data_exists;
        croak($error);
    }
    $env->{_deluserdir} = $userdir;
    $env->{_deldatadir} = $datadir if !$data_exists;

    return $env;
}

=head2 LINZ::BERN::BernUtil::DeleteRuntimeEnvironment( $env ) 

Deletes a runtime environment created by CreateRuntimeEnvironment.

=cut

sub DeleteRuntimeEnvironment {
    my ($env) = @_;
    my $patherror;
    my $userdir = $env->{_deluserdir};
    my $datadir = $env->{_deldatadir};
    remove_tree( $userdir, { error => \$patherror } ) if $userdir;
    remove_tree( $datadir, { error => \$patherror } ) if $datadir;
}

=head2 LINZ::BERN::BernUtil::InstallCampaignFiles($campaign,$files,$options)

Install PCF campaign files, installs files into the campaign directories.

Parameters are:

=over

=item campaign: The campaign to install the files into

=item files: Either a single file specification or an array of file specifications

=item options: Additional options for installation

=back

Each file specification defines a campaign directory and a file to copy in to it, eg

    SOL mydir/mfile/MYSINEX.SNX ...
    SOL uncompress mydir/myfile/MYSINEX.SNX.Z ...

A specification string can include multiple specifications separated by new
lines.  Filenames can include wildcards.  The uncompress option can be applied
to files ending .gz or .Z

Filenames prepended with ~/ are relative to a specified source directory, 
defined in $options{SourceDirectory}, otherwise relative to current directory.

The specification can also be a .ZIP file in which each each file name ends
with a campaign directory and filename.  This is specified either as simply
the name of the zip file, or using a campaign directory name of ZIP, ie

    ZIP zipname

Note: This uses a very inconsistent syntax with the user directory configuration,
- this has been adapted from the LINZ::GNSS::DailyProcessor function.

=cut

sub InstallCampaignFiles {
    my ( $campaign, $files, %options ) = @_;
    my $campdir = $campaign->{campaigndir};

    my @specifications = ();
    my @zipfiles       = ();
    my $srcdir         = $options{SourceDirectory} || '.';
    $files = [$files] if ref($files) ne 'ARRAY';
    foreach my $speclist (@$files) {
        foreach my $spec ( split( ( "\n", $speclist ) ) ) {
            croak("Invalid campaign file specification $spec")
              if $spec !~ /^\s*(?:([A-Z]+)(?:\s+(uncompress))?\s+)?(\S.*?)\s*$/;
            my $subdir = $1 || 'ZIP';
            croak("Invalid campaign directory $subdir in specification $spec")
              if $subdir ne 'ZIP' && !-d "$campdir/$subdir";
            my $uncompress = $2 ne '';
            my $filename   = $3;
            $filename =~ s/^\~\//$srcdir\//;
            if ( $subdir eq 'ZIP' ) {
                push( @zipfiles, $filename );
                next;
            }
            else {
                foreach my $srcfile ( split( ' ', $filename ) ) {
                    push( @specifications, [ $subdir, $uncompress, $srcfile ] );
                }
            }
        }
    }

    # Install zip files

    my @installed = ();

    foreach my $zipfile (@zipfiles) {
        if ( !-f $zipfile ) {
            croak("Cannot find campaign zip file $zipfile\n");
        }
        my $zip = Archive::Zip->new();
        if ( $zip->read($zipfile) != AZ_OK ) {
            croak("Cannot read campaign zip file $zipfile\n");
        }
        foreach my $zf ( $zip->memberNames() ) {
            my ( $zdir, $zname ) = ( $1, $2 ) if $zf =~ /^(\w+)\/([\w\.]+)$/;
            if ( !$zdir || ! -d "$campdir/$zdir" ) {
                croak("Invalid file name $zf in campaign zip file $zipfile");
            }
            if ( $zip->extractMember( $zf, "$campdir/$zf" ) != AZ_OK ) {
                croak("Failed to extract $zf from campaign zip file $zipfile");
            }
            push( @installed, "$zdir/$zname" );
        }
    }

    # Install campaign files
    foreach my $spec (@specifications) {
        my ( $subdir, $uncompress, $filename ) = @$spec;

        # Otherwise copy file(s) to target directory
        my $filedir = $campdir . '/' . $subdir;
        if ( !-d $filedir ) {
            croak("Invalid target directory $subdir in campaign file list");
        }
        my @files = ($filename);
        if ( $filename =~ /[\*\?]/ ) {
            @files = glob($filename);
        }
        foreach my $file (@files) {
            if ( !-f $file ) {
                croak("Cannot find pcf_campaign_file $file");
            }
            my $campfile = $file;
            $campfile =~ s/.*[\\\/]//;
            my $campspec = $filedir . '/' . $campfile;
            if ( !copy( $file, $campspec ) ) {
                croak("Cannot copy pcf_campaign_file $file to $filedir");
            }
            if ( $uncompress && $campspec =~ /^(.*)\.(gz|Z)$/ ) {
                my ( $uncompfile, $type ) = ( $1, $2 );
                my $prog = $type eq 'gz' ? 'gzip' : 'compress';
                my $progexe = File::Which::which($prog);
                if ( !$prog ) {
                    croak("Cannot find compression program $prog");
                }
                system( $progexe, '-d', $campspec );
                if ( !-f $uncompfile ) {
                    croak("Failed to uncompress $subdir/$campfile");
                }
                $campfile =~ s/\.(gz|Z)//;
            }
            push( @installed, "$subdir/$campfile" );
        }
    }
    return \@installed;
}

=head2 $campaign = LINZ::BERN::BernUtil::CreateCampaign($jobid,%options)

Create the campaign directories for a new job.  If the job id includes a string
of hash characters ### then the job will be created in the first non-existing 
directory replacing ### with number 001, 002, ...

The script returns a hash defining the campaign, which can be submitted 
to LINZ::BERN::BernUtil::RunPcf to run the job.

Options can include

=over

=item RinexFiles=>[file1,file2,...]

Adds specified files to the RAW directory.  Rinex files may be modified to 
ensure unique station codes, and potentially to modify antennae and receiver
names.

=item CampaignFiles=>[spec1,spec2,...]

Specifies files to install into the campaign.  Specifications are as
defined for InstallCampaignFiles

=item MakeSessionFile=>1

Creates a session file 

=item UseStandardSessions=>0,1,2

Creates a fixed session file for the time span of the rinex files if 0, 
a daily session file if 1, or an hourly session file if 2.

=item SetSession=>[starttime,endtime]

Defines the start time and end time for a session, overrides those from the
data files if provided.  Alternatively can be a date string recognized by
parse_gnss_date, in which case UseStandardSessions is set to 1.

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
apply to files and mark names which match the listed codes. If 
RenameCodes is specified and RenameRinex is not, then codes matching 
the list will be replaced using a minimal replacement.

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

sub CreateCampaign {
    my ( $job, %options ) = @_;
    my $campdir = $ENV{P};
    croak("Bernese campaign directory \$P not set\n") if !-d $campdir;

    # If automatically allocating a new job then do so now...
    if ( $job =~ /^(\w+)(\#+)(\w*)$/ ) {
        my ( $prefix, $ndigit, $suffix ) = ( $1, length($2), $3 );
        my $format = "%0" . $ndigit . "d";
        my $nextid = 1;
        while (1) {
            $job = $prefix . sprintf( $format, $nextid++ ) . $suffix;
            last if !-e "$campdir/$job";
        }
    }

    my $jobdir = "$campdir/$job";

    my $now = seconds_datetime( time(), 1 );
    my $campaign = {
        JOBID       => $job,
        CAMPAIGN    => "\${P}/$job",
        variables   => {},
        createtime  => $now,
        campaigndir => $jobdir,
        runstatus   => {},
    };
    my $existing = -d $jobdir;

    my $files = ();

    eval {
        remove_tree($jobdir) if -d $jobdir && $options{CanOverwrite};
        croak("Job $job already exists\n") if -d $jobdir;
        $existing = 0;
        mkdir($jobdir) || croak("Cannot create campaign directory $jobdir\n");
        for my $subdir (qw/ATM BPE GRD OBS ORB ORX OUT RAW SOL STA/) {
            mkdir("$jobdir/$subdir")
              || croak("Cannot create campaign directory $jobdir/$subdir\n");
        }
        my @files  = ();
        my @marks  = ();
        my $start  = 0;
        my $end    = 0;
        my $sessid = '';
        my $crdfile;

        if ( $options{CampaignFiles} ) {
            my $campaignfiles = $options{CampaignFiles};
            $campaignfiles=[$campaignfiles] if ref($campaignfiles) ne 'ARRAY';
            if (@$campaignfiles) {
                InstallCampaignFiles( $campaign, @$campaignfiles );
            }
        }

        if ( $options{RinexFiles} ) {
            my $rinexfiles = $options{RinexFiles};
            $rinexfiles = [$rinexfiles] if !ref $rinexfiles;

            if (@$rinexfiles) {
                my $letters     = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
                my %usedfile    = ();
                my %codemap     = ();
                my $rename      = 0;
                my %renamecodes = ();
                my $nextname    = 0;

                if ( ref( $options{RenameCodes} ) eq 'ARRAY' ) {
                    $renamecodes{''} = 1;
                    foreach my $code ( @{ $options{RenameCodes} } ) {
                        $renamecodes{ uc($code) } = 1;
                    }
                }

                # If rename specified
                if ( $options{RenameRinex} ne '' ) {
                    my $newname = uc( $options{RenameRinex} );
                    croak("Invalid RenameRinex code $newname\n")
                      if length($newname) != 4
                      || $newname !~ /^(\w*)(\#+)(\w*)$/;
                    my ( $prefix, $ndigit, $suffix ) = ( $1, length($2), $3 );
                    my $nextid = 1;
                    my $maxid  = 10**$ndigit - 1;
                    my $format = "%0" . $ndigit . "d";
                    $nextname = sub {
                        croak("Too many RINEX files to rename sequentially\n")
                          if $nextid >= $maxid;
                        return
                            $prefix
                          . sprintf( $format, $nextid++ )
                          . $suffix;
                    };
                    $rename = 1;
                }

  # If only have RenameCodes specified, then try replacing characters in current
  # code starting at the end.
                elsif ( $options{RenameCodes} ) {
                    $nextname = sub {
                        my ($code) = @_;
                        return $code if !exists $renamecodes{$code};
                        my $newcode = '';
                        foreach my $i ( 3, 2, 1, 0 ) {
                            my $tmplt =
                              substr( $code, 0, $i ) . '%0' . ( 4 - $i ) . 'd';
                            my $max = 10**( 4 - $i ) - 1;
                            foreach my $j ( 1 .. $max ) {
                                my $test = sprintf( $tmplt, $j );
                                if ( !exists $renamecodes{$test} ) {
                                    $newcode = $test;
                                    last;
                                }
                            }
                            last if $newcode ne '';
                        }
                        if ( $newcode eq '' ) {
                            croak(
                                "Cannot generate alternative name for $code\n");
                        }
                        return $newcode;
                    };
                    $rename = 1;
                }

                my %rnxfiles = ();

                foreach my $rnxfile (@$rinexfiles) {
                    my $rf = new LINZ::GNSS::RinexFile($rnxfile);

                    my $srcfile = basename($rnxfile);
                    my $srccode = $rf->markname;

                    my $rawname = uc($srcfile);
                    my $rawcode = uc($srccode) . $rawname . '0000';
                    $rawcode =~ s/\W//g;
                    $rawcode = substr( $rawcode, 0, 4 );

                    my $renamefile = $rename;
                    $renamefile = 0 if %renamecodes && !$renamecodes{$rawcode};

                    if ($renamefile) {
                        $codemap{$rawcode} = $nextname->($rawcode)
                          if !exists $codemap{$rawcode};
                        $rawcode = $codemap{$rawcode};
                        $rawname = $rawcode . substr( $rawname, 4 );
                    }

                    my $rstart = $rf->starttime;
                    my $rend   = $rf->endtime;
                    $start = $rstart if $start == 0 || $rstart < $start;
                    $end   = $rend   if $end == 0   || $rend > $end;

                    my ( $year, $doy, $hour ) =
                      ( time_elements($rstart) )[ 0, 2, 4 ];
                    $doy = sprintf( "%03d", $doy );
                    $year = substr( sprintf( "%04d", $year ), 2, 2 );

                    my $validre = "^$rawcode$doy.\\.${year}O\$";

                    if ( $rawname !~ /$validre/ || $usedfile{$rawname} ) {
                        my $hcode = substr( $letters, $hour, 1 );
                        if ( $hour == 0 && $rend - $rstart > ( 3600 * 23.0 ) ) {
                            $hcode = '0';
                        }

                        my $ic = 0;
                        $rawname = '';
                        while ( $hcode ne '' ) {
                            my $name = "$rawcode$doy$hcode.${year}O";
                            if ( !exists( $usedfile{$name} ) ) {
                                $rawname = $name;
                                last;
                            }
                            $hcode = substr( $letters, $ic++, 1 );
                        }
                        if ( !$rawname ) {
                            croak(
"Cannot build a unique valid name for file $srcfile\n"
                            );
                        }
                    }

                    my $anttype = sprintf( "%-20.20s", $rf->anttype );
                    my $rectype = $rf->rectype;

                    my $srcanttype = $anttype;
                    my $srcrectype = $rectype;

                    if ( $options{FixRinexAntRec} ) {
                        my $edits = FixRinexAntRec($rf);
                        $anttype = $edits->{antenna}->{to}
                          if exists $edits->{antenna};
                        $rectype = $edits->{receiver}->{to}
                          if exists $edits->{receiver};
                    }
                    elsif ( $options{AddNoneRadome} ) {
                        substr( $anttype, 16, 4 ) = 'NONE'
                          if substr( $anttype, 16, 4 ) eq '    ';
                        $rf->anttype($anttype);
                    }

                    my $dehn      = $rf->delta_hen;
                    my $antheight = 0.0;
                    $antheight = $dehn->[0] if ref($dehn);

                    $rf->markname($rawcode);
                    $rf->write("$jobdir/RAW/$rawname");

                    push(
                        @files,
                        {
                            orig_filename => $srcfile,
                            orig_markname => $srccode,
                            orig_anttype  => $srcanttype,
                            orig_rectype  => $srcrectype,
                            filename      => $rawname,
                            markname      => $rawcode,
                            anttype       => $anttype,
                            antheight     => $antheight,
                            rectype       => $rectype,
                        }
                    );
                    push( @marks, $rf->markname );
                }
            }
            $campaign->{marks} = \@marks;
            $campaign->{files} = \@files;
        }
        my $sesstype=$options{UseStandardSessions};
        if ( $options{SetSession} ) {
            my $sessdef=$options{SetSession};
            if( ref($sessdef) eq 'ARRAY')
            {
                $start = $options{SetSession}->[0];
                $end   = $options{SetSession}->[1];
            }
            else
            {
                $start = $end=parse_gnss_date($sessdef);
                $sesstype = 1;
            }
        }
        if ($start) {
            $campaign->{session_start} = $start;
            $campaign->{session_end}   = $end;
            if ( $options{MakeSessionFile} ) {
                my $sfn = "$jobdir/STA/SESSIONS.SES";
                my $sf  = new LINZ::BERN::SessionFile($sfn);
                if ( !$sesstype ) {
                    $sessid = $sf->addSession( $start, $end );
                }
                else {
                    my $hourly = $sesstype == 2;
                    $sf->resetDefault($hourly);
                    $sessid = $sf->getSession($start);
                }
                $sf->write();
                $campaign->{SES_INFO} = $sessid;
                $campaign->{YR4_INFO} = ( time_elements($start) )[0];
            }
        }
        if ( $options{CrdFile} ) {
            my $cfn = $options{CrdFile};
            $cfn =~ s/\$S\+0/$sessid/g;
            my $crdfilename = "$jobdir/STA/$cfn.CRD";
            eval {
                # Note - currently not adding stations to coordinate file
                # as Bernese software can do this on RINEX import.
                $crdfile = new LINZ::BERN::CrdFile($crdfilename);
                if ($start) { $crdfile->epoch($start); }
                $crdfile->write();
                if ( $options{AbbFile} ) {
                    my $abbfilename =
                      "$jobdir/STA/" . $options{AbbFile} . ".ABB";
                    $crdfile->writeAbbreviationFile($abbfilename);
                }
            };
            if ($@) {
                croak("Cannot create coordinate file $crdfilename\n");
            }
        }

        if ( $options{SettingsFile} ) {
            if ( open( my $of, ">$jobdir/OUT/SETTINGS.JSON" ) ) {
                print $of JSON::PP->new->pretty->utf8->encode($campaign);
                close($of);
            }
        }

        if ( $options{SetupUserMenu} ) {
            my ($year) = ( time_elements($start) )[0];
            SetUserCampaign( $job, $campaign );
        }

        if ( $options{UpdateCampaignList} ) {
            UpdateCampaignList();
        }
    };
    if ($@) {
        my $error = $@;
        if ( -d $jobdir && !$existing ) {
            remove_tree($jobdir);
        }
        croak($@);
    }

    return $campaign;
}

=head2 $status=LINZ::BERN::BernUtil::RunPcf($pcf,$campaign,$environment)

Runs a Bernese script (PCF) on the campaign as created by CreateCampaign.

Parameters are:

=over

=item $pcf

The name of the PCF file to run

=item $campaign

The campaign - a hash ref as returned by CreateCampaign

=item $environment

Optional runtime environment (a hash reference).  Currently supported keys are:

=over 

=item CLIENT_ENV=>$client_env_filename

=item CPU_FILE=>$cpu_file

=back

This variable can be replaced with the environment returned by CreateRuntimeEnvironment
(ie %$environment).

=back

This adds two elements to the campaign hash:

=over

=item runstatus

The status returned by LINZ::BERN::RunPcfStatus

=item bernese_status

The status returned by the startBPE object ERROR_STATUS variable

=back

The script returns the bernese error status, which is empty if the script completes
successfully.

=cut

sub RunPcf {
    my ( $campaign, $pcf, $environment ) = @_;

    $environment ||= {};
    my %options = %$environment;

    # Check USER is set (used by Bernese)
    $ENV{USER} =  (getpwuid($REAL_USER_ID))[0] if ! $ENV{USER};

    # Check that the PCF file exists
    #
    my $userdir = $ENV{U};
    croak("Bernese user directory \$U not set\n") if !-d $userdir;
    my $bpedir = $ENV{BPE};
    croak("Bernese BPE not set\n") if !-e $bpedir;
    @INC = grep { $_ ne $bpedir } @INC;
    unshift( @INC, $bpedir );
    require startBPE;

    my $pcffile = "$userdir/PCF/$pcf.PCF";
    croak("Cannot find PCF file $pcf\n") if !-e $pcffile;

    # Set up user variables

    # Create the processing task
    my $bpe = new startBPE( %{ $campaign->{variables} } );
    $bpe->{BPE_CAMPAIGN} = $campaign->{CAMPAIGN};
    $bpe->{CLIENT_ENV}   = $options{CLIENT_ENV} if exists $options{CLIENT_ENV};
    $bpe->{CPU_FILE}     = $options{CPU_FILE} || 'USER';
    $bpe->{S_CPU_FILE}   = $options{CPU_FILE} || 'USER';
    $bpe->{PCF_FILE}     = $pcf;
    $bpe->{SESSION}      = $campaign->{SES_INFO};
    $bpe->{YEAR}         = $campaign->{YR4_INFO};

    $bpe->{SYSOUT} = $pcf;
    $bpe->{STATUS} = $pcf . '.SUM';

    $bpe->resetCPU();
    $bpe->resetCPU( $bpe->{S_CPU_FILE} );

    $bpe->run();

    $campaign->{bernese_status} = $bpe->{ERROR_STATUS};
    my $result = LINZ::BERN::BernUtil::RunPcfStatus($campaign);
    $campaign->{runstatus} = $result;
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

sub RunPcfStatus {
    my ($campaigndir) = @_;
    if ( ref($campaigndir) ) {
        $campaigndir = $campaigndir->{campaigndir};
    }
    $campaigndir = $ENV{P} . "/$campaigndir"
      if $campaigndir =~ /^\w+$/ && exists $ENV{P};
    my $campdirname = $campaigndir;
    $campdirname =~ s/.*[\\\/]//;
    $campdirname = '${P}/' . $campdirname;

    my $bpedir = $campaigndir . '/BPE';
    croak("Campaign BPE directory $campdirname/BPE is missing\n")
      if !-e $bpedir;

    my %logs = ();
    my @out  = ();
    opendir( my $bd, $bpedir ) || return;
    foreach my $f ( readdir($bd) ) {
        my $bf = $bpedir . '/' . $f;
        push( @out, $bf ) if -f $bf && $f =~ /\.OUT$/;
        $logs{$1} = $bf if -f $bf && $f =~ /_(\d\d\d_\d\d\d).LOG$/;
    }
    closedir($bd);
    @out = sort { -M $a <=> -M $b } @out;

    # Read the run output directory

    croak("Cannot find BPE output file in $bpedir\n") if !@out;

    my $sysout = $out[0];
    open( my $sof, "<$sysout" )
      || croak("Cannot open BPE output file $sysout\n");
    my $header = <$sof>;
    my $spacer = <$sof>;
    croak("$sysout doesn't seem to be a BPE SYSOUT file\n")
      if $header !~ /^\s*time\s+sess\s+pid\s+script\s+option\s+status\s*$/i;

    my $failrun   = '';
    my $runstatus = 'OK';
    while ( my $line = <$sof> ) {
        my ( $run, $status ) = split( /\s+\:\s+/, $line );
        next if $status !~ /^script\s+finished\s+(\w+)/i;
        $runstatus = $1;
        if ( $runstatus ne 'OK' ) {
            $failrun = $run;
            last;
        }
    }
    close($sof);

    my $result = { status => $runstatus };

    if ( $runstatus ne 'OK' ) {
        my ( $date, $time, $sess, $pidr, $script, $option ) =
          split( ' ', $failrun );
        my $pid     = $1 if $pidr =~ /^(\d+)/;
        my $lfile   = $logs{$pidr};
        my $fulllog = '';
        my $prog    = '';
        my $failure = '';
        if ( $lfile && open( my $lf, "<$lfile" ) ) {
            while ( my $line = <$lf> ) {
                $fulllog .= $line;
                $prog = $1 if $line =~ /Call\s+to\s+(\w+)\s+failed\:/i;
                if ( $line =~ /^\s*\*\*\*\s.*?\:\s*(.*?)\s*$/ ) {
                    $failure .= '/ ' . $1;
                    while ( $line = <$lf> ) {
                        $fulllog .= $line;
                        last if $line =~ /^\s*$/;
                        $line =~ s/^\s*//;
                        $line =~ s/\s*$//;
                        $failure .= ' ' . $line;
                    }
                    last if !$line;
                }
            }
        }
        $result->{fail_pid}     = $pid;
        $result->{fail_script}  = $script;
        $result->{fail_prog}    = $prog;
        $failure = substr($failure,2);
        $failure = $fulllog if $failure =~ /^\s*$/ || $ENV{BERNESE_DEBUG} eq 'debug';
        $result->{fail_message} = $failure;
    }

    return $result;
}

=head2 my $result=LINZ::BERN::BernUtil::RunBerneseJob( pcf, %options )


Create a Bernese environment.  Creates a runtime environment, creates a campaign,
runs the PCF, and deletes the runtime environment.  

Takes all the options defined for CreateRuntimeEnvironment and CreateCampaign, plus
additional options:

=over

=item JobId.  The identifier for the campaign, otherwise the name of the PCF

=item KeepEnvironment.  If set the the runtime environment is not deleted

=back

Returns a hash $result which contains:

=over

=item result: The result status code - "OK", "FAIL", or "EXCEPTION"

=item status: More detailed status information in a hash including fail_message if status != OK.

=item environment: The runtime environment if KeepEnvironment option is set.

=back

=cut 

sub RunBerneseJob {
    my ( $pcf, %options ) = @_;

    my $result = { statuscode => 'PENDING' };
    my ($environment, $campaign);
    eval {
        $environment = LINZ::BERN::BernUtil::CreateRuntimeEnvironment(%options);
        $campaign = LINZ::BERN::BernUtil::CreateCampaign($pcf,%options);
        LINZ::BERN::BernUtil::RunPcf( $campaign, $pcf, $environment );
        $result->{status}     = LINZ::BERN::BernUtil::RunPcfStatus($campaign);
        $result->{statuscode} = $result->{status}->{status};
    };
    if ($@) {
        $result->{statuscode} = 'EXCEPTION';
        $result->{status}->{fail_message} = $@;
    }

    if ( $environment && !$options{KeepEnvironment} ) {
        LINZ::BERN::BernUtil::DeleteRuntimeEnvironment($environment);
        $environment = undef;
    }
    else {
        $result->{environment} = $environment;
        $result->{campaign} = $campaign;
    }
    return $result;
}

=head2 LINZ::BERN::BernUtil::SetUserCampaign($job,$campaign)

Setup the user environment for the specified campaign.  Can take
session and year information from a campaign hash as SES_INFO and YR4_INFO,
or if not defined there will try a SETTINGS.JSON file.

=cut

sub SetUserCampaign {
    my ( $job, $campaign ) = @_;
    $campaign ||= {};
    my $campdir = $ENV{P};
    croak("Bernese environment \$P not set\n") if !-d $campdir;
    my $jobdir = "$campdir/$job";
    croak("Campaign $job does not exist\n") if !-d $jobdir;
    my $settingsfile = "$jobdir/OUT/SETTINGS.JSON";
    my $settings     = {};
    if ( -e $settingsfile ) {
        eval {
            if ( open( my $sf, "<$settingsfile" ) ) {
                my $sfdata = join( '', <$sf> );
                close($sf);
                $settings = JSON::PP->new->utf8->decode($sfdata);
            }
        };
    }
    my $sessid = $campaign->{SES_INFO} || $settings->{SES_INFO};
    my $year   = $campaign->{YR4_INFO} || $settings->{YR4_INFO};

    my $doy      = substr( $sessid, 0, 3 );
    my $sesschar = substr( $sessid, 3, 1 );
    my $julday =
      $year ne '' && $sessid ne ''
      ? seconds_julianday( year_seconds($year) ) + ( $doy - 1 )
      : 0;
    my $menufile = $ENV{U} . '/PAN/MENU.INP';
    croak("\$U/PAN/MENU.INP does not exists or is not writeable\n")
      if !-r $menufile || !-w $menufile;
    my @menudata = ();
    open( my $mf, "<$menufile" ) || croak("Cannot open $menufile for input\n");

    while ( my $line = <$mf> ) {
        if ( $line =~ /^(\s*ACTIVE_CAMPAIGN\s+1\s+)/ ) {
            $line = $1 . "\"\${P}/$job\"\n";
        }
        elsif ( $line =~ /^(\s*SESSION_TABLE\s+1\s+)/ ) {
            $line = $1 . "\"\${P}/$job/STA/SESSIONS.SES\"\n";
        }
        elsif ( $line =~ /^(\s*MODJULDATE\s+1\s+)/ && $julday ) {
            $line = $1 . sprintf( "\"%d.000000\"\n", $julday );
        }
        elsif ( $line =~ /^(\s*SESSION_CHAR\s+1\s+)/ && $sessid ne '' ) {
            $line = $1 . "\"$sesschar\"\n";
        }
        push( @menudata, $line );
    }
    close($mf);
    open( $mf, ">$menufile" ) || croak("Cannot open $menufile for output\n");
    print $mf @menudata;
    close($mf);
}

=head2 LINZ::BERN::BernUtil::UpdateCampaignList

Updates the MENU_CMP.INP with the current list of campaigns

=cut

sub UpdateCampaignList {
    my $menufile = $ENV{U} . '/PAN/MENU.INP';
    open( my $mf, "<$menufile" ) || croak("Cannot open \${U}/PAN/MENU.INP\n");
    my $campfile;
    while ( my $line = <$mf> ) {
        if ( $line =~ /^\s*MENU_CMP_INP\s+1\s+\"([^\"]*)\"\s*$/ ) {
            $campfile = $1;
            last;
        }
    }
    croak("MENU_CMP_INP not defined in \${U}/PAN/MENU.INP\n")
      if !$campfile;
    my $campdef = $campfile;
    $campfile =~ s/\$\{(\w+)\}/$ENV{$1}/eg;
    croak("Campaign menu $campdef doesn't exist\n") if !-f $campfile;

    my @camplist = ();
    my $campdir  = $ENV{P};
    opendir( my $cdir, $campdir )
      || croak("Cannot open campaign directory \${P}\n");
    while ( my $cmpn = readdir($cdir) ) {
        next if $cmpn !~ /^\w+$/;
        next if !-d "$campdir/$cmpn";
        next if !-d "$campdir/$cmpn/OUT";
        my $cmpns = $cmpn;
        $cmpns =~ s/(\d+)/sprintf("%05d",$1)/eg;
        $cmpns = $cmpns . ":\"\${P}/$cmpn\"";
        push( @camplist, $cmpns );
    }
    @camplist = map { s/.*\://; $_ } sort @camplist;

    open( my $cf, "<$campfile" )
      || croak("Cannot open campaign file $campdef\n");
    my @mcamp = <$cf>;
    close($cf);

    my ( $ncmp, $nlin ) = ( -1, -1 );
    foreach my $i ( 0 .. $#mcamp ) {
        if ( $mcamp[$i] =~ /^\s*CAMPAIGN\s+(\d+)/ ) {
            $ncmp = $1;
            $nlin = $i;
            last;
        }
    }
    croak("Campaign menu $campdef missing CAMPAIGN\n") if $nlin < 0;

    my $newncmp = scalar(@camplist);
    my $newcamp = "CAMPAIGN $newncmp";
    $newcamp .= "\n  " if $newncmp > 1;
    $newcamp .= join( "\n  ", @camplist );
    $newcamp .= "\n";
    $ncmp += 1 if $ncmp != 1;
    splice( @mcamp, $nlin, $ncmp, $newcamp );

    open( $cf, ">$campfile" )
      || croak("Cannot update campaign file $campdef\n");
    print $cf @mcamp;
    close($cf);
    return $newncmp;
}

=head2 $antennae=LINZ::BERN::BernUtil::AntennaList;

Returns an array or array hash of valid antenna names.

=cut

sub AntennaList {
    my $brndir = $ENV{X};
    my $gendir = $brndir . '/GEN';
    die "BERN environment not set\n" if !$brndir || !-d $gendir;

    my $antfile = $gendir . '/' . $AntennaFile;
    if ( $antfile ne $LoadedAntFile ) {
        $LoadedAntennae = [];
        open( my $af, "<$antfile" )
          || die "Cannot find antenna file $antfile\n";

        while ( my $line = <$af> ) {
            next if $line !~ /^ANTENNA\/RADOME\s+TYPE\s+NUMBER/;
            $line = <$af>;
            $line = <$af> if $line;
            last if !$line;
            my $ant = substr( $line, 0, 20 );
            next if $ant !~ /\S/;
            next if $ant =~ /^MW\s+/;
            next if $ant =~ /^SLR\s+/;

            # Filter out antennae not calibrated for dual frequency GPS obs
            my $ngpsfrq = 0;
            while ( $line !~ /^\s*$/ ) {
                my $sys = substr( $line, 28, 1 );
                if ( $sys eq 'G' ) {
                    $ngpsfrq = substr( $line, 32, 3 ) + 0;
                    last;
                }
                $line = <$af>;
            }
            next if $ngpsfrq < 2;
            push( @$LoadedAntennae, $ant );
        }
        close($af);
    }
    my @antennae = @$LoadedAntennae;

    return wantarray ? @antennae : \@antennae;
}

=head2 $antenna=LINZ::BERN::BernUtil::BestMatchingAntenna($ant)

Return the best matching antenna to the supplied antenna.
The best match is based upon the maximum number of matched leading characters,
and the first in alphabetical order if there is a tie.  The radome
supplied is preferred, otherwise a match with none is used.

=cut

sub BestMatchingAntenna {
    my ($ant) = @_;
    $ant = uc($ant);
    $ant = substr( $ant . ( ' ' x 20 ), 0, 20 );
    my $radome = substr( $ant, 16 );
    $ant = substr( $ant, 0, 16 );
    $radome = 'NONE' if $radome eq '    ';

    my %validAnt = map { $_ => 1 } AntennaList();
    return $ant . $radome if exists $validAnt{ $ant . $radome };
    return $ant . 'NONE'  if exists $validAnt{ $ant . 'NONE' };

    # Build a regular expression to match as much of
    # the antenna string as possible;

    my $repre = '^(';
    my $resuf = ')';
    foreach my $c ( split( //, $ant ) ) {
        $repre .= '(?:' . quotemeta($c);
        $resuf = ')?' . $resuf;
    }
    my $re = $repre . $resuf;

    my $maxmatch = -1;
    my $matchant = '';
    foreach my $vldant ( sort keys %validAnt ) {
        $vldant =~ /$re/;
        my $nmatch = length($1) * 2;
        $nmatch++ if substr( $vldant, 16 ) eq $radome;
        if ( $nmatch > $maxmatch ) {
            $maxmatch = $nmatch;
            $matchant = $vldant;
        }
    }
    return $matchant;
}

=head2 $receivers=LINZ::BERN::BernUtil::ReceiverList;

Returns an array or array hash of valid receiver names.

=cut

sub ReceiverList {
    my $brndir = $ENV{X};
    my $gendir = $brndir . '/GEN';
    die "BERN environment not set\n" if !$brndir || !-d $gendir;

    my $recfile = $gendir . '/' . $ReceiverFile;
    if ( $recfile ne $LoadedRecFile ) {
        $LoadedReceivers = [];

        open( my $af, "<$recfile" )
          || die "Cannot find receiver file $recfile\n";

        my $receivers = [];
        my $nskip     = 6;
        my $line;
        while ( $nskip-- && ( $line = <$af> ) ) { }

        while ( $line = <$af> ) {
            last if $line =~ /^REMARK\:/;
            my $rec = substr( $line, 0, 20 );
            next if $rec !~ /\S/;
            $rec =~ s/\s*$//;

            # Check that the receiver handles GPS system
            next if substr( $line, 49 ) !~ /G/;

            # Check this is a dual frequency receiver
            my $freq = substr( $line, 35, 2 );
            while ( $line = <$af> ) {
                last if $line =~ /^\s*$/;
                $freq .= ' ' . substr( $line, 35, 2 );
            }
            next if $freq !~ /L1/;
            next if $freq !~ /L2/;

            push( @$LoadedReceivers, $rec );
        }
        close($af);
    }

    my @receivers = @$LoadedReceivers;

    return wantarray ? @receivers : \@receivers;
}

=head2 $receiver=LINZ::BERN::BernUtil::BestMatchingReceiver($rec)

Return the best matching receiver to the supplied receiver.
The best match is based upon the maximum number of matched leading characters,
and the first in alphabetical order if there is a tie.  

=cut

sub BestMatchingReceiver {
    my ($rec) = @_;
    $rec = uc($rec);
    $rec =~ s/\s+$//;

    my %validRec = map { $_ => 1 } ReceiverList();
    return $rec if exists $validRec{$rec};

    # Build a regular expression to match as much of
    # the receiver string as possible;

    my $repre = '^(';
    my $resuf = ')';
    foreach my $c ( split( //, $rec ) ) {
        $repre .= '(?:' . quotemeta($c);
        $resuf = ')?' . $resuf;
    }
    my $re = $repre . $resuf;

    my $maxmatch = -1;
    my $matchrec = '';
    foreach my $vldrec ( sort keys %validRec ) {
        $vldrec =~ s/
        $vldrec=~/$re/;
        my $nmatch = length($1);
        if ( $nmatch > $maxmatch ) {
            $maxmatch = $nmatch;
            $matchrec = $vldrec;
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

sub FixRinexAntRec {
    my ($rinexfile) = @_;
    my $edits       = {};
    my $rx          = $rinexfile;

    $rx = new LINZ::GNSS::RinexFile( $rinexfile, skip_obs => 1 )
      if !ref($rinexfile);

    my $rnxant = $rx->anttype;
    my $rnxrec = $rx->rectype;

    my $vldant = BestMatchingAntenna($rnxant);
    my $vldrec = BestMatchingReceiver($rnxrec);

    return $edits if $vldant eq $rnxant && $vldrec eq $rnxrec;

    $rx->anttype($vldant);
    $rx->rectype($vldrec);

    $edits->{antenna} = { from => $rnxant, to => $vldant }
      if $rnxant ne $vldant;
    $edits->{receiver} = { from => $rnxrec, to => $vldrec }
      if $rnxrec ne $vldrec;

    if ( !ref($rinexfile) ) {
        my $tmpfile = $rinexfile . '.rnxtmp';
        $rx->write($tmpfile);
        if ( -f $tmpfile ) {
            unlink($rinexfile) || croak("Cannot replace $rinexfile\n");
            rename( $tmpfile, $rinexfile )
              || croak("Cannot rename $tmpfile to $rinexfile\n");
        }
    }
    return $edits;
}

1;
