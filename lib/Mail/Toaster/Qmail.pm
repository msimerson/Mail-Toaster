package Mail::Toaster::Qmail;

use strict;
use warnings;

our $VERSION = '5.35';

use English qw( -no_match_vars );
use File::Copy;
use File::Path;
use Params::Validate qw( :all );
use POSIX;

use vars qw/ $conf $toaster $setup $t_dns $log $util %std_opts /;

use lib 'lib';
use Mail::Toaster;
use Mail::Toaster::DNS;
use Mail::Toaster::Setup;

sub new {
    my $class = shift;
    my %p     = validate( @_,
        {  toaster=> { type => OBJECT   },
            fatal => { type => BOOLEAN, optional => 1, default => 1 },
            debug => { type => BOOLEAN, optional => 1 },
        }
    );

    $toaster = $p{toaster};
    $conf = $toaster->get_config();
    $log = $util = $toaster->get_util();

    my $debug = $toaster->get_debug;  # inherit from our parent
    my $fatal = $toaster->get_fatal;
    $debug = $p{debug} if defined $p{debug};  # explicity overridden
    $fatal = $p{fatal} if defined $p{fatal};

    my $self = {
        'log' => $log,
        debug => $debug,
        fatal => $fatal,
    };
    bless $self, $class;

    # globally scoped hash, populated with defaults as requested by the caller
    %std_opts = (
        'test_ok' => { type => BOOLEAN, optional => 1 },
        'fatal'   => { type => BOOLEAN, optional => 1, default => $fatal },
        'debug'   => { type => BOOLEAN, optional => 1, default => $debug },
        'quiet'   => { type => BOOLEAN, optional => 1, default => 0 },
    );

    return $self;
}

sub build_pop3_run {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $toaster->get_std_args( %p );

    my $vdir       = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    my $qctrl      = $conf->{'qmail_dir'} . "/control";
    my $qsupervise = $conf->{'qmail_supervise'} || '/var/qmail/supervise';

    -d $qsupervise or
        return $log->error( "$qsupervise does not exist!",fatal=>0);

    my @lines = $toaster->supervised_do_not_edit_notice( vdir => 1 );

    if ( $conf->{'pop3_hostname'} eq 'qmail' ) {
        push @lines, $self->supervised_hostname_qmail( prot => 'pop3' );
    };

#qmail-popup mail.cadillac.net /usr/local/vpopmail/bin/vchkpw qmail-pop3d Maildir 2>&1
    my $exec = $toaster->supervised_tcpserver( prot => 'pop3' ) or return;
    my $chkpass = $self->_set_checkpasswd_bin( prot => 'pop3' ) or return;

    $exec .= "\\\n\tqmail-popup ";
    $exec .= $toaster->supervised_hostname( prot => "pop3" );
    $exec .= $chkpass;
    $exec .= "qmail-pop3d Maildir ";
    $exec .= $toaster->supervised_log_method( prot => "pop3" );

    push @lines, $exec;

    my $file = '/tmp/toaster-watcher-pop3-runfile';
    $util->file_write( $file, lines => \@lines ) or return;
    $self->install_supervise_run( tmpfile => $file, prot => 'pop3' ) or return;
    return 1;
}

sub build_send_run {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $toaster->get_std_args( %p );

    $log->audit( "generating send/run..." );

    my $qsup = $conf->{'qmail_supervise'} or
        return $log->error( "qmail_supervise not set in toaster-watcher.conf!",
            fatal => 0 );

    $util->mkdir_system( dir => $qsup ) if !-d $qsup;

    my $mailbox  = $conf->{'send_mailbox_string'} || "./Maildir/";
    my $send_log = $conf->{'send_log_method'}     || "syslog";

    my @lines = $toaster->supervised_do_not_edit_notice();

    if ( $send_log eq "syslog" ) {
        push @lines, "# use splogger to qmail-send logs to syslog\n
# make changes in /usr/local/etc/toaster-watcher.conf
exec qmail-start $mailbox splogger qmail\n";
    }
    else {
        push @lines, "# sends logs to multilog as directed in log/run
# make changes in /usr/local/etc/toaster-watcher.conf
exec qmail-start $mailbox 2>&1\n";
    }

    my $file = "/tmp/toaster-watcher-send-runfile";
    $util->file_write( $file, lines => \@lines, fatal => 0) or return;
    $self->install_supervise_run( tmpfile => $file, prot => 'send'  ) or return;
    return 1;
}

sub build_smtp_run {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $toaster->get_std_args( %p );

    $log->audit( "generating supervise/smtp/run...");

    $self->_test_smtpd_config_values() or return;

    my $mem;

    my @smtp_run_cmd = $toaster->supervised_do_not_edit_notice( vdir => 1 );
    push @smtp_run_cmd, $self->smtp_set_qmailqueue();

    # check for our control directory existence
    my $qdir  = $conf->{'qmail_dir'};
    my $qctrl = "$qdir/control";
    return $log->error( "build_smtp_run failed. $qctrl is not a directory", fatal=>0)
        unless -d $qctrl;

    return if ! -d $conf->{'qmail_supervise'};

    push @smtp_run_cmd, $self->supervised_hostname_qmail( prot => "smtpd" )
        if $conf->{'smtpd_hostname'} eq "qmail";

    push @smtp_run_cmd, $self->_smtp_sanity_tests();

    my $exec = $toaster->supervised_tcpserver( prot => "smtpd" ) or return;
    $exec .= $self->smtp_set_rbls();
    $exec .= "\\\n\trecordio " if $conf->{'smtpd_recordio'};
    $exec .= "\\\n\tfixcrio "  if $conf->{'smtpd_fixcrio'};
    $exec .= "\\\n\tqmail-smtpd ";
    $exec .= $self->smtp_auth_enable();
    $exec .= $toaster->supervised_log_method( prot => "smtpd" ) or return;

    push @smtp_run_cmd, $exec;

    my $file = '/tmp/toaster-watcher-smtpd-runfile';
    $util->file_write( $file, lines => \@smtp_run_cmd ) or return;
    $self->install_supervise_run( tmpfile => $file, prot => 'smtp' );
    return 1;
}

sub build_submit_run {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $toaster->get_std_args( %p );

    return if ! $conf->{'submit_enable'};

    $log->audit( "generating submit/run...");

    return $log->error( "SMTPd config values failed tests!", %p )
        if ! $self->_test_smtpd_config_values();

    my $vdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    my @lines = $toaster->supervised_do_not_edit_notice( vdir => 1 );

    push @lines, $self->smtp_set_qmailqueue( prot => 'submit' );

    # don't subject authed clients to HELO tests since many (Outlook, OE)
    # do not send a proper HELO. -twa, 2007-03-07
    push @lines, 'export NOBADHELO=""

';

    my $qctrl = $conf->{'qmail_dir'} . "/control";
    return $log->error( "  failed. $qctrl is not a directory", fatal=>0)
        if ! -d $qctrl;

    my $qsupervise = $conf->{'qmail_supervise'};
    return if ! -d $qsupervise;

    push @lines, $self->supervised_hostname_qmail( prot => "submit" )
        if $conf->{'submit_hostname'} eq "qmail";
    push @lines, $self->_smtp_sanity_tests();

    my $exec = $toaster->supervised_tcpserver( prot => "submit" ) or return;

    $exec .= "qmail-smtpd ";

    if ( $conf->{'submit_auth_enable'} ) {
        $exec .= $toaster->supervised_hostname( prot => "submit" )
            if ( $conf->{'submit_hostname'} && $conf->{'qmail_smtpd_auth_0.31'} );

        my $chkpass = $self->_set_checkpasswd_bin( prot => 'submit' ) or return;
        $exec .= $chkpass;
        $exec .= "/usr/bin/true ";
    }

    $exec .= $toaster->supervised_log_method( prot => "submit" ) or return;

    push @lines, $exec;

    my $file = '/tmp/toaster-watcher-submit-runfile';
    $util->file_write( $file, lines => \@lines ) or return;
    $self->install_supervise_run( tmpfile => $file, prot => 'submit' ) or return;
    return 1;
}

sub check_control {
    my $self = shift;
    my %p = validate( @_, { 'dir' => SCALAR, %std_opts } );

    # used in qqtool.pl

    my ( $dir, $fatal, $debug ) = ( $p{'dir'}, $p{'fatal'}, $p{'debug'} );

    if ( -d $dir ) {
        $log->audit( "check_control: checking $dir, ok" );
        return 1;
    }

    my $qcontrol = $toaster->service_dir_get( prot => "send" );

    $log->audit( "check_control: checking $qcontrol/$dir, FAILED" );
    if ($debug) {
        print "
	HEY! The control directory for qmail-send is not
	in $dir where I expected. Please edit this script
	and set $qcontrol to the appropriate directory!\n\n";
    }

    return;
}

sub check_rcpthosts {
    my ( $self, $qmaildir ) = @_;
    $qmaildir ||= "/var/qmail";

    if ( !-d $qmaildir ) {
        $log->audit( "check_rcpthost: oops! the qmail directory does not exist!");
        return;
    }

    my $assign = "$qmaildir/users/assign";
    my $rcpt   = "$qmaildir/control/rcpthosts";
    my $mrcpt  = "$qmaildir/control/morercpthosts";

    # make sure an assign and rcpthosts file exists.
    unless ( -s $assign && -s $rcpt ) {
        $log->audit("check_rcpthost: $assign or $rcpt is missing!");
        return;
    }

    my @domains = $self->get_domains_from_assign( assign => $assign );

    print "check_rcpthosts: checking your rcpthost files.\n.";
    my ( @f2, %rcpthosts, $domains, $count );

    # read in the contents of both rcpthosts files
    my @f1 = $util->file_read( $rcpt );
    @f2 = $util->file_read( $mrcpt )
      if ( -e "$qmaildir/control/morercpthosts" );

    # put their contents into a hash
    foreach ( @f1, @f2 ) { chomp $_; $rcpthosts{$_} = 1; }

    # and then for each domain in assign, make sure it is in rcpthosts
    foreach (@domains) {
        my $domain = $_->{'dom'};
        unless ( $rcpthosts{$domain} ) {
            print "\t$domain\n";
            $count++;
        }
        $domains++;
    }

    if ( ! $count || $count == 0 ) {
        print "Congrats, your rcpthosts is correct!\n";
        return 1;
    }

    if ( $domains > 50 ) {
        print
"\nDomains listed above should be added to $mrcpt. Don't forget to run 'qmail cdb' afterwards.\n";
    }
    else {
        print "\nDomains listed above should be added to $rcpt. \n";
    }
}

