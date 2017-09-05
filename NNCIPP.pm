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
use C4::Circulation qw( AddIssue CanBookBeIssued AddReturn );
use C4::Items;
use C4::Log;
use C4::Members;
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
    my ( $self, $biblionumber, $borrower, $userid, $request_type ) = @_;

    $biblionumber or die "you must specify a biblionumber";
    $borrower or die "you must specify a borrower";
    $request_type = 'Physical' unless $request_type;

    my $borrowernumber = $borrower->borrowernumber or die "no borrowernumber";
    my $nncip_uri = GetBorrowerAttributeValue( $borrowernumber, 'nncip_uri' ) or die "no nncip_uri for '$borrowernumber'";

    # Get more data about the record
    my $bibliodata   = GetBiblioData( $biblionumber ) or die "can't find biblionumber: $biblionumber";

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
        request_type => $request_type,
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

=head2 SendRequestItem

Send a RequestItem. This is always from the Home Library to the Owner Library.

=cut

sub SendRequestItem {
    my ( $self, $args ) = @_;
    my $agency_bnum = $args->{borrowernumber}; # $args->{ordered_from_borrowernumber};
    my $nncip_uri = GetBorrowerAttributeValue( $agency_bnum, 'nncip_uri' ) or die "no nncip_uri for '$agency_bnum'";

    my %types = (
        'barcode' => 'Barcode',
        'isbn'    => 'ISBN',
        'issn'    => 'ISSN',
        'ean'     => 'EAN',
        'rfid'    => 'RFID',
    );

    # Construct ItemIdentifierType and ItemIdentifierValue
    my $ItemIdentifierType  = $types{ lc $args->{'ItemIdentifierType'} } or die "invalid ItemIdentifierType: '$args->{ItemIdentifierType}'";
    my $ItemIdentifierValue = $args->{'ItemIdentifierValue'} or die "missing ItemIdentifierValue";

    my $xml = $self->{XML}->RequestItem(
        from_agency => "NO-".C4::Context->preference('ILLISIL'),
        to_agency => "NO-".$args->{ordered_from},
        userid => $args->{cardnumber},
        item_type => $ItemIdentifierType,
        item_id => $ItemIdentifierValue,
        request_type => $args->{RequestType},
        request_id => $args->{illrequest_id},
        agency_id => "NO-".C4::Context->preference('ILLISIL'),
    );

    return _send_message( 'RequestItem', $xml->toString(), $nncip_uri);
}

=head3 SendCancelRequestItem

Send a CancelRequestItem. 

This can be called in two scenarios: 

