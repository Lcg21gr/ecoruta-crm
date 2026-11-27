package EcoRuta::TestGmailHTTP;
use strict;
use warnings;
use EcoRuta::Gmail;
use HTTP::Tiny;

my $mock = $ENV{GMAIL_TEST_SIM_URL} // '';
die "Usa una simulación Gmail en loopback\n" unless $mock =~ m{\Ahttp://127\.0\.0\.1:[0-9]+/gmail\z};
my $original = \&EcoRuta::Gmail::new;
{
  no warnings 'redefine';
  *EcoRuta::Gmail::new = sub {
    my ($class, %args) = @_;
    $original->($class, %args, http => EcoRuta::TestGmailHTTP::Client->new(
      http_proxy => undef, https_proxy => undef, proxy => undef, timeout => 4,
    ));
  };
}

package EcoRuta::TestGmailHTTP::Client;
our $VERSION = '0.1';
our @ISA = ('HTTP::Tiny');
sub request {
  my ($self, $method, $url, @opts) = @_;
  my %paths = (
    'https://oauth2.googleapis.com/token' => '/token',
    'https://gmail.googleapis.com/gmail/v1/users/me/messages/send' => '/gmail/v1/users/me/messages/send',
  );
  die "Ruta Gmail fuera de la simulación\n" unless exists $paths{$url};
  return $self->SUPER::request($method, $mock . $paths{$url}, @opts);
}
1;