sub config {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );
    my %args = $toaster->get_std_args( %p );

    my $qdir    = $conf->{'qmail_dir'}       || "/var/qmail";
    my $tmp     = $conf->{'toaster_tmp_dir'} || "/tmp";
    my $host    = $conf->{'toaster_hostname'};
    if ( $host =~ /qmail|system/ ) { $host = `hostname`; chomp $host; };

    return $p{test_ok} if defined $p{test_ok};

    my $postmaster = $conf->{'toaster_admin_email'};
    my $ciphers    = $conf->{'openssl_ciphers'} || 'pci';

    if ( $ciphers =~ /^[a-z]+$/ ) {
        if ( ! $setup ) {
            require Mail::Toaster::Setup;
            $setup = Mail::Toaster::Setup->new(conf=>$conf, toaster => $toaster);
        };
        $ciphers = $setup->openssl_get_ciphers( $ciphers );
    };

    my @changes = (
        { file => 'control/me',                 setting => $host, },
        { file => 'control/concurrencyremote',  setting => $conf->{'qmail_concurrencyremote'},},
        { file => 'control/mfcheck',            setting => $conf->{'qmail_mfcheck_enable'},   },
        { file => 'control/tarpitcount',        setting => $conf->{'qmail_tarpit_count'},     },
        { file => 'control/tarpitdelay',        setting => $conf->{'qmail_tarpit_delay'},     },
        { file => 'control/spfbehavior',        setting => $conf->{'qmail_spf_behavior'},     },
        { file => 'alias/.qmail-postmaster',    setting => $postmaster,   },
        { file => 'alias/.qmail-root',          setting => $postmaster,   },
        { file => 'alias/.qmail-mailer-daemon', setting => $postmaster,   },
        { file => 'control/tlsserverciphers',   setting => $ciphers },
        { file => 'control/tlsclientciphers',   setting => $ciphers },
    );

    if ( $conf->{'vpopmail_mysql'} ) {
        my $dbhost = $conf->{'vpopmail_mysql_repl_slave'}
             or die "missing database server hostname\n";
        my $dbport = $conf->{'vpopmail_mysql_repl_slave_port'}
             or die "missing database server port\n";
        my $dbname = $conf->{'vpopmail_mysql_database'}
            or die "missing database name\n";
        my $dbuser = $conf->{'vpopmail_mysql_user'}
            or die "missing vpopmail SQL username\n";
        my $password = $conf->{'vpopmail_mysql_pass'}
            or die "missing vpopmail SQL pass\n";

        push @changes, { file => 'control/sql', setting =>
"server $dbhost\nport $dbport
database $dbname\ntable relay
user $dbuser\npass $password\ntime 1800\n"
        };
    };

    $self->config_write( \@changes );

    my $uid = getpwnam('vpopmail');
    my $gid = getgrnam('vchkpw');

    my $control = "$qdir/control";
    chown( $uid, $gid, "$control/servercert.pem" );
    chown( $uid, $gid, "$control/sql" );
    chmod oct('0640'), "$control/servercert.pem";
    chmod oct('0640'), "$control/clientcert.pem";
    chmod oct('0640'), "$control/sql";
    chmod oct('0644'), "$control/concurrencyremote";

    $self->config_freebsd() if $OSNAME eq "freebsd";

    # install the qmail control script (qmail cdb, qmail restart, etc)
    $self->control_create( %args );

    # create all the service and supervised dirs
    $toaster->service_dir_create( %args );
    $toaster->supervise_dirs_create( %args );

    # install the supervised control files
    $self->install_qmail_control_files( %args );
    $self->install_qmail_control_log_files( %args );
}

sub config_freebsd {
    my $self = shift;
    my $tmp  = $conf->{'toaster_tmp_dir'} || "/tmp";

    # disable sendmail
    require Mail::Toaster::FreeBSD;
    my $freebsd  = Mail::Toaster::FreeBSD->new( toaster => $toaster );

    $freebsd->conf_check(
        check => "sendmail_enable",
        line  => 'sendmail_enable="NONE"',
    );

    # don't build sendmail when we rebuild the world
    $util->file_write( "/etc/make.conf",
        lines  => ["NO_SENDMAIL=true"],
        append => 1,
    )
    if ! `grep NO_SENDMAIL /etc/make.conf`;

    # make sure mailer.conf is set up for qmail
    my $tmp_mailer_conf = "$tmp/mailer.conf";
    my $maillogs = $util->find_bin('maillogs',fatal=>0 )
        || '/usr/local/bin/maillogs';
    open my $MAILER_CONF, '>', $tmp_mailer_conf
        or $log->error( "unable to open $tmp_mailer_conf: $!",fatal=>0);

    print $MAILER_CONF '
# $FreeBSD: src/etc/mail/mailer.conf,v 1.3.36.1 2009/08/03 08:13:06 kensmith Exp $
#
sendmail        /var/qmail/bin/sendmail
send-mail       /var/qmail/bin/sendmail
mailq           ' . $maillogs . ' yesterday
#mailq          /var/qmail/bin/qmail-qread
newaliases      /var/qmail/bin/newaliases
hoststat        /var/qmail/bin/qmail-tcpto
purgestat       /var/qmail/bin/qmail-tcpok
#
# Execute the "real" sendmail program, named /usr/libexec/sendmail/sendmail
#
#sendmail        /usr/libexec/sendmail/sendmail
#send-mail       /usr/libexec/sendmail/sendmail
#mailq           /usr/libexec/sendmail/sendmail
#newaliases      /usr/libexec/sendmail/sendmail
#hoststat        /usr/libexec/sendmail/sendmail
#purgestat       /usr/libexec/sendmail/sendmail

';

    $util->install_if_changed(
        newfile  => $tmp_mailer_conf,
        existing => "/etc/mail/mailer.conf",
        notify   => 1,
        clean    => 1,
    );
    close $MAILER_CONF;
};

sub config_write {
    my $self = shift;
    my $changes = shift;

    my $qdir    = $conf->{'qmail_dir'} || "/var/qmail";
    my $control = "$qdir/control";
    $util->file_write( "$control/locals", lines => ["\n"] )
        if ! -e "$control/locals";

    foreach my $change (@$changes) {
        my $file  = $change->{'file'};
        my $value = $change->{'setting'};

        if ( -e "$qdir/$file" ) {
            my @now = $util->file_read( "$qdir/$file" );
            if ( @now && $now[0] && $now[0] eq $value ) {
                $log->audit( "config_write: $file to '$value', ok (same)" ) if $value !~ /pass/;
                next;
            };
        }
        else {
            $util->file_write( "$qdir/$file", lines => [$value] );
            $log->audit( "config: set $file to '$value'" ) if $value !~ /pass/;
            next;
        };

        $util->file_write( "$qdir/$file.tmp", lines => [$value] );

        my $r = $util->install_if_changed(
            newfile  => "$qdir/$file.tmp",
            existing => "$qdir/$file",
            clean    => 1,
            notify   => 1,
            debug    => 0
        );
        if ($r) { $r = $r == 1 ? "ok" : "ok (same)"; }
        else    { $r = "FAILED"; }

        $log->audit( "config: setting $file to '$value', $r" ) if $value !~ /pass/;
    };

    my $manpath = "/etc/manpath.config";
    if ( -e $manpath ) {
        unless (`grep "/var/qmail/man" $manpath | grep -v grep`) {
            $util->file_write( $manpath,
                lines  => ["OPTIONAL_MANPATH\t\t/var/qmail/man"],
                append => 1,
            );
            $log->audit( "appended /var/qmail/man to MANPATH" );
        }
    }
};

sub control_create {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    my ( $fatal, $debug ) = ($p{'fatal'}, $p{'debug'} );

    my $dl_site = $conf->{'toaster_dl_site'} || "http://www.tnpi.net";
    my $dl_url  = $conf->{'toaster_dl_url'}  || "/internet/mail/toaster";
    my $toaster_url = "$dl_site$dl_url";

    my $qmaildir = $conf->{'qmail_dir'}         || "/var/qmail";
    my $confdir  = $conf->{'system_config_dir'} || "/usr/local/etc";
    my $tmp      = $conf->{'toaster_tmp_dir'}   || "/tmp";
    my $prefix   = $conf->{'toaster_prefix'}    || "/usr/local";

    my $qmailctl = "$qmaildir/bin/qmailctl";

    return $p{'test_ok'} if defined $p{'test_ok'};

    # install a new qmailcontrol if newer than existing one.
    $self->control_write( "$tmp/qmailctl", %p );
    my $r = $util->install_if_changed(
        newfile  => "$tmp/qmailctl",
        existing => $qmailctl,
        mode     => '0755',
        notify   => 1,
        clean    => 1,
    );

    if ($r) {
        if ( $r == 1 ) { $r = "ok" }
        else { $r = "ok (same)" }
    }
    else { $r = "FAILED"; }
    $log->audit( "control_create: installed $qmaildir/bin/qmailctl, $r" );

    $util->syscmd( "$qmailctl cdb", debug=>0 );

    # create aliases
    foreach my $shortcut ( "$prefix/sbin/qmail", "$prefix/sbin/qmailctl" ) {
        next if -l $shortcut;
        if ( -e $shortcut ) {
            $log->audit( "updating $shortcut.");
            unlink $shortcut;
            symlink( "$qmaildir/bin/qmailctl", $shortcut )
                or $log->error( "couldn't link $shortcut: $!");
        }
        else {
            $log->audit( "control_create: adding symlink $shortcut");
            symlink( "$qmaildir/bin/qmailctl", $shortcut )
                or $log->error( "couldn't link $shortcut: $!");
        }
    }

    if ( -e "$qmaildir/rc" ) {
        $log->audit( "control_create: $qmaildir/rc already exists.");
    }
    else {
        $self->build_send_run();
        my $dir = $toaster->supervise_dir_get( prot => 'send' );
        copy( "$dir/run", "$qmaildir/rc" ) and
            $log->audit( "control_create: created $qmaildir/rc.");
        chmod oct('0755'), "$qmaildir/rc";
    }

    # the FreeBSD port used to install this
    if ( -e "$confdir/rc.d/qmail.sh" ) {
        unlink("$confdir/rc.d/qmail.sh")
          or $log->error( "couldn't delete $confdir/rc.d/qmail.sh: $!");
    }
}

