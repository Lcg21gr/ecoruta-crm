#!/usr/bin/perl
# =========================================================
#  EcoRuta CRM · servidor HTTP
#  - Login con usuario y contraseña (PBKDF2-SHA256)
#  - PostgreSQL en Docker, SQLite para el arranque local
#  - Recomendación de vehículo según catálogo, tecnología y presupuesto
#  - Envío de invitaciones por Gmail (SMTP + contraseña de aplicación)
# =========================================================
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";
use EcoRuta::DB qw(connect_db is_pg transaction write_lock ensure_schema init_counters next_id import_sqlite);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use HTTP::Daemon;
use HTTP::Request;
use HTTP::Response;
use JSON::PP;
use Digest::SHA qw(hmac_sha256);
use MIME::Base64 qw(encode_base64);
use Net::SMTP;
use Encode qw(encode decode);
use URI;
use POSIX qw(strftime setlocale LC_TIME tzset);
use Time::Local qw(timegm_posix);

# macOS cierra los procesos hijos (fork) que abren conexiones SSL/DNS por la protección
# "fork safety" de Objective-C, y el navegador recibe "Failed to fetch". El servidor es de
# un solo hilo, así que es seguro desactivarla: se relanza con la variable activa desde el inicio.
if ($^O eq 'darwin' && !@ARGV && ($ENV{OBJC_DISABLE_INITIALIZE_FORK_SAFETY} // '') ne 'YES') {
  $ENV{OBJC_DISABLE_INITIALIZE_FORK_SAFETY} = 'YES';
  exec($^X, $0, @ARGV) or die "No se pudo relanzar el servidor: $!\n";
}

setlocale(LC_TIME, 'C');
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
$| = 1;

# Estructura: crm-ecoruta/{.env, backend/server.pl, backend/data/, frontend/index.html, frontend/img/}
my $ROOT  = dirname($Bin);
my $FRONT = "$ROOT/frontend";
my %ENVFILE = load_env("$ROOT/.env");
sub cfg { my ($k, $def) = @_; return $ENV{$k} // $ENVFILE{$k} // $def }
sub flag { cfg($_[0], $_[1]) =~ /\A(?:1|true|yes)\z/i }

my $PORT   = cfg('PORT', 8080);
my $BIND = cfg('BIND_HOST', '127.0.0.1');
my $DBFILE = cfg('DB_PATH', "$Bin/data/ecoruta.db");
my $SCHEMA = "$Bin/schema.sql";
my $PRODUCTION = cfg('APP_ENV', 'local') eq 'production';
my $HAS_POSTGRES = cfg('DATABASE_URL', '') || cfg('DB_HOST', '');
my $SETUP_TOKEN = cfg('CRM_SETUP_TOKEN', '');
$ENV{TZ} = cfg('TZ', 'Europe/Madrid');
tzset();
my $CONCESIONARIO = 'EcoRuta Madrid';
my $PLAZO_CORTO = 30;
my $J = JSON::PP->new->utf8->canonical;
# Dirección con la que el cliente abre el botón del correo. En local: http://localhost:8080.
# Para clientes reales debe ser una dirección pública (dominio o túnel) que apunte a este servidor.
(my $PUBLIC_URL = cfg('PUBLIC_URL', cfg('RENDER_EXTERNAL_URL', '') || "http://localhost:$PORT")) =~ s{/+$}{};
my $public = URI->new($PUBLIC_URL);
die "PUBLIC_URL debe ser una URL HTTP(S) sin ruta, usuario, consulta ni fragmentos.\n"
  unless $PUBLIC_URL =~ m{\Ahttps?://(?:[a-zA-Z0-9.-]+|\[[0-9a-fA-F:]+\])(?::[0-9]+)?\z} && $public->host;
die "En producción PUBLIC_URL debe usar HTTPS.\n" if $PRODUCTION && $public->scheme ne 'https';
die "En producción configura PostgreSQL para no perder datos al recrear el contenedor.\n" if $PRODUCTION && !$HAS_POSTGRES;
die "CRM_SETUP_TOKEN debe tener al menos 32 caracteres.\n" if length($SETUP_TOKEN) && length($SETUP_TOKEN) < 32;
my $COOKIE_FLAGS = 'Path=/; HttpOnly; SameSite=Strict' . ($public->scheme eq 'https' ? '; Secure' : '');
my $MAX_BODY = 128 * 1024;
our @AFTER;   # tareas que se ejecutan después de responder al navegador (p. ej. avisos por correo)
my $CLI_COLS = 'id,nombre,apellido,telefono,email,origen,permiso,canal,tecnologia,presupuesto,compra_dias AS "compraDias",carga,asesor,vehiculo,creado';

if (@ARGV && $ARGV[0] eq '--migrar-sqlite') {
  die "Uso: perl backend/server.pl --migrar-sqlite /ruta/al/archivo.db\n" unless @ARGV == 2;
  die "Configura un destino PostgreSQL antes de importar.\n" unless $HAS_POSTGRES;
  my $dbh = db();
  my $counts = import_sqlite(\&cfg, $dbh, $ARGV[1], $SCHEMA);
  print "$_: $counts->{$_}\n" for sort keys %$counts;
  print "Migración completada. Las sesiones anteriores no se copiaron.\n";
  $dbh->disconnect;
  exit 0;
}
my $mode = shift(@ARGV) // '';
die "Opción desconocida: $mode\n" if $mode ne '' && $mode ne '--init-db' && $mode ne '--prueba-correo';
make_path(dirname($DBFILE), { mode => 0700 }) unless $HAS_POSTGRES;
{
  my $dbh = db();
  if (flag('CRM_MANAGE_SCHEMA', 1)) {
    $dbh->do('PRAGMA journal_mode = WAL') unless is_pg($dbh);
    transaction($dbh, sub {
      write_lock($dbh);
      ensure_schema($dbh, $SCHEMA);
      init_db($dbh);
      init_counters($dbh);
    });
  } else {
    $dbh->selectrow_array('SELECT ultimo FROM contadores LIMIT 1');
  }
  die "Configura CRM_SETUP_TOKEN para crear de forma segura el primer administrador.\n"
    if $PRODUCTION && !length($SETUP_TOKEN) && needs_setup($dbh);
  $dbh->disconnect;
}
exit 0 if $mode eq '--init-db';

# Modo prueba de correo:  perl backend/server.pl --prueba-correo [destino]
# (sin destino, se envía a la propia cuenta GMAIL_USER)
if ($mode eq '--prueba-correo') {
  my $to = $ARGV[0] // cfg('GMAIL_USER', '');
  print "Enviando correo de prueba a $to ...\n";
  my ($ok, $det) = send_mail(to => $to, subject => "Prueba de correo · $CONCESIONARIO CRM",
    text => "Este es un correo de prueba enviado desde el backend del CRM de $CONCESIONARIO. Si lo recibes, el envío por Gmail funciona.",
    html => "<p>Este es un correo de prueba enviado desde el backend del CRM de <b>$CONCESIONARIO</b>.</p><p>Si lo recibes, el envío por Gmail funciona.</p>");
  my $dbh = db(); log_envio($dbh, undef, 'prueba', $to, 'Prueba de correo (terminal)', $ok ? 'enviado' : 'error', $det, 'terminal'); $dbh->disconnect;
  print $ok ? "OK: correo enviado a $to\n" : "ERROR: $det\n";
  exit($ok ? 0 : 1);
}

if (cfg('HTTP_ENGINE', 'local') eq 'starman') {
  require Plack::Handler::Starman;
  print "EcoRuta CRM · HTTP en $BIND:$PORT · URL pública $PUBLIC_URL\n";
  Plack::Handler::Starman->new(
    host => $BIND, port => $PORT, workers => cfg('WEB_WORKERS', 3),
    max_requests => 500, keepalive_timeout => 2, read_timeout => 15,
  )->run(\&psgi_app);
  exit 0;
}

my $d = HTTP::Daemon->new(LocalAddr => $BIND, LocalPort => $PORT, ReuseAddr => 1)
  or die "No se pudo abrir el puerto $PORT ($!). ¿Ya hay otro servidor del CRM abierto?\n";
$SIG{CHLD} = 'IGNORE';
print "\n  EcoRuta CRM funcionando en  http://localhost:$PORT\n";
print "  Correo Gmail: ", (mail_configured() ? "configurado" : "NO configurado"), "\n";
print "  Para detenerlo pulsa Ctrl+C\n\n";

while (my $c = $d->accept) {
  my $pid = fork();
  if (!defined $pid) { $c->close; next }
  if ($pid) { $c->close; next }        # padre: sigue aceptando
  # hijo: atiende una petición y termina
  $c->timeout(20);
  my $r = $c->get_request;
  if ($r) {
    my $res = dispatch($r);
    $res->header('Connection' => 'close');
    $c->send_response($res);
  }
  $c->close;
  run_after(splice @AFTER);
  exit 0;
}

# =========================================================
#  Utilidades
# =========================================================
sub load_env {
  my $f = shift; my %h;
  open(my $fh, '<:encoding(UTF-8)', $f) or return %h;
  while (my $l = <$fh>) {
    next if $l =~ /^\s*(#|$)/;
    if ($l =~ /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/) { my ($k, $v) = ($1, $2); $v =~ s/^(['"])(.*)\1$/$2/; $h{$k} = $v }
  }
  return %h;
}
sub db { connect_db(sub { $_[0] eq 'DB_PATH' ? $DBFILE : cfg(@_) }) }
sub now_iso { strftime('%Y-%m-%dT%H:%M:%S.000Z', gmtime) }
sub excel_iso { my $v = shift; strftime('%Y-%m-%dT%H:%M:%S.000Z', gmtime(($v - 25569) * 86400)) }
sub rand_hex { my $n = shift; open(my $fh, '<:raw', '/dev/urandom') or die; read($fh, my $b, $n) == $n or die; close $fh; unpack('H*', $b) }
sub trim { my $s = shift // ''; $s =~ s/^\s+|\s+$//g; $s }
sub esc_html { my $s = shift // ''; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; $s }
sub eur { my $n = int(shift // 0); my $neg = $n < 0; $n = abs $n; 1 while $n =~ s/^(\d+)(\d{3})/$1.$2/; ($neg ? '-' : '') . "$n €" }
sub valid_email {
  my $e = shift // '';
  return !ref($e) && length($e) <= 254 && $e =~ /\A[A-Z0-9.!#\x24%&'*+\/=?^_\x60{|}~-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z0-9-]{2,}\z/i;
}

# ---------- Contraseñas: PBKDF2-HMAC-SHA256 ----------
sub pbkdf2 {
  my ($pass, $salt, $iter) = @_;
  $pass = encode('UTF-8', $pass);
  my $u = hmac_sha256($salt . pack('N', 1), $pass); my $t = $u;
  for (2 .. $iter) { $u = hmac_sha256($u, $pass); $t ^= $u }
  return unpack('H*', $t);
}
sub hash_password { my $p = shift; my $salt = rand_hex(16); my $it = 60000; "pbkdf2\$$it\$$salt\$" . pbkdf2($p, pack('H*', $salt), $it) }
sub check_password {
  my ($p, $stored) = @_;
  return 0 unless $stored && $stored =~ /^pbkdf2\$(\d+)\$([0-9a-f]+)\$([0-9a-f]+)$/;
  my $calc = pbkdf2($p, pack('H*', $2), $1); my $exp = $3;
  return same_secret($calc, $exp);
}
sub same_secret {
  my ($left, $right) = @_;
  return 0 unless defined $left && !ref($left) && length($left) == length($right);
  my $diff = 0;
  $diff |= ord(substr($left, $_, 1)) ^ ord(substr($right, $_, 1)) for 0 .. length($right) - 1;
  return $diff == 0;
}

# =========================================================
#  Esquema y datos iniciales (del Excel CRM_EcoRuta_Madrid)
# =========================================================
sub init_db {
  my $dbh = shift;
  # Si la plantilla de invitación sigue siendo la original, se cambia por la nueva (sin "responde a este correo")
  my ($tpl) = $dbh->selectrow_array(q{SELECT valor FROM config WHERE clave = 'plantillaInvitacion'});
  set_config($dbh, 'plantillaInvitacion', plantilla_v2()) if !defined($tpl) || $tpl eq plantilla_v1();
  my ($n) = $dbh->selectrow_array('SELECT COUNT(*) FROM catalogo');
  return if $n;

  my @cat = (
    ['V01','MG3 Hybrid+','Hybrid+ Comfort MY26','HEV',21215,'No','Ciudad y uso diario','Contado publicado por Blendio'],
    ['V02','Toyota Yaris','MY26 Active Hybrid 120','HEV',21500,'No','Ciudad y uso diario','PVP al contado publicado'],
    ['V03','MG ZS Hybrid+','Hybrid+ Comfort','HEV',24700,'No','Uso familiar sin recarga','Contado publicado por Blendio'],
    ['V04','MG4 Urban','54kWh Comfort','BEV',24215,'Sí','Ciudad con recarga habitual','Contado publicado por Blendio'],
    ['V05','MG4','64kWh Premium','BEV',30815,'Sí','Uso mixto con recarga','Contado publicado por Blendio'],
    ['V06','MGS5 EV','64kWh Luxury','BEV',31490,'Sí','Familia y recarga habitual','Contado publicado por Blendio'],
    ['V07','MG HS','1.5T PLUG IN HYBRID COMFORT','PHEV',28932,'Sí','Uso mixto con recarga diaria','Contado publicado por Blendio'],
    ['V08','MGS9','1.5T PHEV Premium AUTO','PHEV',38990,'Sí','Familia y viajes con recarga','Contado publicado por Blendio'],
    ['V09','BYD SEAL U DM-i','Boost MY2027','PHEV',39300,'Sí','Familia y viajes con recarga','PVPR sin ayudas ni financiación'],
  );
  my $sc = $dbh->prepare('INSERT INTO catalogo (id,modelo,version,tec,precio,recarga,uso,base,disponible) VALUES (?,?,?,?,?,?,?,?,1)');
  $sc->execute(@$_) for @cat;

  return unless flag('SEED_DEMO', $PRODUCTION ? 0 : 1);
  my $su = $dbh->prepare('INSERT INTO usuarios (nombre,email,rol,pass_hash,creado) VALUES (?,?,?,NULL,?)');
  $su->execute('Ana Demo', undef, 'estandar', now_iso());
  $su->execute('Luis Demo', undef, 'estandar', now_iso());

  my @cli = (
    ['C001','Alba','Web','Si','Email','BEV',36000,20,'Si','Ana Demo','V05'],
    ['C002','Bruno','Visita','Si','Telefono','PHEV',40000,60,'No','Luis Demo','V07'],
    ['C003','Carla','Evento','No','Email','BEV',42000,15,'Si','Ana Demo','V06'],
    ['C004','Diego','Web','Si','Telefono','HEV',30000,25,'No','Luis Demo','V02'],
    ['C005','Elena','Referido','Si','Email','BEV',26000,20,'Si','Ana Demo','V04'],
    ['C006','Fabio','Web','Si','Email','BEV',35000,90,'Si','Luis Demo','V05'],
    ['C007','Gala','Visita','Si','Telefono','PHEV',45000,30,'Si','Ana Demo','V09'],
    ['C008','Hugo','Evento','Si','Email','BEV',34000,30,'Por confirmar','Luis Demo','V04'],
    ['C009','Ines','Web','Si','Telefono','HEV',29000,10,'No','Ana Demo','V03'],
    ['C010','Jaime','Referido','Si','Email','PHEV',41000,120,'Si','Luis Demo','V08'],
  );
  my $sl = $dbh->prepare('INSERT INTO clientes (id,nombre,apellido,telefono,email,origen,permiso,canal,tecnologia,presupuesto,compra_dias,carga,asesor,vehiculo,creado) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)');
  my $i = 0;
  for my $r (@cli) {
    $i++;
    $sl->execute($r->[0], $r->[1], 'Demo', sprintf('+34 600 000 0%02d', $i), lc($r->[1]) . '.demo@example.com', @$r[2..10], excel_iso(46327));
  }
  my @ints = (
    ['C001',46327.5,'Web','Consulta','Pregunta por un electrico urbano','Ana Demo',''],
    ['C002',46327.5,'Visita','Consulta','Interes en hibrido enchufable','Luis Demo',''],
    ['C003',46328.5,'Evento','Consulta','No autoriza seguimiento comercial','Ana Demo',''],
    ['C004',46328.5,'Web','Consulta','Busca hibrido no enchufable','Luis Demo',''],
    ['C005',46329.5,'Email','Consulta','Presupuesto maximo 26000 EUR','Ana Demo',''],
    ['C006',46329.5,'Web','Consulta','Compra prevista en 90 dias','Luis Demo',''],
    ['C007',46330.5,'Visita','Consulta','Dispone de carga en el trabajo','Ana Demo',''],
    ['C008',46330.5,'Evento','Consulta','Debe confirmar acceso a carga','Luis Demo',''],
    ['C009',46331.5,'Web','Consulta','Interes en HEV','Ana Demo',''],
    ['C010',46331.5,'Email','Consulta','Compra prevista en 120 dias','Luis Demo',''],
    ['C002',46332.5,'Telefono','Solicitud prueba','Quiere probar PHEV; no tiene carga habitual','Luis Demo',''],
    ['C004',46332.5,'Telefono','Solicitud prueba','Solicita prueba del HEV','Luis Demo',''],
    ['C007',46333.5,'Telefono','Solicitud prueba','Solicita prueba del PHEV','Ana Demo',''],
    ['C009',46333.5,'Telefono','Solicitud prueba','Solicita prueba del HEV','Ana Demo',''],
    ['C009',46334.5,'Telefono','Cita confirmada','Acepta cita para HEV el 15/11 a las 10:00','Ana Demo','Invitar a prueba HEV'],
    ['C005',46334.5,'Email','Solicitud prueba','Solicita prueba; presupuesto sigue en 26000','Ana Demo',''],
  );
  my $si = $dbh->prepare('INSERT INTO interacciones (cliente_id,fecha,canal,evento,resultado,responsable,accion) VALUES (?,?,?,?,?,?,?)');
  $si->execute($_->[0], excel_iso($_->[1]), @$_[2..6]) for @ints;

}

sub plantilla_v1 {
"Hola {nombre},

Gracias por confiar en $CONCESIONARIO. Según tus preferencias, te recomendamos el {vehiculo} ({tecnologia}) y nos encantaría invitarte a una prueba de conducción, sin compromiso.

Fecha propuesta: {fecha}
Tu asesor/a: {asesor}

Responde a este correo para confirmar o proponer otro horario.

Un saludo,
Equipo $CONCESIONARIO"
}
sub plantilla_v2 {
"Hola {nombre},

Gracias por confiar en $CONCESIONARIO. Hemos revisado lo que buscas y creemos que el {vehiculo} encaja contigo: {tecnologia}, cómodo y pensado para tu día a día.

Nos encantaría que lo conduzcas tú mismo/a, sin compromiso y con todo el tiempo que necesites. {asesor} te acompañará durante la prueba y resolverá todas tus dudas.

Pulsa el botón para confirmar la fecha o proponer la que mejor te venga. ¡Te esperamos!"
}

# =========================================================
#  HTTP
# =========================================================
sub run_after {
  for my $task (@_) {
    eval { $task->() };
    warn "No se pudo completar un aviso posterior a la respuesta.\n" if $@;
  }
}
sub dispatch {
  my ($r) = @_;
  my $res = eval { handle($r) };
  unless ($res) {
    # No registrar tokens, datos personales ni detalles de credenciales de errores de BD.
    warn "Error interno atendiendo una petición CRM.\n";
    $res = err(500, 'Error interno del servidor');
  }
  $res->header(
    'X-Content-Type-Options' => 'nosniff',
    'Referrer-Policy' => 'no-referrer',
    'X-Frame-Options' => ($r->uri->path eq '/api/correo/vista-previa' ? 'SAMEORIGIN' : 'DENY'),
  );
  return $res;
}
sub psgi_app {
  my ($env) = @_;
  local @AFTER;
  my $r = HTTP::Request->new($env->{REQUEST_METHOD}, $env->{REQUEST_URI});
  for my $key (grep /^HTTP_/, keys %$env) {
    (my $name = substr($key, 5)) =~ tr/_/-/;
    $r->header($name => $env->{$key});
  }
  $r->header('Content-Type' => $env->{CONTENT_TYPE}) if defined $env->{CONTENT_TYPE};
  my $len = $env->{CONTENT_LENGTH} // 0;
  my $res;
  if ($len !~ /\A[0-9]+\z/ || $len > $MAX_BODY) {
    $res = err(413, 'Solicitud demasiado grande');
  } else {
    my $body = '';
    while (length($body) < $len) {
      my $read = $env->{'psgi.input'}->read(my $chunk, $len - length($body));
      last unless $read;
      $body .= $chunk;
    }
    $r->content($body);
    $res = length($body) == $len ? dispatch($r) : err(400, 'Solicitud incompleta');
  }
  my $content = $res->content;
  $res->header('Content-Length' => length($content));
  my @headers;
  $res->headers->scan(sub { push @headers, @_ });
  return [$res->code, \@headers, [$content]] unless @AFTER;
  my @tasks = @AFTER;
  return sub {
    my $writer = $_[0]->([$res->code, \@headers]);
    $writer->write($content);
    $writer->close;
    run_after(@tasks);
  };
}
sub json_res {
  my ($code, $data, @hdr) = @_;
  my $res = HTTP::Response->new($code);
  $res->header('Content-Type' => 'application/json; charset=utf-8', 'Cache-Control' => 'no-store', @hdr);
  $res->content($J->encode($data));
  return $res;
}
sub err { json_res($_[0], { error => $_[1] }) }
sub file_res {
  my ($path, $type) = @_;
  open(my $fh, '<:raw', $path) or return err(404, 'No encontrado');
  local $/; my $b = <$fh>; close $fh;
  my $res = HTTP::Response->new(200);
  $res->header('Content-Type' => $type, 'Cache-Control' => ($type =~ /html/ ? 'no-store' : 'max-age=3600'),
               'X-Content-Type-Options' => 'nosniff');
  $res->content($b);
  return $res;
}

sub handle {
  my $r = shift;
  my $m = $r->method;
  my $p = $r->uri->path;
  return err(413, 'Solicitud demasiado grande') if length($r->content) > $MAX_BODY;
  return json_res(200, { ok => 1 }) if $p eq '/livez' && ($m eq 'GET' || $m eq 'HEAD');
  if ($p eq '/healthz' && ($m eq 'GET' || $m eq 'HEAD')) {
    my $ok = eval { my $dbh = db(); $dbh->selectrow_array('SELECT 1'); $dbh->disconnect; 1 };
    return $ok ? json_res(200, { ok => 1 }) : err(503, 'Base de datos no disponible');
  }

  # Archivos estáticos (lista blanca: nunca se sirve .env ni la base de datos)
  return file_res("$FRONT/index.html", 'text/html; charset=utf-8') if $m eq 'GET' && ($p eq '/' || $p eq '/index.html');
  return file_res("$FRONT/img/$1.jpg", 'image/jpeg') if $m eq 'GET' && $p =~ m{^/img/(V\d\d)\.jpg$};
  # Página pública donde el cliente responde (el token del correo es su única "llave")
  return respuesta_page($1, $r) if $p =~ m{^/r/([0-9a-f]{32})$} && ($m eq 'GET' || $m eq 'POST');
  return err(404, 'No encontrado') unless $p =~ m{^/api/};
  if ($m =~ /\A(?:POST|PUT|DELETE)\z/) {
    my $origin = $r->header('Origin');
    return err(403, 'Origen de la solicitud no permitido')
      if ($r->header('Sec-Fetch-Site') // '') eq 'cross-site'
        || ($PRODUCTION && defined($origin) && $origin ne $PUBLIC_URL);
  }

  my $body = {};
  if ($m eq 'POST' || $m eq 'PUT') {
    return err(415, 'Se esperaba JSON') unless ($r->header('Content-Type') // '') =~ m{\Aapplication/json(?:\s*;|\z)}i;
    $body = eval { $J->decode($r->content || '{}') } // return err(400, 'JSON no válido');
    return err(400, 'JSON no válido') unless ref $body eq 'HASH';
  }
  my $dbh = db();
  my $me = current_user($dbh, $r);

  # ---------- Públicas ----------
  if ($p eq '/api/estado' && $m eq 'GET') {
    return json_res(200, {
      necesitaConfiguracion => needs_setup($dbh) ? JSON::PP::true : JSON::PP::false,
      requiereTokenConfiguracion => length($SETUP_TOKEN) ? JSON::PP::true : JSON::PP::false,
    });
  }
  if ($p eq '/api/setup' && $m eq 'POST') {
    return err(403, 'Token de configuración incorrecto') if length($SETUP_TOKEN) && !same_secret($body->{token}, $SETUP_TOKEN);
    my ($nombre, $email, $pass) = (trim($body->{nombre}), lc trim($body->{email}), $body->{password} // '');
    return err(400, 'Indica nombre, correo y una contraseña de al menos 8 caracteres') unless $nombre && valid_email($email) && !ref($pass) && length($pass) >= 8;
    return transaction($dbh, sub {
      write_lock($dbh);
      return err(403, 'El administrador ya está creado') unless needs_setup($dbh);
      my ($dup) = $dbh->selectrow_array('SELECT 1 FROM usuarios WHERE lower(nombre) = lower(?) OR lower(email) = ?', undef, $nombre, $email);
      return err(400, 'Ya existe un usuario con ese nombre o correo') if $dup;
      $dbh->do('INSERT INTO usuarios (nombre,email,rol,pass_hash,creado) VALUES (?,?,?,?,?)', undef,
        $nombre, $email, 'admin', hash_password($pass), now_iso());
      my ($uid) = $dbh->selectrow_array('SELECT id FROM usuarios WHERE email = ?', undef, $email);
      return login_ok($dbh, $uid);
    });
  }
  if ($p eq '/api/login' && $m eq 'POST') {
    my $email = lc trim($body->{email});
    my $u = $dbh->selectrow_hashref('SELECT * FROM usuarios WHERE lower(email) = ?', undef, $email);
    if (!$u || !check_password($body->{password} // '', $u->{pass_hash})) { sleep 1; return err(401, 'Correo o contraseña incorrectos') }
    return login_ok($dbh, $u->{id});
  }
  if ($p eq '/api/logout' && $m eq 'POST') {
    my $tok = cookie_token($r);
    $dbh->do('DELETE FROM sesiones WHERE token = ?', undef, $tok) if $tok;
    return json_res(200, { ok => 1 }, 'Set-Cookie' => "sid=; $COOKIE_FLAGS; Max-Age=0");
  }

  # ---------- Requieren sesión ----------
  return err(401, 'Inicia sesión para continuar') unless $me;
  my $admin = $me->{rol} eq 'admin';

  if ($p eq '/api/data' && $m eq 'GET') { return json_res(200, all_data($dbh, $me)) }

  if ($p eq '/api/recomendar' && $m eq 'POST') {
    my $t = $body->{tecnologia} // ''; my $pres = int($body->{presupuesto} // 0);
    return err(400, 'Tecnología no válida') unless $t =~ /^(BEV|PHEV|HEV)$/;
    return json_res(200, recomendar($dbh, $t, $pres, $body->{carga} // 'Si'));
  }

  if ($p eq '/api/interacciones' && $m eq 'POST') {
    my $c = get_cliente($dbh, $body->{clienteId}) or return err(404, 'Cliente no encontrado');
    return err(403, 'No tienes acceso a este cliente') unless $admin || $c->{asesor} eq $me->{nombre};
    return err(400, 'Cliente sin permiso de contacto (GDPR)') unless $c->{permiso} eq 'Si';
    my $res = trim($body->{resultado}); return err(400, 'Describe el resultado') unless $res;
    add_int($dbh, $c->{id}, trim($body->{canal}) || 'Otro', trim($body->{evento}) || 'Otro', $res, $me->{nombre}, trim($body->{accion}));
    return json_res(200, { ok => 1 });
  }

  if ($p eq '/api/respuestas/leidas' && $m eq 'POST') {
    if ($admin) { $dbh->do('UPDATE enlaces SET leido = 1 WHERE respondido IS NOT NULL') }
    else { $dbh->do('UPDATE enlaces SET leido = 1 WHERE respondido IS NOT NULL AND cliente_id IN (SELECT id FROM clientes WHERE asesor = ?)', undef, $me->{nombre}) }
    return json_res(200, { ok => 1 });
  }

  return err(403, 'Solo el administrador puede hacer esto') unless $admin;

  if ($p eq '/api/correo/vista-previa' && $m eq 'GET') {
    my %q = $r->uri->query_form;
    my $c = get_cliente($dbh, $q{cliente}) or return err(404, 'Cliente no encontrado');
    my $v = vehiculo_de($dbh, $c) or return err(400, 'No hay vehículo para este cliente');
    my $fecha = fecha_valida($q{fecha}) ? $q{fecha} : undef;
    my $html = html_invitacion(c => $c, v => $v, texto => texto_plantilla($dbh, $c, $v, fecha_txt($fecha)), ftxt => fecha_txt($fecha),
                               tiene_fecha => $fecha ? 1 : 0, url => '#vista-previa', img => "/img/$v->{id}.jpg");
    my $res = HTTP::Response->new(200);
    $res->header('Content-Type' => 'text/html; charset=utf-8', 'Cache-Control' => 'no-store');
    $res->content(encode('UTF-8', $html));
    return $res;
  }

  if ($p eq '/api/clientes' && $m eq 'POST') { return crear_cliente($dbh, $me, $body) }
  if ($p =~ m{^/api/clientes/(C\d+)$} && $m eq 'PUT') { return editar_cliente($dbh, $me, $1, $body) }
  if ($p =~ m{^/api/clientes/(C\d+)$} && $m eq 'DELETE') {
    my $id = $1;
    # Borrado completo (derecho de supresión): perfil, historial, encuestas, enlaces de respuesta y registro de envíos
    return transaction($dbh, sub {
      write_lock($dbh);
      return err(404, 'Cliente no encontrado') unless get_cliente($dbh, $id);
      $dbh->do('DELETE FROM envios WHERE cliente_id = ?', undef, $id);
      $dbh->do('DELETE FROM clientes WHERE id = ?', undef, $id); # Cascada: interacciones, encuestas y enlaces.
      return json_res(200, { ok => 1, eliminado => $id });
    });
  }

  if ($p eq '/api/invitaciones' && $m eq 'POST') {
    if (defined $body->{plantilla} && trim($body->{plantilla}) ne '') { set_config($dbh, 'plantillaInvitacion', $body->{plantilla}) }
    my @ids = ref $body->{ids} eq 'ARRAY' ? @{ $body->{ids} } : ();
    return err(400, 'Selecciona al menos un cliente') unless @ids;
    my @out;
    for my $id (@ids) {
      my $c = get_cliente($dbh, $id) or next;
      push @out, { clienteId => $id, nombre => "$c->{nombre} $c->{apellido}", email => $c->{email}, %{ enviar_invitacion($dbh, $c, $me, $body->{fecha}) } };
    }
    return json_res(200, { resultados => \@out });
  }
  if ($p eq '/api/plantilla' && $m eq 'PUT') {
    my $t = $body->{plantilla} // ''; return err(400, 'La plantilla está vacía') unless trim($t);
    set_config($dbh, 'plantillaInvitacion', $t); return json_res(200, { ok => 1 });
  }

  if ($p eq '/api/encuestas' && $m eq 'POST') {
    my $tipo = trim($body->{tipo}) || 'Satisfacción post-visita';
    my @ids = ref $body->{ids} eq 'ARRAY' ? @{ $body->{ids} } : ();
    return err(400, 'Selecciona al menos un cliente') unless @ids;
    my @out;
    for my $id (@ids) {
      my $c = get_cliente($dbh, $id) or next;
      push @out, { clienteId => $id, nombre => "$c->{nombre} $c->{apellido}", email => $c->{email}, %{ enviar_encuesta($dbh, $c, $me, $tipo) } };
    }
    return json_res(200, { resultados => \@out });
  }
  if ($p =~ m{^/api/encuestas/(E\d+)/respuesta$} && $m eq 'POST') {
    my $e = $dbh->selectrow_hashref('SELECT * FROM encuestas WHERE id = ?', undef, $1) or return err(404, 'Encuesta no encontrada');
    my ($ok, $msg) = registrar_encuesta($dbh, $e, $body, $me->{nombre}, 1);
    return $ok ? json_res(200, { ok => 1 }) : err(400, $msg);
  }

  if ($p =~ m{^/api/catalogo/(V\d\d)/disponible$} && $m eq 'POST') {
    $dbh->do('UPDATE catalogo SET disponible = ? WHERE id = ?', undef, $body->{disponible} ? 1 : 0, $1);
    return json_res(200, { ok => 1 });
  }

  if ($p eq '/api/usuarios' && $m eq 'POST') {
    my ($nombre, $email, $pass, $rol) = (trim($body->{nombre}), lc trim($body->{email}), $body->{password} // '', $body->{rol} // 'estandar');
    return err(400, 'Indica nombre, correo válido y contraseña de al menos 8 caracteres') unless $nombre && valid_email($email) && length($pass) >= 8;
    return err(400, 'Rol no válido') unless $rol =~ /^(admin|estandar)$/;
    my ($dup) = $dbh->selectrow_array('SELECT COUNT(*) FROM usuarios WHERE lower(nombre) = lower(?) OR lower(email) = ?', undef, $nombre, $email);
    return err(400, 'Ya existe un usuario con ese nombre o correo') if $dup;
    $dbh->do('INSERT INTO usuarios (nombre,email,rol,pass_hash,creado) VALUES (?,?,?,?,?)', undef, $nombre, $email, $rol, hash_password($pass), now_iso());
    return json_res(200, { ok => 1 });
  }
  if ($p =~ m{^/api/usuarios/(\d+)/acceso$} && $m eq 'PUT') {
    my $uid = $1; my ($email, $pass) = (lc trim($body->{email}), $body->{password} // '');
    return err(400, 'Indica un correo válido y una contraseña de al menos 8 caracteres') unless valid_email($email) && length($pass) >= 8;
    my ($dup) = $dbh->selectrow_array('SELECT COUNT(*) FROM usuarios WHERE lower(email) = ? AND id <> ?', undef, $email, $uid);
    return err(400, 'Ese correo ya lo usa otro usuario') if $dup;
    my $n = $dbh->do('UPDATE usuarios SET email = ?, pass_hash = ? WHERE id = ?', undef, $email, hash_password($pass), $uid);
    return err(404, 'Usuario no encontrado') unless $n > 0;
    $dbh->do('DELETE FROM sesiones WHERE usuario_id = ? AND usuario_id <> ?', undef, $uid, $me->{id});
    return json_res(200, { ok => 1 });
  }

  if ($p eq '/api/correo/prueba' && $m eq 'POST') {
    my $to = trim($body->{to}); return err(400, 'Correo no válido') unless valid_email($to);
    my ($ok, $det) = send_mail(to => $to, subject => "Prueba de correo · $CONCESIONARIO CRM",
      text => "Este es un correo de prueba enviado desde el CRM de $CONCESIONARIO. Si lo recibes, el envío por Gmail funciona.",
      html => "<p>Este es un correo de prueba enviado desde el CRM de <b>$CONCESIONARIO</b>.</p><p>Si lo recibes, el envío por Gmail funciona.</p>");
    log_envio($dbh, undef, 'prueba', $to, 'Prueba de correo', $ok ? 'enviado' : 'error', $det, $me->{nombre});
    return $ok ? json_res(200, { ok => 1 }) : err(502, $det);
  }

  return err(404, 'Ruta no encontrada');
}

# ---------- Sesión ----------
sub cookie_token { my $r = shift; my $c = $r->header('Cookie') // ''; return $c =~ /(?:^|;\s*)sid=([0-9a-f]{64})/ ? $1 : undef }
sub current_user {
  my ($dbh, $r) = @_;
  my $tok = cookie_token($r) or return undef;
  return $dbh->selectrow_hashref('SELECT u.id, u.nombre, u.email, u.rol FROM sesiones s JOIN usuarios u ON u.id = s.usuario_id WHERE s.token = ? AND s.expira > ?', undef, $tok, time);
}
sub needs_setup { my $dbh = shift; my ($n) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM usuarios WHERE rol = 'admin' AND pass_hash IS NOT NULL}); return !$n }
sub login_ok {
  my ($dbh, $uid) = @_;
  my $tok = rand_hex(32); my $ttl = 12 * 3600;
  $dbh->do('DELETE FROM sesiones WHERE expira < ?', undef, time);
  $dbh->do('INSERT INTO sesiones (token,usuario_id,expira) VALUES (?,?,?)', undef, $tok, $uid, time + $ttl);
  return json_res(200, { ok => 1 }, 'Set-Cookie' => "sid=$tok; $COOKIE_FLAGS; Max-Age=$ttl");
}

# ---------- Datos ----------
sub get_cliente { my ($dbh, $id) = @_; return undef unless defined($id) && !ref($id) && $id =~ /\AC[0-9]+\z/; $dbh->selectrow_hashref("SELECT $CLI_COLS FROM clientes WHERE id = ?", undef, $id) }
sub get_config { my ($dbh, $k) = @_; my ($v) = $dbh->selectrow_array('SELECT valor FROM config WHERE clave = ?', undef, $k); $v }
sub set_config { my ($dbh, $k, $v) = @_; $dbh->do('INSERT INTO config (clave,valor) VALUES (?,?) ON CONFLICT(clave) DO UPDATE SET valor = excluded.valor', undef, $k, $v) }
sub add_int {
  my ($dbh, $cid, $canal, $evento, $res, $resp, $acc) = @_;
  $dbh->do('INSERT INTO interacciones (cliente_id,fecha,canal,evento,resultado,responsable,accion) VALUES (?,?,?,?,?,?,?)', undef, $cid, now_iso(), $canal, $evento, $res, $resp, $acc // '');
}
sub log_envio {
  my ($dbh, $cid, $tipo, $to, $asunto, $estado, $det, $user) = @_;
  $dbh->do('INSERT INTO envios (cliente_id,tipo,destinatario,asunto,estado,detalle,fecha,usuario) VALUES (?,?,?,?,?,?,?,?)', undef, $cid, $tipo, $to, $asunto, $estado, $det, now_iso(), $user);
}
sub catalogo { my $dbh = shift; my $c = $dbh->selectall_arrayref('SELECT * FROM catalogo ORDER BY id', { Slice => {} }); $_->{precio} += 0, $_->{disponible} = $_->{disponible} ? JSON::PP::true : JSON::PP::false for @$c; $c }

sub all_data {
  my ($dbh, $me) = @_;
  my $admin = $me->{rol} eq 'admin';
  my $cl = $admin
    ? $dbh->selectall_arrayref("SELECT $CLI_COLS FROM clientes ORDER BY id", { Slice => {} })
    : $dbh->selectall_arrayref("SELECT $CLI_COLS FROM clientes WHERE asesor = ? ORDER BY id", { Slice => {} }, $me->{nombre});
  for (@$cl) {
    $_->{presupuesto} += 0; $_->{compraDias} += 0;
    if (!$admin && $_->{permiso} ne 'Si') { $_->{email} = ''; $_->{telefono} = '' }
  }
  my $scope = $admin ? '' : ' AND cliente_id IN (SELECT id FROM clientes WHERE asesor = ?)';
  my @bind = $admin ? () : ($me->{nombre});
  my $ints = $dbh->selectall_arrayref(qq{SELECT id, cliente_id AS "clienteId", fecha, canal, evento, resultado, responsable, accion FROM interacciones WHERE 1=1$scope ORDER BY fecha, id}, { Slice => {} }, @bind);
  $_->{id} += 0 for @$ints;
  my $encs = $dbh->selectall_arrayref(qq{SELECT id, cliente_id AS "clienteId", tipo, canal, enviada, estado, respuestas, respondida FROM encuestas WHERE 1=1$scope ORDER BY enviada, id}, { Slice => {} }, @bind);
  $_->{respuestas} = $_->{respuestas} ? JSON::PP->new->decode($_->{respuestas}) : undef for @$encs;
  my $users = $dbh->selectall_arrayref('SELECT id, nombre, email, rol, pass_hash IS NOT NULL AS acceso FROM usuarios ORDER BY rol, nombre', { Slice => {} });
  for (@$users) { $_->{id} += 0; $_->{acceso} = $_->{acceso} ? JSON::PP::true : JSON::PP::false; delete $_->{email} unless $admin }
  my $link_id = is_pg($dbh) ? 'id' : 'rowid';
  my $resps = $dbh->selectall_arrayref(qq{SELECT $link_id AS id, tipo, cliente_id AS "clienteId", resumen, respondido, leido FROM enlaces WHERE respondido IS NOT NULL$scope ORDER BY respondido DESC, id DESC LIMIT 200}, { Slice => {} }, @bind);
  for (@$resps) { $_->{id} += 0; $_->{leido} = $_->{leido} ? JSON::PP::true : JSON::PP::false }
  return {
    me => { id => $me->{id} + 0, nombre => $me->{nombre}, email => $me->{email}, rol => $me->{rol} },
    clientes => $cl, interacciones => $ints, encuestas => $encs, catalogo => catalogo($dbh), usuarios => $users, respuestas => $resps,
    publicUrl => $PUBLIC_URL,
    plantillaInvitacion => get_config($dbh, 'plantillaInvitacion'),
    correo => { configurado => mail_configured() ? JSON::PP::true : JSON::PP::false, remitente => $admin ? (cfg('GMAIL_USER') // '') : '' },
  };
}

# =========================================================
#  Recomendación de vehículo (catálogo × tecnología × presupuesto)
# =========================================================
sub recomendar {
  my ($dbh, $tec, $pres, $carga) = @_;
  my @cands = grep { $_->{tec} eq $tec } @{ catalogo($dbh) };
  @cands = sort { $a->{precio} <=> $b->{precio} } @cands;
  my @dentro = grep { $_->{precio} <= $pres } @cands;
  my @disp = grep { $_->{disponible} } @dentro;
  my ($v, $estado, $motivo);
  if (@disp) {
    $v = $disp[-1]; $estado = 'ok';
    $motivo = "Es el $tec de mayor gama que cabe en el presupuesto y tiene unidad de test drive disponible.";
  } elsif (@dentro) {
    $v = $dentro[-1]; $estado = 'espera';
    $motivo = "Cabe en el presupuesto, pero la unidad de test drive no está disponible hoy: ofrecer fecha alternativa.";
  } elsif (@cands) {
    $v = $cands[0]; $estado = 'presupuesto';
    $motivo = "Ningún $tec cabe en el presupuesto. Se propone el más asequible y revisar financiación.";
  } else {
    return { vehiculo => undef, estado => 'sin_catalogo', motivo => "No hay vehículos $tec en el catálogo.", alternativas => [] };
  }
  my $aviso = '';
  $aviso = "Carga habitual \"$carga\": validar punto de carga antes del test drive." if $tec ne 'HEV' && $carga ne 'Si';
  my @otras = grep { $_->{tec} ne $tec && $_->{precio} <= $pres && $_->{disponible} } @{ catalogo($dbh) };
  return {
    vehiculo => $v, estado => $estado, motivo => $motivo, aviso => $aviso,
    margen => $pres - $v->{precio},
    alternativas => [ map { { id => $_->{id}, modelo => $_->{modelo}, precio => $_->{precio} } } @dentro ],
    otraTecnologia => @otras ? { id => $otras[-1]{id}, modelo => $otras[-1]{modelo}, tec => $otras[-1]{tec}, precio => $otras[-1]{precio} } : undef,
  };
}

# =========================================================
#  Clientes
# =========================================================
sub validar_cliente {
  my ($dbh, $b, $id) = @_;
  my %f; my @e;
  $f{$_} = trim($b->{$_}) for qw(nombre apellido telefono email origen permiso canal tecnologia carga asesor vehiculo);
  $f{email} = lc $f{email};
  push @e, 'Falta el nombre.' unless $f{nombre};
  push @e, 'Falta el apellido.' unless $f{apellido};
  push @e, 'Falta el teléfono.' unless $f{telefono};
  push @e, 'Falta el correo electrónico.' unless $f{email};
  push @e, 'El correo electrónico no es válido.' if $f{email} && !valid_email($f{email});
  push @e, 'El teléfono debe tener al menos 9 dígitos.' if $f{telefono} && ($f{telefono} !~ /^\+?[\d\s()-]+$/ || ($f{telefono} =~ tr/0-9//) < 9);
  push @e, 'Origen no válido.' unless $f{origen} =~ /^(Web|Visita|Evento|Referido)$/;
  push @e, 'Permiso no válido.' unless $f{permiso} =~ /^(Si|No)$/;
  push @e, 'Canal no válido.' unless $f{canal} =~ /^(Email|Telefono)$/;
  push @e, 'Tecnología no válida.' unless $f{tecnologia} =~ /^(BEV|PHEV|HEV)$/;
  push @e, 'Carga habitual no válida.' unless $f{carga} =~ /^(Si|No|Por confirmar)$/;
  $f{presupuesto} = $b->{presupuesto} // ''; $f{compraDias} = $b->{compraDias} // '';
  push @e, 'Indica un presupuesto mayor que 0.' unless $f{presupuesto} =~ /^\d+(\.\d+)?$/ && $f{presupuesto} > 0;
  push @e, 'Indica en cuántos días prevé comprar.' unless $f{compraDias} =~ /^\d+$/;
  my ($ok_as) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM usuarios WHERE nombre = ? AND rol = 'estandar'}, undef, $f{asesor});
  push @e, 'Asesor no válido.' unless $ok_as;
  if ($f{vehiculo} ne '') { my ($ok_v) = $dbh->selectrow_array('SELECT COUNT(*) FROM catalogo WHERE id = ?', undef, $f{vehiculo}); push @e, 'Vehículo no válido.' unless $ok_v }
  if ($f{email} || $f{telefono}) {
    (my $tel = $f{telefono}) =~ s/\D//g;
    for my $c (@{ $dbh->selectall_arrayref('SELECT id, nombre, apellido, email, telefono FROM clientes', { Slice => {} }) }) {
      next if defined $id && $c->{id} eq $id;
      (my $t2 = $c->{telefono}) =~ s/\D//g;
      if (lc $c->{email} eq $f{email} || ($tel ne '' && $t2 eq $tel)) { push @e, "Posible duplicado: $c->{id} ($c->{nombre} $c->{apellido}) ya usa ese correo o teléfono."; last }
    }
  }
  $f{presupuesto} = int($f{presupuesto} || 0); $f{compraDias} = int($f{compraDias} || 0);
  return (\%f, \@e);
}

sub crear_cliente {
  my ($dbh, $me, $b) = @_;
  my ($reco, $c);
  my $failure = transaction($dbh, sub {
    write_lock($dbh);
    my ($f, $e) = validar_cliente($dbh, $b, undef);
    return json_res(400, { error => join(' ', @$e), errores => $e }) if @$e;
    $reco = recomendar($dbh, $f->{tecnologia}, $f->{presupuesto}, $f->{carga});
    my $veh = $f->{vehiculo} ne '' ? $f->{vehiculo} : ($reco->{vehiculo} ? $reco->{vehiculo}{id} : undef);
    my $id = next_id($dbh, 'clientes');
    $dbh->do("INSERT INTO clientes (id,nombre,apellido,telefono,email,origen,permiso,canal,tecnologia,presupuesto,compra_dias,carga,asesor,vehiculo,creado) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      undef, $id, @$f{qw(nombre apellido telefono email origen permiso canal tecnologia presupuesto compraDias carga asesor)}, $veh, now_iso());
    add_int($dbh, $id, $f->{origen}, 'Consulta', 'Alta de cliente en CRM', $me->{nombre}, '');
    if ($reco->{vehiculo}) {
      add_int($dbh, $id, 'Otro', 'Otro', "Recomendación automática: $reco->{vehiculo}{modelo} ($reco->{vehiculo}{id}) · " . eur($reco->{vehiculo}{precio}) . " · $reco->{motivo}", 'Motor de recomendación', '');
    }
    $c = get_cliente($dbh, $id);
    return undef;
  });
  return $failure if $failure;
  my $envio = { estado => 'no_solicitado', detalle => 'No se pidió enviar la invitación.' };
  $envio = enviar_invitacion($dbh, $c, $me, $b->{fecha}) if $b->{enviarInvitacion};
  return json_res(200, { cliente => $c, recomendacion => $reco, envio => $envio });
}

sub editar_cliente {
  my ($dbh, $me, $id, $b) = @_;
  return transaction($dbh, sub {
    write_lock($dbh);
    my $old = get_cliente($dbh, $id) or return err(404, 'Cliente no encontrado');
    my ($f, $e) = validar_cliente($dbh, $b, $id);
    return json_res(400, { error => join(' ', @$e), errores => $e }) if @$e;
    if ($f->{vehiculo} eq '') { my $reco = recomendar($dbh, $f->{tecnologia}, $f->{presupuesto}, $f->{carga}); $f->{vehiculo} = $reco->{vehiculo} ? $reco->{vehiculo}{id} : undef }
    my @camb = grep { ($old->{$_} // '') ne ($f->{$_} // '') } qw(presupuesto carga tecnologia permiso compraDias vehiculo email telefono asesor);
    $dbh->do('UPDATE clientes SET nombre=?,apellido=?,telefono=?,email=?,origen=?,permiso=?,canal=?,tecnologia=?,presupuesto=?,compra_dias=?,carga=?,asesor=?,vehiculo=? WHERE id=?',
      undef, @$f{qw(nombre apellido telefono email origen permiso canal tecnologia presupuesto compraDias carga asesor vehiculo)}, $id);
    add_int($dbh, $id, 'Otro', 'Otro', 'Perfil actualizado: ' . join(', ', @camb), $me->{nombre}, '') if @camb;
    return json_res(200, { cliente => get_cliente($dbh, $id) });
  });
}

# =========================================================
#  Correo (Gmail SMTP con contraseña de aplicación)
# =========================================================
sub mail_configured { my $u = cfg('GMAIL_USER', ''); my $p = cfg('GMAIL_APP_PASSWORD', ''); return valid_email($u) && $p ne '' && $p !~ /^PEGA_AQUI/ }
sub mime_word { my $s = shift; $s =~ s/[\x00-\x1f\x7f]+/ /g; return $s =~ /[^\x20-\x7e]/ ? '=?UTF-8?B?' . encode_base64(encode('UTF-8', $s), '') . '?=' : $s }

sub build_mime {
  my %m = @_;
  my $from_name = cfg('MAIL_FROM_NAME', $CONCESIONARIO);
  my $from = cfg('GMAIL_USER');
  my ($b1, $b2) = ('alt_' . rand_hex(12), 'rel_' . rand_hex(12));
  my $msgid = '<' . rand_hex(16) . '@ecoruta-crm.local>';
  my $out = '';
  $out .= 'From: ' . mime_word($from_name) . " <$from>\n";
  $out .= "To: $m{to}\n";
  $out .= "Reply-To: $from\n";
  $out .= 'Subject: ' . mime_word($m{subject}) . "\n";
  $out .= 'Date: ' . strftime('%a, %d %b %Y %H:%M:%S %z', localtime) . "\n";
  $out .= "Message-ID: $msgid\nMIME-Version: 1.0\n";
  $out .= "Content-Type: multipart/alternative; boundary=\"$b1\"\n\n";
  $out .= "--$b1\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n" . encode_base64(encode('UTF-8', $m{text})) . "\n";
  my $img;
  if ($m{img} && open(my $fh, '<:raw', $m{img})) { local $/; $img = <$fh>; close $fh }
  if ($img) {
    $out .= "--$b1\nContent-Type: multipart/related; boundary=\"$b2\"\n\n";
    $out .= "--$b2\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n" . encode_base64(encode('UTF-8', $m{html})) . "\n";
    $out .= "--$b2\nContent-Type: image/jpeg; name=\"vehiculo.jpg\"\nContent-Transfer-Encoding: base64\nContent-ID: <vehiculo>\nContent-Disposition: inline; filename=\"vehiculo.jpg\"\n\n" . encode_base64($img) . "\n";
    $out .= "--$b2--\n";
  } else {
    $out .= "--$b1\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n" . encode_base64(encode('UTF-8', $m{html})) . "\n";
  }
  $out .= "--$b1--\n";
  return $out;
}

sub send_mail {
  my %m = @_;
  return (0, 'El correo no está configurado: falta GMAIL_USER o GMAIL_APP_PASSWORD en el archivo .env.') unless mail_configured();
  return (0, "Dirección de destino no válida: $m{to}") unless valid_email($m{to});
  my $user = cfg('GMAIL_USER'); (my $pass = cfg('GMAIL_APP_PASSWORD')) =~ s/\s+//g;
  my $host = cfg('SMTP_HOST', 'smtp.gmail.com');
  my $implicit_tls = flag('SMTP_SSL', 1);
  my $port = cfg('SMTP_PORT', $implicit_tls ? 465 : 587);
  my $mime = build_mime(%m);
  my @ssl = (SSL_verify_mode => 1);
  push @ssl, (SSL_ca_file => cfg('SMTP_CA_FILE')) if cfg('SMTP_CA_FILE', '') ne '';
  my $smtp = Net::SMTP->new($host, Port => $port, SSL => $implicit_tls ? 1 : 0, @ssl, Timeout => 12, Hello => 'localhost')
    or return (0, "No se pudo conectar con $host:$port. Revisa tu conexión a internet.");
  unless ($implicit_tls || $smtp->starttls) {
    $smtp->close;
    return (0, 'No se pudo establecer STARTTLS con el servidor de correo.');
  }
  unless ($smtp->auth($user, $pass)) {
    $smtp->quit;
    return (0, 'El servidor de correo rechazó el acceso. Revisa GMAIL_USER y la contraseña de aplicación.');
  }
  my $ok = $smtp->mail($user) && $smtp->to($m{to}) && $smtp->data && $smtp->datasend($mime) && $smtp->dataend;
  $smtp->quit;
  return $ok ? (1, 'Enviado') : (0, 'El servidor de correo rechazó el envío.');
}


# =========================================================
#  Textos y formato
# =========================================================
sub fecha_txt {
  my $f = shift // '';
  return 'la fecha que tú elijas' unless $f =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)/;
  my @mes = qw(enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre);
  my @dia = qw(domingo lunes martes miércoles jueves viernes sábado);
  my ($y, $m, $d, $h, $min) = ($1, $2, $3, $4, $5);
  my $day = eval { timegm_posix(0, 0, 12, $d, $m - 1, $y - 1900) };
  return 'la fecha que tú elijas' unless defined $day && (gmtime($day))[3] == $d;
  return "$dia[(gmtime($day))[6]] " . int($d) . " de $mes[$m-1] a las $h:$min";
}
sub fecha_valida {
  my $f = shift // '';
  return $f =~ /\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]\z/
    && fecha_txt($f) ne 'la fecha que tú elijas';
}
sub tecnom { my $t = shift // ''; my %m = (BEV => '100% eléctrico', PHEV => 'híbrido enchufable', HEV => 'híbrido'); return $m{$t} // $t }
sub ucfirst_utf { my $s = shift // ''; return ucfirst $s }
sub iniciales { my $n = shift // ''; my @p = grep { length } split /\s+/, $n; return uc join '', map { substr($_, 0, 1) } @p[0 .. ($#p < 1 ? $#p : 1)] }
sub vehiculo_de {
  my ($dbh, $c) = @_;
  my $v = $dbh->selectrow_hashref('SELECT * FROM catalogo WHERE id = ?', undef, $c->{vehiculo} // '');
  return $v || recomendar($dbh, $c->{tecnologia}, $c->{presupuesto}, $c->{carga})->{vehiculo};
}
sub texto_plantilla {
  my ($dbh, $c, $v, $ftxt) = @_;
  my %rep = (nombre => $c->{nombre}, apellido => $c->{apellido}, vehiculo => $v->{modelo}, tecnologia => tecnom($v->{tec}),
             asesor => $c->{asesor}, fecha => $ftxt, precio => eur($v->{precio}));
  (my $t = get_config($dbh, 'plantillaInvitacion') // plantilla_v2()) =~ s/\{(\w+)\}/exists $rep{$1} ? $rep{$1} : "{$1}"/ge;
  return $t;
}
sub parrafos_html {
  my $t = shift // '';
  return join '', map { '<p style="margin:0 0 14px;font-size:15.5px;line-height:1.65;color:#3b4a42">' . join('<br>', map { esc_html($_) } split /\n/, $_) . '</p>' }
                  grep { /\S/ } split /\n\s*\n/, $t;
}

# =========================================================
#  Diseño del correo (HTML compatible con Gmail, Outlook y Apple Mail)
# =========================================================
sub email_layout {
  my %a = @_;
  my $pre = esc_html($a{preheader} // '');
  my $title = esc_html($a{title} // $CONCESIONARIO);
  my $legal = $a{legal} // '';
  return qq{<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light only"><title>$title</title></head>
<body style="margin:0;padding:0;background:#eef3ee;-webkit-text-size-adjust:100%">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:#eef3ee;font-size:1px;line-height:1px">$pre</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#eef3ee"><tr><td align="center" style="padding:28px 12px">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;background:#ffffff;border-radius:18px;overflow:hidden;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;color:#1c2420">
<tr><td style="background:#1f7a4d;padding:20px 28px">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
    <td style="vertical-align:middle;white-space:nowrap"><span style="display:inline-block;width:34px;height:34px;line-height:34px;border-radius:9px;background:#ffffff;color:#1f7a4d;font-weight:800;font-size:18px;text-align:center;vertical-align:middle">E</span><span style="color:#ffffff;font-size:19px;font-weight:700;vertical-align:middle;padding-left:10px">$CONCESIONARIO</span></td>
    <td align="right" style="color:#cdebd9;font-size:12px;vertical-align:middle">Movilidad eléctrica e híbrida</td>
  </tr></table>
</td></tr>
$a{content}
<tr><td style="background:#f6f8f6;padding:20px 28px;font-size:11.5px;line-height:1.6;color:#6b7a72;border-top:1px solid #e3e9e4">$legal$CONCESIONARIO · Madrid, España. Recibes este correo porque autorizaste el contacto comercial con nosotros. Si no deseas recibir más comunicaciones, responde a este correo con la palabra BAJA.</td></tr>
</table>
</td></tr></table>
</body></html>};
}
sub email_button {
  my ($url, $text) = @_;
  my ($u, $t) = (esc_html($url), esc_html($text));
  return qq{<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center" style="margin:0 auto"><tr><td align="center" bgcolor="#1f7a4d" style="border-radius:12px;background:#1f7a4d"><a href="$u" target="_blank" style="display:inline-block;padding:16px 36px;font-size:16px;font-weight:700;color:#ffffff;text-decoration:none;border-radius:12px;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif">$t</a></td></tr></table>};
}
sub email_asesor {
  my $n = shift // '';
  my ($ini, $nom) = (esc_html(iniciales($n)), esc_html($n));
  return qq{<tr><td style="padding:6px 32px 28px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-top:1px solid #e3e9e4"><tr>
    <td width="56" style="padding-top:20px;vertical-align:middle"><div style="width:46px;height:46px;line-height:46px;border-radius:50%;background:#e2f1e8;color:#1f7a4d;font-weight:700;font-size:16px;text-align:center">$ini</div></td>
    <td style="padding-top:20px;vertical-align:middle;font-size:14px;line-height:1.5;color:#3b4a42"><b style="color:#1c2420;font-size:15px">$nom</b><br>Tu asesor/a en $CONCESIONARIO<br><span style="color:#6b7a72;font-size:13px">¿Prefieres escribirnos? Responde a este correo y te contestamos enseguida.</span></td>
  </tr></table></td></tr>};
}

sub html_invitacion {
  my %a = @_;
  my ($c, $v) = @a{qw(c v)};
  my $modelo = esc_html($v->{modelo});
  my $nombre = esc_html($c->{nombre});
  my $img = esc_html($a{img});
  my $tec = esc_html(ucfirst_utf(tecnom($v->{tec})));
  my $uso = esc_html($v->{uso} // '');
  my $precio = esc_html(eur($v->{precio}));
  my $version = esc_html($v->{version} // '');
  my $fecha = $a{tiene_fecha}
    ? qq{<div style="font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:#1f7a4d;font-weight:700">Fecha propuesta</div><div style="font-size:18px;font-weight:700;color:#1c2420;margin-top:4px">} . esc_html(ucfirst_utf($a{ftxt})) . qq{</div><div style="font-size:13px;color:#5d6b63;margin-top:4px">¿No te viene bien? Podrás proponer otra fecha al responder.</div>}
    : qq{<div style="font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:#1f7a4d;font-weight:700">Tú eliges el día</div><div style="font-size:16px;font-weight:700;color:#1c2420;margin-top:4px">Propón la fecha y hora que mejor te vengan</div><div style="font-size:13px;color:#5d6b63;margin-top:4px">Nos adaptamos a tu agenda, también fines de semana.</div>};
  my $spec = sub { my ($k, $val) = @_; qq{<td width="33%" style="padding:4px;vertical-align:top"><div style="background:#f3f7f4;border-radius:12px;padding:12px 12px;min-height:58px"><div style="font-size:11px;color:#6b7a72;text-transform:uppercase;letter-spacing:.05em">$k</div><div style="font-size:14px;font-weight:700;color:#1c2420;margin-top:3px">$val</div></div></td>} };
  my $content = qq{
<tr><td style="padding:0;background:#f3f7f4"><img src="$img" width="600" alt="$modelo" style="display:block;width:100%;max-width:600px;height:auto;border:0"></td></tr>
<tr><td style="padding:28px 32px 6px">
  <div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#1f7a4d;font-weight:700">Invitación personal · Test drive</div>
  <h1 style="margin:8px 0 4px;font-size:26px;line-height:1.25;color:#1c2420">$nombre, el $modelo te está esperando</h1>
  <div style="font-size:14px;color:#6b7a72">$version</div>
</td></tr>
<tr><td style="padding:18px 32px 4px">} . parrafos_html($a{texto}) . qq{</td></tr>
<tr><td style="padding:4px 28px 8px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>} . $spec->('Tecnología', $tec) . $spec->('Ideal para', $uso) . $spec->('Precio desde', $precio) . qq{</tr></table></td></tr>
<tr><td style="padding:12px 32px 4px"><div style="border:1.5px solid #cfe5d8;background:#f4faf6;border-radius:14px;padding:16px 18px">$fecha</div></td></tr>
<tr><td style="padding:24px 32px 8px" align="center">} . email_button($a{url}, 'Responder a la invitación') . qq{
  <div style="font-size:13px;color:#6b7a72;margin-top:12px;line-height:1.5">Te llevará menos de un minuto. Tu respuesta llega directamente a tu asesor/a.</div></td></tr>
} . email_asesor($c->{asesor});
  return email_layout(title => "Invitación a probar el $v->{modelo}", preheader => "$c->{nombre}, te reservamos una prueba de conducción del $v->{modelo}, sin compromiso.",
    content => $content, legal => 'Precio de referencia: confirma condiciones, stock y gastos finales con tu asesor/a. ');
}

sub intro_encuesta {
  my ($c, $tipo) = @_;
  my $cuerpo = $tipo =~ /test drive/i
    ? "Gracias por probar uno de nuestros vehículos. Nos encantaría saber qué te pareció la experiencia y cómo podemos ayudarte a dar el siguiente paso."
    : $tipo =~ /nuevo modelo/i
    ? "Estamos preparando novedades en nuestra gama eléctrica e híbrida y queremos saber qué es lo que más te interesa."
    : "Gracias por visitarnos. Tu opinión nos ayuda a mejorar cada día y a ofrecerte una atención todavía más cercana.";
  return "Hola $c->{nombre},\n\n$cuerpo\n\n¿Nos regalas un minuto? Son solo 4 preguntas.";
}
sub html_encuesta {
  my %a = @_;
  my $c = $a{c};
  my $nombre = esc_html($c->{nombre});
  my $content = qq{
<tr><td style="padding:30px 32px 6px">
  <div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#1f7a4d;font-weight:700">} . esc_html($a{tipo}) . qq{</div>
  <h1 style="margin:8px 0 4px;font-size:26px;line-height:1.25;color:#1c2420">$nombre, ¿cómo fue tu experiencia?</h1>
</td></tr>
<tr><td style="padding:16px 32px 4px">} . parrafos_html($a{texto}) . qq{</td></tr>
<tr><td style="padding:8px 32px 8px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f3f7f4;border-radius:14px"><tr><td style="padding:14px 18px;font-size:14px;line-height:1.9;color:#3b4a42">
  ★ Tu satisfacción con la atención<br>★ Si nos recomendarías<br>★ Si te apetece una prueba de conducción<br>★ Lo que quieras contarnos
</td></tr></table></td></tr>
<tr><td style="padding:22px 32px 8px" align="center">} . email_button($a{url}, 'Responder la encuesta') . qq{
  <div style="font-size:13px;color:#6b7a72;margin-top:12px">Menos de un minuto · Tus respuestas llegan directamente a tu asesor/a.</div></td></tr>
} . email_asesor($c->{asesor});
  return email_layout(title => "Tu opinión · $CONCESIONARIO", preheader => "$c->{nombre}, ¿nos cuentas qué tal fue? Son solo 4 preguntas.", content => $content);
}

# =========================================================
#  Envío de invitaciones y encuestas
# =========================================================
sub crear_enlace {
  my ($dbh, %e) = @_;
  my $token = rand_hex(16);
  $dbh->do('INSERT INTO enlaces (token,tipo,cliente_id,encuesta_id,vehiculo,fecha_propuesta,creado) VALUES (?,?,?,?,?,?,?)', undef,
           $token, $e{tipo}, $e{cliente_id}, $e{encuesta_id}, $e{vehiculo}, $e{fecha}, now_iso());
  return $token;
}

sub enviar_invitacion {
  my ($dbh, $c, $me, $fecha) = @_;
  return { estado => 'sin_permiso', detalle => 'Sin permiso de contacto (GDPR): no se envía.' } unless $c->{permiso} eq 'Si';
  my ($cita) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM interacciones WHERE cliente_id = ? AND evento = 'Cita confirmada'}, undef, $c->{id});
  return { estado => 'omitido', detalle => 'Ya tiene una cita confirmada.' } if $cita;
  return { estado => 'omitido', detalle => 'Correo de demostración (@example.com): no se envía.' } if $c->{email} =~ /\@example\.(com|org|net)$/i;
  my $v = vehiculo_de($dbh, $c) or return { estado => 'error', detalle => 'No hay vehículo en el catálogo para esta tecnología.' };

  my $f = fecha_valida($fecha) ? $fecha : undef;
  my $ftxt = fecha_txt($f);
  my $token = crear_enlace($dbh, tipo => 'invitacion', cliente_id => $c->{id}, vehiculo => $v->{id}, fecha => $f);
  my $url = "$PUBLIC_URL/r/$token";
  my $texto = texto_plantilla($dbh, $c, $v, $ftxt);
  my $html = html_invitacion(c => $c, v => $v, texto => $texto, ftxt => $ftxt, tiene_fecha => $f ? 1 : 0, url => $url, img => 'cid:vehiculo');
  my $plain = "$texto\n\nFecha propuesta: " . ucfirst_utf($ftxt) . "\n\nResponde a la invitación aquí: $url\n\n$c->{asesor}\nTu asesor/a en $CONCESIONARIO";
  my $asunto = "$c->{nombre}, te invitamos a probar el $v->{modelo}";
  my ($ok, $det) = send_mail(to => $c->{email}, subject => $asunto, text => $plain, html => $html, img => "$FRONT/img/$v->{id}.jpg");
  log_envio($dbh, $c->{id}, 'invitacion', $c->{email}, $asunto, $ok ? 'enviado' : 'error', $det, $me->{nombre});
  unless ($ok) { $dbh->do('DELETE FROM enlaces WHERE token = ?', undef, $token); return { estado => 'error', detalle => $det } }
  add_int($dbh, $c->{id}, 'Email', 'Invitación test drive', "Correo enviado a $c->{email} para probar $v->{modelo} · fecha propuesta: $ftxt", $me->{nombre}, "Invitar a prueba $v->{tec}");
  return { estado => 'enviado', detalle => "Invitación enviada a $c->{email}", vehiculo => $v->{modelo} };
}

sub enviar_encuesta {
  my ($dbh, $c, $me, $tipo) = @_;
  return { estado => 'sin_permiso', detalle => 'Sin permiso de contacto (GDPR): no se envía.' } unless $c->{permiso} eq 'Si';
  my ($eid, $token);
  transaction($dbh, sub {
    write_lock($dbh);
    $eid = next_id($dbh, 'encuestas');
    $dbh->do('INSERT INTO encuestas (id,cliente_id,tipo,canal,enviada,estado) VALUES (?,?,?,?,?,?)', undef, $eid, $c->{id}, $tipo, 'Email', now_iso(), 'Enviada');
    $token = crear_enlace($dbh, tipo => 'encuesta', cliente_id => $c->{id}, encuesta_id => $eid);
  });
  my $url = "$PUBLIC_URL/r/$token";
  my $res;
  if ($c->{email} =~ /\@example\.(com|org|net)$/i) {
    $res = { estado => 'omitido', detalle => "Correo de demostración (\@example.com): encuesta registrada sin enviar. Enlace: $url" };
  } else {
    my $texto = intro_encuesta($c, $tipo);
    my $asunto = "$c->{nombre}, ¿nos cuentas qué tal fue? · $CONCESIONARIO";
    my ($ok, $det) = send_mail(to => $c->{email}, subject => $asunto, text => "$texto\n\nResponde aquí: $url\n\n$c->{asesor}\n$CONCESIONARIO",
                               html => html_encuesta(c => $c, tipo => $tipo, texto => $texto, url => $url));
    log_envio($dbh, $c->{id}, 'encuesta', $c->{email}, $asunto, $ok ? 'enviado' : 'error', $det, $me->{nombre});
    unless ($ok) {
      $dbh->do('DELETE FROM enlaces WHERE token = ?', undef, $token); $dbh->do('DELETE FROM encuestas WHERE id = ?', undef, $eid);
      return { estado => 'error', detalle => $det };
    }
    $res = { estado => 'enviado', detalle => "Encuesta enviada a $c->{email}" };
  }
  add_int($dbh, $c->{id}, 'Email', 'Encuesta enviada', $tipo, $me->{nombre}, 'Disparar encuesta');
  return $res;
}

# Guarda una respuesta de encuesta (desde la web del cliente o registrada por el administrador)
sub registrar_encuesta {
  my ($dbh, $e, $b, $quien, $leido) = @_;
  my $sat = ($b->{satisfaccion} // '') =~ /^([1-5])$/ ? $1 : 0;
  my $nps = ($b->{nps} // '') =~ /^(\d{1,2})$/ && $1 <= 10 ? $1 : -1;
  my $int = $b->{interes} // '';
  return (0, 'Responde las tres primeras preguntas, por favor.') unless $sat && $nps >= 0 && $int =~ /^(Sí|No|Más adelante)$/;
  return (0, 'Esta encuesta ya fue respondida.') if ($e->{estado} // '') eq 'Respondida';
  my $com = trim(substr($b->{comentario} // '', 0, 1000));
  my $resp = { satisfaccion => $sat + 0, nps => $nps + 0, interes => $int, comentario => $com };
  my $json = JSON::PP->new->encode($resp);
  my $resumen = "Encuesta: satisfacción $sat/5 · recomendaría $nps/10 · test drive: $int" . ($com ? " · \"$com\"" : '');
  return @{transaction($dbh, sub {
    write_lock($dbh);
    my $when = now_iso();
    my $n = $dbh->do(q{UPDATE encuestas SET estado = ?, respuestas = ?, respondida = ? WHERE id = ? AND estado <> 'Respondida'}, undef, 'Respondida', $json, $when, $e->{id});
    return [0, 'Esta encuesta ya fue respondida o no existe.'] unless $n > 0;
    $dbh->do('UPDATE enlaces SET respondido = ?, respuesta = ?, resumen = ?, leido = ? WHERE encuesta_id = ? AND respondido IS NULL', undef, $when, $json, $resumen, $leido ? 1 : 0, $e->{id});
    add_int($dbh, $e->{cliente_id}, 'Web', 'Encuesta respondida', $resumen, $quien, '');
    add_int($dbh, $e->{cliente_id}, 'Web', 'Solicitud prueba', 'Solicita prueba en la encuesta', $quien, '') if $int eq 'Sí';
    return [1, $resumen];
  })};
}

# Aviso al concesionario cuando un cliente responde
sub notificar_respuesta {
  my ($c, $resumen) = @_;
  my $to = cfg('NOTIFY_EMAIL', cfg('GMAIL_USER', ''));
  return unless mail_configured() && valid_email($to);
  my $nom = "$c->{nombre} $c->{apellido}";
  my $panel = $PUBLIC_URL;
  my $content = qq{<tr><td style="padding:28px 32px 8px">
    <div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#1f7a4d;font-weight:700">Nueva respuesta de cliente</div>
    <h1 style="margin:8px 0 12px;font-size:22px;line-height:1.3">} . esc_html($nom) . qq{ <span style="color:#6b7a72;font-weight:400">($c->{id})</span></h1>
    <div style="background:#f3f7f4;border-radius:12px;padding:14px 16px;font-size:15px;line-height:1.55;color:#1c2420">} . esc_html($resumen) . qq{</div>
    <div style="font-size:13px;color:#6b7a72;margin-top:10px">Asesor/a: } . esc_html($c->{asesor}) . qq{ · Ya quedó registrada en su historial del CRM.</div>
  </td></tr><tr><td style="padding:16px 32px 28px" align="center">} . email_button($panel, 'Abrir el CRM') . qq{</td></tr>};
  my ($ok, $det) = send_mail(to => $to, subject => "Respuesta de $nom: $resumen",
    text => "Nueva respuesta de $nom ($c->{id}):\n\n$resumen\n\nAsesor/a: $c->{asesor}\nAbre el CRM: $panel",
    html => email_layout(title => 'Nueva respuesta', preheader => $resumen, content => $content));
  my $dbh = db(); log_envio($dbh, $c->{id}, 'aviso', $to, "Aviso: respuesta de $nom", $ok ? 'enviado' : 'error', $det, 'sistema'); $dbh->disconnect;
}

# =========================================================
#  Página pública de respuesta del cliente (/r/<token>)
# =========================================================
sub parse_form {
  my $r = shift;
  my $u = URI->new('http://x/'); $u->query($r->content // '');
  my @kv = $u->query_form; my %f;
  while (my ($k, $v) = splice(@kv, 0, 2)) { $f{$k} = decode('UTF-8', $v // '') }
  return \%f;
}

sub page_res {
  my ($title, $inner, $code) = @_;
  my $css = <<'CSS';
*{box-sizing:border-box}
body{margin:0;background:#eef3ee;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#1c2420;-webkit-font-smoothing:antialiased}
.wrap{max-width:560px;margin:0 auto;padding:20px 16px 40px}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:17px;margin:4px 2px 16px;color:#1f7a4d}
.mark{width:32px;height:32px;border-radius:9px;background:#1f7a4d;color:#fff;display:grid;place-items:center;font-weight:800}
.card{background:#fff;border-radius:18px;overflow:hidden;box-shadow:0 2px 14px rgba(20,60,40,.08)}
.hero{width:100%;display:block;height:auto;background:#f3f7f4}
.car{display:flex;justify-content:space-between;gap:10px;align-items:baseline;flex-wrap:wrap;padding:14px 22px;border-bottom:1px solid #eef2ec}
.car b{font-size:17px}.car span{color:#1f7a4d;font-weight:700}
.body{padding:22px}
.eyebrow{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#1f7a4d;font-weight:700}
h1{font-size:24px;margin:6px 0 6px;line-height:1.25}
.sub{color:#5d6b63;margin:0 0 6px;line-height:1.55}
.q{font-weight:700;margin:22px 0 10px;font-size:15px}
.opt{display:flex;gap:12px;align-items:flex-start;border:1.5px solid #dde3da;border-radius:12px;padding:13px 14px;margin-bottom:9px;cursor:pointer;line-height:1.4}
.opt:has(input:checked){border-color:#1f7a4d;background:#eef8f2}
.opt input{margin-top:3px;accent-color:#1f7a4d;width:18px;height:18px;flex:none}
.opt small{display:block;color:#5d6b63;margin-top:2px}
.scale{display:flex;gap:6px}
.scale label{flex:1;position:relative;text-align:center;min-width:0}
.scale input{position:absolute;opacity:0;pointer-events:none}
.scale span{display:block;border:1.5px solid #dde3da;border-radius:10px;padding:10px 0;font-weight:600;cursor:pointer;font-size:14px}
.scale input:checked+span{background:#1f7a4d;border-color:#1f7a4d;color:#fff}
.scale input:focus-visible+span{outline:2px solid #1f7a4d;outline-offset:2px}
.scale.n11 span{padding:9px 0;font-size:13px}
.hint{display:flex;justify-content:space-between;font-size:12px;color:#6b7a72;margin-top:5px}
.field{margin-top:4px}
input[type=datetime-local],textarea{width:100%;font:inherit;font-size:16px;padding:11px 12px;border:1.5px solid #dde3da;border-radius:10px;background:#fff;color:inherit}
input:focus,textarea:focus{outline:2px solid #1f7a4d;outline-offset:-1px;border-color:transparent}
textarea{min-height:88px;resize:vertical}
.btn{display:block;width:100%;margin-top:22px;padding:15px;border:0;border-radius:12px;background:#1f7a4d;color:#fff;font:inherit;font-weight:700;font-size:16px;cursor:pointer}
.btn:hover{filter:brightness(1.07)}
.err{background:#fbe4e2;color:#b3261e;border-radius:10px;padding:10px 12px;margin:14px 0 0;font-size:14px}
.ok{text-align:center;padding:36px 24px}
.check{width:66px;height:66px;border-radius:50%;background:#e2f1e8;color:#1f7a4d;display:grid;place-items:center;font-size:32px;margin:0 auto 14px;font-weight:700}
.resumen{background:#f3f7f4;border-radius:12px;padding:12px 14px;margin-top:16px;text-align:left;font-size:14px;line-height:1.5}
.foot{font-size:12px;color:#6b7a72;text-align:center;margin-top:18px;line-height:1.5}
.small{font-size:13px;color:#5d6b63}
CSS
  my $t = esc_html($title);
  my $html = qq{<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>$t · $CONCESIONARIO</title><style>$css</style></head>
<body><div class="wrap"><div class="brand"><div class="mark">E</div>$CONCESIONARIO</div>$inner
<div class="foot">$CONCESIONARIO · Madrid, España<br>Tus respuestas solo las ve tu asesor/a y el equipo comercial.</div></div></body></html>};
  my $res = HTTP::Response->new($code || 200);
  $res->header('Content-Type' => 'text/html; charset=utf-8', 'Cache-Control' => 'no-store', 'X-Content-Type-Options' => 'nosniff',
               'Referrer-Policy' => 'no-referrer', 'X-Frame-Options' => 'DENY');
  $res->content(encode('UTF-8', $html));
  return $res;
}
sub page_mensaje {
  my ($title, $texto, $resumen, $code) = @_;
  my $rs = defined $resumen && $resumen ne '' ? '<div class="resumen"><b>Tu respuesta</b><br>' . esc_html($resumen) . '</div>' : '';
  return page_res($title, '<div class="card ok"><div class="check">✓</div><h1>' . esc_html($title) . '</h1><p class="sub">' . esc_html($texto) . "</p>$rs</div>", $code);
}

sub respuesta_page {
  my ($token, $r) = @_;
  my $dbh = db();
  my $e = $dbh->selectrow_hashref('SELECT * FROM enlaces WHERE token = ?', undef, $token);
  my $c = $e ? get_cliente($dbh, $e->{cliente_id}) : undef;
  return page_res('Enlace no válido', '<div class="card ok"><div class="check">!</div><h1>Este enlace no es válido</h1><p class="sub">Puede que haya caducado o que se haya copiado incompleto. Responde al correo que te enviamos y te ayudamos encantados.</p></div>', 404)
    unless $e && $c;
  if ($e->{respondido}) {
    return page_mensaje("¡Gracias, $c->{nombre}!", "Ya recibimos tu respuesta. Si quieres cambiar algo, responde al correo y tu asesor/a $c->{asesor} lo ajustará contigo.", $e->{resumen});
  }
  my $f = $r->method eq 'POST' ? parse_form($r) : {};
  my $error = '';
  if ($r->method eq 'POST') {
    my ($ok, $resumen);
    if ($e->{tipo} eq 'encuesta') {
      my $enc = $dbh->selectrow_hashref('SELECT * FROM encuestas WHERE id = ?', undef, $e->{encuesta_id});
      ($ok, $resumen) = $enc ? registrar_encuesta($dbh, $enc, $f, 'Cliente (respuesta web)', 0) : (0, 'Encuesta no encontrada.');
    } else {
      ($ok, $resumen) = registrar_invitacion($dbh, $e, $c, $f);
    }
    if ($ok) {
      my %cc = %$c; push @AFTER, sub { notificar_respuesta(\%cc, $resumen) };
      my $txt = $e->{tipo} eq 'encuesta'
        ? "Tu opinión ya está con nuestro equipo. ¡Muchas gracias por ayudarnos a mejorar!"
        : "Tu respuesta ya está con $c->{asesor}, tu asesor/a, que se pondrá en contacto contigo muy pronto para confirmar todos los detalles.";
      return page_mensaje("¡Gracias, $c->{nombre}!", $txt, $resumen);
    }
    $error = $resumen;
  }
  return $e->{tipo} eq 'encuesta' ? form_encuesta($c, $e, $f, $error) : form_invitacion($dbh, $c, $e, $f, $error);
}

sub registrar_invitacion {
  my ($dbh, $e, $c, $f) = @_;
  my $v = $dbh->selectrow_hashref('SELECT * FROM catalogo WHERE id = ?', undef, $e->{vehiculo} // '') || vehiculo_de($dbh, $c);
  my $modelo = $v ? $v->{modelo} : 'vehículo';
  my $op = $f->{opcion} // '';
  my %validas = map { $_ => 1 } ('otra_fecha', 'llamada', 'no', ($e->{fecha_propuesta} ? 'confirmo' : ()));
  return (0, 'Elige una de las opciones, por favor.') unless $validas{$op};
  my $com = trim(substr($f->{comentario} // '', 0, 1000));
  my ($evento, $res);
  if ($op eq 'confirmo') {
    ($evento, $res) = ('Cita confirmada', "Confirma el test drive del $modelo el " . fecha_txt($e->{fecha_propuesta}));
  } elsif ($op eq 'otra_fecha') {
    return (0, 'Indica la fecha y hora que te vienen bien.') unless fecha_valida($f->{fecha});
    return (0, 'La fecha elegida ya pasó. Elige una fecha futura.') if $f->{fecha} lt strftime('%Y-%m-%dT%H:%M', localtime);
    ($evento, $res) = ('Solicitud prueba', "Quiere probar el $modelo y propone el " . fecha_txt($f->{fecha}));
  } elsif ($op eq 'llamada') {
    ($evento, $res) = ('Otro', "Le interesa el $modelo y pide que le llamen antes de agendar la prueba");
  } else {
    ($evento, $res) = ('Otro', "No quiere hacer la prueba del $modelo por ahora");
  }
  my $resumen = $res . ($com ? " · \"$com\"" : '');
  my $json = JSON::PP->new->encode({ opcion => $op, fecha => ($op eq 'otra_fecha' ? $f->{fecha} : $op eq 'confirmo' ? $e->{fecha_propuesta} : undef), comentario => $com });
  return @{transaction($dbh, sub {
    write_lock($dbh);
    my $n = $dbh->do('UPDATE enlaces SET respondido = ?, respuesta = ?, resumen = ?, leido = 0 WHERE token = ? AND respondido IS NULL', undef, now_iso(), $json, $resumen, $e->{token});
    return [0, 'Esta invitación ya fue respondida o no existe.'] unless $n > 0;
    add_int($dbh, $c->{id}, 'Web', $evento, $resumen, 'Cliente (respuesta web)', '');
    return [1, $resumen];
  })};
}

sub form_invitacion {
  my ($dbh, $c, $e, $f, $error) = @_;
  my $v = $dbh->selectrow_hashref('SELECT * FROM catalogo WHERE id = ?', undef, $e->{vehiculo} // '') || vehiculo_de($dbh, $c);
  my $sel = $f->{opcion} // '';
  my $chk = sub { $sel eq $_[0] ? ' checked' : '' };
  my $modelo = esc_html($v->{modelo});
  my $hoy = strftime('%Y-%m-%dT%H:%M', localtime);
  my $confirmo = $e->{fecha_propuesta}
    ? '<label class="opt"><input type="radio" name="opcion" value="confirmo"' . $chk->('confirmo') . '><span><b>Sí, confirmo la fecha</b><small>' . esc_html(ucfirst_utf(fecha_txt($e->{fecha_propuesta}))) . '</small></span></label>'
    : '';
  my $otra = $e->{fecha_propuesta} ? 'Sí, pero prefiero otra fecha' : 'Sí, me encantaría';
  my $inner = qq{<form method="post" class="card" novalidate>
<img class="hero" src="/img/$v->{id}.jpg" alt="$modelo">
<div class="car"><b>$modelo</b><span>Desde } . esc_html(eur($v->{precio})) . qq{</span></div>
<div class="body">
  <div class="eyebrow">Tu invitación al test drive</div>
  <h1>¡Hola, } . esc_html($c->{nombre}) . qq{!</h1>
  <p class="sub">¿Te apetece probar el $modelo? Elige una opción y } . esc_html($c->{asesor}) . qq{, tu asesor/a, se encargará del resto.</p>
  } . ($error ? '<div class="err">' . esc_html($error) . '</div>' : '') . qq{
  <div class="q">¿Hacemos la prueba de conducción?</div>
  $confirmo
  <label class="opt"><input type="radio" name="opcion" value="otra_fecha"} . $chk->('otra_fecha') . qq{><span><b>$otra</b><small>Dinos qué día y hora te vienen mejor</small></span></label>
  <div class="field" id="fecha-box"><input type="datetime-local" name="fecha" min="$hoy" value="} . esc_html($f->{fecha} // '') . qq{" aria-label="Fecha y hora que prefieres"></div>
  <label class="opt" style="margin-top:9px"><input type="radio" name="opcion" value="llamada"} . $chk->('llamada') . qq{><span><b>Prefiero que me llaméis primero</b><small>Para resolver dudas antes de agendar</small></span></label>
  <label class="opt"><input type="radio" name="opcion" value="no"} . $chk->('no') . qq{><span><b>Ahora no, gracias</b><small>Podéis escribirme más adelante</small></span></label>
  <div class="q">¿Quieres contarnos algo más? <span class="small">(opcional)</span></div>
  <textarea name="comentario" maxlength="1000" placeholder="Por ejemplo: prefiero por la tarde, quiero comparar con otro modelo…">} . esc_html($f->{comentario} // '') . qq{</textarea>
  <button class="btn" type="submit">Enviar mi respuesta</button>
</div></form>
<script>(function(){var b=document.getElementById('fecha-box');function u(){var s=document.querySelector('input[name=opcion]:checked');b.style.display=(s&&s.value==='otra_fecha')?'block':'none';}document.querySelectorAll('input[name=opcion]').forEach(function(i){i.addEventListener('change',u)});u();})();</script>};
  return page_res("Invitación al test drive", $inner);
}

sub form_encuesta {
  my ($c, $e, $f, $error) = @_;
  my $radio = sub {
    my ($name, $vals, $cls) = @_;
    return qq{<div class="scale $cls">} . join('', map { my $ch = ($f->{$name} // '') eq $_ ? ' checked' : ''; qq{<label><input type="radio" name="$name" value="$_"$ch><span>$_</span></label>} } @$vals) . '</div>';
  };
  my $int = $f->{interes} // '';
  my $opt = sub { my ($val, $t, $s) = @_; my $ch = $int eq $val ? ' checked' : ''; qq{<label class="opt"><input type="radio" name="interes" value="$val"$ch><span><b>$t</b><small>$s</small></span></label>} };
  my $inner = qq{<form method="post" class="card" novalidate><div class="body">
  <div class="eyebrow">Encuesta · 1 minuto</div>
  <h1>¡Hola, } . esc_html($c->{nombre}) . qq{!</h1>
  <p class="sub">Gracias por dedicarnos un momento. Tu opinión nos ayuda a mejorar cada día.</p>
  } . ($error ? '<div class="err">' . esc_html($error) . '</div>' : '') . qq{
  <div class="q">1. ¿Qué tan satisfecho/a estás con la atención recibida?</div>
  } . $radio->('satisfaccion', [1 .. 5], '') . qq{<div class="hint"><span>Nada</span><span>Muchísimo</span></div>
  <div class="q">2. ¿Nos recomendarías a un amigo o familiar?</div>
  } . $radio->('nps', [0 .. 10], 'n11') . qq{<div class="hint"><span>Nada probable</span><span>Seguro que sí</span></div>
  <div class="q">3. ¿Te gustaría hacer una prueba de conducción?</div>
  } . $opt->('Sí', 'Sí, me encantaría', 'Tu asesor/a te propondrá una fecha') . $opt->('Más adelante', 'Más adelante', 'Ahora no es el momento') . $opt->('No', 'No, gracias', '') . qq{
  <div class="q">4. ¿Algo que quieras contarnos? <span class="small">(opcional)</span></div>
  <textarea name="comentario" maxlength="1000" placeholder="Lo que más te gustó, lo que podemos mejorar…">} . esc_html($f->{comentario} // '') . qq{</textarea>
  <button class="btn" type="submit">Enviar mis respuestas</button>
</div></form>};
  return page_res('Encuesta', $inner);
}
