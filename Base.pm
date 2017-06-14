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

# deprecated, use NNCIPP.pm
sub _ncip {
    my ($self, @data) = @_;
    my $xml = _build_xml(@data);
    my $req = HTTP::Request->new(
        #POST => 'http://koha.ncip.bibkat.no/', # TODO the url should be set during ->create()
        POST => 'http://127.0.0.1:3000/', # TODO test
        [],
        $xml->toString(1),
    );
    my $res = $self->{ua}->request($req);
}

# deprecated, use XML.pm
# expect a tree of ARRAYs, returns a NCIP compliant xml object
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

# expect a string, parse it as xml and return a HoH (with arrays where needed)
sub _parse_xml {
    my ($s) = @_;
    my $doc = XML::LibXML->load_xml(string => $s);
    my $e = $doc->documentElement();

    my $parser; $parser = sub {
        my ($e) = @_;
        my $out = {};
        for my $node ($e->nonBlankChildNodes()) {
            my $name = $node->nodeName();
            if ($name eq '#text') {
                my $t = $node->textContent;
                $t =~ s{^\s+}{}; $t =~ s{\s+$}{};
                return $t;
            }
            $name =~ s{^\w+:}{} or next;
            my $child = $parser->($node);
            push @{ $out->{$name}//=[] }, $child;
        }

        # collapse single element lists (TODO, this might be not the best in some cases, but there is not much we can do)
        for (values %$out) {
            $_ = $_->[0] if scalar(@$_)<2;
        }
        return $out;
    };
    $parser->($e);
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
            OrderFrom => '-', # FIXME
        };
    }

    my %map = (
        # ID => 'id',
        Title => 'title',
        Author => 'author',
        # Status => 'status',
        OrderFrom => 'order_from',
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

#sub renew {
#    # -> request a currently borrowed ILL be renewed in the backend
#    my ( $self, $params ) = @_;
#    # Turn Illrequestattributes into a plain hashref
#    my $value = {};
#    my $attributes = $params->{request}->illrequestattributes;
#    foreach my $attr (@{$attributes->as_list}) {
#        $value->{$attr->type} = $attr->value;
#    };
#    # Submit request to backend, parse response...
#    my ( $error, $status, $message ) = ( 0, '', '' );
#    if ( !$value->{status} || $value->{status} eq 'On order' ) {
#        $error = 1;
#        $status = 'not_renewed';
#        $message = 'Order not yet delivered.';
#    } else {
#        $value->{status} = "Renewed";
#    }
#    # ...then return our result:
#    return {
#        error   => $error,
#        status  => $status,
#        message => $message,
#        method  => 'renew',
#        stage   => 'commit',
#        value   => $value,
#        next    => 'illview',
#    };
#}

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