sub control_write {
    my $self = shift;
    my $file = shift or die "missing file name";
    my %p = validate( @_, { %std_opts } );

    open ( my $FILE_HANDLE, '>', $file ) or
        return $log->error( "failed to open $file: $!" );

    my $qdir   = $conf->{'qmail_dir'}      || "/var/qmail";
    my $prefix = $conf->{'toaster_prefix'} || "/usr/local";
    my $tcprules = $util->find_bin( 'tcprules', %p );
    my $svc      = $util->find_bin( 'svc', %p );

    print $FILE_HANDLE <<EOQMAILCTL;
#!/bin/sh

PATH=$qdir/bin:$prefix/bin:/usr/bin:/bin
export PATH

case "\$1" in
	stat)
		cd $qdir/supervise
		svstat * */log
	;;
	doqueue|alrm|flush)
		echo "Sending ALRM signal to qmail-send."
		$svc -a $qdir/supervise/send
	;;
	queue)
		qmail-qstat
		qmail-qread
	;;
	reload|hup)
		echo "Sending HUP signal to qmail-send."
		$svc -h $qdir/supervise/send
	;;
	pause)
		echo "Pausing qmail-send"
		$svc -p $qdir/supervise/send
		echo "Pausing qmail-smtpd"
		$svc -p $qdir/supervise/smtp
	;;
	cont)
		echo "Continuing qmail-send"
		$svc -c $qdir/supervise/send
		echo "Continuing qmail-smtpd"
		$svc -c $qdir/supervise/smtp
	;;
	restart)
		echo "Restarting qmail:"
		echo "* Stopping qmail-smtpd."
		$svc -d $qdir/supervise/smtp
		echo "* Sending qmail-send SIGTERM and restarting."
		$svc -t $qdir/supervise/send
		echo "* Restarting qmail-smtpd."
		$svc -u $qdir/supervise/smtp
	;;
	cdb)
		if [ -s ~vpopmail/etc/tcp.smtp ]
		then
			$tcprules ~vpopmail/etc/tcp.smtp.cdb ~vpopmail/etc/tcp.smtp.tmp < ~vpopmail/etc/tcp.smtp
			chmod 644 ~vpopmail/etc/tcp.smtp*
			echo "Reloaded ~vpopmail/etc/tcp.smtp."
		fi

		if [ -s ~vpopmail/etc/tcp.submit ]
		then
			$tcprules ~vpopmail/etc/tcp.submit.cdb ~vpopmail/etc/tcp.submit.tmp < ~vpopmail/etc/tcp.submit
			chmod 644 ~vpopmail/etc/tcp.submit*
			echo "Reloaded ~vpopmail/etc/tcp.submit."
		fi

		if [ -s /etc/tcp.smtp ]
		then
			$tcprules /etc/tcp.smtp.cdb /etc/tcp.smtp.tmp < /etc/tcp.smtp
			chmod 644 /etc/tcp.smtp*
			echo "Reloaded /etc/tcp.smtp."
		fi

		if [ -s $qdir/control/simcontrol ]
		then
			if [ -x $qdir/bin/simscanmk ]
			then
				$qdir/bin/simscanmk
				echo "Reloaded $qdir/control/simcontrol."
				$qdir/bin/simscanmk -g
				echo "Reloaded $qdir/control/simversions."
			fi
		fi

		if [ -s $qdir/users/assign ]
		then
			if [ -x $qdir/bin/qmail-newu ]
			then
				echo "Reloaded $qdir/users/assign."
			fi
		fi

		if [ -s $qdir/control/morercpthosts ]
		then
			if [ -x $qdir/bin/qmail-newmrh ]
			then
				$qdir/bin/qmail-newmrh
				echo "Reloaded $qdir/control/morercpthosts"
			fi
		fi

		if [ -s $qdir/control/spamt ]
		then
			if [ -x $qdir/bin/qmail-newst ]
			then
				$qdir/bin/qmail-newst
				echo "Reloaded $qdir/control/spamt"
			fi
		fi
	;;
	help)
		cat <<HELP
		pause -- temporarily stops mail service (connections accepted, nothing leaves)
		cont -- continues paused mail service
		stat -- displays status of mail service
		cdb -- rebuild the cdb files (tcp.smtp, users, simcontrol)
		restart -- stops and restarts smtp, sends qmail-send a TERM & restarts it
		doqueue -- sends qmail-send ALRM, scheduling queued messages for delivery
		reload -- sends qmail-send HUP, rereading locals and virtualdomains
		queue -- shows status of queue
		alrm -- same as doqueue
		hup -- same as reload
HELP
	;;
	*)
		echo "Usage: \$0 {restart|doqueue|flush|reload|stat|pause|cont|cdb|queue|help}"
		exit 1
	;;
esac

exit 0

EOQMAILCTL

    close $FILE_HANDLE;
}

sub get_domains_from_assign {
    my $self = shift;
    my %p = validate ( @_, {
            'assign'  => { type=>SCALAR,  optional=>1, default=>'/var/qmail/users/assign'},
            'match'   => { type=>SCALAR,  optional=>1, },
            'value'   => { type=>SCALAR,  optional=>1, },
            %std_opts
        },
    );

    my ( $assign, $match, $value, $fatal, $debug )
        = ( $p{'assign'}, $p{'match'}, $p{'value'}, $p{'fatal'}, $p{'debug'} );

    return $p{'test_ok'} if defined $p{'test_ok'};

    return $log->error( "the file $assign is missing or empty!", fatal => $fatal)
        if ! -s $assign;

    my @domains;
    my @lines = $util->file_read( $assign );

    foreach my $line (@lines) {
        chomp $line;
        my @fields = split( /:/, $line );
        if ( $fields[0] ne "" && $fields[0] ne "." ) {
            my %domain = (
                stat => $fields[0],
                dom  => $fields[1],
                uid  => $fields[2],
                gid  => $fields[3],
                dir  => $fields[4],
            );

            if (! $match) { push @domains, \%domain; next; };

            if ( $match eq "dom" && $value eq "$fields[1]" ) {
                push @domains, \%domain;
            }
            elsif ( $match eq "uid" && $value eq "$fields[2]" ) {
                push @domains, \%domain;
            }
            elsif ( $match eq "dir" && $value eq "$fields[4]" ) {
                push @domains, \%domain;
            }
        }
    }
    return @domains;
}

sub get_list_of_rbls {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    # two arrays, one for sorted elements, one for unsorted
    my ( @sorted, @unsorted );
    my ( @list,   %sort_keys, $sort );

    foreach my $key ( keys %$conf ) {

        # ignore everything that doesn't start wih rbl
        next unless ( $key =~ /^rbl/ );

        # ignore other similar keys in $conf
        next if ( $key =~ /^rbl_enable/ );
        next if ( $key =~ /^rbl_reverse_dns/ );
        next if ( $key =~ /^rbl_timeout/ );
        next if ( $key =~ /_message$/ );        # RBL custom reject messages
        next if ( $conf->{$key} == 0 );         # not enabled

        $key =~ /^rbl_([a-zA-Z0-9\.\-]*)\s*$/;

        $log->audit( "good key: $1 ");

        # test for custom sort key
        if ( $conf->{$key} > 1 ) {
            $log->audit( "  sorted value $conf->{$key}" );
            @sorted[ $conf->{$key} - 2 ] = $1;
        }
        else {
            $log->audit( "  unsorted, $conf->{$key}" );
            push @unsorted, $1;
        }
    }

    # add the unsorted values to the sorted list
    push @sorted, @unsorted;
    @sorted = grep { defined $_ } @sorted;   # weed out blanks
    @sorted = grep { $_ =~ /\S/ } @sorted;

    $log->audit( "sorted order: " . join( "\n\t", @sorted ) );

    # test each RBL in the list
    my $good_rbls = $self->test_each_rbl( rbls => \@sorted ) or return q{};

    # format them for use in a supervised (daemontools) run file
    my $string_of_rbls;
    foreach (@$good_rbls) {
        my $mess = $conf->{"rbl_${_}_message"};
        $string_of_rbls .= " \\\n\t\t-r $_";
        if ( defined $mess && $mess ) {
            $string_of_rbls .= ":'$mess'";
        }
    }

    $log->audit( $string_of_rbls );
    return $string_of_rbls;
}

sub get_list_of_rwls {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    my @list;

    foreach my $key ( keys %$conf ) {

        next unless ( $key =~ /^rwl/ && $conf->{$key} == 1 );
        next if ( $key =~ /^rwl_enable/ );

        $key =~ /^rwl_([a-zA-Z_\.\-]*)\s*$/;

        $log->audit( "good key: $1");
        push @list, $1;
    }
    return \@list;
}

