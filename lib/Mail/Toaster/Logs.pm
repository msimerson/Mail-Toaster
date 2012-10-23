package Mail::Toaster::Logs;

use strict;
use warnings;

our $VERSION = '5.35';

# the output of warnings and diagnostics should not be enabled in production.
# the SNMP daemon depends on the output of maillogs, so we need to return
# nothing or valid counters.

use Carp;
use English qw( -no_match_vars );
use File::Path;
use Getopt::Std;
use Params::Validate qw( :all);
use Pod::Usage;

use vars qw( $spam_ref $count_ref );

use lib 'lib';
use Mail::Toaster 5.35;
my ( $log, $util, $conf, %std_opts );

sub new {
    my $class = shift;
    my %p = validate(@_, {
            'conf'  => HASHREF,
            toaster => OBJECT,
            test_ok => { type => BOOLEAN, optional => 1 },
            fatal   => { type => BOOLEAN, optional => 1, default => 1 },
            debug   => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my $toaster = $p{toaster};
    $log = $util = $toaster->get_util();
    my $debug = $toaster->get_debug;
    $conf = $p{conf};
    $debug = $conf->{'logs_debug'} if defined $conf->{'logs_debug'};

    my $self = {
        conf  => $conf,
        debug => $debug,
        util  => $util,
    };
    bless( $self, $class );

    %std_opts = (
        'test_ok' => { type => BOOLEAN, optional => 1 },
        'fatal'   => { type => BOOLEAN, optional => 1, default => $p{fatal} },
        'debug'   => { type => BOOLEAN, optional => 1, default => $debug },
        'quiet'   => { type => BOOLEAN, optional => 1, default => 0 },
    );

    return $self;
}

sub report_yesterdays_activity {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate(@_, { %std_opts } );

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $email   = $conf->{'toaster_admin_email'} || "postmaster";
    my $qma_dir = $self->find_qmailanalog() or return;

#    if ( ! -s $self->get_yesterdays_smtp_log() ) {
#        carp "no smtp log file for yesterday found!\n";
#        return;
#    };

    my $send_log = $self->get_yesterdays_send_log();
    if ( ! -s $send_log ) {
        carp "no send log file for yesterday found!\n";
        return;
    };

    $log->audit( "processing log: $send_log" );

    my $cat = $send_log =~ m/\.bz2$/ ? $util->find_bin( "bzcat" )
            : $send_log =~ m/\.gz$/  ? $util->find_bin( "gzcat" )
            : $util->find_bin( "cat" );

    my %cmds = (
        overall  => { cmd => "$qma_dir/zoverall"   },
        failure  => { cmd => "$qma_dir/zfailures"  },
        deferral => { cmd => "$qma_dir/zdeferrals" },
    );

    foreach ( keys %cmds ) {
        my $cmd = "$cat $send_log | $qma_dir/matchup 5>/dev/null | " . $cmds{$_}->{'cmd'};
        $log->audit( "calculating $_ stats with: $cmd");
        $cmds{$_}{'out'} = `$cmd`;
    };

    my ( $dd, $mm, $yy ) = $util->get_the_date(bump=>0);
    my $date = "$yy.$mm.$dd";
    $log->audit( "date: $yy.$mm.$dd" );

    ## no critic
    open my $EMAIL, "| /var/qmail/bin/qmail-inject";
    ## use critic
    print $EMAIL <<"EO_EMAIL";
To: $email
From: postmaster
Subject: Daily Mail Toaster Report for $date

 ====================================================================
               OVERALL MESSAGE DELIVERY STATISTICS                 
 ____________________________________________________________________
\n$cmds{'overall'}{out}\n\n
 ====================================================================
                        MESSAGE FAILURE REPORT                       
 ____________________________________________________________________
$cmds{'failure'}{out}\n\n
 ====================================================================
                      MESSAGE DEFERRAL REPORT                       
 ____________________________________________________________________
$cmds{'deferral'}{out}
EO_EMAIL

    close $EMAIL;

    return 0; # return 0 on success, because periodic expects that
}

sub find_qmailanalog {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my $qmailanalog_dir = $conf->{'qmailanalog_bin'} || "/var/qmail/qmailanalog/bin";

    # the port location changed, if toaster.conf hasn't been updated, this
    # will catch it.
    if ( ! -d $qmailanalog_dir ) {
        carp <<"EO_QMADIR_MISSING";
  ERROR: the location of qmailanalog programs is missing! Make sure you have
  qmailanalog installed and the path to the binaries is set correctly in
  toaster.conf. The current setting is $qmailanalog_dir
EO_QMADIR_MISSING


        if ( -d "/usr/local/qmailanalog/bin" ) {
            $qmailanalog_dir = "/usr/local/qmailanalog/bin";

            carp <<"EO_QMADIR_FOUND";

  YAY!  I found your qmailanalog programs in /usr/local/qmailanalog/bin. You
  should update toaster.conf so you stop getting this error message.
EO_QMADIR_FOUND
        };
    };

    # make sure that the matchup program is in there
    unless ( -x "$qmailanalog_dir/matchup" ) {
        carp <<"EO_NO_MATCHUP";

   report_yesterdays_activity: ERROR! The 'maillogs yesterday' feature only
   works if qmailanalog is installed. I am unable to find the binaries for
   it. Please make sure it is installed and the qmailanalog_bin setting in
   toaster.conf is configured correctly.
EO_NO_MATCHUP

        return;
    }

    return $qmailanalog_dir;
};

sub get_yesterdays_send_log {
    my $self  = shift;
    my $debug = $self->{'debug'};

    if ( $conf->{'send_log_method'} && $conf->{'send_log_method'} eq "syslog" ) {
        return $self->get_yesterdays_send_log_syslog();
    };

    # some form of multilog logging
    my $logbase = $conf->{'logs_base'}
                || $conf->{'qmail_log_base'}
                || "/var/log/mail";

    my ( $dd, $mm, $yy ) = $util->get_the_date(bump=>0);

    # where todays logs are being archived
    my $today = "$logbase/$yy/$mm/$dd/sendlog";
    $log->audit( "updating todays symlink for sendlogs to $today");
    unlink "$logbase/sendlog" if -l "$logbase/sendlog";
    symlink( $today, "$logbase/sendlog" );

    # where yesterdays logs are being archived
    ( $dd, $mm, $yy ) = $util->get_the_date(bump=>1);
    my $yester = "$logbase/$yy/$mm/$dd/sendlog.gz";
    $log->audit( "updating yesterdays symlink for sendlogs to $yester" );
    unlink "$logbase/sendlog.gz" if -l "$logbase/sendlog.gz";
    symlink( $yester, "$logbase/sendlog.gz" );

    return $yester;
};

sub get_yesterdays_send_log_syslog {
    my $self = shift;

    # freebsd's maillog is rotated daily
    if ( $OSNAME eq "freebsd" ) {
        my $file = "/var/log/maillog.0";

        return -e "$file.bz2" ? "$file.bz2"
            : -e "$file.gz" ? "$file.gz"
            : croak "could not find yesterdays qmail-send logs! ";
    }

    if ( $OSNAME eq "darwin" ) {
        return "/var/log/mail.log"; # logs are rotated weekly.
    }

    my $file = "/var/log/mail.log.0";

    return -e "$file.gz" ? "$file.gz"
         : -e "$file.bz2" ? "$file.bz2"
         : croak "could not find your mail logs from yesterday!\n";
};

sub get_yesterdays_smtp_log {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my $logbase = $conf->{'logs_base'}   # some form of multilog logging
        || $conf->{'qmail_log_base'}
        || "/var/log/mail";

    # set up our date variables for today
    my ( $dd, $mm, $yy ) = $util->get_the_date(bump=>0);

    # where todays logs are being archived
    my $today = "$logbase/$yy/$mm/$dd/smtplog";
    $log->audit( "updating todays symlink for smtplogs to $today" );
    unlink("$logbase/smtplog") if -l "$logbase/smtplog";
    symlink( $today, "$logbase/smtplog" );

    ( $dd, $mm, $yy ) = $util->get_the_date(bump=>1);

    # where yesterdays logs are being archived
    my $yester = "$logbase/$yy/$mm/$dd/smtplog.gz";
    $log->audit( "updating yesterdays symlink for smtplogs" );
    unlink("$logbase/smtplog.gz") if -l "$logbase/smtplog.gz";
    symlink( $yester, "$logbase/smtplog.gz" );

    return $yester;
};

sub verify_settings {
    my $self = shift;
    my %p = validate(@_, { %std_opts } );
    return $p{'test_ok'} if defined $p{'test_ok'};

    my $logbase  = $conf->{'logs_base'} || $conf->{'qmail_log_base'} || '/var/log/mail';
    my $counters = $conf->{'logs_counters'} || "counters";

    my $user  = $conf->{'logs_user'}  || 'qmaill';
    my $group = $conf->{'logs_group'} || 'qnofiles';

    if ( !-e $logbase ) {
        mkpath( $logbase, 0, oct('0755') )
            or return $log->error( "Couldn't create $logbase: $!", %p );
        $util->chown($logbase, uid=>$user, gid=>$group) or return;
    };

    if ( -w $logbase ) {
        $util->chown($logbase, uid=>$user, gid=>$group) or return;
    }

    my $dir = "$logbase/$counters";

    if ( ! -e $dir ) {
        eval { mkpath( $dir, 0, oct('0755') ); };
        return $log->error( "Couldn't create $dir: $!",fatal=>0) if $EVAL_ERROR;
        $util->chown($dir, uid=>$user, gid=>$group) or return;
    }
    $log->error( "$dir is not a directory!",fatal=>0) if ! -d $dir;

    my $script = "/usr/local/bin/maillogs";
       $script = '/usr/local/sbin/maillogs' if ! -x $script;

    return $log->error( "$script must be installed!",fatal=>0) if ! -e $script;
    return $log->error( "$script must be executable!",fatal=>0) if ! -x $script;
    return 1;
}

sub parse_cmdline_flags {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate(@_, {
        'prot' => { type=>SCALAR|UNDEF, optional=>1, },
        %std_opts,
    } );

    my $prot  = $p{'prot'} or pod2usage;
       $debug = $p{'debug'};

    my @prots = qw/ smtp send imap pop3 rbl yesterday qmailscanner
                    spamassassin webmail test /;
    my %valid_prots = map { $_ => 1 } @prots;

    pod2usage if !$valid_prots{$prot};

    return 1 if $prot eq "test";

    $log->audit( "parse_cmdline_flags: prot is $prot" );

    return $self->smtp_auth_count() if $prot eq "smtp";
    return $self->rbl_count  ()     if $prot eq "rbl";
    return $self->send_count ()     if $prot eq "send";
    return $self->pop3_count ()     if $prot eq "pop3";
    return $self->imap_count ()     if $prot eq "imap";
    return $self->spama_count()     if $prot eq "spamassassin";
    return $self->qms_count()       if $prot eq "qmailscanner";
    return $self->webmail_count()   if $prot eq "webmail";
    return $self->report_yesterdays_activity() if $prot eq "yesterday";
    pod2usage();
}

sub what_am_i {
    my $self  = shift;
    my $debug = $self->{'debug'};

    $log->audit( "what_am_i: $0");
    $0 =~ /([a-zA-Z0-9\.]*)$/;
    $log->audit( "  returning $1" );
    return $1;
}

sub rbl_count {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my $countfile = $self->set_countfile(prot=>"rbl");
    $spam_ref     = $self->counter_read( file=>$countfile );
    my $logbase   = $conf->{'logs_base'} || "/var/log/mail";

    $self->process_rbl_logs(
        files => $self->check_log_files( "$logbase/smtp/current" ),
    );

    print "      Spam Counts\n\n" if $debug;

    my $i = 0;
    while ( my ($description,$count) =  each %$spam_ref ) {
        print ":" if $i > 0;
        print "$description:$count";
        $i++;
    }
    print "\n" if $i > 0;
    return 1;
}

sub smtp_auth_count {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my $countfile = $self->set_countfile(prot=>"smtp");
    my $count_ref = $self->counter_read( file=>$countfile );

    print "      SMTP Counts\n\n" if $debug;

    my $logfiles = $self->check_log_files( $self->syslog_locate() );
    if ( $logfiles->[0] eq "" ) {
        carp "\nsmtp_auth_count: Ack, no logfiles! You may want to see why?";
        return 1;
    }

    my ($lines, %new_entries);

    # we could have one log file, or dozens (multilog)
    # go through each, adding their entries to the new_entries hash.
    foreach (@$logfiles) {
        open my $LOGF, "<", $_;

        while ( my $log_line = <$LOGF> ) {
            next unless ( $log_line =~ /vchkpw-(smtp|submission)/ );

            $lines++;
            $new_entries{'connect'}++;
            $new_entries{'success'}++ if ( $log_line =~ /success/i );
        }
    }

    if ( $new_entries{'success'} ) {

        # because rrdtool expects ever increasing counters (ie, not starting new
        # each day), we keep track of when the counts suddenly reset (ie, after a
        # syslog gets rotated). To reliably know when this happens, we save the
        # last counter in a _last count. If the new count is greater the last
        # count, add the difference, which is how many authentications
        # happened since we last checked.

        if ( $new_entries{'success'} >= $count_ref->{'success_last'} ) {
            $count_ref->{'success'} +=
            ( $new_entries{'success'} - $count_ref->{'success_last'} );
        }
        else { 
            # If the counters are lower, then the logs were just rolled and we 
            # need only to add them to the new count. 
            $count_ref->{'success'} += $new_entries{'success'};
        };

        $count_ref->{'success_last'} = $new_entries{'success'};
    }

    if ( $new_entries{'connect'} ) {
        if ( $new_entries{'connect'} >= $count_ref->{'connect_last'} ) {
            $count_ref->{'connect'} += 
                ( $new_entries{'connect'} - $count_ref->{'connect_last'} );
        }
        else { 
            $count_ref->{'connect'} += $new_entries{'connect'} 
        };

        $count_ref->{'connect_last'} = $new_entries{'connect'};
    };

    foreach ( qw/ connect success / ) {
        $count_ref->{$_} = 0 if ! defined $count_ref->{$_};
    };

    print "smtp_auth_connect:$count_ref->{'connect'}:"
         ."smtp_auth_success:$count_ref->{'success'}\n";

    return $self->counter_write( log=>$countfile, values=>$count_ref, fatal=>0, debug=>$debug );
}

sub send_count {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my $logbase   = $conf->{'logs_base'} || "/var/log/mail";
    my $countfile = $self->set_countfile(prot=>"send");
       $count_ref = $self->counter_read( file=>$countfile );

    print "processing send logs\n" if $debug;

    $self->process_send_logs(
        roll  => 0,
        files => $self->check_log_files( "$logbase/send/current" ),
    );

    if ( $count_ref->{'status_remotep'} && $count_ref->{'status'} ) {
        $count_ref->{'concurrencyremote'} =
          ( $count_ref->{'status_remotep'} / $count_ref->{'status'} ) * 100;
    }

    print "      Counts\n\n" if $debug;

    my $i = 0;
    while ( my ($description, $count) = each %$count_ref ) {
        print ":" if ( $i > 0 );
        print "$description:$count";
        $i++;
    }
    print "\n";
    return 1;
}

sub imap_count {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my ( $imap_success, $imap_connect, $imap_ssl_success, $imap_ssl_connect );

    my $countfile = $self->set_countfile(prot=>"imap");
       $count_ref = $self->counter_read( file=>$countfile );

    my $logfiles  = $self->check_log_files( $self->syslog_locate() );
    if ( @$logfiles[0] eq "" ) {
        carp "\n   imap_count ERROR: no logfiles!";
        return;
    }

    my $lines;
    foreach (@$logfiles) {
        open my $LOGF, "<", $_;

        while ( my $line = <$LOGF> ) {
            next if $line !~ /imap/;

            $lines++;

            if ( $line =~ /imap-login/ ) {   # dovecot
                if ( $line =~ /secured/ ) { $imap_ssl_success++; } 
                else {                      $imap_success++;     };
                next;
            };

            if ( $line =~ /ssl: LOGIN/ ) {   # courier
                $imap_ssl_success++;
                next;
            }

            if ( $line =~ /LOGIN/ ) {       # courier
                $imap_success++; 
                next;
            }
            
            # elsif ( $line =~ /ssl: Connection/     ) { $imap_ssl_connect++; }
            # elsif ( $line =~ /Connection/          ) { $imap_connect++; }
        }
        close $LOGF;
    }

    unless ( $lines ) {
        $count_ref->{'imap_success'} ||= 0;   # hush those "uninitialized value" errors
        $count_ref->{'imap_ssl_success'} ||= 0;

        print "imap_success:$count_ref->{'imap_success'}"
            . ":imap_ssl_success:$count_ref->{'imap_ssl_success'}\n";
        carp "imap_count: no log entries to process. I'm done!" if $debug;
        return 1;
    };

    if ( $imap_success ) {
        if ( $imap_success >= $count_ref->{'imap_success_last'} ) {
            $count_ref->{'imap_success'} 
                += ( $imap_success - $count_ref->{'imap_success_last'} );
        }
        else { 
            $count_ref->{'imap_success'} += $imap_success;
        }

        $count_ref->{'imap_success_last'}     = $imap_success;
    };

    if ( $imap_ssl_success ) {
        if ( $imap_ssl_success >= $count_ref->{'imap_ssl_success_last'} ) {
            $count_ref->{'imap_ssl_success'} += 
            ( $imap_ssl_success - $count_ref->{'imap_ssl_success_last'} );
        }
        else {
            $count_ref->{'imap_ssl_success'} += $imap_ssl_success;
        }

        $count_ref->{'imap_ssl_success_last'} = $imap_ssl_success;
    };

#    Courier no longer logs this information
#    if ( $imap_connect >= $count_ref->{'imap_connect_last'} ) {
#        $count_ref->{'imap_connect'} += 
#          ( $imap_connect - $count_ref->{'imap_connect_last'} );
#    }
#    else { $count_ref->{'imap_connect'} += $imap_connect }
#
#    if ( $imap_ssl_connect >= $count_ref->{'imap_ssl_connect_last'} ) {
#        $count_ref->{'imap_ssl_connect'} += 
#          ( $imap_ssl_connect - $count_ref->{'imap_ssl_connect_last'} );
#    }
#    else {
#        $count_ref->{'imap_ssl_connect'} += $imap_ssl_connect;
#    }
#
#    $count_ref->{'imap_connect_last'}     = $imap_connect;
#    $count_ref->{'imap_ssl_connect_last'} = $imap_ssl_connect;
#
#    print "connect_imap:$count_ref->{'imap_connect'}:connect_imap_ssl" 
#        . ":$count_ref->{'imap_ssl_connect'}:"

    print "imap_success:$count_ref->{'imap_success'}"
        . ":imap_ssl_success:$count_ref->{'imap_ssl_success'}\n";

    return $self->counter_write( log=>$countfile, values=>$count_ref, fatal=>0 );
}

sub pop3_count {
    my $self  = shift;
    my $debug = $self->{'debug'};

    # read our counters from disk
    my $countfile = $self->set_countfile(prot=>"pop3");

    print "pop3_count: reading counters from $countfile.\n" if $debug;
       $count_ref = $self->counter_read( file=>$countfile );

    # get the location of log files to process
    print "finding the log files to process.\n" if $debug;
    my $logfiles  = $self->check_log_files( $self->syslog_locate() );
    if ( $logfiles->[0] eq "" ) {
        carp "    pop3_count: ERROR: no logfiles to process!";
        return;
    }

    print "pop3_count: processing files @$logfiles.\n" if $debug;

    my $lines;
    my %new_entries = ( 
        'connect'     => 0,
        'success'     => 0,
        'ssl_connect' => 0,
        'ssl_success' => 0,
    );

    my %valid_counters = (
        'pop3_success'          => 1,    # successful authentication
        'pop3_success_last'     => 1,    # last success count
        'pop3_connect'          => 1,    # total connections
        'pop3_connect_last'     => 1,    # last total connections
        'pop3_ssl_success'      => 1,    # ssl successful auth
        'pop3_ssl_success_last' => 1,    # last ssl success auths
        'pop3_ssl_connect'      => 1,    # ssl connections
        'pop3_ssl_connect_last' => 1,    # last ssl connects
    );

    foreach my $key ( keys %valid_counters ) {
        if ( ! defined $count_ref->{$key} ) {
             carp "pop3_count: missing key $key in count_ref!" if $debug;
             $count_ref->{$key} = 0;
        };
    };

    print "processing...\n" if $debug;
    foreach (@$logfiles) {
        open my $LOGF, "<", $_;

        LINE:
        while ( my $line = <$LOGF> ) {
            next unless ( $line =~ /pop3/ );   # discard everything not pop3
            $lines++;

            if ( $line =~ /vchkpw-pop3:/ ) {    # qmail-pop3d
                $new_entries{'connect'}++;
                $new_entries{'success'}++ if ( $line =~ /success/ );
            }
            elsif ( $line =~ /pop3d: / ) {      # courier pop3d
                $new_entries{'connect'}++ if ( $line =~ /Connection/ );
                $new_entries{'success'}++ if ( $line =~ /LOGIN/ );
            }
            elsif ( $line =~ /pop3d-ssl: / ) {    # courier pop3d-ssl
                if ( $line =~ /LOGIN/ ) {
                    $new_entries{'ssl_success'}++;
                    next LINE;
                };
                $new_entries{'ssl_connect'}++ if ( $line =~ /Connection/ );
            }
            elsif ( $line =~ /pop3-login: / ) {    # dovecot pop3
                if ( $line =~ /secured/ ) {
                    $new_entries{'ssl_success'}++;
                } else {
                    $new_entries{'success'}++;
                }
            }
        }
        close $LOGF;
    }

    if ( ! $lines ) {
        pop3_report();
        carp "pop3_count: no log entries, I'm done!" if $debug;
        return 1;
    };

    if ( $new_entries{'success'} ) {
        if ( $new_entries{'success'} >= $count_ref->{'pop3_success_last'} ) {
            $count_ref->{'pop3_success'} += 
                ( $new_entries{'success'} - $count_ref->{'pop3_success_last'} );
        }
        else { 
            $count_ref->{'pop3_success'} += $new_entries{'success'};
        }

        $count_ref->{'pop3_success_last'} = $new_entries{'success'};
    };

    if ( $new_entries{'connect'} ) {
        if ( $new_entries{'connect'} >= $count_ref->{'pop3_connect_last'} ) {
            $count_ref->{'pop3_connect'} += 
            ( $new_entries{'connect'} - $count_ref->{'pop3_connect_last'} );
        }
        else { $count_ref->{'pop3_connect'} += $new_entries{'connect'} }

        $count_ref->{'pop3_connect_last'}     = $new_entries{'connect'};
    };

    if ( $new_entries{'ssl_success'} ) {
        if ( $new_entries{'ssl_success'} >= $count_ref->{'pop3_ssl_success_last'} ) {
            $count_ref->{'pop3_ssl_success'} += 
            ( $new_entries{'ssl_success'} - $count_ref->{'pop3_ssl_success_last'} );
        }
        else {
            $count_ref->{'pop3_ssl_success'} += $new_entries{'ssl_success'};
        }

        $count_ref->{'pop3_ssl_success_last'} = $new_entries{'ssl_success'};
    };

    if ( $new_entries{'ssl_connect'} ) {
        if ( $new_entries{'ssl_connect'} >= $count_ref->{'pop3_ssl_connect_last'} ) {
            $count_ref->{'pop3_ssl_connect'} 
                += ( $new_entries{'ssl_connect'} - $count_ref->{'pop3_ssl_connect_last'} );
        }
        else {
            $count_ref->{'pop3_ssl_connect'} += $new_entries{'ssl_connect'};
        }

        $count_ref->{'pop3_ssl_connect_last'} = $new_entries{'ssl_connect'};
    };

    pop3_report();

    return $self->counter_write( log=>$countfile, values=>$count_ref, fatal=>0 );
}

sub pop3_report {

    $count_ref->{'pop3_connect'}     || 0;
    $count_ref->{'pop3_ssl_connect'} || 0;
    $count_ref->{'pop3_success'}     || 0;
    $count_ref->{'pop3_ssl_success'} || 0;

    print "pop3_connect:"     . $count_ref->{'pop3_connect'}
       . ":pop3_ssl_connect:" . $count_ref->{'pop3_ssl_connect'}
       . ":pop3_success:"     . $count_ref->{'pop3_success'}
       . ":pop3_ssl_success:" . $count_ref->{'pop3_ssl_success'}
       . "\n";
};

sub webmail_count {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my $countfile = $self->set_countfile(prot=>"web");
       $count_ref = $self->counter_read( file=>$countfile );

    my $logfiles  = $self->check_log_files( $self->syslog_locate() );
    if ( @$logfiles[0] eq "" ) {
        carp "\n    ERROR: no logfiles!";
        return 0;
    }

# sample log entries
# Feb 21 10:24:41 cadillac sqwebmaild: LOGIN, user=matt@cadillac.net, ip=[66.227.213.209]
# Feb 21 10:27:00 cadillac sqwebmaild: LOGIN FAILED, user=matt@cadillac.net, ip=[66.227.213.209]

    my %temp;

    foreach (@$logfiles) {
        open my $LOGF, "<", $_;

        while ( my $line = <$LOGF> ) {
            next if $line =~ /spamd/;    # typically half the syslog file
            next if $line =~ /pop3/;     # another 1/3 to 1/2

            if ( $line =~ /Successful webmail login/ ) { # squirrelmail w/plugin
                $temp{'success'}++;
                $temp{'connect'}++;
            }
            elsif ( $line =~ /sqwebmaild/ ) {            # sqwebmail
                $temp{'connect'}++;
                $temp{'success'}++ if ( $line !~ /FAILED/ );
            }
            elsif ( $line =~ /imapd: LOGIN/ && $line =~ /127\.0\.0\./ )
            {    # IMAP connections on loopback interface are webmail
                $temp{'success'}++;
            }
        }
        close $LOGF;
    }

    if ( !$temp{'connect'} ) {
        carp "webmail_count: No webmail logins! I'm all done." if $debug;
        return 1;
    };

    if ( $temp{'success'} ) {
        if ( $temp{'success'} >= $count_ref->{'success_last'} ) {
            $count_ref->{'success'} =
            $count_ref->{'success'} + ( $temp{'success'} - $count_ref->{'success_last'} );
        }
        else { $count_ref->{'success'} = $count_ref->{'success'} + $temp{'success'} }

        $count_ref->{'success_last'} = $temp{'success'};
    };

    if ( $temp{'connect'} ) {
        if ( $temp{'connect'} >= $count_ref->{'connect_last'} ) {
            $count_ref->{'connect'} =
            $count_ref->{'connect'} + ( $temp{'connect'} - $count_ref->{'connect_last'} );
        }
        else { $count_ref->{'connect'} = $count_ref->{'connect'} + $temp{'connect'} }

        $count_ref->{'connect_last'} = $temp{'connect'};
    };

    if ( ! $count_ref->{'connect'} ) {
        $count_ref->{'connect'} = 0;
    };

    if ( ! $count_ref->{'success'} ) {
        $count_ref->{'success'} = 0;
    };

    print "webmail_connect:$count_ref->{'connect'}"
        . ":webmail_success:$count_ref->{'success'}"
        . "\n";

    return $self->counter_write( 
        log    => $countfile, 
        values => $count_ref, 
        fatal  => 0, 
    );
}

sub spama_count {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my $countfile = $self->set_countfile(prot=>"spam");
       $count_ref = $self->counter_read( file=>$countfile );

    my $logfiles  = $self->check_log_files( $self->syslog_locate() );
    if ( @$logfiles[0] eq "" ) {
        carp "\n   spamassassin_count ERROR: no logfiles!";
        return;
    }

    my %temp = ( spam => 1, ham => 1 );

    foreach (@$logfiles) {
        open my $LOGF, "<", $_ or do {
            carp "unable to open $_: $!";
            next;
        };

        while ( my $line = <$LOGF> ) {
            next unless $line =~ /spamd/;
           	$temp{spamd_lines}++;

            if ( $line =~
/clean message \(([0-9-\.]+)\/([0-9\.]+)\) for .* in ([0-9\.]+) seconds, ([0-9]+) bytes/
              )
            {
                $temp{ham}++;
                $temp{ham_scores}  += $1;
                $temp{threshhold}  += $2;
                $temp{ham_seconds} += $3;
                $temp{ham_bytes}   += $4;
            }
            elsif ( $line =~
/identified spam \(([0-9-\.]+)\/([0-9\.]+)\) for .* in ([0-9\.]+) seconds, ([0-9]+) bytes/
              )
            {
                $temp{spam}++;
                $temp{spam_scores}  += $1;
                $temp{threshhold}   += $2;
                $temp{spam_seconds} += $3;
                $temp{spam_bytes}   += $4;
            }
            else {
                $temp{other}++;
            }
        }

        close $LOGF;
    }

    unless ( $temp{'spamd_lines'} ) {
        carp "spamassassin_count: no log file entries for spamd!" if $debug;
        return 1;
    };

    my $ham_count  = $temp{'ham'} || 0;
    my $spam_count = $temp{'spam'} || 0;

    if ( $ham_count ) {
        if ( $ham_count >= $count_ref->{'sa_ham_last'} ) {
            $count_ref->{'sa_ham'} =
            $count_ref->{'sa_ham'} + ( $ham_count - $count_ref->{'sa_ham_last'} );
        }
        else {
            $count_ref->{'sa_ham'} = $count_ref->{'sa_ham'} + $ham_count;
        }
    };

    if ( $spam_count ) {
        if ( $spam_count >= $count_ref->{'sa_spam_last'} ) {
            $count_ref->{'sa_spam'} =
            $count_ref->{'sa_spam'} + ( $spam_count - $count_ref->{'sa_spam_last'} );
        }
        else {
            $count_ref->{'sa_spam'} = $count_ref->{'sa_spam'} + $spam_count;
        }
    };

    require POSIX;    # needed for floor()
    $count_ref->{'avg_spam_score'} = (defined $temp{'spam_scores'} && $spam_count ) 
        ? POSIX::floor( $temp{'spam_scores'} / $spam_count * 100 ) : 0;

    $count_ref->{'avg_ham_score'}  = (defined $temp{'ham_scores'} && $ham_count ) 
        ? POSIX::floor( $temp{'ham_scores'} / $ham_count * 100 )   : 0;

    $count_ref->{'threshhold'}     = ( $temp{'threshhold'} && ($ham_count || $spam_count) )
        ? POSIX::floor( $temp{'threshhold'} / ( $ham_count + $spam_count ) * 100 ) : 0;

    $count_ref->{'sa_ham_last'}     = $ham_count;
    $count_ref->{'sa_spam_last'}    = $spam_count;

    $count_ref->{'sa_ham_seconds'}  = (defined $temp{'ham_seconds'} && $ham_count )
        ? POSIX::floor( $temp{'ham_seconds'} / $ham_count * 100 ) : 0;

    $count_ref->{'sa_spam_seconds'} = (defined $temp{spam_seconds} && $spam_count)
        ? POSIX::floor( $temp{spam_seconds} / $spam_count * 100 ) : 0;

    $count_ref->{'sa_ham_bytes'}  = (defined $temp{'ham_bytes'} && $ham_count ) 
        ? POSIX::floor( $temp{'ham_bytes'} / $ham_count * 100 ) : 0;

    $count_ref->{'sa_spam_bytes'} = (defined $temp{'ham_bytes'} && $spam_count ) 
        ? POSIX::floor( $temp{'spam_bytes'} / $spam_count * 100 ) : 0;

    print "sa_spam:$count_ref->{'sa_spam'}"
        . ":sa_ham:$count_ref->{'sa_ham'}"
        . ":spam_score:$count_ref->{'avg_spam_score'}"
        . ":ham_score:$count_ref->{'avg_ham_score'}"
        . ":threshhold:$count_ref->{'threshhold'}"
        . ":ham_seconds:$count_ref->{'sa_ham_seconds'}"
        . ":spam_seconds:$count_ref->{'sa_spam_seconds'}"
        . ":ham_bytes:$count_ref->{'sa_ham_bytes'}"
        . ":spam_bytes:$count_ref->{'sa_spam_bytes'}"
        . "\n";

    return $self->counter_write( log=>$countfile, values=>$count_ref, fatal=>0 );
}

sub qms_count {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my ( $qs_clean, $qs_virus, $qs_all );

    my $countfile = $self->set_countfile(prot=>"virus");
    my $count_ref = $self->counter_read( file=>$countfile );

    my $logfiles  = $self->check_log_files( $self->syslog_locate() );
    if ( ! defined @$logfiles[0] || @$logfiles[0] eq "" ) {
        carp "    qms_count: ERROR: no logfiles!";
        return 1;
    }

    my $grep = $util->find_bin("grep", debug=>0);
    my $wc   = $util->find_bin("wc", debug=>0);

    $qs_clean = `$grep " qmail-scanner" @$logfiles | $grep "Clear:" | $wc -l`;
    $qs_clean = $qs_clean * 1;
    $qs_all   = `$grep " qmail-scanner" @$logfiles | $wc -l`;
    $qs_all   = $qs_all * 1;
    $qs_virus = $qs_all - $qs_clean;

    if ( $qs_all == 0 ) {
        carp "qms_count: no log files for qmail-scanner found!" if $debug;
        return 1;
    };

    if ( $qs_clean ) {
        if ( $qs_clean >= $count_ref->{'qs_clean_last'} ) {
            $count_ref->{'qs_clean'} =
                $count_ref->{'qs_clean'} + ( $qs_clean - $count_ref->{'qs_clean_last'} );
        }
        else { $count_ref->{'qs_clean'} = $count_ref->{'qs_clean'} + $qs_clean }

        $count_ref->{'qs_clean_last'} = $qs_clean;
    };

    if ( $qs_virus ) {
        if ( $qs_virus >= $count_ref->{'qs_virus_last'} ) {
            $count_ref->{'qs_virus'} =
                $count_ref->{'qs_virus'} + ( $qs_virus - $count_ref->{'qs_virus_last'} );
        }
        else { $count_ref->{'qs_virus'} = $count_ref->{'qs_virus'} + $qs_virus }

        $count_ref->{'qs_virus_last'} = $qs_virus;
    };

    print "qs_clean:$qs_clean:qs_virii:$qs_virus\n";

    if ( !$count_ref ) {
        $count_ref = { qs_clean=>0, qs_virii=>0 };
    };

    return $self->counter_write( log=>$countfile, values=>$count_ref, fatal=>0 );
}

sub roll_send_logs {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my $logbase  = $conf->{'logs_base'} || "/var/log/mail";
    print "roll_send_logs: logging base is $logbase.\n" if $debug;

    my $countfile = $self->set_countfile(prot=>"send");
       $count_ref = $self->counter_read( file=>$countfile );

    $self->process_send_logs(
        roll  => 1,
        files => $self->check_log_files( "$logbase/send/current" ),
    );

    $self->counter_write( log=>$countfile, values=>$count_ref, fatal=>0 );
}

sub roll_rbl_logs {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my $logbase = $conf->{'logs_base'} || "/var/log/mail";

    my $countfile = $self->set_countfile(prot=>"rbl");
    unless ( -r $countfile ) {
        carp "WARNING: roll_rbl_logs could not read $countfile!: $!";
        return;
    }

    $spam_ref = $self->counter_read( file=>$countfile );

    $self->process_rbl_logs(
        roll  => 1,
        files => $self->check_log_files( "$logbase/smtp/current" ),
    );

    $self->counter_write( log=>$countfile, values=>$spam_ref, fatal=>0 );
}

sub roll_pop3_logs {
    my $self  = shift;
    my $debug = $self->{'debug'};

    #	my $countfile = "$logbase/$counters/$qpop_log";
    #	%count        = $self->counter_read( file=>$countfile );

    my $logbase = $conf->{'logs_base'} || "/var/log/mail";

    $self->process_pop3_logs(
        roll  => 1,
        files => $self->check_log_files( "$logbase/pop3/current" ),
    );

    #$self->counter_write(log=>$countfile, values=>\%count);
    $self->compress_yesterdays_logs( file=>"pop3log" );
}

sub compress_yesterdays_logs {
    my $self  = shift;

    my %p = validate( @_, { 'file' => SCALAR } );
    my $file = $p{'file'};

    my ( $dd, $mm, $yy ) = $util->get_the_date(bump=>1 );

    my $logbase = $conf->{'logs_base'} || "/var/log/mail";
    $file    = "$logbase/$yy/$mm/$dd/$file";

    return $log->audit( "  $file is already compressed") if -e "$file.gz";
    return $log->audit( "  $file does not exist.") if ! -e $file;
    return $log->error( "insufficient permissions to compress $file",fatal=>0)
        if ! $util->is_writable( "$file.gz",fatal=>0 );

    my $gzip = $util->find_bin('gzip',fatal=>0) or return;
    $util->syscmd( "$gzip $file", fatal=>0 )
        or return $log->error( "compressing the logfile $file: $!", fatal=>0);

    $log->audit("compressed $file");
    return 1;
}

sub purge_last_months_logs {
    my $self  = shift;
    my $debug = $self->{'debug'};

    if ( ! $conf->{'logs_archive_purge'} ) {
        $log->audit( "logs_archive_purge is disabled in toaster.conf, skipping.\n");
        return 1;
    };

    my ( $dd, $mm, $yy ) = $util->get_the_date(bump=>31 ) or return;

    my $logbase = $conf->{'logs_base'} || "/var/log/mail";

    unless ( $logbase && -d $logbase ) {
        carp "purge_last_months_logs: no log directory $logbase. I'm done!";
        return 1;
    };

    my $last_m_log = "$logbase/$yy/$mm";

    if ( ! -d $last_m_log ) {
        print "purge_last_months_logs: log dir $last_m_log doesn't exist. I'm done.\n" if $debug;
        return 1;
    };

    print "\nI'm about to delete $last_m_log...." if $debug;
    if ( rmtree($last_m_log) ) {
        print "done.\n\n" if $debug;
        return 1;
    };

    return;
}

sub check_log_files {
    my $self  = shift;
    my @exists;
    foreach my $file ( @_ ) {
        next if !$file || ! -e $file;
        push @exists, $file;
    };
    return \@exists;
}

sub check_log_files_2 {
  # this will be for logcheck based counters - someday
    my $self  = shift;
    my @exists;
    foreach my $file ( @_ ) { };
    return \@exists;
};

sub process_pop3_logs {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate(@_, {
            'roll'  => { type=>BOOLEAN, optional=>1, default=>0 },
            'files' => { type=>ARRAYREF, optional=>1 }
         }
    );

    my $files_ref = $p{'files'};

    my $skip_archive = 0;
       $skip_archive++ if !$files_ref || !$files_ref->[0]; # no log file(s)!

    if ( $p{'roll'} ) {

        my $PIPE_TO_CRONOLOG;
        if ( ! $skip_archive ) {
            $PIPE_TO_CRONOLOG = $self->get_cronolog_handle(file=>"pop3log")
                or $skip_archive++;
        };

        while (<STDIN>) {
            print                   $_ if $conf->{'logs_taifiles'};
            print $PIPE_TO_CRONOLOG $_ if ! $skip_archive;
        }
        close $PIPE_TO_CRONOLOG if ! $skip_archive;
        return $skip_archive;
    }

    # these logfiles are empty unless debugging is enabled
    foreach my $file ( @$files_ref ) {
        $log->audit( "  reading file $file...");

        my $MULTILOG_FILE;
        open ($MULTILOG_FILE, '<', $file ) or do {
            carp "couldn't read $file: $!";
            $skip_archive++;
            next;
        };

        while (<$MULTILOG_FILE>) {
            chomp;
            #count_pop3_line( $_ );
        }
        close $MULTILOG_FILE;
        $log->audit( "done.") if $debug;
    }

    return $skip_archive;
}

sub process_rbl_logs {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'roll'    => { type=>BOOLEAN, optional=>1, default=>0 },
            'files'   => { type=>ARRAYREF,optional=>1,  },
        },
    );

    my $files_ref = $p{'files'};

    my $skip_archive = 0;
       $skip_archive++ if ! $files_ref || !$files_ref->[0];  # no log file(s)!

    if ( $p{'roll'} ) {
        my $PIPE_TO_CRONOLOG;
        if ( ! $skip_archive ) {
            $PIPE_TO_CRONOLOG = $self->get_cronolog_handle(file=>"smtplog")
                or $skip_archive++;
        };

        while (<STDIN>) {
            $self->count_rbl_line ( $_ );
            print                   $_ if $conf->{'logs_taifiles'};
            print $PIPE_TO_CRONOLOG $_ if ! $skip_archive;
        }
        close $PIPE_TO_CRONOLOG if ! $skip_archive;
        return $skip_archive;
    }

    foreach my $file ( @$files_ref ) {
        print "process_rbl_logs: reading file $file..." if $debug;

        my $MULTILOG_FILE;
        open ($MULTILOG_FILE, "<", $file ) or do {
            carp "couldn't read $file: $!";
            $skip_archive++;
            next;
        };

        while (<$MULTILOG_FILE>) { $self->count_rbl_line( $_ ); }
        close $MULTILOG_FILE ;
        print "done.\n" if $debug;
    }

    return $skip_archive;
}

