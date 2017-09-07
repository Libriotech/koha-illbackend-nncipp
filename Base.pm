package Koha::Illbackends::NNCIPP::Base;

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

use Modern::Perl;
use DateTime;

use Data::Dumper; # FIXME Debug
use XML::LibXML;
use LWP::UserAgent;
use HTTP::Request;

use Koha::Illbackends::NNCIPP::NNCIPP;
use Koha::Illrequestattribute;
use Koha::Patrons;

=head1 NAME

Koha::Illrequest::Backend::NNCIPP - Koha ILL Backend: NNCIPP

=head1 SYNOPSIS

Koha ILL implementation for the "NNCIPP" backend.

=head1 DESCRIPTION

=head2 Overview

We will be providing the Abstract interface which requires we implement the
following methods:
- create        -> initial placement of the request for an ILL order
- confirm       -> confirm placement of the ILL order
- renew         -> request a currently borrowed ILL be renewed in the backend
- update_status -> ILL module update hook: custom actions on status update
- cancel        -> request an already 'confirm'ed ILL order be cancelled
- status        -> request the current status of a confirmed ILL order
- status_graph  -> return a hashref of additional statuses

Each of the above methods will receive the following parameter from
Illrequest.pm:

  {
      request    => $request,
      other      => $other,
  }

where:

- $REQUEST is the Illrequest object in Koha.  It's associated
  Illrequestattributes can be accessed through the `illrequestattributes`
  method.
- $OTHER is any further data, generally provided through templates .INCs

Each of the above methods should return a hashref of the following format:

    return {
        error   => 0,
        # ^------- 0|1 to indicate an error
        status  => 'result_code',
        # ^------- Summary of the result of the operation
        message => 'Human readable message.',
        # ^------- Message, possibly to be displayed
        #          Normally messages are derived from status in INCLUDE.
        #          But can be used to pass API messages to the INCLUDE.
        method  => 'status',
        # ^------- Name of the current method invoked.
        #          Used to load the appropriate INCLUDE.
        stage   => 'commit',
        # ^------- The current stage of this method
        #          Used by INCLUDE to determine HTML to generate.
        #          'commit' will result in final processing by Illrequest.pm.
        next    => 'illview'|'illlist',
        # ^------- When stage is 'commit', should we move on to ILLVIEW the
        #          current request or ILLLIST all requests.
        value   => {},
        # ^------- A hashref containing an arbitrary return value that this
        #          backend wants to supply to its INCLUDE.
    };

=head2 About NNCIPP

NNCIPP is the "Norwegian NCIP Profile", a subset of NCIP agreed upon by the
Norwegian library system vendors.

This code needs to cooperate with an instance of NCIPServer. See 
L<https://github.com/Libriotech/NCIPServer>.

=head1 API

=head2 Class Methods

=cut

=head3 new

  my $backend = Koha::Illrequest::Backend::NNCIPP->new;

=cut

sub new {
    # -> instantiate the backend
    my ( $class ) = @_;
    my $self = {};
    $self->{ua} = LWP::UserAgent->new(
        agent => "Koha-NNCIP/1.0 (inter library loans module - if abuse contact oha at oha.it)",
    );
    bless( $self, $class );
    return $self;
}

sub name {
    return "NNCIPP";
}

=head3 metadata

Return a hashref containing canonical values from the key/value
illrequestattributes store.

=cut

sub metadata {
    my ( $self, $request ) = @_;
    my $attrs = $request->illrequestattributes;

    if (my $biblio_id = $request->biblio_id) {
        my $b = C4::Biblio::GetBiblio( $biblio_id, 1 );
        use Data::Dumper; warn Dumper($b);
        my $title = $b->{title} // '-';
        my $author = $b->{author} // '-';
        return {
            Title => $title,
            Author => $author,
        };
    }

    my %map = (
        Title => 'title',
        Author => 'author',
    );

    my %attr;
    for my $k (keys %map) {
        my $v = $attrs->find({ type => $map{$k} });
        $attr{$k} = $v->value if defined $v;
    }

    return \%attr;
}


=head3 status_graph

=cut

