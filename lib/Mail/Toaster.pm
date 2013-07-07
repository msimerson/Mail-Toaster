package Mail::Toaster;

use strict;
use warnings;

our $VERSION = '5.42';

use Carp;
use Cwd;
#use Data::Dumper;
use English '-no_match_vars';
use File::Basename;
use File::Find;
use File::stat;
use Params::Validate ':all';
use Sys::Hostname;
use version;

use lib 'lib';
use parent 'Mail::Toaster::Base';

sub test {
    my $self = shift;
    my $mess = shift or croak "test with no args?!";
    my $result = shift;

    my %p = validate(@_, { $self->get_std_opts } );
    return $p{test_ok} if defined $p{test_ok};

    return if ! $self->verbose;
    print $mess;
    defined $result or do { print "\n"; return; };
    for ( my $i = length($mess); $i <=  65; $i++ ) { print '.' };
    print $result ? 'ok' : 'FAILED';
    print "\n";
};

sub check {
    my $self = shift;
    my %p = validate(@_, { $self->get_std_opts } );
    my %args = $self->get_std_args( %p );

    $self->check_permissions_twc;   # toaster-watcher.conf
    $self->check_permissions_tc;    # toaster.conf

    $self->check_running_processes;
    $self->check_watcher_log_size;

    # check that we can't SMTP AUTH with random user names and passwords

    # make sure the supervised processes are configured correctly.
    foreach my $prot ( $self->get_daemons(1) ) {
        $self->supervised_dir_test( $prot, %args );
    };

    $self->check_cron_dccd;
    return 1;
}

sub check_permissions_tc {
    my $self = shift;
    my $etc = $self->conf->{'system_config_dir'} || '/usr/local/etc';
    my $conf = "$etc/toaster.conf";
    return if ! -f $conf;
    my $mode = $self->util->file_mode(file=>$conf, verbose=>0);
    $self->audit( "file mode of $conf is $mode" );
    my $others = substr($mode, -1, 1);
    return 1 if $others;
    chmod 0644, $conf;
    $self->audit( "Changed the permissions on $conf to 0644");
    return 1;
};

sub check_permissions_twc {
    my $self = shift;
    my $etc = $self->conf->{'system_config_dir'} || '/usr/local/etc';
    my $conf = "$etc/toaster-watcher.conf";
    return if ! -f $conf;

    my $mode = $self->util->file_mode( file=>$conf, verbose=>0 );
    $self->audit( "file mode of $conf is $mode." );
    my $others = substr($mode, -1, 1);
    if ( $others > 0 ) {
        chmod 0600, $conf;
        $self->audit( "Changed the permissions on $conf to 0600" );
    }
    return 1;
};

sub check_running_processes {
    my $self = shift;
    my %p = validate(@_, { $self->get_std_opts } );
    my $conf = $self->conf;

    $self->audit( "checking running processes");

    my @processes = qw/ svscan qmail-send multilog /;

    push @processes, "httpd"              if $conf->{install_apache};
    push @processes, "lighttpd"           if $conf->{install_lighttpd};
    push @processes, "mysqld"             if $conf->{install_mysqld};
    push @processes, "snmpd"              if $conf->{install_snmp};
    push @processes, "clamd", "freshclam" if $conf->{install_clamav};
    push @processes, "sqwebmaild"         if $conf->{install_sqwebmail};
    push @processes, "dovecot"            if $conf->{install_dovecot};
    push @processes, "vpopmaild"          if $conf->{vpopmail_daemon};
    if ( $conf->{install_courier_imap} ) {
        push @processes, "imapd-ssl", "imapd", "pop3d-ssl";
        my $cour = $conf->{install_courier_imap};
        push @processes, "authdaemond" if ( $cour eq 'port' || $cour > 4 );
    };

    foreach (@processes) {
        $self->test( "  $_", $self->util->is_process_running($_) );
    }

    return 1;
}

sub check_cron_dccd {
    my $self = shift;

    return $self->audit("unable to check dcc cron jobs on $OSNAME")
        if $OSNAME ne "freebsd";

    return if ! -f '/usr/local/dcc/libexec/cron-dccd';

    my $periodic_dir = '/usr/local/etc/periodic/daily';
    if ( ! -d $periodic_dir ) {
        $self->util->mkdir_system(dir=>$periodic_dir, mode => '0755')
            or return $self->error("unable to create $periodic_dir");
    };

    my $script = "$periodic_dir/501.dccd";
    if ( ! -f $script ) {
        $self->util->file_write( $script,
            lines => [ '#!/bin/sh', '/usr/local/dcc/libexec/cron-dccd', ],
            mode => '0755',
        );
        $self->audit("created dccd nightly cron job");
    };
};

sub check_watcher_log_size {
    my $self = shift;

    my $logfile = $self->conf->{'toaster_watcher_log'} or return;
    return if ! -e $logfile;

    # make sure watcher.log is not larger than 1MB
    my $size = stat($logfile)->size;
    if ( $size && $size > 999999 ) {
        $self->audit( "compressing $logfile! ($size)");
        $self->util->syscmd( "gzip -f $logfile" );
    }
};

