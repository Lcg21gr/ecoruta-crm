const http = require('node:http');

let refreshes = 0;
const messages = [];
let accepted = 0;
let unauthorized = 0;
const uncertain = [];

http.createServer(async (req, res) => {
  const respond = (status, value) => {
    res.writeHead(status, {'content-type': 'application/json'});
    res.end(JSON.stringify(value));
  };
  const path = new URL(req.url, 'http://fixture').pathname;
  if (req.method === 'GET' && path === '/__test/results') {
    return respond(200, {refreshes, messages, accepted, unauthorized, uncertain});
  }
  let content = req.body;
  if (content === undefined) {
    content = '';
    for await (const chunk of req) content += chunk;
  }
  if (Buffer.isBuffer(content)) content = content.toString('utf8');
  if (req.method === 'POST' && path === '/token') {
    const form = new URLSearchParams(content);
    if (!req.headers['content-type']?.includes('application/x-www-form-urlencoded')
        || form.get('grant_type') !== 'refresh_token'
        || form.get('client_id') !== 'fixture-client'
        || form.get('client_secret') !== 'fixture-secret'
        || form.get('refresh_token') !== 'fixture-refresh') {
      return respond(400, {error:'invalid_grant'});
    }
    return respond(200, {access_token:'fixture-token-' + ++refreshes, expires_in:3600, token_type:'Bearer'});
  }
  if (req.method === 'POST' && path === '/gmail/v1/users/me/messages/send') {
    if (!req.headers['content-type']?.includes('application/json')) return respond(415, {error:{status:'INVALID_ARGUMENT'}});
    const {raw} = typeof content === 'string' ? JSON.parse(content) : content;
    if (!/^[A-Za-z0-9_-]+$/.test(raw || '')) return respond(400, {error:{status:'INVALID_ARGUMENT'}});
    const mime = Buffer.from(raw, 'base64url').toString();
    if (!mime.startsWith('From:') || !mime.includes('\r\nTo: ') || /(?<!\r)\n/.test(mime)) {
      return respond(400, {error:{status:'INVALID_ARGUMENT'}});
    }
    const token = req.headers.authorization;
    if (!/^Bearer fixture-token-[0-9]+$/.test(token || '')) return respond(401, {error:{status:'UNAUTHENTICATED'}});
    if (token.endsWith('-1')) {
      unauthorized++;
      return respond(401, {error:{status:'UNAUTHENTICATED'}});
    }
    if (mime.includes('\r\nTo: temporal@example.test\r\n')) {
      uncertain.push(mime);
      return respond(503, {error:{status:'UNAVAILABLE', message:'No mostrar fixture-secreto-interno'}});
    }
    if (mime.includes('\r\nTo: limite@example.test\r\n')) return respond(429, {error:{status:'RESOURCE_EXHAUSTED'}});
    accepted++;
    messages.push(mime);
    return respond(200, {id:'fixture-message-' + accepted});
  }
  return respond(501, {error:{status:'UNIMPLEMENTED'}});
}).listen(process.env.PORT);
