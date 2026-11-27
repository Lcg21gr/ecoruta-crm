package EcoRuta::DB;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use DBI;
use URI::Escape qw(uri_unescape);
our @EXPORT_OK = qw(connect_db is_pg transaction write_lock ensure_schema init_counters next_id import_sqlite);

sub connect_db {
  my ($cfg, %opt) = @_;
  my %attrs = (RaiseError => 1, PrintError => 0, AutoCommit => 1);
  if ($opt{sqlite} || !($cfg->('DATABASE_URL', '') || $cfg->('DB_HOST', ''))) {
    require DBD::SQLite;
    my $file = $opt{sqlite} // $cfg->('DB_PATH', '');
    my $dbh = DBI->connect("dbi:SQLite:dbname=$file", '', '', {
      %attrs, sqlite_unicode => 1, sqlite_use_immediate_transaction => $opt{readonly} ? 0 : 1,
      ($opt{readonly} ? (sqlite_open_flags => DBD::SQLite::OPEN_READONLY()) : ()),
    });
    $dbh->sqlite_busy_timeout(5000);
    $dbh->do('PRAGMA foreign_keys = ON');
    return $dbh;
  }
  my $url = $cfg->('DATABASE_URL', '');
  my ($host, $port, $name, $user, $pass, %options);
  if ($url ne '') {
    ($user, $pass, $host, $port, $name, my $query) = $url =~ m{\Apostgres(?:ql)?://([^:/?\#@]+):([^/?\#@]*)@(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+)(?::([0-9]+))?/([^/?\#]+)(?:\?([^\#]*))?\z};
    die "DATABASE_URL no tiene el formato postgres://usuario:clave\@servidor/base esperado.\n" unless defined $name;
    ($user, $pass, $name) = map { uri_unescape($_) } ($user, $pass, $name);
    $host =~ s/\A\[(.*)\]\z/$1/;
    for my $pair (split /&/, $query // '') {
      my ($key, $value) = split /=/, $pair, 2;
      die "Opción no admitida en DATABASE_URL.\n"
        unless defined $value && $key =~ /\A(?:sslmode|sslrootcert|channel_binding|connect_timeout)\z/;
      $options{$key} = uri_unescape($value);
    }
    $options{sslmode} //= 'verify-full';
    # El CA del sistema también funciona con PostgreSQL administrado.
    $options{sslrootcert} //= '/etc/ssl/certs/ca-certificates.crt' if $options{sslmode} =~ /\Averify-/;
  } else {
    ($host, $port, $name, $user, $pass) = map { $cfg->($_, '') } qw(DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD);
    $options{sslmode} = $cfg->('DB_SSLMODE', 'prefer');
    $options{sslrootcert} = $cfg->('DB_SSLROOTCERT', '/etc/ssl/certs/ca-certificates.crt') if $options{sslmode} =~ /\Averify-/;
  }
  $port ||= 5432;
  $options{connect_timeout} //= 5;
  my %dsn = (%options, host => $host, port => $port, dbname => $name);
  die "Configuración PostgreSQL incompleta o no válida.\n"
    unless length($user) && $port =~ /\A[0-9]+\z/ && $port > 0 && $port <= 65535
      && !grep { !defined($_) || /[;\s'"\\\x00]/ || !length($_) } values %dsn;
  my $dsn = join ';', map { "$_=$dsn{$_}" } sort keys %dsn;
  my $dbh = eval { DBI->connect("dbi:Pg:$dsn", $user, $pass, { %attrs, pg_enable_utf8 => 1 }) };
  die "No se pudo conectar a PostgreSQL. Revisa la configuración, las credenciales y TLS.\n" unless $dbh;
  return $dbh;
}

sub is_pg { $_[0]->{Driver}{Name} eq 'Pg' }
sub transaction {
  my ($dbh, $fn) = @_;
  $dbh->begin_work;
  my $out;
  my $ok = eval { $out = $fn->(); $dbh->commit; 1 };
  unless ($ok) {
    my $error = $@;
    eval { $dbh->rollback };
    die $error;
  }
  return $out;
}

# SQLite inicia la transacción de escritura con BEGIN IMMEDIATE.
# PostgreSQL serializa aquí las secciones cortas que validan y escriben en varias tablas.
sub write_lock { $_[0]->do('SELECT pg_advisory_xact_lock(420706810)') if is_pg($_[0]); }

sub ensure_schema {
  my ($dbh, $file) = @_;
  open my $fh, '<:encoding(UTF-8)', $file or die "No se pudo leer el esquema: $!\n";
  my $sql = do { local $/; <$fh> };
  my $auto = is_pg($dbh) ? 'BIGSERIAL PRIMARY KEY' : 'INTEGER PRIMARY KEY AUTOINCREMENT';
  my $link = is_pg($dbh) ? 'id BIGSERIAL UNIQUE NOT NULL,' : '';
  $sql =~ s/__AUTO_ID__/$auto/g;
  $sql =~ s/__LINK_ID__/$link/g;
  $dbh->do($_) for grep /\S/, split /;/, $sql;
}

my %prefix = (clientes => 'C', encuestas => 'E');
sub init_counters {
  my ($dbh) = @_;
  for my $table (sort keys %prefix) {
    $dbh->do("INSERT INTO contadores (entidad, ultimo)
      SELECT ?, COALESCE(MAX(CAST(SUBSTR(id, 2) AS BIGINT)), 0) FROM $table WHERE 1=1
      ON CONFLICT(entidad) DO NOTHING", undef, $table);
  }
}
sub next_id {
  my ($dbh, $table) = @_;
  die "Contador no válido\n" unless exists $prefix{$table};
  my $changed = $dbh->do('UPDATE contadores SET ultimo = ultimo + 1 WHERE entidad = ?', undef, $table);
  die "Contador no inicializado\n" unless $changed > 0;
  my ($id) = $dbh->selectrow_array('SELECT ultimo FROM contadores WHERE entidad = ?', undef, $table);
  return sprintf('%s%03d', $prefix{$table}, $id);
}

my @tables = (
  [usuarios => qw(id nombre email rol pass_hash creado)],
  [catalogo => qw(id modelo version tec precio recarga uso base disponible)],
  [clientes => qw(id nombre apellido telefono email origen permiso canal tecnologia presupuesto compra_dias carga asesor vehiculo creado)],
  [interacciones => qw(id cliente_id fecha canal evento resultado responsable accion)],
  [encuestas => qw(id cliente_id tipo canal enviada estado respuestas respondida)],
  [envios => qw(id cliente_id tipo destinatario asunto estado detalle fecha usuario)],
  [config => qw(clave valor)],
  [enlaces => qw(id token tipo cliente_id encuesta_id vehiculo fecha_propuesta creado respondido respuesta resumen leido)],
);
sub import_sqlite {
  my ($cfg, $target, $file, $schema) = @_;
  die "Configura un destino PostgreSQL antes de importar.\n" unless is_pg($target);
  die "No se encontró el archivo SQLite.\n" unless -f $file;
  my $source = connect_db($cfg, sqlite => $file, readonly => 1);
  $source->begin_work;
  my ($integrity) = $source->selectrow_array('PRAGMA quick_check');
  die "El SQLite de origen no superó la verificación de integridad.\n"
    unless $integrity eq 'ok' && !@{$source->selectall_arrayref('PRAGMA foreign_key_check')};
  my $counts = transaction($target, sub {
    write_lock($target);
    ensure_schema($target, $schema);
    my %count;
    for my $table (qw(sesiones contadores), map { $_->[0] } @tables) {
      my ($has_rows) = $target->selectrow_array("SELECT 1 FROM $table LIMIT 1");
      die "El destino contiene datos ($table). Usa una base PostgreSQL vacía.\n" if $has_rows;
    }
    for my $spec (@tables) {
      my ($table, @fields) = @$spec;
      my $columns = join ',', @fields;
      my $source_columns = $table eq 'enlaces' ? "rowid AS $columns" : $columns;
      my $marks = join ',', ('?') x @fields;
      my $read = $source->prepare("SELECT $source_columns FROM $table");
      my $write = $target->prepare("INSERT INTO $table ($columns) VALUES ($marks)");
      $read->execute;
      my $copied = 0;
      while (my $row = $read->fetchrow_arrayref) { $write->execute(@$row); $copied++ }
      my ($total) = $target->selectrow_array("SELECT COUNT(*) FROM $table");
      die "No coincide el número de filas en $table.\n" unless $total == $copied;
      $count{$table} = $copied;
    }
    # Las tablas se importan con sus IDs previos. Avanzar las secuencias antes de usar el CRM.
    for my $table (qw(usuarios interacciones envios enlaces)) {
      $target->do("SELECT setval(pg_get_serial_sequence('$table', 'id'), GREATEST(COALESCE(MAX(id), 1), 1), COUNT(*) > 0) FROM $table");
    }
    init_counters($target);
    return \%count;
  });
  $source->commit;
  $source->disconnect;
  return $counts;
}
1;
