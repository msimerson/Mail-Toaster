package Mail::Toaster::FreeBSD;
use strict;
use warnings;

our $VERSION = '5.47';

use Carp;
use File::Copy;
use Params::Validate qw( :all );
use POSIX;

use lib 'lib';
use parent 'Mail::Toaster::Base';

sub drive_spin_down {
    my $self = shift;
    my %p = validate( @_, { 'drive' => SCALAR, $self->get_std_opts } );
    my %args = $self->toaster->get_std_args( %p );

    my $drive = $p{'drive'};

    return $p{'test_ok'} if defined $p{'test_ok'};

    #TODO: see if the drive exists!

    my $camcontrol = $self->util->find_bin( "camcontrol", %args)
        or return $self->error( "couldn't find camcontrol", %args );

    print "spinning down backup drive $drive...";
    $self->util->syscmd( "$camcontrol stop $drive", %args );
    print "done.\n";
    return 1;
}

sub get_defines {
    my ($self, $flags) = @_;

    # flags are the "make -DWITH_OPTION" flags
    return '' if ! $flags;

    my $make_defines;
    foreach my $def ( split( /,/, $flags ) ) {
        if ( $def =~ /=/ ) {             # DEFINE=VALUE format, use as is
            $make_defines .= " $def ";
        }
        else {
            $make_defines .= " -D$def "; # otherwise, prepend the -D flag
        }
    }
    return $make_defines;
};

sub get_port_category {
    my $self = shift;
    my $port = shift or die "missing port in request\n";

    my ($path) = glob("/usr/ports/*/$port/distinfo");
    if ( ! $path ) {
        ($path) = glob("/usr/ports/*/$port/Makefile");
    };
    return if ! $path;
    return (split '/', $path)[3];
}

sub get_version {
    my $self  = shift;

    my (undef, undef, $version) = POSIX::uname;
    $self->audit( "version is $version" );

    return $version;
}

sub install_port {
    my $self = shift;
    my $portname = shift or return $self->error("missing port/package name" );
    my %p = validate( @_,
        {   dir      => { type => SCALAR, optional => 1 },
            category => { type => SCALAR, optional => 1 },
            check    => { type => SCALAR, optional => 1 },
            flags    => { type => SCALAR, optional => 1 },
            options  => { type => SCALAR, optional => 1 },
            $self->get_std_opts,
        },
    );

    my $options = $p{options};
    my %args = $self->get_std_args( %p );

    return $p{test_ok} if defined $p{test_ok};

    my $check = $p{check} || $portname;
    return 1 if $self->is_port_installed( $check, verbose=>1);

    my $port_dir = $p{dir} || $portname;
    $port_dir =~ s/::/-/g;

    my $category = $p{category} || $self->get_port_category($portname)
        or die "unable to find port directory for port $portname\n";

    my $path = "/usr/ports/$category/$port_dir";
    -d $path or $self->error( "missing $path: $!\n" );

    $self->util->audit("install_port: installing $portname");

    my $make_defines = $self->get_defines($p{flags});

    if ($options) {
        $self->port_options( port => $portname, cat => $category, opts => $options );
    }

    # reset our PATH, to make sure we use our system supplied tools
    $ENV{PATH} = "/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin";

    # the vast majority of ports work great this way
    $self->audit( "running: make -C $path $make_defines install clean");
    system "make -C $path clean";
    system "make -C $path $make_defines";
    system "make -C $path $make_defines install";
    if ( $portname eq "ezmlm-idx" ) {
        copy( "$path/work/ezmlm-0.53/ezmlmrc", "/usr/local/bin" );
    }
    system "make -C $path clean";

    return 1 if $self->is_port_installed( $check, verbose=>1 );

    $self->util->audit( "install_port: $portname install, FAILED" );

    if ( $portname =~ /\Ap5\-(.*)\z/ ) {
        my $p_name = $1;
        $p_name =~ s/\-/::/g;
        $self->util->install_module_cpan($p_name) and return 1;
    };

    $self->install_port_try_manual( $portname, $path );
    return $self->error( "Install of $portname failed. Please fix and try again.", %args);
}

