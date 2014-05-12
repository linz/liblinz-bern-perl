#!usr/bin/perl
use strict;
use warnings;

use Config;
use Module::Build;

my $requires = {
    'Carp' => 0,
    'Config::General' => 0,
    'DBI' => 0,
    'DBD::SQLite' => 0,
    'File::Basename' => 0,
    'File::Copy' => 0,
    'File::Path' => 0,
    'JSON::PP' => 0,
    'LINZ::GNSS::RinexFile' => 0,
    'LINZ::GNSS::Time' => 0,
};

my $build =  Module::Build->new(
    module_name        => 'LINZ::BERN',
    license            => 'bsd',
    dist_author        => 'LINZ',
    dist_version_from  => 'lib/LINZ/BERN/BernUtil.pm',
    dist_abstract      => 'Modules to support LINZ Bernese utilities',
    requires           => $requires,
    create_makefile_pl => 'small',
);

$build->create_build_script;
