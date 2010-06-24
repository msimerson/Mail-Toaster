use strict;
use warnings;

package Mail::Toaster::Ezmlm;

our $VERSION = '5.25';

use Params::Validate qw( :all );;
use Pod::Usage;
use English qw( -no_match_vars );

use lib 'lib';
use Mail::Toaster          5.25; 
my ($toaster, $util);


sub new {
    my $class = shift;
    my %p = validate( @_, {
        toaster => { type=> SCALAR, optional => 1 },
    });

    $toaster = $p{toaster} || Mail::Toaster->new(debug=>0);
    $util = $toaster->get_util();

    my $self = { toaster => $toaster };

    bless( $self, $class );
    return $self;
}

sub authenticate {

    my $self = shift;
    
	my %p = validate ( @_, {
	        'domain'   => { type=>SCALAR,  optional=>0, },
	        'password' => { type=>SCALAR,  optional=>0, },
            'fatal'    => { type=>BOOLEAN, optional=>1, default=>1 },
            'debug'    => { type=>BOOLEAN, optional=>1, default=>1 },
        },
	);

	my ($domain, $password, $fatal, $debug) 
	    = ($p{'domain'}, $p{'password'}, $p{'fatal'}, $p{'debug'} );

    print "attempting to authenticate postmaster\@$domain..." if $debug;

    $util->install_module( "vpopmail", debug => $debug,);

    require vpopmail;

    if ( vpopmail::vauth_user( 'postmaster', $domain, $password, undef ) ) {
        print "ok.<br>" if $debug;
        return 1;
    }

    print "AUTHENTICATION FAILED! (dom: $domain, pass: $password)<br>";

    print "if you are certain the authentication information is correct, then
it is quite likely you cannot authenticate because your web server is running as
a user ($UID) that lacks permission to run this script. You can:<br>
<br>
  <blockquote>
    a: run this script suid vpopmail<br>
    b: run the web server as user vpopmail<br>
  </blockquote>

The easiest and most common methods is:<br>
<br>
  chown vpopmail /path/to/ezmlm.cgi<br>
  chmod 4755 /path/to/ezmlm.cgi<br>
<br>
\n\n";

    return 0;
}

sub dir_check {

    my $self = shift;
    
    my %p = validate( @_, {
            'dir'     => { type=>SCALAR, },
            'br'      => { type=>SCALAR,  optional=>1, default=>'<br>' },
            'fatal'   => { type=>BOOLEAN, optional=>1, default=>1 },
            'debug'   => { type=>BOOLEAN, optional=>1, default=>1 },
        },
    );

    my ( $dir, $br, $fatal, $debug )
        = ( $p{'dir'}, $p{'br'}, $p{'fatal'}, $p{'debug'} );

    print "dir_check: checking: $dir..." if $debug;

    unless ( -d $dir && -r $dir ) {
        print "ERROR: No read permissions to $dir: $! $br";
        return 0;
    }
    else {
        print "ok.$br" if $debug;
        return 1;
    }
}

sub footer {
    shift;    # $self
    my $VERSION = shift;

    print <<EOFOOTER;
<hr> <p align="center"><font size="-2">
		<a href="http://mail-toaster.org">Mail::Toaster::Ezmlm</a>
      $VERSION -
		&copy; <a href="http://www.tnpi.net">The Network People, Inc.</a> 1999-2008 <br><br>
        <!--Donated to the toaster community by <a href="mailto:sam.mayes\@sudhian.com">Sam Mayes</a>--></font>
     </p>
  </body>
</html>
EOFOOTER

}

sub lists_get {

    my $self = shift;
    
    my %p = validate( @_, {
            'domain'  => { type=>SCALAR, },
            'br'      => { type=>SCALAR,  optional=>1, default=>'<br>' },
            'fatal'   => { type=>BOOLEAN, optional=>1, default=>1 },
            'debug'   => { type=>BOOLEAN, optional=>1, default=>1 },
        },
    );

    my ( $domain, $br, $fatal, $debug )
        = ( $p{'domain'}, $p{'br'}, $p{'fatal'}, $p{'debug'} );

    my %lists;

    $util->install_module( "vpopmail", debug => $debug,);

    require vpopmail;

    my $dir = vpopmail::vgetdomaindir($domain);

    unless ( -d $dir ) {
        print
          "FAILED: invalid directory ($dir) returned from vgetdomaindir $br";
        return 0;
    }

    print "domain dir for $domain: $dir $br" if $debug;

    print "now fetching a list of ezmlm lists..." if $debug;

    foreach my $all ( $util->get_dir_files( dir => $dir ) ) {
        next unless ( -d $all );

        foreach my $second ( $util->get_dir_files( dir => $all ) ) {
            next unless ( -d $second );
            if ( $second =~ /subscribers$/ ) {
                print "found one: $all, $second $br" if $debug;
                my ( $path, $list_dir ) = $util->path_parse($all);
                print "list name: $list_dir $br" if $debug;
                $lists{$list_dir} = $all;
            }
            else {
                print "failed second match: $second $br" if $debug;
            }
        }
    }

    print "done. $br" if $debug;

    return \%lists;
}

