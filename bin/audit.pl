#!/usr/bin/perl

use strict;
use warnings;

use English;

my $http_url = "http://secure.example.com";

$|++;

# some files should be chmod 0 in nearly all cases
check_file_permissions();
login_notifications();

if ( $OSNAME eq "freebsd" ) {
    access_control();
    valid_accounts();
    empty_password();
    xploit_turds();
    pf_firewall();
    rc_dot_conf_settings();
    sysctl_conf_settings();
    sshd_config();
};

snmp_public_ip();
mysql_public_ip();
apache();
lighttpd();
var_cron();
qmail_conf();
robots_dot_txt();

# IDEAS
# make all mods necessary for CIS-1 security standard

# is public IP firewalled?
# is networking needed?

# require single-user console password
#   awk '($1 == "console") { $5 = "insecure" } { print }' /etc/ttys > /etc/ttys.new
#   mv /etc/ttys.new /etc/ttys

# Set daemon umask
#   find /etc/ /usr/local/etc/rc.d | xargs grep 'umask'

# disable sendmail

# throttle inetd 
#  inetd_flags="-CX -sX -cX

# ROUGUE LISTENERS
# check for rogue ports being listened to
#   netstat -an | grep LISTEN
#   sockstat 

sub access_control
{
    my $hosts_allow = "hosts.allow";
    my $hosts_sshd  = "hosts.allow.ssh";
    my $hosts_mysql = "hosts.allow.mysql";
    my $hosts_http  = "hosts.allow.http";

    return 0;

    get_url("$http_url/$hosts_allow");
    get_url("$http_url/$hosts_sshd");
    get_url("$http_url/$hosts_mysql");
    get_url("$http_url/$hosts_http");
};

sub xploit_turds
{
    print "\ncleaning up behind exploit kits...";
    sleep 1;

    my @homedirs = `/bin/ls /home/`; chomp @homedirs;
    foreach my $dir (@homedirs) {
        if ( -l "/home/$dir/.history" ) {
             print "removed a tampered .history file: /home/$dir/.history\n";
             unlink "/home/$dir/.history";
        };
    };
};

sub valid_accounts
{
    print "\nchecking for valid accounts...\n";
    sleep 1;

    my $changes = 0;

    my @valid_accounts = qw/
        root toor daemon operator bin tty kmem games news man 
        sshd smmsp mailnull bind proxy _pflogd _dhcp uucp pop 
        www mysql nobody /;

    my @invalid_accounts;

    my $good_users = "users.valid";
    my $bad_users  = "users.invalid";

    get_url("$http_url/$good_users");
    get_url("$http_url/$bad_users");

    my @tmp = `cat $good_users`; chomp @tmp;
    push @valid_accounts, @tmp;
    #print "adding users: " . join(" ", @tmp) . "\n";
    my %valid = map { $_ => 1 } @valid_accounts;

    @tmp = `cat $bad_users`; chomp @tmp;
    push @invalid_accounts, @tmp;
    my %invalid = map { $_ => 1 } @invalid_accounts;

    my @all_accounts = `grep -v '^#' /etc/passwd | cut -f1 -d":"`;
    chomp @all_accounts;

    foreach my $account (@all_accounts) {
        if ( defined $invalid{$account} ) {
            print "invalid account: $account\n";
            $changes++;
            next;
        };
        if ( defined $valid{$account} ) {
            next;   # it's ok
        } else {
            print "unknown account: $account\n";
            $changes++;
        }
    };

    unlink $good_users;
    unlink $bad_users;

    _changes($changes, "ALERT: please verify the accounts shown above\n");
};

sub login_notifications
{
    print "\nchecking for login notification...";
    sleep 1;

    my $changes = 0;

    if ( ! `grep notice /etc/csh.login` ) {
        $changes++;
        print "\n\techo '/usr/bin/w -n | /usr/bin/mail -s \"login notice for \$USER@`hostname`\" root' >> /etc/csh.login";
        print "\n\techo '/usr/bin/w -n | /usr/bin/mail -s \"login notice for \$USER@`hostname`\" root' >> /etc/profile\n";
    };

    _changes($changes);
};