sub is_port_installed {
    my $self = shift;
    my $port = shift or return $self->error("missing port name", fatal=>0);
    my %p    = validate( @_,
        {   'alt' => { type => SCALAR | UNDEF, optional => 1 },
            $self->get_std_opts,
        },
    );

    my $alt = $p{alt} || $port;

    my ( $r, @args );

    $self->util->audit( "  checking for port $port", verbose=>0);

    return $p{test_ok} if defined $p{test_ok};

    my @packages;
    if ( -x '/usr/sbin/pkg' ) {
        @packages = `/usr/sbin/pkg info`; chomp @packages;
    }
    else {
        my $pkg_info = $self->util->find_bin( 'pkg_info', verbose => 0 );
        @packages = `$pkg_info`; chomp @packages;
    }

    my @matches = grep {/^$port\-/} @packages;
    if ( scalar @matches == 0 ) { @matches = grep {/^$port/} @packages; };
    if ( scalar @matches == 0 ) { @matches = grep {/^$alt\-/ } @packages; };
    if ( scalar @matches == 0 ) { @matches = grep {/^$alt/ } @packages; };
    return if scalar @matches == 0; # no matches
    $self->util->audit( "WARN: found multiple matches for port $port",verbose=>1)
        if scalar @matches > 1;

    my ($installed_as) = split(/\s/, $matches[0]);
    $self->util->audit( "found port $port installed as $installed_as" );
    return $installed_as;
}

sub install_portupgrade {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my %args = $self->toaster->get_std_args( %p );

    my $package = $self->conf->{'package_install_method'} || "packages";

    if ( defined $p{'test_ok'} ) { return $p{'test_ok'}; }

    # if we're running FreeBSD 6, try installing the package as it will do the
    # right thing. On older systems we want to install a (much newer) version
    # of portupgrade from ports

    if ( $self->get_version =~ m/\A6/ ) {
        $self->install_package( "portupgrade", %args );
    }

    if ( $package eq "packages" ) {
        $self->install_package( "ruby18_static",
            alt   => "ruby-1.8",
            %args,
        );
    }

    $self->install_port( port => "portupgrade", %args );

    return 1 if $self->is_port_installed( "portupgrade" );
    return;
}

sub install_package {
    my $self = shift;
    my $package = shift or die "missing package in request\n";
    my %p    = validate(
        @_,
        {   'alt'   => { type => SCALAR, optional => 1, },
            'url'   => { type => SCALAR, optional => 1, },
            $self->get_std_opts,
        },
    );

    my ( $alt, $pkg_url ) = ( $p{'alt'}, $p{'url'} );
    my %args = $self->toaster->get_std_args( %p );

    $self->util->audit("install_package: checking if $package is installed");

    return $p{'test_ok'} if defined $p{'test_ok'};

    return 1 if $self->is_port_installed( $package, alt => $alt, %args );

    print "install_package: installing $package....\n";
    $ENV{"PACKAGESITE"} = $pkg_url if $pkg_url;

    my ($pkg_add, $r2);
    if ( -x '/usr/sbin/pkg' ) {
        $pkg_add = '/usr/sbin/pkg';
        $r2 = $self->util->syscmd( "$pkg_add install -y $package", verbose => 0 );
    }

    if (! -x $pkg_add) {
        $pkg_add = $self->util->find_bin( "pkg_add", %args );
        if ( !$pkg_add || !-x $pkg_add ) {
            return $self->error( "couldn't find pkg_add",fatal=>0)
        };
        $r2 = $self->util->syscmd( "$pkg_add -r $package", verbose => 0 );
    }

    if   ( !$r2 ) { print "\t $pkg_add failed\t "; }
    else          { print "\t $pkg_add success\t " };

    my $r = $self->is_port_installed( $package, alt => $alt, %args );
    if ( ! $r ) {
        carp "  : Sorry, I couldn't install $package!\n";
        return;
    }

    return $r;
}

sub install_port_try_manual {
    my ($self, $portname, $path ) = @_;
    print <<"EO_PORT_TRY_MANUAL";

    Automatic installation of port $portname failed! You can try to install $portname manually
using the following commands:

        cd $path
        make
        make install clean

    If that does not work, make sure your ports tree is up to date and
    try again. See also "Dealing With Broken Ports":

        http://www.freebsd.org/doc/en_US.ISO8859-1/books/handbook/ports-broken.html

If manual installation fails, there may be something "unique" about your system
or the port may be broken. You can:

    a. Wait until the port is fixed
    b. Try fixing the port
    c. Get someone else to fix it

EO_PORT_TRY_MANUAL
}

sub port_options {
    my $self = shift;
    my %p = validate(
        @_,
        {   port  => SCALAR,
            opts  => SCALAR,
            cat   => SCALAR,
            $self->get_std_opts,
        },
    );

    my ( $port, $cat, $opts ) = ( $p{port}, $p{cat}, $p{opts} );
    my %args = $self->toaster->get_std_args( %p );

    return $p{test_ok} if defined $p{test_ok};

    my $opt_dir = "/var/db/ports/$cat".'_'.$port;
    if ( !-d $opt_dir ) {
        $self->util->mkdir_system( dir => $opt_dir, %args,);
    }

    my $prefix = '# This file installed by Mail::Toaster';
    $self->util->file_write( "$opt_dir/options", lines => [$prefix,$opts], %args );
}