sub count_rbl_line {
    my $self = shift;
    my $line = shift or return;

    # comment out print lines
    chomp $line;

    if ( $line =~ /rblsmtpd/ ) {
        # match the most common entries earliest
          if  ( $line =~ /spamhaus/     ) { $spam_ref->{'spamhaus'}++ }
        elsif ( $line =~ /spamcop/      ) { $spam_ref->{'spamcop'}++  }
        elsif ( $line =~ /dsbl\.org/    ) { $spam_ref->{'dsbl'}++     }
        elsif ( $line =~ /services/     ) { $spam_ref->{'services'}++ }
        elsif ( $line =~ /rfc-ignorant/ ) { $spam_ref->{'ignorant'}++ }
        elsif ( $line =~ /sorbs/        ) { $spam_ref->{'sorbs'}++    }
        elsif ( $line =~ /njabl/        ) { $spam_ref->{'njabl'}++    }
        elsif ( $line =~ /ORDB/         ) { $spam_ref->{'ordb'}++     }
        elsif ( $line =~ /mail-abuse/   ) { $spam_ref->{'maps'}++     }
        elsif ( $line =~ /monkeys/      ) { $spam_ref->{'monkeys'}++  }
        elsif ( $line =~ /visi/         ) { $spam_ref->{'visi'}++     }
        else {
            #print $line;
            $spam_ref->{'other'}++;
        }
    }
    elsif ( $line =~ /CHKUSER/ ) {
           if ( $line =~ /CHKUSER acce/ ) { $spam_ref->{'ham'}++     }
        elsif ( $line =~ /CHKUSER reje/ ) { $spam_ref->{'chkuser'}++ }
        else {
            #print $line;
            $spam_ref->{'other'}++;
        }
    }
    elsif ( $line =~ /simscan/i ) {
           if ( $line =~ /clean/i    ) { $spam_ref->{'ham'}++          }
        elsif ( $line =~ /virus:/i   ) { $spam_ref->{'virus'}++        }
        elsif ( $line =~ /spam rej/i ) { $spam_ref->{'spamassassin'}++ }
        else {
            #print $line;
            $spam_ref->{'other'}++;
        };
    }
    else {
           if ( $line =~ /badhelo:/     ) { $spam_ref->{'badhelo'}++     }
        elsif ( $line =~ /badmailfrom:/ ) { $spam_ref->{'badmailfrom'}++ }
        elsif ( $line =~ /badmailto:/   ) { $spam_ref->{'badmailto'}++   }
        elsif ( $line =~ /Reverse/      ) { $spam_ref->{'dns'}++         }
        else {
            #print $line;
            $spam_ref->{'other'}++;
        };
    }

    $spam_ref->{'count'}++;
    return 1;
}