sub empty_password
{
    print "\nchecking passwords...";
    sleep 1;

    my $changes=0;

    my $grep_cmd = 'grep -v \'^#\' /etc/master.passwd | grep -v \'^\w*:\*:\'';
    #print "$grep_cmd\n";
    my @passwords = `$grep_cmd`;

    foreach my $pass (@passwords ) {
        chomp $pass;
        $changes++;
        print "\n\t$pass"; 
    };

    my $mess = "\nNOTICE: you should fix the password entries shown!\n";
    _changes($changes, $mess);
};

sub robots_dot_txt 
{
    my @web_dirs = `ls -d /home/*/html`;
    chomp @web_dirs;

    foreach my $dir (@web_dirs) {
        if ( ! -e "$dir/robots.txt" || ! -s "$dir/robots.txt" ) {
            open my $ROB, ">", "$dir/robots.txt";
            print $ROB default_config();
            close $ROB;
            print "    updated $dir/robots.txt\n";
            next;
        };
        #print "$dir has valid robots.txt.\n";
    };

    sub default_config {
        return "User-agent: *
Disallow: /cgi-bin/
Disallow: /awstats/
Disallow: /stats/
Disallow: /logs/
Disallow: /mail/
Disallow: /dns/
Disallow: \n";
    }
};

sub qmail_conf {

    print "checking qmail...";
    sleep 1;

    if ( ! -d "/var/qmail" ) {     # qmail is not installed
        print "ok (not installed).\n";
        return;
    };

    my $changes = 0;

    if ( ! -s "/var/qmail/control/me" ) {
        print "    echo `hostname` > /var/qmail/control/me\n";
        $changes++;
    };
    if ( ! -f "/var/qmail/rc" ) {
        print "cp /var/qmail/boot/maildir /var/qmail/rc\n";
        $changes++;
    };
    if ( ! -s "/var/qmail/control/smtproutes" ) {
        print "    echo ':relay.example.com' > /var/qmail/control/smtproutes\n";
    }

    _changes($changes);
};

sub lighttpd {

    my $http_conf = "/usr/local/etc/lighttpd.conf";
    if ( ! -e $http_conf ) {
        $http_conf = "/usr/local/etc/lighttpd/lighttpd.conf";
    }

    print "\nchecking lighttpd...";
    sleep 1;

    if ( ! -e $http_conf ) {
        print "not found, skipping.\n";
        return;
    };

    my $changes = 0;


    if ( `grep '^accesslog.format' $http_conf` !~ /%v/ ) {
        print <<'EO_LIGHT'

   accesslog.format      = "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" %v"
   accesslog.filename    = "|/usr/local/sbin/cronolog /var/log/http/%Y/%m/%d/access.log"
EO_LIGHT
;
        $changes++;
    }

    if ( ! `grep errorlog $http_conf` ) {
        print '   server.errorlog       = "/var/log/http/error.log"';
    };

    if ( ! -d "/var/log/http" ) {
        print "    mkdir /var/log/http\n";
        print "    chown www:www /var/log/http\n";
        $changes++;
    };

    my $mess = "Consider making the changes shown above to $http_conf\n";
    _changes($changes, $mess);
    sleep 2;
};

sub interface_polling {
    return 0 unless $OSNAME eq "freebsd";

    print "
    man polling
    http://taosecurity.blogspot.com/2006/09/freebsd-device-polling.html
    http://silverwraith.com/papers/freebsd-tuning.php
";
};

sub var_cron 
{
    print "\nchecking cron...";
    sleep 1;

    my $changes = 0;

    if ( -d "/var/cron" ) {
        if ( ! -f "/var/cron/allow" ) {
            print <<EO_CRON
"     RESTRICT CRON: Consider restricting cron use. 
      Create /var/cron/allow and add only users that need cron access. eg:

          echo "root" > /var/cron/allow
          chmod o-rwx /var/cron/allow
EO_CRON
;
            $changes++;
        };
    };

    _changes($changes);
};

