use strict;
use warnings;

use Test::More;
use Data::Dumper;

use lib '../../../';

sub must_fail {
    my ($code, $label, $re) = @_;
    if (eval { $code->(); 1; }) {
        fail $label;
    } else {
        my $err = $@; chomp($err);
        if ($re) {
            $err =~ m{$re} or fail "$label: error doesn't match /$re/: $err";
        }
        pass "$label: $err";
    }
}

require_ok("Koha::Illbackends::NNCIPP::XML");

my $x = Koha::Illbackends::NNCIPP::XML->new();
isa_ok($x, "Koha::Illbackends::NNCIPP::XML");

my $parsed = $x->parse(<<'EOD');
<ns1:NCIPMessage xmlns:ns1="http://www.niso.org/2008/ncip" ns1:version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">
  <ns1:ItemRequested>
    <ns1:InitiationHeader>
      <ns1:FromAgencyId>
        <ns1:AgencyId>NO-from</ns1:AgencyId>
      </ns1:FromAgencyId>
      <ns1:ToAgencyId>
        <ns1:AgencyId>NO-to</ns1:AgencyId>
      </ns1:ToAgencyId>
    </ns1:InitiationHeader>
  </ns1:ItemRequested>
</ns1:NCIPMessage>
EOD

is($parsed->findvalue('//ns1:FromAgencyId//*'), 'NO-from', 'from agency');
is($parsed->findvalue('//ns1:ToAgencyId//*'), 'NO-to', 'to agency');

# TODO test for an error


subtest ItemRequested => sub {
    my %args = (
        from_agency => 'NO-from',
        to_agency => 'NO-to',
        userid => 'user001',
        barcode => '1234567',
        request_type => 'Physical',
        bibliographic_description => {
            Author => 'U.N. Owen',
        },
    );
    my $xml = $x->ItemRequested(%args);
    isa_ok($xml, 'XML::LibXML::Document');

    my $txt = $xml->toString(1);
    like($txt, qr/U\.N\. Owen/, "Author is present in the XML as text");
    is($xml->findvalue('//ns1:ItemIdentifierValue'), '1234567', 'barcode');

    for my $k (keys %args) {
        my %missing = %args;
        delete $missing{$k};
        must_fail(sub {
            $x->ItemRequested(%missing);
        }, "missing arguments: '$k'", $k);
    }
};

subtest RequestItem => sub {
    my %args = (
        from_agency => 'NO-from',
        to_agency => 'NO-to',
        userid => 'user001',
        barcode => '1234567',
        request_type => 'Physical',
    );
    my $xml = $x->RequestItem(%args);
    isa_ok($xml, 'XML::LibXML::Document');
    is($xml->findvalue('//ns1:ItemIdentifierValue'), '1234567', 'barcode');

    for my $k (keys %args) {
        my %missing = %args;
        delete $missing{$k};
        must_fail(sub {
            $x->RequestItem(%missing);
        }, "missing arguments: '$k'", $k);
    }
};

subtest CancelRequestItem => sub {
    my %args = (
        request_id => 'R#123',
        from_agency => 'NO-from',
        to_agency => 'NO-to',
        userid => 'user001',
        barcode => '1234567',
        cardnumber => 'NL-12345',
        date_shipped => "2015-11-22",
        request_type => 'Physical',
        address => {
            street => 'Narrowgata',
            city => 'Townia',
            country => 'Norway',
            zipcode => '0123',
        },
        cancelled_by => 'Me',
    );
    my $xml = $x->CancelRequestItem(%args);
    isa_ok($xml, 'XML::LibXML::Document');
    is($xml->findvalue('//ns1:ItemIdentifierValue'), '1234567', 'barcode');

    for my $k (keys %args) {
        my %missing = %args;
        delete $missing{$k};
        must_fail(sub {
            $x->ItemShipped(%missing);
        }, "missing arguments: '$k'", $k);
    }
};


subtest ItemShipped => sub {
    my %args = (
        request_id => 'R#123',
        from_agency => 'NO-from',
        to_agency => 'NO-to',
        userid => 'user001',
        barcode => '1234567',
        cardnumber => 'NL-12345',
        date_shipped => "2015-11-22",
        bibliographic_description => {
            Author => 'U.N. Owen',
        },
        address => {
            street => 'Narrowgata',
            city => 'Townia',
            country => 'Norway',
            zipcode => '0123',
        },
        shipped_by => 'Posten',
    );
    my $xml = $x->ItemShipped(%args);
    isa_ok($xml, 'XML::LibXML::Document');

    my $txt = $xml->toString(1);
    like($txt, qr/U\.N\. Owen/, "author is present in the xml as text");
    is($xml->findvalue('//ns1:ItemIdentifierValue'), '1234567', 'barcode');

    for my $k (keys %args) {
        my %missing = %args;
        delete $missing{$k};
        must_fail(sub {
            $x->ItemShipped(%missing);
        }, "missing arguments: '$k'", $k);
    }

    must_fail(sub {
        local $args{date_shipped} = 'Jun 3rd, 2003';
        $x->ItemShipped(%args);
    }, "not iso date");
};

done_testing();
