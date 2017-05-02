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

use XML::LibXML;
use LWP::UserAgent;
use HTTP::Request;

use C4::Members;

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
    return {
        # ID     => $attrs->find({ type => 'id' })->value,
        # Title  => $attrs->find({ type => 'title' })->value,
        # Author => $attrs->find({ type => 'author' })->value,
        # Status => $attrs->find({ type => 'status' })->value,
        # OrderedFrom => $attrs->find({ type => 'ordered_from' })->value,
        ItemIdentifierType  => $attrs->find({ type => 'ItemIdentifierType' })->value,
        ItemIdentifierValue => $attrs->find({ type => 'ItemIdentifierValue' })->value,
        # Language            => $attrs->find({ type => 'Language' })->value,
        # PlaceOfPublication  => $attrs->find({ type => 'PlaceOfPublication' })->value,
        # PublicationDate     => $attrs->find({ type => 'PublicationDate' })->value,
        # Publisher           => $attrs->find({ type => 'Publisher' })->value,
        RequestScopeType    => $attrs->find({ type => 'RequestScopeType' })->value,
        RequestType         => $attrs->find({ type => 'RequestType' })->value,
    }
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
            name           => 'Request Item',                   # UI name of this status
            ui_method_name => 'Request Item',                   # UI name of method leading
                                                           # to this status
            method         => 'requestitem',                    # method to this status
            next_actions   => [ 'H_REQUESTITEM' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-send-o',                   # UI Style class
        },
        H_CANCELREQUESTITEM => {
            prev_actions => [ 'H_REQUESTITEM' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_REQUESTITEM',                   # ID of this status
            name           => 'Cancel Request Item',                   # UI name of this status
            ui_method_name => 'Cancel Request Item',                   # UI name of method leading
                                                           # to this status
            method         => 'cancelrequestitem',                    # method to this status
            next_actions   => [ 'KILL' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-trash',                   # UI Style class
        },
        H_DONE => {
            prev_actions => [ 'H_CANCELREQUESTITEM' ],                           # Actions containing buttons
                                                           # leading to this status
            id             => 'H_DONE',                   # ID of this status
            name           => 'Done',                   # UI name of this status
            ui_method_name => 'Done',                   # UI name of method leading
                                                           # to this status
            method         => '',                    # method to this status
            next_actions   => [], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-trash',                   # UI Style class
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
            name           => 'Request Item',                   # UI name of this status
            ui_method_name => 'Request Item',                   # UI name of method leading
                                                           # to this status
            method         => 'requestitem',                    # method to this status
            next_actions   => [ 'KILL' ], # buttons to add to all
                                                           # requests with this status
            ui_method_icon => 'fa-send-o',                   # UI Style class
        },
    };
}

=head3 requestitem

Send a RequestItem. This can be initiated in one of two ways:

1. We have received an ItemRequested and respond by sending RequestItem back. 
This will be done autmatically by the cronjob return_itemrequested.pl

2. TODO We have entered the necesarry data into a form and send the request with
the data we entered. NOT YET IMPLEMENTED.

=cut

sub requestitem {

    my ( $self, $params ) = @_;
    my $stage = $params->{other}->{stage};

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'requestitem',
        stage   => 'commit',
        next    => 'illview',
        # value   => $request_details,
    };

}

=head3 create # FIXME Rename to itemrequested (?)

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
    my $borrowernumber = $params->{other}->{borrowernumber}; # FIXME Check that we have a valid borrowernumber
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

=head3 cancelrequestitem

Send a CancelRequestItem to the library that we sent a RequestItem to, informing
them we are no longer interested in the requested item.

The home library sends this to the owner library.

=cut

