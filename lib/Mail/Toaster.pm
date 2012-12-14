package Mail::Toaster;

use strict;
use warnings;

our $VERSION = '5.35';

use Cwd;
#use Data::Dumper;
use English qw/ -no_match_vars /;
use File::Basename;
use File::Find;
use File::stat;
use Params::Validate qw/ :all /;
use Sys::Hostname;
use version;

use vars qw/ $INJECT $util $conf $log $qmail %std_opts /;

sub new {
    my $class = shift;

    %std_opts = (
        test_ok => { type => BOOLEAN, optional => 1 },
        debug   => { type => BOOLEAN, optional => 1, default => 1 },
        fatal   => { type => BOOLEAN, optional => 1, default => 1 },
        quiet   => { type => BOOLEAN, optional => 1, default => 0 },
    );

    my %p = validate( @_, { %std_opts } );

    my $self = {
        audit  => [],
        errors => [],
        last_audit => 0,
        last_error => 0,
        conf   => undef,
        util   => undef,
        debug  => $p{debug},
        fatal  => $p{fatal},
        quiet  => undef,
    };
    bless( $self, $class );

    $self->{util} = $log = $util = $self->get_util();

    my @caller = caller;
    warn sprintf( "Toaster.pm loaded by %s, %s, %s\n", @caller )
        if $caller[0] ne 'main';
    return $self;
}

sub log {
    my $self = shift;
    my $mess = shift or return;

    my $logfile = $conf->{'toaster_watcher_log'} or return;
    return if ( -e $logfile && ! -w $logfile );

    $util->logfile_append(
        file  => $logfile,
        lines => [$mess],
        fatal => 0,
    );
};

sub test {
    my $self = shift;
    my $mess = shift or return;
    my $result = shift;

    my %p = validate(@_, { %std_opts } );
    my $quiet = $p{quiet};
    return if ( defined $p{test_ok} && ! $p{debug} );
    return if ( $quiet && ! $p{debug} );

    print $mess if ! $quiet;
    defined $result or do { print "\n" if ! $quiet; return; };
    for ( my $i = length($mess); $i <=  65; $i++ ) { print '.' if ! $quiet; };
    return if $quiet;
    print $result ? 'ok' : 'FAILED', "\n";
};

sub check {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $util->get_std_args( %p );

    $conf ||= $self->get_config();

    $self->check_permissions( %args );
    $self->check_processes( %args );
    $self->check_watcher_log_size( %args );

    # check that we can't SMTP AUTH with random user names and passwords

    # make sure the supervised processes are configured correctly.
    foreach my $svc ( qw/ smtp send pop3 submit vpopmaild qmail-deliverable / ) {
        $self->supervised_dir_test( prot => $svc, %args );
    };

    return 1;
}

sub check_permissions {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    $conf ||= $self->get_config();

    # check permissions on toaster-watcher.conf
    my $etc = $conf->{'system_config_dir'} || '/usr/local/etc';
    my $twconf = "$etc/toaster-watcher.conf";
    if ( -f $twconf ) {
        my $mode = $util->file_mode( file=>$twconf, debug=>0 );
        $log->audit( "file mode of $twconf is $mode.", %p);
        my $others = substr($mode, -1, 1);
        if ( $others > 0 ) {
            chmod 0600, $twconf;
            $log->audit( "Changed the permissions on $twconf to 0600" );
        }
    };

    # check permissions on toaster.conf
    $twconf = "$etc/toaster.conf";
    if ( -f $twconf ) {
        my $mode = $util->file_mode(file=>$twconf, debug=>0);
        $log->audit( "file mode of $twconf is $mode", %p);
        my $others = substr($mode, -1, 1);
        if ( ! $others ) {
            chmod 0644, $twconf;
            $log->audit( "Changed the permissions on $twconf to 0644");
        }
    };
};

sub check_processes {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $util->get_std_args( %p );

    $conf ||= $self->get_config();

    $log->audit( "checking running processes");

    my @processes = qw( svscan qmail-send );

    push @processes, "httpd"              if $conf->{'install_apache'};
    push @processes, "mysqld"             if $conf->{'install_mysqld'};
    push @processes, "snmpd"              if $conf->{'install_snmp'};
    push @processes, "clamd", "freshclam" if $conf->{'install_clamav'};
    push @processes, "sqwebmaild"         if $conf->{'install_sqwebmail'};
    push @processes, "imapd-ssl", "imapd", "pop3d-ssl"
      if $conf->{'install_courier-imap'};
    push @processes, "vpopmaild"          if $conf->{'vpopmail_daemon'};

    push @processes, "authdaemond"
      if ( $conf->{'install_courier_imap'} eq "port"
        || $conf->{'install_courier_imap'} > 4 );

    push @processes, "sendlog"
      if ( $conf->{'send_log_method'} eq "multilog"
        && $conf->{'send_log_postprocessor'} eq "maillogs" );

    push @processes, "smtplog"
      if ( $conf->{'smtpd_log_method'} eq "multilog"
        && $conf->{'smtpd_log_postprocessor'} eq "maillogs" );

    foreach (@processes) {
        $self->test( "  $_", $util->is_process_running($_), %args );
    }

    return 1;
}

sub check_cron {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $util->get_std_args( %p );

    $conf ||= $self->get_config();

    return $log->audit("unable to check cron jobs on $OSNAME")
        if $OSNAME ne "freebsd";

    $log->audit( "checking cron jobs");
    $self->check_cron_dccd();
};

sub check_cron_dccd {
    my $self = shift;

    return if ! -f '/usr/local/dcc/libexec/cron-dccd';

    my $periodic_dir = '/usr/local/etc/periodic/daily';
    if ( ! -d $periodic_dir ) {
        $util->mkdir_system(dir=>$periodic_dir, mode => '0755')
            or return $log->error("unable to create $periodic_dir");
    };

    my $script = "$periodic_dir/501.dccd";
    if ( ! -f $script ) {
        $util->file_write( $script,
            lines => [ '#!/bin/sh', '/usr/local/dcc/libexec/cron-dccd', ],
            mode => '0755',
        );
        $self->audit("created dccd nightly cron job");
    };
};

sub check_watcher_log_size {
    my $self = shift;

    $conf ||= $self->get_config();

    my $logfile = $conf->{'toaster_watcher_log'} or return;
    return if ! -e $logfile;

    # make sure watcher.log is not larger than 1MB
    my $size = stat($logfile)->size;
    if ( $size && $size > 999999 ) {
        $log->audit( "compressing $logfile! ($size)");
        $util->syscmd( "gzip -f $logfile" );
    }
};

sub learn_mailboxes {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $util->get_std_args( %p );

    return $p{test_ok} if defined $p{test_ok};

    $self->learn_mailboxes_setup() or return;
    my $find = $util->find_bin( 'find', debug=>0 );

    foreach my $d ( $self->get_maildir_paths() ) {  # every email box
        next if ! -d $d;
        my ($user,$domain) = (split('/', $d))[-1,-2];
        my $email = lc($user) . '@'. lc($domain);

        my $age = $conf->{'maildir_learn_interval'} * 86400;
        if ( -f "$d/learn.log" ) {
            $age = time - stat("$d/learn.log")->ctime;
        };

        my %counter = ( spam => 0, ham => 0 );
        my %messages = ( ham => [], spam => [] );

        foreach my $dir ( $self->get_maildir_folders( $d, $find ) ) {
            my $type = 'ham';
            $type = 'spam' if $dir =~ /spam|junk/i;

            foreach my $message ( $self->get_maildir_messages($dir, $age, $find) ) {
                $counter{$type}++;  # throttle learning for really big maildirs
                next if $counter{$type} > 10000 && $counter{$type} % 50 != 0;
                next if $counter{$type} >  5000 && $counter{$type} % 25 != 0;
                next if $counter{$type} >  2500 && $counter{$type} % 10 != 0;

                $self->train_dspam( $type, $message, $email );
                push @{$messages{$type}}, $message; # for SA training
            };
        };

        $self->train_spamassassin($d, \%messages );

        if ( $counter{'ham'} || $counter{'spam'} ) {
            $util->logfile_append( file => "$d/learn.log",
                prog => $0,
                lines => [ "trained $counter{'ham'} hams and $counter{'spam'} spams" ],
                debug => 0,
            );
        };
    }
}