sub sysctl_conf_settings
{
    my $changes = 0;
    my $sysconf = "/etc/sysctl.conf";

    print "\nchecking $sysconf settings...";
    sleep 1;

    # disable core dumps
    if ( ! `grep coredump $sysconf` && ! am_i_jailed() ) {
        print <<EO_COREDUMP

echo "# don't dump core files unless we specifically ask for it!" >> $sysconf
echo "kern.coredump=0" >> $sysconf
EO_COREDUMP
;
        $changes++;
    };

    # prevent users from seeing others processes
    if ( ! `grep see_other_uids $sysconf` ) {
        print <<EO_UIDS

echo "# This prevents users from seeing processes running under other [U|G]IDs." >> /etc/sysconf
echo "#security.bsd.see_other_uids=0" >> $sysconf
echo "#security.bsd.see_other_gids=0 >> $sysconf
EO_UIDS
;
        $changes++;
    };

    if ( ! `grep blackhole $sysconf` && ! am_i_jailed() ) {
        print <<EO_BLACK

echo "# security additions to consider" >> /etc/sysctl.conf
echo "#net.inet.tcp.blackhole=1" >> /etc/sysctl.conf
echo "#net.inet.udp.blackhole=1" >> /etc/sysctl.conf
echo "#net.inet.tcp.log_in_vain=1" >> /etc/sysctl.conf
echo "#net.inet.udp.log_in_vain=1" >> /etc/sysctl.conf
EO_BLACK
;
        $changes++;
    };

    _changes($changes);
    sleep 2;
};

sub sshd_config {

    if ( $OSNAME ne "freebsd" ) {
        return 0;
    };

    print "\nchecking sshd_config.\n";
    sleep 1;

    my $sshd_config = "/etc/ssh/sshd_config";

    if ( `grep '^VersionAddendum' $sshd_config | grep -v FreeBSD` ) {
        # already updated
    } else {
        print "    edit $sshd_config and make the following changes:

    Protocol 2
    PermitRootLogin no
    VersionAddendum For Authorized Use Only
    ChallengeResponseAuthentication no
    MaxStartups 2:50:5\n\n";
    };
    
    if ( ! `grep "NOTICE" /etc/motd` ) {
        print "    add something like this to /etc/motd: 

*****************************  NOTICE  ********************************
   Unauthorized access prohibited and punishable to the full extent 
   of the law. All connection attempts and network traffic are logged 
   and archived. Keystrokes are subject to monitoring. Remaining 
   connected is consent to this policy.

*****************************  NOTICE  ********************************
\n";
    };

    my $mode = get_mode($sshd_config);
    if ( $mode !~ /600$/  ) {
        print "\tchmod 600 /etc/ssh/sshd_config\n";
    };

    my $sentry = '/var/db/sentry/sentry.pl';
    if ( ! -x $denyhosts ) {
        print "\t consider installing Sentry to protect your SSH daemon.
\thttp://www.tnpi.net/wiki/Sentry\n";
    };

    sleep 2;
};