sub learn_mailboxes {
    my $self = shift;
    my %p = validate(@_, { $self->get_std_opts } );
    return $p{test_ok} if defined $p{test_ok};

    my $days = $self->conf->{maildir_learn_interval}
        or return $self->error( 'learn_mailboxes: disabled', fatal => 0 );

    my $find = $self->util->find_bin( 'find', verbose=>0 );

    foreach my $d ( $self->get_maildir_paths() ) {  # every email box
        if  ( ! -d $d ) {
            $self->audit("invalid path: $d");
            next;
        };
        my ($user,$domain) = (split('/', $d))[-1,-2];
        my $email = lc($user) . '@'. lc($domain);

        my $age = $self->conf->{maildir_learn_interval} * 86400;
        if ( -f "$d/learn.log" ) {
            $age = time - stat("$d/learn.log")->ctime;
        };

        my $counter = $self->learn_mailbox($email, $d, $find, $age);
        next if ! $counter->{ham} && ! $counter->{spam};

        $self->util->logfile_append( file => "$d/learn.log",
            prog => $0,
            lines => [ "trained $counter->{'ham'} hams and $counter->{'spam'} spams" ],
            verbose => 0,
        );
    }
}

sub learn_mailbox {
    my ($self, $email, $d, $find, $age) = @_;

    my %counter = ( spam => 0, ham => 0 );
    my %messages = ( ham => [], spam => [] );

    foreach my $dir ( $self->get_maildir_folders( $d, $find ) ) {
        my $type = 'ham';
        $type = 'spam' if $dir =~ /(?:spam|junk)/i;

        foreach my $message ( $self->get_maildir_messages($dir, $age) ) {
            $counter{$type}++;  # throttle learning for really big maildirs
            next if $counter{$type} > 10000 && $counter{$type} % 50 != 0;
            next if $counter{$type} >  5000 && $counter{$type} % 25 != 0;
            next if $counter{$type} >  2500 && $counter{$type} % 10 != 0;

            $self->train_dspam( $type, $message, $email );
            push @{$messages{$type}}, $message; # for SA training
        };
    };

    $self->train_spamassassin($d, \%messages );
    return \%counter;
};

sub train_spamassassin {
    my ($self, $d, $messages ) = @_;

    return if ! $self->{install_spamassassin};
    my $salearn = $self->util->find_bin('sa-learn');

    foreach my $t ( qw/ ham spam / ) {
        my $list = $messages->{$t};
        next if ! scalar @$list;
        my $file = "$d/learned-$t-messages";
        $self->util->file_write($file, lines => $list, verbose=>0 );
        $self->util->syscmd( "$salearn --$t -f $file", verbose=>0 );
    };
};

sub train_dspam {
    my ($self, $type, $file, $email) = @_;
    if ( ! $self->conf->{install_dspam} ) {
        $self->audit( "skip dspam training, install_dspam unset");
        return;
    };
    if ( ! -f $file ) {   # file moved (due to MUA action)
        $self->audit( "skipping dspam train of $file, it moved");
        return;
    };
    my $dspam = $self->util->find_bin('dspamc');
    if ( ! -x $dspam ) {
        $self->audit("skipping, could not exec $dspam");
        return;
    };
    my $cmd = "$dspam --client --stdout --deliver=summary --user $email";
    if ( $type eq 'ham' ) {
        my $dspam_class = $self->get_dspam_class( $file );
        if ( $dspam_class ) {
            if ( $dspam_class eq 'innocent' ) {
                $self->audit("dpam tagged innocent correctly, skipping");
                return;
            };
            if ( $dspam_class eq 'spam' ) {         # dspam miss
                $cmd .= "--class=innocent --source=error --mode=toe";
            };
        }
        else {
            $cmd .= "--class=innocent --source=corpus";
        };
    }
    elsif ( $type eq 'spam' ) {
        my $dspam_class = $self->get_dspam_class( $file );
        if ( $dspam_class ) {
            if ( $dspam_class eq 'spam' ) {
                $self->audit("dpam tagged spam correctly, skipping");
                return;
            }
            elsif ( $dspam_class eq 'innocent' ) {
                $cmd .= "--class=spam --source=error --mode=toe";
            };
        }
        else {
            $cmd .= "--class=spam --source=corpus";
        };
    };
    $self->audit( "$cmd < $file" );
    my $r = `$cmd < '$file'`;  # capture the stdout
    $self->audit( $r );
};

