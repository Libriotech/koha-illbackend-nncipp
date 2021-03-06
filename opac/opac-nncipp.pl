#!/usr/bin/perl

# Copyright 2017 Magnus Enger Libriotech
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use CGI qw ( -utf8 );

use C4::Auth;
use C4::Biblio;
use C4::Context;
use C4::Koha;
use C4::Output;
use Koha::Patrons;
use Koha::Illrequests;
use Koha::Illbackends::NNCIPP::NNCIPP;
use Koha::Libraries;
use URI::Escape;

use Data::Dumper; # FIXME Debug

my $cgi = CGI->new();
my ( $template, $borrowernumber, $cookie ) = get_template_and_user(
    {
        template_name   => 'opac-nncipp.tt',
        query           => $cgi,
        type            => 'opac',
        authnotrequired => 0,
    }
);

my $message      = '';
my $query        = $cgi->param('query_value');
my $here         = "/cgi-bin/koha/opac-nncipp.pl";
my $op           = $cgi->param('op');
my $biblionumber = $cgi->param('biblionumber');
my $userid       = $cgi->param('userid');
my $request_type = $cgi->param('request_type');

# Find the logged in user (a library)
my $borrower = Koha::Patrons->new->find( $borrowernumber );
#     || die "You're logged in as the database user. We don't support that.";

# Default: Display "Order | Cancel" links for the given biblionumber

if ( $op eq 'order' && $biblionumber ne '' ) {

    # FIXME Add more checks to make sure the item can be ordered through ILL

    # FIXME Not sure if we should save the request, or just send ItemRequested and wait for RequestItem?
    # my $illrequest   = Koha::Illrequests->new;
    # my $request = $illrequest->request({
    #     'biblionumber' => $biblionumber,
    #     'branch'       => $borrower->{'branchcode'},
    #     'borrower'     => $borrowernumber, # This will be a library, where "NO-$borrowernumber" = ISIL for that library
    #     'remote_user'  => $userid,
    # });
    # $illRequest->save;
    # warn Dumper $illRequest;
    # my $request_id = $request->{'status'}->{'id'};
    # $message = { message => 'order_success', request_id => $request_id };

    # Notify the users home library that this request was made
    # NNCIPP: Use case #3. Call #8.
    my $ncip = Koha::Illbackends::NNCIPP::NNCIPP->new;
    my $ncip_response = $ncip->SendItemRequested( $biblionumber, $borrower, $userid, $request_type );

    $template->param(
        query_value   => $query,
        op            => 'sent',
        biblionumber  => $biblionumber,
        biblio        => GetBiblioData( $biblionumber ),
        message       => $message,
        ncip_response => $ncip_response,
    );

} else {

    $template->param(
        query_value   => $query,
        op            => $op,
        biblionumber  => $biblionumber,
        biblio        => GetBiblioData( $biblionumber ),
        message       => $message,
    );

}

output_html_with_http_headers( $cgi, $cookie, $template->output );
