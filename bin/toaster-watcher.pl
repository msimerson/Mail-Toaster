#!/usr/bin/perl
use strict;
use warnings;

#use Data::Dumper;
use English '-no_match_vars';
use Getopt::Std;

use lib 'lib';
use Mail::Toaster 5.41;

die "Sorry, you are not root!\n" if $UID != 0;

use vars qw/ $opt_d $opt_v /;
$|++;

getopts('dv');
$opt_v = $opt_v ? 1 : 0;

my $toaster = Mail::Toaster->new( verbose => $opt_v );
my $verbose = $toaster->conf->{'toaster_verbose'} || $opt_v || 0;

my $pidfile = "/var/run/toaster-watcher.pid";
if ( ! $toaster->util->check_pidfile( $pidfile, fatal=>0, verbose=>$verbose ) ) {
    $toaster->error( "another toaster-watcher is running,  I refuse to!",fatal=>0,verbose=>$verbose);
    exit 500;
};

# suppress test output when not running in verbose mode
my $quiet = 1; $quiet-- if $verbose;

my %args = ( fatal=>0, verbose => $verbose, quiet => $quiet );

print "$0 v$Mail::Toaster::VERSION\n" if $verbose;

$toaster->log( "Starting up" );
$toaster->qmail->config( %args );

foreach my $prot ( qw/  send pop3 smtp submit / ) {
    $toaster->log( "Building $prot/run" );
    my $method = 'build_' . $prot . '_run';
    $toaster->qmail->$method( %args );
};
$toaster->build_vpopmaild_run;

#$toaster->setup->startup_script();
$toaster->check( %args );
$toaster->service_symlinks( %args );
$toaster->clear_open_smtp( %args );
$toaster->sqwebmail_clean_cache( %args );
$toaster->run_isoqlog( %args );
$toaster->run_qmailscanner( %args );
$toaster->clean_mailboxes( %args );
$toaster->learn_mailboxes( %args );
$toaster->process_logfiles( %args );
$toaster->check_cron( %args );

$toaster->qmail->rebuild_ssl_temp_keys( %args );
$toaster->qmail->rebuild_simscan_control( %args );

unlink $pidfile;
$toaster->log( "Exiting" );

exit 0;

__END__


=head1 NAME

toaster-watcher.pl - monitors and configure various aspects of a qmail toaster

=head1 SYNOPSIS

toaster-watcher does several unique and important things. First, it includes a configuration file that stores settings about your mail system. You configure it to suit your needs and it goes about making sure all the settings on your system are as you selected. Various other scripts (like toaster_setup.pl) and programs use this configuration file to determine how to configure themselves and other parts of the mail toaster solution.

The really cool part about toaster-watcher.pl is that it dynamically builds the run files for your qmail daemons (qmail-smtpd, qmail-send, and qmail-pop3). You choose all your settings in toaster-watcher.conf and toaster-watcher.pl builds your run files for you, on the fly. It tests the RBL's you've selected to use, and builds a control file based on your settings and dynamic information such as the availability of the RBLs you want to use.


=head1 DESCRIPTION

=head1 SUBROUTINES

=over

=item build_send_run

We first build a new $service/send/run file based on your settings in
toaster-watcher.conf. There are a ton of configuration options, be sure
to check out the docs for toaster-watcher.conf.

If the new generated file is different than the installed version, we
install the updated run file and restart the daemon.


=item build_pop3_run

We first build a new $service/pop3/run file based on your settings in
toaster-watcher.conf. There are a ton of configuration options, be sure
to check out the docs for toaster-watcher.conf.

If the new generated file is different than the installed version, we
install the updated run file and restart the daemon.


=item build_smtp_run

We first build a new $service/smtp/run file based on your settings in
toaster-watcher.conf. There are a ton of configuration options, be sure
to check out the docs for toaster-watcher.conf.

If the new generated file is different than the installed version, we
install the updated run file and restart the daemon.


=item build_submit_run

We first build a new $service/submit/run file based on your settings in
toaster-watcher.conf. There are a ton of configuration options, be sure
to check out the docs for toaster-watcher.conf.

If the new generated file is different than the installed version, we
install the updated run file and restart the daemon.


=item Clear Open SMTP

This script runs the clearopensmtp program which expires old ip addresses from the vpopmail smtp relay table. It will only run if you have vpopmail_roaming_users enabled in toaster-watcher.conf.


=item Isoqlog

If you have isoqlog installed, you'll want to have it running frequently. I suggest running it from here, or from cron directly.


=item Qmail-Scanner Quarantine Processing

Qmail-Scanner quarantines any files that fail certain tests, such as banned attachments, Virus laden messages, etc. The messages get left laying around in the quarantine until someone does something about it. If you enable this feature, toaster-watcher.pl will go through the quarantine and deal with messages as you see fit.

I have mine configured to block the IP (for 24 hours) of anyone that's sent me a virus and delete the quarantined message. I run toaster-watcher.pl from cron every 5 minutes so this usually keeps virus infected hosts from sending me another virus laden message for at least 24 hours, after which we hope the owner of the system has cleaned up his computer.


=item Maildir Processing

Many times its useful to have a script that cleans up old mail messages on your mail system and enforces policy. Now toaster-watcher.pl does that. You tell it how often to run (I use every 7 days), what mail folders to clean (Inbox, Read, Unread, Sent, Trash, Spam), and then how old the messaged need to be before you remove them.

I have my system set to remove messages in Sent folders more than 180 days old and messages in Trash and Spam folders that are over 14 days old. I have also instructed toaster-watcher to feed any messages in my Spam and Read folders that are more than 1 day old through sa-learn. That way I train SpamAssassin by merely moving my messages into appropriate folders.


=back

=head1 TODO

Feature request by David Chaplin-Leobell: check for low disk space on the queue and
mail delivery partitions.  If low disk is detected, it could either just
notify the administrator, or it could do some cleanup of things like the
qmail-scanner quarantine folder.


=head1 AUTHOR

Matt Simerson <matt@tnpi.net>


=head1 DEPENDENCIES

This module requires these other modules and libraries:

Net::DNS


=head1 SEE ALSO

http://mail-toaster.org/

=head1 ACKNOWLEDGEMENTS

Thanks to Randy Ricker, Anton Zavrin, Randy Jordan, Arie Gerszt, Joe Kletch, and Marius Kirschner for contributing to the development of this program.


=head1 COPYRIGHT AND LICENSE

Copyright (c) 2004-2013, The Network People, Inc.  All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