sub cancelrequestitem {

    my ( $self, $params ) = @_;

warn "hitting cancelrequestitem";

    # Send a CancelRequestItem to the library we made the RequestItem to
    my $nncipp = Koha::Illbackends::NNCIPP::NNCIPP->new();
    my $req = $params->{request};
    my $patron = GetMember( borrowernumber => $req->borrowernumber );
    my $resp = $nncipp->SendCancelRequestItem({
        'remote_library'         => $req->illrequestattributes->find({ type => 'ordered_from_borrowernumber' })->value,
        'FromAgencyId'           => C4::Context->preference('ILLISIL'),
        'ToAgencyId'             => $req->illrequestattributes->find({ type => 'ordered_from' })->value,
        'UserIdentifierValue'    => $patron->{'cardnumber'},
        'RequestAgencyId'        => C4::Context->preference('ILLISIL'),
        'RequestIdentifierValue' => $req->illrequest_id,
        'ItemIdentifierType'     => $req->illrequestattributes->find({ type => 'ItemIdentifierType' })->value,
        'ItemIdentifierValue'    => $req->illrequestattributes->find({ type => 'ItemIdentifierValue' })->value,
        'RequestType'            => $req->illrequestattributes->find({ type => 'RequestType' })->value,
    });

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'cancelrequestitem',
        stage   => 'commit',
        next    => 'illview',
        # value   => $request_details,
    };

#    ### OLD ###

#    # Get data about the "other" library, from which we have requested the loan
#    my $request = $args->{'request'};
#    my $remote_library_id = $request->status->getProperty('ordered_from');
#    my $remote_library = GetMemberDetails( $remote_library_id );

#    # Get data about the person for whom the initial request was made
#    my $borrower_id = $request->status->getProperty('borrowernumber');
#    my $borrower    = GetMemberDetails( $borrower_id );

#    my ( $remote_id_agency, $remote_id_id ) = split /:/, $request->status->getProperty('remote_id');

#    # Set up the template for the message
#    my $tmplbase = 'ill/nncipp/CancelRequestItem.xml';
#    my $language = 'en'; # _get_template_language($query->cookie('KohaOpacLanguage'));
#    my $path     = C4::Context->config('intrahtdocs'). "/prog/". $language;
#    my $filename = "$path/modules/" . $tmplbase;
#    my $template = C4::Templates->new( 'intranet', $filename, $tmplbase );
#    $template->param(
#        'FromAgency'        => C4::Context->preference('ILLISIL'),
#        'ToAgency'          => $remote_library->{'cardnumber'},
#        'UserId'            => $borrower->{'cardnumber'},
#        'AgencyId'          => $remote_id_agency,
#        'RequestId'         => $remote_id_id,
#        'ItemIdentifier'    => $request->status->getProperty('remote_barcode'),
#        'RequestType'       => $request->status->getProperty('reqtype'),
#    );
#    my $msg = $template->output();

#    my $nncip_uri = GetBorrowerAttributeValue( $remote_library_id, 'nncip_uri' );
#    return _send_message( 'CancelRequestItem', $msg, $nncip_uri );

}

=head3 confirm

  my $response = $backend->confirm({
      request    => $requestdetails,
      other      => $other,
  });

Confirm the placement of the previously "selected" request (by using the
'create' method).

In this case we will generally use $request.
This will be supplied at all times through Illrequest.  $other may be supplied
using templates.

=cut

sub confirm {
    # -> confirm placement of the ILL order
    my ( $self, $params ) = @_;
    # Turn Illrequestattributes into a plain hashref
    my $value = {};
    my $attributes = $params->{request}->illrequestattributes;
    foreach my $attr (@{$attributes->as_list}) {
        $value->{$attr->type} = $attr->value;
    };
    # Submit request to backend...

    _ncip(
        ItemRequested => [
            InitiationHeader => [
                FromAgencyId => [
                    AgencyId => "FFL", #TODO
                ],
                ToAgencyId => [
                    AgencyId => "CPL", #TODO
                ],
            ],
            UserId => [
                UserIdentifierValue => 51, #TODO
            ],
            ItemId => [
                ItemIdentifierValue => 1, #TODO
            ],
            RequestType => "Loan",
            RequestScopeType => 0,
        ],
    );

    # ...parse response...
    $attributes->find_or_create({ type => "status", value => "On order" });
    my $request = $params->{request};
    $request->cost("30 GBP");
    $request->orderid($value->{id});
    $request->status("REQ");
    $request->accessurl("URL") if $value->{url};
    $request->store;
    $value->{status} = "On order";
    $value->{cost} = "30 GBP";
    # ...then return our result:
    return {
        error    => 0,
        status   => '',
        message  => '',
        method   => 'confirm',
        stage    => 'commit',
        next     => 'illview',
        value    => $value,
    };
}

