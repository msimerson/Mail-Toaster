package Mail::Toaster::Setup::Vpopmail;
use strict;
use warnings;

our $VERSION = '5.44';

use Carp;
use English '-no_match_vars';
use Params::Validate ':all';

use lib 'lib';
use parent 'Mail::Toaster::Base';

sub install {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( !$self->conf->{'install_vpopmail'} ) {
        $self->audit( "vpopmail: installing, skipping (disabled)" );
        return;
    }

    my $version = $self->conf->{install_vpopmail} || '5.4.33';

    if ( $OSNAME eq "freebsd" ) {
    # always install the port version, so subsequent ports will
    # find it registered in the ports db.
        $self->install_freebsd_port;
    }

    if ( $version ne 'port' ) {
        $self->install_from_source( %p );
    };

    return $self->post_install;
};

sub install_freebsd_port {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $conf = $self->conf;
    my $version = $conf->{'install_vpopmail'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my @defs = 'LOGLEVEL="p"';

    my $learn = $conf->{vpopmail_learn_passwords}     ? 'SET' : 'UNSET';
    my $ip_alias = $conf->{vpopmail_ip_alias_domains} ? 'SET' : 'UNSET';
    my $qmail_ext= $conf->{vpopmail_qmail_ext}        ? 'SET' : 'UNSET';
    my $single_dom=$conf->{vpopmail_disable_many_domains} ? 'SET' : 'UNSET';
    my $maildrop = $conf->{vpopmail_maildrop}         ? 'SET' : 'UNSET';
    my $mysql    = $conf->{'vpopmail_mysql'}          ? 'SET' : 'UNSET';
    my $roaming  = $conf->{vpopmail_roaming_users}    ? 'SET' : 'UNSET';
    my $mysql_rep= my $mysql_lim = my $sql_log = my $valias = 'UNSET';
    my $auth_log = $conf->{vpopmail_auth_logging}     ? 'SET' : 'UNSET';

    if ( $roaming eq 'SET' && $conf->{vpopmail_relay_clear_minutes} ) {
        push @defs, 'RELAYCLEAR='.$conf->{vpopmail_relay_clear_minutes};
    };

    if ( $mysql eq 'SET' ) {
        $self->error( "vpopmail_mysql is enabled but install_mysql is not. Please correct your settings" ) if ! $conf->{install_mysql};
        $mysql_rep = 'SET' if $conf->{vpopmail_mysql_replication};
        $mysql_lim = 'SET' if $conf->{vpopmail_mysql_limits};
        $valias    = 'SET' if $conf->{vpopmail_valias};
        $sql_log   = 'SET' if $conf->{vpopmail_mysql_logging};
    };

    $self->freebsd->install_port( 'vpopmail',
        flags => join( ',', @defs ),
        options => "# installed by Mail::Toaster
# Options for vpopmail-5.4.32_3
_OPTIONS_READ=vpopmail-5.4.32_3
_FILE_COMPLETE_OPTIONS_LIST=AUTH_LOG CLEAR_PASSWD DOCS DOMAIN_QUOTAS FILE_LOCKING FILE_SYNC FPIC IP_ALIAS LDAP LDAP_SASL LEARN_PASSWORDS MAILDROP MD5_PASSWORDS MYSQL MYSQL_LIMITS MYSQL_REPLICATION ONCHANGE_SCRIPT ORACLE PASSWD PGSQL QMAIL_EXT ROAMING SEEKABLE SINGLE_DOMAIN SMTP_AUTH_PATCH SPAMASSASSIN SPAMFOLDER SQL_LOG SQL_LOG_TRIM SUID_VCHKPW SYBASE USERS_BIG_DIR VALIAS
OPTIONS_FILE_$auth_log+=AUTH_LOG
OPTIONS_FILE_SET+=CLEAR_PASSWD
OPTIONS_FILE_SET+=DOCS
OPTIONS_FILE_UNSET+=DOMAIN_QUOTAS
OPTIONS_FILE_SET+=FILE_LOCKING
OPTIONS_FILE_UNSET+=FILE_SYNC
OPTIONS_FILE_SET+=FPIC
OPTIONS_FILE_$ip_alias+=IP_ALIAS
OPTIONS_FILE_UNSET+=LDAP
OPTIONS_FILE_UNSET+=LDAP_SASL
OPTIONS_FILE_$learn+=LEARN_PASSWORDS
OPTIONS_FILE_$maildrop+=MAILDROP
OPTIONS_FILE_SET+=MD5_PASSWORDS
OPTIONS_FILE_$mysql+=MYSQL
OPTIONS_FILE_$mysql_lim+=MYSQL_LIMITS
OPTIONS_FILE_$mysql_rep+=MYSQL_REPLICATION
OPTIONS_FILE_UNSET+=ONCHANGE_SCRIPT
OPTIONS_FILE_UNSET+=ORACLE
OPTIONS_FILE_UNSET+=PASSWD
OPTIONS_FILE_UNSET+=PGSQL
OPTIONS_FILE_$qmail_ext+=QMAIL_EXT
OPTIONS_FILE_$roaming+=ROAMING
OPTIONS_FILE_SET+=SEEKABLE
OPTIONS_FILE_$single_dom+=SINGLE_DOMAIN
OPTIONS_FILE_UNSET+=SMTP_AUTH_PATCH
OPTIONS_FILE_UNSET+=SPAMASSASSIN
OPTIONS_FILE_UNSET+=SPAMFOLDER
OPTIONS_FILE_$sql_log+=SQL_LOG
OPTIONS_FILE_UNSET+=SQL_LOG_TRIM
OPTIONS_FILE_UNSET+=SUID_VCHKPW
OPTIONS_FILE_UNSET+=SYBASE
OPTIONS_FILE_SET+=USERS_BIG_DIR
OPTIONS_FILE_$valias+=VALIAS
",
    ) or return;

    my $vpopdir = $self->get_vpop_dir;
    my $docroot = $self->conf->{'toaster_http_docs'};

    # add a symlink so docs are web browsable
    if ( -d $docroot && ! -e "$docroot/vpopmail" ) {
        if ( -d "$vpopdir/doc/man_html" ) {
            symlink "$vpopdir/doc/man_html", "$docroot/vpopmail";
        }
    }
}

sub install_from_source {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $conf = $self->conf;
    my $version = $conf->{'install_vpopmail'} || "5.4.33";
    my $package = "vpopmail-$version";
    my $vpopdir = $self->get_vpop_dir;

    $self->create_user();   # add the vpopmail user/group
    my $uid = getpwnam( $conf->{'vpopmail_user'} || "vpopmail" );
    my $gid = getgrnam( $conf->{'vpopmail_group'} || "vchkpw"  );

    my $installed = $self->installed_version();

    if ( $installed && $installed eq $version ) {
        $self->util->yes_or_no(
                "Do you want to reinstall vpopmail with the same version?",
            timeout => 60,
            ) or do {
            $self->post_install();
            return 1;
        };
    }

    my $conf_args;
    foreach ( qw/ rebuild_tcpserver_file ip_alias_domains valias mysql_logging
        qmail_ext learn_passwords mysql / ) {
        my $mt_setting = 'vpopmail_' . $_;
        my $conf_arg = "--enable-$_";
        $conf_arg =~ s/_/-/g;
        my $r = $conf->{$mt_setting} ? 'yes' : 'no';
        $conf_args .= " $conf_arg=$r";
        print "$conf_arg=$r\n";
    };

    if ( ! $self->is_newer( min => "5.3.30", cur => $version ) ) {
        if ( defined $conf->{'vpopmail_default_quota'} ) {
            $conf_args .=
              " --enable-defaultquota=".$conf->{'vpopmail_default_quota'};
            print "default quota: ".$conf->{'vpopmail_default_quota'}."\n";
        }
        else {
            $conf_args .= " --enable-defaultquota=100000000S,10000C";
            print "default quota: 100000000S,10000C\n";
        }
    }

    $conf_args .= $self->roaming_users();

    if ( $OSNAME eq "darwin" && !-d "/usr/local/mysql"
        && -d "/opt/local/include/mysql" ) {
        $conf_args .= " --enable-incdir=/opt/local/include/mysql";
        $conf_args .= " --enable-libdir=/opt/local/lib/mysql";
    }

    my $tcprules = $self->util->find_bin( "tcprules", verbose=>0 );
    $conf_args .= " --enable-tcprules-prog=$tcprules";

    my $src = $conf->{'toaster_src_dir'} || "/usr/local/src";

    $self->util->cwd_source_dir( "$src/mail" );

    my $tarball = "$package.tar.gz";

    # save having to download it again
    if ( -e "/usr/ports/distfiles/vpopmail-$version.tar.gz" ) {
        copy(
            "/usr/ports/distfiles/vpopmail-$version.tar.gz",
            "/usr/local/src/mail/"
        );
    }

    $self->util->sources_get(
        'package' => $package,
        site      => "http://" . $conf->{'toaster_sf_mirror'},
        path      => "/vpopmail",
    );

    if ( -d $package ) {
        $self->util->source_warning(
                package => $package,
                src     => "$src/mail",
            ) or return;
    }

    $self->util->extract_archive( $tarball ) or die;

    if ( $conf->{vpopmail_mysql} ) {
        $conf_args .= $self->mysql_options();
    };
    $conf_args .= $self->logging();
    $conf_args .= $self->default_domain($version);
    $conf_args .= $self->etc_passwd();

    # in case someone updates their toaster and not their config file
    if ( defined $conf->{'vpopmail_qmail_ext'}
              && $conf->{'vpopmail_qmail_ext'} ) {
        $conf_args .= " --enable-qmail-ext=y";
        print "qmail extensions: yes\n";
    }
    if ( defined $conf->{'vpopmail_maildrop'} ) {
        $conf_args .= " --enable-maildrop=y";
    };

    print "fixup for longer passwords\n";
    system "sed -i -Ee '/^pw_clear_passwd char(/s/16/128/' vmysql.h";
    system "sed -i -Ee '/^pw_passwd char(/s/40/128/' vmysql.h";

    chdir($package);
    print "running configure with $conf_args\n\n";

    $self->util->syscmd( "./configure $conf_args", verbose => 0 );
    $self->util->syscmd( "make",                   verbose => 0 );
    $self->util->syscmd( "make install-strip",     verbose => 0 );

    if ( -e "vlimits.h" ) {
        # this was for a bug in vpopmail 5.4.?(1-2) installer
        $self->util->syscmd( "cp vlimits.h $vpopdir/include/", verbose => 0);
    }

    return 1;
}

sub default_domain {
    my $self = shift;
    my $version = shift;

    my $default_domain;

    if ( defined $self->conf->{'vpopmail_default_domain'} ) {
        $default_domain = $self->conf->{'vpopmail_default_domain'};
    }
    else {
        $self->util->yes_or_no( "Do you want to use a default domain? " ) or do {
            print "default domain: NONE SELECTED.\n";
            return '';
        };

        $default_domain = $self->util->ask("your default domain");
    };

    if ( ! $default_domain ) {
        print "default domain: NONE SELECTED.\n";
        return '';
    };

    if ( $self->is_newer( min => "5.3.22", cur => $version ) ) {
        my $vpopetc = $self->get_vpop_etc;
        $self->util->file_write( "$vpopetc/defaultdomain",
            lines => [ $default_domain ],
            verbose => 0,
        );

        $self->util->chown( "$vpopetc/defaultdomain",
            uid  => $self->conf->{'vpopmail_user'}  || "vpopmail",
            gid  => $self->conf->{'vpopmail_group'} || "vchkpw",
        );

        return '';
    }

    print "default domain: $default_domain\n";
    return " --enable-default-domain=$default_domain";
};

sub vpopmail_etc {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $vetc = $self->get_vpop_etc;

    mkpath( $vetc, oct('0775') ) if ! -d $vetc;

    if ( -d $vetc ) {
        print "$vetc already exists.\n";
    }
    else {
        print "creating $vetc\n";
        mkdir( $vetc, oct('0775') ) or carp "failed to create $vetc: $!\n";
    }

    $self->setup->tcp_smtp( etc_dir => $vetc );
    $self->setup->tcp_smtp_cdb( etc_dir => $vetc );
}

sub etc_passwd {
    my $self = shift;

    unless ( defined $self->conf->{'vpopmail_etc_passwd'} ) {
        print "\t\t CAUTION!!  CAUTION!!

    The system user account feature is NOT compatible with qmail-smtpd-chkusr.
    If you selected that option in the qmail build, you should not answer
    yes here. If you are unsure, select (n).\n";

        if ( $self->util->yes_or_no( "Do system users (/etc/passwd) get mail? (n) ")) {
            print "system password accounts: yes\n";
            return " --enable-passwd";
        }
    }

    if ( $self->conf->{'vpopmail_etc_passwd'} ) {
        print "system password accounts: yes\n";
        return " --enable-passwd";
    }

    print "system password accounts: no\n";
};

sub get_vpop_etc {
    my $self = shift;
    my $base = $self->get_vpop_dir;
    return "$base/etc";
};

sub get_vpop_dir {
    my $self = shift;
    return $self->{conf}{vpopmail_home_dir} || '/usr/local/vpopmail';
};

sub installed_version {
    my $self = shift;

    my $vpopdir = $self->get_vpop_dir;
    return if ! -x "$vpopdir/bin/vpasswd";

    my $installed = `$vpopdir/bin/vpasswd -v | head -1 | cut -f2 -d" "`;
    chop $installed;
    $self->alert( "vpopmail version $installed installed." );
    return $installed;
}

sub logging {
    my $self = shift;

    my $conf = $self->conf;
    if ( defined $conf->{vpopmail_logging} && $conf->{vpopmail_logging} ) {
        if ( $conf->{'vpopmail_logging_verbose'} ) {
            print "logging: verbose with failed passwords\n";
            return " --enable-logging=v";
        }

        print "logging: everything\n";
        return " --enable-logging=y";
    }

    if ( ! $self->util->yes_or_no( "Do you want logging enabled? (y) ")) {
        return " --enable-logging=p";
    };

    if ( $self->util->yes_or_no( "Do you want verbose logging? (y) ")) {
        print "logging: verbose\n";
        return " --enable-logging=v";
    }

    print "logging: verbose with failed passwords\n";
    return " --enable-logging=p";
};

sub post_install {
    my $self = shift;
    $self->vpopmail_etc;
    $self->mysql_privs;
    $self->util->install_module( "vpopmail" ) if $self->{conf}{install_ezmlm_cgi};
    print "vpopmail: complete.\n";
    return 1;
};

sub roaming_users {
    my $self = shift;

    my $roaming = $self->conf->{'vpopmail_roaming_users'};

    if ( defined $roaming && !$roaming ) {
        print "roaming users: no\n";
        return " --enable-roaming-users=n";
    }

    # default to enabled
    if ( !defined $self->conf->{'vpopmail_roaming_users'} ) {
        print "roaming users: value not set?!\n";
    }

    print "roaming users: yes\n";

    my $min = $self->conf->{'vpopmail_relay_clear_minutes'};
    if ( $min && $min ne 180 ) {
        print "roaming user minutes: $min\n";
        return " --enable-roaming-users=y" .
            " --enable-relay-clear-minutes=$min";
    };
    return " --enable-roaming-users=y";
};

sub test {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok};

    print "do vpopmail directories exist...\n";
    my $vpdir = $self->conf->{'vpopmail_home_dir'};
    foreach ( "", "bin", "domains", "etc/", "include", "lib" ) {
        $self->setup->test->pretty("  $vpdir/$_", -d "$vpdir/$_" );
    }

    print "checking vpopmail binaries...\n";
    foreach (
        qw/
        clearopensmtp   vaddaliasdomain     vadddomain
        valias          vadduser            vchkpw
        vchangepw       vconvert            vdeldomain
        vdelivermail    vdeloldusers        vdeluser
        vdominfo        vipmap              vkill
        vmkpasswd       vmoddomlimits       vmoduser
        vpasswd         vpopbull            vqmaillocal
        vsetuserquota   vuserinfo   /
      )
    {
        $self->setup->test->pretty("  $_", -x "$vpdir/bin/$_" );
    }

    print "do vpopmail libs exist...\n";
    foreach ("$vpdir/lib/libvpopmail.a") {
        $self->setup->test->pretty("  $_", -e $_ );
    }

    print "do vpopmail includes exist...\n";
    foreach (qw/ config.h vauth.h vlimits.h vpopmail.h vpopmail_config.h /) {
        $self->setup->test->pretty("  include/$_", -e "$vpdir/include/$_" );
    }

    print "checking vpopmail etc files...\n";
    my @vpetc = qw/ inc_deps lib_deps tcp.smtp tcp.smtp.cdb vlimits.default /;
    push @vpetc, 'vpopmail.mysql' if $self->conf->{'vpopmail_mysql'};

    foreach ( @vpetc ) {
        $self->setup->test->pretty("  $_", (-e "$vpdir/etc/$_" && -s "$vpdir/etc/$_" ));
    }
}

