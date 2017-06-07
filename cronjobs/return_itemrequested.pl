#!/usr/bin/perl

=head1 return_itemrequested.pl

Scan the ILL-requests for requests with status H_ITEMREQUESTED and turn them into
RequestItem messages to the owner library. Update status to H_REQUESTITEM.

=cut

use C4::Members;
use Koha::Illrequests;
use Koha::Illbackends::NNCIPP::NNCIPP;
use Modern::Perl;
use Data::Dumper;

# Find pending requests
my $resultset = Koha::Illrequests->search({ status => 'H_ITEMREQUESTED' });
exit if $resultset->count == 0;

foreach my $req ( $resultset->next ) {

    # Send a RequestItem to the library we made the ItemRequested from
    my $nncipp = Koha::Illbackends::NNCIPP::NNCIPP->new();
    my $patron = GetMember( borrowernumber => $req->borrowernumber );
    my $resp = $nncipp->SendRequestItem({
        'illrequest_id'       => $req->illrequest_id,
        'orderid'             => $req->orderid,
        'cardnumber'          => $patron->{'cardnumber'},
        'borrowernumber'      => $req->illrequestattributes->find({ type => 'ordered_from_borrowernumber' })->value,
        'ordered_from'        => $req->illrequestattributes->find({ type => 'ordered_from' })->value,
        'ItemIdentifierType'  => $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value,
        'ItemIdentifierValue' => $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value,
        'RequestType'         => $req->illrequestattributes->find({ type => 'RequestType' })->value,
    });

    if ( $resp->{success} == 1 ) {
        say $req->illrequest_id . " ok";
        $req->status( 'H_REQUESTITEM' )->store;
    } elsif ( $resp->{success} == 0 ) {
        say $req->illrequest_id . " NOT OK: " . $resp->{msg};
    }

}
