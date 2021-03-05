=head1 LINZ::BERN

Packages for interfacing with the Bernese GNSS suite

See:

=over

=item LINZ::BERN::BernUtil

Support routines, creating campaigns, running PCF

=item LINZ::BERN::Environment

Routines to support building scripts run by the BPE

=item LINZ::BERN::CrdFile

Read/write coordinate files

=item LINZ::BERN::SessionFile

Read/write session table files

=item LINZ::BERN::PcfFile

Extract information from PCF files

=back

Also provides programs:

=over

=item run_bernese_pcf

=item create_bernese_campaign

=item get_pcf_files

=item get_pcf_opts

=item sinex2crd

=item igslog_to_sta

=back

The routines for creating runtime environments and running PCF scripts allow redirecting
the bernese ${X}/GEN and ${D} directories to facilitate implementations such as Docker where
these are maintained separately to the processing docker image.  These locations can be 
defined with environment variables BERNESE_GENDIR and BERNESE_DATAPOOL, or they can be 
explicitly defined in functions seach as BernUtil::CreateRuntimeEnvironment.  The BERNESE_SERVER_HOST
environment variable can be used to override the value in LOADGPS.setvar (typically `localhost`).
BERNESE_DEBUG can be set to "debug" to use the debug versions of programs (F_VERS=GNUc).
The BERNESE_ENV_FILE variable can be used to override the default location of LOADGPS.setvar

=cut

1;