sub process_send_logs {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'roll'    => { type=>SCALAR,  optional=>1, default=>0 },
            'files'   => { type=>ARRAYREF,optional=>1,  },
        },
    );

    my $files_ref = $p{'files'};

    my $skip_archive = 0;
       $skip_archive++ if ! $files_ref || !$files_ref->[0]; # no log files

    if ( $p{'roll'} ) {

        print "process_send_logs: log rolling is enabled.\n" if $debug;

        my $PIPE_TO_CRONOLOG;
        if ( ! $skip_archive ) {
            $PIPE_TO_CRONOLOG = $self->get_cronolog_handle(file=>"sendlog")
                or $skip_archive++;
        };

        while (<STDIN>) {
            $self->count_send_line( $_ );
            print                   $_ if $conf->{'logs_taifiles'};
            print $PIPE_TO_CRONOLOG $_ if ! $skip_archive;
        }
        close $PIPE_TO_CRONOLOG if ! $skip_archive;
        return $skip_archive;
    }

    print "process_send_logs: log rolling is disabled.\n" if $debug;

    foreach my $file ( @$files_ref ) {

        print "process_send_logs: reading file $file.\n" if $debug;

        my $INFILE;
        open( $INFILE, "<", $file ) or do {
            carp "process_send_logs couldn't read $file: $!";
            $skip_archive++;
            next;
        };

        while (<$INFILE>) {
            chomp;
            $self->count_send_line( $_ );
        }
        close $INFILE;
    }

    return $skip_archive;
}

