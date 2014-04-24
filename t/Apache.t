#!/usr/bin/perl
use strict;
use warnings;
use Cwd;
use English qw( -no_match_vars );

use Test::More 'no_plan';

use lib "lib";

BEGIN { 
    use_ok( 'Mail::Toaster' );
    use_ok( 'Mail::Toaster::Apache' );
}
require_ok( 'Mail::Toaster' );
require_ok( 'Mail::Toaster::Apache' );

my $toaster = Mail::Toaster->new(verbose=>0);

my $apache = Mail::Toaster::Apache->new;
isa_ok( $apache, 'Mail::Toaster::Apache', 'object class' );

# install_apache1

# install_apache2

# startup


# freebsd_extras

    my $apachectl = $apache->util->find_bin( "apachectl", fatal=>0,verbose=>0);
    if ( $apachectl && -x $apachectl ) {
        ok ( -x $apachectl, 'apachectl exists' );

# apache2_fixups
    # icky...this sub needs to be cleaned up
        #$apache->apache2_fixups("apache22");


# conf_get_dir
        my $httpd_conf = $apache->conf_get_dir();
        if ( $httpd_conf && -f $httpd_conf ) {
            print "httpd.conf: $httpd_conf \n";
            ok ( -f $httpd_conf, 'find httpd.conf' );

# apache_conf_patch
            ok( $apache->apache_conf_patch(
                test_ok => 1, 
                verbose => 0,
            ), 'apache_conf_patch');
        };

# install_ssl_certs
        ok( $apache->install_ssl_certs(test_ok=>1, verbose=>0), 'install_ssl_certs');

    };

# restart

# RemoveOldApacheSources

# openssl_config_note
    # just prints a notice, no need to test
    ok( $apache->openssl_config_note(), 'openssl_config_note');

# install_dsa_cert

# install_rsa_cert
    ok( $apache->install_rsa_cert( 
        crtdir => "/etc/httpd", 
        keydir => "/etc/httpd", 
        test_ok=> 1,
        verbose=> 0,
    ), 'install_rsa_cert');
 