sub learn_mailboxes_setup {
    my $self = shift;
    my %p    = validate( @_, { %std_opts } );
    #my %args = $util->get_std_args( %p );

    my $log_base = $conf->{'qmail_log_base'} || '/var/log/mail';
    my $learn_log = "$log_base/learn.log";
    $log->audit( "learn log file is: $learn_log");

    my $days = $conf->{'maildir_learn_interval'}
        or return $log->error(
        'learning is disabled because maildir_learn_interval is not set in \$conf', fatal => 0 );

    return 1;
};

sub train_spamassassin {
    my ($self, $d, $messages ) = @_;

    return if ! $self->{'install_spamassassin'};
    my $salearn = '/usr/local/bin/sa-learn';

    if ( scalar @{$messages->{'ham'}} ) {
        my $hamlist  = "$d/learned-ham-messages";
        $util->file_write($hamlist, lines => $messages->{ham}, debug=>0 );
        $util->syscmd( "$salearn --ham -f $hamlist", debug=>0 );
    }
    if ( scalar @{$messages->{'spam'}} ) {
        my $spamlist = "$d/learned-spam-messages";
        $util->file_write($spamlist, lines => $messages->{spam}, debug=>0 );
        $util->syscmd( "$salearn --spam -f $spamlist", debug=>0 );
    }
};

sub train_dspam {
    my ($self, $type, $file, $email) = @_;
    return if ! $conf->{install_dspam};
    #$log->audit($file);
    my $cmd;
    my $dspam = '/usr/local/bin/dspamc';
    -x $dspam or return;
    if ( $type eq 'ham' ) {
        $cmd = "$dspam --client --user $email --source=corpus --class=innocent --deliver=summary --stdout";
        my $dspam_class = $self->get_dspam_class( $file );
        return if ( $dspam_class && $dspam_class eq 'innocent' ); # dspam correct
        if ( $dspam_class && $dspam_class eq 'spam' ) {         # dspam miss
            $cmd = "$dspam --client --user $email --mode=toe --source=error --class=innocent --deliver=summary --stdout";
        };
    }
    elsif ( $type eq 'spam' ) {
        $cmd = "$dspam --client --user $email --source=corpus --class=spam --deliver=summary --stdout";
        my $dspam_class = $self->get_dspam_class( $file );
        return if ( $dspam_class && $dspam_class eq 'innocent' );
        if ( $dspam_class && $dspam_class eq 'innocent' ) {
            $cmd = "$dspam --client --user $email --mode=toe --source=error --class=spam --deliver=summary --stdout";
        };
    };
    $log->audit( "$cmd" );
    my $r = `$cmd < '$file'`;  # capture the stdout
    $log->audit( $r );
};

sub clean_mailboxes {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $util->get_std_args( %p );

    return $p{test_ok} if defined $p{test_ok};

    my $days = $conf->{'maildir_clean_interval'} or
        return $log->audit( 'skipping maildir cleaning, not enabled in config' );

    my $log_base = $conf->{'qmail_log_base'} || '/var/log/mail';
    my $clean_log = "$log_base/clean.log";
    $log->audit( "clean log file is: $clean_log");

    # create the log file if it does not exist
    if ( ! -e $clean_log ) {
        $util->file_write( $clean_log, lines => ["created file"], %args );
        return if ! -e $clean_log;
    }

    if ( -M $clean_log <= $days ) {
        $log->audit( "skipping, $clean_log is less than $days old");
        return 1;
    }

    $util->logfile_append(
        file  => $clean_log,
        prog  => $0,
        lines => ["clean_mailboxes running."],
        %args,
    ) or return;

    $log->audit( "checks passed, cleaning");

    my @every_maildir_on_server = $self->get_maildir_paths();

    foreach my $maildir (@every_maildir_on_server) {

        if ( ! $maildir || ! -d $maildir ) {
            $log->audit( "$maildir does not exist, skipping!");
            next;
        };

        $log->audit( "  processing $maildir");

        $self->maildir_clean_ham( path=>$maildir );
        $self->maildir_clean_new( path=>$maildir );
        $self->maildir_clean_sent( path=>$maildir );
        $self->maildir_clean_trash( path=>$maildir );
        $self->maildir_clean_spam( path=>$maildir );
    };

    return 1;
}

sub clear_open_smtp {
    my $self = shift;

    return if ! $conf->{'vpopmail_roaming_users'};

    my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    if ( ! -x "$vpopdir/bin/clearopensmtp" ) {
        return $log->error( "cannot find clearopensmtp program!",fatal=>0 );
    };

    $log->audit( "running clearopensmtp");
    $util->syscmd( "$vpopdir/bin/clearopensmtp" );
};

sub maildir_clean_spam {
    my $self = shift;
    my %p = validate( @_, { path  => { type=>SCALAR } } );

    my $path = $p{path};
    my $days = $conf->{'maildir_clean_Spam'} or return;
    my $spambox = "$path/Maildir/.Spam";

    return $log->error( "clean_spam: skipped because $spambox does not exist.",fatal=>0)
        if !-d $spambox;

    $log->audit( "clean_spam: cleaning spam messages older than $days days." );

    my $find = $util->find_bin( 'find', debug=>0 );
    $util->syscmd( "$find $spambox/cur -type f -mtime +$days -exec rm {} \\;" );
    $util->syscmd( "$find $spambox/new -type f -mtime +$days -exec rm {} \\;" );
};

sub maildir_clean_trash {
    my $self = shift;
    my %p = validate( @_, { 'path' => { type=>SCALAR  } } );

    my $path = $p{path};
    my $trash = "$path/Maildir/.Trash";
    my $days = $conf->{'maildir_clean_Trash'} or return;

    return $log->error( "clean_trash: skipped because $trash does not exist.", fatal=>0)
        if ! -d $trash;

    $log->audit( "clean_trash: cleaning deleted messages older than $days days");

    my $find = $util->find_bin( "find" );
    $util->syscmd( "$find $trash/new -type f -mtime +$days -exec rm {} \\;");
    $util->syscmd( "$find $trash/cur -type f -mtime +$days -exec rm {} \\;");
}

sub maildir_clean_sent {
    my $self = shift;
    my %p = validate( @_, { 'path' => { type=>SCALAR,  }, },);

    my $path = $p{path};
    my $sent = "$path/Maildir/.Sent";
    my $days = $conf->{'maildir_clean_Sent'} or return;

    if ( ! -d $sent ) {
        $log->audit("clean_sent: skipped because $sent does not exist.");
        return 0;
    }

    $log->audit( "clean_sent: cleaning sent messages older than $days days");

    my $find = $util->find_bin( "find", debug=>0 );
    $util->syscmd( "$find $sent/new -type f -mtime +$days -exec rm {} \\;");
    $util->syscmd( "$find $sent/cur -type f -mtime +$days -exec rm {} \\;");
}

sub maildir_clean_new {
    my $self = shift;
    my %p = validate( @_, { 'path' => { type=>SCALAR,  }, },);

    my $path = $p{path};
    my $unread = "$path/Maildir/new";
    my $days = $conf->{'maildir_clean_Unread'} or return;

    if ( ! -d $unread ) {
        $log->audit( "clean_new: skipped because $unread does not exist.");
        return 0;
    }

    my $find = $util->find_bin( "find", debug=>0 );
    $log->audit( "clean_new: cleaning unread messages older than $days days");
    $util->syscmd( "$find $unread -type f -mtime +$days -exec rm {} \\;" );
}