sub status_graph {
    return {
        # Status where we are Home Library
        H_ITEMREQUESTED => {
            prev_actions => [ ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_ITEMREQUESTED',                   # ID of this status
            name           => 'Item Requested',                   # UI name of this status
            ui_method_name => 'Item Requested',                   # UI name of method leading
                                                           # to this status
            method         => 'create',                    # method to this status
            next_actions   => [ 'H_REQUESTITEM', 'KILL' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-plus',                   # UI Style class
        },
        H_REQUESTITEM => {
            prev_actions => [ 'H_ITEMREQUESTED' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_REQUESTITEM',                   # ID of this status
            name           => 'Item requested from Owner Library',                   # UI name of this status
            ui_method_name => 'Request Item',                   # UI name of method leading
                                                           # to this status
            method         => 'requestitem',                    # method to this status
            next_actions   => [ 'H_CANCELLED', 'H_ITEMRECEIVED' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-send-o',                   # UI Style class
        },
        H_CANCELLED => { # Dummy status
            prev_actions => [ 'H_REQUESTITEM' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_CANCELLED',                   # ID of this status
            name           => 'Cancelled',                   # UI name of this status
            ui_method_name => 'Cancel',                   # UI name of method leading
                                                           # to this status
            method         => 'cancelrequestitem',                    # method to this status
            next_actions   => [  ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-times',                   # UI Style class
        },
        H_ITEMSHIPPED => {
            prev_actions => [  ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_ITEMSHIPPED',                   # ID of this status
            name           => 'Item shipped',                   # UI name of this status
            ui_method_name => 'Ship item',                   # UI name of method leading
                                                           # to this status
            method         => '',                    # method to this status
            next_actions   => [ 'KILL', 'H_ITEMRECEIVED' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-send-o',                   # UI Style class
        },
        H_ITEMRECEIVED => {
            prev_actions => [ 'H_ITEMSHIPPED' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_ITEMRECEIVED',                   # ID of this status
            name           => 'Item received',                   # UI name of this status
            ui_method_name => 'Receive item',                   # UI name of method leading
                                                           # to this status
            method         => 'itemreceived',                    # method to this status
            next_actions   => [ 'KILL', 'H_RETURNED', 'H_RENEWITEM' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-inbox',                   # UI Style class
        },
        H_RENEWITEM => {
            prev_actions => [ 'H_ITEMRECEIVED' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_RENEWITEM',                   # ID of this status
            name           => 'Request for renewal sent',                   # UI name of this status
            ui_method_name => 'Request Renewal',                   # UI name of method leading
                                                           # to this status
            method         => 'renewitem',                    # method to this status
            next_actions   => [ 'H_RENEWITEM' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-inbox',                   # UI Style class
        },
        H_RENEWALREJECTED => {
            prev_actions => [ 'H_RENEWITEM' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_RENEWALREJECTED',                   # ID of this status
            name           => 'Renewal rejected',                   # UI name of this status
            ui_method_name => 'Renewal rejected',                   # UI name of method leading
                                                           # to this status
            method         => 'renewalrejectedok',                    # method to this status
            next_actions   => ['KILL','H_RETURNED'], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-check',                   # UI Style class
        },
        H_RETURNED => {
            prev_actions => [ 'H_ITEMRECEIVED' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_RETURNED',                   # ID of this status
            name           => 'Item returned',                   # UI name of this status
            ui_method_name => 'Return item',                   # UI name of method leading
                                                           # to this status
            method         => 'itemshipped',                    # method to this status
            next_actions   => [ 'KILL', 'DONE' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-inbox',                   # UI Style class
        },

        # Statuses where we are Owner Library
        O_ITEMREQUESTED => {
            prev_actions => [ ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'O_ITEMREQUESTED',                   # ID of this status
            name           => 'Item Requested',                   # UI name of this status
            ui_method_name => 'Item Requested',                   # UI name of method leading
                                                           # to this status
            method         => 'create',                    # method to this status
            next_actions   => [ 'O_REQUESTITEM', 'KILL' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-plus',                   # UI Style class
        },
        O_REQUESTITEM => {
            prev_actions => [ 'O_ITEMREQUESTED' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'O_REQUESTITEM',                   # ID of this status
            name           => 'Item requested by Home Library',                   # UI name of this status
            ui_method_name => 'Request Item',                   # UI name of method leading
                                                           # to this status
            method         => 'requestitem',                    # method to this status
            next_actions   => [ 'KILL', 'O_CANCELLED', 'O_ITEMSHIPPED' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-send-o',                   # UI Style class
        },
        O_CANCELLED => { # Dummy status
            prev_actions => [ 'O_REQUESTITEM' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_CANCELLED',                   # ID of this status
            name           => 'Cancelled',                   # UI name of this status
            ui_method_name => 'Cancel',                   # UI name of method leading
                                                           # to this status
            method         => 'cancelrequestitem',                    # method to this status
            next_actions   => [  ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-times',                   # UI Style class
        },
        O_ITEMSHIPPED => {
            prev_actions => [ 'O_REQUESTITEM' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'O_ITEMSHIPPED',                   # ID of this status
            name           => 'Item shipped to Home Library',                   # UI name of this status
            ui_method_name => 'Ship item',                   # UI name of method leading
                                                           # to this status
            method         => 'itemshipped',                    # method to this status
            next_actions   => [ 'KILL' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-send-o',                   # UI Style class
        },
        O_ITEMRECEIVED => {
            prev_actions => [ 'O_ITEMSHIPPED' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'O_ITEMRECEIVED',                   # ID of this status
            name           => 'Item received',                   # UI name of this status
            ui_method_name => 'Receive item',                   # UI name of method leading
                                                           # to this status
            method         => '',                    # method to this status
            next_actions   => [ 'KILL', 'O_RETURNED' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-inbox',                   # UI Style class
        },
        O_RETURNED => {
            prev_actions => [ 'O_ITEMRECEIVED' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'O_RETURNED',                   # ID of this status
            name           => 'Item returned from Home Library',                   # UI name of this status
            ui_method_name => 'Return item',                   # UI name of method leading
                                                           # to this status
            method         => 'itemreceived',                    # method to this status
            next_actions   => [ 'KILL', 'DONE' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-inbox',                   # UI Style class
        },

        # Common statuses
        DONE => {
            prev_actions => [  ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'DONE',                   # ID of this status
            name           => 'Transaction completed',                   # UI name of this status
            ui_method_name => 'Done',                   # UI name of method leading
                                                           # to this status
            method         => 'itemreceived',                    # method to this status
            next_actions   => [], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-inbox',                   # UI Style class
        },

    };
}

=head3 create

  my $response = $backend->create({
      request    => $requestdetails,
      other      => $other,
  });

This is the initial creation of the request.  Generally this stage will be
some form of search with the backend.

By and large we will not have useful $requestdetails (borrowernumber,
branchcode, status, etc.).

$params is simply an additional slot for any further arbitrary values to pass
to the backend.

This is an example of a multi-stage method.

=cut

#BEGIN {
#    $SIG{__DIE__} = sub {
#        Carp::cluck "DIE[@_]";
#        CORE::die(@_);
#    };
#};

sub create {

    # -> initial placement of the request for an ILL order
    my ( $self, $params ) = @_;
    my $stage = $params->{other}->{stage};

    if (!$stage) { # display a simple form asking for details
        return {
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'create_form',
            value   => {},
        };
    }
    my $request = $params->{request};
    my $borrowernumber = $params->{other}->{borrowernumber}; # TODO Check that we have a valid borrowernumber
    $request->borrowernumber($borrowernumber);
    $request->biblio_id($params->{other}->{biblionumber});

    $request->branchcode($params->{other}->{branchcode});
    $request->medium($params->{other}->{medium});
    $request->status($params->{other}->{status});
    $request->backend($params->{other}->{backend});
    $request->placed(DateTime->now);
    $request->updated(DateTime->now);
    $request->store;
    # ...Populate Illrequestattributes
    while ( my ( $type, $value ) = each %{$params->{other}->{attr}} ) {
        Koha::Illrequestattribute->new({
            illrequest_id => $request->illrequest_id,
            type          => $type,
            value         => $value,
        })->store;
    }

    # There are two times where we create and save to the db a new request:
    # 1. We are the Home Library and received an ItemRequested
    #    The status will be H_ITEMREQUESTED
    #    We should create an orderid with our own ISIL and our own illrequest_id
    # 2. We are the Owner Library and received a RequestItem
    #    The status will be O_REQUESTITEM
    #    We should NOT create a new orderid, but use AgencyId and RequestIdentifierValue
    # Update the saved request with the orderid that we thereby create 
    my $orderid;
    if ( $request->status eq 'H_ITEMREQUESTED' ) {
        $orderid = 'NO-' . C4::Context->preference('ILLISIL') . ':' . $request->illrequest_id;
    } elsif ( $request->status eq 'O_REQUESTITEM' )  {
        my $agencyid = $request->illrequestattributes->find({ type => 'AgencyId' })->value;
        $orderid = $agencyid . ':' . $request->illrequestattributes->find({ type => 'RequestIdentifierValue' })->value;
    }
    $request->orderid( $orderid )->store;

    # -> create response.
    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'create',
        stage   => 'commit',
        next    => 'illview',
        # value   => $request_details,
    };

}

=head2 cancelrequestitem

Send a CancelRequestItem.

=cut

sub cancelrequestitem {

    my ( $self, $params ) = @_;

    my $nncipp = Koha::Illbackends::NNCIPP::NNCIPP->new();
    my $resp = $nncipp->SendCancelRequestItem({
        'request' => $params->{request},
    });

    return {
        error    => 0,
        status   => '',
        message  => '',
        method   => 'cancelrequestitem',
        stage    => 'commit',
        next     => 'illview',
        value    => '',
    };

}

=head2 itemshipped

Send an ItemShipped message to another library as the Owner Library

See also SendItemShippedAsHome.

=cut

sub itemshipped {

    # -> initial placement of the request for an ILL order
    my ( $self, $params ) = @_;

    warn Dumper $params->{request}->illrequest_id;

    my $nncipp = Koha::Illbackends::NNCIPP::NNCIPP->new();
    my $resp = $nncipp->SendItemShipped({
        'request' => $params->{request},
    });

    return {
        error    => 0,
        status   => '',
        message  => '',
        method   => 'itemshipped',
        stage    => 'commit',
        next     => 'illview',
        value    => '',
    };

}

=head2 itemreceived

Send ItemReceived.

=cut

sub itemreceived {

    # -> initial placement of the request for an ILL order
    my ( $self, $params ) = @_;

    warn Dumper $params->{request}->illrequest_id;

    my $nncipp = Koha::Illbackends::NNCIPP::NNCIPP->new();
    my $resp = $nncipp->SendItemReceived({
        'request' => $params->{request},
    });

    return {
        error    => 0,
        status   => '',
        message  => '',
        method   => 'itemreceived',
        stage    => 'commit',
        next     => 'illview',
        value    => '',
    };

}

=head2 renewitem

Send RenewItem, NNCIPP call #9.

=cut

sub renewitem {

    my ( $self, $params ) = @_;

    my $nncipp = Koha::Illbackends::NNCIPP::NNCIPP->new();
    my $resp = $nncipp->SendRenewItem({
        'request' => $params->{request},
    });

    return {
        error    => 0,
        status   => '',
        message  => '',
        method   => 'renewitem',
        stage    => 'commit',
        next     => 'illview',
        value    => '',
    };

}

=head2 renewalrejectedok

Acknowledge that a request for renewal was received. This should not generate
any NCIP messages, just reset the status to H_ITEMRECEIVED.

=cut

sub renewalrejectedok {

    my ( $self, $params ) = @_;

    my $req = $params->{request};
    $req->status( 'H_ITEMRECEIVED' )->store;

    return {
        error    => 0,
        status   => '',
        message  => '',
        method   => 'renewalrejectedok',
        stage    => 'commit',
        next     => 'illview',
        value    => '',
    };

}

=head1 AUTHOR

Magnus Enger <magnus@libriotech.no>

Based on the "Dummy" backend by Alex Sassmannshausen <alex.sassmannshausen@ptfs-europe.com>

=cut

1;