sub rc_dot_conf_settings {

    my $rc_conf = "/etc/rc.conf";

    if ( ! -f $rc_conf ) {
        return 0;
    };

    print "\nchecking rc.conf settings...\n";
    sleep 1;

    my $changes= 0;
    my $jailed = am_i_jailed();

    # prevent syslog from listening on the network
    if ( ! `grep syslogd_flags $rc_conf` ) {
        print <<EO_SYSLOG
# either of these syslog invocations are good choices
syslogd_flags="-ss"             # Flags to syslogd (if enabled).
#syslogd_flags="-s -b 127.0.0.1" # Flags to syslogd (if enabled).
EO_SYSLOG
;
        $changes++;
    }
    if ( ! `grep update_motd $rc_conf` ) {
        print "    echo 'update_motd=\"NO\"' >> $rc_conf\n";
        $changes++;
    };
    if ( ! `grep clear_tmp_enable $rc_conf` ) {
        print "    echo 'clear_tmp_enable=\"YES\"' >> $rc_conf\n";
        $changes++;
    };

    if ( ! `grep inetd /etc/rc.conf` ) {
        print <<EO_INETD
    echo 'inetd_enable="NO"' >> $rc_conf
    echo 'inetd_flags="-Ww1 -C60"' >> $rc_conf
EO_INETD
;

        $changes++;
    };

    if ( ! $jailed ) {
        if ( ! `grep pf_enable /etc/rc.conf` ) {
            print '
    pf_enable="YES"                 # Set to YES to enable packet filter (pf)
    pf_rules="/etc/pf.conf"         # rules definition file for pf
    pf_flags=""                     # additional flags for pfctl
    pflog_enable="YES"              # Set to YES to enable packet filter logging
    pflog_logfile="/var/log/pflog"  # where pflogd should store the logfile
    pflog_flags=""                  # additional flags for pflogd
';
            $changes++;
        };

        if ( ! `grep fsck_y_enable $rc_conf` ) {
            print '    fsck_y_enable="YES"' . "\n";
            $changes++;
        };
        if ( ! `grep log_in_vain $rc_conf` ) {
            print '    log_in_vain="YES"       # careful, could fill up disk!' . "\n";
            $changes++;
        };
        if ( ! `grep icmp_log_red $rc_conf` ) {
            print '    icmp_log_redirect="NO"   # careful, could fill up disk!' . "\n";
            $changes++;
        };
        if ( ! `grep icmp_drop_red $rc_conf` ) {
            print '    icmp_drop_redirect="YES"' . "\n";
            $changes++;
        };
        if ( ! `grep tcp_drop_synfin $rc_conf` ) {
            print '    tcp_drop_synfin="YES"' . "\n";
            $changes++;
        };

        if ( ! `grep securelevel /etc/rc.conf` ) {
            print '
    kern_securelevel="1"
    kern_securelevel_enable="YES"
';
            $changes++;
        };

        if ( ! `grep ntpdate /etc/rc.conf` ) {
            print '
    ntpdate="YES"
    ntpdate_flags="north-America.pool.ntp.org"
';
            $changes++;
        };
    };

    $changes == 0 ?
          print "ok\n"
        : print "consider making the changes shown above to /etc/rc.conf\n\n";

    sleep 2;
};

# is snmp restricted to localhost?
sub snmp_public_ip {

    print "\nchecking for snmpd listening on a public IP...";
    sleep 1;

    my $sockstat = `which sockstat`; chomp $sockstat;
    if ( ! -x $sockstat ) {
        print "ERROR: no sockstat!\n";
        return 0;
    };

    if ( `$sockstat -4 -l -p 161 | grep -v COMMAND | grep -v 127` ) {
        print "\n    Consider having snmpd bind to an internal IP address such as 127.0.0.1\n    by adding something like this to snmp startup script:

   -p 161\@localhost\n\n";
        sleep 2;
    } else {
        print "ok.\n";
    };
};

# Mysql Tests
# is mysql listening on public IP?
sub mysql_public_ip {

    print "\nchecking for mysql listening on a public IP...";
    sleep 1;

    my $sockstat = `which sockstat`; chomp $sockstat;
    my $grep = `which grep`; chomp $grep;

    if ( ! -x $sockstat ) {
        print "ERROR: no sockstat!\n";
        return 0;
    };

    if ( `$sockstat -4 -l -p 3306 | grep -v COMMAND | grep -v 127` ) {
        print "\n    consider having MySQL bind to a non-pulic IP such as 127.0.0.1. 
    Adding something like this to your /etc/my.cnf:

    bind-address  = 127.0.0.1

";
        return;
    } else {
        print "ok.\n";
    };

    sleep 2;
};


#   Files to change permissions on 
sub check_file_permissions {

    my $changes = 0;

    #   Files to chmod o-rwx
    my @chmod_no_other = qw{ 
        /etc/crontab
        /root
        /var/cron/allow
    };

    print "checking directory permissions...";
    sleep 1;

    foreach my $dirs ( @chmod_no_other ) {
        next unless -e $dirs;

        if ( get_mode($dirs) !~ /0$/ ) {
            print "\n\tchmod o-rwx $dirs";
            $changes++;
        };
    };

    _changes($changes);

    $changes = 0;  # reset changes

    # check setuid files

    print "\nchecking suid file permissions...";
    sleep 1;

    #   Files to chmod 0 (not needed)
    my @chmod_zero = qw{ /sbin/rcp /sbin/ping6
        /usr/sbin/traceroute6 /usr/sbin/authpf
        /usr/bin/lpq         /usr/bin/lpr
        /usr/bin/lprm        /usr/sbin/lpc
        /usr/sbin/mrinfo     /usr/sbin/mtrace
        /usr/sbin/ppp        /usr/sbin/pppd
        /usr/sbin/sliplogin
        /usr/sbin/timedc
    };

    # if sendmail isn't the active MTA
    my $sendmail = `grep '^sendmail' /etc/mail/mailer.conf | awk '{ print $2 }'`;
    if ( $sendmail ne "/usr/libexec/sendmail/sendmail" ) {
        push @chmod_zero, "/usr/libexec/sendmail/sendmail";
    };

    foreach my $bins ( @chmod_zero ) {
        if ( -x $bins ) {
            print "\n\tchmod 0 $bins";
            $changes++;
        }
    };

    _changes($changes);
};