sub maildir_clean_ham {
    my $self = shift;
    my %p = validate( @_, { 'path' => { type=>SCALAR, }, }, );

    my $path = $p{path};
    my $read = "$path/Maildir/cur";
    my $days = $conf->{'maildir_clean_Read'} or return;

    if ( ! -d $read ) {
        $log->audit( "clean_ham: skipped because $read does not exist.");
        return 0;
    }

    $log->audit( "clean_ham: cleaning read messages older than $days days");
    my $find = $util->find_bin( "find", debug=>0 );
    $util->syscmd( "$find $read -type f -mtime +$days -exec rm {} \\;" );
}

sub email_send {
    my $self = shift;
    my %p = validate( @_, { 'type' => { type=>SCALAR }, %std_opts } );

    my $type = $p{'type'};

    my $email = $conf->{'toaster_admin_email'} || "root";

    my $qdir = $conf->{'qmail_dir'} || "/var/qmail";
    return 0 unless -x "$qdir/bin/qmail-inject";

    ## no critic
    unless ( open( $INJECT, "| $qdir/bin/qmail-inject -a -f \"\" $email" ) ) {
        warn "FATAL: couldn't send using qmail-inject!\n";
        return;
    }
    ## use critic

    if    ( $type eq "clean" )  { $self->email_send_clean($email) }
    elsif ( $type eq "spam" )   { $self->email_send_spam($email) }
    elsif ( $type eq "virus" )  { $self->email_send_eicar($email) }
    elsif ( $type eq "attach" ) { $self->email_send_attach($email) }
    elsif ( $type eq "clam" )   { $self->email_send_clam($email) }
    else { print "man Mail::Toaster to figure out how to use this!\n" }

    close $INJECT;

    return 1;
}

sub email_send_attach {

    my ( $self, $email ) = @_;

    print "\n\t\tSending .com test attachment - should fail.\n";
    print $INJECT <<"EOATTACH";
From: Mail Toaster Testing <$email>
To: Email Administrator <$email>
Subject: Email test (blocked attachment message)
Mime-Version: 1.0
Content-Type: multipart/mixed; boundary="gKMricLos+KVdGMg"
Content-Disposition: inline

--gKMricLos+KVdGMg
Content-Type: text/plain; charset=us-ascii
Content-Disposition: inline

This is an example of an Email message containing a virus. It should
trigger the virus scanner, and not be delivered.

If you are using qmail-scanner, the server admin should get a notification.

--gKMricLos+KVdGMg
Content-Type: text/plain; charset=us-ascii
Content-Disposition: attachment; filename="Eicar.com"

00000000000000000000000000000000000000000000000000000000000000000000

--gKMricLos+KVdGMg--

EOATTACH

}

sub email_send_clam {

    my ( $self, $email ) = @_;

    print "\n\t\tSending ClamAV test virus - should fail.\n";
    print $INJECT <<EOCLAM;
From: Mail Toaster testing <$email>
To: Email Administrator <$email>
Subject: Email test (virus message)

This is a viral message containing the clam.zip test virus pattern. It should be blocked by any scanning software using ClamAV.


--Apple-Mail-7-468588064
Content-Transfer-Encoding: base64
Content-Type: application/zip;
        x-unix-mode=0644;
        name="clam.zip"
Content-Disposition: attachment;
        filename=clam.zip

UEsDBBQAAAAIALwMJjH9PAfvAAEAACACAAAIABUAY2xhbS5leGVVVAkAA1SjO0El6E1BVXgEAOgD
6APzjQpgYGJgYGBh4Gf4/5+BYQeQrQjEDgxSDAQBIwPD7kIBBwbjAwEB3Z+DgwM2aDoYsKStqfy5
y5ChgndtwP+0Aj75fYYML5/+38J5VnGLz1nFJB4uRqaCMnEmOT8eFv1bZwRQjTwA5Degid0C8r+g
icGAt2uQn6uPsZGei48PA4NrRWZJQFF+cmpxMUNosGsQVNzZx9EXKJSYnuqUX+HI8Axqlj0QBLgy
MPgwMjIkOic6wcx8wNDXyM3IJAkMFAYGNoiYA0iPAChcwDwwGxRwjFA9zAxcEIYCODDBgAlMCkDE
QDTUXmSvtID8izeQaQOiQWHiGBbLAPUXsl+QwAEAUEsBAhcDFAAAAAgAvAwmMf08B+8AAQAAIAIA
AAgADQAAAAAAAAAAAKSBAAAAAGNsYW0uZXhlVVQFAANUoztBVXgAAFBLBQYAAAAAAQABAEMAAAA7
AQAAAAA=

--Apple-Mail-7-468588064


EOCLAM

}

sub email_send_clean {

    my ( $self, $email ) = @_;

    print "\n\t\tsending a clean message - should arrive unaltered\n";
    print $INJECT <<EOCLEAN;
From: Mail Toaster testing <$email>
To: Email Administrator <$email>
Subject: Email test (clean message)

This is a clean test message. It should arrive unaltered and should also pass any virus or spam checks.

EOCLEAN

}