sub count_send_line {
    my $self = shift;
    my $line = shift or do {
        $count_ref->{'message_other'}++;
        return;
    };

########## $line will have a log entry in this format ########
# @40000000450c020b32315f74 new msg 71198
# @40000000450c020b32356e84 info msg 71198: bytes 3042 from <doc-committers@FreeBSD.org> qp 44209 uid 89
# @40000000450c020b357ed10c starting delivery 196548: msg 71198 to localexample.org-user@example.org
# @40000000450c020b357f463c status: local 1/10 remote 0/100
# @40000000450c020c06ac5dcc delivery 196548: success: did_0+0+1/
# @40000000450c020c06b6122c status: local 0/10 remote 0/100
# @40000000450c020c06be6ae4 end msg 71198
################################################

    chomp $line;
    #carp "$line";

    # split the line into date and activity
    my ( $tai_date, $activity ) = $line =~ /\A@([a-z0-9]*)\s(.*)\z/xms;

    unless ($activity) {
        $count_ref->{'message_other'}++;
        return;
    };

    if    ( $activity =~ /^new msg/ ) {
        # new msg 71512
        # the complete line match: /^new msg ([0-9]*)/
        $count_ref->{'message_new'}++;
    }
    elsif ( $activity =~ /^info msg / ) {
        # info msg 71766: bytes 28420 from <elfer@club-internet.fr> qp 5419 uid 89
        # a complete line match
        # /^info msg ([0-9]*): bytes ([0-9]*) from \<(.*)\> qp ([0-9]*)/

        $activity =~ /^info msg ([0-9]*): bytes ([0-9]*) from/;

        $count_ref->{'message_bytes'} += $2;
        $count_ref->{'message_info'}++;
    }
    elsif ( $activity =~ /^starting delivery/ ) {

        # starting delivery 136986: msg 71766 to remote bbarnes@example.com

        # a more complete line match
        # /^starting delivery ([0-9]*): msg ([0-9]*) to ([a-z]*) ([a-zA-Z\@\._-])$/

        $activity =~ /^starting delivery ([0-9]*): msg ([0-9]*) to ([a-z]*) /;

           if ( $3 eq "remote" ) { $count_ref->{'start_delivery_remote'}++ }
        elsif ( $3 eq "local"  ) { $count_ref->{'start_delivery_local'}++  }
        else { print "count_send_line: unknown delivery line format\n"; };

        $count_ref->{'start_delivery'}++;
    }
    elsif ( $activity =~ /^status: local/ ) {
        # status: local 0/10 remote 3/100
        $activity =~ /^status: local ([0-9]*)\/([0-9]*) remote ([0-9]*)\/([0-9]*)/;

        $count_ref->{'status_localp'}  += ( $1 / $2 );
        $count_ref->{'status_remotep'} += ( $3 / $4 );

        $count_ref->{'status'}++;
    }
    elsif ( $activity =~ /^end msg/ ) {
        # end msg 71766
        # /^end msg ([0-9]*)$/

        # this line is useless, why was it here?
        #$count_ref->{'local'}++ if ( $3 && $3 eq "local" );

        $count_ref->{'message_end'}++;
    }
    elsif ( $activity =~ /^delivery/ ) {
        # delivery 136986: success: 67.109.54.82_accepted_message./Remote_host_said:
        #   _250_2.6.0__<000c01c6c92a$97f4a580$8a46c3d4@p3>_Queued_mail_for_delivery/

        $activity =~ /^delivery ([0-9]*): ([a-z]*): /;

           if ( $2 eq "success"  ) { $count_ref->{'delivery_success'}++  }
        elsif ( $2 eq "deferral" ) { $count_ref->{'delivery_deferral'}++ }
        elsif ( $2 eq "failure"  ) { $count_ref->{'delivery_failure'}++  }
        else { print "unknown " . $activity . "\n"; };

        $count_ref->{'delivery'}++;
    }
    elsif ( $activity =~ /^bounce/ ) {
        # /^bounce msg ([0-9]*) [a-z]* ([0-9]*)/
        $count_ref->{'message_bounce'}++;
    }
    else {
        #warn "other: $activity";
        $count_ref->{'other'}++;
    }

    return 1;
}


