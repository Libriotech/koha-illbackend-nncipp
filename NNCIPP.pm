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

use C4::Biblio;
use C4::Items;
use C4::Log;
use C4::Members::Attributes qw ( GetBorrowerAttributeValue );

use HTTP::Tiny;
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
    my $self  = {};
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

    my $msg = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
    <ns1:NCIPMessage xmlns:ns1=\"http://www.niso.org/2008/ncip\" ns1:version=\"http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd\"
        xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.niso.org/2008/ncip http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd\">
        <!-- Usage in NNCIPP 1.0 is in use-case 3, call #8: Owner library informs Home library that a user requests one Item -->
        <ns1:ItemRequested>
            <!-- The InitiationHeader, stating from- and to-agency, is mandatory. -->
            <ns1:InitiationHeader>
                <!-- Owner Library -->
                <ns1:FromAgencyId>
                    <ns1:AgencyId>NO-" . C4::Context->preference('ILLISIL') . "</ns1:AgencyId>
                </ns1:FromAgencyId>
                <!-- Home Library -->
                <ns1:ToAgencyId>
                    <ns1:AgencyId>NO-" . $borrower->cardnumber . "</ns1:AgencyId>
                </ns1:ToAgencyId>
            </ns1:InitiationHeader>
            <!-- The UserId must be a NLR-Id (National Patron Register) -->
            <ns1:UserId>
                <ns1:UserIdentifierValue>" . $userid . "</ns1:UserIdentifierValue>
            </ns1:UserId>
            <!-- The ItemId must uniquely identify the requested Item in the scope of the FromAgencyId. -->
            <!-- The ToAgency may then mirror back this ItemId in a RequestItem-call to order it.-->
            <!-- Note: NNCIPP do not support use of BibliographicId insted of ItemId, in this case. -->
            <ns1:ItemId>
                <!-- All Items must have a scannable Id either a RFID or a Barcode or Both. -->
                <!-- In the case of both, start with the Barcode, use colon and no spaces as delimitor.-->
                <ns1:ItemIdentifierType>Barcode</ns1:ItemIdentifierType>
                <ns1:ItemIdentifierValue>" . $barcode . "</ns1:ItemIdentifierValue>
            </ns1:ItemId>
            <!-- The RequestType must be one of the following: -->
            <!-- Physical, a loan (of a physical item, create a reservation if not available) -->
            <!-- Non-Returnable, a copy of a physical item - that is not required to return -->
            <!-- PhysicalNoReservation, a loan (of a physical item), do NOT create a reservation if not available -->
            <!-- LII, a patron initialized physical loan request, threat as a physical loan request -->
            <!-- LIINoReservation, a patron initialized physical loan request, do NOT create a reservation if not available -->
            <!-- Depot, a border case; some librarys get a box of (foreign language) books from the national library -->
            <!-- If your library dont recive 'Depot'-books; just respond with a \"Unknown Value From Known Scheme\"-ProblemType -->
            <ns1:RequestType>Physical</ns1:RequestType>
            <!-- RequestScopeType is mandatory and must be \"Title\", signaling that the request is on title-level -->
            <!-- (and not Item-level - even though the request was on a Id that uniquely identify the requested Item) -->
            <ns1:RequestScopeType>Title</ns1:RequestScopeType>
            <!-- Include ItemOptionalFields.BibliographicDescription if you wish to recive Bibliographic data in the response -->
            <ns1:ItemOptionalFields>
                <!-- BibliographicDescription is used, as needed, to supplement the ItemId -->
                <ns1:BibliographicDescription>
                    <ns1:Author>"             . $bibliodata->{'author'} . "</ns1:Author>
                    <ns1:PlaceOfPublication>" . $bibliodata->{'place'} . "</ns1:PlaceOfPublication>
                    <ns1:PublicationDate>"    . $bibliodata->{'copyrightdate'} . "</ns1:PublicationDate>
                    <ns1:Publisher>"          . $bibliodata->{'publishercode'} . "</ns1:Publisher>
                    <ns1:Title>"              . $bibliodata->{'title'} . "</ns1:Title>
                    <ns1:Language>"           . $lang_code . "</ns1:Language>
                    <ns1:MediumType>Book</ns1:MediumType> <!-- Map from " . $bibliodata->{'itemtype'} . "? -->
                </ns1:BibliographicDescription>
            </ns1:ItemOptionalFields>
        </ns1:ItemRequested>
    </ns1:NCIPMessage>";

    return _send_message( 'ItemRequested', $msg, $nncip_uri );

}

=head1 INTERNAL SUBROUTINES

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