sub clean_mailboxes {
    my $self = shift;
    my %p = validate(@_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $days = $self->conf->{maildir_clean_interval} or
        return $self->audit( 'skip maildir clean, config' );

    my $clean_log = $self->get_clean_log;
    if ( -M $clean_log <= $days ) {
        $self->audit( "skipping, $clean_log is less than $days old");
        return 1;
    }

    $self->util->logfile_append(
        file  => $clean_log,
        prog  => $0,
        lines => ["clean_mailboxes running."],
    ) or return;

    $self->audit( "checks passed, cleaning");

    my @every_maildir_on_server = $self->get_maildir_paths();

    foreach my $maildir (@every_maildir_on_server) {

        if ( ! $maildir || ! -d $maildir ) {
            $self->audit( "$maildir does not exist");
            next;
        };

        $self->audit( "  processing $maildir");

        $self->maildir_clean_ham( $maildir );
        $self->maildir_clean_new( $maildir );
        $self->maildir_clean_sent( $maildir );
        $self->maildir_clean_trash( $maildir );
        $self->maildir_clean_spam( $maildir );
    };

    return 1;
}

sub clear_open_smtp {
    my $self = shift;

    return if ! $self->conf->{vpopmail_roaming_users};

    my $vpopdir = $self->conf->{vpopmail_home_dir} || '/usr/local/vpopmail';

    if ( ! -x "$vpopdir/bin/clearopensmtp" ) {
        return $self->error( "cannot find clearopensmtp program!",fatal=>0 );
    };

    $self->util->syscmd( "$vpopdir/bin/clearopensmtp" );
};

sub maildir_clean_spam {
    my $self = shift;
    my $path = shift or croak "missing maildir!";
    my $days = $self->conf->{maildir_clean_Spam} or return;
    my $spambox = "$path/Maildir/.Spam";

    return $self->error( "clean_spam: skipped because $spambox does not exist.",fatal=>0)
        if !-d $spambox;

    $self->audit( "clean_spam: cleaning spam messages older than $days days." );

    my $find = $self->util->find_bin( 'find', verbose=>0 );
    $self->util->syscmd( "$find $spambox/cur -type f -mtime +$days -exec rm {} \\;" );
    $self->util->syscmd( "$find $spambox/new -type f -mtime +$days -exec rm {} \\;" );
};

sub maildir_clean_trash {
    my $self = shift;
    my $path = shift or croak "missing maildir!";
    my $trash = "$path/Maildir/.Trash";
    my $days = $self->conf->{'maildir_clean_Trash'} or return;

    return $self->error( "clean_trash: skipped because $trash does not exist.", fatal=>0)
        if ! -d $trash;

    $self->audit( "clean_trash: cleaning deleted messages older than $days days");

    my $find = $self->util->find_bin( "find" );
    $self->util->syscmd( "$find $trash/new -type f -mtime +$days -exec rm {} \\;");
    $self->util->syscmd( "$find $trash/cur -type f -mtime +$days -exec rm {} \\;");
}

sub maildir_clean_sent {
    my $self = shift;
    my $path = shift or croak "missing maildir!";
    my $sent = "$path/Maildir/.Sent";
    my $days = $self->conf->{maildir_clean_Sent} or return;

    if ( ! -d $sent ) {
        $self->audit("clean_sent: skipped because $sent does not exist.");
        return 0;
    }

    $self->audit( "clean_sent: cleaning sent messages older than $days days");

    my $find = $self->util->find_bin( "find", verbose=>0 );
    $self->util->syscmd( "$find $sent/new -type f -mtime +$days -exec rm {} \\;");
    $self->util->syscmd( "$find $sent/cur -type f -mtime +$days -exec rm {} \\;");
}

sub maildir_clean_new {
    my $self = shift;
    my $path = shift or croak "missing maildir!";
    my $unread = "$path/Maildir/new";
    my $days = $self->conf->{maildir_clean_Unread} or return;

    if ( ! -d $unread ) {
        $self->audit( "clean_new: skipped because $unread does not exist.");
        return 0;
    }

    my $find = $self->util->find_bin( "find", verbose=>0 );
    $self->audit( "clean_new: cleaning unread messages older than $days days");
    $self->util->syscmd( "$find $unread -type f -mtime +$days -exec rm {} \\;" );
}

sub maildir_clean_ham {
    my $self = shift;
    my $path = shift or croak "missing maildir!";
    my $read = "$path/Maildir/cur";
    my $days = $self->conf->{maildir_clean_Read} or return;

    if ( ! -d $read ) {
        $self->audit( "clean_ham: skipped, $read does not exist.");
        return;
    }

    $self->audit( "clean_ham: cleaning read messages older than $days days");
    my $find = $self->util->find_bin( 'find', verbose=>0 );
    $self->util->syscmd( "$find $read -type f -mtime +$days -exec rm {} \\;" );
}

sub get_daemons {
    my $self = shift;
    my $active = shift;
    return qw/ smtp send pop3 submit qmail-deliverable qpsmtpd vpopmaild / if ! $active;

    my @list = qw/ send pop3 /;
    push @list, 'vpopmaild' if $self->conf->{vpopmail_daemon};

    if ( $self->conf->{smtpd_daemon} && 'qpsmtpd' eq $self->conf->{smtpd_daemon} ) {
        push @list, 'qmail-deliverable', 'qpsmtpd';
    }
    else {
        push @list, 'smtp';
    };

    if ( ! $self->conf->{submit_daemon} || 'qmail' eq $self->conf->{submit_daemon} ) {
        push @list, 'submit';
    };

    return @list;
};

sub get_clean_log {
    my $self = shift;

    my $dir = $self->conf->{'qmail_log_base'} || '/var/log/mail';
    my $clean_log = "$dir/clean.log";

    $self->audit( "clean log file is: $clean_log");

    # create the log file if it does not exist
    if ( ! -e $clean_log ) {
        $self->util->file_write( $clean_log, lines => ["created file"] );
        return if ! -e $clean_log;
    }
    return $clean_log;
};

sub get_dspam_class {
    my ($self, $file) = @_;
    if ( ! -f $file ) {
        return $self->error( "file $file disappeared",fatal=>0 );
    };
    my @headers = $self->util->file_read( $file, max_lines => 20 );
    #foreach my $h ( @headers ) { print "\t$h\n"; };

    no warnings;
    my ($dspam_status) = grep {/^X-DSPAM-Result:/} @headers;
    my ($signature) = grep {/^X-DSPAM-Signature:/} @headers;
    use warnings;

    return if ! $dspam_status || ! $signature;
    my ($class) = $dspam_status =~ /^X-DSPAM-Result:\s+([\w]+)\,/
        or return;
    return lc $class;
};

sub get_maildir_paths {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $vpdir = $self->conf->{vpopmail_home_dir};

    # this method requires a SQL query for each domain
    my @all_domains = $self->qmail->get_domains_from_assign(fatal=> 0);

    return $self->error( "No domains found in qmail/users/assign",fatal=>0 )
        unless $all_domains[0];

    my $count = @all_domains;
    $self->audit( "get_maildir_paths: found $count domains." );

    my @paths;
    foreach (@all_domains) {
        my $domain_name = $_->{'dom'};
        #$self->audit( "  processing $domain_name mailboxes." );
        my @list_of_maildirs = `$vpdir/bin/vuserinfo -d -D $domain_name`;
        push @paths, @list_of_maildirs;
    }

    chomp @paths;
    my %saw;
    my @unique_paths = grep(!$saw{$_}++, @paths);

    $self->audit( "found ". scalar @unique_paths ." mailboxes.");
    return @unique_paths;
}

sub get_maildir_folders {
    my ( $self, $d, $find ) = @_;

    $find ||= $self->util->find_bin( 'find', verbose=>0 );
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
    my ($self, $dir, $age ) = @_;

    my @recents;
    my $oldest = time - $age;

    find( { wanted =>
                sub { -f && stat($_)->ctime > $oldest
                         && push @recents, $File::Find::name;
                    },
            no_chdir=>1,
        }, $dir );

    #print "found " . @recents . " messages in $dir\n";
    chomp @recents;
    return @recents;
};

sub get_toaster_htdocs {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    # if available, use the configured location
    if ( defined $self->conf && $self->conf->{toaster_http_docs} ) {
        return $self->conf->{toaster_http_docs};
    }

    # check the usual locations
    foreach my $dir (
        "/usr/local/www/toaster",       # toaster
        "/usr/local/www/data/mail",     # legacy
        "/usr/local/www/mail",
        "/Library/Webserver/Documents", # Mac OS X
        "/var/www/html",                # Linux
        "/usr/local/www/data",          # FreeBSD
            ) {
        return $dir if -d $dir;
    };

    $self->error("could not find htdocs location.");
}

sub get_toaster_cgibin {
    my $self = shift;

    # if set, use.
    return $self->conf->{toaster_cgi_bin} if defined $self->conf->{toaster_cgi_bin};

    # Mail-Toaster
    return "/usr/local/www/cgi-bin.mail" if -d "/usr/local/www/cgi-bin.mail";
    return "/usr/local/www/cgi-bin" if -d "/usr/local/www/cgi-bin"; # FreeBSD
    return "/var/www/cgi-bin" if -d "/var/www/cgi-bin"; # linux

    # Mac OS X standard location
    if ( -d "/Library/WebServer/CGI-Executables" ) {
        return "/Library/WebServer/CGI-Executables";
    }

    # all else failed, try to predict
    return $OSNAME eq "linux"  ? "/var/www/cgi-bin"
         : $OSNAME eq "darwin" ? "/Library/WebServer/CGI-Executables"
         : $OSNAME eq "netbsd" ? "/var/apache/cgi-bin"
         : "/usr/local/www/cgi-bin"   # last resort
         ;
}

sub get_toaster_logs {
    my $self = shift;
    return $self->conf->{logs_base} || $self->conf->{qmail_log_base} || '/var/log/mail';
}

sub process_logfiles {
    my $self = shift;
    my $conf = $self->conf;

    my $pop3_logs = $conf->{pop3_log_method} || $conf->{logs_pop3d};
    my $smtpd  = $conf->{smtpd_daemon}  || 'qmail';
    my $submit = $conf->{submit_daemon} || 'qmail';

    $self->supervised_log_rotate('send'  );
    $self->supervised_log_rotate('smtp'  ) if $smtpd eq 'qmail';
    $self->supervised_log_rotate('submit') if $conf->{submit_enable} && $submit eq 'qmail';
    $self->supervised_log_rotate('pop3'  ) if $pop3_logs eq 'qpop3d';

    $self->logs->compress_yesterdays_logs( "sendlog" );
    $self->logs->compress_yesterdays_logs( "smtplog" ) if $smtpd eq 'qmail';
    $self->logs->compress_yesterdays_logs( "pop3log" ) if $pop3_logs eq 'qpop3d';

    $self->logs->purge_last_months_logs() if $conf->{logs_archive_purge};

    return 1;
};

sub run_isoqlog {
    my $self = shift;
    return if ! $self->conf->{install_isoqlog};

    my $isoqlog = $self->util->find_bin( 'isoqlog', verbose=>0 )
        or return;

    system "$isoqlog >/dev/null" or return 1;
    return;
};

sub run_qmailscanner {
    my $self = shift;
    return if ! $self->conf->{install_qmailscanner};
    return if ! $self->conf->{qs_quarantine_process};

    $self->audit( "checking qmail-scanner quarantine.");
    my @list = $self->qmail->get_qmailscanner_virus_sender_ips;

    $self->qmail->UpdateVirusBlocks( ips => \@list )
        if $self->conf->{qs_block_virus_senders};
};

sub service_dir_get {
    my $self = shift;
    my $prot = shift or croak "missing prot!";

    $prot = 'smtp' if $prot eq 'smtpd'; # catch and fix legacy usage.

    my %valid = map { $_ => 1 } $self->get_daemons;
    return $self->error( "invalid service: $prot",fatal=>0) if ! $valid{$prot};

    my $svcdir = $self->conf->{qmail_service} || '/var/service';
       $svcdir = "/service" if ( !-d $svcdir && -d '/service' ); # legacy

    my $dir = "$svcdir/$prot";

    $self->audit("service dir for $prot is $dir");
    return $dir;
}

sub service_symlinks {
    my $self = shift;

    my @active_services = 'send';

    foreach my $prot ( qw/ smtp submit pop3 vpopmaild qmail_deliverabled / ) {
        my $method = 'service_symlinks_' . $prot;
        my $r = $self->$method or next;
        push @active_services, $r;
    };

    foreach my $prot ( @active_services ) {

        my $svcdir = $self->service_dir_get( $prot );
        my $supdir = $self->supervise_dir_get( $prot );

        if ( ! -d $supdir ) {
            $self->audit( "skip symlink $svcdir, target $supdir doesn't exist.");
            next;
        };

        if ( -e $svcdir ) {
            $self->audit( "service_symlinks: $svcdir already exists.");
            next;
        }

        print "service_symlinks: creating symlink from $supdir to $svcdir\n";
        symlink( $supdir, $svcdir )
            or $self->error("couldn't symlink $supdir: $!");
    }

    return 1;
}

sub service_symlinks_pop3 {
    my $self = shift;

    if (    $self->conf->{pop3_enable}   # legacy
         || $self->conf->{pop3_daemon} eq 'qpop3d' ) {
        return 'pop3';
    };
    $self->service_symlinks_cleanup( 'pop3' );
    return;
};

sub service_symlinks_vpopmaild {
    my $self = shift;
    my $enabled = $self->conf->{vpopmail_daemon};
    return 'vpopmaild' if $enabled;
    $self->service_symlinks_cleanup( 'vpopmaild' );
    return;
};

sub service_symlinks_qmail_deliverabled {
    my $self = shift;
#return 'qmail-deliverabled' if $enabled;
#$self->service_symlinks_cleanup( 'qmail-deliverabled' );
    return;
};

sub service_symlinks_smtp {
    my $self = shift;
    my $daemon = $self->conf->{smtpd_daemon} or return 'smtp';

    if ( $daemon eq 'qmail' ) {
        $self->service_symlinks_cleanup( 'qpsmtpd' );
        return 'smtp';
    };

    if ( $daemon eq 'qpsmtpd' ) {
        $self->service_symlinks_cleanup( 'smtp' );
        return 'qpsmtpd';
    };

    return 'smtp';
}

sub service_symlinks_submit {
    my $self = shift;
    my $daemon = $self->conf->{submit_daemon} or return 'submit';

    if ( $daemon eq 'qpsmtpd' ) {
        $self->service_symlinks_cleanup( 'submit' );
        return 'qpsmtpd';
    };

    return 'submit';
}

sub service_symlinks_cleanup {
    my ($self, $prot ) = @_;

    my $dir = $self->service_dir_get( $prot );

    if ( ! -e $dir ) {
        $self->audit("$prot not enabled due to configuration settings.");
        return;
    };

    $self->audit("deleting $dir because $prot isn't enabled!");
    unlink $dir;
}

sub service_dir_create {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $service = $self->conf->{qmail_service} || "/var/service";

    if ( ! -d $service ) {
        mkdir( $service, oct('0775') ) or
            return $self->error( "service_dir_create: failed to create $service: $!");
    };

    $self->audit("$service exists");

    unless ( -l "/service" ) {
        if ( -d "/service" ) {
            $self->util->syscmd( "rm -rf /service", fatal=>0 );
        }
        symlink( "/var/service", "/service" );
    }
}

sub service_dir_test {
    my $self = shift;

    my $service = $self->conf->{qmail_service} || "/var/service";

    return $self->error( "service_dir_test: $service is missing!",fatal=>0)
        if !-d $service;

    $self->audit( "service_dir_test: $service already exists.");

    return $self->error( "/service symlink is missing!",fatal=>0)
        unless ( -l "/service" && -e "/service" );

    $self->audit( "service_dir_test: /service symlink exists.");

    return 1;
}

sub sqwebmail_clean_cache {
    my $self = shift;
    return 1 if ! $self->conf->{install_sqwebmail};
    my $script = "/usr/local/share/sqwebmail/cleancache.pl";
    return $self->error("unable to locate sqwebmail's cleancache.pl")
        if ! -x $script;
    system $script;
};

sub supervise_dir_get {
    my $self = shift;
    my $prot = shift or croak "missing prot!";

    my $sdir = $self->qmail->get_supervise_dir;
    $sdir = "/var/supervise" if ( !-d $sdir && -d '/var/supervise'); # legacy
    $sdir = "/supervise" if ( !-d $sdir && -d '/supervise');
    $sdir ||= $self->qmail->get_qmail_dir . '/supervise';

    my $dir = "$sdir/$prot";

    # expand the qmail_supervise shortcut
    $dir = "$sdir/$1" if $dir =~ /^qmail_supervise\/(.*)$/;

    $self->audit( "supervise dir for $prot is $dir");
    return $dir;
}

sub supervise_dirs_create {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    my %args = $self->get_std_args( %p );

    my $supdir = $self->qmail->get_supervise_dir;

    return $p{test_ok} if defined $p{test_ok};

    if ( -d $supdir ) {
        $self->audit( "supervise_dirs_create: $supdir, ok (exists)" );
    }
    else {
        mkpath( $supdir, oct('0775') )
            or $self->error( "failed to create $supdir: $!", %args);
        $self->audit( "supervise_dirs_create: $supdir, ok" );
    }

    foreach my $prot ( $self->get_daemons ) {

        my $protdir = $self->supervise_dir_get( $prot );
        if ( -d $protdir ) {
            $self->audit( "supervise_dirs_create: $protdir, ok (exists)" );
            next;
        }

        mkdir( $protdir, oct('0775') )
            or $self->error( "failed to create $protdir: $!", %args );
        $self->audit( "supervise_dirs_create: creating $protdir, ok" );

        mkdir( "$protdir/log", oct('0775') )
            or $self->error( "failed to create $protdir/log: $!", %args);
        $self->audit( "supervise_dirs_create: creating $protdir/log, ok" );

        $self->util->syscmd( "chmod +t $protdir", verbose=>0 );
    }

    foreach my $prot ( $self->get_daemons(1) ) {
        my $protdir = $self->supervise_dir_get( $prot );
        my $svc_dir = $self->service_dir_get($prot);
        symlink( $protdir, $svc_dir ) if ! -e "$supdir/$prot";
    };
}

sub supervised_dir_test {
    my $self = shift;
    my $prot = shift or croak "missing prot";
    my %p = validate( @_, { $self->get_std_opts } );
    my %args = $self->get_std_args( %p );

    my $dir = $self->supervise_dir_get( $prot ) or return;

    return $p{test_ok} if defined $p{test_ok};

    return $self->error("directory $dir does not exist", %args )
        unless ( -d $dir || -l $dir );
    $self->test( "exists, $dir", -d $dir );

    if ( ! -f "$dir/run" ) {
        $self->qmail->install_qmail_control_files;
        return $self->error("$dir/run does not exist!", %args ) if ! -f "$dir/run";
    };
    $self->test( "exists, $dir/run", -f "$dir/run" );

    return $self->error("$dir/run is not executable", %args ) if ! -x "$dir/run";
    $self->test( "perms,  $dir/run", -x "$dir/run" );

    return $self->error("$dir/down is present", %args ) if -f "$dir/down";
    $self->test( "!exist, $dir/down", !-f "$dir/down" );

    my $log_method = $self->conf->{ $prot . '_log_method' }
      || $self->conf->{ $prot . 'd_log_method' }
      || "multilog";

    return 1 if $log_method =~ /(?:syslog|disabled)/i;

    # make sure the log directory exists
    return $self->error( "$dir/log does not exist", %args ) if ! -d "$dir/log";
    $self->test( "exists, $dir/log", -d "$dir/log" );

    # make sure the supervise/log/run file exists
    if ( ! -f "$dir/log/run" ) {
        $self->qmail->install_qmail_control_log_files;
        return $self->error( "$dir/log/run does not exist", %args )
            if ! -f "$dir/log/run";
    };
    $self->test( "exists, $dir/log/run", -f "$dir/log/run" );

    # check the log/run file permissions
    return $self->error( "perms, $dir/log/run", %args ) if ! -x "$dir/log/run";
    $self->test( "perms,  $dir/log/run", -x "$dir/log/run" );

    # make sure the supervise/down file does not exist
    return $self->error( "$dir/log/down exists", %args ) if -f "$dir/log/down";
    $self->test( "!exist, $dir/log/down", "$dir/log/down" );
    return 1;
}

sub supervised_do_not_edit_notice {
    my $self = shift;
    my $vdir = shift;

    if ($vdir) {
        $vdir = $self->setup->vpopmail->get_vpop_dir;
    }

    my $qdir   = $self->qmail->get_qmail_dir;
    my $prefix = $self->conf->{toaster_prefix} || '/usr/local';

    my $path  = "PATH=$qdir/bin";
       $path .= ":$vdir/bin" if $vdir;
       $path .= ":$prefix/bin:/usr/bin:/bin";

    return "#!/bin/sh\n
#    NOTICE: This file is automatically updated by toaster-watcher.pl.\n
#    Please DO NOT hand edit this file. Instead, edit toaster-watcher.conf
#      and then run toaster-watcher.pl to make your settings active.
#      Run: 'perldoc toaster-watcher.conf' for more detailed info.\n
$path
export PATH\n
";
}

sub supervised_hostname {
    my $self = shift;
    my $prot = shift or croak "missing prot!";

    $prot .= "_hostname";
    $prot = $self->conf->{ $prot . '_hostname' };

    if ( ! $prot || $prot eq "system" ) {
        $self->audit( "using system hostname (" . hostname() . ")" );
        return hostname() . ' ';
    };
    if ( $prot eq "qmail" ) {
        $self->audit( "  using qmail hostname." );
        return '\"$LOCAL" ';
    };

    $self->audit( "using conf defined hostname ($prot).");
    return "$prot ";
}

sub supervised_multilog {
    my $self = shift;
    my $prot = shift or croak "missing prot!";
    my %p = validate( @_, { $self->get_std_opts } );
    my %args = $self->get_std_args( %p );

    my $setuidgid = $self->util->find_bin( 'setuidgid', fatal=>0 );
    my $multilog  = $self->util->find_bin( 'multilog', fatal=>0);

    return $self->error( "supervised_multilog: missing daemontools components!", %args)
        unless ( -x $setuidgid && -x $multilog );

    my $loguser  = $self->conf->{'qmail_log_user'} || "qmaill";
    my $log_base = $self->conf->{'qmail_log_base'} || $self->conf->{'log_base'} || '/var/log/mail';
    my $logprot  = $prot eq 'smtp' ? 'smtpd' : $prot;
    my $runline  = "exec $setuidgid $loguser $multilog t ";

    my $maxbytes = $self->conf->{ $logprot . '_log_maxsize_bytes' } || '100000';
    my $method   = $self->conf->{ $logprot . '_log_method' } || 'none';

    if    ( $method eq "stats" )    { $runline .= "-* +stats s$maxbytes "; }
    elsif ( $method eq "disabled" ) { $runline .= "-* "; }
    else                            { $runline .= "s$maxbytes "; };

    $self->audit( "supervised_multilog: log method for $prot is $method");

    if ( $prot eq "send" && $self->conf->{'send_log_isoqlog'} ) {
        $runline .= "n288 ";    # keep a days worth of logs around
    }

    $runline .= "$log_base/$prot";
    return $runline;
}

sub supervised_log_method {
    my $self = shift;
    my $prot = shift or croak "missing prot!";

    if ( 'syslog' eq $self->conf->{$prot . '_hostname'} ) {
        $self->audit( "  syslog logging." );
        return "\\\n\tsplogger $prot ";
    };

    $self->audit( "  multilog logging." );
    return "\\\n\t2>&1 ";
}

sub supervised_log_rotate {
    my $self  = shift;
    my $prot = shift or croak "missing prot!";

    return $self->error( "root privs are needed to rotate logs.",fatal=>0)
        if $UID != 0;

    my $dir = $self->supervise_dir_get( $prot ) or return;

    return $self->error( "the supervise directory '$dir' is missing", fatal=>0)
        if ! -d $dir;

    return $self->error( "the supervise run file '$dir/run' is missing", fatal=>0)
        if ! -f "$dir/run";

    $self->audit( "sending ALRM signal to $prot at $dir");
    my $svc = $self->util->find_bin('svc',verbose=>0,fatal=>0) or return;
    system "$svc -a $dir";

    return 1;
};

sub supervise_restart {
    my $self = shift;
    my $dir  = shift or die "missing dir\n";

    return $self->error( "supervise_restart: is not a dir: $dir" ) if !-d $dir;

    my $svc  = $self->util->find_bin( 'svc',  verbose=>0, fatal=>0 );
    my $svok = $self->util->find_bin( 'svok', verbose=>0, fatal=>0 );

    return $self->error( "svc not found, is daemontools installed?")
        if ! -x $svc;

    if ( $svok ) {
        system "$svok $dir" and
            return $self->error( "sorry, $dir isn't supervised!" );
    };

    # send the service a TERM signal
    $self->audit( "sending TERM signal to $dir" );
    system "$svc -t $dir";
    return 1;
}

sub supervised_tcpserver {
    my $self = shift;
    my $prot = shift or croak "missing prot!";

    # get max memory, default 4MB if unset
    my $mem = $self->conf->{ $prot . '_max_memory_per_connection' };
    $mem = $mem ? $mem * 1024000 : 4000000;
    $self->audit( "memory limited to $mem bytes" );

    my $softlimit = $self->util->find_bin( 'softlimit', verbose => 0);
    my $tcpserver = $self->util->find_bin( 'tcpserver', verbose => 0);

    my $exec = "exec\t$softlimit -m $mem \\\n\t$tcpserver ";
    $exec .= $self->supervised_tcpserver_mysql( $prot, $tcpserver );
    $exec .= "-H " if $self->conf->{ $prot . '_lookup_tcpremotehost' } == 0;
    $exec .= "-R " if $self->conf->{ $prot . '_lookup_tcpremoteinfo' } == 0;
    $exec .= "-p " if $self->conf->{ $prot . '_dns_paranoia' } == 1;
    $exec .= "-v " if $self->conf->{ $prot . '_verbose' };

    my $maxcon = $self->conf->{ $prot . '_max_connections' } || 40;
    my $maxmem = $self->conf->{ $prot . '_max_memory' };

    if ( $maxmem ) {
        if ( ( $mem / 1024000 ) * $maxcon > $maxmem ) {
            require POSIX;
            $maxcon = POSIX::floor( $maxmem / ( $mem / 1024000 ) );
            $self->qmail->_memory_explanation( $prot, $maxcon );
        }
    }
    $exec .= "-c$maxcon " if $maxcon != 40;
    $exec .= "-t$self->conf->{$prot.'_dns_lookup_timeout'} "
      if $self->conf->{ $prot . '_dns_lookup_timeout' } != 26;

    $exec .= $self->supervised_tcpserver_cdb( $prot );

    if ( $prot =~ /^smtpd|submit$/ ) {

        my $uid = getpwnam( $self->conf->{ $prot . '_run_as_user' } );
        my $gid = getgrnam( $self->conf->{ $prot . '_run_as_group' } );

        unless ( $uid && $gid ) {
            print
"uid or gid is not set!\n Check toaster_watcher.conf and make sure ${prot}_run_as_user and ${prot}_run_as_group are set to valid usernames\n";
            return 0;
        }
        $exec .= "\\\n\t-u $uid -g $gid ";
    }

    # default to 0 (all) if not selected
    my $address = $self->conf->{ $prot . '_listen_on_address' } || 0;
    $exec .= $address eq "all" ? "0 " : "$address ";
    $self->audit( "  listening on ip $address.");

    my $port = $self->conf->{ $prot . '_listen_on_port' };
       $port ||= $prot eq "smtpd"      ? "smtp"
               : $prot eq "submission" ? "submission"
               : $prot eq "pop3"       ? "pop3"
               : die "can't figure out what port $port should listen on!\n";
    $exec .= "$port ";
    $self->audit( "listening on port $port.");

    return $exec;
}

sub supervised_tcpserver_mysql {
    my $self = shift;
    my ($prot, $tcpserver ) = @_;

    return '' if ! $self->conf->{ $prot . '_use_mysql_relay_table' };

    # is tcpserver mysql patch installed
    my $strings = $self->util->find_bin( 'strings', verbose=>0);

    if ( grep /sql/, `$strings $tcpserver` ) {
        $self->audit( "using MySQL based relay table" );
        return "-S ";
    }

    $self->error( "The mysql relay table option is selected but the MySQL patch for ucspi-tcp (tcpserver) is not installed! Please re-install ucspi-tcp with the patch (toaster_setup.pl -s ucspi) or disable ${prot}_use_mysql_relay_table.", fatal => 0);
    return '';
};

sub supervised_tcpserver_cdb {
    my ($self, $prot) = @_;

    my $cdb = $self->conf->{ $prot . '_relay_database' };
    return '' if ! $cdb;

    my $vdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    $self->audit( "relay db set to $cdb");

    if ( $cdb =~ /^vpopmail_home_dir\/(.*)$/ ) {
        $cdb = "$vdir/$1";
        $self->audit( "  expanded to $cdb" );
    }

    if ( ! -e $cdb ) {
        $self->setup->tcp_smtp( etc_dir => "$vdir/etc" );
        $self->setup->tcp_smtp_cdb( etc_dir => "$vdir/etc" );
    };

    $self->error( "$cdb selected but not readable" ) if ! -r $cdb;
    return "\\\n\t-x $cdb ";
};

1;
__END__
sub {}

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
        $toaster->maildir_clean_trash( $maildir );
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


=item get_toaster_cgibin

Determine the location of the cgi-bin directory used for email applications.


=item get_toaster_logs

Determine where log files are stored.


=item get_toaster_htdocs

Determine the location of the htdocs directory used for email applications.


=item maildir_clean_spam

  ########### maildir_clean_spam #############
  # Usage      : $toaster->maildir_clean_spam( '/domains/example.com/user' );
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
  # Usage      : $toaster->maildir_clean_trash( '/domains/example.com/user' );
  # Purpose    : expire old messages in Trash folders
  # Returns    : 0 - failure, 1 - success
  # Results    : a Trash folder with messages older than X days pruned
  # Parameters : path - path to a maildir
  # Throws     : no exceptions

Comments: Removes messages in .Trash folders that exceed the number of days defined in toaster-watcher.conf.


=item maildir_clean_sent

  ############################################
  # Usage      : $toaster->maildir_clean_sent( '/domains/example.com/user' );
  # Purpose    : expire old messages in Sent folders
  # Returns    : 0 - failure, 1 - success
  # Results    : messages over X days in Sent folders are deleted
  # Parameters : path - path to a maildir
  # Throws     : no exceptions


=item maildir_clean_new


  ############ maildir_clean_new #############
  # Usage      : $toaster->maildir_clean_new( '/domains/example.com/user' );
  # Purpose    : expire unread messages older than X days
  # Returns    : 0 - failure, 1 - success
  # Parameters : path - path to a maildir
  # Throws     : no exceptions

  This should be set to a large value, such as 180 or 365. Odds are, if a user hasn't read their messages in that amount of time, they never will so we should clean them out.


=item maildir_clean_ham


  ############################################
  # Usage      : $toaster->maildir_clean_ham( '/domains/example.com/user' );
  # Purpose    : prune read email messages
  # Returns    : 0 - failure, 1 - success
  # Results    : an INBOX minus read messages older than X days
  # Parameters : path - path to a maildir
  # Throws     : no exceptions


=item service_dir_create

Create the supervised services directory (if it doesn't exist).

	$toaster->service_dir_create;

Also sets the permissions to 775.


=item service_dir_get

This is necessary because things such as service directories are now in /var/service by default but older versions of my toaster installed them in /service. This will detect and adjust for that.


 Example
   $toaster->service_dir_get( 'smtp' );


 arguments required:
   prot is one of these protocols: smtp, pop3, submit, send

 arguments optional:
   verbose
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

  my $dir = $toaster->supervise_dir_get( "smtp" );

This sub just sets the supervise directory used by the various qmail
services (qmail-smtpd, qmail-send, qmail-pop3d, qmail-submit). It sets
the values according to your preferences in toaster-watcher.conf. If
any settings are missing from the config, it chooses reasonable defaults.

This is used primarily to allow you to set your mail system up in ways
that are a different than mine, like a LWQ install.


=item supervise_dirs_create

Creates the qmail supervise directories.

	$toaster->supervise_dirs_create(verbose=>$verbose);

The default directories created are:

  $supervise/smtp
  $supervise/submit
  $supervise/send
  $supervise/pop3

unless otherwise specified in $self->conf


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
    verbose


=item supervise_restart

Restarts a supervised process.


=item check_running_processes

Tests to see if all the processes on your Mail::Toaster that should be running in fact are.

 usage:
    $toaster->check_running_processes;

 arguments optional:
    verbose



=back

=head1 SEE ALSO

The following man (perldoc) pages:

  Mail::Toaster
  Mail::Toaster::Conf
  toaster.conf
  toaster-watcher.conf

  http://www.mail-toaster.org/


=head1 DIAGNOSTICS

Since the functions in the module are primarily called by toaster-watcher.pl, they are designed to do their work with a minimum amount of feedback, complaining only when a problem is encountered. Whether or not they produce status messages and verbose errors is governed by the "verbose" argument which is passed to each sub/function.

Status messages and verbose logging is enabled by default. toaster-watcher.pl and most of the automated tests (see t/toaster-watcher.t and t/Toaster.t) explicitely turns this off by setting verbose=>0.


=head1 CONFIGURATION AND ENVIRONMENT

The primary means of configuration for Mail::Toaster is via toaster-watcher.conf. It is typically installed in /usr/local/etc, but may also be found in /opt/local/etc, or simply /etc. Documentation for the man settings in toaster-watcher.conf can be found in the man page (perldoc toaster-watcher.conf).


=head1 DEPENDENCIES

    Params::Validate - must be installed seperately
    POSIX (floor only - included with Perl)
    Mail::Toaster::Utility


=head1 BUGS AND LIMITATIONS

Report to author or submit patches on GitHub.

=head1 AUTHOR

Matt Simerson (matt@tnpi.net)


=head1 COPYRIGHT AND LICENCE

Copyright (c) 2004-2013, The Network People, Inc. C<< <matt@tnpi.net> >>. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
