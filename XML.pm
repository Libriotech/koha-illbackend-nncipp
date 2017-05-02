use strict;
use warnings;

package Koha::Illbackends::NNCIPP::XML;

use XML::LibXML;
use Carp;

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


=head1 NAME

NNCIPP - Norwegian NCIP Protocol XML Adapter

=head1 SYNOPSIS

    use Koha::Illbackends::NNCIPP::XML;

    my $adapter = Koha::Illbackends::NNCIPP::XML->new();

    my $req = $adapter->SendItemRequested(
        from_agency => 'NO-01',
        to_agency => 'NO-02',
	userid => $userid,
	barcode => $barcode,
	...
    );

    my $xml_bytes = $req->toString(1); # req is a XML::LibXML document

=head1 DESCRIPTION

Utility class that convert simple data to LibXML documents object


=head2 SendItemRequested

Builds a SendItemRequested XML

=cut

sub  SendItemRequested {
    my ($self, %args) = @_;
    my $required = sub {
        my ($k) = @_;
        exists $args{$k} or Carp::croak "argument {$k} is required";
        $args{$k};
    };

    return $self->build(
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



=head2 build

Build a proper NCIP XML document (with niso.org namespaces) from an Array references tree

e.g.:

    $xml->build(
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

sub build {
    my ($self, @data) = @_;

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

1;
