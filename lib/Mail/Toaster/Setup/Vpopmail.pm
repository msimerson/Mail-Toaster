package Mail::Toaster::Setup::Vpopmail;

use strict;
use warnings;

our $VERSION = '5.50';

use Carp;
use English qw( -no_match_vars );
use Params::Validate qw( :all );

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

    my $version = $self->conf->{'install_vpopmail'} || "5.4.33";

    if ( $OSNAME eq "freebsd" && $version eq 'port' ) {
        return 1 if $self->freebsd->is_port_installed( "vpopmail", debug=>1 );

        $self->install_freebsd_port();
        return 1 if $self->freebsd->is_port_installed( "vpopmail", debug=>1 );
    };

    return $self->install_from_source( %p );
};

sub install_freebsd_port {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    # we install the port version regardless of whether it is selected.
    # This is because later apps (like courier) that we want to install
    # from ports require it to be registered in the ports db

    my $version = $self->conf->{'install_vpopmail'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my @defs = "WITH_CLEAR_PASSWD=yes";
    push @defs, "WITH_LEARN_PASSWORDS=yes" if $self->conf->{vpopmail_learn_passwords};
    push @defs, "WITH_IP_ALIAS=yes" if $self->conf->{vpopmail_ip_alias_domains};
    push @defs, "WITH_QMAIL_EXT=yes" if $self->conf->{vpopmail_qmail_ext};
    push @defs, "WITH_SINGLE_DOMAIN=yes" if $self->conf->{vpopmail_disable_many_domains};
    push @defs, "WITH_MAILDROP=yes" if $self->conf->{vpopmail_maildrop};
    push @defs, 'LOGLEVEL="p"';

    if ( $self->conf->{'vpopmail_mysql'} ) {
        $self->error( "vpopmail_mysql is enabled by install_mysql is not. Please correct your settings" ) if ! $self->conf->{install_mysql};
        push @defs, "WITH_MYSQL=yes";
        push @defs, "WITH_MYSQL_REPLICATION=yes" if $self->conf->{vpopmail_mysql_replication};
        push @defs, "WITH_MYSQL_LIMITS=yes" if $self->conf->{vpopmail_mysql_limits};
        push @defs, 'WITH_VALIAS=yes' if $self->conf->{vpopmail_valias};
    };

    return if ! $self->freebsd->install_port( "vpopmail", flags => join( ",", @defs ),);

    # add a symlink so docs are web browsable
    my $vpopdir = $self->conf->{'vpopmail_home_dir'};
    my $docroot = $self->conf->{'toaster_http_docs'};

    if ( ! -e "$docroot/vpopmail" ) {
        if ( -d "$vpopdir/doc/man_html" && -d $docroot ) {
            symlink "$vpopdir/doc/man_html", "$docroot/vpopmail";
        }
    }

    $self->freebsd->install_port( "p5-vpopmail", fatal => 0 );
    $self->vpopmail_post_install() if $version eq "port";
}

sub install_from_source {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $version = $self->conf->{'install_vpopmail'} || "5.4.33";
    my $package = "vpopmail-$version";
    my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    $self->vpopmail_create_user();   # add the vpopmail user/group
    my $uid = getpwnam( $self->conf->{'vpopmail_user'} || "vpopmail" );
    my $gid = getgrnam( $self->conf->{'vpopmail_group'} || "vchkpw"  );

    my $installed = $self->vpopmail_installed_version();

    if ( $installed && $installed eq $version ) {
        $self->util->yes_or_no(
                "Do you want to reinstall vpopmail with the same version?",
            timeout => 60,
            ) or do {
            $self->vpopmail_post_install();
            return 1;
        };
    }

    my $conf_args;
    foreach ( qw/ rebuild_tcpserver_file ip_alias_domains valias mysql_logging
        qmail_ext learn_passwords mysql / ) {
        my $mt_setting = 'vpopmail_' . $_;
        my $conf_arg = "--enable-$_";
        $conf_arg =~ s/_/-/g;
        my $r = $self->conf->{$mt_setting} ? 'yes' : 'no';
        $conf_args .= " $conf_arg=$r";
        print "$conf_arg=$r\n";
    };

    if ( ! $self->is_newer( min => "5.3.30", cur => $version ) ) {
        if ( defined $self->conf->{'vpopmail_default_quota'} ) {
            $conf_args .=
              " --enable-defaultquota=$self->conf->{'vpopmail_default_quota'}";
            print "default quota: $self->conf->{'vpopmail_default_quota'}\n";
        }
        else {
            $conf_args .= " --enable-defaultquota=100000000S,10000C";
            print "default quota: 100000000S,10000C\n";
        }
    }

    $conf_args .= $self->vpopmail_roaming_users();

    if ( $OSNAME eq "darwin" && !-d "/usr/local/mysql"
        && -d "/opt/local/include/mysql" )
    {
        $conf_args .= " --enable-incdir=/opt/local/include/mysql";
        $conf_args .= " --enable-libdir=/opt/local/lib/mysql";
    }

    my $tcprules = $self->util->find_bin( "tcprules", debug=>0 );
    $conf_args .= " --enable-tcprules-prog=$tcprules";

    my $src = $self->conf->{'toaster_src_dir'} || "/usr/local/src";

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
        site      => "http://" . $self->conf->{'toaster_sf_mirror'},
        path      => "/vpopmail",
    );

    if ( -d $package ) {
        if ( !$self->util->source_warning(
                package => $package,
                src     => "$src/mail",
            ) )
        {
            carp "vpopmail: OK then, skipping install.\n";
            return;
        }
    }

    croak "Couldn't expand $tarball!\n"
        if !$self->util->extract_archive( $tarball );

    if ( $self->conf->{vpopmail_mysql} ) {
        $conf_args .= $self->vpopmail_mysql_options();
    };
    $conf_args .= $self->vpopmail_logging();
    $conf_args .= $self->vpopmail_default_domain($version);
    $conf_args .= $self->vpopmail_etc_passwd();

    # in case someone updates their toaster and not their config file
    if ( defined $self->conf->{'vpopmail_qmail_ext'} && $self->conf->{'vpopmail_qmail_ext'} ) {
        $conf_args .= " --enable-qmail-ext=y";
        print "qmail extensions: yes\n";
    }
    if ( defined $self->conf->{'vpopmail_maildrop'} ) { $conf_args .= " --enable-maildrop=y"; };

    print "fixup for longer passwords\n";
    system "sed -i -Ee '/^pw_clear_passwd char(/s/16/128/' vmysql.h";
    system "sed -i -Ee '/^pw_passwd char(/s/40/128/' vmysql.h";

    chdir($package);
    print "running configure with $conf_args\n\n";

    $self->util->syscmd( "./configure $conf_args", debug => 0 );
    $self->util->syscmd( "make",                   debug => 0 );
    $self->util->syscmd( "make install-strip",     debug => 0 );

    if ( -e "vlimits.h" ) {
        # this was needed due to a bug in vpopmail 5.4.?(1-2) installer
        $self->util->syscmd( "cp vlimits.h $vpopdir/include/", debug => 0);
    }

    $self->vpopmail_post_install();
    return 1;
}

