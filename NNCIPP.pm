package Koha::Illbackends::NNCIPP::NNCIPP;

# Copyright Magnus Enger Libriotech 2017
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

use Koha::Illbackends::NNCIPP::XML;

use C4::Biblio;
use C4::Items;
use C4::Log;
use C4::Members::Attributes qw ( GetBorrowerAttributeValue );

use Data::Dumper; # FIXME Debug
use Carp;
use HTTP::Tiny;
use XML::Simple;

use Modern::Perl;

=head1 NAME

NNCIPP - Norwegian NCIP Protocol

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use Koha::Illbackends::NNCIPP::NNCIPP;

    my $nncipp = Koha::Illbackends::NNCIPP::NNCIPP->new();

=head1 SUBROUTINES/METHODS

=head2 new

=cut

sub new {
    my ( $class ) = @_;
    my $self  = {
        XML => Koha::Illbackends::NNCIPP::XML->new(),
    };
    bless $self, $class;
    return $self;
}


=head2 SendItemRequested

Typically triggered when a library has logged into the OPAC and placed an ILL
request there. This message is sent back to the ILS of the library that made
the request, so that they know what they have requested.

Arguments:

=over 4

=item * $bibliodata = the result of a call to GetBiblioData()

=item * $borrower = the result of a call to Koha::Borrowers->new->find( $borrowernumber )

=item * $userid = The userid/cardnumber of the user that the requested document is meant for, at the Home Library

=back

=cut

sub SendItemRequested {

    my ( $self, $biblionumber, $borrower, $userid ) = @_;

    # FIXME Return with an error if there is no nncip_uri
    my $nncip_uri = GetBorrowerAttributeValue( $borrower->borrowernumber, 'nncip_uri' );

    # Get more data about the record
    my $bibliodata   = GetBiblioData( $biblionumber );

    # Pick out an item to tie the request to (we take the first one that has a barcode)
    my $barcode;
    my @items = GetItemsInfo( $biblionumber );
    foreach my $item ( @items ) {
        if ( $item->{'barcode'} ne '' ) {
            $barcode = $item->{'barcode'};
            last;
        }
    }

    # Pick out the language code from 008, position 35-37
    my $lang_code = _get_langcode_from_bibliodata( $biblionumber );

    my $xml = $self->{XML}->ItemRequested(
        to_agency => "NO-".$borrower->cardnumber,
        from_agency => "NO-".C4::Context->preference('ILLISIL'),
        userid => $userid,
        barcode => $barcode,
        request_type => "Physical",
        bibliographic_description => {
            Author => $bibliodata->{author},
            PlaceOfPublication => $bibliodata->{place},
            PublicationDate => $bibliodata->{copyrightdate},
            Publisher => $bibliodata->{publishercode},
            Title => $bibliodata->{title},
            Language => $lang_code,
            MediumType => "Book", # TODO map from $bibliodata->{itemtype}
        },
    );
    return _send_message( 'ItemRequested', $xml->toString(1), $nncip_uri );
}