sub create_user {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $vpopdir = $self->get_vpop_dir;
    my $vpuser  = $self->conf->{vpopmail_user}  || 'vpopmail';
    my $vpgroup = $self->conf->{vpopmail_group} || 'vchkpw';

    my $uid = getpwnam($vpuser);
    my $gid = getgrnam($vpgroup);

    if ( !$uid || !$gid ) {
        $self->group_add( $vpgroup, "89" );
        $self->user_add( $vpuser, 89, 89, homedir => $vpopdir );
    }

    $uid = getpwnam($vpuser);
    $gid = getgrnam($vpgroup);

    return $self->error( "failed to add vpopmail user or group!")
        if ( !$uid || !$gid );

    return 1;
}

sub mysql_options {
    my $self = shift;
    my $mysql_repl = $self->conf->{vpopmail_mysql_replication};
    my $my_write   = $self->conf->{vpopmail_mysql_repl_master} || 'localhost';
    my $db         = $self->conf->{vpopmail_mysql_database} || 'vpopmail';

    my $opts;
    if ( $self->conf->{vpopmail_mysql_limits} ) {
        print "mysql qmailadmin limits: yes\n";
        $opts .= " --enable-mysql-limits=y";
    }

    if ( $mysql_repl ) {
        $opts .= " --enable-mysql-replication=y";
        print "mysql replication: yes\n";
        print "      replication master: $my_write\n";
    }

    if ( $self->conf->{vpopmail_disable_many_domains} ) {
        $opts .= " --disable-many-domains";
    }

    return $opts;
}