sub update_ports {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts, } );
    my %args = $self->toaster->get_std_args( %p );

    return $p{test_ok} if defined $p{test_ok};

    return $self->error( "you do not have write permission to /usr/ports.",%args) if ! $self->util->is_writable('/usr/ports', %args);

    my $supfile = $self->conf->{'cvsup_supfile_ports'} || "portsnap";

    return $self->portsnap( %args);

    return 1;
}

sub portsnap {
    my $self = shift;
    my %p    = validate( @_, { $self->get_std_opts, },);

    my %args = $self->toaster->get_std_args( %p );

    return $p{'test_ok'} if defined $p{'test_ok'};

    # should be installed already on FreeBSD 5.5 and 6.x
    my $portsnap = $self->util->find_bin( "portsnap", fatal => 0 );
    my $ps_conf = "/etc/portsnap.conf";

    unless ( $portsnap && -x $portsnap ) {
        $self->install_port( "portsnap" );

        $ps_conf = '/usr/local/etc/portsnap.conf';
        if ( !-e $ps_conf ) {
            if ( -e "$ps_conf.sample" ) {
                copy( "$ps_conf.sample", $ps_conf );
            }
            else {
                warn "WARNING: portsnap configuration file is missing!\n";
            }
        }

        $portsnap = $self->util->find_bin( "portsnap", fatal => 0 );
        unless ( $portsnap && -x $portsnap ) {
            return $self->util->error(
                "portsnap is not installed (correctly). I cannot go on!");
        }
    }

    if ( !-e $ps_conf ) {
        $portsnap .= " -s portsnap.freebsd.org";
    }

    # grabs the latest updates from the portsnap servers
    system $portsnap, 'fetch';

    if ( !-e "/usr/ports/.portsnap.INDEX" ) {
        print "\a
    COFFEE BREAK TIME: this step will take a while, dependent on how fast your
    disks are. After this initial extract, portsnap updates are much quicker than
    doing a cvsup and require less bandwidth (good for you, and the FreeBSD
    servers). Please be patient.\n\n";
        sleep 2;
        system $portsnap, "extract";
    }
    else {
        system $portsnap, "update";
    }

    return 1;
}

sub conf_check {
    my $self = shift;
    my %p = validate(
        @_,
        {   'check' => { type => SCALAR, },
            'line'  => { type => SCALAR, },
            'file'  => { type => SCALAR,  optional => 1, },
            $self->get_std_opts,
        },
    );

    my %args = $self->get_std_args( %p );
    my $check = $p{check};
    my $line  = $p{line};
    my $file  = $p{file} || "/etc/rc.conf";
    $self->util->audit("conf_check: looking for $check");

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $changes;
    my @lines;
    @lines = $self->util->file_read( $file ) if -f $file;
    foreach ( @lines ) {
        next if $_ !~ /^$check\=/;
        return $self->util->audit("\tno change") if $_ eq $line;
        $self->util->audit("\tchanged:\n$_\n\tto:\n$line\n" );
        $_ = $line;
        $changes++;
    };
    if ( $changes ) {
        return $self->util->file_write( $file, lines => \@lines, %args );
    };

    return $self->util->file_write( $file, append => 1, lines => [$line], %args );
}

1;
__END__


=head1 NAME

Mail::Toaster::FreeBSD - FreeBSD specific Mail::Toaster functions.

=head1 SYNOPSIS

Primarily functions for working with FreeBSD ports (updating, installing, configuring with custom options, etc) but also includes a suite of methods for FreeBSD managing jails.


=head1 DESCRIPTION

Usage examples for each subroutine are included.


=head1 SUBROUTINES

=over

=item new

	use Mail::Toaster::FreeBSD;
	my $fbsd = Mail::Toaster::FreeBSD->new;


=item is_port_installed

Checks to see if a port is installed.

    $fbsd->is_port_installed( "p5-CGI" );

 arguments required
   port - the name of the port/package

 arguments optional:
   alt - alternate package name. This can help as ports evolve and register themselves differently in the ports database.

 result:
   0 - not installed
   1 - if installed


=item jail_create

    $fbsd->jail_create( );

 arguments required:
    ip        - 10.0.1.1

 arguments optional:
    hostname  - jail36.example.com,
    jail_home - /home/jail,

If hostname is not passed and reverse DNS is set up, it will
be looked up. Otherwise, the hostname defaults to "jail".

jail_home defaults to "/home/jail".

Here's an example of how I use it:

    ifconfig fxp0 inet alias 10.0.1.175/32

    perl -e 'use Mail::Toaster::FreeBSD;
         my $fbsd = Mail::Toaster::FreeBSD->new;
         $fbsd->jail_create( ip=>"10.0.1.175" )';