sub get_mode {
    my $dir = shift;

    my $raw_mode = (stat($dir))[2];
    return sprintf "%04o", $raw_mode & 07777;
};

sub apache {

    # Apache Tests

    my $changes = 0;

    # find httpd.conf
    my $httpconf = find_httpd_conf();

    if (! -f $httpconf) {
        print "\nchecking apache: skipping, httpd.conf not found.\n";
        sleep 1;
        return;
    };

    # check ServerSignatures
    if ( `grep "ServerSignature On" $httpconf` ) {
        print "    ServerSignature Off\n";
        $changes++;
    };

    # check ServerTokens
    if ( ! `grep "ServerTokens Prod" $httpconf` ) {
        print "    ServerTokens ProductOnly\n";
        $changes++;
    };

    if ( `grep '^LogFormat' $httpconf` !~ /%v/ ) {
        print '    CustomLog "| /usr/local/sbin/cronolog /var/log/http/%Y/%m/%d/access.log" logmonster' . "\n";
        print '    LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" %v" logmonster' . "\n";
        unless ( -x "/usr/local/sbin/cronolog" ) {
            warn "WARNING: cronolog is not installed!\n";
        };
        $changes++;
    };

    # disable track and trace HTTP methods
    if ( ! `grep "TRACE" $httpconf` ) {
        print << "EOAPACHE";
    <IfModule mod_rewrite.c>
             RewriteEngine On
             RewriteCond %{REQUEST_METHOD} ^(TRACE|TRACK)
             RewriteRule .* - [F]
    </IfModule>
EOAPACHE
;
        $changes++;
    };

    $changes == 0 ? 
          print "checking httpd.conf settings...ok\n"
        : print "I suggest making the changes show above to $httpconf\n";
    
};


## PF Firewall ##
sub pf_firewall {

    if ( $OSNAME ne "freebsd" ) {
        return;
    };

    return if am_i_jailed();

    print "\nchecking PF firewall...";
    sleep 1;

    if ( -e "/dev/pf" ) {
        print "ok.\n";
        return;
    };

    print << "EOPF";

    Add PF support support to your kernel by adding these options to your
    kernel config file:

options         ALTQ
options         ALTQ_CBQ        # Class Bases Queuing (CBQ)
options         ALTQ_RED        # Random Early Detection (RED)
options         ALTQ_RIO        # RED In/Out
options         ALTQ_HFSC       # Hierarchical Packet Scheduler (HFSC)
options         ALTQ_PRIQ       # Priority Queuing (PRIQ)
options         ALTQ_NOPCC      # Required for SMP build

    while you're at it, consider adding these too:

options         QUOTA
options         DEVICE_POLLING   # speed up networking
options         TCP_DROP_SYNFIN  # cloak our identity

EOPF
;

};

sub am_i_jailed {
    my $jail = `/sbin/sysctl -n security.jail.jailed`;
    $jail == 1 ? return 1 : return 0;
};