sub SendRequestItem {

    my ( $self, $args ) = @_;

    my %types = (
        'barcode' => 'Barcode',
        'isbn'    => 'ISBN',
        'issn'    => 'ISSN',
        'ean'     => 'EAN',
        'rfid'    => 'RFID',
    );

    # Construct ItemIdentifierType and ItemIdentifierValue
    my $ItemIdentifierType  = $types{ lc $args->{'ItemIdentifierType'} };
    my $ItemIdentifierValue = $args->{'ItemIdentifierValue'};

    my $xml = $self->{XML}->RequestItem(
        from_agency => "NO-".C4::Context->preference('ILLISIL'),
        to_agency => "NO-".$args->{ordered_from},
        userid => $args->{cardnumber},
        item_type => $ItemIdentifierType,
        item_id => $ItemIdentifierValue,
        request_type => $args->{RequestType},
        request_id => $args->{illrequest_id},
    );

    return _send_message( 'RequestItem', $xml->toString(), GetBorrowerAttributeValue( $args->{'borrowernumber'}, 'nncip_uri' ) );

    # TODO magnuse, check if the above is ok (it should be, but not easy for me to test) and remove the following when fine

    my ( $AgencyId, $RequestIdentifierValue ) = split /:/, $args->{'orderid'};

    my $msg = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
    <ns1:NCIPMessage xmlns:ns1=\"http://www.niso.org/2008/ncip\" ns1:version=\"http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.niso.org/2008/ncip http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd\">
        <!-- Usage in NNCIPP 1.0 is in use-case 2: A user request a spesific uniqe item, from a external library.  -->
        <ns1:RequestItem>
            <!-- The InitiationHeader, stating from- and to-agency, is mandatory. -->
            <ns1:InitiationHeader>
                <!-- Home Library -->
                <ns1:FromAgencyId>
                    <ns1:AgencyId>NO-" . C4::Context->preference('ILLISIL') . "</ns1:AgencyId>
                </ns1:FromAgencyId>
                <!-- Owner Library -->
                <ns1:ToAgencyId>
                    <ns1:AgencyId>NO-" . $args->{'ordered_from'} . "</ns1:AgencyId>
                </ns1:ToAgencyId>
            </ns1:InitiationHeader>
            <!-- The UserId must be a NLR-Id (National Patron Register) -->
            <ns1:UserId>
                <ns1:UserIdentifierValue>" . $args->{'cardnumber'} . "</ns1:UserIdentifierValue>
            </ns1:UserId>";
    if ( $ItemIdentifierType eq 'Barcode' ) {
            # Barcode or FIXME RFID
            $msg .= "<!-- The ItemId must uniquely identify the requested Item in the scope of the ToAgencyId -->
                    <ns1:ItemId>
                        <!-- All Items must have a scannable Id either a RFID or a Barcode or Both. -->
                        <!-- In the case of both, start with the Barcode, use colon and no spaces as delimitor.-->
                        <ns1:ItemIdentifierType>" . $ItemIdentifierType . "</ns1:ItemIdentifierType>
                        <ns1:ItemIdentifierValue>" . $ItemIdentifierValue . "</ns1:ItemIdentifierValue>
                    </ns1:ItemId>";
    } else {
            # ISBN, ISSN, EAN eller FIXME OwnerLocalRecordID
            $msg .= "<ns1:BibliographicId>
                        <ns1:BibliographicRecordId>
                            <ns1:BibliographicRecordIdentifier>" . $ItemIdentifierValue . "</ns1:BibliographicRecordIdentifier>
                            <!-- Supported BibliographicRecordIdentifierCode is OwnerLocalRecordID, ISBN, ISSN and EAN -->
                            <!-- Supported values of OwnerLocalRecordID is simplyfied to 'LocalId' - each system know it's own values. -->
                            <ns1:BibliographicRecordIdentifierCode>" . $ItemIdentifierType . "</ns1:BibliographicRecordIdentifierCode>
                        </ns1:BibliographicRecordId>
                    </ns1:BibliographicId>";
    }
    $msg .= "<!-- The RequestId must be created by the initializing AgencyId and it has to be globaly uniqe -->
            <ns1:RequestId>
                <!-- The initializing AgencyId must be part of the RequestId -->
                <ns1:AgencyId>NO-" . $AgencyId . "</ns1:AgencyId>
                <!-- The RequestIdentifierValue must be part of the RequestId-->
                <ns1:RequestIdentifierValue>" . $RequestIdentifierValue . "</ns1:RequestIdentifierValue>
            </ns1:RequestId>
            <!-- The RequestType must be one of the following: -->
            <!-- Physical, a loan (of a physical item, create a reservation if not available) -->
            <!-- Non-Returnable, a copy of a physical item - that is not required to return -->
            <!-- PhysicalNoReservation, a loan (of a physical item), do NOT create a reservation if not available -->
            <!-- LII, a patron initialized physical loan request, threat as a physical loan request -->
            <!-- LIINoReservation, a patron initialized physical loan request, do NOT create a reservation if not available -->
            <!-- Depot, a border case; some librarys get a box of (foreign language) books from the national library -->
            <!-- If your library dont recive 'Depot'-books; just respond with a \"Unknown Value From Known Scheme\"-ProblemType -->
            <ns1:RequestType>" . $args->{'RequestType'} . "</ns1:RequestType>
            <!-- RequestScopeType is mandatory and must be \"Title\", signaling that the request is on title-level -->
            <!-- (and not Item-level - even though the request was on a Id that uniquely identify the requested Item) -->
            <ns1:RequestScopeType>Title</ns1:RequestScopeType>
            <!-- Include ItemOptionalFields.BibliographicDescription if you wish to recive Bibliographic data in the response -->
            <ns1:ItemOptionalFields>
                <ns1:BibliographicDescription/>
            </ns1:ItemOptionalFields>
        </ns1:RequestItem>
    </ns1:NCIPMessage>";

    return _send_message( 'RequestItem', $msg, GetBorrowerAttributeValue( $args->{'borrowernumber'}, 'nncip_uri' ) );

}