sub get_qmailscanner_virus_sender_ips {

    # deprecated function

    my $self = shift;
    my @ips;

    my $debug      = $conf->{'debug'};
    my $block      = $conf->{'qs_block_virus_senders'};
    my $clean      = $conf->{'qs_quarantine_clean'};
    my $quarantine = $conf->{'qs_quarantine_dir'};

    unless ( -d $quarantine ) {
        $quarantine = "/var/spool/qmailscan/quarantine"
          if ( -d "/var/spool/qmailscan/quarantine" );
    }

    unless ( -d "$quarantine/new" ) {
        warn "no quarantine dir!";
        return;
    }

    my @files = $util->get_dir_files( dir => "$quarantine/new" );

    foreach my $file (@files) {
        if ($block) {
            my $ipline = `head -n 10 $file | grep HELO`;
            chomp $ipline;

            next unless ($ipline);
            print " $ipline  - " if $debug;

            my @lines = split( /Received/, $ipline );
            foreach my $line (@lines) {
                print $line if $debug;

                # Received: from unknown (HELO netbible.org) (202.54.63.141)
                my ($ip) = $line =~ /([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/;

                # we need to check the message and verify that it's
                # a virus that was blocked, not an admin testing
                # (Matt 4/3/2004)

                if ( $ip =~ /\s+/ or !$ip ) { print "$line\n" if $debug; }
                else { push @ips, $ip; }
                print "\t$ip" if $debug;
            }
            print "\n" if $debug;
        }
        unlink $file if $clean;
    }

    my ( %hash, @sorted );
    foreach (@ips) { $hash{$_} = "1"; }
    foreach ( keys %hash ) { push @sorted, $_; delete $hash{$_} }
    return @sorted;
}

sub install_qmail {
    my $self = shift;
    my %p = validate( @_, {
            'package' => { type=>SCALAR,  optional=>1, },
            %std_opts,
        },
    );

    my $package = $p{'package'};

    my ( $patch, $chkusr );

    return $p{'test_ok'} if defined $p{'test_ok'};

    # redirect if netqmail is selected
    if ( $conf->{'install_netqmail'} ) {
        return $self->netqmail();
    }

    my $ver = $conf->{'install_qmail'} or do {
        print "install_qmail: installation disabled in .conf, SKIPPING";
        return;
    };

    $self->install_qmail_groups_users();

    $package ||= "qmail-$ver";

    my $src      = $conf->{'toaster_src_dir'}   || "/usr/local/src";
    my $qmaildir = $conf->{'qmail_dir'}         || "/var/qmail";
    my $vpopdir  = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    my $mysql = $conf->{'qmail_mysql_include'}
      || "/usr/local/lib/mysql/libmysqlclient.a";
    my $dl_site = $conf->{'toaster_dl_site'} || "http://www.tnpi.net";
    my $dl_url  = $conf->{'toaster_dl_url'}  || "/internet/mail/toaster";
    my $toaster_url = "$dl_site$dl_url";

    $util->cwd_source_dir( "$src/mail" );

    if ( -e $package ) {
        unless ( $util->source_warning( package=>$package, src=>$src ) ) {
            warn "install_qmail: FATAL: sorry, I can't continue.\n";
            return;
        }
    }

    unless ( defined $conf->{'qmail_chk_usr_patch'} ) {
        print "\nCheckUser support causes the qmail-smtpd daemon to verify that
a user exists locally before accepting the message, during the SMTP conversation.
This prevents your mail server from accepting messages to email addresses that
don't exist in vpopmail. It is not compatible with system user mailboxes. \n\n";

        $chkusr =
          $util->yes_or_no( "Do you want qmail-smtpd-chkusr support enabled?" );
    }
    else {
        if ( $conf->{'qmail_chk_usr_patch'} ) {
            $chkusr = 1;
            print "chk-usr patch: yes\n";
        }
    }

    if ($chkusr) { $patch = "$package-toaster-2.8.patch"; }
    else { $patch = "$package-toaster-2.6.patch"; }

    my $site = "http://cr.yp.to/software";

    unless ( -e "$package.tar.gz" ) {
        if ( -e "/usr/ports/distfiles/$package.tar.gz" ) {
            use File::Copy;
            copy( "/usr/ports/distfiles/$package.tar.gz",
                "$src/mail/$package.tar.gz" );
        }
        else {
            $util->get_url( "$site/$package.tar.gz" );
            unless ( -e "$package.tar.gz" ) {
                die "install_qmail FAILED: couldn't fetch $package.tar.gz!\n";
            }
        }
    }

    unless ( -e $patch ) {
        $util->get_url( "$toaster_url/patches/$patch" );
        unless ( -e $patch ) { die "\n\nfailed to fetch patch $patch!\n\n"; }
    }

    my $tar      = $util->find_bin( "tar"  );
    my $patchbin = $util->find_bin( "patch" );
    unless ( $tar && $patchbin ) { die "couldn't find tar or patch!\n"; }

    $util->syscmd( "$tar -xzf $package.tar.gz" );
    chdir("$src/mail/$package")
      or die "install_qmail: cd $src/mail/$package failed: $!\n";
    $util->syscmd( "$patchbin < $src/mail/$patch" );

    $util->file_write( "conf-qmail", lines => [$qmaildir] )
      or die "couldn't write to conf-qmail: $!";

    $util->file_write( "conf-vpopmail", lines => [$vpopdir] )
      or die "couldn't write to conf-vpopmail: $!";

    $util->file_write( "conf-mysql", lines => [$mysql] )
      or die "couldn't write to conf-mysql: $!";

    my $servicectl = "/usr/local/sbin/services";

    if ( -x $servicectl ) {

        print "Stopping Qmail!\n";
        $util->syscmd( "$servicectl stop" );
        $self->send_stop();
    }

    my $make = $util->find_bin( "gmake", fatal => 0 );
    $make  ||= $util->find_bin( "make" );

    $util->syscmd( "$make setup" );

    unless ( -f "$qmaildir/control/servercert.pem" ) {
        $util->syscmd( "$make cert" );
    }

    if ($chkusr) {
        $util->chown( "$qmaildir/bin/qmail-smtpd",
            uid => 'vpopmail',
            gid => 'vchkpw',
        );

        $util->chmod( file => "$qmaildir/bin/qmail-smtpd",
            mode  => '6555',
        );
    }

    unless ( -e "/usr/share/skel/Maildir" ) {

# deprecated, not necessary unless using system accounts
# $util->syscmd( "$qmaildir/bin/maildirmake /usr/share/skel/Maildir" );
    }

    $self->config();

    if ( -x $servicectl ) {
        print "Starting Qmail & supervised services!\n";
        $util->syscmd( "$servicectl start" );
    }
}

sub install_qmail_control_files {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    my $supervise = $conf->{'qmail_supervise'} || "/var/qmail/supervise";

    return $p{'test_ok'} if defined $p{'test_ok'};

    foreach my $prot (qw/ pop3 send smtp submit /) {
        my $supdir = $toaster->supervise_dir_get( prot => $prot);
        my $run_f = "$supdir/run";

        if ( -e $run_f ) {
            $log->audit( "install_qmail_control_files: $run_f already exists!");
            next;
        }

        if    ( $prot eq "smtp"   ) { $self->build_smtp_run()   }
        elsif ( $prot eq "send"   ) { $self->build_send_run()   }
        elsif ( $prot eq "pop3"   ) { $self->build_pop3_run()   }
        elsif ( $prot eq "submit" ) { $self->build_submit_run() }
    }
}

sub install_qmail_groups_users {
    my $self = shift;
    my %p = validate( @_, { %std_opts },);

    my $err = "ERROR: You need to update your toaster-watcher.conf file!\n";

    my $qmailg   = $conf->{'qmail_group'}       || 'qmail';
    my $alias    = $conf->{'qmail_user_alias'}  || 'alias';
    my $qmaild   = $conf->{'qmail_user_daemon'} || 'qmaild';
    my $qmailp   = $conf->{'qmail_user_passwd'} || 'qmailp';
    my $qmailq   = $conf->{'qmail_user_queue'}  || 'qmailq';
    my $qmailr   = $conf->{'qmail_user_remote'} || 'qmailr';
    my $qmails   = $conf->{'qmail_user_send'}   || 'qmails';
    my $qmaill   = $conf->{'qmail_user_log'}    || 'qmaill';
    my $nofiles  = $conf->{'qmail_log_group'}   || 'nofiles';

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $uid = 81;
    my $gid = 81;

    if ( $OSNAME eq 'darwin' ) { $uid = $gid = 200; }

    if ( ! $setup ) {
        require Mail::Toaster::Setup;
        $setup = Mail::Toaster::Setup->new(conf=>$conf, toaster => $toaster);
    };
    $setup->group_add( 'qnofiles', $gid );
    $setup->group_add( $qmailg, $gid + 1 );

    my $homedir = $conf->{'qmail_dir'} || '/var/qmail';

    $setup->user_add($alias, $uid, $gid, homedir => "$homedir/alias" );
    $uid++;
    $setup->user_add($qmaild, $uid, $gid, homedir => $homedir );
    $uid++;
    $setup->user_add($qmaill, $uid, $gid, homedir => $homedir );
    $uid++;
    $setup->user_add($qmailp, $uid, $gid, homedir => $homedir );
    $uid++;
    $gid++;
    $setup->user_add($qmailq, $uid, $gid, homedir => $homedir );
    $uid++;
    $setup->user_add($qmailr, $uid, $gid, homedir => $homedir );
    $uid++;
    $setup->user_add($qmails, $uid, $gid, homedir => $homedir );
}

sub install_supervise_run {
    my $self = shift;
    my %p = validate( @_, {
            'tmpfile'     => { type=>SCALAR,  },
            'destination' => { type=>SCALAR,  optional=>1, },
            'prot'        => { type=>SCALAR,  optional=>1, },
            %std_opts,
        },
    );
    my %args = $toaster->get_std_args( %p );

    my ( $tmpfile, $destination, $prot )
        = ( $p{'tmpfile'}, $p{'destination'}, $p{'prot'} );

    return $p{'test_ok'} if defined $p{'test_ok'};

    if ( !$destination ) {
        return $log->error( "you didn't set destination or prot!" ) if !$prot;

        my $dir = $toaster->supervise_dir_get( prot => $prot )
            or return $log->error( "no sup dir for $prot found" );
        $destination = "$dir/run";
    }

    return $log->error( "the new file ($tmpfile) is missing!",fatal=>0)
        if !-e $tmpfile;

    my $s = -e $destination ? 'updating' : 'installing';
    $log->audit( "install_supervise_run: $s $destination");

    return $util->install_if_changed(
        existing => $destination,  newfile  => $tmpfile,
        mode     => '0755',        clean    => 1,
        notify   => $conf->{'supervise_rebuild_notice'} || 1,
        email    => $conf->{'toaster_admin_email'} || 'postmaster',
        debug    => $self->{debug},
        fatal    => 0,
    );
}

sub install_qmail_control_log_files {
    my $self = shift;
    my %p = validate( @_, {
            prots   => { type=>ARRAYREF,optional=>1, default=>['smtp', 'send', 'pop3', 'submit'] },
            %std_opts,
        },
    );

    my %args = $toaster->get_std_args( %p );
    my $prots = $p{prots};

    my $supervise = $conf->{'qmail_supervise'} || "/var/qmail/supervise";

    my %valid_prots = map { $_ => 1 } qw/ smtp send pop3 submit /;

    return $p{test_ok} if defined $p{test_ok};

    # Create log/run files
    foreach my $serv (@$prots) {

        die "invalid protocol: $serv!\n" unless $valid_prots{$serv};

        my $supervisedir = $toaster->supervise_dir_get( prot => $serv );
        my $run_f = "$supervisedir/log/run";

        $log->audit( "install_qmail_control_log_files: preparing $run_f");

        my @lines = $toaster->supervised_do_not_edit_notice();
        push @lines, $toaster->supervised_multilog(prot=>$serv );

        my $tmpfile = "/tmp/mt_supervise_" . $serv . "_log_run";
        $util->file_write( $tmpfile, lines => \@lines );

        $log->audit( "install_qmail_control_log_files: comparing $run_f");

        my $notify = defined $conf->{'supervise_rebuilt_notice'} ? $conf->{'supervise_rebuilt_notice'} : 1;

        if ( -s $tmpfile ) {
            $util->install_if_changed(
                newfile  => $tmpfile, existing => $run_f,
                mode     => '0755',   clean    => 1,
                notify   => $notify,  email    => $conf->{'toaster_admin_email'},
            ) or return;
            $log->audit( " updating $run_f, ok" );
        }

        $toaster->supervised_dir_test( prot  => $serv, %args  );
    }
}

sub install_ssl_temp_key {
    my ( $cert, $fatal ) = @_;

    my $user  = $conf->{'smtpd_run_as_user'} || "vpopmail";
    my $group = $conf->{'qmail_group'}       || "qmail";

    $util->chmod(
        file_or_dir => "$cert.new",
        mode        => '0660',
        fatal       => $fatal,
    );

    $util->chown( "$cert.new",
        uid   => $user,
        gid   => $group,
        fatal => $fatal,
    );

    move( "$cert.new", $cert );
}

sub maildir_in_skel {

    my $skel = "/usr/share/skel";
    if ( ! -d $skel ) {
        $skel = "/etc/skel" if -d "/etc/skel";    # linux
    }

    if ( ! -e "$skel/Maildir" ) {
        # only necessary for systems with local email accounts
        #$util->syscmd( "$qmaildir/bin/maildirmake $skel/Maildir" ) ;
    }
}

sub netqmail {
    my $self = shift;
    my %p = validate( @_, {
            'package' => { type=>SCALAR,  optional=>1, },
            %std_opts,
        },
    );

    my $package = $p{package};
    my $ver     = $conf->{'install_netqmail'} || "1.05";
    my $src     = $conf->{'toaster_src_dir'}  || "/usr/local/src";
    my $vhome   = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    $package ||= "netqmail-$ver";

    return $p{test_ok} if defined $p{test_ok};

    $self->install_qmail_groups_users();

    # check to see if qmail-smtpd already has vpopmail support
    return 0 unless $self->netqmail_rebuild();

    $util->cwd_source_dir( "$src/mail" );

    $self->netqmail_get_sources( $package ) or return;
    my @patches = $self->netqmail_get_patches( $package );

    $util->extract_archive( "$package.tar.gz" );

    # netqmail requires a "collate" step before it can be built
    chdir("$src/mail/$package")
        or die "netqmail: cd $src/mail/$package failed: $!\n";

    $util->syscmd( "./collate.sh" );

    chdir("$src/mail/$package/$package")
        or die "netqmail: cd $src/mail/$package/$package failed: $!\n";

    my $patchbin = $util->find_bin( 'patch' );

    foreach my $patch (@patches) {
        print "\nnetqmail: applying $patch\n\n";
        sleep 1;
        $util->syscmd( "$patchbin < $src/mail/$patch" );
    };

    $self->netqmail_makefile_fixups();
    $self->netqmail_queue_extra()   if $conf->{'qmail_queue_extra'};
    $self->netqmail_darwin_fixups() if $OSNAME eq "darwin";
    $self->netqmail_conf_cc();
    $self->netqmail_conf_fixups();
    $self->netqmail_chkuser_fixups();

    my $servicectl = '/usr/local/sbin/services';
    $servicectl = '/usr/local/bin/services' if ! -x $servicectl;
    if ( -x $servicectl ) {
        print "Stopping Qmail!\n";
        $self->send_stop();
        system "$servicectl stop";
    }

    my $make = $util->find_bin( "gmake", fatal => 0 ) || $util->find_bin( "make" );
    $util->syscmd( "$make setup" );

    $self->netqmail_ssl( $make );
    $self->netqmail_permissions();

    $self->maildir_in_skel();
    $self->config();

    if ( -x $servicectl ) {
        print "Starting Qmail & supervised services!\n";
        system "$servicectl start";
    }
}

sub netqmail_chkuser_fixups {
    my $self = shift;

    return if ! $conf->{vpopmail_qmail_ext};

    my $file = 'chkuser_settings.h';
    print "netqmail: fixing up $file\n";

    my @lines = $util->file_read( $file );
    foreach my $line (@lines) {
        if ( $line =~ /^\/\* \#define CHKUSER_ENABLE_USERS_EXTENSIONS/ ) {
            $line = "#define CHKUSER_ENABLE_USERS_EXTENSIONS";
        }
    }
    $util->file_write( $file, lines => \@lines );

};

sub netqmail_conf_cc {
    my $self = shift;

    my $vpopdir    = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    my $domainkeys = $conf->{'qmail_domainkeys'};

    # make changes to conf-cc
    print "netqmail: fixing up conf-cc\n";
    my $cmd = "cc -O2 -DTLS=20060104 -I$vpopdir/include";

    # add in the -I (include) dir for OpenSSL headers
    if ( -d "/opt/local/include/openssl" ) {
        print "netqmail: building against /opt/local/include/openssl.\n";
        $cmd .= " -I/opt/local/include/openssl";
    }
    elsif ( -d "/usr/local/include/openssl" && $conf->{'install_openssl'} )
    {
        print
          "netqmail: building against /usr/local/include/openssl from ports.\n";
        $cmd .= " -I/usr/local/include/openssl";
    }
    elsif ( -d "/usr/include/openssl" ) {
        print "netqmail: using system supplied OpenSSL libraries.\n";
        $cmd .= " -I/usr/include/openssl";
    }
    else {
        if ( -d "/usr/local/include/openssl" ) {
            print "netqmail: building against /usr/local/include/openssl.\n";
            $cmd .= " -I/usr/local/include/openssl";
        }
        else {
            print
"netqmail: WARNING: I couldn't find your OpenSSL libraries. This might cause problems!\n";
        }
    }

    # add in the include directory for libdomainkeys
    if ( $domainkeys ) {
        # make sure libdomainkeys is installed
        if ( ! -e "/usr/local/include/domainkeys.h" ) {
            if ( ! $setup ) {
                require Mail::Toaster::Setup;
                $setup = Mail::Toaster::Setup->new(conf=>$conf, toaster => $toaster);
            };
            $setup->domainkeys();
        };
        if ( -e "/usr/local/include/domainkeys.h" ) {
            $cmd .= " -I/usr/local/include";
        };
    };

    $util->file_write( "conf-cc", lines => [$cmd] );
};

sub netqmail_conf_fixups {
    my $self = shift;

    print "netqmail: fixing up conf-qmail\n";
    my $qmaildir = $conf->{'qmail_dir'}        || "/var/qmail";
    $util->file_write( "conf-qmail", lines => [$qmaildir] );

    print "netqmail: fixing up conf-vpopmail\n";
    my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    $util->file_write( "conf-vpopmail", lines => [$vpopdir] );

    print "netqmail: fixing up conf-mysql\n";
    my $mysql = $conf->{'qmail_mysql_include'} || "/usr/local/lib/mysql/libmysqlclient.a";
    $util->file_write( "conf-mysql", lines => [$mysql] );

    print "netqmail: fixing up conf-groups\n";
    my $q_group = $conf->{'qmail_group'} || 'qmail';
    my $l_group = $conf->{'qmail_log_group'} || "qnofiles";
    $util->file_write( "conf-groups", lines => [ $q_group, $l_group ] );
};

sub netqmail_darwin_fixups {
    my $self = shift;

    print "netqmail: fixing up conf-ld\n";
    $util->file_write( "conf-ld", lines => ["cc -Xlinker -x"] )
      or die "couldn't write to conf-ld: $!";

    print "netqmail: fixing up dns.c for Darwin\n";
    my @lines = $util->file_read( "dns.c" );
    foreach my $line (@lines) {
        if ( $line =~ /#include <netinet\/in.h>/ ) {
            $line = "#include <netinet/in.h>\n#include <nameser8_compat.h>";
        }
    }
    $util->file_write( "dns.c", lines => \@lines );

    print "netqmail: fixing up strerr_sys.c for Darwin\n";
    @lines = $util->file_read( "strerr_sys.c" );
    foreach my $line (@lines) {
        if ( $line =~ /struct strerr strerr_sys/ ) {
            $line = "struct strerr strerr_sys = {0,0,0,0};";
        }
    }
    $util->file_write( "strerr_sys.c", lines => \@lines );

    print "netqmail: fixing up hier.c for Darwin\n";
    @lines = $util->file_read( "hier.c" );
    foreach my $line (@lines) {
        if ( $line =~
            /c\(auto_qmail,"doc","INSTALL",auto_uido,auto_gidq,0644\)/ )
        {
            $line =
              'c(auto_qmail,"doc","INSTALL.txt",auto_uido,auto_gidq,0644);';
        }
    }
    $util->file_write( "hier.c", lines => \@lines );

    # fixes due to case sensitive file system
    move( "INSTALL",  "INSTALL.txt" );
    move( "SENDMAIL", "SENDMAIL.txt" );
}

sub netqmail_get_sources {
    my $self = shift;
    my $package = shift;
    my $site = "http://www.qmail.org";
    my $src  = $conf->{'toaster_src_dir'}  || "/usr/local/src";

    $util->source_warning( package=>$package, src=>"$src/mail" ) or return;

    return 1 if -e "$package.tar.gz";   # already exists

    # check to see if we have it in the ports repo
    my $dist = "/usr/ports/distfiles/$package.tar.gz";
    if ( -e $dist ) {
        copy( $dist, "$src/mail/$package.tar.gz" );
    }
    return 1 if -e "$package.tar.gz";

    $util->get_url( "$site/$package.tar.gz" );
    return 1 if -e "$package.tar.gz";

    return $log->error( "couldn't fetch $package.tar.gz!" );
};

sub netqmail_get_patches {
    my $self = shift;
    my $package = shift;

    my $patch_ver = $conf->{'qmail_toaster_patch_version'};

    my @patches;
    push @patches, "$package-toaster-$patch_ver.patch" if $patch_ver;

    if ( defined $conf->{qmail_smtp_reject_patch} && $conf->{qmail_smtp_reject_patch} ) {
        push @patches, "$package-smtp_reject-3.0.patch";
    }

    if ( defined $conf->{qmail_domainkeys} && $conf->{qmail_domainkeys} ) {
        push @patches, "$package-toaster-3.1-dk.patch";
    };

    my ($sysname, undef, $version) = POSIX::uname;
    if ( $sysname eq 'FreeBSD' && $version =~ /^9/ )  {
        push @patches, "qmail-extra-patch-utmpx.patch";
    }

    my $dl_site    = $conf->{'toaster_dl_site'}   || "http://www.tnpi.net";
    my $dl_url     = $conf->{'toaster_dl_url'}    || "/internet/mail/toaster";
    my $toaster_url = "$dl_site$dl_url";

    foreach my $patch (@patches) {
        next if -e $patch;
        $util->get_url( "$toaster_url/patches/$patch" );
        next if -e $patch;
        return $log->error( "failed to fetch patch $patch!" );
    }
    return @patches;
};

sub netqmail_makefile_fixups {
    my $self = shift;
    my $vpopdir    = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    # find those pesky openssl libraries
    my $prefix = $conf->{'toaster_prefix'} || "/usr/local/";
    my $ssl_lib = "$prefix/lib";
    if ( !-e "$ssl_lib/libcrypto.a" ) {
        if    ( -e "/opt/local/lib/libcrypto.a" ) { $ssl_lib = "/opt/local/lib"; }
        elsif ( -e "/usr/local/lib/libcrypto.a" ) { $ssl_lib = "/usr/local/lib"; }
        elsif ( -e "/opt/lib/libcrypto.a"       ) { $ssl_lib = "/opt/lib"; }
        elsif ( -e "/usr/lib/libcrypto.a"       ) { $ssl_lib = "/usr/lib"; }
    }


    my @lines = $util->file_read( "Makefile" );
    foreach my $line (@lines) {
        if ( $vpopdir ne "/home/vpopmail" ) {    # fix up vpopmail home dir
            if ( $line =~ /^VPOPMAIL_HOME/ ) {
                $line = 'VPOPMAIL_HOME=' . $vpopdir;
            }
        }

        # add in the discovered ssl library location
        if ( $line =~
            /tls.o ssl_timeoutio.o -L\/usr\/local\/ssl\/lib -lssl -lcrypto/ )
        {
            $line =
              '	tls.o ssl_timeoutio.o -L' . $ssl_lib . ' -lssl -lcrypto \\';
        }

        # again with the ssl libs
        if ( $line =~
/constmap.o tls.o ssl_timeoutio.o ndelay.a -L\/usr\/local\/ssl\/lib -lssl -lcrypto \\/
          )
        {
            $line =
                '	constmap.o tls.o ssl_timeoutio.o ndelay.a -L' . $ssl_lib
              . ' -lssl -lcrypto \\';
        }
    }
    $util->file_write( "Makefile", lines => \@lines );

};

sub netqmail_permissions {
    my $self = shift;

    my $qmaildir = $conf->{'qmail_dir'} || "/var/qmail";
    $util->chown( "$qmaildir/bin/qmail-smtpd",
        uid  => 'vpopmail',
        gid  => 'vchkpw',
    );

    $util->chmod(
        file_or_dir => "$qmaildir/bin/qmail-smtpd",
        mode        => '6555',
    );
};

sub netqmail_queue_extra {
    my $self = shift;

    print "netqmail: enabling QUEUE_EXTRA...\n";
    my $success = 0;
    my @lines = $util->file_read( "extra.h" );
    foreach my $line (@lines) {
        if ( $line =~ /#define QUEUE_EXTRA ""/ ) {
            $line = '#define QUEUE_EXTRA "Tlog\0"';
            $success++;
        }

        if ( $line =~ /#define QUEUE_EXTRALEN 0/ ) {
            $line = '#define QUEUE_EXTRALEN 5';
            $success++;
        }
    }

    if ( $success == 2 ) {
        print "success.\n";
        $util->file_write( "extra.h", lines => \@lines );
    }
    else {
        print "FAILED.\n";
    }
}

sub netqmail_rebuild {
    my $self = shift;

    # check to see if qmail-smtpd has vpopmail support already
    if ( -x "/var/qmail/bin/qmail-smtpd"
        && `strings /var/qmail/bin/qmail-smtpd | grep vpopmail` ) {
        return if
            !$util->yes_or_no(
                "toasterized qmail is already installed, do you want to reinstall",
                timeout => 30,
            );
    }
    return 1;
}

sub netqmail_ssl {
    my $self = shift;
    my $make = shift;

    my $qmaildir = $conf->{'qmail_dir'} || "/var/qmail";

    if ( ! -d "$qmaildir/control" ) {
        mkpath "$qmaildir/control";
    };

    $ENV{PATH} = "/bin:/sbin:/usr/bin:/usr/sbin";
    if ( ! -f "$qmaildir/control/servercert.pem" ) {
        print "netqmail: installing SSL certificate\n";
        if ( -f "/usr/local/openssl/certs/server.pem" ) {
            copy( "/usr/local/openssl/certs/server.pem", "$qmaildir/control/servercert.pem");
            link( "/var/qmail/control/servercert.pem", "$qmaildir/control/clientcert.pem" );
        }
        else {
            system "$make cert";
        };
    }

    if ( ! -f "$qmaildir/control/rsa512.pem" ) {
        print "netqmail: install temp SSL \n";
        system "$make tmprsadh";
    }
};

sub netqmail_virgin {
    my $self = shift;
    my %p = validate( @_, {
            'package' => { type=>SCALAR,  optional=>1, },
            %std_opts,
        },
    );

    my $package = $p{'package'};
    my $chkusr;

    my $ver      = $conf->{'install_netqmail'} || "1.05";
    my $src      = $conf->{'toaster_src_dir'}  || "/usr/local/src";
    my $qmaildir = $conf->{'qmail_dir'}        || "/var/qmail";

    $package ||= "netqmail-$ver";

    my $mysql = $conf->{'qmail_mysql_include'}
      || "/usr/local/lib/mysql/libmysqlclient.a";
    my $qmailgroup = $conf->{'qmail_log_group'} || "qnofiles";

    # we do not want to try installing anything during "make test"
    if ( defined $p{'test_ok'} ) { return $p{'test_ok'}; }

    $self->install_qmail_groups_users();

    $util->cwd_source_dir( "$src/mail" );
    $self->netqmail_get_sources( $package );

    unless ( $util->extract_archive( "$package.tar.gz" ) ) {
        die "couldn't expand $package.tar.gz\n";
    }

    # netqmail requires a "collate" step before it can be built
    chdir("$src/mail/$package")
      or die "netqmail: cd $src/mail/$package failed: $!\n";
    $util->syscmd( "./collate.sh" );
    chdir("$src/mail/$package/$package")
      or die "netqmail: cd $src/mail/$package/$package failed: $!\n";

    $self->netqmail_conf_fixups();
    $self->netqmail_darwin_fixups() if $OSNAME eq 'darwin';

    print "netqmail: fixing up conf-cc\n";
    $util->file_write( "conf-cc", lines => ["cc -O2"] )
      or die "couldn't write to conf-cc: $!";

    my $servicectl = "/usr/local/sbin/services";
    if ( -x $servicectl ) {
        print "Stopping Qmail!\n";
        $self->send_stop();
        $util->syscmd( "$servicectl stop" );
    }

    my $make = $util->find_bin( "gmake", fatal => 0 ) || $util->find_bin( "make" );
    $util->syscmd( "$make setup" );

    $self->maildir_in_skel();
    $self->config();

    if ( -x $servicectl ) {
        print "Starting Qmail & supervised services!\n";
        $util->syscmd( "$servicectl start" );
    }
}

sub queue_check {
    # used in qqtool.pl

    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    my ( $fatal, $debug ) = ( $p{'fatal'}, $p{'debug'} );

    my $base  = $conf->{'qmail_dir'};
    unless ( $base ) {
        print "queue_check: ERROR! qmail_dir is not set in conf! This is almost certainly an error!\n";
        $base = "/var/qmail"
    }

    my $queue = "$base/queue";

    print "queue_check: checking $queue..." if $debug;

    unless ( $queue && -d $queue ) {
        my $err = "\tHEY! The queue directory for qmail is missing!\n";
        $err .= "\tI expected it to be at $queue\n" if $queue;
        $err .= "\tIt should have been set via the qmail_dir setting in toaster-watcher.conf!\n";

        return $log->error( $err, fatal => $fatal );
    }

    print "ok.\n" if $debug;
    return "$base/queue";
}

sub rebuild_simscan_control {

    return if ! $conf->{install_simscan};

    my $qmdir = $conf->{'qmail_dir'} || '/var/qmail';

    my $control = "$qmdir/control/simcontrol";
    return if ! -f $control;
    return 1 if ( -e "$control.cdb" && ! $util->file_is_newer( f1=>$control, f2=>"$control.cdb" ) );

    my $simscanmk = "$qmdir/bin/simscanmk";
    return if ! -x $simscanmk;

    `$simscanmk` or return 1;
    `$simscanmk -g`;    # for old versions of simscan
};

sub rebuild_ssl_temp_keys {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    my $openssl = $util->find_bin( "openssl" );
    my $fatal = $p{fatal};

    my $qmdir = $conf->{'qmail_dir'} || "/var/qmail";
    my $cert  = "$qmdir/control/rsa512.pem";

    return $p{'test_ok'} if defined $p{'test_ok'};

    if ( ! -f $cert || -M $cert >= 1 || !-e $cert ) {
        $log->audit( "rebuild_ssl_temp_keys: rebuilding RSA key");
        $util->syscmd( "$openssl genrsa -out $cert.new 512 2>/dev/null" );

        install_ssl_temp_key( $cert, $fatal );
    }

    $cert = "$qmdir/control/dh512.pem";
    if ( ! -f $cert || -M $cert >= 1 || !-e $cert ) {
        $log->audit( "rebuild_ssl_temp_keys: rebuilding DSA 512 key");
        $util->syscmd( "$openssl dhparam -2 -out $cert.new 512 2>/dev/null" );

        install_ssl_temp_key( $cert, $fatal );
    }

    $cert = "$qmdir/control/dh1024.pem";
    if ( ! -f $cert || -M $cert >= 1 || !-e $cert ) {
        $log->audit( "rebuild_ssl_temp_keys: rebuilding DSA 1024 key");
        system  "$openssl dhparam -2 -out $cert.new 1024 2>/dev/null";
        install_ssl_temp_key( $cert, $fatal );
    }

    return 1;
}

sub restart {
    my $self = shift;
    my %p = validate( @_, {
            'prot'    => { type=>SCALAR },
            %std_opts,
        },
    );

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $prot = $p{'prot'};
    my $dir = $toaster->service_dir_get( prot => $prot ) or return;

    return $log->error( "no such dir: $dir!" ) unless ( -d $dir || -l $dir );

    $toaster->supervise_restart($dir);
}

sub send_start {
    my $self = shift;
    my %p = validate( @_, { %std_opts, },);

    my %args = ( debug => $p{debug}, fatal => $p{fatal} );

    my $qcontrol = $toaster->service_dir_get( prot => "send" );

    return $p{'test_ok'}  if defined $p{'test_ok'};

    return $log->error( "uh oh, the service directory $qcontrol is missing!",
        %args ) if ! -d $qcontrol;

    if ( ! $toaster->supervised_dir_test( prot=>"send", %args ) ) {
        return $log->error( "something is wrong with the service/send dir.", %args );
    }

    return $log->error( "Only root can control supervised daemons, and you aren't root!",
        %args ) if $UID != 0;

    my $svc    = $util->find_bin( "svc", debug=>0 );
    my $svstat = $util->find_bin( "svstat", debug=>0 );

    # Start the qmail-send (and related programs)
    system "$svc -u $qcontrol";

    # loop until it is up and running.
    foreach my $i ( 1 .. 200 ) {
        my $r = `$svstat $qcontrol`;
        chomp $r;
        if ( $r =~ /^.*:\sup\s\(pid [0-9]*\)\s[0-9]*\sseconds$/ ) {
            print "Yay, we're up!\n";
            return 1;
        }
        sleep 1;
    }
    return 1;
}

sub send_stop {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    my %args = ( debug => $p{debug}, fatal => $p{fatal} );

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $svc    = $util->find_bin( "svc", debug=>0 );
    my $svstat = $util->find_bin( "svstat", debug=>0 );

    my $qcontrol = $toaster->service_dir_get( prot => "send" );

    return $log->error( "uh oh, the service directory $qcontrol is missing! Giving up.",
        %args ) unless $qcontrol;

    return $log->error( "something was wrong with the service/send dir.", %args )
        if ! $toaster->supervised_dir_test( prot=>"send", dir=>$qcontrol, %args );

    return $log->error( "Only root can control supervised daemons, and you aren't root!",
        %args ) if $UID != 0;

    # send qmail-send a TERM signal
    system "$svc -d $qcontrol";

    # loop up to a thousand seconds waiting for qmail-send to exit
    foreach my $i ( 1 .. 1000 ) {
        my $r = `$svstat $qcontrol`;
        chomp $r;
        if ( $r =~ /^.*:\sdown\s[0-9]*\sseconds/ ) {
            print "Yay, we're down!\n";
            return;
        }
        elsif ( $r =~ /supervise not running/ ) {
            print "Yay, we're down!\n";
            return;
        }
        else {

            # if more than 100 seconds passes, lets kill off the qmail-remote
            # processes that are forcing us to wait.

            if ( $i > 100 ) {
                $util->syscmd( "killall qmail-remote", debug=>0 );
            }
            print "$r\n";
        }
        sleep 1;
    }
    return 1;
}

sub set_config {
    my $self = shift;
    $self->{config} = $conf = shift or return;
};

sub smtp_auth_enable {
    my $self = shift;

    return '' if ! $conf->{'smtpd_auth_enable'};

    my $smtp_auth = '';

    $log->audit( "build_smtp_run: enabling SMTP-AUTH");

    # deprecated, should not be used any longer
    if ( $conf->{'smtpd_hostname'} && $conf->{'qmail_smtpd_auth_0.31'} ) {
        $log->audit( "  configuring smtpd hostname");
        $smtp_auth .= $toaster->supervised_hostname( prot => 'smtpd' );
    }

    my $chkpass = $self->_set_checkpasswd_bin( prot => 'smtpd' )
        or return '';

    return "$smtp_auth $chkpass /usr/bin/true ";
}

sub smtp_set_qmailqueue {
    my $self = shift;
    my %p = validate( @_, { 'prot' => { type=>SCALAR,  optional=>1 } } );

    my $prot = $p{'prot'};
    my $qdir = $conf->{'qmail_dir'} || '/var/qmail';

    if ( $conf->{'filtering_method'} ne "smtp" ) {
        $log->audit( "filtering_method != smtp, not setting QMAILQUEUE.");
        return "";
    }

    # typically this will be simscan, qmail-scanner, or qmail-queue
    my $queue = $conf->{'smtpd_qmail_queue'} || "$qdir/bin/qmail-queue";

    if ( defined $prot && $prot eq "submit" ) {
        $queue = $conf->{'submit_qmail_queue'};
    }

    # if the selected one is not executable...
    if ( ! -x $queue ) {

        return $log->error( "$queue is not executable by uid $>.", fatal => 0)
            if !-x "$qdir/bin/qmail-queue";

        warn "WARNING: $queue is not executable! I'm falling back to
$qdir/bin/qmail-queue. You need to either (re)install $queue or update your
toaster-watcher.conf file to point to its correct location.\n
You will continue to get this notice every 5 minutes until you fix this.\n";
        $queue = "$qdir/bin/qmail-queue";
    }

    $log->audit( "  using $queue for QMAILQUEUE");

    return "QMAILQUEUE=\"$queue\"\nexport QMAILQUEUE\n";
}

sub smtp_set_rbls {
    my $self = shift;

    return q{} if ( ! $conf->{'rwl_enable'} && ! $conf->{'rbl_enable'} );

    my $rbl_cmd_string;

    my $rblsmtpd = $util->find_bin( "rblsmtpd" );
    $rbl_cmd_string .= "\\\n\t$rblsmtpd ";

    $log->audit( "smtp_set_rbls: using rblsmtpd");

    my $timeout = $conf->{'rbl_timeout'} || 60;
    $rbl_cmd_string .= $timeout != 60 ? "-t $timeout " : q{};

    $rbl_cmd_string .= "-c " if  $conf->{'rbl_enable_fail_closed'};
    $rbl_cmd_string .= "-b " if !$conf->{'rbl_enable_soft_failure'};

    if ( $conf->{'rwl_enable'} && $conf->{'rwl_enable'} > 0 ) {
        my $list = $self->get_list_of_rwls();
        foreach my $rwl (@$list) { $rbl_cmd_string .= "\\\n\t\t-a $rwl " }
        $log->audit( "tested DNS white lists" );
    }
    else { $log->audit( "no RWLs selected"); };

    if ( $conf->{'rbl_enable'} && $conf->{'rbl_enable'} > 0 ) {
        my $list = $self->get_list_of_rbls();
        $rbl_cmd_string .= $list if $list;
        $log->audit( "tested DNS blacklists" );
    }
    else { $log->audit( "no RBLs selected") };

    return "$rbl_cmd_string ";
};

sub supervised_hostname_qmail {
    my $self = shift;
    my %p = validate( @_, { 'prot' => { type=>SCALAR } } );

    my $prot = $p{'prot'};

    my $qsupervise = $conf->{'qmail_supervise'} || "/var/qmail/supervise";

    my $prot_val = "qmail_supervise_" . $prot;
    my $prot_dir = $conf->{$prot_val} || "$qsupervise/$prot";

    $log->audit( "supervise dir is $prot_dir");

    if ( $prot_dir =~ /^qmail_supervise\/(.*)$/ ) {
        $prot_dir = "$qsupervise/$1";
        $log->audit( "expanded supervise dir to $prot_dir");
    }

    my $qmaildir = $conf->{'qmail_dir'} || '/var/qmail';
    my $me = "$qmaildir/control/me"; # the qmail file for the hostname

    my @lines = <<EORUN
LOCAL=\`head -1 $me\`
if [ -z \"\$LOCAL\" ]; then
    echo ERROR: $prot_dir/run tried reading your hostname from $me and failed!
    exit 1
fi\n
EORUN
;
    $log->audit( "hostname set to contents of $me");

    return @lines;
}

sub test_each_rbl {
    my $self = shift;
    my %p = validate( @_, {
            'rbls'    => { type=>ARRAYREF },
            %std_opts,
        },
    );

    my $rbls = $p{'rbls'};

    $t_dns ||= Mail::Toaster::DNS->new( toaster => $toaster );

    my @valid_dnsbls;
    foreach my $rbl (@$rbls) {
        if ( ! $rbl ) {
            $log->error("how did a blank RBL make it in here?", fatal=>0);
            next;
        };
        next if ! $t_dns->rbl_test( zone => $rbl );
        push @valid_dnsbls, $rbl;
    }
    return \@valid_dnsbls;
}

sub UpdateVirusBlocks {

    # deprecated function - no longer maintained.

    my $self = shift;
    my %p = validate( @_, { 'ips' => ARRAYREF, %std_opts } );

    my $ips   = $p{'ips'};
    my $time  = $conf->{'qs_block_virus_senders_time'};
    my $relay = $conf->{'smtpd_relay_database'};
    my $vpdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    if ( $relay =~ /^vpopmail_home_dir\/(.*)\.cdb$/ ) {
        $relay = "$vpdir/$1";
    }
    else {
        if ( $relay =~ /^(.*)\.cdb$/ ) { $relay = $1; }
    }
    unless ( -r $relay ) { die "$relay selected but not readable!\n" }

    my @lines;

    my $debug = 0;
    my $in     = 0;
    my $done   = 0;
    my $now    = time;
    my $expire = time + ( $time * 3600 );

    print "now: $now   expire: $expire\n" if $debug;

    my @userlines = $util->file_read( $relay );
  USERLINES: foreach my $line (@userlines) {
        unless ($in) { push @lines, $line }
        if ( $line =~ /^### BEGIN QMAIL SCANNER VIRUS ENTRIES ###/ ) {
            $in = 1;

            for (@$ips) {
                push @lines,
"$_:allow,RBLSMTPD=\"-VIRUS SOURCE: Block will be automatically removed in $time hours: ($expire)\"\n";
            }
            $done++;
            next USERLINES;
        }

        if ( $line =~ /^### END QMAIL SCANNER VIRUS ENTRIES ###/ ) {
            $in = 0;
            push @lines, $line;
            next USERLINES;
        }

        if ($in) {
            my ($timestamp) = $line =~ /\(([0-9]+)\)"$/;
            unless ($timestamp) {
                print "ERROR: malformed line: $line\n" if $debug;
            }

            if ( $now > $timestamp ) {
                print "removing $timestamp\t" if $debug;
            }
            else {
                print "leaving $timestamp\t" if $debug;
                push @lines, $line;
            }
        }
    }

    if ($done) {
        if ($debug) {
            foreach (@lines) { print "$_\n"; };
        }
        $util->file_write( $relay, lines => \@lines );
    }
    else {
        print
"FAILURE: Couldn't find QS section in $relay\n You need to add the following lines as documented in the toaster-watcher.conf and FAQ:

### BEGIN QMAIL SCANNER VIRUS ENTRIES ###
### END QMAIL SCANNER VIRUS ENTRIES ###

";
    }

    my $tcprules = $util->find_bin( "tcprules" );
    $util->syscmd( "$tcprules $vpdir/etc/tcp.smtp.cdb $vpdir/etc/tcp.smtp.tmp "
            . "< $vpdir/etc/tcp.smtp",
    );
    chmod oct('0644'), "$vpdir/etc/tcp.smtp*";
}

sub _memory_explanation {

    my ( $self, $prot, $maxcon ) = @_;
    my ( $sysmb,        $maxsmtpd,   $memorymsg,
        $perconnection, $connectmsg, $connections  );

    warn "\nbuild_${prot}_run: your "
      . "${prot}_max_memory_per_connection and "
      . "${prot}_max_connections settings in toaster-watcher.conf have exceeded your "
      . "${prot}_max_memory setting. I have reduced the maximum concurrent connections "
      . "to $maxcon to compensate. You should fix your settings.\n\n";

    if ( $OSNAME eq "freebsd" ) {
        $sysmb = int( substr( `/sbin/sysctl hw.physmem`, 12 ) / 1024 / 1024 );
        $memorymsg = "Your system has $sysmb MB of physical RAM.  ";
    }
    else {
        $sysmb     = 1024;
        $memorymsg =
          "This example assumes a system with $sysmb MB of physical RAM.";
    }

    $maxsmtpd = int( $sysmb * 0.75 );

    if ( $conf->{'install_mail_filtering'} ) {
        $perconnection = 40;
        $connectmsg    =
          "This is a reasonable value for systems which run filtering.";
    }
    else {
        $perconnection = 15;
        $connectmsg    =
          "This is a reasonable value for systems which do not run filtering.";
    }

    $connections = int( $maxsmtpd / $perconnection );
    $maxsmtpd    = $connections * $perconnection;

    warn <<EOMAXMEM;

These settings control the concurrent connection limit set by tcpserver,
and the per-connection RAM limit set by softlimit.

Here are some suggestions for how to set these options:

$memorymsg

smtpd_max_memory = $maxsmtpd # approximately 75% of RAM

smtpd_max_memory_per_connection = $perconnection
   # $connectmsg

smtpd_max_connections = $connections

If you want to allow more than $connections simultaneous SMTP connections,
you'll either need to lower smtpd_max_memory_per_connection, or raise
smtpd_max_memory.

smtpd_max_memory_per_connection is a VERY important setting, because
softlimit/qmail will start soft-bouncing mail if the smtpd processes
exceed this value, and the number needs to be sufficient to allow for
any virus scanning, filtering, or other processing you have configured
on your toaster.

If you raise smtpd_max_memory over $sysmb MB to allow for more than
$connections incoming SMTP connections, be prepared that in some
situations your smtp processes might use more than $sysmb MB of memory.
In this case, your system will use swap space (virtual memory) to
provide the necessary amount of RAM, and this slows your system down. In
extreme cases, this can result in a denial of service-- your server can
become unusable until the services are stopped.

EOMAXMEM

}

sub _test_smtpd_config_values {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    my ( $fatal, $debug ) = ( $p{'fatal'}, $p{'debug'} );

    my $file = $util->find_config( "toaster.conf" );

    return $log->error( "qmail_dir does not exist as configured in $file" )
        if !-d $conf->{'qmail_dir'};

    # if vpopmail is enabled, make sure the vpopmail home dir exists
    return $log->error( "vpopmail_home_dir does not exist as configured in $file" )
        if ( $conf->{'install_vpopmail'} && !-d $conf->{'vpopmail_home_dir'} );

    # make sure qmail_supervise is set and is not a directory
    my $qsuper = $conf->{'qmail_supervise'};
    return $log->error( "conf->qmail_supervise is not set!" )
        if ( !defined $qsuper || !$qsuper );

    # make sure qmail_supervise is not a directory
    return $log->error( "qmail_supervise ($qsuper) is not a directory!" )
        if !-d $qsuper;

    return 1;
}

sub _smtp_sanity_tests {
    my $qdir = $conf->{'qmail_dir'} || "/var/qmail";

    return "if [ ! -f $qdir/control/rcpthosts ]; then
	echo \"No $qdir/control/rcpthosts!\"
	echo \"Refusing to start SMTP listener because it'll create an open relay\"
	exit 1
fi
";

}

sub _set_checkpasswd_bin {
    my $self = shift;
    my %p = validate( @_, { 'prot' => { type=>SCALAR } } );

    my $prot = $p{'prot'};

    $log->audit( "  setting checkpasswd for protocol: $prot");

    my $vdir = $conf->{'vpopmail_home_dir'}
        or return $log->error( "vpopmail_home_dir not set in $conf" );

    my $prot_dir = $prot . "_checkpasswd_bin";
    $log->audit("  getting protocol directory for $prot from conf->$prot_dir");

    my $chkpass;
    $chkpass = $conf->{$prot_dir} or do {
        print "WARN: $prot_dir is not set in toaster-watcher.conf!\n";
        $chkpass = "$vdir/bin/vchkpw";
    };

    $log->audit( "  using $chkpass for checkpasswd");

    # vpopmail_home_dir is an alias, expand it
    if ( $chkpass =~ /^vpopmail_home_dir\/(.*)$/ ) {
        $chkpass = "$vdir/$1";
        $log->audit( "  expanded to $chkpass" );
    }

    return $log->error( "chkpass program $chkpass selected but not executable!")
        unless -x $chkpass;

    return "$chkpass ";
}


1;
__END__


=head1 NAME

Mail::Toaster:::Qmail - Qmail specific functions


=head1 SYNOPSIS

    use Mail::Toaster::Qmail;
    my $qmail = Mail::Toaster::Qmail->new();

    $qmail->install();

Mail::Toaster::Qmail is a module of Mail::Toaster. It contains methods for use with qmail, like starting and stopping the deamons, installing qmail, checking the contents of config files, etc. Nearly all functionality  contained herein is accessed via toaster_setup.pl.

See http://mail-toaster.org/ for details.


=head1 DESCRIPTION

This module has all sorts of goodies, the most useful of which are the build_????_run modules which build your qmail control files for you. See the METHODS section for more details.


=head1 SUBROUTINES/METHODS

An object of this class represents a means for interacting with qmail. There are functions for starting, stopping, installing, generating run-time config files, building ssl temp keys, testing functionality, monitoring processes, and training your spam filters.

=over 8

=item new

To use any of the methods following, you need to create a qmail object:

	use Mail::Toaster::Qmail;
	my $qmail = Mail::Toaster::Qmail->new();



=item build_pop3_run

	$qmail->build_pop3_run() ? print "success" : print "failed";

Generate a supervise run file for qmail-pop3d. $file is the location of the file it's going to generate. I typically use it like this:

  $qmail->build_pop3_run()

If it succeeds in building the file, it will install it. You should restart the service after installing a new run file.

 arguments required:
    file - the temp file to construct

 arguments optional:
    debug
    fatal

 results:
    0 - failure
    1 - success


=item install_qmail_control_log_files

	$qmail->install_qmail_control_log_files();

Installs the files that control your supervised processes logging. Typically this consists of qmail-smtpd, qmail-send, and qmail-pop3d. The generated files are:

 arguments optional:
    prots - an arrayref list of protocols to build run files for.
           Defaults to [pop3,smtp,send,submit]
	debug
	fatal

 Results:
    qmail_supervise/pop3/log/run
    qmail_supervise/smtp/log/run
    qmail_supervise/send/log/run
    qmail_supervise/submit/log/run


=item install_supervise_run

Installs a new supervise/run file for a supervised service. It first builds a new file, then compares it to the existing one and installs the new file if it has changed. It optionally notifies the admin.

  $qmail->build_smtp_run()

 arguments required:
 arguments optional:
 result:
    1 - success
    0 - error

=item netqmail_virgin

Builds and installs a pristine netqmail. This is necessary to resolve a chicken and egg problem. You can't apply the toaster patches (specifically chkuser) against netqmail until vpopmail is installed, and you can't install vpopmail without qmail being installed. After installing this, and then vpopmail, you can rebuild netqmail with the toaster patches.

 Usage:
   $qmail->netqmail_virgin( debug=>1);

 arguments optional:
    package  - the name of the programs tarball, defaults to "netqmail-1.05"
    debug
    fatal

 result:
    qmail installed.


=item send_start

	$qmail->send_start() - Start up the qmail-send process.

After starting up qmail-send, we verify that it's running before returning.


=item send_stop

  $qmail->send_stop()

Use send_stop to quit the qmail-send process. It will send qmail-send the TERM signal and then wait until it's shut down before returning. If qmail-send fails to shut down within 100 seconds, then we force kill it, causing it to abort any outbound SMTP sessions that are active. This is safe, as qmail will attempt to deliver them again, and again until it succeeds.


=item  restart

  $qmail->restart( prot=>"smtp")

Use restart to restart a supervised qmail process. It will send the TERM signal causing it to exit. It will restart immediately because it's supervised.


=item  supervised_hostname_qmail

Gets/sets the qmail hostname for use in supervise/run scripts. It dynamically creates and returns those hostname portion of said run file such as this one based on the settings in $conf.

 arguments required:
    prot - the protocol name (pop3, smtp, submit, send)

 result:
   an array representing the hostname setting portion of the shell script */run.

 Example result:

	LOCAL=`head -1 /var/qmail/control/me`
	if [ -z "$LOCAL" ]; then
		echo ERROR: /var/service/pop3/run tried reading your hostname from /var/qmail/control/me and failed!
		exit 1
	fi


=item  test_each_rbl

	my $available = $qmail->test_each_rbl( rbls=>$selected, debug=>1 );

We get a list of RBL's in an arrayref, run some tests on them to determine if they are working correctly, and pass back the working ones in an arrayref.

 arguments required:
   rbls - an arrayref with a list of RBL zones

 arguments optional:
   debug - print status messages

 result:
   an arrayref with the list of the correctly functioning RBLs.


=item  build_send_run

  $qmail->build_send_run() ? print "success";

build_send_run generates a supervise run file for qmail-send. $file is the location of the file it's going to generate.

  $qmail->build_send_run() and
        $qmail->restart( prot=>'send');

If it succeeds in building the file, it will install it. You can optionally restart qmail after installing a new run file.

 arguments required:
   file - the temp file to construct

 arguments optional:
   debug
   fatal

 results:
   0 - failure
   1 - success


=item  build_smtp_run

  if ( $qmail->build_smtp_run( file=>$file) ) { print "success" };

Generate a supervise run file for qmail-smtpd. $file is the location of the file it's going to generate.

  $qmail->build_smtp_run()

If it succeeds in building the file, it will install it. You can optionally restart the service after installing a new run file.

 arguments required:
    file - the temp file to construct

 arguments optional:
    debug
    fatal

 results:
    0 - failure
    1 - success


=item  build_submit_run

  if ( $qmail->build_submit_run( file=>$file ) ) { print "success"};

Generate a supervise run file for qmail-smtpd running on submit. $file is the location of the file it's going to generate.

  $qmail->build_submit_run( file=>$file );

If it succeeds in building the file, it will install it. You can optionally restart the service after installing a new run file.

 arguments required:
    file - the temp file to construct

 arguments optional:
    debug
    fatal

 results:
    0 - failure
    1 - success


=item  check_control

Verify the existence of the qmail control directory (typically /var/qmail/control).

 arguments required:
    dir - the directory whose existence we test for

 arguments optional:
    debug
    fatal

 results:
    0 - failure
    1 - success


=item  check_rcpthosts

  $qmail->check_rcpthosts($qmaildir);

Checks the control/rcpthosts file and compares its contents to users/assign. Any zones that are in users/assign but not in control/rcpthosts or control/morercpthosts will be presented as a list and you will be expected to add them to morercpthosts.

 arguments required:
    none

 arguments optional:
    dir - defaults to /var/qmail

 result
    instructions to repair any problem discovered.


=item  config

Qmail is nice because it is quite easy to configure. Just edit files and put the right values in them. However, many find that a problem because it is not so easy to always know the syntax for what goes in every file, and exactly where that file might be. This sub takes your values from toaster-watcher.conf and puts them where they need to be. It modifies the following files:

   /var/qmail/control/concurrencyremote
   /var/qmail/control/me
   /var/qmail/control/mfcheck
   /var/qmail/control/spfbehavior
   /var/qmail/control/tarpitcount
   /var/qmail/control/tarpitdelay
   /var/qmail/control/sql
   /var/qmail/control/locals
   /var/qmail/alias/.qmail-postmaster
   /var/qmail/alias/.qmail-root
   /var/qmail/alias/.qmail-mailer-daemon

  FreeBSD specific:
   /etc/rc.conf
   /etc/mail/mailer.conf
   /etc/make.conf

You should not manually edit these files. Instead, make changes in toaster-watcher.conf and allow it to keep them updated.

 Usage:
   $qmail->config();

 arguments optional:
    debug
    fatal

 results:
    0 - failure
    1 - success


=item  control_create

To make managing qmail a bit easier, we install a control script that allows the administrator to interact with the running qmail processes.

 Usage:
   $qmail->control_create();

 Sample Output
    /usr/local/sbin/qmail {restart|doqueue|flush|reload|stat|pause|cont|cdb|queue|help}

    # qmail help
	        pause -- temporarily stops mail service (connections accepted, nothing leaves)
	        cont -- continues paused mail service
	        stat -- displays status of mail service
	        cdb -- rebuild the cdb files (tcp.smtp, users, simcontrol)
	        restart -- stops and restarts smtp, sends qmail-send a TERM & restarts it
	        doqueue -- sends qmail-send ALRM, scheduling queued messages for delivery
	        reload -- sends qmail-send HUP, rereading locals and virtualdomains
	        queue -- shows status of queue
	        alrm -- same as doqueue
	        hup -- same as reload

 arguments optional:
    debug
    fatal

 results:
    0 - failure
    1 - success


=item  get_domains_from_assign

Fetch a list of domains from the qmaildir/users/assign file.

  $qmail->get_domains_from_assign( assign=>$assign, debug=>$debug );

 arguments required:
    none

 arguments optional:
    assign - the path to the assign file (default: /var/qmail/users/assign)
    debug
    match - field to match (dom, uid, dir)
    value - the pattern to  match

 results:
    an array


=item  get_list_of_rbls

Gets passed a hashref of values and extracts all the RBLs that are enabled in the file. See the toaster-watcher.conf file and the rbl_ settings therein for the format expected. See also the t/Qmail.t for examples of usage.

  my $r = $qmail->get_list_of_rbls( debug => $debug );

 arguments optional:
    debug

 result:
   an arrayref of values


=item  get_list_of_rwls

  my $selected = $qmail->get_list_of_rwls( debug=>$debug);

Here we collect a list of the RWLs from the configuration file that gets passed to us and return them.

 arguments optional:
   debug
   fatal

 result:
   an arrayref with the enabled rwls.


=item  install_qmail

Builds qmail and installs qmail with patches (based on your settings in toaster-watcher.conf), installs the SSL certs, adjusts the permissions of several files that need it.

 Usage:
   $qmail->install_qmail( debug=>1);

 arguments optional:
     package  - the name of the programs tarball, defaults to "qmail-1.03"
     debug
     fatal

 result:
     one kick a55 mail server.

Patch info is here: http://mail-toaster.org/patches/


=item  install_qmail_control_files

When qmail is first installed, it needs some supervised run files to run under tcpserver and daemontools. This sub generates the qmail/supervise/*/run files based on your settings. Perpetual updates are performed by toaster-watcher.pl.

  $qmail->install_qmail_control_files();

 arguments optional:

 result:
    qmail_supervise/pop3/run
    qmail_supervise/smtp/run
    qmail_supervise/send/run
    qmail_supervise/submit/run



=back

=head1 EXAMPLES

Working examples of the usage of these methods can be found in  t/Qmail.t, toaster-watcher.pl, and toaster_setup.pl.


=head1 DIAGNOSTICS

All functions include debugging output which is enabled by default. You can disable the status/debugging messages by calling the functions with debug=>0. The default behavior is to die upon errors. That too can be overriddent by setting fatal=>0. See the tests in t/Qmail.t for code examples.


  #=head1 COMMON USAGE MISTAKES



=head1 CONFIGURATION AND ENVIRONMENT

Nearly all of the configuration options can be manipulated by setting the
appropriate values in toaster-watcher.conf. After making changes in toaster-watcher.conf,
you can run toaster-watcher.pl and your changes will propagate immediately,
or simply wait a few minutes for them to take effect.


=head1 DEPENDENCIES

A list of all the other modules that this module relies upon, including any
restrictions on versions, and an indication whether these required modules are
part of the standard Perl distribution, part of the module's distribution,
or must be installed separately.

    Params::Validate        - from CPAN
    Mail::Toaster           - with package


=head1 BUGS AND LIMITATIONS

None known. When found, report to author.
Patches are welcome.


=head1 TODO


=head1 SEE ALSO

  Mail::Toaster
  Mail::Toaster::Conf
  toaster.conf
  toaster-watcher.conf

 http://mail-toaster.org/


=head1 AUTHOR

Matt Simerson  (matt@tnpi.net)


=head1 ACKNOWLEDGEMENTS


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2004-2012 The Network People, Inc. (info@tnpi.net). All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