sub counter_create {
    my $self = shift;
    my $file = shift;

    my $debug = $self->{'debug'};
    carp "\nWARN: the file $file is missing! I will try to create it." if $debug;

    if ( ! $util->is_writable( $file,debug=>0,fatal=>0) ) {
        carp "FAILED.\n $file does not exist and the user $UID has "
            . "insufficent privileges to create it!" if $debug;
        return;
    };

    $self->counter_write( log => $file, values => { created => time(), },);

    my $user = $self->{'conf'}{'logs_user'} || "qmaill";
    my $group = $self->{'conf'}{'logs_group'} || "qnofiles";

    $util->chown( $file, uid=>$user, gid=>$group, debug=>0);

    print "done.\n";
    return 1;
};

sub counter_read {
    my $self  = shift;
    my %p = validate(@_, { 'file' => SCALAR, %std_opts } );
    my %args = $log->get_std_args( %p );

    my $file  = $p{'file'} or croak "you must pass a filename!\n";
    my $debug = $p{'debug'};

    if ( ! -e $file ) {
        $self->counter_create( $file ) or return;
    }

    my %hash;

    foreach ( $util->file_read( $file, debug=>$debug ) ) {
        my ($description, $count) = split( /:/, $_ );
        $hash{ $description } = $count;
    }

    $log->audit( "counter_read: read counters from $file", %args );

    return \%hash;
}