sub logo {

    my $self = shift;
    
    my %p = validate( @_, {
            'conf'         => { type=>HASHREF, optional=>1, },
	        'web_logo_url' => { type=>SCALAR,  optional=>1, },
	        'web_logo_alt' => { type=>SCALAR,  optional=>1, },
            'fatal'        => { type=>BOOLEAN, optional=>1, default=>1 },
            'debug'        => { type=>BOOLEAN, optional=>1, default=>1 },
        },
    );

	my ($conf, $logo, $alt, $fatal, $debug)
        = ( $p{'conf'}, $p{'web_logo_url'}, $p{'web_logo_alt'}, $p{'fatal'}, $p{'debug'} );

    $logo ||= $conf->{'web_logo_url'}
        || "http://www.tnpi.net/images/head.jpg";
        
    $alt ||= $conf->{'web_logo_alt_text'}
        || "tnpi.net logo";

    return "<img src=\"$logo\" alt=\"$alt\">";
}

sub process_cgi {

    my $self = shift;
    
    my %p = validate( @_, {
            'list_dir' => { type=>SCALAR,  optional=>1, },
            'br'       => { type=>SCALAR,  optional=>1, default=>'<br>' },
            'fatal'    => { type=>BOOLEAN, optional=>1, default=>1 },
            'debug'    => { type=>BOOLEAN, optional=>1, default=>1 },
        },
    );

    my ( $list_dir, $br, $fatal, $debug )
        = ( $p{'list_dir'}, $p{'br'}, $p{'fatal'}, $p{'debug'} );

    my ( $mess, $ezlists, $authed );

    use CGI qw(:standard);
    use CGI::Carp qw( fatalsToBrowser );
    print header('text/html');

    #use Mail::Toaster::CGI;

    $util->install_module( "HTML::Template", debug      => $debug,);

    my $conf = $toaster->parse_config( file=>"toaster.conf", debug => 0 );

    #die "FAILURE: Could not find toaster.conf!\n" unless $conf;

    $debug = 0;

    my $cgi = CGI->new;

    # get settings from HTML form submission
    my $domain   = param('domain')   || '';
    my $password = param('password') || '';
    my $list_sel = param('list');
    my $action   = param('action');

    unless ($list_sel) { $mess .= " select a list from the menu" }
    unless ($action)   { $mess .= " select an action.<br>" }

    # display create the HTML form
    my $template = HTML::Template->new( filename => 'ezmlm.tmpl' );

    $template->param( logo => $self->logo(conf=>$conf) );
    $template->param( head => 'Ezmlm Mailing List Import Tool' );
    $template->param(
        domain => '<input name="domain" type="text" value="' . $domain
          . '" size="20">' );
    $template->param(
            password => '<input name="password" type="password" value="'
          . $password
          . '" size="20">' );
    $template->param( action =>
'<input name="action"   type="radio" value="list"> List <input name="action" type="radio" value="add">Add <input name="action" type="radio" value="remove"> Remove'
    );

    my $list_of_lists = '<select name="list">';

    if ( $domain && $password ) {
        print "we got a domain ($domain) & password ($password)<br>" if $debug;

        $authed = $self->authenticate( domain=>$domain, password=>$password, debug=>$debug );

        if ($authed) {
            $ezlists = $self->lists_get( domain=>$domain, br=>$br, debug=>$debug );
            print "WARNING: couldn't retrieve list of ezmlm lists!<br>"
              unless $ezlists;

            foreach my $key ( keys %$ezlists ) {
                $list_of_lists .=
                  '<option value="' . $key . '">' . $key . '</option>'
                  if $key;
            }
        }
    }
    else { $mess = "authentication information is missing!<br>"; }

    $list_of_lists .= '</select>';

    $template->param( instruct => $mess );
    $template->param( list     => $list_of_lists );

    print $template->output;

    if ( $action && $list_sel ) {
        unless ($authed) {
            print "skipping processing because authentication failed!<br>";
            exit 0;
        }

        $util->install_module( "vpopmail", debug => $debug,);
        print "running vpopmail v", vpopmail::vgetversion(), "<br>" if $debug;

        $util->install_module( "Mail::Ezmlm", debug => $debug,);
        require Mail::Ezmlm;

        $list_dir = $ezlists->{$list_sel};
        return 0 unless $self->dir_check( dir=>$list_dir, br=>$br, debug=>$debug );
        my $list = new Mail::Ezmlm($list_dir);

        if ( $action eq "list" ) {
            $self->subs_list( list=>$list, list_dir=>$list_dir, br=>$br, debug=>$debug );
        }
        elsif ( $action eq "add" ) {
            my @reqs = split( "\n", param('addresses') );
            print "reqs: @reqs<br>" if $debug;
            my $requested = \@reqs;
            $self->subs_add( list=>$list, list_dir=>$list_dir, requested=>$requested, br=>$br );
        }
        else {
            print "Sorry, action $action is not supported yet.<br>";
        }
    }
    else {
        print "missing auth, action, or lists<br>";
    }

    $self->footer($VERSION);
}