=head2 SendItemShipped

Send an ItemShipped message. This message can be sent in two different scenarios:

=over 4

=item 1 The Owner Library has sent the book to the Home Library. The status will
change from O_REQUESTITEM to O_ITEMSHIPPED.

=item 2 The Home Library has sent the book back to the Owner Library. Status
changes from H_ITEMRECEIVED to H_RETURNED.

=back

=cut

sub SendItemShipped {

    my ( $self, $params ) = @_;

    my $req = $params->{request};

    # Set up the values that differ for the two scenarios described in the POD
    my $shipped_by;
    my $new_status;
    my $other_library;
    if ( $req->status eq 'O_REQUESTITEM' ) {
        # 1. Owner sends to Home
        $shipped_by = 'ShippedBy.Lender';
        $new_status = 'O_ITEMSHIPPED';
        $other_library = $args->{requested_by};
    } elsif ( $req->status eq 'H_ITEMRECEIVED' ) {
        # 2. Home sends to Owner
        $shipped_by = 'ShippedBy.Borrower';
        $new_status = 'H_RETURNED';
        $other_library = $args->{ordered_from};
    }

    my $xml = $self->{XML}->ItemShipped(
        from_agency => C4::Context->preference('ILLISIL'), # Us
        to_agency => "NO-".$other_library,
        request_id => $req->illrequestattributes->find({ type => 'RequestIdentifierValue' })->value, # Our illrequest_id
        itemidentifiertype => $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value,
        itemidentifiervalue => $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value,
        userid => $req->illrequestattributes->find({ type => 'UserIdentifierValue' })->value,
        date_shipped => '2017-05-15', # FIXME Use date and time now
        address => { # FIXME
            street => 'Narrowgata',
            city => 'Townia',
            country => 'Norway',
            zipcode => '0123',
        },
        # PhysicalAddressType => [], # TODO ??? why an empty tag?
        # bibliographic_description # FIXME "If an alternative Item is shipped to fulfill a loan"
        shipped_by => $shipped_by,
    );

    my $nncip_uri = GetBorrowerAttributeValue( _cardnumber2borrowernumber( $other_library ), 'nncip_uri' );
    my $response = _send_message( 'ItemShipped', $xml->toString(1), $nncip_uri );

    # Check the response, change the status
    if ( $response->{'success'} == 1 && $response->{'problem'} == 0 ) {
        warn "OK";
        $req->status( $new_status )->store;
    } else {
        # TODO
        warn "NOT OK";
        warn Dumper $response;
    }

    return $response;

}

=head2 SendItemReceived

Send an ItemReceived message. Similar to ItemShipped, this will be triggered in
one of two ways:

=over 4