sub counter_write {
    my $self  = shift;
    my %p = validate( @_, {
            'values' => HASHREF,
            'log'    => SCALAR,
            %std_opts,
        },
    );
    my %args = $log->get_std_args( %p );

    my ( $logfile, $values_ref ) = ( $p{'log'}, $p{'values'} );

    if ( -d $logfile ) {
        print "FAILURE: counter_write $logfile is a directory!\n";
    }

    return $log->error( "counter_write: $logfile is not writable",fatal=>0 )
        unless $util->is_writable( $logfile, %args  );

    unless ( -e $logfile ) {
        print "NOTICE: counter_write is creating $logfile";
    }

    # it might be necessary to wrap the counters
    #
    # if so, the 32 and 64 bit limits are listed below. Just
    # check the number, and subtract the maximum value for it.
    # rrdtool will continue to Do The Right Thing. :)

    my @lines;
    while ( my ($key, $value) = each %$values_ref ) {
        $log->audit( "key: $key  \t val: $value", %args);
        if ( $key && defined $value ) {
            # 32 bit - 4294967295
            # 64 bit - 18446744073709551615
            if ( $value > 4294967295 ) { $value = $value - 4294967295; };
            push @lines, "$key:$value";
        }
    }

    return $util->file_write( $logfile, lines => \@lines, %args );
}

