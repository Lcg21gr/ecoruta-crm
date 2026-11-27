package EcoRuta::Gmail;
use strict;
use warnings;
use utf8;
use HTTP::Tiny;
use JSON::PP;
use MIME::Base64 qw(encode_base64url);

my $OAUTH_URL = 'https://oauth2.googleapis.com/token';
my $SEND_URL = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send';
my $JSON = JSON::PP->new->utf8;

sub new {
  my ($class, %args) = @_;
  $args{http} //= HTTP::Tiny->new(
    verify_SSL => 1, timeout => 12, max_redirect => 0, max_size => 128 * 1024,
  );
  return bless \%args, $class;
}

sub _access_token {
  my ($self) = @_;
  return ($self->{access_token}, undef) if ($self->{expires_at} // 0) > time;
  my $res = $self->{http}->post_form($OAUTH_URL, {
    grant_type => 'refresh_token',
    client_id => $self->{client_id},
    client_secret => $self->{client_secret},
    refresh_token => $self->{refresh_token},
  }, { headers => { Accept => 'application/json' } });
  my $data = _json($res);
  unless ($res->{success}) {
    return (undef, 'Google rechazó la autorización de Gmail. Reautoriza la cuenta y revisa los secretos OAuth.')
      if ($data->{error} // '') =~ /\A(?:invalid_grant|invalid_client|unauthorized_client)\z/;
    return (undef, 'No se pudo renovar el acceso a Gmail por HTTPS.');
  }
  my ($token, $ttl) = @$data{qw(access_token expires_in)};
  return (undef, 'Google devolvió una autorización OAuth no válida.')
    unless defined($token) && !ref($token) && $token =~ /\A[a-zA-Z0-9._~+\/=-]+\z/
      && defined($ttl) && !ref($ttl) && $ttl =~ /\A[0-9]+\z/ && $ttl > 0
      && lc($data->{token_type} // '') eq 'bearer';
  $self->{access_token} = $token;
  $self->{expires_at} = time + $ttl - 60;
  return ($token, undef);
}

sub _json {
  my ($res) = @_;
  my $value = eval { $JSON->decode($res->{content} // '') };
  return ref($value) eq 'HASH' ? $value : {};
}

sub send_mime {
  my ($self, $mime) = @_;
  $mime =~ s/(?<!\r)\n/\r\n/g;
  my $payload = $JSON->encode({ raw => encode_base64url($mime) });
  for my $attempt (0, 1) {
    my ($token, $error) = $self->_access_token;
    return (0, $error) unless defined $token;
    my $res = $self->{http}->post($SEND_URL, {
      headers => {
        Authorization => "Bearer $token",
        'Content-Type' => 'application/json',
        Accept => 'application/json',
      },
      content => $payload,
    });
    my $status = $res->{status} // 0;
    if ($res->{success}) {
      my $id = _json($res)->{id};
      return (1, 'Enviado por Gmail API') if defined($id) && !ref($id) && length $id;
      return (0, 'Gmail no confirmó el identificador del envío. Comprueba la carpeta Enviados antes de repetir.', 1);
    }
    if ($status == 401 && !$attempt) {
      delete @$self{qw(access_token expires_at)};
      next;
    }
    return (0, 'Gmail no autorizó el envío. Revisa que la API esté habilitada y el permiso gmail.send esté concedido.')
      if $status == 401 || $status == 403;
    return (0, 'Gmail alcanzó un límite temporal de envío. Intenta más tarde.') if $status == 429;
    return (0, 'Gmail no confirmó el envío. Comprueba la carpeta Enviados antes de repetir.', 1)
      if $status >= 500 || !$status;
    return (0, 'Gmail rechazó el mensaje.');
  }
}

1;