After running $fbsd->jail_create, you need to set up the jail.
At the very least, you need to:

    1. set root password
    2. create a user account
    3. get remote root
        a) use sudo (pkg_add -r sudo; visudo)
        b) add user to wheel group (vi /etc/group)
        c) modify /etc/ssh/sshd_config to permit root login
    4. install perl (pkg_add -r perl)

Here's how I set up my jails:

    pw useradd -n matt -d /home/matt -s /bin/tcsh -m -h 0
    passwd root
    pkg_add -r sudo rsync perl5.8
    rehash; visudo
    sh /etc/rc

Ssh into the jail from another terminal. Once successfully
logged in with root privs, you can drop the initial shell
and access the jail directly.

Read the jail man pages for more details. Read the perl code
to see what else it does.


=item jail_delete

Delete a jail.

  $freebsd->jail_delete( ip=>'10.0.1.160' );

This script unmounts the proc and dev filesystems and then nukes the jail directory.

It would be a good idea to shut down any processes in the jail first.


=item jail_start

Starts up a FreeBSD jail.

	$fbsd->jail_start( ip=>'10.0.1.1', hostname=>'jail03.example.com' );


 arguments required:
    ip        - 10.0.1.1,

 arguments optional:
    hostname  - jail36.example.com,
    jail_home - /home/jail,

If hostname is not passed and reverse DNS is set up, it will be
looked up. Otherwise, the hostname defaults to "jail".

jail_home defaults to "/home/jail".

Here's an example of how I use it:

    perl -e 'use Mail::Toaster::FreeBSD;
      $fbsd = Mail::Toaster::FreeBSD->new;
      $fbsd->jail_start( ip=>"10.0.1.175" )';



=item install_port

    $fbsd->install_port( "openldap" );

That's it. Really. Well, OK, sometimes it can get a little more complex. install_port checks first to determine if a port is already installed and if so, skips right on by. It is very intelligent that way. However, sometimes port maintainers do goofy things and we need to override settings that would normally work. A good example of this is currently openldap.

If you want to install OpenLDAP 2, then you can install from any of:

		/usr/ports/net/openldap23-server
		/usr/ports/net/openldap23-client
		/usr/ports/net/openldap24-server
		/usr/ports/net/openldap24-client

So, a full complement of settings could look like:

    $freebsd->install_port( "openldap-client",
		dir   => "openldap24-server",
		check => "openldap-client-2.4",
		flags => "NOPORTDOCS=true",
		fatal => 0,
	);

 arguments required:
   port - the name of the directory in which the port resides

 arguments optional:
   dir   - overrides 'port' for the build directory
   check - what to test for to determine if the port is installed (see note #1)
   flags - comma separated list of arguments to pass when building

 NOTES:

#1 - On rare occasion, a port will get installed as a name other than the ports name. Of course, that wreaks all sorts of havoc so when one of them nasties is found, you can optionally pass along a fourth parameter which can be used as the port installation name to check with.


=item install_package

	$fbsd->install_package( "maildrop" );

Suggested usage:

	unless ( $fbsd->install_package( "maildrop" ) ) {
		$fbsd->install_port( "maildrop" );
	};

Installs the selected package from FreeBSD packages. If the first install fails, it will try again using an alternate FTP site (ftp2.freebsd.org). If that fails, it returns 0 (failure) so you know it failed and can try something else, like installing via ports.

If the package is registered in FreeBSD's package registry as another name and you want to check against that name (so it doesn't try installing a package that's already installed), instead, pass it along as alt.

 arguments required:
    port - the name of the package to install

 arguments optional:
    alt  - a name the package is registered in the ports tree as
    url  - a URL to fetch the package from

See the pkg_add man page for more details on using an alternate URL.


=item update_ports

Updates the FreeBSD ports tree (/usr/ports/).

    $fbsd->update_ports();

 arguments required:
   conf - a hashref

See the docs for toaster-watcher.conf for complete details.


=item conf_check

    $fbsd->conf_check(check=>"snmpd_enable", line=>"snmpd_enable=\"YES\"");

The above example is for snmpd. This checks to verify that an snmpd_enable line exists in /etc/rc.conf. If it doesn't, then it will add it by appending the second argument to the file.


=back

=head1 AUTHOR

Matt Simerson <matt@tnpi.net>

=head1 BUGS

None known. Report any to author.

=head1 TODO

Needs more documentation.

=head1 SEE ALSO

The following are all man/perldoc pages:

 Mail::Toaster
 Mail::Toaster::Conf
 toaster.conf
 toaster-watcher.conf

 http://mail-toaster.org/
 http://www.tnpi.net/computing/freebsd/


=head1 COPYRIGHT

Copyright 2003-2012, The Network People, Inc. All Rights Reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