1. Cancellation by the Home Library (#10)

After a RequestItem has been sent, and before the Owner Library has sent an
ItemShipped, the Home Library can decide to cancel a RequestItem. The status
at the Home Library will change from H_REQUESTITEM to DONE.

2. Cancellation by the Owner Library (#11)

After the Owner Library has received a RequestItem, it can decide that the
requested item can not be lent (it might be e.g. missing from the shelf). The
Owner Library will then send a CancelRequestItem to the Home Library, and the
status at the Owner Library will change from O_REQUESTITEM to DONE.

=cut

sub SendCancelRequestItem {

    my ( $self, $params ) = @_;

    my $req = $params->{request};
    my $patron = $req->patron;

    my $cancelled_by;
    my $other_library;
    my $agency_id;
    my $request_id;
    my $user_id;
    if ( $req->status eq 'H_REQUESTITEM' ) {
        # 1. Cancellation by the Home Library (#10)
        $cancelled_by = 'CancelledBy.Borrower';
        $other_library = $req->illrequestattributes->find({ type => 'ordered_from_borrowernumber' })->value;
        $agency_id = 'NO-' . C4::Context->preference('ILLISIL');
        $request_id = $req->illrequest_id;
        $user_id = _borrowernumber2cardnumber( $req->borrowernumber );
    } elsif ( $req->status eq 'O_REQUESTITEM' ) {
        # 2. Cancellation by the Owner Library (#11)
        $cancelled_by = 'CancelledBy.Lender';
        $other_library = $patron->borrowernumber;
        $agency_id = 'NO-' . _borrowernumber2cardnumber( $patron->borrowernumber );
        $request_id = $req->illrequestattributes->find({ type => 'RequestIdentifierValue' })->value,
        $user_id = $req->illrequestattributes->find({ type => 'UserIdentifierValue' })->value;
    }

    my $xml = $self->{XML}->CancelRequestItem(
        from_agency => "NO-".C4::Context->preference('ILLISIL'), # Us
        to_agency => "NO-"._borrowernumber2cardnumber( $other_library ),
        agency_id => $agency_id, # For the RequestId
        request_id => $request_id,
        itemidentifiertype => $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value,
        itemidentifiervalue => $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value,
        userid => $user_id,
        request_type => $req->illrequestattributes->find({ type => 'RequestType' })->value,
        cancelled_by => $cancelled_by,
    );

    my $nncip_uri = GetBorrowerAttributeValue( $other_library, 'nncip_uri' ) or die "nncip_uri missing for borrower: ".$other_library;
    my $response = _send_message( 'CancelRequestItem', $xml->toString(1), $nncip_uri );

    # Check the response, change the status
    if ( $response->{'success'} == 1 && $response->{'problem'} == 0 ) {
        warn "OK";
        $req->status( 'DONE' )->store;
    } else {
        # TODO
        warn "NOT OK";
        warn Dumper $response;
    }

    return $response;

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
    my $patron = $req->patron;

    # Set up the values that differ for the two scenarios described in the POD
    my $shipped_by;
    my $new_status;
    my $other_library;
    my $agency_id;
    my $request_id;
    my $user_id;
    if ( $req->status eq 'O_REQUESTITEM' ) {
        # 1. Owner sends to Home
        $shipped_by = 'ShippedBy.Lender';
        $new_status = 'O_ITEMSHIPPED';
        $other_library = $patron->borrowernumber;
        $agency_id = 'NO-' . _borrowernumber2cardnumber( $patron->borrowernumber );
        $request_id = $req->illrequestattributes->find({ type => 'RequestIdentifierValue' })->value,
        $user_id = $req->illrequestattributes->find({ type => 'UserIdentifierValue' })->value;
        # Add a loan/issue, so we can keep track of it and renew it later
        if ( $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value eq 'Barcode' && $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value ) {
            # Get the data we need
            my $borrower = GetMember( borrowernumber => $patron->borrowernumber );
            my $barcode = $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value;
            # Check if the book can be issued
            # FIXME For now we put this in a warn, we should use it for something clever
            my ( $issuingimpossible, $needsconfirmation ) =  CanBookBeIssued( $borrower, $barcode );
            warn "issuingimpossible: " . Dumper $issuingimpossible;
            warn "needsconfirmation: " . Dumper $needsconfirmation;
            # Make the actual issue
            my $issue = AddIssue( $borrower, $barcode );
        } else {
            # FIXME Return an NCIP error
            warn "NO ISSUE ADDED";
            warn "ItemIdentifierType:  " . $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value;
            warn "ItemIdentifierValue: " . $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value;
        }
    } elsif ( $req->status =~ m{^(H_ITEMRECEIVED|H_RENEWALREJECTED)$} ) {
        # 2. Home sends to Owner
        $shipped_by = 'ShippedBy.Borrower';
        $new_status = 'H_RETURNED';
        $other_library = $req->illrequestattributes->find({ type => 'ordered_from_borrowernumber' })->value;
        $agency_id = 'NO-' . C4::Context->preference('ILLISIL');
        $request_id = $req->illrequest_id;
        $user_id = _borrowernumber2cardnumber( $req->borrowernumber );
    } else {
        die "wrong status: ".$req->status;
    }

    my $xml = $self->{XML}->ItemShipped(
        from_agency => "NO-".C4::Context->preference('ILLISIL'), # Us
        to_agency => "NO-"._borrowernumber2cardnumber( $other_library ),
        agency_id => $agency_id, # For the RequestId
        request_id => $request_id,
        itemidentifiertype => $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value,
        itemidentifiervalue => $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value,
        userid => $user_id,
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
    my $nncip_uri = GetBorrowerAttributeValue($other_library, 'nncip_uri') or die "nncip_uri missing for borrower: ".$other_library;
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
    my $patron = $req->patron;

    # Set up the values that differ for the two scenarios described in the POD
    my $received_by;
    my $new_status;
    my $other_library;
    my $agency_id;
    my $request_id;
    if ( $req->status eq 'H_ITEMSHIPPED' ) {
        # 1. Home has received from Owner (#5)
        $received_by = 'ReceivedBy.Borrower';
        $new_status = 'H_ITEMRECEIVED';
        $other_library = $req->illrequestattributes->find({ type => 'ordered_from_borrowernumber' })->value;
        $agency_id = 'NO-' . C4::Context->preference('ILLISIL');
        $request_id = $req->illrequest_id;
    } elsif ( $req->status eq 'O_RETURNED' ) {
        # 2. Owner has received from Home (#7)
        $received_by = 'ReceivedBy.Lender';
        $new_status = 'DONE';
        $other_library = $patron->borrowernumber;
        $agency_id = $req->illrequestattributes->find({ type => 'AgencyId' })->value;
        $request_id = $req->illrequestattributes->find({ type => 'RequestIdentifierValue' })->value;
        # Mark the loan/issue as returned
        if ( $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value eq 'Barcode' && $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value ) {
            my $barcode = $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value;
            # FIXME Branch (second argument of AddReturn) is hardcoded to ILL, for now. Should probably be the branch of the logged in user? 
            my ($doreturn, $messages, $iteminformation, $borrower) = AddReturn( $barcode, 'ILL' );
            warn 'doreturn: ' . $doreturn;
            warn Dumper $messages;
            warn 'iteminformation.barcode: ' . $iteminformation->{'barcode'};
            warn 'borrower.borrowernumber: ' . $borrower->{'borrowernumber'};
        } else {
            # FIXME Handle other identifiers
        }
    }

    my $xml = $self->{XML}->ItemReceived(
        from_agency => "NO-".C4::Context->preference('ILLISIL'), # Us
        to_agency => "NO-"._borrowernumber2cardnumber( $other_library ),
        agency_id => $agency_id, # For the RequestId
        request_id => $request_id,
        itemidentifiertype => $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value,
        itemidentifiervalue => $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value,
        date_received => '2017-05-15', # FIXME Use date and time now
        received_by => $received_by,
    );

    my $nncip_uri = GetBorrowerAttributeValue( $other_library, 'nncip_uri' ) or die "nncip_uri missing for borrower: ".$other_library;
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

=head2 SendRenewItem

Send a RenewItem message. This can only be sent from the Home Library to the
Owner Library.

We can only ask to renew an item if the status is H_ITEMRECEIVED. Immediately
when the request for renewal is sent, we will set the status to H_RENEWITEM. This
way we can catch requests that fail, without a valid response from the Owner
Library. 

If the request for renewal is confirmed, we change the status back to
H_ITEMRECEIVED. 

If it is not confirmed (renewal was not possible) we set the status to
H_RENEWALREJECTED, so librarians can pick up on it.

=cut

sub SendRenewItem {

    my ( $self, $params ) = @_;

    my $req = $params->{request};

    my $xml = $self->{XML}->RenewItem(
        from_agency         => "NO-".C4::Context->preference('ILLISIL'), # Us
        to_agency           => "NO-"._borrowernumber2cardnumber( $req->illrequestattributes->find({ type => 'ordered_from_borrowernumber' })->value ),
        userid              => _borrowernumber2cardnumber( $req->borrowernumber ),
        itemidentifiertype  => $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value,
        itemidentifiervalue => $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value,
    );

    my $nncip_uri = GetBorrowerAttributeValue( $req->illrequestattributes->find({ type => 'ordered_from_borrowernumber' })->value, 'nncip_uri' ) or die "nncip_uri missing for borrower: ".$req->borrowernumber;
    my $response = _send_message( 'RenewItem', $xml->toString(1), $nncip_uri );
    $req->status( 'H_RENEWITEM' )->store;

    # Check the response, change the status
    if ( $response->{'success'} == 1 && $response->{'problem'} == 0 ) {
        warn "Renewal OK";
        $req->status( 'H_ITEMRECEIVED' )->store;
        # FIXME Use an illrequestattribute to count the number of renewals
        # FIXME Extend the due date of the loan, so the patron does not get reminders/fines
    } elsif ( $response->{'success'} == 1 && $response->{'problem'} == 1 ) {
        warn "Renewal NOT OK";
        $req->status( 'H_RENEWALREJECTED' )->store;
        # FIXME Send a message to the patron?
    } else {
        # TODO
        warn "Response to renewal request NOT OK";
        warn Dumper $response;
    }

    return $response;

}

=head1 INTERNAL SUBROUTINES

=head2 _borrowernumber2cardnumber

Given a borrowernumber, return the corresponding cardnumber.

=cut

sub _borrowernumber2cardnumber {

    my ( $borrowernumber ) = @_;
    my $borrower = GetMember( 'borrowernumber' => $borrowernumber );
    return $borrower->{cardnumber};

}

=head2 _cardnumber2borrowernumber

Given a cardnumber, return the corresponding borrowernumber.

=cut

sub _cardnumber2borrowernumber {

    my ( $cardnumber ) = @_;
    my $borrower = GetMember( 'cardnumber' => $cardnumber );
    return $borrower->{borrowernumber};

}

=head2 _send_message

Do the actual sending of XML messages to NCIP endpoints.

=cut

sub _send_message {
    my ( $req, $msg, $endpoint ) = @_;
    $msg or die "missing message";
    $endpoint or die "missing endpoint"; warn "talking to $endpoint";

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