sub process_shell {

    my ($self) = @_;
    use vars qw($opt_a $opt_d $opt_f $opt_v $list $debug);

    $util->install_module( "Mail::Ezmlm", debug => 0,);
    require Mail::Ezmlm;

    use Getopt::Std;
    getopts('a:d:f:v');

    my $br = "\n";
    $opt_v ? $debug = 1 : $debug = 0;

    # set up based on command line options
    my $list_dir;
    $list_dir = $opt_d if $opt_d;

    # set a default list dir if not already set
    if (! $list_dir) {
        print "You didn't set the list directory! Use the -d option!\n";
        pod2usage;
    }
    return 0 if ! $self->dir_check( dir=>$list_dir, br=>$br, debug=>$debug );

    if ( $opt_a && $opt_a eq "list" ) {
        $list = new Mail::Ezmlm($list_dir);
        $self->subs_list( list=>$list, list_dir=>$list_dir, br=>$br, debug=>$debug );
        return 1;
    }

    unless ( $opt_a && $opt_a eq "add" ) {
        pod2usage();
        return 0;
    }

    # since we're adding, fetch a list of email addresses
    my $requested;
    my $list_file = $opt_f;
    $list_file ||= "ezmlm.importme";

    unless ( -e $list_file ) {
        print "FAILED: cannot find $list_file!\n Try specifying it with -f.\n";
        return 0;
    }

    if ( -r $list_file ) {
        my @lines = $util->file_read($list_file, debug=>$debug);
        $requested = \@lines;
    }
    else {
        print "FAILED: $list_file not readable!\n";
        return 0;
    }

    $list = new Mail::Ezmlm($list_dir);

    #$list->setlist($list_dir);    # use this to switch lists

    $self->subs_add( list=>$list, list_dir=>$list_dir, requested=>$requested, br=>$br );

    return 1;
}

sub subs_add {

    my $self = shift;
    
    my %p = validate( @_, {
	        'list'      => { type=>SCALAR,   },
            'list_dir'  => { type=>SCALAR,   },
	        'requested' => { type=>ARRAYREF, },
            'br'        => { type=>SCALAR,   },
            'fatal'     => { type=>BOOLEAN, optional=>1, default=>1 },
            'debug'     => { type=>BOOLEAN, optional=>1, default=>1 },
        },
    );

	my ($list, $list_dir, $requested, $br, $fatal, $debug) 
        = ( $p{'list'}, $p{'list_dir'}, $p{'requested'}, $p{'br'}, $p{'fatal'}, $p{'debug'} );
	
	if ( ! -d $list_dir ) {
        print "ERROR: Aiiieee, the list $list_dir is missing!\n" if $debug;
        return 0;
    }
    
    my ( $duplicates, $success, $failed, @list_dups, @list_success,
        @list_fail );

    print "$br";

    unless ( $requested && $requested->[0] ) {
        print "FAILURE: no list of addresses was supplied! $br";
        exit 0;
    }

    foreach my $addy (@$requested) {
        $addy = lc($addy);    # convert it to lower case
        chomp($addy);
        ($addy) = $addy =~ /([a-z0-9\.\-\@]*)/;

        printf "adding %25s...", $addy;

        no warnings;
        require Email::Valid;
        unless ( Email::Valid->address($addy) ) {
            print "FAILED! (address fails $Email::Valid::Details check). $br";
            $failed++;
            next;
        }
        use warnings;

        if ( $list->issub($addy) ) {
            $duplicates++;
            push @list_dups, $addy;
            print "FAILED (duplicate). $br";
        }
        else {
            if ( $list->sub($addy) ) {
                print "ok. $br";
                $success++;
            }
            else {
                print "FAILED! $br";
                $failed++;
            }
        }
    }

    print " $br $br --- STATISTICS ---  $br $br";
    printf "duplicates...%5d  $br", $duplicates;
    printf "success......%5d  $br", $success;
    printf "failed.......%5d  $br", $failed;
}