sub mysql_privs {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    if ( !$self->conf->{'vpopmail_mysql'} ) {
        print "vpopmail mysql_privs: mysql support not selected\n";
        return;
    }

    my $mysql_repl    = $self->conf->{vpopmail_mysql_replication};
    my $my_write      = $self->conf->{vpopmail_mysql_repl_master} || 'localhost';
    my $my_write_port = $self->conf->{vpopmail_mysql_repl_master_port} || 3306;
    my $my_read       = $self->conf->{vpopmail_mysql_repl_slave}  || 'localhost';
    my $my_read_port  = $self->conf->{vpopmail_mysql_repl_slave_port} || 3306;
    my $db            = $self->conf->{vpopmail_mysql_database} || 'vpopmail';

    my $user = $self->conf->{'vpopmail_mysql_user'} || $self->conf->{vpopmail_mysql_repl_user};
    my $pass = $self->conf->{'vpopmail_mysql_pass'} || $self->conf->{vpopmail_mysql_repl_pass};

    my $vpopdir = $self->get_vpop_dir;

    my @lines = "$my_read|0|$user|$pass|$db";
    if ($mysql_repl) {
        push @lines, "$my_write|$my_write_port|$user|$pass|$db";
    }
    else {
        push @lines, "$my_read|$my_read_port|$user|$pass|$db";
    }

    $self->util->file_write( "$vpopdir/etc/vpopmail.mysql",
        lines => \@lines,
        verbose => 1,
    );

    my $dot = $self->mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 )
        || { user => $user, pass => $pass, host => $my_write, db => $db };

    my ( $dbh, $dsn, $drh ) = $self->mysql->connect( $dot, 1 );
    if ( !$dbh ) {
        $dot = { user => 'root', pass => '', host => $my_write };
        ( $dbh, $dsn, $drh ) = $self->mysql->connect( $dot, 1 );
    };

    if ( !$dbh ) {
        print <<"EOMYSQLGRANT";

        WARNING: I couldn't connect to your database server!  If this is a new install,
        you will need to connect to your database server and run this command manually:

        mysql -u root -h $my_write -p
        CREATE DATABASE $db;
        GRANT ALL PRIVILEGES ON $db.* TO $user\@'$my_write' IDENTIFIED BY '$pass';
        use $db;
        CREATE TABLE relay ( ip_addr char(18) NOT NULL default '',
          timestamp char(12) default NULL, name char(64) default NULL,
          PRIMARY KEY (ip_addr)) PACK_KEYS=1;
        ALTER TABLE vpopmail MODIFY pw_clear_passwd VARCHAR(128);
        ALTER TABLE vpopmail MODIFY pw_passwd VARCHAR(128);
        quit;

        If this is an upgrade and you already use MySQL authentication,
        then you can safely ignore this warning.

EOMYSQLGRANT
        return;
    }

    my $query = "use $db";
    my $sth = $self->mysql->query( $dbh, $query, 1 );
    if ( !$sth->errstr ) {
        $self->audit( "vpopmail: database setup, ok (exists)" );
        $sth->finish;
        return 1;
    }

    print "vpopmail: no vpopmail database, creating it now...\n";
    $query = "CREATE DATABASE $db";
    $sth   = $self->mysql->query( $dbh, $query );

    print "vpopmail: granting privileges to $user\n";
    $query =
      "GRANT ALL PRIVILEGES ON $db.* TO $user\@'$my_write' IDENTIFIED BY '$pass'";
    $sth = $self->mysql->query( $dbh, $query );

    print "vpopmail: creating the relay table.\n";
    $query = "CREATE TABLE $db.relay ( ip_addr char(18) NOT NULL default '', timestamp char(12) default NULL, name char(64) default NULL, PRIMARY KEY (ip_addr)) PACK_KEYS=1";
    $sth = $self->mysql->query( $dbh, $query );
    $self->audit( "vpopmail: databases created, ok" );
    $sth = $self->mysql->query( $dbh, "ALTER TABLE vpopmail MODIFY pw_clear_passwd VARCHAR(128)" );
    $sth = $self->mysql->query( $dbh, "ALTER TABLE vpopmail MODIFY pw_passwd VARCHAR(128)" );

    $sth->finish;

    return 1;
}

1;
