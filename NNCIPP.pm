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

    my $xml = $self->_SendItemRequested(
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

# this will simplify testing
sub _SendItemRequested {
    my ($self, %args) = @_;
    my $required = sub {
        my (@k) = @_;
        my @out = map {
            exists $args{$_} or Carp::croak "argument {$_} is required";
            use Data::Dumper; warn Dumper([$_ => $args{$_}]);
            $args{$_};
        } @k;
        return @out if wantarray;
        return $out[0];
    };

    return _build_xml(
        ItemRequested => [
            InitiationHeader => [ # The InitiationHeader, stating from- and to-agency, is mandatory.
                FromAgencyId => [ AgencyId => $required->('from_agency') ],
                ToAgencyId => [ AgencyId => $required->('to_agency') ],
            ],
            UserId => [ # The UserId must be a NLR-Id (National Patron Register) -->
                UserIdentifierValue => $required->('userid'),
            ],
            ItemId => [ # The ItemId must uniquely identify the requested Item in the scope of the FromAgencyId. -->
                        # The ToAgency may then mirror back this ItemId in a RequestItem-call to order it.-->
                        # Note: NNCIPP do not support use of BibliographicId insted of ItemId, in this case. -->
                ItemIdentifierType => 'Barcode',
                ItemIdentifierValue => $required->('barcode'),
            ],
            RequestType => [ # The RequestType must be one of the following: -->
                             # Physical, a loan (of a physical item, create a reservation if not available) -->
                             # Non-Returnable, a copy of a physical item - that is not required to return -->
                             # PhysicalNoReservation, a loan (of a physical item), do NOT create a reservation if not available -->
                             # LII, a patron initialized physical loan request, threat as a physical loan request -->
                             # LIINoReservation, a patron initialized physical loan request, do NOT create a reservation if not available -->
                             # Depot, a border case; some librarys get a box of (foreign language) books from the national library -->
                             # If your library dont recive 'Depot'-books; just respond with a \"Unknown Value From Known Scheme\"-ProblemType -->
                $required->('request_type'),
            ],
            RequestScopeType => [ # RequestScopeType is mandatory and must be \"Title\", signaling that the request is on title-level -->
                                  # (and not Item-level - even though the request was on a Id that uniquely identify the requested Item) -->
                "Title",
            ],
            ItemOptionalFields => [ # Include ItemOptionalFields.BibliographicDescription if you wish to recive Bibliographic data in the response -->
                BibliographicDescription => [ # BibliographicDescription is used, as needed, to supplement the ItemId -->
                    %{$required->('bibliographic_description')},
                ],
            ],
        ]
    );
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

=head2 _build_xml

Build a proper NCIP XML document (with niso.org namespaces) from an Array references tree

e.g.:

    _build_xml(
        ItemRequest => [
            Foo => "foo",
        ]);

will return:

    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <ns1:NCIPMessage xmlns:ns1="http://www.niso.org/2008/ncip" ns1:version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">
      <ns1:ItemRequest>
        <ns1:Foo>foo</ns1:Foo>
      </ns1:ItemRequest>
    </ns1:NCIPMessage>

=cut

sub _build_xml {
    my (@data) = @_;

    my $doc = XML::LibXML::Document->new('1.0', 'UTF-8');
    $doc->setStandalone(1);

    #my $ns = XML::LibXML::Namespace->new('http://www.niso.org/2008/ncip');

    my $root = $doc->createElement('NCIPMessage');
    $root->setNamespace('http://www.niso.org/2008/ncip' => 'ns1' => 1);
    $root->setAttributeNS('http://www.niso.org/2008/ncip' => 'version' => 'http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd');
    $doc->setDocumentElement($root);

    my $appender; $appender = sub {
        my ($parent, $data) = @_;
        if (ref $data) {
            my @list = @$data;
            while(@list) {
                my $name = shift @list;
                my $data = shift @list;

                my $node = $doc->createElement($name);
                $node->setNamespace('http://www.niso.org/2008/ncip' => ns1 => 1);
                $parent->appendChild($node);
                $appender->($node, $data) if $data;
            }
        } else {
            $parent->appendText($data);
        }
    };
    $appender->($root, \@data);

    return $doc;
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