=head3 renew

  my $response = $backend->renew({
      request    => $requestdetails,
      other      => $other,
  });

Attempt to renew a request that was supplied through backend and is currently
in use by us.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub renew {
    # -> request a currently borrowed ILL be renewed in the backend
    my ( $self, $params ) = @_;
    # Turn Illrequestattributes into a plain hashref
    my $value = {};
    my $attributes = $params->{request}->illrequestattributes;
    foreach my $attr (@{$attributes->as_list}) {
        $value->{$attr->type} = $attr->value;
    };
    # Submit request to backend, parse response...
    my ( $error, $status, $message ) = ( 0, '', '' );
    if ( !$value->{status} || $value->{status} eq 'On order' ) {
        $error = 1;
        $status = 'not_renewed';
        $message = 'Order not yet delivered.';
    } else {
        $value->{status} = "Renewed";
    }
    # ...then return our result:
    return {
        error   => $error,
        status  => $status,
        message => $message,
        method  => 'renew',
        stage   => 'commit',
        value   => $value,
        next    => 'illview',
    };
}

=head3 cancel

  my $response = $backend->cancel({
      request    => $requestdetails,
      other      => $other,
  });

We will attempt to cancel a request that was confirmed.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub cancel {
    # -> request an already 'confirm'ed ILL order be cancelled
    my ( $self, $params ) = @_;
    # Turn Illrequestattributes into a plain hashref
    my $value = {};
    my $attributes = $params->{request}->illrequestattributes;
    foreach my $attr (@{$attributes->as_list}) {
        $value->{$attr->type} = $attr->value;
    };
    # Submit request to backend, parse response...
    my ( $error, $status, $message ) = (0, '', '');
    if ( !$value->{status} ) {
        ( $error, $status, $message ) = (
            1, 'unknown_request', 'Cannot cancel an unknown request.'
        );
    } else {
        $attributes->find({ type => "status" })->value('Reverted')->store;
        $params->{request}->status("REQREV");
        $params->{request}->cost(undef);
        $params->{request}->orderid(undef);
        $params->{request}->store;
    }
    return {
        error   => $error,
        status  => $status,
        message => $message,
        method  => 'cancel',
        stage   => 'commit',
        value   => $value,
        next    => 'illview',
    };
}

=head3 status

  my $response = $backend->create({
      request    => $requestdetails,
      other      => $other,
  });

We will try to retrieve the status of a specific request.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub status {
    # -> request the current status of a confirmed ILL order
    my ( $self, $params ) = @_;
    my $value = {};
    my $stage = $params->{other}->{stage};
    my ( $error, $status, $message ) = (0, '', '');
    if ( !$stage || $stage eq 'init' ) {
        # Generate status result
        # Turn Illrequestattributes into a plain hashref
        my $attributes = $params->{request}->illrequestattributes;
        foreach my $attr (@{$attributes->as_list}) {
            $value->{$attr->type} = $attr->value;
        }
        ;
        # Submit request to backend, parse response...
        if ( !$value->{status} ) {
            ( $error, $status, $message ) = (
                1, 'unknown_request', 'Cannot query status of an unknown request.'
            );
        }
        return {
            error   => $error,
            status  => $status,
            message => $message,
            method  => 'status',
            stage   => 'status',
            value   => $value,
        };

    } elsif ( $stage eq 'status') {
        # No more to do for method.  Return to illlist.
        return {
            error   => $error,
            status  => $status,
            message => $message,
            method  => 'status',
            stage   => 'commit',
            next    => 'illlist',
            value   => {},
        };

    } else {
        # Invalid stage, return error.
        return {
            error   => 1,
            status  => 'unknown_stage',
            message => '',
            method  => 'create',
            stage   => $params->{stage},
            value   => {},
        };
    }
}

=head1 AUTHOR

Magnus Enger <magnus@libriotech.no>

Based on the "Dummy" backend by Alex Sassmannshausen <alex.sassmannshausen@ptfs-europe.com>

=cut

1;