sub get_cronolog_handle {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate(@_, { 'file' => SCALAR, },);

    my $file = $p{'file'};

    my $logbase = $conf->{'logs_base'} || "/var/log/mail";

    # archives disabled in toaster.conf
    if ( ! $conf->{'logs_archive'} ) {
        print "get_cronolog_handle: archives disabled, skipping cronolog handle.\n" if $debug;
        return;
    };

    # $logbase is missing and we haven't permission to create it
    unless ( -w $logbase ) {
        carp "WARNING: could not write to $logbase. FAILURE!";
        return;
    };

    my $cronolog = $util->find_bin( "cronolog", debug=>0, fatal=>0 );
    if ( ! $cronolog || !-x $cronolog) {
        carp "cronolog could not be found. Please install it!";
        return;
    }

    my $tai64nlocal;

    if ( $conf->{'logs_archive_untai'} ) {
        my $taibin = $util->find_bin( "tai64nlocal",debug=>0, fatal=>0 );

        if ( ! $taibin ) {
            carp "tai64nlocal is selected in toaster.conf but cannot be found!";
        };

        if ( $taibin && ! -x $taibin ) {
            carp "tai64nlocal is not executable by you! ERROR!";
        }

        $tai64nlocal = $taibin;
    }


    my $cronolog_invocation = "| ";
    $cronolog_invocation .= "$tai64nlocal | " if $tai64nlocal;
    $cronolog_invocation .= "$cronolog $logbase/\%Y/\%m/\%d/$file";

    ## no critic
    open my $PIPE_TO_CRONOLOG, $cronolog_invocation or return;
    ## use critic

    return $PIPE_TO_CRONOLOG;
};