sub vpopmail_default_domain {
    my $self = shift;
    my $version = shift;

    my $default_domain;

    if ( defined $self->conf->{'vpopmail_default_domain'} )
    {
        $default_domain = $self->conf->{'vpopmail_default_domain'};
    }
    else {
        if ( ! $self->util->yes_or_no( "Do you want to use a default domain? ", ) ) {
            print "default domain: NONE SELECTED.\n";
            return q{};
        };

        $default_domain = $self->util->ask("your default domain");
    };

    if ( ! $default_domain )
    {
        print "default domain: NONE SELECTED.\n";
        return q{};
    };

    if ( $self->is_newer( min => "5.3.22", cur => $version ) ) {
        my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
        $self->util->file_write( "$vpopdir/etc/defaultdomain",
            lines => [ $default_domain ],
            debug => 0,
        );

        $self->util->chown( "$vpopdir/etc/defaultdomain",
            uid  => $self->conf->{'vpopmail_user'}  || "vpopmail",
            gid  => $self->conf->{'vpopmail_group'} || "vchkpw",
        );

        return q{};
    }

    print "default domain: $default_domain\n";
    return " --enable-default-domain=$default_domain";
};

sub vpopmail_etc {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my @lines;

    my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    my $vetc    = "$vpopdir/etc";
    my $qdir    = $self->conf->{'qmail_dir'};

    mkdir( $vpopdir, oct('0775') ) unless ( -d $vpopdir );

    if ( -d $vetc ) { print "$vetc already exists.\n"; }
    else {
        print "creating $vetc\n";
        mkdir( $vetc, oct('0775') ) or carp "failed to create $vetc: $!\n";
    }

    $self->vpopmail_install_default_tcp_smtp( etc_dir => $vetc );

    my $qmail_control = "$qdir/bin/qmailctl";
    if ( -x $qmail_control ) {
        print " vpopmail_etc: rebuilding tcp.smtp.cdb\n";
        $self->util->syscmd( "$qmail_control cdb", debug => 0 );
    }
}