sub find_httpd_conf {
    my $httpconf;

    if ( $OSNAME eq "darwin" ) {
        $httpconf = "/etc/httpd/httpd.conf";
        return $httpconf;
    }

    my $apachectl = "/usr/local/sbin/apachectl";
    if ( ! -x $apachectl ) {
        $apachectl = "/usr/sbin/apachectl";
        if ( ! -x $apachectl ) {
            return 0;
        };
    };

    my $http_root = `$apachectl -V | grep HTTPD_ROOT | cut -f2 -d'"'`;
    my $http_file = `$apachectl -V | grep SERVER_CONFIG_FILE | cut -f2 -d'"'`;
    chomp ($http_root, $http_file);

    my $httpd_conf = "$http_root/$http_file";
    if ( -f $httpd_conf ) {
        return $httpd_conf;
    } else {
        die "uh oh, something is wrong with the path: $httpd_conf\n";
    };

#    my $etcdir = "/usr/local/etc";
#    if ( $OSNAME eq "freebsd" ) {
#        if ( -d "$etcdir/apache" ) {
#            $httpconf = "$etcdir/apache/httpd.conf";
#            return $httpconf;
#        }
#        elsif ( -d "$etcdir/apache2" ) {
#            $httpconf = "$etcdir/apache2/httpd.conf";
#            return $httpconf;
#        }
#        elsif ( -d "$etcdir/apache22" ) {
#            $httpconf = "$etcdir/apache22/httpd.conf";
#            return $httpconf;
#        };
#    }
}


sub _changes 
{
    my $changes = shift;
    my $message = shift;

    if ( $changes == 0 ) {
        print "ok.\n";
        return;
    } else {
        $message ||= "\nALERT: consider running the commands shown above.\n";
        print $message;
    };

    sleep 2;
};

sub get_url {

    my ($url, $timer, $fatal, $debug) = @_;

    my ( $fetchbin, $found );

    print "get_url: fetching $url\n" if $debug;

    if ( $OSNAME eq "freebsd" ) {
        $fetchbin = find_bin('fetch');
        if ( $fetchbin && -x $fetchbin ) {
            $found = "fetch";
            $found .= " -q" unless $debug;
        }
    }
    elsif ( $OSNAME eq "darwin" ) {
        $fetchbin = find_bin( 'curl' );
        if ( $fetchbin && -x $fetchbin ) {
            $found = "curl -O";
            $found .= " -s " unless $debug;
        }
    }

    unless ($found) {
        $fetchbin = find_bin( 'wget' );
        if ( $fetchbin && -x $fetchbin ) { $found = "wget"; }
    }

    unless ($found) {
        # should use LWP here if available
        warn "Yikes, couldn't find wget! Please install it.\n";
        return 0;
    }

    my $fetchcmd = "$found $url";
          
    my $r;
    
    # timeout stuff goes here.
    if ($timer) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $timer;
            system $fetchcmd;
            alarm 0;
        }; 
    }
    else {
        system $fetchcmd;
    }

    if ($@) {
        ( $@ eq "alarm\n" )
          ? print "timed out!\n"
          : carp $@;    # propagate unexpected errors
        die if $fatal;
    }
}

sub find_bin {

    my $bin = shift;
    my $dir = shift;

    if ( ! $bin ) {
        warn "invalid params to find_bin.\n";
        return;
    }

    #print "find_bin: searching for $bin\n" if $debug;

    my $prefix = "/usr/local";

    if ( $dir && -x "$dir/$bin" ) { return "$dir/$bin"; }
    if ( $bin =~ /^\// && -x $bin ) { return $bin }
    ;    # we got a full path

    if    ( -x "$prefix/bin/$bin" )       { return "/usr/local/bin/$bin"; }
    elsif ( -x "$prefix/sbin/$bin" )      { return "/usr/local/sbin/$bin"; }
    elsif ( -x "$prefix/mysql/bin/$bin" ) { return "$prefix/mysql/bin/$bin"; }
    elsif ( -x "/bin/$bin" )              { return "/bin/$bin"; }
    elsif ( -x "/usr/bin/$bin" )          { return "/usr/bin/$bin"; }
    elsif ( -x "/sbin/$bin" )             { return "/sbin/$bin"; }
    elsif ( -x "/usr/sbin/$bin" )         { return "/usr/sbin/$bin"; }
    elsif ( -x "/opt/local/bin/$bin" )    { return "/opt/local/bin/$bin"; }
    elsif ( -x "/opt/local/sbin/$bin" )   { return "/opt/local/sbin/$bin"; }
    else {
        warn "find_bin: WARNING: could not find $bin";
        return;
    }
}