=item 1 The Home Library has received the book from the Owner Library. Status
will change from H_ITEMSHIPPED to H_ITEMRECEIVED.

=item 2 The Owner Library has received the book from the Home Library. Status
will change from O_RETURNED to DONE.

=cut

sub SendItemReceived {

    my ( $self, $params ) = @_;

    my $req = $params->{request};

    # Set up the values that differ for the two scenarios described in the POD
    my $received_by;
    my $new_status;
    my $other_library;
    if ( $req->status eq 'H_ITEMSHIPPED' ) {
        # 1. Home has received from Owner
        $received_by = 'ReceivedBy.Borrower';
        $new_status = 'H_ITEMRECEIVED';
        $other_library = $args->{ordered_from};
    } elsif ( $req->status eq 'O_RETURNED' ) {
        # 2. Owner has received from Home
        $received_by = 'ReceivedBy.Lender';
        $new_status = 'DONE';
        $other_library = $args->{requested_by};
    }

    my $xml = $self->{XML}->ItemReceived(
        from_agency => C4::Context->preference('ILLISIL'), # Us
        to_agency => $other_library,
        request_id => $req->illrequestattributes->find({ type => 'RequestIdentifierValue' })->value,
        itemidentifiertype => $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value,
        itemidentifiervalue => $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value,
        date_received => '2017-05-15', # FIXME Use date and time now
        received_by => $received_by,
    );

    my $nncip_uri = GetBorrowerAttributeValue( _cardnumber2borrowernumber( $other_library ), 'nncip_uri' );
    my $response = _send_message( 'ItemReceived', $xml->toString(1), $nncip_uri );

    # Check the response, change the status
    if ( $response->{'success'} == 1 && $response->{'problem'} == 0 ) {
        warn "OK";
        $req->status( $new_status )->store;
    } else {
        # TODO
        warn "NOT OK";
        warn Dumper $response;
    }

    return $response;

}

=head1 INTERNAL SUBROUTINES

=head2 _cardnumber2borrowernumber

Given a barcode, return the corresponding barcode.

=cut

sub _barcode2borrowernumber {

    my ( $cardnumber ) = @_;
    my $borrower = GetMember( 'cardnumber' => $cardnumber );
    return $borrower->{borrowernumber};

}

=head2 _send_message

Do the actual sending of XML messages to NCIP endpoints.

=cut

sub _send_message {

    my ( $req, $msg, $endpoint ) = @_;

    warn "talking to $endpoint";

    logaction( 'ILL', $req, undef, $msg );
    my $response = HTTP::Tiny->new->request( 'POST', $endpoint, { 'content' => $msg } );

    if ( $response->{success} ){
        # We got a 200 response from the server, but it could still contain a Problem element
        logaction( 'ILL', $req . 'Response', undef, $response->{'content'} );
        # Check if we got a Problem response
        my $problem = 0;
        if ( $response->{'content'} =~ m/ns1:Problem/g ) {
            $problem = 1;
        }
        return {
            'success' => 1,
            'problem' => $problem,
            'msg'     => $response->{'content'},
            'data'    => XMLin( $response->{'content'} ),
        };
    } else {
        my $msg = "ERROR: $response->{status} $response->{reason}";
        logaction( 'ILL', $req . 'Response', undef, $msg );
        return {
            'success' => 0,
            'msg' => $msg,
        };
    }

}


=head2 _get_langcode_from_bibliodata

Take a record and pick ut the language code in controlfield 008, position 35-37.

=cut

sub _get_langcode_from_bibliodata {

    my ( $biblionumber ) = @_;

    my $marcxml = GetXmlBiblio( $biblionumber );
    my $record = MARC::Record->new_from_xml( $marcxml, 'UTF-8' );
    my $f008 = $record->field( '008' )->data();
    my $lang_code = '   ';
    if ( $f008 ) {
        $lang_code = substr $f008, 35, 3;
    }
    return $lang_code;

}

1;
