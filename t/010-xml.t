use strict;
use warnings;

use Test::More;
use Data::Dumper;

use lib '../../../';

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




# ItemRequested

my $item_requested = $x->ItemRequested(
    from_agency => 'NO-from',
    to_agency => 'NO-to',
    userid => 'user001',
    barcode => '1234567',
    request_type => 'Physical',
    bibliographic_description => {
        Author => 'U.N. Owen',
    },
);

isa_ok($item_requested, 'XML::LibXML::Document');

my $item_requested_txt = $item_requested->toString(1);
like($item_requested_txt, qr/U\.N\. Owen/, "Author is present in the XML as text");
is($item_requested->findvalue('//ns1:ItemIdentifierValue'), '1234567', 'barcode');

done_testing();