sub subs_list {

    my $self = shift;

    my %p = validate( @_, {
	        'list'      => { type=>HASHREF,   },
            'list_dir'  => { type=>SCALAR,   },
            'br'        => { type=>SCALAR,  optional=>1, default=>'\n' },
            'fatal'     => { type=>BOOLEAN, optional=>1, default=>1 },
            'debug'     => { type=>BOOLEAN, optional=>1, default=>1 },
        },
    );

    my ( $list, $list_dir, $br, $fatal, $debug )
        = ( $p{'list'}, $p{'list_dir'}, $p{'br'}, $p{'fatal'}, $p{'debug'} );

    if ( ! -d $list_dir ) {
        print "ERROR: Aiiieee, the list $list_dir is missing!\n" if $debug;
        return 0;
    }
    print "subs_list: listing subs for list $list_dir $br" if $debug;

    #	print "subscriber list: ";
    #	$list->list;                 # list subscribers
    #	#$list->list(\*STDERR);       # list subscribers
    #	"\n";

    print "subs_list: getting list of subscribers...$br$br" if $debug;

    foreach my $sub ( $list->subscribers ) {
        print "$sub $br";
    }

    print "$br done. $br";
}


1;
__END__

# =head1 ACKNOWLEDGEMENTS
#
# Funded by Sam Mayes (sam.mayes@sudhian.com) and donated to the toaster community
# I'll add this back in if Sam ever pays up.

=head1 NAME

Mail::Toaster::Ezmlm - a batch processing tool for ezmlm mailing lists

=head1 SYNOPSIS

     ezmlm.cgi -a [ add | remove | list ]

     -a   action  - add, remove, list
     -d   dir     - ezmlm list directory
     -f   file    - file containing list of email addresses
     -v   verbose - print debugging options


=head1 DESCRIPTION

Ezmlm.cgi is a command line and CGI application that allows a domain administrator (ie, postmaster@example.com) to add, remove, and list batches of email addresses. You can use this utility to subscribe lists of email addresses, delete a list of addresses, or simply retrieve a list of subscribers. 


=head1 DEPENDENCIES

 some functions depend on Mail::Ezmlm;
 authentication depends on "vpopmail" (a perl extension)

If you need to run ezmlm.cgi suid, which is likely the case, then hacks to Mail::Ezmlm are required for the "list" function to work in taint mode. Also, for a perl script to run suid, you must have suidperl installed. Another (better) approach is to use Apache suexec instead of suidperl. 


=head1 METHODS

=over

=item new

Creates a new Mail::Toaster::Ezmlm object.

   use Mail::Toaster::Ezmlm;
   my $ez = Mail::Toaster::Ezmlm;


=item authenticate

Authenticates a HTTP user against vpopmail to verify the user has permission to do what they're asking.


=item dir_check

Check a directory and see if it's a directory and readable.

    $ezmlm->dir_check(dir=>$dir);

return 0 if not, return 1 if OK.


=item lists_get

Get a list of Ezmlm lists for a given mail directory. This is designed to work with vpopmail where all the list for example.com are in ~vpopmail/domains. 

    $ezmlm->lists_get("example.com");


=item logo

Put the logo on the HTML page. Sets the URL from $conf.

    $ezmlm->logo(conf=>$conf);

$conf is values from toaster.conf.

 Example: 
    $ezmlm->logo(
        web_logo_url => 'http://www.tnpi.net/images/head.jpg',
        web_log_alt  => 'tnpi.net logo',
    );


=item process_cgi

Accepts input from HTTP requests, presents a HTML request form, and triggers actions based on input.

   $ez->process_cgi();


=item process_shell

Get input from the command line options and proceed accordingly.


=item subs_add

Subcribe a user (or list of users) to a mailing list.

   $ezmlm->subs_add(
       list      => $list_name, 
       list_dir  => $list_dir, 
       requested => $address_list
    );


=item subs_list

Print out a list of subscribers to an Ezmlm mailing list.

    $ezmlm->subs_list(list=>$list, dir=>$list_dir);


=back

=head1 AUTHOR

Matt Simerson (matt@tnpi.net)


=head1 BUGS

None known. Report any to author.


=head1 TODO

=head1 SEE ALSO

The following are all man/perldoc pages: 

 Mail::Toaster 
 Mail::Toaster::Conf
 toaster.conf
 toaster-watcher.conf

 http://mail-toaster.org/


=head1 COPYRIGHT AND LICENSE

Copyright (c) 2005-2008, The Network People, Inc.  All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