sub email_send_eicar {

    my ( $self, $email ) = @_;

    # http://eicar.org/anti_virus_test_file.htm
    # X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*

    print "\n\t\tSending the EICAR test virus - should fail.\n";
    print $INJECT <<EOVIRUS;
From: Mail Toaster testing <$email'>
To: Email Administrator <$email>
Subject: Email test (eicar virus test message)
Mime-Version: 1.0
Content-Type: multipart/mixed; boundary="gKMricLos+KVdGMg"
Content-Disposition: inline

--gKMricLos+KVdGMg
Content-Type: text/plain; charset=us-ascii
Content-Disposition: inline

This is an example email containing a virus. It should trigger any good virus
scanner.

If it is caught by AV software, it will not be delivered to its intended
recipient (the email admin). The Qmail-Scanner administrator should receive
an Email alerting him/her to the presence of the test virus. All other
software should block the message.

--gKMricLos+KVdGMg
Content-Type: text/plain; charset=us-ascii
Content-Disposition: attachment; filename="sneaky.txt"

X5O!P%\@AP[4\\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*

--gKMricLos+KVdGMg--

EOVIRUS
      ;

}

sub email_send_spam {

    print "\n\t\tSending a sample spam message - should fail\n";

    print $INJECT 'Return-Path: sb55sb55@yahoo.com
Delivery-Date: Mon, 19 Feb 2001 13:57:29 +0000
Return-Path: <sb55sb55@yahoo.com>
Delivered-To: jm@netnoteinc.com
Received: from webnote.net (mail.webnote.net [193.120.211.219])
   by mail.netnoteinc.com (Postfix) with ESMTP id 09C18114095
   for <jm7@netnoteinc.com>; Mon, 19 Feb 2001 13:57:29 +0000 (GMT)
Received: from netsvr.Internet (USR-157-050.dr.cgocable.ca [24.226.157.50] (may be forged))
   by webnote.net (8.9.3/8.9.3) with ESMTP id IAA29903
   for <jm7@netnoteinc.com>; Sun, 18 Feb 2001 08:28:16 GMT
From: sb55sb55@yahoo.com
Received: from R00UqS18S (max1-45.losangeles.corecomm.net [216.214.106.173]) by netsvr.Internet with SMTP (Microsoft Exchange Internet Mail Service Version 5.5.2653.13)
   id 1429NTL5; Sun, 18 Feb 2001 03:26:12 -0500
DATE: 18 Feb 01 12:29:13 AM
Message-ID: <9PS291LhupY>
Subject: anti-spam test: checking SpamAssassin [if present] (There yours for FREE!)
To: undisclosed-recipients:;

Congratulations! You have been selected to receive 2 FREE 2 Day VIP Passes to Universal Studios!

Click here http://209.61.190.180

As an added bonus you will also be registered to receive vacations discounted 25%-75%!


@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
This mailing is done by an independent marketing co.
We apologize if this message has reached you in error.
Save the Planet, Save the Trees! Advertise via E mail.
No wasted paper! Delete with one simple keystroke!
Less refuse in our Dumps! This is the new way of the new millennium
To be removed please reply back with the word "remove" in the subject line.
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

';
}

sub get_config {
    my ($self, $config) = @_;

    if ( $config && ref $config eq 'HASH' ) {
        $self->{conf} = $conf = $config;
        return $conf;
    }

    return $self->{conf} if (defined $self->{conf} && ref $self->{conf});

    $self->{conf} = $conf = $util->parse_config( "toaster-watcher.conf" );
    return $conf;
};

sub get_debug {
    my ($self, $debug) = @_;
    return $debug if defined $debug;
    return $self->{debug};
};

sub get_dspam_class {
    my ($self, $file) = @_;
    if ( ! -f $file ) {
        return $log->error( "file $file disappeared",fatal=>0 );
    };
    my @headers = $util->file_read( $file, max_lines => 20 );
    #foreach my $h ( @headers ) { print "\t$h\n"; };

    no warnings;
    my ($dspam_status) = grep {/^X-DSPAM-Result:/} @headers;
    my ($signature) = grep {/^X-DSPAM-Signature:/} @headers;
    use warnings;

    return if ! $dspam_status || ! $signature;
    my ($class) = $dspam_status =~ /^X-DSPAM-Result:\s+([\w]+)\,/
        or return;
    return lc($class);
};

sub get_fatal {
    my ($self, $fatal) = @_;
    return $fatal if defined $fatal;
    return $self->{fatal};
};

sub get_maildir_paths {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $util->get_std_args( %p );

    my $vpdir = $conf->{'vpopmail_home_dir'};

    # this method requires a SQL query for each domain
    require Mail::Toaster::Qmail;
    $qmail ||= Mail::Toaster::Qmail->new( toaster => $self );

    my $qdir  = $conf->{'qmail_dir'} || "/var/qmail";

    my @all_domains = $qmail->get_domains_from_assign(
        assign => "$qdir/users/assign",
        fatal  => 0,
    );

    return $log->error( "No domains found in qmail/users/assign",fatal=>0 )
        unless $all_domains[0];

    my $count = @all_domains;
    $log->audit( "get_maildir_paths: found $count domains." );

    my @paths;
    foreach (@all_domains) {
        my $domain_name = $_->{'dom'};
        #$log->audit( "  processing $domain_name mailboxes.", %args);
        my @list_of_maildirs = `$vpdir/bin/vuserinfo -d -D $domain_name`;
        push @paths, @list_of_maildirs;
    }

    chomp @paths;
    my %saw;
    my @unique_paths = grep(!$saw{$_}++, @paths);

    $log->audit( "found ". scalar @unique_paths ." mailboxes.");
    return @unique_paths;
}

sub get_maildir_folders {
    my ( $self, $d, $find ) = @_;

    $find ||= $util->find_bin( 'find', debug=>0 );
    my $find_dirs = "$find $d -type d -name cur";

    my @dirs;
    foreach my $maildir ( `$find_dirs` ) {
        chomp $maildir;
        next if $maildir =~ /\.Notes\/cur$/i;    # not email
        next if $maildir =~ /\.Apple/i;          # not email
        next if $maildir =~ /drafts|sent/i;   # not 'received' email
        next if $maildir =~ /trash|delete/i;  # unknown ham/spam
        push @dirs, $maildir;
    };
    return @dirs;
};

sub get_maildir_messages {
    my ($self, $dir, $age, $find) = @_;

    my @recents;
    my $oldest = time - $age;

    find( {wanted=> sub { -f && stat($_)->ctime > $oldest && push @recents, $File::Find::name; }, no_chdir=>1}, $dir);
    #my @messages = `$find "$dir" -type f -ctime -${age}s`;

    #print "found " . @recents . " messages in $dir\n";
    chomp @recents;
    return @recents;
};

sub get_std_args {
    my $self = shift;
    return $util->get_std_args(@_);
};

sub get_toaster_htdocs {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    # if available, use the configured location
    if ( defined $conf && $conf->{'toaster_http_docs'} ) {
        return $conf->{'toaster_http_docs'};
    }

    # otherwise, check the usual locations
    my @dirs = (
        "/usr/local/www/toaster",       # toaster
        "/usr/local/www/data/mail",     # legacy
        "/usr/local/www/mail",
        "/Library/Webserver/Documents", # Mac OS X
        "/var/www/html",                # Linux
        "/usr/local/www/data",          # FreeBSD
    );

    foreach my $dir ( @dirs ) {
        return $dir if -d $dir;
    };

    $log->error("could not find htdocs location.");
}

sub get_toaster_cgibin {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    # if it is set, then use it.
    if ( defined $conf && defined $conf->{'toaster_cgi_bin'} ) {
        return $conf->{'toaster_cgi_bin'};
    }

    # Mail-Toaster preferred
    if ( -d "/usr/local/www/cgi-bin.mail" ) {
        return "/usr/local/www/cgi-bin.mail";
    }

    # FreeBSD default
    if ( -d "/usr/local/www/cgi-bin" ) {
        return "/usr/local/www/cgi-bin";
    }

    # linux
    if ( -d "/var/www/cgi-bin" ) {
        return "/var/www/cgi-bin";
    }

    # Mac OS X standard location
    if ( -d "/Library/WebServer/CGI-Executables" ) {
        return "/Library/WebServer/CGI-Executables";
    }

    # all else has failed, we must try to predict
    return $OSNAME eq "linux"  ? "/var/www/cgi-bin"
         : $OSNAME eq "darwin" ? "/Library/WebServer/CGI-Executables"
         : $OSNAME eq "netbsd" ? "/var/apache/cgi-bin"
         : "/usr/local/www/cgi-bin"   # last resort
         ;

}

sub get_toaster_logs {
    my $self = shift;

    # if it is set, then use it.
    if ( defined $conf && defined $conf->{'qmail_log_base'} ) {
        return $conf->{'qmail_log_base'};
    };

    #otherwise, we simply default to /var/log/mail
    return "/var/log/mail";
}

sub get_toaster_conf {
    my $self = shift;

    # if it is set, then use it.
    if ( defined $conf && defined $conf->{'system_config_dir'} ) {
        return $conf->{'system_config_dir'};
    };

	return $OSNAME eq "darwin"  ? "/opt/local/etc"  # Mac OS X
	     : $OSNAME eq "freebsd" ? "/usr/local/etc"  # FreeBSD
	     : $OSNAME eq "linux"   ? "/etc"            # Linux
	     : "/usr/local/etc"                         # reasonably good guess
	     ;

}

sub get_util {
    my $self = shift;
    return $util if ref $util;
    use lib 'lib';
    require Mail::Toaster::Utility;
    $self->{util} = $util = Mail::Toaster::Utility->new( debug => $self->{debug} );
    return $util;
};

sub process_logfiles {
    my $self = shift;

    my $pop3_logs = $conf->{pop3_log_method} || $conf->{'logs_pop3d'};
    my $smtpd = $conf->{'smtpd_daemon'} || 'qmail';
    my $submit = $conf->{'submit_daemon'} || 'qmail';

    $self->supervised_log_rotate( prot => 'send' );
    $self->supervised_log_rotate( prot => 'smtp' ) if $smtpd eq 'qmail';
    $self->supervised_log_rotate( prot => 'submit' ) if $conf->{submit_enable} && $submit eq 'qmail';
    $self->supervised_log_rotate( prot => 'pop3'   ) if $pop3_logs eq 'qpop3d';

    require Mail::Toaster::Logs;
    my $logs = Mail::Toaster::Logs->new( toaster => $self, conf => $conf ) or return;

    $logs->compress_yesterdays_logs( file=>"sendlog" );
    $logs->compress_yesterdays_logs( file=>"smtplog" ) if $smtpd eq 'qmail';
    $logs->compress_yesterdays_logs( file=>"pop3log" ) if $pop3_logs eq "qpop3d";

    $logs->purge_last_months_logs() if $conf->{'logs_archive_purge'};

    return 1;
};

sub run_isoqlog {
    my $self = shift;

    return if ! $conf->{'install_isoqlog'};

    my $isoqlog = $util->find_bin( "isoqlog", debug=>0,fatal => 0 )
        or return;

    system "$isoqlog >/dev/null" or return 1;
    return;
};

sub run_qmailscanner {
    my $self = shift;

    return if ! ( $conf->{'install_qmailscanner'}
        && $conf->{'qs_quarantine_process'} );

    $log->audit( "checking qmail-scanner quarantine.");

    my $qs_debug = $conf->{'qs_quarantine_verbose'};
    $qs_debug++ if $self->{debug};

    my @list = $qmail->get_qmailscanner_virus_sender_ips( $qs_debug );

    $log->audit( "found " . scalar @list . " infected files" ) if scalar @list;

    $qmail->UpdateVirusBlocks( ips => \@list )
        if $conf->{'qs_block_virus_senders'};
};

sub service_dir_get {
    my $self = shift;
    my %p = validate( @_, { prot => { type=>SCALAR } } );

    my $prot = $p{prot};
       $prot = 'smtp' if $prot eq 'smtpd'; # catch and fix legacy usage.

    my @valid = qw/ send smtp pop3 submit qpsmtpd qmail-deliverable /;
    my %valid = map { $_=>1 } @valid;
    return $log->error( "invalid service: $prot",fatal=>0) if ! $valid{$prot};

    my $svcdir = $conf->{'qmail_service'} || '/var/service';
       $svcdir = "/service" if ( !-d $svcdir && -d '/service' ); # legacy

    my $dir = "$svcdir/$prot";

    $log->audit("service dir for $prot is $dir");

    return $dir;
}

sub service_symlinks {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $util->get_std_args( %p );

    my @active_services = 'send';

    my $r = $self->service_symlinks_smtp();
    push @active_services, $r if $r;

    $r = $self->service_symlinks_submit();
    push @active_services, $r if $r;

    if ( $conf->{'pop3_enable'} ) {
        push @active_services, 'pop3';
    }
    else {
        $self->service_symlinks_cleanup( 'pop3' );
    };

    foreach my $prot ( @active_services ) {

        my $svcdir = $self->service_dir_get( prot => $prot );
        my $supdir = $self->supervise_dir_get( prot => $prot );

        if ( ! -d $supdir ) {
            $log->audit( "skipping symlink to $svcdir because target $supdir doesn't exist.");
            next;
        };

        if ( -e $svcdir ) {
            $log->audit( "service_symlinks: $svcdir already exists.");
            next;
        }

        print "service_symlinks: creating symlink from $supdir to $svcdir\n";
        symlink( $supdir, $svcdir ) or die "couldn't symlink $supdir: $!";
    }

    return 1;
}

sub service_symlinks_smtp {
    my $self = shift;

    return 'smtp' if !  $conf->{smtpd_daemon};

    if ( $conf->{smtpd_daemon} eq 'qmail' ) {
        $self->service_symlinks_cleanup( 'qpsmtpd' );
        return 'smtp';
    };

    if ( $conf->{smtpd_daemon} eq 'qpsmtpd' ) {
        $self->service_symlinks_cleanup( 'smtp' );
        return 'qpsmtpd';
    };
}

sub service_symlinks_submit {
    my $self = shift;

    return 'submit' if ! $conf->{smtpd_daemon};

    if ( $conf->{submit_daemon} eq 'qpsmtpd' ) {
        $self->service_symlinks_cleanup( 'submit' );
        return 'qpsmtpd';
    };
}

sub service_symlinks_cleanup {
    my ($self, $prot ) = @_;

    my $dir = $self->service_dir_get( prot => $prot );

    if ( -e $dir ) {
        $log->audit("deleting $dir because $prot isn't enabled!");
        unlink($dir);
    }
    else {
        $log->audit("$prot not enabled due to configuration settings.");
    }
}

sub service_dir_create {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $service = $conf->{'qmail_service'} || "/var/service";

    if ( ! -d $service ) {
        mkdir( $service, oct('0775') ) or
            return $log->error( "service_dir_create: failed to create $service: $!");
    };

    $log->audit("$service exists");

    unless ( -l "/service" ) {
        if ( -d "/service" ) {
            $util->syscmd( "rm -rf /service", fatal=>0 );
        }
        symlink( "/var/service", "/service" );
    }
}

sub service_dir_test {
    my $self = shift;

    my $service = $conf->{'qmail_service'} || "/var/service";

    return $log->error( "service_dir_test: $service is missing!",fatal=>0)
        if !-d $service;

    $log->audit( "service_dir_test: $service already exists.");

    return $log->error( "/service symlink is missing!",fatal=>0)
        unless ( -l "/service" && -e "/service" );

    $log->audit( "service_dir_test: /service symlink exists.");

    return 1;
}

sub sqwebmail_clean_cache {
    my $self = shift;

    return 1 if ! $conf->{install_sqwebmail};

    my $script = "/usr/local/share/sqwebmail/cleancache.pl";
    return if ! -x $script;
    system $script;
};

sub supervise_dir_get {
    my $self = shift;
    my %p = validate( @_, { prot => { type=>SCALAR } } );

    my $prot = $p{prot};

    my $sdir = $conf->{'qmail_supervise'};
    $sdir = "/var/supervise" if ( !-d $sdir && -d '/var/supervise'); # legacy
    $sdir = "/supervise" if ( !-d $sdir && -d '/supervise');
    $sdir ||= "/var/qmail/supervise";

    my $dir = "$sdir/$prot";

    # expand the qmail_supervise shortcut
    $dir = "$sdir/$1" if $dir =~ /^qmail_supervise\/(.*)$/;

    $log->audit( "supervise dir for $prot is $dir");
    return $dir;
}

sub supervise_dirs_create {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $util->get_std_args( %p );

    my $supervise = $conf->{'qmail_supervise'} || "/var/qmail/supervise";

    return $p{test_ok} if defined $p{test_ok};

    if ( -d $supervise ) {
        $log->audit( "supervise_dirs_create: $supervise, ok (exists)", %args );
    }
    else {
        mkdir( $supervise, oct('0775') ) or die "failed to create $supervise: $!\n";
        $log->audit( "supervise_dirs_create: $supervise, ok", %args );
    }

    chdir $supervise;

    my @sdirs = qw/ smtp send pop3 submit /;
    push @sdirs, 'vpopmaild' if $conf->{vpopmail_daemon};
    if ( 'qpsmtpd' eq $conf->{smtpd_daemon} ) {
        push @sdirs, 'qmail-deliverable';
        push @sdirs, 'qpsmtpd';
    };

    foreach my $prot ( @sdirs ) {

        my $dir = $self->supervise_dir_get( prot => $prot );
        if ( -d $dir ) {
            $log->audit( "supervise_dirs_create: $dir, ok (exists)", %args );
            next;
        }

        mkdir( $dir, oct('0775') ) or die "failed to create $dir: $!\n";
        $log->audit( "supervise_dirs_create: creating $dir, ok", %args );

        mkdir( "$dir/log", oct('0775') ) or die "failed to create $dir/log: $!\n";
        $log->audit( "supervise_dirs_create: creating $dir/log, ok", %args );

        $util->syscmd( "chmod +t $dir", debug=>0 );

        symlink( $dir, $prot ) if ! -e $prot;
    }
}

sub supervised_dir_test {
    my $self = shift;
    my %p = validate( @_, {
            'prot'    => { type=>SCALAR, },
            'dir'     => { type=>SCALAR, optional=>1, },
            %std_opts,
        },
    );

    my ($prot, $dir ) = ( $p{'prot'}, $p{'dir'} );
    my %args = $util->get_std_args( %p );

    return $p{test_ok} if defined $p{test_ok};

    if ( ! $dir ) {
        $dir = $self->supervise_dir_get( prot => $prot ) or return;
    }

    return $log->error("directory $dir does not exist", %args )
        unless ( -d $dir || -l $dir );
    $self->test( "exists, $dir", -d $dir, %args );

    return $log->error("$dir/run does not exist!", %args ) if ! -f "$dir/run";
    $self->test( "exists, $dir/run", -f "$dir/run", %args);

    return $log->error("$dir/run is not executable", %args ) if ! -x "$dir/run";
    $self->test( "perms,  $dir/run", -x "$dir/run", %args );

    return $log->error("$dir/down is present", %args ) if -f "$dir/down";
    $self->test( "!exist, $dir/down", !-f "$dir/down", %args );

    my $log_method = $conf->{ $prot . '_log_method' }
      || $conf->{ $prot . 'd_log_method' }
      || "multilog";

    return 1 if $log_method =~ /syslog|disabled/i;

    # make sure the log directory exists
    return $log->error( "$dir/log does not exist", %args ) if ! -d "$dir/log";
    $self->test( "exists, $dir/log", -d "$dir/log", %args );

    # make sure the supervise/log/run file exists
    return $log->error( "$dir/log/run does not exist", %args ) if ! -f "$dir/log/run";
    $self->test( "exists, $dir/log/run", -f "$dir/log/run", %args );

    # check the log/run file permissions
    return $log->error( "perms, $dir/log/run", %args) if ! -x "$dir/log/run";
    $self->test( "perms,  $dir/log/run", -x "$dir/log/run", %args );

    # make sure the supervise/down file does not exist
    return $log->error( "$dir/log/down exists", %args) if -f "$dir/log/down";
    $self->test( "!exist, $dir/log/down", "$dir/log/down", %args );
    return 1;
}

sub supervised_do_not_edit_notice {
    my $self = shift;
    my %p = validate( @_, {
            vdir  => { type=>SCALAR,  optional=>1, },
        },
    );

    my $vdir = $p{'vdir'};

    if ($vdir) {
        $vdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    }

    my $qdir   = $conf->{'qmail_dir'}      || "/var/qmail";
    my $prefix = $conf->{'toaster_prefix'} || "/usr/local";

    my @lines = "#!/bin/sh

#    NOTICE: This file is generated automatically by toaster-watcher.pl.
#
#    Please DO NOT hand edit this file. Instead, edit toaster-watcher.conf
#      and then run toaster-watcher.pl to make your settings active.
#      Run: perldoc toaster-watcher.conf  for more detailed info.
";

    my $path  = "PATH=$qdir/bin";
       $path .= ":$vdir/bin" if $vdir;
       $path .= ":$prefix/bin:/usr/bin:/bin";

    push @lines, $path;
    push @lines, "export PATH\n";
    return @lines;
}

sub supervised_hostname {
    my $self = shift;
    my %p = validate( @_, { 'prot' => { type=>SCALAR }, },);

    my $prot = $p{'prot'};

    $prot .= "_hostname";
    $prot = $conf->{ $prot . '_hostname' };

    if ( ! $prot || $prot eq "system" ) {
        $log->audit( "using system hostname (" . hostname() . ")" );
        return hostname() . " ";
    }
    elsif ( $prot eq "qmail" ) {
        $log->audit( "  using qmail hostname." );
        return '\"$LOCAL" ';
    }
    else {
        $log->audit( "using conf defined hostname ($prot).");
        return "$prot ";
    }
}

sub supervised_multilog {
    my $self = shift;
    my %p = validate( @_, { 'prot' => SCALAR, %std_opts, },);
    my %args = $util->get_std_args( %p );
    my $prot = $p{prot};

    my $setuidgid = $util->find_bin( 'setuidgid', fatal=>0 );
    my $multilog  = $util->find_bin( 'multilog', fatal=>0);

    return $log->error( "supervised_multilog: missing daemontools components!", %args)
        unless ( -x $setuidgid && -x $multilog );

    my $loguser  = $conf->{'qmail_log_user'} || "qmaill";
    my $log_base = $conf->{'qmail_log_base'} || $conf->{'log_base'} || '/var/log/mail';
    my $logprot  = $prot eq 'smtp' ? 'smtpd' : $prot;
    my $runline  = "exec $setuidgid $loguser $multilog t ";

    if ( $conf->{ $logprot . '_log_postprocessor' } eq "maillogs" ) {
        $log->audit( "supervised_multilog: using maillogs for $prot");
        $runline .= "!./" . $prot . "log ";
    }

    my $maxbytes = $conf->{ $logprot . '_log_maxsize_bytes' } || "100000";
    my $method   = $conf->{ $logprot . '_log_method' };

    if    ( $method eq "stats" )    { $runline .= "-* +stats s$maxbytes "; }
    elsif ( $method eq "disabled" ) { $runline .= "-* "; }
    else                            { $runline .= "s$maxbytes "; };

    $log->audit( "supervised_multilog: log method for $prot is $method");

    if ( $prot eq "send" && $conf->{'send_log_isoqlog'} ) {
        $runline .= "n288 ";    # keep a days worth of logs around
    }

    $runline .= "$log_base/$prot";
    return $runline;
}

sub supervised_log_method {
    my $self = shift;
    my %p = validate( @_, { prot => SCALAR } );

    my $prot = $p{'prot'} . "_hostname";

    if ( $conf->{$prot} eq "syslog" ) {
        $log->audit( "  using syslog logging." );
        return "\\\n\tsplogger qmail ";
    };

    $log->audit( "  using multilog logging." );
    return "\\\n\t2>&1 ";
}

sub supervised_log_rotate {
    my $self  = shift;
    my %p = validate( @_, { 'prot' => SCALAR } );
    my $prot = $p{prot};

    return $log->error( "root privs are needed to rotate logs.",fatal=>0)
        if $UID != 0;

    my $dir = $self->supervise_dir_get( prot => $prot ) or return;

    return $log->error( "the supervise directory '$dir' is missing", fatal=>0)
        if ! -d $dir;

    return $log->error( "the supervise run file '$dir/run' is missing", fatal=>0)
        if ! -f "$dir/run";

    $log->audit( "sending ALRM signal to $prot at $dir");
    my $svc = $util->find_bin('svc',debug=>0,fatal=>0) or return;
    system "$svc -a $dir";

    return 1;
};

sub supervise_restart {
    my $self = shift;
    my $dir  = shift or die "missing dir\n";

    return $log->error( "supervise_restart: is not a dir: $dir" ) if !-d $dir;

    my $svc  = $util->find_bin( 'svc',  debug=>0, fatal=>0 );
    my $svok = $util->find_bin( 'svok', debug=>0, fatal=>0 );

    return $log->error( "unable to find svc! Is daemontools installed?")
        if ! -x $svc;

    if ( $svok ) {
        system "$svok $dir" and
            return $log->error( "sorry, $dir isn't supervised!" );
    };

    # send the service a TERM signal
    $log->audit( "sending TERM signal to $dir" );
    system "$svc -t $dir";
    return 1;
}

sub supervised_tcpserver {
    my $self = shift;
    my %p = validate( @_, { prot => { type=>SCALAR } } );

    my $prot = $p{'prot'};

    # get max memory, default 4MB if unset
    my $mem = $conf->{ $prot . '_max_memory_per_connection' };
    $mem = $mem ? $mem * 1024000 : 4000000;
    $log->audit( "memory limited to $mem bytes" );

    my $softlimit = $util->find_bin( 'softlimit', debug => 0);
    my $tcpserver = $util->find_bin( 'tcpserver', debug => 0);

    my $exec = "exec\t$softlimit -m $mem \\\n\t$tcpserver ";
    $exec .= $self->supervised_tcpserver_mysql( $prot, $tcpserver );
    $exec .= "-H " if $conf->{ $prot . '_lookup_tcpremotehost' } == 0;
    $exec .= "-R " if $conf->{ $prot . '_lookup_tcpremoteinfo' } == 0;
    $exec .= "-p " if $conf->{ $prot . '_dns_paranoia' } == 1;
    $exec .= "-v " if (defined $conf->{$prot . '_verbose'} && $conf->{ $prot . '_verbose' } == 1);

    my $maxcon = $conf->{ $prot . '_max_connections' } || 40;
    my $maxmem = $conf->{ $prot . '_max_memory' };

    if ( $maxmem ) {
        if ( ( $mem / 1024000 ) * $maxcon > $maxmem ) {
            require POSIX;
            $maxcon = POSIX::floor( $maxmem / ( $mem / 1024000 ) );
            require Mail::Toaster::Qmail;
            $qmail ||= Mail::Toaster::Qmail->new( toaster  => $self );
            $qmail->_memory_explanation( $prot, $maxcon );
        }
    }
    $exec .= "-c$maxcon " if $maxcon != 40;
    $exec .= "-t$conf->{$prot.'_dns_lookup_timeout'} "
      if $conf->{ $prot . '_dns_lookup_timeout' } != 26;

    $exec .= $self->supervised_tcpserver_cdb( $prot );

    if ( $prot =~ /^smtpd|submit$/ ) {

        my $uid = getpwnam( $conf->{ $prot . '_run_as_user' } );
        my $gid = getgrnam( $conf->{ $prot . '_run_as_group' } );

        unless ( $uid && $gid ) {
            print
"uid or gid is not set!\n Check toaster_watcher.conf and make sure ${prot}_run_as_user and ${prot}_run_as_group are set to valid usernames\n";
            return 0;
        }
        $exec .= "\\\n\t-u $uid -g $gid ";
    }

    # default to 0 (all) if not selected
    my $address = $conf->{ $prot . '_listen_on_address' } || 0;
    $exec .= $address eq "all" ? "0 " : "$address ";
    $log->audit( "  listening on ip $address.");

    my $port = $conf->{ $prot . '_listen_on_port' };
       $port ||= $prot eq "smtpd"      ? "smtp"
               : $prot eq "submission" ? "submission"
               : $prot eq "pop3"       ? "pop3"
               : die "can't figure out what port $port should listen on!\n";
    $exec .= "$port ";
    $log->audit( "listening on port $port.");

    return $exec;
}

sub supervised_tcpserver_mysql {
    my $self = shift;
    my ($prot, $tcpserver ) = @_;

    return '' if ! $conf->{ $prot . '_use_mysql_relay_table' };

    # is tcpserver mysql patch installed
    my $strings = $util->find_bin( 'strings', debug=>0);

    if ( grep /sql/, `$strings $tcpserver` ) {
        $log->audit( "using MySQL based relay table" );
        return "-S ";
    }

    $log->error( "The mysql relay table option is selected but the MySQL patch for ucspi-tcp (tcpserver) is not installed! Please re-install ucspi-tcp with the patch (toaster_setup.pl -s ucspi) or disable ${prot}_use_mysql_relay_table.", fatal => 0);
    return '';
};

sub supervised_tcpserver_cdb {
    my ($self, $prot) = @_;

    my $cdb = $conf->{ $prot . '_relay_database' };
    return '' if ! $cdb;

    my $vdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    $log->audit( "relay db set to $cdb");

    if ( $cdb =~ /^vpopmail_home_dir\/(.*)$/ ) {
        $cdb = "$vdir/$1";
        $log->audit( "  expanded to $cdb" );
    }

    $log->error( "$cdb selected but not readable" ) if ! -r $cdb;
    return "\\\n\t-x $cdb ";
};


1;
__END__


=head1 NAME

Mail::Toaster - a fast, secure, full-featured mail server.


=head1 SYNOPSIS

    functions used in: toaster-watcher.pl
                       toaster_setup.pl
                       qqtool.pl

To expose much of what can be done with these, run toaster_setup.pl -s help and you'll get a list of the available targets.

The functions in Mail::Toaster.pm are used by toaster-watcher.pl (which is run every 5 minutes via cron), as well as in toaster_setup.pl and other functions, particularly those in Qmail.pm and mailadmin.


=head1 USAGE

    use Mail::Toaster;
    my $toaster = Mail::Toaster->new;

    # verify that processes are all running and complain if not
    $toaster->check();

    # get a list of all maildirs on the system
    my @all_maildirs = $toaster->get_maildir_paths();

    # clean up old messages over X days old
    $toaster->clean_mailboxes();

    # clean up messages in Trash folders that exceed X days
    foreach my $maildir ( @all_maildirs ) {
        $toaster->maildir_clean_trash( path => $maildir );
    };

These functions can all be called indivually, see the working
examples in the aforementioned scripts or the t/Toaster.t file.


=head1 DESCRIPTION


Mail::Toaster, Everything you need to build a industrial strength mail system.

A collection of perl scripts and modules that are quite useful for building and maintaining a mail system. It was first authored for FreeBSD and has since been extended to Mac OS X, and Linux. It has become quite useful on other platforms and may grow to support other MTA's (think postfix) in the future.


=head1 SUBROUTINES


A separate section listing the public components of the module's interface.
These normally consist of either subroutines that may be exported, or methods
that may be called on objects belonging to the classes that the module provides.
Name the section accordingly.

In an object-oriented module, this section should begin with a sentence of the
form "An object of this class represents...", to give the reader a high-level
context to help them understand the methods that are subsequently described.


=over 8


=item new

  ############################################
  # Usage      : use Mail::Toaster;
  #            : my $toaster = Mail::Toaster->new;
  # Purpose    : create a new Mail::Toaster object
  # Returns    : an object to access Mail::Toaster functions
  # Parameters : none
  # Throws     : no exceptions


=item check

  ############################################
  # Usage      : $toaster->check();
  # Purpose    : Runs a series of tests to inform admins of server problems
  # Returns    : prints out a series of test failures
  # Throws     : no exceptions
  # See Also   : toaster-watcher.pl
  # Comments   :

Performs the following tests:

   * check for processes that should be running.
   * make sure watcher.log is less than 1MB
   * make sure ~alias/.qmail-* exist and are not empty
   * verify multilog log directories are working

When this is run by toaster-watcher.pl via cron, the mail server admin will get notified via email any time one of the tests fails. Otherwise, there is no output generated.


=item learn_mailboxes

  ############################################
  # Usage      : $toaster->learn_mailboxes();
  # Purpose    : train SpamAssassin bayesian filters with your ham & spam
  # Returns    : 0 - failure, 1 - success
  # See Also   : n/a
  # Comments   :

Powers an easy to use mechanism for training SpamAssassin on what you think is ham versus spam. It does this by trawling through a mail system, finding mail messages that have arrived since the last time it ran. It passes these messages through sa-learn with the appropriate flags (sa-learn --ham|--spam) to train its bayesian filters.


=item clean_mailboxes

  ############# clean_mailboxes ##############
  # Usage      : $toaster->clean_mailboxes();
  # Purpose    : cleaning out old mail messages from user mailboxes
  # Returns    : 0 - failure, 1 - success
  # See Also   : n/a
  # Comments   :


This sub trawls through the mail system pruning all messages that exceed the threshholds defined in toaster-watcher.conf.

Peter Brezny suggests adding another option which is good. Set a window during which the cleaning script can run so that it is not running during the highest load times.


=item email_send


  ############ email_send ####################
  # Usage      : $toaster->email_send(type=>"clean" );
  #            : $toaster->email_send(type=>"spam"  );
  #            : $toaster->email_send(type=>"attach");
  #            : $toaster->email_send(type=>"virus" );
  #            : $toaster->email_send(type=>"clam"  );
  #
  # Purpose    : send test emails to test the content scanner
  # Returns    : 1 on success
  # Parameters : type (clean, spam, attach, virus, clam)
  # See Also   : email_send_[clean|spam|...]


Email test routines for testing a mail toaster installation.

This sends a test email of a specified type to the postmaster email address configured in toaster-watcher.conf.


=item email_send_attach


  ######### email_send_attach ###############
  # Usage      : internal only
  # Purpose    : send an email with a .com attachment
  # Parameters : an email address
  # See Also   : email_send

Sends a sample test email to the provided address with a .com file extension. If attachment scanning is enabled, this should trigger the content scanner (simscan/qmailscanner/etc) to reject the message.


=item email_send_clam

Sends a test clam.zip test virus pattern, testing to verify that the AV engine catches it.


=item email_send_clean

Sends a test clean email that the email filters should not block.


=item email_send_eicar

Sends an email message with the Eicar virus inline. It should trigger the AV engine and block the message.


=item email_send_spam

Sends a sample spam message that SpamAssassin should block.


=item get_toaster_cgibin

Determine the location of the cgi-bin directory used for email applications.

=item get_toaster_conf

Determine where the *.conf files for mail-toaster are stored.


=item get_toaster_logs

Determine where log files are stored.


=item get_toaster_htdocs

Determine the location of the htdocs directory used for email applications.


=item maildir_clean_spam

  ########### maildir_clean_spam #############
  # Usage      : $toaster->maildir_clean_spam(
  #                  path => '/home/domains/example.com/user',
  #              );
  # Purpose    : Removes spam that exceeds age as defined in t-w.conf.
  # Returns    : 0 - failure, 1 - success
  # Parameters : path - path to a maildir


results in the Spam folder of a maildir with messages older than X days removed.


=item get_maildir_paths

  ############################################
  # Usage      : $toaster->get_maildir_paths()
  # Purpose    : build a list of email dirs to perform actions upon
  # Returns    : an array listing every maildir on a Mail::Toaster
  # Throws     : exception on failure, or 0 if fatal=>0

This sub creates a list of all the domains on a Mail::Toaster, and then creates a list of every email box (maildir) on every domain, thus generating a list of every mailbox on the system.


=item maildir_clean_trash

  ############################################
  # Usage      : $toaster->maildir_clean_trash(
  #                 path => '/home/domains/example.com/user',
  #              );
  # Purpose    : expire old messages in Trash folders
  # Returns    : 0 - failure, 1 - success
  # Results    : a Trash folder with messages older than X days pruned
  # Parameters : path - path to a maildir
  # Throws     : no exceptions

Comments: Removes messages in .Trash folders that exceed the number of days defined in toaster-watcher.conf.


=item maildir_clean_sent

  ############################################
  # Usage      : $toaster->maildir_clean_sent(
  #                 path => '/home/domains/example.com/user',
  #              );
  # Purpose    : expire old messages in Sent folders
  # Returns    : 0 - failure, 1 - success
  # Results    : messages over X days in Sent folders are deleted
  # Parameters : path - path to a maildir
  # Throws     : no exceptions


=item maildir_clean_new


  ############ maildir_clean_new #############
  # Usage      : $toaster->maildir_clean_new(
  #                 path => '/home/domains/example.com/user',
  #              );
  # Purpose    : expire unread messages older than X days
  # Returns    : 0 - failure, 1 - success
  # Parameters : path - path to a maildir
  # Throws     : no exceptions

  This should be set to a large value, such as 180 or 365. Odds are, if a user hasn't read their messages in that amount of time, they never will so we should clean them out.


=item maildir_clean_ham


  ############################################
  # Usage      : $toaster->maildir_clean_ham(
  #                 path => '/home/domains/example.com/user',
  #              );
  # Purpose    : prune read email messages
  # Returns    : 0 - failure, 1 - success
  # Results    : an INBOX minus read messages older than X days
  # Parameters : path - path to a maildir
  # Throws     : no exceptions


=item service_dir_create

Create the supervised services directory (if it doesn't exist).

	$toaster->service_dir_create();

Also sets the permissions to 775.


=item service_dir_get

This is necessary because things such as service directories are now in /var/service by default but older versions of my toaster installed them in /service. This will detect and adjust for that.


 Example
   $toaster->service_dir_get( prot=>'smtp' );


 arguments required:
   prot is one of these protocols: smtp, pop3, submit, send

 arguments optional:
   debug
   fatal

 result:
    0 - failure
    the path to a directory upon success

=item service_dir_test

Makes sure the service directory is set up properly

	$toaster->service_dir_test();

Also sets the permissions to 775.


=item service_symlinks

Sets up the supervised mail services for Mail::Toaster

    $toaster->service_symlinks();

This populates the supervised service directory (default: /var/service) with symlinks to the supervise control directories (typically /var/qmail/supervise/). Creates and sets permissions on the following directories and files:

    /var/service/pop3
    /var/service/smtp
    /var/service/send
    /var/service/submit


=item supervise_dir_get

  my $dir = $toaster->supervise_dir_get( prot=>"smtp" );

This sub just sets the supervise directory used by the various qmail
services (qmail-smtpd, qmail-send, qmail-pop3d, qmail-submit). It sets
the values according to your preferences in toaster-watcher.conf. If
any settings are missing from the config, it chooses reasonable defaults.

This is used primarily to allow you to set your mail system up in ways
that are a different than mine, like a LWQ install.


=item supervise_dirs_create

Creates the qmail supervise directories.

	$toaster->supervise_dirs_create(debug=>$debug);

The default directories created are:

  $supervise/smtp
  $supervise/submit
  $supervise/send
  $supervise/pop3

unless otherwise specified in $conf


=item supervised_dir_test

Checks a supervised directory to see if it is set up properly for supervise to start it. It performs a bunch of tests including:

 * directory exists
 * dir/run file exists and is executable
 * dir/down file is not present
 * dir/log exists
 * dir/log/run exists and is executable
 * dir/log/down does not exist

 arguments required:
    prot - a protocol to check (smtp, pop3, send, submit)

 arguments optional:
    debug


=item supervise_restart

Restarts a supervised process.


=item check_processes

Tests to see if all the processes on your Mail::Toaster that should be running in fact are.

 usage:
    $toaster->check_processes();

 arguments optional:
    debug



=back

=head1 SEE ALSO

The following man (perldoc) pages:

  Mail::Toaster
  Mail::Toaster::Conf
  toaster.conf
  toaster-watcher.conf

  http://www.mail-toaster.org/


=head1 DIAGNOSTICS

Since the functions in the module are primarily called by toaster-watcher.pl, they are designed to do their work with a minimum amount of feedback, complaining only when a problem is encountered. Whether or not they produce status messages and verbose errors is governed by the "debug" argument which is passed to each sub/function.

Status messages and verbose logging is enabled by default. toaster-watcher.pl and most of the automated tests (see t/toaster-watcher.t and t/Toaster.t) explicitely turns this off by setting debug=>0.


=head1 CONFIGURATION AND ENVIRONMENT

The primary means of configuration for Mail::Toaster is via toaster-watcher.conf. It is typically installed in /usr/local/etc, but may also be found in /opt/local/etc, or simply /etc. Documentation for the man settings in toaster-watcher.conf can be found in the man page (perldoc toaster-watcher.conf).


=head1 DEPENDENCIES

    Params::Validate - must be installed seperately
    POSIX (floor only - included with Perl)
    Mail::Toaster::Utility


=head1 BUGS AND LIMITATIONS

There are no known bugs in this module.
Please report problems to author
Patches are welcome.


=head1 TODO

  Install an optional stub DNS resolver (dnscache)

=head1 AUTHOR

Matt Simerson (matt@tnpi.net)


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2004-2010, The Network People, Inc. C<< <matt@tnpi.net> >>. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