sub syslog_locate {
    my ( $self, $debug ) = @_;

    my $log = "/var/log/maillog";

    if ( -e $log ) {
        print "syslog_locate: using $log\n" if $debug;
        return "$log";
    }

    $log = "/var/log/mail.log";
    if ( $OSNAME eq "darwin" ) {
        print "syslog_locate: Darwin detected...using $log\n" if $debug;
        return $log;
    }

    if ( -e $log ) {
        print "syslog_locate: using $log\n" if $debug;
        return $log;
    };

    $log = "/var/log/messages";
    return $log if -e $log;

    $log = "/var/log/system.log";
    return $log if -e $log;

    croak "syslog_locate: can't find your syslog mail log\n";
}

sub set_countfile {
    my $self = shift;
    my $debug = $self->{'debug'};

    my %p = validate(@_, { prot=>SCALAR }, );
    my $prot = $p{'prot'};

    print "set_countfile: countfile for prot $prot is " if $debug;

    my $logbase  = $conf->{'logs_base'} || "/var/log/mail";
    my $counters = $conf->{'logs_counters'} || "counters";
    my $prot_file = $conf->{'logs_'.$prot.'_count'} || "$prot.txt";

    print "$logbase/$counters/$prot_file\n" if $debug;

    return "$logbase/$counters/$prot_file";
}

1;
__END__


=head1 NAME

Mail::Toaster::Logs - objects and functions for interacting with email logs

This module contains functions related to mail logging and are used primarily in maillogs. Some functions are also used in toaster-watcher.pl and toaster_setup.pl.


=head1 METHODS

=over 8

=item new

Create a new Mail::Toaster::Logs object.

    use Mail::Toaster::Logs;
    $logs = Mail::Toaster::Logs->new;


=item report_yesterdays_activity

email a report of yesterdays email traffic.


=item verify_settings

Does some checks to make sure things are set up correctly.

    $logs->verify_settings();

tests:

  logs base directory exists
  logs based owned by qmaill
  counters directory exists
  maillogs is installed


=item parse_cmdline_flags

Do the appropriate things based on what argument is passed on the command line.

	$logs->parse_cmdline_flags(prot=>$prot, debug=>0);

$conf is a hashref of configuration values, assumed to be pulled from toaster-watcher.conf.

$prot is the protocol we're supposed to work on.


=item check_log_files

	$logs->check_log_files( $check );


=item compress_yesterdays_logs

	$logs->compress_yesterdays_logs(
	    file  => $file,
	);


=item count_rbl_line

    $logs->count_rbl_line($line);


=item count_send_line

 usage:
     $logs->count_send_line( $count, $line );

 arguments required:
      count - a hashref of counter values
      line  - an entry from qmail's send logs

 results:
     a hashref will be returned with updated counters


=item counter_read

	$logs->counter_read( file=>$file, debug=>$debug);

$file is the file to read from. $debug is optional, it prints out verbose messages during the process. The sub returns a hashref full of key value pairs.


=item counter_write

	$logs->counter_write(log=>$file, values=>$values);

 arguments required:
    file   - the logfile to write.
    values - a hashref of value=count style pairs.

 result:
   1 if written
   0 if not.

=cut

=item imap_count

	$logs->imap_count(conf=>$conf);

Count the number of connections and successful authentications via IMAP and IMAP-SSL.


=item pop3_count

	$logs->pop3_count(conf=>$conf);

Count the number of connections and successful authentications via POP3 and POP3-SSL.


=item process_pop3_logs


=item process_rbl_logs

    process_rbl_logs(
        roll  => 0,
        files => $self->check_log_files( "$logbase/smtp/current" ),
    );



=item process_send_logs



=item qms_count

	$logs->qms_count($conf);

Count statistics logged by qmail scanner.


=item purge_last_months_logs

	$logs->purge_last_months_logs(
        fatal   => 0,
	);

For a supplied protocol, cleans out last months email logs.


=item rbl_count

Count the number of connections we've blocked (via rblsmtpd) for each RBL that we use.

	$logs->rbl_count(conf=>$conf, $debug);

=item roll_rbl_logs

	$logs->roll_rbl_logs($conf, $debug);

Roll the qmail-smtpd logs (without 2>&1 output generated by rblsmtpd).

=item RollPOP3Logs

	$logs->RollPOP3Logs($conf);

These logs will only exist if tcpserver debugging is enabled. Rolling them is not likely to be necessary but the code is here should it ever prove necessary.


=item roll_send_logs

	$logs->roll_send_logs();

Roll the qmail-send multilog logs. Update the maillogs counter.


=item send_count

	$logs->send_count(conf=>$conf);

Count the number of messages we deliver, and a whole mess of stats from qmail-send.


=item smtp_auth_count

	$logs->smtp_auth_count(conf=>$conf);

Count the number of times users authenticate via SMTP-AUTH to our qmail-smtpd daemon.


=item spama_count

	$logs->spama_count($conf);

Count statistics logged by SpamAssassin.


=item syslog_locate

	$logs->syslog_locate($debug);

Determine where syslog.mail is logged to. Right now we just test based on the OS you're running on and assume you've left it in the default location. This is easy to expand later.

=cut

=item webmail_count

	$logs->webmail_count();

Count the number of webmail authentications.


=item what_am_i

	$logs->what_am_i()

Determine what the filename of this program is. This is used in maillogs, as maillogs gets renamed in order to function as a log post-processor for multilog.

=back

=head1 AUTHOR

Matt Simerson <matt@tnpi.net>


=head1 BUGS

None known. Report any to author.
Patches welcome.


=head1 SEE ALSO

The following are relevant man/perldoc pages:

 maillogs
 Mail::Toaster
 toaster.conf

 http://mail-toaster.org/


=head1 COPYRIGHT

Copyright (c) 2004-2008, The Network People, Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