sub vpopmail_etc_passwd {
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

sub vpopmail_install_default_tcp_smtp {
    my $self  = shift;
    my %p = validate( @_, {
            'etc_dir' => SCALAR,
        },
    );

    my $etc_dir = $p{'etc_dir'};

    # test for an existing one
    if ( -f "$etc_dir/tcp.smtp" ) {
        my $count = $self->util->file_read( "$etc_dir/tcp.smtp" );
        return if $count != 1;
        # back it up
        $self->util->archive_file( "$etc_dir/tcp.smtp" );
    }

    my $qdir = $self->conf->{'qmail_dir'};

    my @lines = <<"EO_TCP_SMTP";
# RELAYCLIENT="" means IP can relay
# RBLSMTPD=""    means DNSBLs are ignored for this IP
# QMAILQUEUE=""  is the qmail queue process, defaults to $qdir/bin/qmail-queue
#
#    common QMAILQUEUE settings:
# QMAILQUEUE="$qdir/bin/qmail-queue"
# QMAILQUEUE="$qdir/bin/simscan"
#
#      handy test settings
# 127.:allow,RELAYCLIENT="",RBLSMTPD="",QMAILQUEUE="$qdir/bin/simscan"
# 127.:allow,RELAYCLIENT="",RBLSMTPD="",QMAILQUEUE="$qdir/bin/qscanq/bin/qscanq"
127.0.0.1:allow,RELAYCLIENT="",RBLSMTPD=""

EO_TCP_SMTP
    my $block = 1;

    if ( $self->conf->{'vpopmail_enable_netblocks'} ) {

        if (
            $self->util->yes_or_no(
                  "Do you need to enable relay access for any netblocks? :

NOTE: If you are an ISP and have dialup pools, this is where you want
to enter those netblocks. If you have systems that should be able to
relay through this host, enter their IP/netblocks here as well.\n\n"
            )
          )
        {
            do {
                $block = $self->util->ask( "the netblock to add (empty to finish)" );
                push @lines, "$block:allow" if $block;
            } until ( !$block );
        }
    }

    #no Smart::Comments;
    push @lines, <<"EO_QMAIL_SCANNER";
#
# Allow anyone with reverse DNS set up
#=:allow
#    soft block on no reverse DNS
#:allow,RBLSMTPD="Blocked - Reverse DNS queries for your IP fail. Fix your DNS!"
#    hard block on no reverse DNS
#:allow,RBLSMTPD="-Blocked - Reverse DNS queries for your IP fail. You cannot send me mail."
#    default allow
#:allow,QMAILQUEUE="$qdir/bin/simscan"
:allow
EO_QMAIL_SCANNER

    $self->util->file_write( "$etc_dir/tcp.smtp", lines => \@lines );
}

sub vpopmail_installed_version {
    my $self = shift;

    my $vpopdir = $self->{conf}{vpopmail_home_dir} || '/usr/local/vpopmail';
    return if ! -x "$vpopdir/bin/vpasswd";

    my $installed = `$vpopdir/bin/vpasswd -v | head -1 | cut -f2 -d" "`;
    chop $installed;
    print "vpopmail version $installed currently installed.\n";
    return $installed;
}

sub vpopmail_logging {

    my $self = shift;

    if ( defined $self->conf->{'vpopmail_logging'} )
    {
        if ( $self->conf->{'vpopmail_logging'} )
        {
            if ( $self->conf->{'vpopmail_logging_verbose'} )
            {
                print "logging: verbose with failed passwords\n";
                return " --enable-logging=v";
            }

            print "logging: everything\n";
            return " --enable-logging=y";
        }
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

sub vpopmail_post_install {
    my $self = shift;
    $self->vpopmail_etc();
    $self->vpopmail_mysql_privs();
    $self->util->install_module( "vpopmail" ) if $self->{conf}{install_ezmlm_cgi};
    print "vpopmail: complete.\n";
    return 1;
};

sub vpopmail_roaming_users {
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

sub vpopmail_test {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok};

    print "do vpopmail directories exist...\n";
    my $vpdir = $self->conf->{'vpopmail_home_dir'};
    foreach ( "", "bin", "domains", "etc/", "include", "lib" ) {
        $self->toaster->test("  $vpdir/$_", -d "$vpdir/$_" );
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
        $self->toaster->test("  $_", -x "$vpdir/bin/$_" );
    }

    print "do vpopmail libs exist...\n";
    foreach ("$vpdir/lib/libvpopmail.a") {
        $self->toaster->test("  $_", -e $_ );
    }

    print "do vpopmail includes exist...\n";
    foreach (qw/ config.h vauth.h vlimits.h vpopmail.h vpopmail_config.h /) {
        $self->toaster->test("  include/$_", -e "$vpdir/include/$_" );
    }

    print "checking vpopmail etc files...\n";
    my @vpetc = qw/ inc_deps lib_deps tcp.smtp tcp.smtp.cdb vlimits.default /;
    push @vpetc, 'vpopmail.mysql' if $self->conf->{'vpopmail_mysql'};

    foreach ( @vpetc ) {
        $self->toaster->test("  $_", (-e "$vpdir/etc/$_" && -s "$vpdir/etc/$_" ));
    }
}

sub vpopmail_create_user {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    my $vpuser  = $self->conf->{'vpopmail_user'}     || "vpopmail";
    my $vpgroup = $self->conf->{'vpopmail_group'}    || "vchkpw";

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

sub vpopmail_mysql_options {

    my $self = shift;
    my $mysql_repl    = $self->conf->{vpopmail_mysql_replication};
    my $my_write      = $self->conf->{vpopmail_mysql_repl_master} || 'localhost';
    my $db         = $self->conf->{vpopmail_mysql_database} || 'vpopmail';

    my $opts;
    if ( $self->conf->{'vpopmail_mysql_limits'} ) {
        print "mysql qmailadmin limits: yes\n";
        $opts .= " --enable-mysql-limits=y";
    }

    if ( $mysql_repl ) {
        $opts .= " --enable-mysql-replication=y";
        print "mysql replication: yes\n";
        print "      replication master: $my_write\n";
    }

    if ( $self->conf->{'vpopmail_disable_many_domains'} ) {
        $opts .= " --disable-many-domains";
    }

    return $opts;
}

sub vpopmail_mysql_privs {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    if ( !$self->conf->{'vpopmail_mysql'} ) {
        print "vpopmail_mysql_privs: mysql support not selected!\n";
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

    my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    my @lines = "$my_read|0|$user|$pass|$db";
    if ($mysql_repl) {
        push @lines, "$my_write|$my_write_port|$user|$pass|$db";
    }
    else {
        push @lines, "$my_read|$my_read_port|$user|$pass|$db";
    }

    $self->util->file_write( "$vpopdir/etc/vpopmail.mysql",
        lines => \@lines,
        debug => 1,
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
